// pskcr.mbt — PSK-CR 三消息握手(A0 v1 原案;D-S4 nonce 注入,D-S6 字节进出)
//
// 客户端:client_start → [Hello] → on_salt → [Auth] + keys(标准 CR 形:
// 客户端先持钥,服务端 on_auth 确认)。错 psk = AuthFail;错序错型 = BadState。
// noise 插拔位(D-S1):任何握手只要产出 SessionKeys 即可与记录层对接。

///|
pub(all) enum PskCrErr {
  BadState(String)
  BadWire(String)
  AuthFail
} derive(Eq, Debug)

///|
/// 握手消息。wire 形 = 1B tag ‖ payload(D-S6)。
pub(all) enum PskCrMsg {
  Hello(Bytes) // 16B client_nonce
  Salt(Bytes) // 16B server_nonce
  Auth(Bytes) // 32B HMAC(psk, "C"‖cn‖sn)
} derive(Eq, Debug)

///|
pub fn PskCrMsg::to_wire(self : PskCrMsg) -> Bytes {
  match self {
    PskCrMsg::Hello(n) => b"\x01" + n
    PskCrMsg::Salt(n) => b"\x02" + n
    PskCrMsg::Auth(m) => b"\x03" + m
  }
}

///|
pub fn PskCrMsg::of_wire(data : Bytes) -> PskCrMsg? {
  if data.length() == 0 {
    return None
  }
  let tag = data[0].to_int()
  let body = data[1:data.length()].to_owned()
  match tag {
    1 => Some(PskCrMsg::Hello(body))
    2 => Some(PskCrMsg::Salt(body))
    3 => Some(PskCrMsg::Auth(body))
    _ => None
  }
}

///|
/// 客户端中态:已发 Hello,持 psk 与自己的 nonce。
pub(all) struct PskCrClient {
  psk : Bytes
  client_nonce : Bytes
}

///|
/// 客户端起步:发 HELLO。
pub fn pskcr_client_start(
  psk~ : Bytes,
  client_nonce~ : Bytes,
) -> (PskCrMsg, PskCrClient) {
  (PskCrMsg::Hello(client_nonce), { psk, client_nonce, })
}

///|
/// 客户端吃 SALT:验型 → AUTH 出手 → 密钥到手。
pub fn PskCrClient::on_salt(
  self : PskCrClient,
  msg~ : PskCrMsg,
) -> Result[(PskCrMsg, SessionKeys), PskCrErr] {
  let sn = match msg {
    PskCrMsg::Salt(n) => n
    _ => return Err(PskCrErr::BadState("应 SALT"))
  }
  if sn.length() != 16 || self.client_nonce.length() != 16 {
    return Err(PskCrErr::BadWire("nonce 须 16B"))
  }
  let mac = @lib.hmac_sha256(self.psk, b"C" + self.client_nonce + sn)
  let keys = derive_keys(self.psk, self.client_nonce, sn)
  Ok((PskCrMsg::Auth(mac), keys))
}

///|
/// 服务端中态:已回 SALT,持三方量。
pub(all) struct PskCrServer {
  psk : Bytes
  client_nonce : Bytes
  server_nonce : Bytes
}

///|
/// 服务端吃 HELLO:回 SALT。
pub fn pskcr_server_on_hello(
  psk~ : Bytes,
  server_nonce~ : Bytes,
  msg~ : PskCrMsg,
) -> Result[(PskCrMsg, PskCrServer), PskCrErr] {
  let cn = match msg {
    PskCrMsg::Hello(n) => n
    _ => return Err(PskCrErr::BadState("应 HELLO"))
  }
  if cn.length() != 16 || server_nonce.length() != 16 {
    return Err(PskCrErr::BadWire("nonce 须 16B"))
  }
  Ok((PskCrMsg::Salt(server_nonce), { psk, client_nonce: cn, server_nonce, }))
}

///|
/// 服务端吃 AUTH:挑战应答核验 → 密钥到手。错 psk 即 AuthFail。
pub fn PskCrServer::on_auth(
  self : PskCrServer,
  msg~ : PskCrMsg,
) -> Result[SessionKeys, PskCrErr] {
  let mac = match msg {
    PskCrMsg::Auth(m) => m
    _ => return Err(PskCrErr::BadState("应 AUTH"))
  }
  let expect = @lib.hmac_sha256(
    self.psk,
    b"C" + self.client_nonce + self.server_nonce,
  )
  if @lib.bytes_equal(expect, mac) == false {
    return Err(PskCrErr::AuthFail)
  }
  Ok(derive_keys(self.psk, self.client_nonce, self.server_nonce))
}

///|
/// trait/derive 方法显式晋升([0079] 标准动作)。
pub extend PskCrMsg with Eq::{not_equal, equal}

///|
pub extend PskCrMsg with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend PskCrErr with Eq::{not_equal, equal}

///|
pub extend PskCrErr with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend SessionKeys with Eq::{not_equal, equal}

///|
pub extend SessionKeys with @moonbitlang/core/debug.Debug::{to_repr}
