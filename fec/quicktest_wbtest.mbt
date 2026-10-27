// quicktest_wbtest.mbt — quicktest 三面:边界 / 守恒律 / 公平性(K8 评审收尾)
//
// 边界 = 构造器组形域(k≥1, m≥1, k+m≤256;越域 abort 径进程内不可测,
// 与 FecTx 超容量同属已知边界留证)+ 头校验域上界。守恒律 = 逐组记账
// 精确等式:≤m 抹除的组必全量交付(数据即投 + 恢复补投 = k),内容
// 恰好一次。公平性 = 恢复窗逐出 FIFO 定序(最老未闭组先亡,幸存组
// 服务不受扰);片位公平已由 MDS 抹除穷举门定理级盖全,不重测。

///|
test "边界:k=1/m=1 最小组形端到端 + k+m=256 域上界 + 头校验越域拒收" {
  // 最小组形:k=1/m=1 单片即闭组;只喂冗余片也当场恢复
  let tx = FecTx::new(1, 1, 32)
  let payload = FixedArray::make(4, (7).to_byte())
  let frames = tx.feed(payload)
  assert_eq(frames.length(), 2)
  let rx = FecRx::new(4)
  let got = rx.feed(frames[1])
  assert_eq(got.length(), 1)
  assert_true(shards_equal(got[0], payload))
  let st = rx.stats()
  assert_eq(st.delivered, 1)
  assert_eq(st.recovered_groups, 1)
  assert_eq(st.recovered_shards, 1)
  // 线域上界 k+m=255(shard_total 单字节)可读写
  let frame = FixedArray::make(40, (0).to_byte())
  fec_write_header(frame, 9, 254, 254, 1, 4)
  assert_true(fec_read_header(frame) is Some(_))
  // 线域 k+m=256 写不出(字节回卷 0)→ 读拒;发侧构造器同域守卫急停
  let dead = FixedArray::make(40, (0).to_byte())
  fec_write_header(dead, 9, 0, 255, 1, 4)
  assert_true(fec_read_header(dead) is None)
  // 头校验域:k+m>255 拒收
  let bad = FixedArray::make(40, (0).to_byte())
  fec_write_header(bad, 9, 0, 200, 100, 4) // k+m=300
  assert_true(fec_read_header(bad) is None)
  // 编解码域上界 k+m=256(GF 上限,直连口可达)可构造,MDS 恢复在
  // 边界成立(254 数据 + 1 冗余)
  let edge = RsCodec::new(255, 1)
  let rng : Array[Int32] = [31]
  let data = make_shards(255, 1, rng)
  let parity = edge.encode_parity(data)
  assert_eq(parity.length(), 1)
  let slots : Array[FixedArray[Byte]?] = []
  for shard in data {
    slots.push(Some(shard))
  }
  slots[0] = None
  slots.push(Some(parity[0]))
  match edge.recover(slots) {
    Some(full) => {
      assert_true(shards_equal(full[0], data[0]))
      assert_true(shards_equal(full[255], parity[0]))
    }
    None => fail("编解码域上界 k+m=256 恢复不可达失败")
  }
}

///|
test "守恒律:LCG 三种子逐组记账,delivered 精确等式 + 内容恰好一次" {
  let group_k = 4
  let group_m = 2
  let group_total = 6
  let payload_n = 20 // 5 整组,无尾组
  for seed in [101, 202, 303] {
    let rng : Array[Int32] = [seed]
    let tx = FecTx::new(group_k, group_m, 64)
    let rx = FecRx::new(8)
    let sent = make_shards(payload_n, 8, rng)
    let wire : Array[FixedArray[Byte]] = []
    for p in sent {
      for f in tx.feed(p) {
        wire.push(f)
      }
    }
    assert_eq(wire.length(), 30)
    // 逐组随机抹 0..=2 帧(≤m,组必可恢复);记账:组内抹到数据片
    // 则该组恢复账 +1(组级,非片级——冗余片抹除不触发恢复计数),
    // 碎片账 += 数据抹除帧数
    let drop_flags : FixedArray[Bool] = FixedArray::make(30, false)
    let mut expected_recovered = 0
    let mut expected_recovered_shards = 0
    let mut dropped_total = 0
    for g in 0..<5 {
      let drops = lcg_next(rng) % 3
      let mut placed = 0
      let mut data_dropped = false
      while placed < drops {
        let pos = lcg_next(rng) % group_total
        let idx = g * group_total + pos
        if !drop_flags[idx] {
          drop_flags[idx] = true
          placed += 1
          dropped_total += 1
          if pos < group_k {
            data_dropped = true
            expected_recovered_shards += 1
          }
        }
      }
      if data_dropped {
        expected_recovered += 1
      }
    }
    let delivered : Array[FixedArray[Byte]] = []
    for i in 0..<30 {
      if !drop_flags[i] {
        for msg in rx.feed(wire[i]) {
          delivered.push(msg)
        }
      }
    }
    // 守恒等式:可恢复组全量交付 = 入组载荷数,一分不少一粒不多
    assert_eq(delivered.length(), payload_n)
    let st = rx.stats()
    assert_eq(st.delivered, payload_n)
    assert_eq(st.recovered_groups, expected_recovered)
    assert_eq(st.recovered_shards, expected_recovered_shards)
    assert_eq(st.dropped_malformed, 0)
    assert_eq(st.groups_lost, 0)
    assert_eq(st.frames_in, 30 - dropped_total)
    // 内容守恒:每条载荷恰投一次(顺序可异,多重集合相等)
    let used : FixedArray[Bool] = FixedArray::make(payload_n, false)
    for msg in delivered {
      let mut found = -1
      for j in 0..<payload_n {
        if found < 0 && !used[j] && shards_equal(msg, sent[j]) {
          found = j
        }
      }
      assert_true(
        found >= 0,
        msg="守恒律违:投出载荷不匹配任何入载荷",
      )
      if found >= 0 {
        used[found] = true
      }
    }
    for j in 0..<payload_n {
      assert_true(used[j], msg="守恒律违:入载荷 \{j} 未投出")
    }
  }
}

///|
test "公平性:窗口逐出 FIFO 定序——最老未闭组先亡,幸存组恢复服务不受扰" {
  let tx = FecTx::new(2, 1, 48)
  let wire : Array[FixedArray[Byte]] = []
  for i in 1..<9 {
    let p = FixedArray::make(4, i.to_byte())
    for f in tx.feed(p) {
      wire.push(f)
    }
  }
  // 4 整组 × 3 帧 = 12;组号改写为 100..103(内容不动)
  assert_eq(wire.length(), 12)
  for g in 0..<4 {
    let gid = 100 + g
    for f in 0..<3 {
      let frame = wire[g * 3 + f]
      frame[0] = ((gid >> 24) & 0xFF).to_byte()
      frame[1] = ((gid >> 16) & 0xFF).to_byte()
      frame[2] = ((gid >> 8) & 0xFF).to_byte()
      frame[3] = (gid & 0xFF).to_byte()
    }
  }
  let rx = FecRx::new(3)
  let _ = rx.feed(wire[0]) // g100 d0
  let _ = rx.feed(wire[3]) // g101 d0
  let _ = rx.feed(wire[6]) // g102 d0 → 窗满 [100,101,102]
  // g103 d0 入窗 → FIFO 逐出最老的 g100(未闭)→ 组亡恰 1
  let out = rx.feed(wire[9]) // g103 d0
  assert_eq(out.length(), 1)
  // 幸存三组补冗余片:当场恢复缺失数据片,内容各归其组
  let d1_g101 = rx.feed(wire[5]) // g101 p0 → 恢复 d1 = 载荷 4
  assert_eq(d1_g101.length(), 1)
  assert_eq(d1_g101[0][0], (4).to_byte())
  let d1_g102 = rx.feed(wire[8]) // g102 p0 → 恢复 d1 = 载荷 6
  assert_eq(d1_g102.length(), 1)
  assert_eq(d1_g102[0][0], (6).to_byte())
  let d1_g103 = rx.feed(wire[11]) // g103 p0 → 恢复 d1 = 载荷 8
  assert_eq(d1_g103.length(), 1)
  assert_eq(d1_g103[0][0], (8).to_byte())
  let st = rx.stats()
  // FIFO 定序铁证:若逐出的是 g101/g102,恢复账到不了 3
  assert_eq(st.groups_lost, 1)
  assert_eq(st.recovered_groups, 3)
  assert_eq(st.recovered_shards, 3)
  assert_eq(st.delivered, 7) // 4 数据即投 + 3 恢复补投
  assert_eq(st.dropped_malformed, 0)
  assert_eq(st.dropped_late, 0)
}
