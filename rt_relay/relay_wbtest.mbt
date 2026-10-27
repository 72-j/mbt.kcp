// relay_wbtest.mbt — M1b 门:入房/扇出排除发送者/presence/清扫/畸形帧弃

///|
test "subscribe joins room and broadcasts presence to all" {
  let relay = RtRelay::new(8)
  let out1 = relay.on_frame(
    1, 0, "{\"kind\":\"subscribe\",\"topic\":\"doc1\",\"user\":\"alice\"}",
  )
  // 馌一个入房者:presence 只回自己
  assert_eq(out1.length(), 1)
  assert_true(out1[0].0 == 1)
  let out2 = relay.on_frame(
    2, 10, "{\"kind\":\"subscribe\",\"topic\":\"doc1\",\"user\":\"bob\"}",
  )
  // 第二个入房:双方各收 presence,名单含二人
  assert_eq(out2.length(), 2)
  assert_true(
    (out2[0].0 == 1 && out2[1].0 == 2) || (out2[0].0 == 2 && out2[1].0 == 1),
  )
  assert_true(out2[0].1.contains("alice") && out2[0].1.contains("bob"))
}

///|
test "cursor and op fanout exclude sender and carry payload" {
  let relay = RtRelay::new(8)
  let _ = relay.on_frame(
    1, 0, "{\"kind\":\"subscribe\",\"topic\":\"doc1\",\"user\":\"alice\"}",
  )
  let _ = relay.on_frame(
    2, 10, "{\"kind\":\"subscribe\",\"topic\":\"doc1\",\"user\":\"bob\"}",
  )
  let out = relay.on_frame(
    1, 20, "{\"kind\":\"cursor\",\"topic\":\"doc1\",\"doc\":\"d1\",\"pos\":\"42\"}",
  )
  // 只投 bob(排除发送者 alice);携带发送者 user
  assert_eq(out.length(), 1)
  assert_eq(out[0].0, 2)
  assert_true(out[0].1.contains("\"user\":\"alice\""))
  assert_true(out[0].1.contains("\"doc\":\"d1\""))
  let out_op = relay.on_frame(
    1, 30, "{\"kind\":\"op\",\"topic\":\"doc1\",\"payload\":{\"hlc\":\"x1\",\"data\":\"hi\"}}",
  )
  assert_eq(out_op.length(), 1)
  assert_eq(out_op[0].0, 2)
  // op 载荷转写语义等价(键序不保证):关键键在即可
  assert_true(out_op[0].1.contains("\"hlc\":\"x1\""))
  assert_true(out_op[0].1.contains("\"kind\":\"op\""))
}

///|
test "heartbeat refreshes and sweep evicts silent with presence" {
  let relay = RtRelay::new(8)
  let _ = relay.on_frame(
    1, 0, "{\"kind\":\"subscribe\",\"topic\":\"t\",\"user\":\"alice\"}",
  )
  let _ = relay.on_frame(
    2, 0, "{\"kind\":\"heartbeat\",\"topic\":\"t\",\"user\":\"bob\"}",
  )
  // t=500,ttl=300:A(500 刚刷)留,B(0 起,500-0=500>300)逐
  let _ = relay.on_frame(
    1, 500, "{\"kind\":\"heartbeat\",\"topic\":\"t\",\"user\":\"alice\"}",
  )
  let evicted = relay.sweep(500, 300)
  assert_eq(evicted, [("t", 2)])
  // 被逐者再发 cursor:不在房,静默弃
  let out = relay.on_frame(
    2, 600, "{\"kind\":\"cursor\",\"topic\":\"t\",\"doc\":\"d\",\"pos\":\"1\"}",
  )
  assert_eq(out.length(), 0)
}

///|
test "malformed and unknown frames dropped silently" {
  let relay = RtRelay::new(8)
  assert_eq(relay.on_frame(1, 0, "not json").length(), 0)
  assert_eq(relay.on_frame(1, 0, "{\"kind\":\"mystery\"}").length(), 0)
  assert_eq(relay.on_frame(1, 0, "{\"kind\":\"cursor\"}").length(), 0)
  assert_eq(relay.on_frame(1, 0, "[]").length(), 0)
}

///|
test "capacity guard rejects overflow member" {
  let relay = RtRelay::new(2)
  let _ = relay.on_frame(
    1, 0, "{\"kind\":\"subscribe\",\"topic\":\"t\",\"user\":\"a\"}",
  )
  let _ = relay.on_frame(
    2, 0, "{\"kind\":\"subscribe\",\"topic\":\"t\",\"user\":\"b\"}",
  )
  let out = relay.on_frame(
    3, 0, "{\"kind\":\"subscribe\",\"topic\":\"t\",\"user\":\"c\"}",
  )
  // 满员:第三家不进房(无 presence 增员广播给 3)
  assert_eq(relay.size("t"), 2)
  let _ = out
}
