// rs.mbt — Reed-Solomon 系统码编解码(K8 刀2)
//
// 系统阵:(k+m)×k,上 k 行 = 单位阵(数据片透传零开销),下 m 行 = Cauchy
// C[r][c] = 1/(x_r ⊕ y_c),x_r ∈ [k, k+m)、y_c ∈ [0, k) —— 两组元素不相交,
// 分母恒非零;Cauchy 阵保证任 k×k 子阵可逆(MDS),任意 ≤m 片抹除可恢复。
//
// 解码 = 存活片抽子阵 → GF 高斯消元求逆 → 重造数据片;冗余片由数据片
// 重编码复原(冗余是数据的函数,不单独做恢复数学)。
//
// 门(rs_wbtest.mbt):MDS 抹除穷举(小组合全部 ≤m 子集)+ LCG 财产门
// (k 1..20 × m 1..8,随机 ≤m 抹除逐字节复原)。

///|
/// RS(k+m) 编解码器(系统码:数据片透传,冗余片 = Cauchy 行 × 数据片)。
/// 判据:k ≥ 1,m ≥ 1,k+m ≤ 256(GF 域上限;Cauchy 的 x/y 两组取
/// [0, k+m) 不相交分割)。片长由调用面统一(刀3 垫片收口)。
pub struct RsCodec {
  k : Int32
  m : Int32
  /// 系统阵 row-major:(k+m) 行 × k 列;上 k 行单位阵,下 m 行 Cauchy。
  matrix : FixedArray[Int32]
}

///|
pub fn RsCodec::new(k : Int32, m : Int32) -> RsCodec {
  if k < 1 || m < 1 || k + m > 256 {
    abort(
      "RsCodec::new: 组形越域 k=\{k} m=\{m}(判据:k≥1, m≥1, k+m≤256)",
    )
  }
  let matrix : FixedArray[Int32] = FixedArray::make((k + m) * k, 0)
  // 上 k 行单位阵
  for i in 0..<k {
    matrix[i * k + i] = 1
  }
  // 下 m 行 Cauchy:x_r = k + r,y_c = c → C[r][c] = 1/(k+r ⊕ c)
  for r in 0..<m {
    for c in 0..<k {
      matrix[(k + r) * k + c] = gf_inv((k + r) ^ c)
    }
  }
  { k, m, matrix, }
}

///|
/// 编码冗余片:k 个等长数据片进,m 个冗余片出(纯函数,不改输入)。
pub fn RsCodec::encode_parity(
  self : RsCodec,
  data : Array[FixedArray[Byte]],
) -> Array[FixedArray[Byte]] {
  let shard_len = data[0].length()
  let parity : Array[FixedArray[Byte]] = []
  for r in 0..<self.m {
    let row = FixedArray::make(shard_len, (0).to_byte())
    let mat_row = (self.k + r) * self.k
    for c in 0..<self.k {
      let coef = self.matrix[mat_row + c]
      if coef != 0 {
        let src = data[c]
        for b in 0..<shard_len {
          row[b] = (row[b].to_int() ^ gf_mul(coef, src[b].to_int())).to_byte()
        }
      }
    }
    parity.push(row)
  }
  parity
}

///|
/// 从存活片恢复全量:slots 长度 = k+m(Some = 存活,None = 抹除)。
/// 存活 ≥ k 即可恢复(MDS);返回全量 k+m 片——数据片按序重造,
/// 冗余片由数据片重编码。存活不足 / 片长不一 / 子阵不可逆 → None。
pub fn RsCodec::recover(
  self : RsCodec,
  slots : Array[FixedArray[Byte]?],
) -> Array[FixedArray[Byte]]? {
  // 单趟收集:存活下标与存活片(并行数组),免二次解包
  let surviving : Array[Int32] = []
  let ys : Array[FixedArray[Byte]] = []
  let mut shard_len = -1
  for i in 0..<slots.length() {
    match slots[i] {
      Some(s) => {
        if shard_len < 0 {
          shard_len = s.length()
        } else if s.length() != shard_len {
          return None
        }
        surviving.push(i)
        ys.push(s)
      }
      None => ()
    }
  }
  if shard_len <= 0 || surviving.length() < self.k {
    return None
  }
  // 抽 k×k 子阵(存活行),GF 高斯消元求逆
  let sub = FixedArray::make(self.k * self.k, 0)
  for r in 0..<self.k {
    for c in 0..<self.k {
      sub[r * self.k + c] = self.matrix[surviving[r] * self.k + c]
    }
  }
  let inv = match gf_mat_inv(sub, self.k) {
    Some(inverse) => inverse
    None => return None
  }
  // 数据片:x = A⁻¹ · y(逐行:row = Σ inv[r][c] · y[c])
  let data : Array[FixedArray[Byte]] = []
  for r in 0..<self.k {
    let row = FixedArray::make(shard_len, (0).to_byte())
    for c in 0..<self.k {
      let coef = inv[r * self.k + c]
      if coef != 0 {
        let src = ys[c]
        for b in 0..<shard_len {
          row[b] = (row[b].to_int() ^ gf_mul(coef, src[b].to_int())).to_byte()
        }
      }
    }
    data.push(row)
  }
  // 冗余片由数据片重编码;全量 = 数据 + 冗余
  let parity = self.encode_parity(data)
  let full : Array[FixedArray[Byte]] = []
  for d in data {
    full.push(d)
  }
  for p in parity {
    full.push(p)
  }
  Some(full)
}

///|
/// GF 高斯消元求逆:n×n 阵 row-major;不可逆 → None(Cauchy 子阵不触发)。
fn gf_mat_inv(a : FixedArray[Int32], n : Int32) -> FixedArray[Int32]? {
  let width = 2 * n
  // 增广 n × 2n:左 = a,右 = 单位阵
  let aug : FixedArray[Int32] = FixedArray::make(n * width, 0)
  for r in 0..<n {
    for c in 0..<n {
      aug[r * width + c] = a[r * n + c]
    }
    aug[r * width + n + r] = 1
  }
  for col in 0..<n {
    // 选主元
    let mut pivot = -1
    for r in col..<n {
      if aug[r * width + col] != 0 {
        pivot = r
        break
      }
    }
    if pivot < 0 {
      return None
    }
    // 行交换
    if pivot != col {
      for c in 0..<width {
        let tmp = aug[col * width + c]
        aug[col * width + c] = aug[pivot * width + c]
        aug[pivot * width + c] = tmp
      }
    }
    // 主元行归一(乘主元逆)
    let lead_inv = gf_inv(aug[col * width + col])
    for c in 0..<width {
      aug[col * width + c] = gf_mul(aug[col * width + c], lead_inv)
    }
    // 消其余行(GF 加法 = 异或)
    for r in 0..<n {
      if r != col {
        let factor = aug[r * width + col]
        if factor != 0 {
          for c in 0..<width {
            aug[r * width + c] = aug[r * width + c] ^
              gf_mul(factor, aug[col * width + c])
          }
        }
      }
    }
  }
  // 取右半
  let inv : FixedArray[Int32] = FixedArray::make(n * n, 0)
  for r in 0..<n {
    for c in 0..<n {
      inv[r * n + c] = aug[r * width + n + c]
    }
  }
  Some(inv)
}
