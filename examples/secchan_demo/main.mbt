// main.mbt — secchan 真传输演示:KCP 环回上跑 PSK-CR 握手 + AES-GCM 记录层
// 运行:cd moonkcp && moon run examples/secchan_demo --target native
// 单进程双角:bg 任务扮服务端,主协程扮客户端,真 UDP 127.0.0.1 环回。
// 握手 wire 消息骑 KCP 载荷,_keys 到手后每包 AES-GCM 密封(seq 确定性
// nonce + 方向分钥 + 滑窗)。时间与熵常量注入(D-S4;生产换 CSPRNG + 真钟)。

///|
let demo_psk : Bytes = Bytes::make(32, b'\x77')

///|
let demo_aad : Bytes = b"secchan demo"

///|
let demo_client_nonce : Bytes = Bytes::make(16, b'\x0a')

///|
let demo_server_nonce : Bytes = Bytes::make(16, b'\x0b')

///|
enum ServerStage {
  WaitHello
  WaitAuth
  Echo
}

///|
/// 服务端角:等 HELLO → 回 SALT → 核 AUTH → 记录层回显三包。
async fn server_role(hub : @adapter.KcpUdpHub) -> Unit {
  let mut t = @async.now().to_int()
  let mut stage : ServerStage = WaitHello
  let mut server : @secchan.PskCrServer? = None
  let mut sess : @secchan.SecSession? = None
  let mut echoed = 0
  while echoed < 3 {
    let _ = @async.with_timeout_opt(20, () => hub.recv_one())
    for conv in hub.convs() {
      match hub.server.session_of(conv) {
        Some(s) => s.kcp.set_nodelay(1, 10, 2, 1)
        None => ()
      }
      let mut go = true
      while go {
        match hub.poll_message(conv) {
          Some(msg) =>
            match stage {
              WaitHello =>
                match @secchan.PskCrMsg::of_wire(fa_to_bytes(msg)) {
                  Some(h) =>
                    match
                      @secchan.pskcr_server_on_hello(
                        psk=demo_psk,
                        server_nonce=demo_server_nonce,
                        msg=h,
                      ) {
                      Ok((salt, srv)) => {
                        server = Some(srv)
                        let _ = hub.send_message_to(
                          conv,
                          bytes_to_fa(salt.to_wire()),
                        )
                        stage = WaitAuth
                        println("[server] HELLO 收讫,SALT 已回")
                      }
                      Err(_) => println("[server] HELLO 处理败")
                    }
                  None => println("[server] 非 wire 字节,弃")
                }
              WaitAuth =>
                match @secchan.PskCrMsg::of_wire(fa_to_bytes(msg)) {
                  Some(a) =>
                    match server {
                      Some(srv) =>
                        match srv.on_auth(msg=a) {
                          Ok(keys) => {
                            sess = Some(@secchan.SecSession::server(keys~))
                            stage = Echo
                            println("[server] AUTH 核讫,记录层上线")
                          }
                          Err(_) => println("[server] AUTH 核验败")
                        }
                      None => println("[server] 无中态")
                    }
                  None => println("[server] 非 wire 字节,弃")
                }
              Echo =>
                match sess {
                  Some(s) =>
                    match s.open(aad=demo_aad, record=fa_to_bytes(msg)) {
                      Some(pt) => {
                        echoed += 1
                        println("[server] 开出第 \{echoed} 包,原路回封")
                        let _ = hub.send_message_to(
                          conv,
                          bytes_to_fa(s.seal(aad=demo_aad, plaintext=pt)),
                        )
                      }
                      None => println("[server] 记录开启败,弃")
                    }
                  None => println("[server] 未到 Echo 段")
                }
            }
          None => go = false
        }
      }
    }
    t = @async.now().to_int()
    let _ = hub.pump_out(t)
  }
  println("[server] 三包回显完毕,收工")
  // 冲刷宽限:回封已入 KCP 队,泵数拍让尾包出户再弃 hub(否则尾包丢在队列里)
  let mut drained = 0
  while drained < 10 {
    t = @async.now().to_int()
    let _ = hub.pump_out(t)
    let _ = @async.sleep(10)
    drained += 1
  }
}

///|
/// 客户端角:发 HELLO → 吃 SALT 发 AUTH → 记录层发三包收回显。
async fn client_role(addr : String) -> Unit {
  let peer = @adapter.KcpUdpPeer::connect_client(
    9,
    128,
    @socket.Addr::parse(addr),
  )
  peer.session.kcp.set_nodelay(1, 10, 2, 1)
  let (hello, client) = @secchan.pskcr_client_start(
    psk=demo_psk,
    client_nonce=demo_client_nonce,
  )
  let _ = peer.send_message(bytes_to_fa(hello.to_wire()))
  let mut t = @async.now().to_int()
  // 等 SALT → AUTH 出手
  let mut keys : @secchan.SessionKeys? = None
  let mut got_salt = false
  while got_salt == false {
    let _ = @async.with_timeout_opt(20, () => peer.recv_one())
    t = @async.now().to_int()
    let _ = peer.pump_out(t)
    match peer.poll_message() {
      Some(wire) =>
        match @secchan.PskCrMsg::of_wire(fa_to_bytes(wire)) {
          Some(salt_msg) =>
            match client.on_salt(msg=salt_msg) {
              Ok((auth, ckeys)) => {
                let _ = peer.send_message(bytes_to_fa(auth.to_wire()))
                keys = Some(ckeys)
                got_salt = true
                println("[client] SALT 收讫,AUTH 已发")
              }
              Err(_) => println("[client] SALT 处理败")
            }
          None => println("[client] 非 wire 字节,弃")
        }
      None => ()
    }
  }
  let sess = @secchan.SecSession::client(
    keys=match keys {
      Some(k) => k
      None => abort("unreachable")
    },
  )
  // 三包加密回显
  for i in 0..<3 {
    let plain = "ping-\{i} 密信道上的话"
    let _ = peer.send_message(
      bytes_to_fa(sess.seal(aad=demo_aad, plaintext=@utf8.encode(plain))),
    )
    let mut done = false
    while done == false {
      let _ = @async.with_timeout_opt(20, () => peer.recv_one())
      t = @async.now().to_int()
      let _ = peer.pump_out(t)
      match peer.poll_message() {
        Some(rec) =>
          match sess.open(aad=demo_aad, record=fa_to_bytes(rec)) {
            Some(pt) => {
              println(
                "[client] 第 \{i + 1} 包回显 → \{@utf8.decode_lossy(pt)}",
              )
              done = true
            }
            None => ()
          }
        None => ()
      }
    }
  }
  println("[client] 三包全通,收工")
}

///|
/// FixedArray[Byte] → Bytes(adapter 面与 secchan 面的边界件)。
fn fa_to_bytes(fa : FixedArray[Byte]) -> Bytes {
  Bytes::makei(fa.length(), fn(i) { fa[i] })
}

///|
/// Bytes → FixedArray[Byte](send_message 收 FixedArray)。
fn bytes_to_fa(b : Bytes) -> FixedArray[Byte] {
  FixedArray::makei(b.length(), fn(i) { b[i] })
}

///|
async fn main {
  let hub = @adapter.KcpUdpHub::listen(128, 16)
  let addr = "\{hub.local_addr()}"
  println("[demo] secchan 真传输演示:KCP 环回 \{addr}")
  println("")
  @async.with_task_group(async fn(group) -> Unit {
    group.spawn_bg(no_wait=true) <| () => { server_role(hub) }
    let _ = @async.sleep(100)
    client_role(addr)
    let _ = @async.sleep(300)
  })
  println("[demo] 收工")
}
