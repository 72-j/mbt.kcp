// main.mbt — K5 差分驱动(MoonBit 侧;与 ../diff_driver.c 逐行同构)
//
// 场景机:双实例 conv=0x12345678,nodelay(1,10,2,1),mtu=300(mss=276);
// 四相收发(A 环前 50/300/550/1000,B@120 拍 120/260/40,A@150 拍 276/277/800,
// B@180 拍 1000/55);B@300 拍收窗缩到 2(应用不读 + 窗停摆 → 探窗 WASK/WINS
// 全上桌),B@600 拍窗复原(恢复投递);2000 拍快钟。
// 带损 + 乱序:LCG 确定性(x = x*1664525+1013904223 回绕,种子 12345)——
// 每帧一抽判丢((x & 0x7FFFFFFF) % 5 == 0 弃,~20%);每批一抽判倒序
// ((x & 0x7FFFFFFF) % 2 == 0 整批倒序投递)——C/MoonBit 同式同种同序。
// 转录行 = `<round> <side> <hex>` **原样无屏蔽**(探窗帧 sn/ts 的 C 模板段
// 残留 quirk 已在核心侧精确复刻,对拍不再特判)。
// 尾行 `done <side> <累计收字节数>` = 收敛验讫。

///|
let conv_id : Int = 0x12345678

///|
let hex_table : Array[String] = [
  "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
]

///|
/// LCG 确定性抽签盒:状态单格(引用语义,跨函数推进可见)。
/// C 侧 `x = x * 1664525u + 1013904223u` 同式(Int 32 位回绕等价)。
struct LossBox {
  mut state : Int
}

///|
fn LossBox::make(seed : Int) -> LossBox {
  { state: seed, }
}

///|
/// 抽一签:推进状态,回正 31 位值。
fn LossBox::draw(self : LossBox) -> Int {
  self.state = self.state * 1664525 + 1013904223
  self.state & 0x7FFFFFFF
}

///|
/// 判一帧去留:~20% 丢弃。
fn LossBox::drop(self : LossBox) -> Bool {
  self.draw() % 5 == 0
}

///|
/// 确定性载荷:(tag * 37 + j) & 0x7F——C 侧同式。
fn payload_of(msg_tag : Int, length : Int) -> Bytes {
  Bytes::makei(length, fn(j) { ((msg_tag * 37 + j) & 0x7F).to_byte() })
}

///|
fn byte_hex(sb : StringBuilder, b : Int) -> Unit {
  sb.write(hex_table[(b >> 4) & 15])
  sb.write(hex_table[b & 15])
}

///|
fn print_frames(round : Int, side : String, frames : Array[Bytes]) -> Unit {
  for frame in frames {
    let sb = StringBuilder()
    sb.write("\{round} ")
    sb.write(side)
    sb.write(" ")
    let mut i = 0
    while i < frame.length() {
      byte_hex(sb, frame[i].to_int())
      i += 1
    }
    println(sb.to_string())
  }
}

///|
/// 带损投递一帧列(倒序判定已先抽):每帧一抽判丢。
fn deliver_lossy(
  loss : LossBox, frames : Array[Bytes], to : @moonkcp.Kcp, reversed : Bool
) -> Unit {
  let n = frames.length()
  let mut i = 0
  while i < n {
    let idx = if reversed {
      n - 1 - i
    } else {
      i
    }
    if loss.drop() == false {
      let _ = to.input(frames[idx])
    }
    i += 1
  }
}

///|
/// 驱动末尾:排空一端全部消息,累计收字节数。
fn total_received(kcp : @moonkcp.Kcp) -> Int {
  let mut total = 0
  let mut go = true
  while go {
    match kcp.recv() {
      Some(msg) => total += msg.length()
      None => go = false
    }
  }
  total
}

///|
fn main {
  let a = @moonkcp.Kcp::create(conv_id)
  let b = @moonkcp.Kcp::create(conv_id)
  a.set_nodelay(1, 10, 2, 1)
  b.set_nodelay(1, 10, 2, 1)
  let _ = a.set_mtu(300)
  let _ = b.set_mtu(300)
  // 第一相:A 发四条(50/300/550/1000 → 分片 1/2/2/4,mss=276)
  let _ = a.send(payload_of(1, 50))
  let _ = a.send(payload_of(2, 300))
  let _ = a.send(payload_of(3, 550))
  let _ = a.send(payload_of(4, 1000))
  let loss = LossBox::make(12345)
  let mut drained_b = 0
  let mut round = 0
  while round < 2000 {
    if round == 120 {
      // 第二相:B 发三条(回程)
      let _ = b.send(payload_of(5, 120))
      let _ = b.send(payload_of(6, 260))
      let _ = b.send(payload_of(7, 40))
    }
    if round == 150 {
      // 第三相:A 追发三条(276 恰一满片 / 277 跨两片 / 800 三片)
      let _ = a.send(payload_of(8, 276))
      let _ = a.send(payload_of(9, 277))
      let _ = a.send(payload_of(10, 800))
    }
    if round == 180 {
      // 第四相:B 追发两条
      let _ = b.send(payload_of(11, 1000))
      let _ = b.send(payload_of(12, 55))
    }
    if round == 60 {
      // 第五相:A 洪发 200 条小消息——B 应用不读,rcv_queue 涨满 128
      // → rmt_wnd=0 → A 停摆 + 探窗(WASK/WINS 真发,quirk 帧上桌)
      let mut flood_tag = 13
      while flood_tag <= 212 {
        let _ = a.send(payload_of(flood_tag, 20))
        flood_tag += 1
      }
    }
    if round == 600 {
      // 泄洪相:排空 B(收窗重开;字节数累计进讫数——末尾口径含中途泄洪)
      let mut go = true
      while go {
        match b.recv() {
          Some(msg) => drained_b += msg.length()
          None => go = false
        }
      }
    }
    let t = round * 10
    let frames_a = a.update(t)
    let frames_b = b.update(t)
    print_frames(round, "a", frames_a)
    print_frames(round, "b", frames_b)
    // 抽签序同 C:两笔倒序签先抽,再进逐帧丢包抽
    let rev_a = loss.draw() % 2 == 0
    let rev_b = loss.draw() % 2 == 0
    deliver_lossy(loss, frames_a, b, rev_a)
    deliver_lossy(loss, frames_b, a, rev_b)
    round += 1
  }
  println("done b \{drained_b + total_received(b)}")
  println("done a \{total_received(a)}")
}
