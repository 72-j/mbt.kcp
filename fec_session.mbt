// fec_session.mbt — FEC 会话壳(K8 刀4)
//
// 组合宿主:KcpSession + FecTx/FecRx 薄包装,应用面 API 一一透传。
// 接线(茗篇 §一):
//   - send_message → KcpSession.send_message(KCP 面零改动)
//   - tick         → KCP 帧 逐帧 FecTx.feed(组满同突发出冗余)
//   - on_datagram  → 线帧 FecRx.feed 出 KCP 报文 逐个喂会话
//   - poll_message → 直通
// 线预算(D-FEC5):片容量 = KCP mtu + FEC 头 + 体长前缀(缺省 1414
// ≤ 路径 MTU 1500);更紧预算的路径,建壳前先 session.kcp.set_mtu(预算−14)
// (容量构造时冻结)。载荷超容量时 FecTx.feed abort(诚实急停,刀3 语义)。
// FEC 关闭 = 直接用 KcpSession——本壳不存在即直通,核零沾。

///|
/// FEC 会话:KCP 会话 + FEC 发/收机(层外组合,双向对称)。
pub struct FecSession {
  session : KcpSession
  tx : @fec.FecTx
  rx : @fec.FecRx
}

///|
/// 新会话:conv 双端一致;high_water = 背压水位;k/m 组形;
/// 恢复窗深缺省 8 组。片容量按 KCP 当前 mtu 推导。
pub fn FecSession::new(
  conv : Int32,
  high_water : Int32,
  k : Int32,
  m : Int32,
) -> FecSession {
  let session = KcpSession::new(conv, high_water)
  let capacity = session.kcp.mtu + @fec.FEC_HEADER_SIZE + 2
  { session, tx: @fec.FecTx::new(k, m, capacity), rx: @fec.FecRx::new(8), }
}

///|
/// 应用下发一消息(透传;返回同 KcpSession::send_message)。
pub fn FecSession::send_message(
  self : FecSession,
  payload : FixedArray[Byte],
) -> Int32 {
  self.session.send_message(payload)
}

///|
/// 宿主投递一线帧:FEC 收机结算,出的 KCP 报文逐个喂会话。
/// 返回第一个非零 input 错码(全零返 0)。
pub fn FecSession::on_datagram(
  self : FecSession,
  frame : FixedArray[Byte],
) -> Int32 {
  let mut code = 0
  for msg in self.rx.feed(frame) {
    let c = self.session.on_datagram(msg)
    if c != 0 && code == 0 {
      code = c
    }
  }
  code
}

///|
/// 宿主时钟推进:KCP 到点 flush 出的帧逐个入 FEC 发机,
/// 返回待发送线帧(宿主逐帧走 UDP 发出)。
pub fn FecSession::tick(
  self : FecSession,
  now : Int32,
) -> Array[FixedArray[Byte]] {
  let wire : Array[FixedArray[Byte]] = []
  for frame in self.session.tick(now) {
    for out in self.tx.feed(frame) {
      wire.push(out)
    }
  }
  wire
}

///|
/// 应用收一消息(直通,FIFO)。
pub fn FecSession::poll_message(self : FecSession) -> FixedArray[Byte]? {
  self.session.poll_message()
}

///|
pub fn FecSession::is_dead(self : FecSession) -> Bool {
  self.session.is_dead()
}

///|
pub fn FecSession::last_active(self : FecSession) -> Int32 {
  self.session.last_active()
}

///|
/// KCP 观测快照(直通;FEC 侧读数走 fec_tx_stats / fec_rx_stats)。
pub fn FecSession::stats(self : FecSession) -> KcpStats {
  self.session.stats()
}

///|
pub fn FecSession::fec_tx_stats(self : FecSession) -> @fec.FecTxStats {
  self.tx.stats()
}

///|
pub fn FecSession::fec_rx_stats(self : FecSession) -> @fec.FecRxStats {
  self.rx.stats()
}
