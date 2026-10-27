// rs_wbtest.mbt — 刀2 门:MDS 抹除穷举 + LCG 财产门(白盒,同包)

///|
/// LCG 确定性抽签(与 workspace/diff_driver.c 同式:线性同余,取 31 位)。
fn lcg_next(state : Array[Int32]) -> Int32 {
  let x = (state[0] * 1664525 + 1013904223) & 0x7FFFFFFF
  state[0] = x
  x
}

///|
/// LCG 随机数据片组(k 片 × shard_len 字节)。
fn make_shards(
  k : Int32,
  shard_len : Int32,
  rng : Array[Int32],
) -> Array[FixedArray[Byte]] {
  let data : Array[FixedArray[Byte]] = []
  for _ in 0..<k {
    let shard = FixedArray::make(shard_len, (0).to_byte())
    for b in 0..<shard_len {
      shard[b] = (lcg_next(rng) & 0xFF).to_byte()
    }
    data.push(shard)
  }
  data
}

///|
/// 逐字节比对。
fn shards_equal(a : FixedArray[Byte], b : FixedArray[Byte]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
/// 组装 slots(data + parity 全存活,再按 erased 下标抹除)。
fn build_slots(
  data : Array[FixedArray[Byte]],
  parity : Array[FixedArray[Byte]],
  erased : Array[Int32],
) -> Array[FixedArray[Byte]?] {
  let slots : Array[FixedArray[Byte]?] = []
  for d in data {
    slots.push(Some(d))
  }
  for p in parity {
    slots.push(Some(p))
  }
  for idx in erased {
    slots[idx] = None
  }
  slots
}

///|
/// 原始全量(data ‖ parity)。
fn full_of(
  data : Array[FixedArray[Byte]],
  parity : Array[FixedArray[Byte]],
) -> Array[FixedArray[Byte]] {
  let full : Array[FixedArray[Byte]] = []
  for d in data {
    full.push(d)
  }
  for p in parity {
    full.push(p)
  }
  full
}

///|
/// 位掩码 popcount。
fn popcount(x : Int32) -> Int32 {
  let mut v = x
  let mut n = 0
  while v > 0 {
    if (v & 1) == 1 {
      n += 1
    }
    v = v >> 1
  }
  n
}

///|
/// MDS 抹除穷举:枚举全部 ≤m 片抹除子集(位掩码),逐一恢复逐字节比对。
fn exhaust_case(k : Int32, m : Int32, rng : Array[Int32]) -> Unit raise {
  let codec = RsCodec::new(k, m)
  let total = k + m
  let data = make_shards(k, 8, rng)
  let parity = codec.encode_parity(data)
  let original = full_of(data, parity)
  for mask in 0..<(1 << total) {
    if popcount(mask) <= m {
      let erased : Array[Int32] = []
      for i in 0..<total {
        if ((mask >> i) & 1) == 1 {
          erased.push(i)
        }
      }
      let slots = build_slots(data, parity, erased)
      match codec.recover(slots) {
        Some(recovered) =>
          for i in 0..<total {
            let msg = "MDS 复原不等:k=\{k} m=\{m} mask=\{mask} 片\{i}"
            assert_true(shards_equal(recovered[i], original[i]), msg~)
          }
        None => fail("MDS 恢复不可达失败:k=\{k} m=\{m} mask=\{mask}")
      }
    }
  }
}

///|
test "MDS 抹除穷举:k=1/1、k=4/2、k=5/3 全部 ≤m 子集复原" {
  exhaust_case(1, 1, [777])
  exhaust_case(4, 2, [4242])
  exhaust_case(5, 3, [987654])
}

///|
test "LCG 财产门:k 1..20 × m 1..8,随机 ≤m 抹除逐字节复原(160 组合×4 轮)" {
  let rng : Array[Int32] = [12345]
  let mut combos = 0
  for k in 1..<21 {
    for m in 1..<9 {
      let codec = RsCodec::new(k, m)
      let data = make_shards(k, 16, rng)
      let parity = codec.encode_parity(data)
      let original = full_of(data, parity)
      for _round in 0..<4 {
        // 随机选 0..m 个互异下标抹除
        let erase_cnt = lcg_next(rng) % (m + 1)
        let erased : Array[Int32] = []
        while erased.length() < erase_cnt {
          let idx = lcg_next(rng) % (k + m)
          let mut dup = false
          for e in erased {
            if e == idx {
              dup = true
            }
          }
          if !dup {
            erased.push(idx)
          }
        }
        let slots = build_slots(data, parity, erased)
        match codec.recover(slots) {
          Some(recovered) =>
            for i in 0..<(k + m) {
              let msg = "LCG 财产门不等:k=\{k} m=\{m} 片\{i}"
              assert_true(shards_equal(recovered[i], original[i]), msg~)
            }
          None => fail("LCG 财产门恢复失败:k=\{k} m=\{m}")
        }
      }
      combos += 1
    }
  }
  assert_eq(combos, 160)
}

///|
test "存活不足 k 或片长不一 → None(诚实拒判)" {
  let codec = RsCodec::new(4, 2)
  let rng : Array[Int32] = [9]
  let data = make_shards(4, 8, rng)
  let parity = codec.encode_parity(data)
  // 抹 3 片(>m=2)→ 存活 3 < k → None
  let slots3 = build_slots(data, parity, [0, 1, 2])
  assert_true(codec.recover(slots3) is None)
  // 抹 1 片 + 篡改片长 → None
  let short = FixedArray::make(4, (0).to_byte())
  let slots_len : Array[FixedArray[Byte]?] = [
    None,
    Some(short),
    Some(parity[0]),
    Some(parity[1]),
    Some(data[3]),
    Some(data[2]),
  ]
  assert_true(codec.recover(slots_len) is None)
}

///|
test "Cauchy 系统阵形:上 k 行单位阵,下 m 行全非零" {
  let codec = RsCodec::new(3, 2)
  for r in 0..<3 {
    for c in 0..<3 {
      assert_eq(codec.matrix[r * 3 + c], if r == c { 1 } else { 0 })
    }
  }
  for r in 3..<5 {
    for c in 0..<3 {
      assert_true(codec.matrix[r * 3 + c] != 0)
    }
  }
}
