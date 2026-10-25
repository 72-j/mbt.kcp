// rt_relay cmd — KCP 原生实时中继可执行壳:KcpUdpHub(传输)×
// RtRelay(帧逻辑)驱动环。纯形逻辑在 ../relay.mbt,本件只包 IO。

///|
async fn main {
  let hub = @adapter.KcpUdpHub::listen(128, 256)
  let relay = @rt_relay.RtRelay::new(64)
  println("kcp rt-relay listening on \{hub.local_addr()}")
  let mut t = @async.now().to_int()
  let mut next_sweep = t + 5000
  while true {
    // 有界等待 + 回泵(自驱泵形状;两端任一先起都活)
    let _ = @async.with_timeout_opt(20, () => hub.recv_one())
    for conv in hub.convs() {
      let mut go = true
      while go {
        match hub.poll_message(conv) {
          Some(msg) => {
            let text = @rt_relay.frame_text(msg, msg.length())
            let out = relay.on_frame(conv, t, text)
            for entry in out {
              let (target, body) = entry
              let _ = hub.send_message_to(target, @rt_relay.frame_bytes(body))
            }
          }
          None => go = false
        }
      }
    }
    if t >= next_sweep {
      let _ = relay.sweep(t, 30000)
      next_sweep = t + 5000
    }
    let _ = hub.pump_out(t)
    t = @async.now().to_int()
  }
}
