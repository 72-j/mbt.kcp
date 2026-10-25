// KCP 客户端示例:connected UDP,向服务端发 10 条消息并逐条收回显。
//
// 运行(先启动 server,把它打印的监听地址作为参数):
//   moon run . --target native -- 127.0.0.1:XXXXX

///|
/// 载荷构造:data[0] = tag,其余递推——与 server 同式。
fn mk_payload(tag : Int, len : Int) -> FixedArray[Byte] {
  FixedArray::makei(len, fn(i) { ((tag + i) % 128).to_byte() })
}

///|
async fn main {
  let argv = @env.args()
  if argv.length() < 2 {
    println("usage: moon run . --target native -- <server_addr>")
    println("example: moon run . --target native -- 127.0.0.1:40001")
    abort("missing server address")
  }
  let server_addr = argv[1]
  let peer = @adapter.KcpUdpPeer::connect_client(7, 128, @socket.Addr::parse(server_addr))
  peer.session.kcp.set_nodelay(1, 10, 2, 1)
  println("connected to \{server_addr} (conv 7)")
  let mut sent = 0
  let mut got = 0
  let mut t = @async.now().to_int()
  while got < 10 {
    if sent < 10 {
      let _ = peer.send_message(mk_payload(sent + 1, 16))
      sent += 1
    }
    let _ = peer.pump_out(t)
    // 有界等待 + 回泵:阻塞中时钟停走会活锁(实测),20ms 无报即回泵续拍
    let _ = @async.with_timeout_opt(20, () => peer.recv_one())
    let mut go = true
    while go {
      match peer.poll_message() {
        Some(msg) => {
          println("echo \{got}: \{msg.length()} bytes")
          got += 1
          go = false
        }
        None => go = false
      }
    }
    t = @async.now().to_int()
  }
  println("done: sent 10, echoed 10, client done")
}
