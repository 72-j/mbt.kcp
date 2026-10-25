// session_wbtest.mbt — K3 门:会话壳 API 往返 + 背压 + 队列 FIFO

///|
fn mk_session(conv : Int32, high_water : Int32) -> KcpSession {
  let session = KcpSession::new(conv, high_water)
  session.kcp.set_nodelay(1, 10, 2, 1)
  session
}

///|
/// 会话级无损泵:帧走 session.tick 出,对端 on_datagram 进。
/// start_ms 起泵——ts_flush 跨泵续时,别从 0 重启(重启 = 泵进历史,零 flush)。
fn pump_sessions(
  a : KcpSession,
  b : KcpSession,
  start_ms : Int32,
  ticks : Int32,
) -> Unit {
  let mut t = start_ms
  let mut tick = 0
  while tick < ticks {
    let fa = a.tick(t)
    let mut i = 0
    while i < fa.length() {
      let _ = b.on_datagram(fa[i])
      i += 1
    }
    let fb = b.tick(t)
    let mut i = 0
    while i < fb.length() {
      let _ = a.on_datagram(fb[i])
      i += 1
    }
    t += 10
    tick += 1
  }
}

///|
test "session roundtrip fragmented message" {
  let a = mk_session(31, 128)
  let b = mk_session(31, 128)
  let _ = a.kcp.set_mtu(100)
  let payload = mk_payload(9, 250)
  assert_eq(a.send_message(payload), 250)
  pump_sessions(a, b, 0, 20)
  assert_msg(b.poll_message(), payload)
  assert_eq(b.poll_message(), None)
}

///|
/// 窗口满背压:high_water=3,管道满第四条拒;ACK 回来管道疏浚后可再发。
test "backpressure rejects when pipe full" {
  let a = mk_session(33, 3)
  let b = mk_session(33, 128)
  assert_eq(a.send_message(mk_payload(1, 10)), 10)
  assert_eq(a.send_message(mk_payload(2, 10)), 10)
  assert_eq(a.send_message(mk_payload(3, 10)), 10)
  assert_eq(a.send_message(mk_payload(4, 10)), -2)
  assert_eq(a.kcp.waitsnd(), 3)
  // 泵到对端收齐并 ACK 回流,waitsnd 归零,背压解除
  pump_sessions(a, b, 0, 30)
  assert_eq(a.kcp.waitsnd(), 0)
  assert_eq(a.send_message(mk_payload(4, 10)), 10)
  pump_sessions(a, b, 300, 20)
  let inbox : Array[FixedArray[Byte]] = []
  let mut go = true
  while go {
    match b.poll_message() {
      Some(msg) => inbox.push(msg)
      None => go = false
    }
  }
  assert_eq(inbox.length(), 4)
}

///|
/// poll_message FIFO:多条消息按发送序出队。
test "poll_message fifo order" {
  let a = mk_session(35, 128)
  let b = mk_session(35, 128)
  let mut tag = 1
  while tag <= 8 {
    assert_eq(a.send_message(mk_payload(tag, 6)), 6)
    tag += 1
  }
  pump_sessions(a, b, 0, 30)
  let mut tag = 1
  while tag <= 8 {
    assert_msg(b.poll_message(), mk_payload(tag, 6))
    tag += 1
  }
  assert_eq(b.poll_message(), None)
}

///|
/// 有损收敛(会话级复测):乱序 + 丢 + 重复,20 条全量按序。
test "session lossy convergence" {
  let a = mk_session(37, 128)
  let b = mk_session(37, 128)
  let mut tag = 1
  while tag <= 20 {
    assert_eq(a.send_message(mk_payload(tag, 24)), 24)
    tag += 1
  }
  let mut t = 0
  let mut tick = 0
  while tick < 300 {
    let fa = a.tick(t)
    let mut i = 0
    while i < fa.length() {
      let frame = fa[i]
      let drop_key = (frame.length() * 13 + i * 7 + tick * 31) % 5
      if drop_key != 0 {
        let _ = b.on_datagram(frame)
      }
      i += 1
    }
    let fb = b.tick(t)
    let mut i = 0
    while i < fb.length() {
      let frame = fb[i]
      let drop_key = (frame.length() * 11 + i * 5 + tick * 17) % 5
      if drop_key != 0 {
        let _ = a.on_datagram(frame)
      }
      i += 1
    }
    t += 10
    tick += 1
  }
  let mut tag = 1
  while tag <= 20 {
    assert_msg(b.poll_message(), mk_payload(tag, 24))
    tag += 1
  }
  assert_eq(b.poll_message(), None)
}

///|
/// 判死透传:对端回程黑洞 + dead_link 触发,is_dead 报真。
test "session reports link death" {
  let a = mk_session(39, 128)
  a.kcp.dead_link = 3
  assert_eq(a.send_message(mk_payload(1, 8)), 8)
  assert_false(a.is_dead())
  let mut t = 0
  let mut tick = 0
  while tick < 100 && !a.is_dead() {
    let _ = a.tick(t)
    t += 10
    tick += 1
  }
  assert_true(a.is_dead())
}
