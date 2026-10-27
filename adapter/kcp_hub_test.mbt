// kcp_hub_test.mbt — K7 门:真 UDP 多客户端 hub(路由不串线/回程/
// 洪泛护栏/闲置回收/逐后重建)——服务端组合宿主真传输验收

///|
/// hub 级锁步:各客户端一拍(帧数守恒,hub 收恰 N 报),hub 一拍出帧
/// 按分表定向回投。返回 hub 的逐会话帧数分表。
async fn drive_hub(
  hub : @adapter.KcpUdpHub,
  clients : Array[@adapter.KcpUdpPeer],
  start_ms : Int32,
  ticks : Int32,
) -> Array[(Int32, Int32)] {
  let mut t = start_ms
  let mut tick = 0
  let mut last_tagged : Array[(Int32, Int32)] = []
  while tick < ticks {
    let mut total = 0
    for client in clients {
      total += client.pump_out(t)
    }
    let mut k = 0
    while k < total {
      let _ = hub.recv_one()
      k += 1
    }
    last_tagged = hub.pump_out(t)
    for entry in last_tagged {
      let (conv, n) = entry
      let mut j = 0
      while j < clients.length() {
        if clients[j].session.kcp.conv == conv {
          let mut r = 0
          while r < n {
            let _ = clients[j].recv_one()
            r += 1
          }
        }
        j += 1
      }
    }
    t += 10
    tick += 1
  }
  last_tagged
}

///|
async test "K7: hub serves two clients over real UDP without cross-talk" {
  let hub = @adapter.KcpUdpHub::listen(128, 4)
  let ca = @adapter.KcpUdpPeer::connect_client(101, 128, hub.local_addr())
  let cb = @adapter.KcpUdpPeer::connect_client(202, 128, hub.local_addr())
  ca.session.kcp.set_nodelay(1, 10, 2, 1)
  cb.session.kcp.set_nodelay(1, 10, 2, 1)
  let mut tag = 1
  while tag <= 5 {
    assert_eq(ca.send_message(mk_payload(tag, 20)), 20)
    assert_eq(cb.send_message(mk_payload(tag + 10, 24)), 24)
    tag += 1
  }
  let _ = drive_hub(hub, [ca, cb], 0, 60)
  // 各会话按序收全,不串线
  assert_eq(hub.convs().length(), 2)
  let mut tag = 1
  while tag <= 5 {
    assert_msg(hub.poll_message(101), mk_payload(tag, 20))
    assert_msg(hub.poll_message(202), mk_payload(tag + 10, 24))
    tag += 1
  }
  assert_eq(hub.poll_message(101), None)
  // 回程:hub 对 101 发三条,ca 按序收全
  let mut tag = 1
  while tag <= 3 {
    assert_eq(hub.send_message_to(101, mk_payload(tag + 50, 14)), 14)
    tag += 1
  }
  let _ = drive_hub(hub, [ca, cb], 600, 60)
  let mut tag = 1
  while tag <= 3 {
    assert_msg(ca.poll_message(), mk_payload(tag + 50, 14))
    tag += 1
  }
  assert_eq(ca.poll_message(), None)
}

///|
async test "K7: flood cap rejects third conv, sweep frees slot" {
  let hub = @adapter.KcpUdpHub::listen(128, 2)
  let ca = @adapter.KcpUdpPeer::connect_client(101, 128, hub.local_addr())
  let cb = @adapter.KcpUdpPeer::connect_client(202, 128, hub.local_addr())
  let c3 = @adapter.KcpUdpPeer::connect_client(303, 128, hub.local_addr())
  ca.session.kcp.set_nodelay(1, 10, 2, 1)
  cb.session.kcp.set_nodelay(1, 10, 2, 1)
  c3.session.kcp.set_nodelay(1, 10, 2, 1)
  let _ = ca.send_message(mk_payload(1, 10))
  let _ = cb.send_message(mk_payload(2, 10))
  let _ = c3.send_message(mk_payload(3, 10))
  // 前两家入表,第三家洪泛护栏 -4
  let fa = ca.pump_out(0)
  let fb = cb.pump_out(0)
  let f3 = c3.pump_out(0)
  let mut k = 0
  while k < fa {
    let _ = hub.recv_one()
    k += 1
  }
  let mut k = 0
  while k < fb {
    let _ = hub.recv_one()
    k += 1
  }
  let mut last_code = 0
  let mut k = 0
  while k < f3 {
    last_code = hub.recv_one()
    k += 1
  }
  assert_eq(last_code, -4)
  assert_eq(hub.convs().length(), 2)
  // A 续发到 t=600(B 自 t=0 后静默):泄洪后 B 静默 ~600ms,A ~400ms
  let mut t = 10
  while t <= 600 {
    let _ = ca.send_message(mk_payload(10, 10))
    let fa = ca.pump_out(t)
    let mut k = 0
    while k < fa {
      let _ = hub.recv_one()
      k += 1
    }
    let tagged = hub.pump_out(t)
    for entry in tagged {
      let (conv, n) = entry
      // 按 conv 路由回投——202 的 ACK 在 cb 的 socket 上,错拿 ca 收即永阻
      let peer = if conv == 101 { ca } else { cb }
      let mut r = 0
      while r < n {
        let _ = peer.recv_one()
        r += 1
      }
    }
    t += 10
  }
  // 闲置清扫(t=1000):B(静默 1000ms)被逐;A(静默 400ms ≤ 450)留存
  let evicted = hub.sweep(1000, 450)
  assert_eq(evicted, [202])
  assert_eq(hub.convs().length(), 1)
  // 槽位释放后,303 重发即入(自动重建)
  let f3 = c3.pump_out(1100)
  let mut k = 0
  let mut code = 0
  while k < f3 {
    code = hub.recv_one()
    k += 1
  }
  assert_eq(code, 0)
  assert_eq(hub.convs().length(), 2)
  // 303 会话在册实证:能发消息(无会话时 send_message_to 返 -1)
  assert_true(hub.send_message_to(303, mk_payload(99, 8)) >= 0)
}
