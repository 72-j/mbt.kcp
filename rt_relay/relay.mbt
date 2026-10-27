// relay.mbt — RtRelay:KCP 原生实时中继核心(M1b;moonlineage §6.5 帧协议)
//
// 哑管道纪律(对位 workspace/realtime_relay.mjs):房表 + 扇出(排除
// 发送者)+ presence 名单 + 心跳超时清扫;零持久化,op 载荷不过目。
// 纯形:零 IO 零时钟——报文进,出站 (conv, json) 表出;sweep 时钟由
// 宿主注入。传输(KCP 会话)归调用侧(KcpUdpHub 包外皮)。

///|
/// 公开仅因其出现在公开房表字段类型中;消费方不构造(Envelope 同律)。
pub(all) struct Member {
  user : String
  mut last_seen : Int32
}

///|
/// 实时中继核:房表(topic → conv → member)+ 扇出 + presence。
pub(all) struct RtRelay {
  rooms : Map[String, Map[Int32, Member]]
  max_members : Int32
}

///|
/// 新中继:max_members = 每房成员上限(洪泛护栏)。
pub fn RtRelay::new(max_members : Int32) -> RtRelay {
  { rooms: Map([]), max_members, }
}

///|
fn jfields(j : Json) -> Map[String, Json]? {
  match j {
    Object(fields) => Some(fields)
    _ => None
  }
}

///|
fn jstr(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// JSON 字符串转义写入(引号/反斜杠/控制字符;其余直通)。
fn jlit_into(sb : StringBuilder, s : String) -> Unit {
  sb.write("\"")
  // 码元空间(UTF-16 单元)比较;非控制码元 unsafe_to_char 回写
  //(入串为合法 String,无孤代理)
  let mut i = 0
  while i < s.length() {
    let code = s[i].to_int()
    if code == 34 {
      sb.write("\\\"")
    } else if code == 92 {
      sb.write("\\\\")
    } else if code == 10 {
      sb.write("\\n")
    } else if code == 13 {
      sb.write("\\r")
    } else if code == 9 {
      sb.write("\\t")
    } else if code < 0x20 {
      sb.write("\\u00")
      sb.write(hexdigit((code >> 4) & 15))
      sb.write(hexdigit(code & 15))
    } else {
      sb.write_char(code.unsafe_to_char())
    }
    i += 1
  }
  sb.write("\"")
}

///|
fn hexdigit(v : Int32) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  sb.write(digits[(v >> 4) & 15])
  sb.write(digits[v & 15])
  sb.to_string()
}

///|
/// JSON 字符串字面量便捷形(转义写入)。
fn jlit(s : String) -> String {
  let sb = StringBuilder()
  jlit_into(sb, s)
  sb.to_string()
}

///|
/// 递归 JSON 序列化(core Json 变体只读不可直构,自写写出器;
/// 键序随遍历,语义等价、字节序不保证——中继哑管道语义无损)。
fn json_write(sb : StringBuilder, j : Json) -> Unit {
  match j {
    Null => sb.write("null")
    True => sb.write("true")
    False => sb.write("false")
    Number(n, ..) => sb.write(n.to_string())
    String(s) => jlit_into(sb, s)
    Array(items) => {
      sb.write("[")
      let mut first = true
      for item in items {
        if first == false {
          sb.write(",")
        }
        first = false
        json_write(sb, item)
      }
      sb.write("]")
    }
    Object(fields) => {
      sb.write("{")
      let mut first = true
      for key, value in fields {
        if first == false {
          sb.write(",")
        }
        first = false
        jlit_into(sb, key)
        sb.write(":")
        json_write(sb, value)
      }
      sb.write("}")
    }
  }
}

///|
/// 入站一帧 → 出站 (conv, json) 表。畸形/未知 kind 静默弃(空表)。
/// 每有效帧刷新发送者活跃戳。
pub fn RtRelay::on_frame(
  self : RtRelay,
  conv : Int32,
  now : Int32,
  text : String,
) -> Array[(Int32, String)] {
  let out : Array[(Int32, String)] = []
  let parsed = @json.parse(text) catch { _ => return out }
  let fields = match jfields(parsed) {
    Some(f) => f
    None => return out
  }
  let kind = match jstr(fields, "kind") {
    Some(k) => k
    None => return out
  }
  let topic = match jstr(fields, "topic") {
    Some(t) => t
    None => return out
  }
  if kind == "subscribe" || kind == "heartbeat" {
    let user = match jstr(fields, "user") {
      Some(u) => u
      None => return out
    }
    self.join(topic, conv, user, now)
    self.broadcast_presence(topic, out)
    return out
  }
  // cursor / op:发送者须已在房
  let room = match self.rooms.get(topic) {
    Some(r) => r
    None => return out
  }
  let attendee = match room.get(conv) {
    Some(m) => m
    None => return out
  }
  attendee.last_seen = now
  if kind == "cursor" {
    let doc = match jstr(fields, "doc") {
      Some(d) => d
      None => return out
    }
    let pos = match jstr(fields, "pos") {
      Some(p) => p
      None => return out
    }
    let body = "{\"kind\":\"cursor\",\"topic\":\{jlit(topic)},\"user\":\{jlit(attendee.user)},\"doc\":\{jlit(doc)},\"pos\":\{jlit(pos)}}"
    self.fanout(topic, conv, body, out)
    return out
  }
  if kind == "op" {
    let payload = match fields.get("payload") {
      Some(p) => {
        let psb = StringBuilder()
        json_write(psb, p)
        psb.to_string()
      }
      None => return out
    }
    let body = "{\"kind\":\"op\",\"topic\":\{jlit(topic)},\"payload\":\{payload}}"
    self.fanout(topic, conv, body, out)
    return out
  }
  out
}

///|
/// 入房(容量护栏:满员弃新);已在房则刷新 user 与活跃戳。
fn RtRelay::join(
  self : RtRelay,
  topic : String,
  conv : Int32,
  user : String,
  now : Int32,
) -> Unit {
  let room = match self.rooms.get(topic) {
    Some(r) => r
    None => {
      let r : Map[Int32, Member] = Map([])
      self.rooms[topic] = r
      r
    }
  }
  match room.get(conv) {
    Some(attendee) => {
      attendee.last_seen = now
      ()
    }
    None => {
      if room.length() >= self.max_members {
        return
      }
      room[conv] = { user, last_seen: now, }
    }
  }
}

///|
/// 扇出:房内除发送者外的全部成员。
fn RtRelay::fanout(
  self : RtRelay,
  topic : String,
  sender : Int32,
  body : String,
  out : Array[(Int32, String)],
) -> Unit {
  let room = match self.rooms.get(topic) {
    Some(r) => r
    None => return
  }
  for conv, _attendee in room {
    if conv != sender {
      out.push((conv, body))
    }
  }
}

///|
/// presence 全量名单广播至房内全员。
fn RtRelay::broadcast_presence(
  self : RtRelay,
  topic : String,
  out : Array[(Int32, String)],
) -> Unit {
  let room = match self.rooms.get(topic) {
    Some(r) => r
    None => return
  }
  let sb = StringBuilder()
  sb.write("{\"kind\":\"presence\",\"topic\":\{jlit(topic)},\"users\":[")
  let mut first = true
  for _conv, attendee in room {
    if first == false {
      sb.write(",")
    }
    sb.write(jlit(attendee.user))
    first = false
  }
  sb.write("]}")
  let body = sb.to_string()
  for conv, _attendee in room {
    out.push((conv, body))
  }
}

///|
/// 闲置清扫:now - last_seen > ttl 的成员逐出,受影响房广播 presence。
/// 返回被逐 (topic, conv) 清单。
pub fn RtRelay::sweep(
  self : RtRelay,
  now : Int32,
  ttl : Int32,
) -> Array[(String, Int32)] {
  let stale : Array[(String, Int32)] = []
  for topic, room in self.rooms {
    for conv, attendee in room {
      if itimediff_rel(now, attendee.last_seen) > ttl {
        stale.push((topic, conv))
      }
    }
  }
  let evicted : Array[(String, Int32)] = []
  let mut i = 0
  while i < stale.length() {
    let (topic, conv) = stale[i]
    match self.rooms.get(topic) {
      Some(room) => {
        let _ = room.remove(conv)
        evicted.push((topic, conv))
        let out : Array[(Int32, String)] = []
        self.broadcast_presence(topic, out)
      }
      None => ()
    }
    i += 1
  }
  evicted
}

///|
fn itimediff_rel(later : Int32, earlier : Int32) -> Int32 {
  later - earlier
}

///|
/// String → UTF-8 定长字节帧(控制/载荷帧体;帧长即字符编码后字节数)。
pub fn frame_bytes(text : String) -> FixedArray[Byte] {
  let bytes = @utf8.encode(text)
  let fa : FixedArray[Byte] = FixedArray::make(bytes.length(), 0b0)
  let mut i = 0
  while i < bytes.length() {
    fa[i] = bytes[i]
    i += 1
  }
  fa
}

///|
/// UTF-8 字节帧 → String(recv 侧;失配字节按 lossy 处理)。
pub fn frame_text(buf : FixedArray[Byte], n : Int32) -> String {
  let copy : FixedArray[Byte] = FixedArray::make(n, 0b0)
  if n > 0 {
    FixedArray::unsafe_blit(copy, 0, buf, 0, n)
  }
  @utf8.decode_lossy(Bytes::from_array(copy))
}

///|
/// 房内成员数(护栏读数;无房返回 0)。
pub fn RtRelay::size(self : RtRelay, topic : String) -> Int32 {
  match self.rooms.get(topic) {
    Some(room) => room.length()
    None => 0
  }
}
