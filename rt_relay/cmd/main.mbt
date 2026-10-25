// rt_relay cmd — KCP 原生实时中继可执行壳:KcpUdpHub(传输)×
// RtRelay(帧逻辑)驱动环。纯形逻辑在 ../relay.mbt,本件只包 IO。
//
// 收发分离:后台收件任务(recv_into → 收件箱,永不取消——取消打在
// UDP recv 上会冻死后续唤醒)+ 主环(排收件箱 / 帧逻辑 / 泵 / 清扫)。

///|
async fn main {
  let hub = @adapter.KcpUdpHub::listen(128, 256)
  let relay = @rt_relay.RtRelay::new(64)
  println("kcp rt-relay listening on \{hub.local_addr()}")
  let inbox : Array[FixedArray[Byte]] = []
  let mut t = @async.now().to_int()
  let mut next_sweep = t + 5000
  @async.with_task_group(_group => {
    while true {
      // 有界收一报(超时取消语义无损——UDP 报文在内核排队,不丢)
      let got = try @async.with_timeout_opt(20, () => hub.recv_one()) catch {
        _ => None
      }
      if got is Some(n) {
        println("[dbg] recv n=\{n}")
      }
      // 排收件箱 → 会话(recv_one 已直喂;此处兼容注入形)
      while inbox.length() > 0 {
        let datagram = inbox.remove(0)
        let _ = hub.server.on_datagram(datagram)
      }
      // 帧逻辑:逐会话 poll → on_frame → 回投(扇出排除发送者)
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
        // 陈旧 KCP 会话同拍老化(客户端重启换 conv 后,旧会话闲置即摘)
        let _ = hub.sweep(t, 30000)
        next_sweep = t + 5000
      }
      // 向已退客户端端口的 sendto 会遭 ICMP refused 毒化 socket——
      // 泵的瞬态错误必须吞掉,否则中继主环崩死(全员失联)
      let _ = try hub.pump_out(t) catch {
        _ => []
      }
      t = @async.now().to_int()
      let _ = @async.sleep(20)
    }
  })
}
