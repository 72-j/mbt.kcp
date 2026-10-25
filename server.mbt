// server.mbt — KcpServer:conv 分离器多会话服务端(K6)
//
// 一条 UDP socket 收多会话报文 → 按头 4 字节 conv 路由到 KcpSession;
// 未知 conv 自动建会话(标准 KCP 服务端行为),会话表满则弃包(-4)。
// 纯形:零 IO 零时钟;tick 返回 (conv, 帧) 列表,宿主自持 conv→对端地址
// 映射投递(conv 不是地址,定位是会话标识)。
// 生命周期:判死会话由宿主经 is_dead 探得后 remove 收尸。

///|
/// conv 分离器多会话服务端。
pub(all) struct KcpServer {
  sessions : Map[Int32, KcpSession]
  high_water : Int32
  max_sessions : Int32
}

///|
/// 新服务端:high_water = 每会话背压水位;max_sessions = 会话表上限
/// (洪泛护栏,未知 conv 建会话超限即弃)。
pub fn KcpServer::new(high_water : Int32, max_sessions : Int32) -> KcpServer {
  { sessions: Map([]), high_water, max_sessions, }
}

///|
/// 会话查访(已建会话;不建)。
pub fn KcpServer::session_of(self : KcpServer, conv : Int32) -> KcpSession? {
  self.sessions.get(conv)
}

///|
/// 会话取建:未知 conv 自动建;表满返回 None(调用方弃包)。
pub fn KcpServer::get_or_create(self : KcpServer, conv : Int32) -> KcpSession? {
  match self.sessions.get(conv) {
    Some(session) => Some(session)
    None => {
      if self.sessions.length() >= self.max_sessions {
        return None
      }
      let session = KcpSession::new(conv, self.high_water)
      self.sessions[conv] = session
      Some(session)
    }
  }
}

///|
/// 收一报:头 4 字节 conv 路由。返回码:input 错码直传(0/-1/-2/-3);
/// -4 = 会话表满弃包。
pub fn KcpServer::on_datagram(
  self : KcpServer,
  datagram : FixedArray[Byte],
) -> Int32 {
  if datagram.length() < HEADER_SIZE {
    return -1
  }
  let conv = read_u32(datagram, 0)
  let session = match self.get_or_create(conv) {
    Some(session) => session
    None => return -4
  }
  session.on_datagram(datagram)
}

///|
/// 时间推进:全部会话各 tick 一拍,出帧带 conv 标签展平返回
/// (宿主按 conv 查地址投递)。
pub fn KcpServer::tick(
  self : KcpServer,
  current : Int32,
) -> Array[(Int32, FixedArray[Byte])] {
  let out : Array[(Int32, FixedArray[Byte])] = []
  for conv, session in self.sessions {
    for frame in session.tick(current) {
      out.push((conv, frame))
    }
  }
  out
}

///|
/// 会话收尸(宿主经 is_dead 探得后调用;或管理面强拆)。
pub fn KcpServer::remove(self : KcpServer, conv : Int32) -> Unit {
  self.sessions.remove(conv)
}

///|
/// 在册会话数(护栏读数)。
pub fn KcpServer::size(self : KcpServer) -> Int32 {
  self.sessions.length()
}

///|
/// 在册 conv 清单(宿主逐会话 poll 用)。
pub fn KcpServer::convs(self : KcpServer) -> Array[Int32] {
  let out : Array[Int32] = []
  for conv, _session in self.sessions {
    out.push(conv)
  }
  out
}

///|
/// 闲置清扫:current - last_active > idle_timeout 的会话移除并返回
/// 被逐 conv 清单。纯形:时钟由宿主注入,清扫由宿主在驱动环里调。
pub fn KcpServer::sweep(
  self : KcpServer,
  current : Int32,
  idle_timeout : Int32,
) -> Array[Int32] {
  let stale : Array[Int32] = []
  for conv, session in self.sessions {
    if itimediff(current, session.last_active()) > idle_timeout {
      stale.push(conv)
    }
  }
  let evicted : Array[Int32] = []
  let mut i = 0
  while i < stale.length() {
    let conv = stale[i]
    self.sessions.remove(conv)
    evicted.push(conv)
    i += 1
  }
  evicted
}
