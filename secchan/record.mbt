// record.mbt — 记录层(D-S2 确定性 nonce / D-S3 滑窗垃圾不毒窗 / D-S5 AAD)
//
// 记录线形 = seq(8B 大端) ‖ ct ‖ tag(16B);nonce = 4B 零 ‖ seq(8B BE)。
// 方向分钥:Sealer/Opener 各持一方向 32B 钥。seq 从 1 起(0 保留拒收)。

///|
/// 窗口预检(纯函数):(收否, 新 highest, 新 bits)。不落账——解密成功
/// 才由调用方提交,垃圾包不毒窗(D-S3)。
fn window_probe(
  highest : UInt64,
  bits : UInt64,
  seq : UInt64,
) -> (Bool, UInt64, UInt64) {
  if seq == 0UL {
    return (false, highest, bits)
  }
  if seq > highest {
    let shift = seq - highest
    let next_bits = if shift >= 64UL {
      1UL
    } else {
      (bits << shift.to_int()) | 1UL
    }
    return (true, seq, next_bits)
  }
  let back = highest - seq
  if back >= 64UL {
    return (false, highest, bits)
  }
  let bit = 1UL << back.to_int()
  if (bits & bit) != 0UL {
    return (false, highest, bits)
  }
  (true, highest, bits | bit)
}

///|
fn seq_bytes(seq : UInt64) -> Bytes {
  Bytes::makei(8, fn(i) { ((seq >> ((7 - i) * 8)) & 0xFFUL).to_byte() })
}

///|
fn record_nonce(seq : UInt64) -> Bytes {
  b"\x00\x00\x00\x00" + seq_bytes(seq)
}

///|
fn seq_of(record : Bytes) -> UInt64 {
  let mut v = 0UL
  for i in 0..<8 {
    v = (v << 8) | record[i].to_int().to_uint64()
  }
  v
}

///|
/// 密封侧:发送序单调递增。
pub struct Sealer {
  key : Bytes
  mut seq : UInt64
}

///|
pub fn Sealer::new(key~ : Bytes) -> Sealer {
  { key, seq: 0UL, }
}

///|
/// 密封:输出 seq(8B BE) ‖ ct ‖ tag。aad 与记录绑定防挪包(D-S5)。
pub fn Sealer::seal(self : Sealer, aad~ : Bytes, plaintext~ : Bytes) -> Bytes {
  self.seq = self.seq + 1UL
  let nonce = record_nonce(self.seq)
  let tagged = @lib.aes_gcm_encrypt(plaintext, self.key, nonce, aad)
  seq_bytes(self.seq) + tagged.ct + tagged.tag
}

///|
/// 开启侧:滑窗 64 位;解密成功才提交窗口(D-S3)。
pub struct Opener {
  key : Bytes
  mut highest : UInt64
  mut bits : UInt64
}

///|
pub fn Opener::new(key~ : Bytes) -> Opener {
  { key, highest: 0UL, bits: 0UL, }
}

///|
/// 开启:重放/窗外/篡改/撕短 一律 None(无 oracle)。
pub fn Opener::open(self : Opener, aad~ : Bytes, record~ : Bytes) -> Bytes? {
  if record.length() < 8 + 16 {
    return None
  }
  let seq = seq_of(record)
  let (ok, next_highest, next_bits) = window_probe(self.highest, self.bits, seq)
  if ok == false {
    return None
  }
  let body_len = record.length() - 8 - 16
  let ct = Bytes::makei(body_len, fn(i) { record[8 + i] })
  let tag = Bytes::makei(16, fn(i) { record[8 + body_len + i] })
  match @lib.aes_gcm_decrypt(ct, self.key, record_nonce(seq), aad, tag) {
    Ok(pt) => {
      self.highest = next_highest
      self.bits = next_bits
      Some(pt)
    }
    Err(_) => None
  }
}
