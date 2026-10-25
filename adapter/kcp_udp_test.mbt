// kcp_udp_test.mbt — K4 门:真 UDP 回环双实例(内核协议栈真传输,
// 协议时序仍注入快钟——确定性不破)

///|
fn mk_payload(tag : Int, len : Int) -> Bytes {
  Bytes::makei(len, fn(i) { ((tag + i) % 128).to_byte() })
}

///|
/// 锁步驱动:双方各 pump 一拍;帧数守恒(kernel 回环不丢),各收恰
/// 对端发出的帧数——recv 只在有数据保票时调,零死锁。
async fn drive(
  a : @adapter.KcpUdpPeer,
  b : @adapter.KcpUdpPeer,
  start_ms : Int32,
  rounds : Int32,
) -> Unit {
  let mut t = start_ms
  for _ in 0..<rounds {
    let fa = a.pump_out(t)
    let fb = b.pump_out(t)
    if fa + fb > 0 {
      let mut k = 0
      while k < fb {
        let _ = a.recv_one()
        k += 1
      }
      let mut k = 0
      while k < fa {
        let _ = b.recv_one()
        k += 1
      }
    }
    t += 10
  }
}

///|
async test "K4: loopback A to B twenty messages in order" {
  let b = @adapter.KcpUdpPeer::listen_server(77, 128)
  let a = @adapter.KcpUdpPeer::connect_client(77, 128, b.local_addr())
  a.session.kcp.set_nodelay(1, 10, 2, 1)
  b.session.kcp.set_nodelay(1, 10, 2, 1)
  let mut tag = 1
  while tag <= 20 {
    assert_eq(a.send_message(mk_payload(tag, 24)), 24)
    tag += 1
  }
  drive(a, b, 0, 300)
  let mut tag = 1
  while tag <= 20 {
    assert_eq(b.poll_message(), Some(mk_payload(tag, 24)))
    tag += 1
  }
  assert_eq(b.poll_message(), None)
}

///|
async test "K4: fragmented message over real datagrams" {
  let b = @adapter.KcpUdpPeer::listen_server(78, 128)
  let a = @adapter.KcpUdpPeer::connect_client(78, 128, b.local_addr())
  a.session.kcp.set_nodelay(1, 10, 2, 1)
  b.session.kcp.set_nodelay(1, 10, 2, 1)
  let _ = a.session.kcp.set_mtu(100)
  let payload = mk_payload(9, 250)
  assert_eq(a.send_message(payload), 250)
  drive(a, b, 0, 200)
  assert_eq(b.poll_message(), Some(payload))
  assert_eq(b.poll_message(), None)
}

///|
async test "K4: return path B to A via server sendto" {
  let b = @adapter.KcpUdpPeer::listen_server(79, 128)
  let a = @adapter.KcpUdpPeer::connect_client(79, 128, b.local_addr())
  a.session.kcp.set_nodelay(1, 10, 2, 1)
  b.session.kcp.set_nodelay(1, 10, 2, 1)
  // 先走一轮 A→B:B 学得 A 地址
  assert_eq(a.send_message(mk_payload(1, 8)), 8)
  drive(a, b, 0, 60)
  assert_eq(b.poll_message(), Some(mk_payload(1, 8)))
  // 回程:B(server sendto)→ A
  let mut tag = 2
  while tag <= 6 {
    assert_eq(b.send_message(mk_payload(tag, 12)), 12)
    tag += 1
  }
  drive(a, b, 600, 300)
  let mut tag = 2
  while tag <= 6 {
    assert_eq(a.poll_message(), Some(mk_payload(tag, 12)))
    tag += 1
  }
  assert_eq(a.poll_message(), None)
}
