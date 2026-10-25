// KCP 服务端示例:一条 UDP socket 服务多会话(echo hub)。
// 收到的每条消息原样回显给来源客户端;收满 10 条后退出。
//
// 运行(先于 client 启动):
//   moon run . --target native
// 启动后打印监听地址,把它喂给 client。

///|
async fn main {
  let hub = @adapter.KcpUdpHub::listen(128, 16)
  println("kcp echo server listening on \{hub.local_addr()}")
  println("run the client with this address as its argument")
  let mut served = 0
  let mut t = @async.now().to_int()
  while served < 10 {
    // 有界等待 + 回泵:两端自驱,任一端先起都活
    let _ = @async.with_timeout_opt(20, () => hub.recv_one())
    // 新会话配低延迟档(幂等)
    for conv in hub.convs() {
      match hub.server.session_of(conv) {
        Some(session) => session.kcp.set_nodelay(1, 10, 2, 1)
        None => ()
      }
    }
    // 排空各会话整消息,原样回显
    for conv in hub.convs() {
      let mut go = true
      while go {
        match hub.poll_message(conv) {
          Some(msg) => {
            println("conv \{conv} <- \{msg.length()} bytes")
            let _ = hub.send_message_to(conv, msg)
            served += 1
          }
          None => go = false
        }
      }
    }
    for conv in hub.convs() {
      match hub.server.session_of(conv) {
        Some(session) => session.kcp.set_nodelay(1, 10, 2, 1)
        None => ()
      }
    }
    let _ = hub.pump_out(t)
    t = @async.now().to_int()
  }
  println("echoed 10 messages, server done")
}
