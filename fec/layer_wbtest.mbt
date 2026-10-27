// layer_wbtest.mbt — 刀3 门:线格式往返负例 + 突发语义 + 端到端带损恢复
// + 弃置面(重复/坏帧/逐出)+ 端口注入(白盒,同包)

///|
test "FEC 头编解码往返 + 负例族" {
  let frame = FixedArray::make(40, (0).to_byte())
  fec_write_header(frame, 0x12345678, 4, 3, 2, 17)
  match fec_read_header(frame) {
    Some(h) => {
      assert_eq(h.group_id, 0x12345678)
      assert_eq(h.shard_index, 4)
      assert_eq(h.k, 3)
      assert_eq(h.m, 2)
      assert_eq(h.shard_total, 5)
      assert_eq(h.payload_len, 17)
    }
    None => fail("头往返不可达失败")
  }
  // 短帧
  assert_true(fec_read_header(FixedArray::make(11, (0).to_byte())) is None)
  let bad = FixedArray::make(40, (0).to_byte())
  // k=0 越域
  fec_write_header(bad, 1, 0, 0, 2, 8)
  assert_true(fec_read_header(bad) is None)
  // shard_total 失配
  fec_write_header(bad, 1, 0, 3, 2, 8)
  bad[7] = (9).to_byte()
  assert_true(fec_read_header(bad) is None)
  // index 越组
  fec_write_header(bad, 1, 6, 3, 2, 8)
  assert_true(fec_read_header(bad) is None)
  // payload_len 超帧余量(40-12=28,取 29)
  fec_write_header(bad, 1, 0, 3, 2, 29)
  assert_true(fec_read_header(bad) is None)
}

///|
test "TX 突发语义:k=3/m=2 组满同突发发冗余,尾组不闭,组号推进" {
  let tx = FecTx::new(3, 2, 40)
  let mk = fn(i : Int32) {
    let b = FixedArray::make(10, (0).to_byte())
    b[0] = i.to_byte()
    b
  }
  let f1 = tx.feed(mk(1))
  assert_eq(f1.length(), 1)
  let f2 = tx.feed(mk(2))
  assert_eq(f2.length(), 1)
  let f3 = tx.feed(mk(3))
  assert_eq(f3.length(), 3) // 数据 + 2 冗余同突发
  let f4 = tx.feed(mk(4))
  assert_eq(f4.length(), 1) // 新组尾组不闭
  // 头 payload_len 与体内 body_len 镜像一致(直通帧)
  assert_eq((f1[0][8].to_int() << 8) | f1[0][9].to_int(), fec_body_len(f1[0]))
  // 冗余帧 payload_len = 片体容量
  assert_eq((f3[1][8].to_int() << 8) | f3[1][9].to_int(), 40 - FEC_HEADER_SIZE)
  let st = tx.stats()
  assert_eq(st.closed_groups, 1)
  assert_eq(st.frames_out, 6)
}

///|
test "端到端带损:k=3/m=2 两组六消息,组内两抹除当场恢复,补投顺序正确" {
  let tx = FecTx::new(3, 2, 40)
  let rx = FecRx::new(8)
  let mk = fn(i : Int32) {
    let b = FixedArray::make(6, (0).to_byte())
    b[0] = i.to_byte()
    b[5] = ((i * 7) & 0xFF).to_byte()
    b
  }
  let wire : Array[FixedArray[Byte]] = []
  for i in 1..<7 {
    for f in tx.feed(mk(i)) {
      wire.push(f)
    }
  }
  assert_eq(wire.length(), 10) // (3+2)+(3+2)
  // 抹组0 的 idx1(数据)与 idx3(冗余)
  let drop : FixedArray[Bool] = FixedArray::make(10, false)
  drop[1] = true
  drop[3] = true
  let delivered : Array[Int32] = []
  for i in 0..<10 {
    if !drop[i] {
      for msg in rx.feed(wire[i]) {
        delivered.push(msg[0].to_int())
      }
    }
  }
  assert_eq(delivered.length(), 6)
  // 顺序:直通 1,3 → 组0 齐片恢复 2 → 组1 顺 4,5,6
  assert_eq(delivered[0], 1)
  assert_eq(delivered[1], 3)
  assert_eq(delivered[2], 2)
  assert_eq(delivered[3], 4)
  assert_eq(delivered[4], 5)
  assert_eq(delivered[5], 6)
  let st = rx.stats()
  assert_eq(st.delivered, 6)
  assert_eq(st.recovered_shards, 1)
  assert_eq(st.recovered_groups, 1)
  assert_eq(st.dropped_malformed, 0)
  assert_eq(st.dropped_late, 2) // 组1 两冗余帧迟到,弃置入账
}

///|
test "弃置面:重复帧弃/坏帧弃/窗口逐出计组亡" {
  let tx = FecTx::new(3, 1, 32)
  let rx = FecRx::new(1)
  let mk = fn(i : Int32) { FixedArray::make(4, i.to_byte()) }
  let a1 = tx.feed(mk(1))
  let a2 = tx.feed(mk(2))
  let a3 = tx.feed(mk(3)) // 闭组0:[数据, 冗余]
  let a4 = tx.feed(mk(4)) // 组1 尾组
  let _ = rx.feed(a1[0])
  let _ = rx.feed(a1[0]) // 重复 → late
  let _ = rx.feed(a2[0])
  let _ = rx.feed(FixedArray::make(20, (0).to_byte())) // k=0 → malformed
  let _ = rx.feed(a4[0]) // 组1 入窗 → 逐出组0(未 done)→ lost
  assert_true(a3.length() == 2)
  let st = rx.stats()
  assert_eq(st.delivered, 3)
  assert_eq(st.dropped_late, 1)
  assert_eq(st.dropped_malformed, 1)
  assert_eq(st.groups_lost, 1)
}

///|
test "端口注入:with_codec 走 MdsCodec 适配器同收敛,数据齐组不计恢复" {
  let tx = FecTx::with_codec(RsCodec::new(2, 1), 2, 1, 32)
  let rx = FecRx::with_codec(fn(k : Int32, m : Int32) { RsCodec::new(k, m) }, 4)
  let mk = fn(i : Int32) { FixedArray::make(4, i.to_byte()) }
  let b1 = tx.feed(mk(1))
  let b2 = tx.feed(mk(2)) // 闭组
  let got : Array[Int32] = []
  for f in b1 {
    for msg in rx.feed(f) {
      got.push(msg[0].to_int())
    }
  }
  for f in b2 {
    for msg in rx.feed(f) {
      got.push(msg[0].to_int())
    }
  }
  assert_eq(got.length(), 2)
  assert_eq(got[0], 1)
  assert_eq(got[1], 2)
  let st = rx.stats()
  assert_eq(st.recovered_groups, 0) // 数据齐组,无恢复
  assert_eq(st.delivered, 2)
}
