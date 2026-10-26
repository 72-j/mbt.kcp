// session.mbt — 双方向会话(D-S1:keys 唯一交换物)
//
// 客户端:发用 c2s、收用 s2c;服务端镜像。noise 插拔位:任何握手产出
// SessionKeys 即可 client/server 起 会话。

///|
pub struct SecSession {
  sealer : Sealer
  opener : Opener
}

///|
/// 客户端视角。
pub fn SecSession::client(keys~ : SessionKeys) -> SecSession {
  {
    sealer: Sealer::new(key=keys.key_c2s),
    opener: Opener::new(key=keys.key_s2c),
  }
}

///|
/// 服务端视角(方向镜像)。
pub fn SecSession::server(keys~ : SessionKeys) -> SecSession {
  {
    sealer: Sealer::new(key=keys.key_s2c),
    opener: Opener::new(key=keys.key_c2s),
  }
}

///|
/// 密封一包(发送方向自动)。
pub fn SecSession::seal(
  self : SecSession,
  aad~ : Bytes,
  plaintext~ : Bytes,
) -> Bytes {
  self.sealer.seal(aad~, plaintext~)
}

///|
/// 开启一包(接收方向自动);重放/篡改/窗外 None。
pub fn SecSession::open(
  self : SecSession,
  aad~ : Bytes,
  record~ : Bytes,
) -> Bytes? {
  self.opener.open(aad~, record~)
}
