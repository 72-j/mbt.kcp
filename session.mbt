// session.mbt — KcpSession 会话壳(K3)
//
// 宿主侧 API 门面:bundle Kcp 状态机 + 应用消息队列 + 背压。
// 集成面(与 heart tick / UDP adapter 对接的形状):
//   - 宿主收到 UDP 报文 → on_datagram(报文)
//   - 宿主时钟到点     → frames = tick(current);逐帧走 UDP 发出
//   - 应用发消息       → send_message(载荷)(窗口满拒收 = 背压)
//   - 应用收消息       → poll_message()(FIFO)
// 仍是纯形:零 IO 零时钟,帧与报文进出由宿主搬运。消息面全 Bytes(K1 刀1)。

///|
/// KCP 会话:状态机 + 收件队列 + 发送背压水位。
pub(all) struct KcpSession {
  kcp : Kcp
  inbound : Array[FixedArray[Byte]]
  high_water : Int32
}

///|
/// 新会话:conv 双端一致;high_water = waitsnd 背压上限
/// (snd_queue + snd_buf 达此值 send_message 拒收)。
pub fn KcpSession::new(conv : Int32, high_water : Int32) -> KcpSession {
  { kcp: Kcp::create(conv), inbound: [], high_water, }
}

///|
/// 应用下发一消息。waitsnd 达 high_water 返回 -2(窗口满背压);
/// 否则转 Kcp::send(负错码直传;成功返回字节数)。
pub fn KcpSession::send_message(
  self : KcpSession,
  payload : FixedArray[Byte],
) -> Int32 {
  if self.kcp.waitsnd() >= self.high_water {
    return -2
  }
  self.kcp.send(payload)
}

///|
/// 宿主投递一 UDP 报文:状态机结算后,把已就绪的整消息
/// 全部搬入收件队列。返回 input 错码(0 = 正常)。
pub fn KcpSession::on_datagram(
  self : KcpSession,
  datagram : FixedArray[Byte],
) -> Int32 {
  let code = self.kcp.input(datagram)
  let mut go = true
  while go {
    match self.kcp.recv() {
      Some(msg) => self.inbound.push(msg)
      None => go = false
    }
  }
  code
}

///|
/// 宿主时钟推进:到 interval 点则 flush,返回待发送帧
/// (宿主逐帧走 UDP 发出)。
pub fn KcpSession::tick(
  self : KcpSession,
  current : Int32,
) -> Array[FixedArray[Byte]] {
  self.kcp.update(current)
}

///|
/// 应用收一消息(FIFO);无消息返回 None。
pub fn KcpSession::poll_message(self : KcpSession) -> FixedArray[Byte]? {
  if self.inbound.length() == 0 {
    return None
  }
  Some(self.inbound.remove(0))
}

///|
/// 链路判死(dead_link 触发后 state = -1)。
pub fn KcpSession::is_dead(self : KcpSession) -> Bool {
  self.kcp.state != 0
}

///|
/// 观测快照透传(运维/调试面)。
pub fn KcpSession::stats(self : KcpSession) -> KcpStats {
  self.kcp.stats()
}

///|
/// 活性戳透传(最近一次合法对端报文的注入 ms;闲置回收判据)。
pub fn KcpSession::last_active(self : KcpSession) -> Int32 {
  self.kcp.last_active
}
