// main.mbt — 吞吐模式(茗篇 moonbit_throughput_ming.md §3;留证不作门)
//
// 场景:纯核零传输(不出 socket),双实例无损交叉投递——sender 每拍顶满
// 发送窗(window_segs 段),update + 投递 + drain,跑满载荷总量达标为止。
// 读数 = 墙钟 pps(数据段/秒)/ MBps(载荷字节/秒)。
// 参数与 ../bench_driver.c 逐项同构。

///|
let chunk_len : Int32 = 1376 // mtu 1400 - 24 头 = mss,一段一消息

///|
let target_bytes : Int64 = 64L * 1024L * 1024L

///|
let window_segs : Int32 = 512

///|
let max_rounds : Int32 = 100000

///|
fn main {
  let a = @moonkcp.Kcp::create(1)
  let b = @moonkcp.Kcp::create(1)
  a.set_nodelay(1, 10, 2, 1)
  b.set_nodelay(1, 10, 2, 1)
  a.set_wnd(window_segs, window_segs)
  b.set_wnd(window_segs, window_segs)
  let chunk : FixedArray[Byte] = FixedArray::make(chunk_len, 65)
  let start : Int64 = @async.now()
  let mut sent_bytes : Int64 = 0L
  let mut segments : Int64 = 0L
  let mut received : Int64 = 0L
  let mut t = 0
  let mut round = 0
  while received < target_bytes && round < max_rounds {
    // 顶满发送窗
    while a.waitsnd() < window_segs && sent_bytes < target_bytes {
      let _ = a.send(chunk)
      sent_bytes += chunk_len.to_int64()
      segments += 1L
    }
    let frames_a = a.update(t)
    let frames_b = b.update(t)
    for frame in frames_a {
      let _ = b.input(frame)
    }
    for frame in frames_b {
      let _ = a.input(frame)
    }
    // 排空接收
    let mut go = true
    while go {
      match b.recv() {
        Some(msg) => received += msg.length().to_int64()
        None => go = false
      }
    }
    t += 10
    round += 1
  }
  let elapsed_ms : Int64 = @async.now() - start
  if elapsed_ms <= 0L {
    println(
      "KCPBENCH:MOONBIT pps=? mbps=? (elapsed too small: \{elapsed_ms}ms)",
    )
    return
  }
  let pps : Int64 = segments * 1000L / elapsed_ms
  let mbps : Int64 = received * 1000L / elapsed_ms / (1024L * 1024L)
  println(
    "KCPBENCH:MOONBIT pps=\{pps} mbps=\{mbps} bytes=\{received} segs=\{segments} ms=\{elapsed_ms}",
  )
}
