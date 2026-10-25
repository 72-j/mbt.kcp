// server_wbtest.mbt — K6 门:conv 分离(多会话路由)/自动建会话/洪泛护栏/收尸

///|
fn mk_server_client(conv : Int32) -> Kcp {
  let client = Kcp::create(conv)
  client.set_nodelay(1, 10, 2, 1)
  client
}

///|
/// 服务端级泵:各 client 一拍,帧全喂 server;server 一拍,
/// (conv, 帧) 按 conv 回投各 client。
fn pump_server(
  server : KcpServer,
  clients : Array[Kcp],
  start_ms : Int32,
  ticks : Int32,
) -> Unit {
  let mut t = start_ms
  let mut tick = 0
  while tick < ticks {
    for client in clients {
      let frames = client.update(t)
      let mut i = 0
      while i < frames.length() {
        let _ = server.on_datagram(frames[i])
        i += 1
      }
    }
    let tagged = server.tick(t)
    let mut i = 0
    while i < tagged.length() {
      let (conv, frame) = tagged[i]
      let mut j = 0
      while j < clients.length() {
        if clients[j].conv == conv {
          let _ = clients[j].input(frame)
        }
        j += 1
      }
      i += 1
    }
    t += 10
    tick += 1
  }
}

///|
fn drain_session(session : KcpSession, out : Array[Bytes]) -> Unit {
  let mut go = true
  while go {
    match session.poll_message() {
      Some(msg) => out.push(msg)
      None => go = false
    }
  }
}

///|
/// 分离主门:两个 conv 各发三条,服务端路由互不串线,各会话按序收全。
test "server demuxes two convs without cross-talk" {
  let server = KcpServer::new(128, 16)
  let ca = mk_server_client(101)
  let cb = mk_server_client(202)
  let mut tag = 1
  while tag <= 3 {
    let _ = ca.send(mk_payload(tag, 20))
    let _ = cb.send(mk_payload(tag + 10, 22))
    tag += 1
  }
  pump_server(server, [ca, cb], 0, 60)
  let sa = server.session_of(101) |> unwrap_session
  let sb = server.session_of(202) |> unwrap_session
  assert_eq(server.size(), 2)
  let mut tag = 1
  while tag <= 3 {
    assert_eq(sa.poll_message(), Some(mk_payload(tag, 20)))
    tag += 1
  }
  assert_eq(sa.poll_message(), None)
  let mut tag = 1
  while tag <= 3 {
    assert_eq(sb.poll_message(), Some(mk_payload(tag + 10, 22)))
    tag += 1
  }
  assert_eq(sb.poll_message(), None)
}

///|
/// 自动建会话:未知 conv 首包即建;洪泛护栏:超 max_sessions 弃包 -4。
test "auto-create with flood cap" {
  let server = KcpServer::new(128, 2)
  let c1 = mk_server_client(11)
  let c2 = mk_server_client(22)
  let c3 = mk_server_client(33)
  let _ = c1.send(mk_payload(1, 8))
  let _ = c2.send(mk_payload(2, 8))
  let _ = c3.send(mk_payload(3, 8))
  let f1 = c1.update(0)
  let f2 = c2.update(0)
  let f3 = c3.update(0)
  assert_eq(server.on_datagram(f1[0]), 0)
  assert_eq(server.on_datagram(f2[0]), 0)
  // 表满(2):第三家弃包 -4
  assert_eq(server.on_datagram(f3[0]), -4)
  assert_eq(server.size(), 2)
  // 收尸后可再进
  server.remove(11)
  assert_eq(server.size(), 1)
  assert_eq(server.on_datagram(f3[0]), 0)
  assert_eq(server.size(), 2)
}

///|
/// 碎片消息跨会话:conv B 发三条大消息(多片段),路由后按序合并完整。
test "server routes fragmented messages per conv" {
  let server = KcpServer::new(128, 16)
  let cb = mk_server_client(777)
  let _ = cb.set_mtu(100)
  let mut tag = 1
  while tag <= 3 {
    let _ = cb.send(mk_payload(tag, 250))
    tag += 1
  }
  pump_server(server, [cb], 0, 40)
  let sb = server.session_of(777) |> unwrap_session
  let inbox : Array[Bytes] = []
  drain_session(sb, inbox)
  assert_eq(inbox.length(), 3)
  let mut tag = 1
  while tag <= 3 {
    assert_eq(inbox[tag - 1], mk_payload(tag, 250))
    tag += 1
  }
}

///|
fn unwrap_session(opt : KcpSession?) -> KcpSession {
  match opt {
    Some(session) => session
    None => abort("session missing")
  }
}

///|
/// 闲置清扫:静默会话被逐,活跃会话留存;被逐后同 conv 再来报自动重建。
test "sweep evicts idle sessions keeps active" {
  let server = KcpServer::new(128, 8)
  let ca = mk_server_client(101)
  let cb = mk_server_client(202)
  // A 只在前 20 拍发声,B 发到 60 拍
  let mut tag = 1
  while tag <= 6 {
    let _ = ca.send(mk_payload(tag, 10))
    let _ = cb.send(mk_payload(tag, 10))
    let t = tag * 10
    let fa = ca.update(t)
    let fb = cb.update(t)
    let mut i = 0
    while i < fa.length() {
      let _ = server.on_datagram(fa[i])
      i += 1
    }
    if tag <= 6 {
      let mut j = 0
      while j < fb.length() {
        let _ = server.on_datagram(fb[j])
        j += 1
      }
    }
    let _ = server.tick(t)
    tag += 1
  }
  // B 续发声到 t=600
  let mut tag = 7
  while tag <= 60 {
    let _ = cb.send(mk_payload(tag, 10))
    let t = tag * 10
    let fb = cb.update(t)
    let mut i = 0
    while i < fb.length() {
      let _ = server.on_datagram(fb[i])
      i += 1
    }
    let _ = server.tick(t)
    tag += 1
  }
  // t=1000,A 静默 ~800ms 被逐;B 静默 ~400ms 留存
  let evicted = server.sweep(1000, 450)
  assert_eq(evicted, [101])
  assert_eq(server.size(), 1)
  // 被逐 conv 再来报:自动重建
  let fa = ca.update(1100)
  let mut i = 0
  while i < fa.length() {
    let _ = server.on_datagram(fa[i])
    i += 1
  }
  assert_eq(server.size(), 2)
  assert_true(server.session_of(101) is Some(_))
}
