// keys.mbt — SessionKeys + 派生(D-S1:唯一交换物;D-S4:熵全参数注入)
//
// PSK + 双 nonce → 双方向会话密钥(A0 v1 派生式):
//   master = HKDF-Extract(salt=cn‖sn, ikm=psk)
//   key_c2s = Expand(master, "secchan c2s");key_s2c = Expand(master, "secchan s2c")

///|
/// 会话密钥对:方向分离(各 32B)。PSK-CR / Noise 谁产出,信道不关心。
pub(all) struct SessionKeys {
  key_c2s : Bytes
  key_s2c : Bytes
} derive(Eq, Debug)

///|
/// 由 PSK 与双方 nonce 派生会话密钥。nonce 各 16B(消费方 CSPRNG 注入)。
pub fn derive_keys(
  psk : Bytes,
  client_nonce : Bytes,
  server_nonce : Bytes,
) -> SessionKeys {
  let salt = client_nonce + server_nonce
  let master = @lib.hkdf_sha256(salt, psk, b"secchan master", 32)
  SessionKeys::{
    key_c2s: @lib.hkdf_sha256(b"", master, b"secchan c2s", 32),
    key_s2c: @lib.hkdf_sha256(b"", master, b"secchan s2c", 32),
  }
}
