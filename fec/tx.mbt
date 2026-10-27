// tx.mbt — FEC 发送组状态机(K8 刀3)
//
// 语义(具名效应,K9 策略机可拾):收片 → 攒组 → 组满同突发发冗余 → 闭组
// 推进组号。发侧零等待(D-卷 §四):数据帧到达即出,冗余帧只搭组满那拍
// 的顺风车;尾组不满 k 不闭(D-FEC4),ARQ 兜底。

///|
/// FEC 发送机:纯形零 IO,帧由宿主搬运。
pub struct FecTx {
  k : Int32
  m : Int32
  /// 线帧整片字节数(12B 头 + 体);载荷上限 = capacity - 14。
  capacity : Int32
  codec : &MdsCodec
  mut group_id : Int32
  mut slots : Array[FixedArray[Byte]]
  mut closed_groups : Int32
  mut frames_out : Int32
}

///|
/// RS 缺省适配器版。
pub fn FecTx::new(k : Int32, m : Int32, capacity : Int32) -> FecTx {
  FecTx::with_codec(RsCodec::new(k, m), k, m, capacity)
}

///|
/// 端口注入版(换码 = 换适配器,层机器零改动)。
/// 判据:k ≥ 1,m ≥ 1,k+m ≤ 255(shard_total 单字节线域;越域即断言死,
/// k+m=256 的组形线头写不出,发出来只会全数被对端弃置——谎报不如急停)。
pub fn FecTx::with_codec(
  codec : &MdsCodec,
  k : Int32,
  m : Int32,
  capacity : Int32,
) -> FecTx {
  if k < 1 || m < 1 || k + m > 255 {
    abort(
      "FecTx::with_codec: 组形越线域 k=\{k} m=\{m}(判据:k≥1, m≥1, k+m≤255)",
    )
  }
  {
    k,
    m,
    capacity,
    codec,
    group_id: 0,
    slots: [],
    closed_groups: 0,
    frames_out: 0,
  }
}

///|
/// 发送快照。
pub struct FecTxStats {
  closed_groups : Int32
  frames_out : Int32
}

///|
pub fn FecTx::stats(self : FecTx) -> FecTxStats {
  { closed_groups: self.closed_groups, frames_out: self.frames_out, }
}

///|
/// 下一片数据:载荷进组,出线上帧——数据帧即出;组满同突发追加冗余帧。
/// 判据:载荷 ≤ capacity - 14(12B 头 + 2B 体长前缀),超限即断言死
/// (刀4 以 KCP mtu 让位保证;静默截断是谎报)。
pub fn FecTx::feed(
  self : FecTx,
  payload : FixedArray[Byte],
) -> Array[FixedArray[Byte]] {
  if payload.length() > self.capacity - 14 {
    abort(
      "FecTx::feed 载荷超片容量:\{payload.length()} > \{self.capacity - 14}",
    )
  }
  let payload_len = payload.length()
  let shard = FixedArray::make(self.capacity, (0).to_byte())
  shard[FEC_HEADER_SIZE] = ((payload_len >> 8) & 0xFF).to_byte()
  shard[FEC_HEADER_SIZE + 1] = (payload_len & 0xFF).to_byte()
  FixedArray::unsafe_blit(shard, FEC_HEADER_SIZE + 2, payload, 0, payload_len)
  fec_write_header(
    shard,
    self.group_id,
    self.slots.length(),
    self.k,
    self.m,
    payload_len,
  )
  self.slots.push(shard)
  let out : Array[FixedArray[Byte]] = [shard]
  self.frames_out += 1
  if self.slots.length() == self.k {
    // 闭组:同突发发冗余帧(头编码后重盖)
    let data : Array[FixedArray[Byte]] = []
    for s in self.slots {
      data.push(s)
    }
    let parity = self.codec.encode_parity(data)
    for r in 0..<self.m {
      let p = parity[r]
      fec_write_header(
        p,
        self.group_id,
        self.k + r,
        self.k,
        self.m,
        self.capacity - FEC_HEADER_SIZE,
      )
      out.push(p)
      self.frames_out += 1
    }
    self.closed_groups += 1
    self.group_id = self.group_id + 1
    self.slots = []
  }
  out
}
