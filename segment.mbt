// segment.mbt — KCP Segment 线格式(K1;刀1 Bytes 化)
//
// Segment = 24B 固定头 + 可选 data。线格式全 Bytes:构造单趟 makei、
// 零 push 循环(茗篇 moonbit_throughput_ming.md 刀1;Bytes 不可变 ⇒
// send 侧载荷零拷贝共享)。

///|
pub const CMD_PUSH : Int32 = 81

///|
pub const CMD_ACK : Int32 = 82

///|
pub const CMD_WASK : Int32 = 83

///|
pub const CMD_WINS : Int32 = 84

///|
pub const HEADER_SIZE : Int32 = 24

///|
/// KCP 段:24B 线格式字段 + snd_buf 在途态。data 为 Bytes(不可变,
/// 发送侧与载荷共享同一对象,零拷贝)。
pub(all) struct KcpSegment {
  mut conv : Int32
  mut cmd : Int32
  mut frg : Int32
  mut wnd : Int32
  mut ts : Int32
  mut sn : Int32
  mut una : Int32
  mut len : Int32
  mut data : Bytes
  mut xmit : Int32
  mut fastack : Int32
  mut resendts : Int32
  mut rto : Int32
}

///|
/// 线格式段构造(在途态清零)。
fn KcpSegment::make(
  conv : Int32,
  cmd : Int32,
  frg : Int32,
  wnd : Int32,
  ts : Int32,
  sn : Int32,
  una : Int32,
  data : Bytes,
) -> KcpSegment {
  {
    conv,
    cmd,
    frg,
    wnd,
    ts,
    sn,
    una,
    len: data.length(),
    data,
    xmit: 0,
    fastack: 0,
    resendts: 0,
    rto: 0,
  }
}

///|
/// 段线字节求值:i < 24 为头字段 little-endian 展开,其余为载荷直通。
fn segment_byte(seg : KcpSegment, data_len : Int32, i : Int32) -> Byte {
  if i < 4 {
    ((seg.conv >> (i * 8)) & 0xFF).to_byte()
  } else if i == 4 {
    seg.cmd.to_byte()
  } else if i == 5 {
    seg.frg.to_byte()
  } else if i < 8 {
    ((seg.wnd >> ((i - 6) * 8)) & 0xFF).to_byte()
  } else if i < 12 {
    ((seg.ts >> ((i - 8) * 8)) & 0xFF).to_byte()
  } else if i < 16 {
    ((seg.sn >> ((i - 12) * 8)) & 0xFF).to_byte()
  } else if i < 20 {
    ((seg.una >> ((i - 16) * 8)) & 0xFF).to_byte()
  } else if i < 24 {
    ((data_len >> ((i - 20) * 8)) & 0xFF).to_byte()
  } else {
    seg.data[i - 24]
  }
}

///|
/// 编码 Segment 为线格式 Bytes(单趟 makei,头 + 载荷一体成形)。
pub fn encode_segment(seg : KcpSegment) -> Bytes {
  let data_len = seg.data.length()
  Bytes::makei(HEADER_SIZE + data_len, fn(i) { segment_byte(seg, data_len, i) })
}

///|
/// 读取 little-endian u16。
fn read_u16(buf : Bytes, offset : Int32) -> Int32 {
  buf[offset].to_int() | (buf[offset + 1].to_int() << 8)
}

///|
/// 读取 little-endian u32。
fn read_u32(buf : Bytes, offset : Int32) -> Int32 {
  buf[offset].to_int() |
  (buf[offset + 1].to_int() << 8) |
  (buf[offset + 2].to_int() << 16) |
  (buf[offset + 3].to_int() << 24)
}

///|
/// 从 Bytes 报文 offset 处解码一段。返回 (段, 消耗字节数);
/// 头不完整或声明 len 越界返回 None。
pub fn decode_segment(buf : Bytes, offset : Int32) -> (KcpSegment, Int32)? {
  let remaining = buf.length() - offset
  if remaining < HEADER_SIZE {
    return None
  }
  let conv = read_u32(buf, offset)
  let cmd = buf[offset + 4].to_int()
  let frg = buf[offset + 5].to_int()
  let wnd = read_u16(buf, offset + 6)
  let ts = read_u32(buf, offset + 8)
  let sn = read_u32(buf, offset + 12)
  let una = read_u32(buf, offset + 16)
  let data_len = read_u32(buf, offset + 20)
  if offset + HEADER_SIZE + data_len > buf.length() {
    return None
  }
  let data = Bytes::makei(data_len, fn(i) { buf[offset + HEADER_SIZE + i] })
  let seg = KcpSegment::make(conv, cmd, frg, wnd, ts, sn, una, data)
  Some((seg, HEADER_SIZE + data_len))
}
