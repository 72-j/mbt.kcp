// frame.mbt — FEC 线格式适配器(K8 刀3;合同 = domain/fec_dialect.toml)
//
// 12B 头(大端,对位 KCP 24B 头字节序惯例):
//   [0..4)   group_id    u32  组号,发侧逐组递增
//   [4]      shard_index u8   片位:<k 数据片,>=k 冗余片
//   [5]      k           u8
//   [6]      m           u8
//   [7]      shard_total u8   = k+m(一致性校验位)
//   [8..10)  payload_len u16  头内载荷长(体内 body_len 的镜像)
//   [10..12) reserved    u16  = 0
//
// 片体(受保护域,RS 全片可重建):[0..2) body_len u16 + 载荷 + 零垫。
// 载荷长双写的原因:恢复重建的整片含体,12B 头不可重建——直通快径读头,
// 恢复径只认体内 body_len(单一真相在体内,头是镜像,一致性有门钉)。

///|
/// FEC 头字节数(线帧 = 头 + 片体;刀4 以此让位 KCP mtu,D-FEC5)。
pub const FEC_HEADER_SIZE : Int32 = 12

///|
priv struct FecHeader {
  group_id : Int32
  shard_index : Int32
  k : Int32
  m : Int32
  shard_total : Int32
  payload_len : Int32
}

///|
/// 写 12B 头(帧头可编码后重盖:冗余帧即此用法)。
fn fec_write_header(
  frame : FixedArray[Byte],
  group_id : Int32,
  shard_index : Int32,
  k : Int32,
  m : Int32,
  payload_len : Int32,
) -> Unit {
  frame[0] = ((group_id >> 24) & 0xFF).to_byte()
  frame[1] = ((group_id >> 16) & 0xFF).to_byte()
  frame[2] = ((group_id >> 8) & 0xFF).to_byte()
  frame[3] = (group_id & 0xFF).to_byte()
  frame[4] = (shard_index & 0xFF).to_byte()
  frame[5] = (k & 0xFF).to_byte()
  frame[6] = (m & 0xFF).to_byte()
  frame[7] = ((k + m) & 0xFF).to_byte()
  frame[8] = ((payload_len >> 8) & 0xFF).to_byte()
  frame[9] = (payload_len & 0xFF).to_byte()
  frame[10] = (0).to_byte()
  frame[11] = (0).to_byte()
}

///|
/// 读 12B 头 + 一致性校验:短帧 / k·m 越域 / shard_total 失配 /
/// index 越组 / payload_len 超帧余量 → None(弃置面自计)。
fn fec_read_header(frame : FixedArray[Byte]) -> FecHeader? {
  if frame.length() < FEC_HEADER_SIZE {
    return None
  }
  let group_id = (frame[0].to_int() << 24) |
    (frame[1].to_int() << 16) |
    (frame[2].to_int() << 8) |
    frame[3].to_int()
  let k = frame[5].to_int()
  let m = frame[6].to_int()
  let shard_total = frame[7].to_int()
  let payload_len = (frame[8].to_int() << 8) | frame[9].to_int()
  // 线域:shard_total 单字节 ⇒ k+m ≤ 255(k+m=256 写不出——字节回卷
  // 为 0,恒被 shard_total 核拒;此门拨 255 与之同判,免死宽)。
  // 编解码域(GF 上限 256)由 RsCodec::new 守卫另执,两级不同面。
  if k < 1 || m < 1 || k + m > 255 || shard_total != k + m {
    return None
  }
  let shard_index = frame[4].to_int()
  if shard_index >= shard_total {
    return None
  }
  if payload_len > frame.length() - FEC_HEADER_SIZE {
    return None
  }
  let header : FecHeader = {
    group_id,
    shard_index,
    k,
    m,
    shard_total,
    payload_len,
  }
  Some(header)
}

///|
/// 读体内体长前缀(受保护域,恢复径的单一真相)。
fn fec_body_len(shard : FixedArray[Byte]) -> Int32 {
  (shard[FEC_HEADER_SIZE].to_int() << 8) | shard[FEC_HEADER_SIZE + 1].to_int()
}

///|
/// 剥头剥垫取载荷:体内 body_len 定长(直通帧与恢复重建片同形)。
fn fec_payload_of(shard : FixedArray[Byte]) -> FixedArray[Byte] {
  let body_len = fec_body_len(shard)
  let payload = FixedArray::make(body_len, (0).to_byte())
  FixedArray::unsafe_blit(payload, 0, shard, FEC_HEADER_SIZE + 2, body_len)
  payload
}
