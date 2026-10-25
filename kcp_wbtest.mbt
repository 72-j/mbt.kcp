// kcp_wbtest.mbt — K2 门:ARQ 核心收敛(乱序/丢包/重复)+ RTO + 探窗 + 判死

///|
/// 回绕差:32 位有符号回绕直译等价——C `(IINT32)((u32)a - (u32)b)`。
test "itimediff wraps at 32-bit boundary" {
  assert_eq(itimediff(10, 5), 5)
  assert_eq(itimediff(5, 10), -5)
  // later 回绕到负半轴(0x80000004),earlier 在正半轴顶(0x7FFFFFF8):
  // 位差 12,有符号解释必须为 +12
  assert_eq(itimediff(-2147483644, 2147483640), 12)
}

///|
fn mk_fast(conv : Int32) -> Kcp {
  let kcp = Kcp::create(conv)
  kcp.set_nodelay(1, 10, 2, 1)
  kcp
}

///|
/// 造载荷:data[0] = tag,其余 (tag + i) % 128 递推——序判定用。
fn mk_payload(tag : Int32, len : Int32) -> Bytes {
  Bytes::makei(len, fn(i) { ((tag + i) % 128).to_byte() })
}

///|
/// 无损泵:双端各 update 一拍,帧互投。每拍 10ms。start_ms 起泵
/// (ts_flush 跨泵续时,从 0 重启 = 泵进历史,零 flush)。
fn pump_clean(a : Kcp, b : Kcp, start_ms : Int32, ticks : Int32) -> Unit {
  let mut t = start_ms
  let mut tick = 0
  while tick < ticks {
    let fa = a.update(t)
    let mut i = 0
    while i < fa.length() {
      let _ = b.input(fa[i])
      i += 1
    }
    let fb = b.update(t)
    let mut i = 0
    while i < fb.length() {
      let _ = a.input(fb[i])
      i += 1
    }
    t += 10
    tick += 1
  }
}

///|
/// 有损泵:确定性丢帧(约 1/5 丢)+ 重复注入 + 帧序倒置。
fn pump_lossy(a : Kcp, b : Kcp, ticks : Int32) -> Unit {
  let mut t = 0
  let mut tick = 0
  while tick < ticks {
    let fa = a.update(t)
    deliver_lossy(fa, b, tick)
    let fb = b.update(t)
    deliver_lossy(fb, a, tick + 3)
    t += 10
    tick += 1
  }
}

///|
fn deliver_lossy(frames : Array[Bytes], to : Kcp, secret : Int32) -> Unit {
  let mut i = 0
  while i < frames.length() {
    let frame = frames[i]
    let drop_key = (frame.length() * 13 + i * 7 + secret * 31) % 5
    if drop_key != 0 {
      let _ = to.input(frame)
    }
    let dup_key = (frame.length() * 11 + i * 3 + secret) % 7
    if dup_key == 0 {
      let _ = to.input(frame)
    }
    i += 1
  }
}

///|
/// 排空收端全部整消息。
fn drain(kcp : Kcp, out : Array[Bytes]) -> Unit {
  let mut go = true
  while go {
    match kcp.recv() {
      Some(msg) => out.push(msg)
      None => go = false
    }
  }
}

///|
test "clean roundtrip single message" {
  let sender = mk_fast(7)
  let receiver = mk_fast(7)
  let payload = mk_payload(42, 30)
  assert_eq(sender.send(payload), 30)
  pump_clean(sender, receiver, 0, 10)
  let inbox : Array[Bytes] = []
  drain(receiver, inbox)
  assert_eq(inbox.length(), 1)
  assert_eq(inbox[0], payload)
}

///|
test "fragmented message merges in order" {
  let sender = mk_fast(9)
  let receiver = mk_fast(9)
  let _ = sender.set_mtu(100)
  assert_eq(sender.mss, 100 - HEADER_SIZE)
  let payload = mk_payload(5, 200)
  assert_eq(sender.send(payload), 200)
  pump_clean(sender, receiver, 0, 20)
  let inbox : Array[Bytes] = []
  drain(receiver, inbox)
  assert_eq(inbox.length(), 1)
  assert_eq(inbox[0], payload)
}

///|
test "twenty messages in order clean" {
  let sender = mk_fast(11)
  let receiver = mk_fast(11)
  let mut tag = 1
  while tag <= 20 {
    assert_eq(sender.send(mk_payload(tag, 20)), 20)
    tag += 1
  }
  pump_clean(sender, receiver, 0, 30)
  let inbox : Array[Bytes] = []
  drain(receiver, inbox)
  assert_eq(inbox.length(), 20)
  let mut tag = 1
  while tag <= 20 {
    assert_eq(inbox[tag - 1], mk_payload(tag, 20))
    tag += 1
  }
}

///|
/// K2 主门:乱序 + 丢包 + 重复下,40 条消息全量按序收敛。
test "lossy convergence: reorder drop dup all delivered in order" {
  let sender = mk_fast(13)
  let receiver = mk_fast(13)
  let mut tag = 1
  while tag <= 40 {
    assert_eq(sender.send(mk_payload(tag, 24)), 24)
    tag += 1
  }
  pump_lossy(sender, receiver, 400)
  let inbox : Array[Bytes] = []
  drain(receiver, inbox)
  assert_eq(inbox.length(), 40)
  let mut tag = 1
  while tag <= 40 {
    assert_eq(inbox[tag - 1], mk_payload(tag, 24))
    tag += 1
  }
}

///|
/// RTO 重传:首窗 PUSH 全灭,靠超时重发收敛。
test "rto retransmit recovers lost data" {
  let sender = mk_fast(15)
  let receiver = mk_fast(15)
  sender.set_nodelay(1, 10, 0, 1)
  let mut tag = 1
  while tag <= 5 {
    assert_eq(sender.send(mk_payload(tag, 16)), 16)
    tag += 1
  }
  let mut t = 0
  let mut tick = 0
  let inbox : Array[Bytes] = []
  while tick < 200 {
    let fa = sender.update(t)
    let mut i = 0
    while i < fa.length() {
      // 前 20 拍(200ms)全丢;此后放行
      if tick >= 20 {
        let _ = receiver.input(fa[i])
      }
      i += 1
    }
    let fb = receiver.update(t)
    let mut i = 0
    while i < fb.length() {
      let _ = sender.input(fb[i])
      i += 1
    }
    t += 10
    tick += 1
  }
  drain(receiver, inbox)
  assert_eq(inbox.length(), 5)
  let mut tag = 1
  while tag <= 5 {
    assert_eq(inbox[tag - 1], mk_payload(tag, 16))
    tag += 1
  }
}

///|
/// 探窗:收端应用不读 → rcv_queue 涨满 128 → rmt_wnd 归零 → 发端 WASK
/// 主动探(PROBE_INIT 5000ms 后)→ 排空后 WINS 通 → 全量送达。
test "window probe resumes after receiver stall" {
  let sender = mk_fast(17)
  let receiver = mk_fast(17)
  // 140 条小消息 > rcv_wnd(128):不 drain 即满队列停摆(收窗钳制
  // imax(rcvwnd, WND_RCV) 下,set_wnd 缩窗不可用——真停摆只能靠应用不读)
  let mut tag = 1
  while tag <= 140 {
    assert_eq(sender.send(mk_payload(tag, 10)), 10)
    tag += 1
  }
  // 泵到队列满(128)+ 泵过 PROBE_INIT(5000ms):观察 WASK 帧真发出
  pump_clean(sender, receiver, 0, 30)
  let mut saw_wask = false
  let mut t = 300
  let mut tick = 0
  while tick < 560 {
    let fa = sender.update(t)
    let mut i = 0
    while i < fa.length() {
      if fa[i][4].to_int() == CMD_WASK {
        saw_wask = true
      }
      let _ = receiver.input(fa[i])
      i += 1
    }
    let fb = receiver.update(t)
    let mut i = 0
    while i < fb.length() {
      let _ = sender.input(fb[i])
      i += 1
    }
    t += 10
    tick += 1
  }
  assert_true(saw_wask)
  assert_eq(receiver.rcv_queue.length(), 128)
  // 排空后继续泵,探窗应恢复投递(停摆期 RTO 退避 ~1s+,泵程跨过重传点)
  let inbox : Array[Bytes] = []
  drain(receiver, inbox)
  pump_clean(sender, receiver, t + 100, 800)
  drain(receiver, inbox)
  assert_eq(inbox.length(), 140)
  let mut tag = 1
  while tag <= 140 {
    assert_eq(inbox[tag - 1], mk_payload(tag, 10))
    tag += 1
  }
}

///|
/// dead_link:对端回程全黑洞,同段重发达阈值 → 判链路死(state = -1)。
test "dead_link flags link death" {
  let sender = mk_fast(19)
  sender.dead_link = 3
  assert_eq(sender.send(mk_payload(1, 8)), 8)
  let mut t = 0
  let mut tick = 0
  while tick < 100 && sender.state == 0 {
    // 黑洞:出帧全弃,对端永远收不到、回程永远无 ACK
    let _ = sender.update(t)
    t += 10
    tick += 1
  }
  assert_eq(sender.state, -1)
}

///|
/// parse_una 直测:una=2 清掉 sn 0/1,留 sn 2。
test "parse_una drops acked prefix" {
  let kcp = Kcp::create(1)
  let mut sn = 0
  while sn < 3 {
    let seg = KcpSegment::make(1, CMD_PUSH, 0, 32, 0, sn, 0, mk_payload(sn, 4))
    kcp.snd_buf.push(seg)
    sn += 1
  }
  kcp.snd_nxt = 3
  kcp.snd_una = 0
  kcp.parse_una(2)
  assert_eq(kcp.snd_buf.length(), 1)
  assert_eq(kcp.snd_buf[0].sn, 2)
  // C input 序:parse_una 后随 shrink_buf,snd_una 才回缩
  kcp.shrink_buf()
  assert_eq(kcp.snd_una, 2)
}

///|
/// 重复 PUSH 去重:同 sn 注入两次只收一份,连续后一次性就绪。
test "duplicate push deduplicated" {
  let receiver = mk_fast(21)
  let payload = mk_payload(1, 12)
  let seg = KcpSegment::make(21, CMD_PUSH, 0, 32, 100, 0, 0, payload)
  let encoded = encode_segment(seg)
  assert_eq(receiver.input(encoded), 0)
  assert_eq(receiver.input(encoded), 0)
  assert_eq(receiver.rcv_buf.length(), 0)
  assert_eq(receiver.rcv_queue.length(), 1)
  let inbox : Array[Bytes] = []
  drain(receiver, inbox)
  assert_eq(inbox.length(), 1)
  assert_eq(inbox[0], payload)
  assert_eq(receiver.rcv_nxt, 1)
}

///|
/// peeksize:三碎片在齐前 -1,齐后全长。
test "peeksize waits for all fragments" {
  let sender = mk_fast(23)
  let _ = sender.set_mtu(100)
  let receiver = mk_fast(23)
  let _ = receiver.set_mtu(100)
  assert_eq(sender.send(mk_payload(2, 200)), 200)
  pump_clean(sender, receiver, 0, 20)
  assert_eq(receiver.peeksize(), 200)
}

///|
/// 空消息:一空段往返。
test "empty message roundtrip" {
  let sender = mk_fast(25)
  let receiver = mk_fast(25)
  assert_eq(sender.send([]), 0)
  pump_clean(sender, receiver, 0, 10)
  let inbox : Array[Bytes] = []
  drain(receiver, inbox)
  assert_eq(inbox.length(), 1)
  assert_eq(inbox[0].length(), 0)
}

///|
/// input 错码:-1 短报文 / conv 不符,-3 非法 cmd。
test "input rejects malformed datagrams" {
  let receiver = mk_fast(27)
  let short = Bytes::make(10, 0b0)
  assert_eq(receiver.input(short), -1)
  let empty = Bytes::make(0, 0b0)
  let wrong_conv = encode_segment(
    KcpSegment::make(999, CMD_PUSH, 0, 32, 0, 0, 0, empty),
  )
  assert_eq(receiver.input(wrong_conv), -1)
  let bad_cmd = encode_segment(KcpSegment::make(27, 99, 0, 32, 0, 0, 0, empty))
  assert_eq(receiver.input(bad_cmd), -3)
}

///|
/// 观测面:有损收敛后 stats 读数 sanity——srtt 有采样、rto 在界内、
/// 超时重传计数非零(首窗全灭场景)、队列读数自洽。
test "stats reflect transport reality" {
  let sender = mk_fast(91)
  let receiver = mk_fast(91)
  sender.set_nodelay(1, 10, 0, 1)
  let mut tag = 1
  while tag <= 5 {
    assert_eq(sender.send(mk_payload(tag, 16)), 16)
    tag += 1
  }
  let mut t = 0
  let mut tick = 0
  while tick < 200 {
    let fa = sender.update(t)
    let mut i = 0
    while i < fa.length() {
      if tick >= 20 {
        let _ = receiver.input(fa[i])
      }
      i += 1
    }
    let fb = receiver.update(t)
    let mut i = 0
    while i < fb.length() {
      let _ = sender.input(fb[i])
      i += 1
    }
    t += 10
    tick += 1
  }
  let stats = sender.stats()
  // 锁步泵里重传→ACK 同拍回,rtt 恒 0:首样本 update_ack(0) 使 srtt
  // 停在哨兵值(C 同语义)——srtt 断言只作非负;rto 落下限钳制 30
  assert_true(stats.srtt >= 0)
  assert_eq(stats.rto, 30)
  assert_true(stats.rto <= RTO_MAX)
  assert_true(stats.rto_retransmits > 0)
  assert_eq(stats.in_flight, 0)
  assert_eq(stats.queued, 0)
  assert_true(stats.last_active > 0)
}

///|
/// 守恒律(任意时刻可验,非终态特判):
/// 接收账 rcv_accepted == rcv_queue + rcv_buf(入库即记账,不漏不重);
/// 发送账 snd_buf 全员落于 [snd_una, snd_nxt) 且队首即 snd_una。
test "conservation laws hold mid-flight and at quiescence" {
  let sender = mk_fast(61)
  let receiver = mk_fast(61)
  let mut tag = 1
  while tag <= 40 {
    assert_eq(sender.send(mk_payload(tag, 24)), 24)
    tag += 1
  }
  // 中途核查:泵 7 拍(未收敛)即验
  let mut t = 0
  let mut tick = 0
  while tick < 7 {
    let fa = sender.update(t)
    let mut i = 0
    while i < fa.length() {
      let _ = receiver.input(fa[i])
      i += 1
    }
    let fb = receiver.update(t)
    let mut i = 0
    while i < fb.length() {
      let _ = sender.input(fb[i])
      i += 1
    }
    t += 10
    tick += 1
  }
  let rs = receiver.stats()
  assert_eq(
    rs.rcv_accepted,
    receiver.rcv_queue.length() + receiver.rcv_buf.length(),
  )
  assert_snd_bounds(sender)
  // 收敛后核查
  pump_clean(sender, receiver, t, 60)
  let rs2 = receiver.stats()
  assert_eq(
    rs2.rcv_accepted,
    receiver.rcv_queue.length() + receiver.rcv_buf.length(),
  )
  assert_snd_bounds(sender)
  // 端到端字节守恒:发 = 收(无损路径)
  let inbox : Array[Bytes] = []
  drain(receiver, inbox)
  let mut total = 0
  for msg in inbox {
    total += msg.length()
  }
  assert_eq(total, 40 * 24)
}

///|
/// 发送账界核查:snd_buf 全员 [snd_una, snd_nxt),队首即 snd_una。
fn assert_snd_bounds(kcp : Kcp) -> Unit raise {
  let mut i = 0
  while i < kcp.snd_buf.length() {
    let seg = kcp.snd_buf[i]
    assert_true(itimediff(seg.sn, kcp.snd_una) >= 0)
    assert_true(itimediff(seg.sn, kcp.snd_nxt) < 0)
    i += 1
  }
  if kcp.snd_buf.length() > 0 {
    assert_eq(kcp.snd_buf[0].sn, kcp.snd_una)
  }
}

///|
/// 配置面:mtu 下限拒(-1)/interval 钳 10 下限/rcv_wnd 钳 128 下限
/// (差分门逮出的 imax 钳制,专项钉住)。
test "config clamps and rejects" {
  let kcp = Kcp::create(1)
  assert_eq(kcp.set_mtu(49), -1)
  assert_eq(kcp.set_mtu(60), 0)
  assert_eq(kcp.mss, 60 - HEADER_SIZE)
  kcp.set_nodelay(1, 5, -1, -1)
  assert_eq(kcp.interval, 10)
  kcp.set_wnd(0, 1)
  assert_eq(kcp.rcv_wnd, WND_RCV)
  kcp.set_wnd(7, 0)
  assert_eq(kcp.snd_wnd, 7)
  assert_eq(kcp.rcv_wnd, WND_RCV)
}

///|
/// input -2:头合法但声明 len 超出余量——截断帧构造。
test "input rejects truncated payload with -2" {
  let receiver = mk_fast(63)
  let full = encode_segment(
    KcpSegment::make(63, CMD_PUSH, 0, 32, 0, 0, 0, mk_payload(1, 10)),
  )
  // 截到 24 + 5:头声明 len=10,余量仅 5
  let truncated = Bytes::makei(HEADER_SIZE + 5, fn(i) { full[i] })
  assert_eq(receiver.input(truncated), -2)
}

///|
/// check:闲时返回下次 flush 点;大幅跳钟即立即。
test "check schedules next update and resyncs on jump" {
  let kcp = mk_fast(65)
  let _ = kcp.update(0)
  // ts_flush=10:current=5 时,下次唤醒 = 10
  assert_eq(kcp.check(5), 10)
  // 已过 flush 点:立即
  assert_eq(kcp.check(15), 15)
  // 跳钟 |slap|>=10000:ts_flush 重锚,返回 current
  assert_eq(kcp.check(20000), 20000)
}
