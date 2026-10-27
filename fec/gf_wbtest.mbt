// gf_wbtest.mbt — 刀1 已知答案门 + 域完备性门(白盒,同包)

///|
test "GF 表实现 = 移位加实现,全 65536 组合逐项相等" {
  for a in 0..<256 {
    for b in 0..<256 {
      assert_eq(gf_mul(a, b), gf_mul_shift_add(a, b))
    }
  }
}

///|
test "生成元 2 本原:exp 前 255 项恰覆盖全部非零元,阶恰 255" {
  let seen : FixedArray[Bool] = FixedArray::make(256, false)
  for i in 0..<255 {
    let v = gf_exp[i]
    assert_true(v >= 1 && v <= 255)
    assert_true(!seen[v])
    seen[v] = true
  }
  assert_eq(gf_exp[255], 1)
}

///|
test "乘法单位元/零吸收/手算已知答案" {
  assert_eq(gf_mul(1, 0x53), 0x53)
  assert_eq(gf_mul(0, 0x53), 0)
  // 0x80 << 1 = 0x100 过界,折 GF_POLY:0x100 ^ 0x11D = 0x1D
  assert_eq(gf_mul(2, 0x80), 0x1D)
  // (2⊕1)² = 4⊕2⊕2⊕1 = 5,任意 GF(2^8) 成立
  assert_eq(gf_mul(3, 3), 5)
}

///|
test "逆元全域:a · a⁻¹ = 1" {
  for a in 1..<256 {
    assert_eq(gf_mul(a, gf_inv(a)), 1)
  }
}

///|
test "除法全域:(a / b) · b = a" {
  for a in 0..<256 {
    for b in 1..<256 {
      assert_eq(gf_mul(gf_div(a, b), b), a)
    }
  }
}
