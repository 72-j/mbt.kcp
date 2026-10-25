// rt-telnet — KCP 实时中继诊断 CLI(§6.5 帧协议;send/listen 两模式)。
//
// 用法:
//   rt-telnet <addr> send <user> <topic> <text>   订阅后发一条 op,收窗内回帧
//   rt-telnet <addr> listen <user> <topic> [ms]   订阅并监听(默认 15000ms,
//                                                 每 2s 心跳),逐帧打印
//
// 单环自驱泵:pump(每轮必泵——interval 门挡拍即消息滞留)→ 有界收
//(超时取消语义无损,UDP 报文在内核排队)→ 排整消息打印。
//
// 服务端:moon run ../rt_relay/cmd --target native

///|
fn mk_subscribe(topic : String, user : String) -> String {
  "{\"kind\":\"subscribe\",\"topic\":\{jstr_lit(topic)},\"user\":\{jstr_lit(user)}}"
}

///|
fn mk_heartbeat(topic : String, user : String) -> String {
  "{\"kind\":\"heartbeat\",\"topic\":\{jstr_lit(topic)},\"user\":\{jstr_lit(user)}}"
}

///|
fn mk_op(topic : String, text : String) -> String {
  "{\"kind\":\"op\",\"topic\":\{jstr_lit(topic)},\"payload\":{\"text\":\{jstr_lit(text)}}}"
}

///|
/// JSON 字符串转义写入(与 rt_relay 中继同式)。
fn jstr_lit(s : String) -> String {
  let sb = StringBuilder()
  sb.write("\"")
  let mut i = 0
  while i < s.length() {
    let code = s[i].to_int()
    if code == 34 {
      sb.write("\\\"")
    } else if code == 92 {
      sb.write("\\\\")
    } else if code < 0x20 {
      sb.write(" ")
    } else {
      sb.write_char(code.unsafe_to_char())
    }
    i += 1
  }
  sb.write("\"")
  sb.to_string()
}

///|
fn parse_ms(s : String) -> Int {
  let mut v = 0
  let mut i = 0
  while i < s.length() {
    let c = s[i].to_int()
    if c >= 48 && c <= 57 {
      v = v * 10 + (c - 48)
    }
    i += 1
  }
  v
}

///|
async fn main {
  let argv = @env.args()
  if argv.length() < 5 {
    println("usage: rt-telnet <addr> send <user> <topic> <text>")
    println("       rt-telnet <addr> listen <user> <topic> [ms]")
    abort("missing arguments")
  }
  let addr = argv[1]
  let mode = argv[2]
  let user = argv[3]
  let topic = argv[4]
  // conv = 时间窗 ⊕ user 哈希:每次运行取新 conv(客户端重启 = 新端点,
  // 中继陈旧会话自然老化);user 低 8 位散列避开同时启动撞车。
  let mut h = -2128831035 // FNV-1a 32 位基 PIO(回绕负形,位面等价)
  let mut ui = 0
  while ui < user.length() {
    h = (h ^ user[ui].to_int()) * 16777619
    ui += 1
  }
  let conv = ((@async.now().to_int() & 0x3F00) | (h & 0xFF)) + 1
  let peer = @adapter.KcpUdpPeer::connect_client(
    conv, 128, @socket.Addr::parse(addr),
  )
  peer.session.kcp.set_nodelay(1, 10, 2, 1)
  println("connected to \{addr} (conv \{conv})")
  let _ = peer.send_message(@rt_relay.frame_bytes(mk_subscribe(topic, user)))
  if mode == "send" {
    let text = if argv.length() > 5 {
      argv[5]
    } else {
      ""
    }
    let _ = peer.send_message(@rt_relay.frame_bytes(mk_op(topic, text)))
  }
  let lifetime = if mode == "listen" {
    let extra = if argv.length() > 5 {
      parse_ms(argv[5])
    } else {
      15000
    }
    extra
  } else {
    3000
  }
  let deadline = @async.now().to_int() + lifetime
  while @async.now().to_int() < deadline {
    // 每轮必泵(interval 门挡拍即消息滞留)
    let _ = peer.pump_out(@async.now().to_int())
    // 有界收(超时取消语义无损——UDP 报文在内核排队,不丢)
    let got = try @async.with_timeout_opt(20, () => peer.recv_one()) catch {
      _ => None
    }
    if got is Some(n) {
      if n > 0 {
        let mut go = true
        while go {
          match peer.poll_message() {
            Some(msg) => {
              println("recv: \{@utf8.decode_lossy(Bytes::from_array(msg))}")
            }
            None => go = false
          }
        }
      }
    }
    if mode == "listen" {
      let _ = peer.send_message(
        @rt_relay.frame_bytes(mk_heartbeat(topic, user)),
      )
    }
    let _ = @async.sleep(20)
  }
  if mode == "send" {
    println("sent op to \{topic}")
  } else {
    println("listen done")
  }
}
