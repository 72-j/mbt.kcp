// gf.mbt — GF(2^8) 有限域内核(K8 刀1,D-FEC3)
//
// 域参数拍定:多项式 0x11D(x^8+x^4+x^3+x^2+1),生成元 2(libfec 惯例;
// 与 klauspost/reedsolomon 的 0x1D 惯例不同域,互不通用)。钉死永不变。
//
// 门(gf_wbtest.mbt):
//   - 双实现全组合对拍:表实现 vs 移位加实现,65536 组合逐项相等
//   - 域完备性:生成元本原性(exp 前 255 项恰覆盖全部非零元,阶恰 255)
//   - a·a⁻¹ = 1 全域;(a/b)·b = a 全组合
//
// 值域约定:入参出参一律 [0, 255];仅供刀2 RS 矩阵编解码消费。

///|
/// 域多项式(含 x^8 位)。
pub const GF_POLY : Int32 = 0x11D

///|
/// 指数表:gf_exp[i] = 生成元 2 的 i 次幂,i ∈ [0, 511] 倍周期展开
/// (乘法查表免取模:log 和至多 254+254 = 508)。
let gf_exp : FixedArray[Int32] = gf_build_exp()

///|
/// 对数表:gf_log[v] = v 的指数(exp 的逆);v = 0 项无定义,驻 0
/// (调用面不触,防御位)。
let gf_log : FixedArray[Int32] = gf_build_log()

///|
fn gf_build_exp() -> FixedArray[Int32] {
  let table : FixedArray[Int32] = FixedArray::make(512, 0)
  let mut x = 1
  for i in 0..<512 {
    table[i] = x
    x = x << 1
    if x >= 256 {
      x = x ^ GF_POLY
    }
  }
  table
}

///|
fn gf_build_log() -> FixedArray[Int32] {
  let table : FixedArray[Int32] = FixedArray::make(256, 0)
  let mut x = 1
  for i in 0..<255 {
    table[x] = i
    x = x << 1
    if x >= 256 {
      x = x ^ GF_POLY
    }
  }
  table
}

///|
/// GF 乘法:全值域定义(0 吸收)。
pub fn gf_mul(a : Int32, b : Int32) -> Int32 {
  if a == 0 || b == 0 {
    0
  } else {
    gf_exp[gf_log[a] + gf_log[b]]
  }
}

///|
/// GF 除法:b = 0 无定义,防御返 0(调用面 = 可逆子阵消元,不产生除零)。
pub fn gf_div(a : Int32, b : Int32) -> Int32 {
  if a == 0 || b == 0 {
    0
  } else {
    let mut d = gf_log[a] - gf_log[b]
    if d < 0 {
      d += 255
    }
    gf_exp[d]
  }
}

///|
/// GF 逆元:a = 0 无定义,防御返 0。
pub fn gf_inv(a : Int32) -> Int32 {
  if a == 0 {
    0
  } else {
    gf_exp[255 - gf_log[a]]
  }
}

///|
/// 移位加参照乘法:与表实现算法独立,公开供测试/交叉验证对拍
/// (全组合逐项相等 = 刀1 已知答案门)。
pub fn gf_mul_shift_add(a : Int32, b : Int32) -> Int32 {
  let mut acc = 0
  let mut x = a
  let mut y = b
  while y > 0 {
    if (y & 1) == 1 {
      acc = acc ^ x
    }
    y = y >> 1
    x = x << 1
    if x >= 256 {
      x = x ^ GF_POLY
    }
  }
  acc
}
