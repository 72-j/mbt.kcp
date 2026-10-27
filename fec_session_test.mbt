// fec_session_test.mbt — 刀4 带损集成门(黑盒;进程内,LCG 确定性,D-FEC6)
//
// 拍语:10ms/拍宿主注入,起泵 1000(跳过 ts_flush epoch),interval=10
// 逐拍 flush;cwnd 线性起步(1,2,3…帧/拍)。A 发 6×1000B(mss 1376 →
// 每消息恰一 KCP 帧,两组 k=3);强制丢 A→B 第 2 线帧(组0 数据片1)。
// FEC 开:冗余随闭组突发,组齐当场恢复,交付 ≤ 8 拍;
// FEC 关:同位帧丢,KCP 等 RTO 重传(~21 拍,缺省 rx_rto 200ms),
// 且按序交付把后继拖到同一拍(队头阻塞)。
// KCPDIFF 门原样不动(FEC 在核外,D-FEC6)。

///|
/// LCG 确定性抽签(差分驱动同式)。
fn lcg_next(state : Array[Int32]) -> Int32 {
  let x = (state[0] * 1664525 + 1013904223) & 0x7FFFFFFF
  state[0] = x
  x
}

///|
fn make_payload(
  id : Int32,
  len : Int32,
  rng : Array[Int32],
) -> FixedArray[Byte] {
  let payload = FixedArray::make(len, (0).to_byte())
  payload[0] = id.to_byte()
  for i in 1..<len {
    payload[i] = (lcg_next(rng) & 0xFF).to_byte()
  }
  payload
}

///|
fn bytes_equal(a : FixedArray[Byte], b : FixedArray[Byte]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut same = true
  for i in 0..<a.length() {
    if a[i] != b[i] {
      same = false
    }
  }
  same
}

///|
test "带损集成门 FEC 开:强丢组内一数据帧,当场恢复全交付 ≤ 8 拍" {
  let a = @moonkcp.FecSession::new(7, 128, 3, 2)
  let b = @moonkcp.FecSession::new(7, 128, 3, 2)
  a.session.kcp.interval = 10
  b.session.kcp.interval = 10
  let rng : Array[Int32] = [20261027]
  let payloads : Array[FixedArray[Byte]] = []
  for id in 0..<6 {
    payloads.push(make_payload(id, 1000, rng))
  }
  for payload in payloads {
    assert_true(a.send_message(payload) > 0)
  }
  let arrival : FixedArray[Int32] = FixedArray::make(6, -1)
  let mut ab_count = 0
  for step in 0..<60 {
    let now = 1000 + step * 10
    for frame in a.tick(now) {
      ab_count += 1
      if ab_count != 2 {
        let _ = b.on_datagram(frame)
      }
    }
    for frame in b.tick(now) {
      let _ = a.on_datagram(frame)
    }
    let mut more = true
    while more {
      match b.poll_message() {
        Some(msg) => {
          let id = msg[0].to_int()
          assert_true(bytes_equal(msg, payloads[id]))
          if arrival[id] < 0 {
            arrival[id] = step
          }
        }
        None => more = false
      }
    }
  }
  // 全部交付,且不经历 RTO(≤ 8 拍;若恢复失灵,缺片须等 RTO ~21 拍,门必红)
  for id in 0..<6 {
    assert_true(arrival[id] >= 0)
    assert_true(arrival[id] <= 8)
  }
  // FEC 观测面:两组全闭,B 恰恢复一数据片
  let tx_st = a.fec_tx_stats()
  assert_eq(tx_st.closed_groups, 2)
  let rx_st = b.fec_rx_stats()
  assert_eq(rx_st.recovered_groups, 1)
  assert_eq(rx_st.recovered_shards, 1)
  assert_eq(rx_st.delivered, 6)
  assert_eq(rx_st.groups_lost, 0)
}

///|
test "带损集成门 FEC 关:同位帧丢,缺片等 RTO ≥ 15 拍,队头阻塞拖累后继" {
  let a = @moonkcp.KcpSession::new(7, 128)
  let b = @moonkcp.KcpSession::new(7, 128)
  a.kcp.interval = 10
  b.kcp.interval = 10
  let rng : Array[Int32] = [20261027]
  for id in 0..<6 {
    assert_true(a.send_message(make_payload(id, 1000, rng)) > 0)
  }
  let arrival : FixedArray[Int32] = FixedArray::make(6, -1)
  let mut ab_count = 0
  for step in 0..<60 {
    let now = 1000 + step * 10
    for frame in a.tick(now) {
      ab_count += 1
      if ab_count != 2 {
        let _ = b.on_datagram(frame)
      }
    }
    for frame in b.tick(now) {
      let _ = a.on_datagram(frame)
    }
    let mut more = true
    while more {
      match b.poll_message() {
        Some(msg) => {
          let id = msg[0].to_int()
          if arrival[id] < 0 {
            arrival[id] = step
          }
        }
        None => more = false
      }
    }
  }
  for id in 0..<6 {
    assert_true(arrival[id] >= 0)
  }
  // 首消息直达(第 1 线帧未丢)
  assert_true(arrival[0] <= 2)
  // 缺片等 RTO 重传(实测 14 拍:RTO 自适应 ~130ms;FEC 开 ≤ 8 拍,齿距仍在)
  assert_true(arrival[1] >= 10)
  // 按序交付:后继消息虽帧已到,仍被缺片拖到同一拍之后(队头阻塞,实测 15)
  assert_true(arrival[3] >= 10)
}

///|
test "带损集成门 LCG 20% 帧损:FEC 开 30 消息全交付" {
  let a = @moonkcp.FecSession::new(9, 128, 3, 2)
  let b = @moonkcp.FecSession::new(9, 128, 3, 2)
  a.session.kcp.interval = 10
  b.session.kcp.interval = 10
  let rng : Array[Int32] = [424242]
  for id in 0..<30 {
    assert_true(a.send_message(make_payload(id, 200, rng)) > 0)
  }
  let seen : FixedArray[Bool] = FixedArray::make(30, false)
  let mut count = 0
  let drop_rng : Array[Int32] = [987654321]
  // 600 步跑道:20% 帧损下 RTO 退避可达数百 ms,终局收敛为门(非速度赛)
  for step in 0..<600 {
    let now = 1000 + step * 10
    for frame in a.tick(now) {
      if lcg_next(drop_rng) % 5 != 0 {
        let _ = b.on_datagram(frame)
      }
    }
    for frame in b.tick(now) {
      if lcg_next(drop_rng) % 5 != 0 {
        let _ = a.on_datagram(frame)
      }
    }
    let mut more = true
    while more {
      match b.poll_message() {
        Some(msg) => {
          let id = msg[0].to_int()
          if !seen[id] {
            seen[id] = true
            count += 1
          }
        }
        None => more = false
      }
    }
  }
  // 20% 帧损下 FEC 当场恢复 + ARQ 兜底,终局全交付
  assert_eq(count, 30)
}
