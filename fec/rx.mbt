// rx.mbt — FEC 接收恢复窗(K8 刀3)
//
// 语义(具名效应):收帧校验 → 按 group_id 攒窗 → 数据片即投(不攒,
// 零排队延时)→ 组齐 k 片当场恢复补投缺失数据片 → 组销账弃迟到片。
// 窗深定常环形,超深逐最老(未 done 计组亡,ARQ 兜底)。

///|
/// 组槽位(包私有):逐组自描述 k/m——发侧逐组拍板,收侧零协商。
struct RxGroup {
  k : Int32
  m : Int32
  slots : Array[FixedArray[Byte]?]
  mut filled : Int32
  mut done : Bool
}

///|
/// FEC 接收机:纯形零 IO,帧由宿主搬运。
pub struct FecRx {
  depth : Int32
  codec_factory : (Int32, Int32) -> &MdsCodec
  groups : Map[Int32, RxGroup]
  order : Array[Int32]
  mut frames_in : Int32
  mut delivered : Int32
  mut recovered_shards : Int32
  mut recovered_groups : Int32
  mut dropped_malformed : Int32
  mut dropped_late : Int32
  mut groups_lost : Int32
}

///|
/// RS 缺省适配器版。
pub fn FecRx::new(depth : Int32) -> FecRx {
  FecRx::with_codec(fn(k : Int32, m : Int32) { RsCodec::new(k, m) }, depth)
}

///|
/// 端口注入版(编解码器工厂逐组调用,k/m 由帧头自描述)。
pub fn FecRx::with_codec(
  codec_factory : (Int32, Int32) -> &MdsCodec,
  depth : Int32,
) -> FecRx {
  {
    depth,
    codec_factory,
    groups: Map([]),
    order: [],
    frames_in: 0,
    delivered: 0,
    recovered_shards: 0,
    recovered_groups: 0,
    dropped_malformed: 0,
    dropped_late: 0,
    groups_lost: 0,
  }
}

///|
/// 接收快照(观测面,R6;信号聚合器将来读此喂策略端口)。
pub struct FecRxStats {
  frames_in : Int32
  delivered : Int32
  recovered_shards : Int32
  recovered_groups : Int32
  dropped_malformed : Int32
  dropped_late : Int32
  groups_lost : Int32
}

///|
pub fn FecRx::stats(self : FecRx) -> FecRxStats {
  {
    frames_in: self.frames_in,
    delivered: self.delivered,
    recovered_shards: self.recovered_shards,
    recovered_groups: self.recovered_groups,
    dropped_malformed: self.dropped_malformed,
    dropped_late: self.dropped_late,
    groups_lost: self.groups_lost,
  }
}

///|
/// 取组或建组:不在窗 → 超深逐最老(未 done 计组亡)→ 建新组入窗。
fn FecRx::group_of(self : FecRx, header : FecHeader) -> RxGroup {
  match self.groups.get(header.group_id) {
    Some(existing) => return existing
    None => ()
  }
  while self.order.length() >= self.depth {
    let oldest = self.order[0]
    let _ = self.order.remove(0)
    match self.groups.get(oldest) {
      Some(old_group) => if !old_group.done { self.groups_lost += 1 }
      None => ()
    }
    let _ = self.groups.remove(oldest)
  }
  let slots : Array[FixedArray[Byte]?] = []
  for _i in 0..<header.shard_total {
    slots.push(None)
  }
  let fresh : RxGroup = {
    k: header.k,
    m: header.m,
    slots,
    filled: 0,
    done: false,
  }
  let _ = self.groups.set(header.group_id, fresh)
  self.order.push(header.group_id)
  fresh
}

///|
/// 进一线上帧,出 KCP 报文流:数据帧即刻透传(剥头剥垫);组齐 k 片
/// 当场恢复,缺失数据片补投;坏帧/重复帧/迟到帧弃置计数。
pub fn FecRx::feed(
  self : FecRx,
  frame : FixedArray[Byte],
) -> Array[FixedArray[Byte]] {
  self.frames_in += 1
  let header : FecHeader = match fec_read_header(frame) {
    Some(h) => h
    None => {
      self.dropped_malformed += 1
      return []
    }
  }
  let group = self.group_of(header)
  if group.done || group.slots[header.shard_index] is Some(_) {
    self.dropped_late += 1
    return []
  }
  // 数据帧:头 payload_len 与体内 body_len 镜像核(漂移 = 腐坏,弃)
  if header.shard_index < header.k && header.payload_len != fec_body_len(frame) {
    self.dropped_malformed += 1
    return []
  }
  group.slots[header.shard_index] = Some(frame)
  group.filled += 1
  let out : Array[FixedArray[Byte]] = []
  if header.shard_index < header.k {
    out.push(fec_payload_of(frame))
    self.delivered += 1
  }
  // 组齐 k 片当场恢复:缺失数据片补投(冗余片由数据片重编码,不投)
  if group.filled >= group.k {
    let codec = (self.codec_factory)(group.k, group.m)
    match codec.recover(group.slots) {
      Some(fullset) => {
        group.done = true
        let mut missed = 0
        for i in 0..<group.k {
          if group.slots[i] is None {
            missed += 1
            out.push(fec_payload_of(fullset[i]))
          }
        }
        if missed > 0 {
          self.recovered_shards += missed
          self.recovered_groups += 1
          self.delivered += missed
        }
      }
      None => {
        // MDS 阵列不该不可逆——诚实计数,组废(ARQ 兜底)
        group.done = true
        self.groups_lost += 1
      }
    }
  }
  out
}
