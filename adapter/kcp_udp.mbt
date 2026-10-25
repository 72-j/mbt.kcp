// kcp_udp.mbt — K4:async UDP adapter(六边形出浆口)
//
// 协议核心零 IO 律不破:本包是唯一触碰 socket 的地方。
// 形状:B 侧 = UdpServer(:0 自分配,首包 recvfrom 学对端地址);
//       A 侧 = UdpClient(connected,构造即指向 B)。
// 会话帧即 Bytes(刀1)——出帧直发、收报单趟切片;时序仍由宿主注入
// (pump_out(current),核心 ms 律不变)。

///|
/// UDP 载荷切片 → wire Bytes(只取前 n 字节,recv 返回实际读长)。
fn bytes_of(buf : FixedArray[Byte], n : Int) -> Bytes {
  Bytes::makei(n, fn(i) { buf[i] })
}

///|
/// KCP 会话的 UDP 末端:session + client(A 侧)或 server(B 侧)。
pub struct KcpUdpPeer {
  session : @moonkcp.KcpSession
  priv client : @socket.UdpClient?
  priv server : @socket.UdpServer?
  priv mut peer_addr : @socket.Addr?
}

///|
/// A 侧:connected UDP 客户端,指向 server_addr(recv 只认该对端)。
pub async fn KcpUdpPeer::connect_client(
  conv : Int, high_water : Int, server_addr : @socket.Addr
) -> KcpUdpPeer raise {
  let client = @socket.UdpClient::UdpClient(server_addr)
  {
    session: @moonkcp.KcpSession::new(conv, high_water),
    client: Some(client),
    server: None,
    peer_addr: None,
  }
}

///|
/// B 侧:UDP 服务端,127.0.0.1:0 自分配;真身地址问 local_addr()。
pub async fn KcpUdpPeer::listen_server(
  conv : Int, high_water : Int
) -> KcpUdpPeer raise {
  let server = @socket.UdpServer::UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  {
    session: @moonkcp.KcpSession::new(conv, high_water),
    client: None,
    server: Some(server),
    peer_addr: None,
  }
}

///|
/// 本端绑定地址(对端 connect 用)。
pub fn KcpUdpPeer::local_addr(self : KcpUdpPeer) -> @socket.Addr {
  match self.client {
    Some(client) => client.addr
    None =>
      match self.server {
        Some(server) => server.addr
        None => abort("KcpUdpPeer: no endpoint")
      }
  }
}

///|
/// 出泵:tick 会话,出帧逐帧走 UDP 发出(Bytes 直发,零转换)。返回发出帧数。
pub async fn KcpUdpPeer::pump_out(self : KcpUdpPeer, current : Int) -> Int raise {
  let frames = self.session.tick(current)
  let mut sent = 0
  for frame in frames {
    match self.client {
      Some(client) => client.send(frame)
      None =>
        match self.server {
          Some(server) =>
            match self.peer_addr {
              Some(peer) => server.sendto(frame, peer)
              // 对端地址未学得(B 首包未到)——帧弃,发送侧重传机制自会补
              None => ()
            }
          None => abort("KcpUdpPeer: no endpoint")
        }
    }
    sent += 1
  }
  sent
}

///|
/// 收一报(阻塞至达):喂会话;B 侧顺带学对端地址。返回读得字节数。
pub async fn KcpUdpPeer::recv_one(self : KcpUdpPeer) -> Int raise {
  let buf : FixedArray[Byte] = FixedArray::make(2048, 0b0)
  match self.client {
    Some(client) => {
      let n = client.recv(buf)
      if n > 0 {
        let _ = self.session.on_datagram(bytes_of(buf, n))
      }
      n
    }
    None =>
      match self.server {
        Some(server) => {
          let (n, addr) = server.recvfrom(buf)
          self.peer_addr = Some(addr)
          if n > 0 {
            let _ = self.session.on_datagram(bytes_of(buf, n))
          }
          n
        }
        None => abort("KcpUdpPeer: no endpoint")
      }
  }
}

///|
/// 应用下发一消息(背压语义同会话壳)。
pub fn KcpUdpPeer::send_message(self : KcpUdpPeer, payload : Bytes) -> Int {
  self.session.send_message(payload)
}

///|
/// 应用收一消息(FIFO;无消息 None)。
pub fn KcpUdpPeer::poll_message(self : KcpUdpPeer) -> Bytes? {
  self.session.poll_message()
}

///|
/// K7 服务端组合宿主:UdpServer + KcpServer + conv→Addr 表。
/// 一条 socket 服务多会话:recvfrom 学地址、按 conv 路由;出泵按
/// conv 查地址 sendto。闲置回收同拍清地址表。
pub struct KcpUdpHub {
  server : @moonkcp.KcpServer
  priv udp : @socket.UdpServer
  priv addrs : Map[Int, @socket.Addr]
}

///|
/// 监听 127.0.0.1:0 自分配;真身地址问 local_addr()。
pub async fn KcpUdpHub::listen(high_water : Int, max_sessions : Int) -> KcpUdpHub raise {
  let udp = @socket.UdpServer::UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  {
    server: @moonkcp.KcpServer::new(high_water, max_sessions),
    udp,
    addrs: Map([]),
  }
}

///|
/// 本端绑定地址(客户端 connect 用)。
pub fn KcpUdpHub::local_addr(self : KcpUdpHub) -> @socket.Addr {
  self.udp.addr
}

///|
/// 收一报(阻塞至达):recvfrom 学 conv→Addr,路由进分离器。
/// 返回 input 错码(0/-1/-2/-3/-4,含义同 KcpServer::on_datagram)。
pub async fn KcpUdpHub::recv_one(self : KcpUdpHub) -> Int raise {
  let buf : FixedArray[Byte] = FixedArray::make(2048, 0b0)
  let (n, addr) = self.udp.recvfrom(buf)
  if n >= 4 {
    let conv = buf[0].to_int() | (buf[1].to_int() << 8) | (buf[2].to_int() << 16) | (buf[3].to_int() << 24)
    self.addrs[conv] = addr
  }
  self.server.on_datagram(bytes_of(buf, n))
}

///|
/// 出泵:分离器 tick,出帧按 conv 查地址 sendto。
/// 返回逐会话帧数 [(conv, n_frames)]——宿主/测试据此定向收包。
pub async fn KcpUdpHub::pump_out(
  self : KcpUdpHub, current : Int
) -> Array[(Int, Int)] raise {
  let tagged = self.server.tick(current)
  let per_conv : Array[(Int, Int)] = []
  for entry in tagged {
    let (conv, frame) = entry
    match self.addrs.get(conv) {
      Some(addr) => self.udp.sendto(frame, addr)
      // conv 无地址(不可能经报文入表缺失)——帧弃,重传自会补
      None => ()
    }
    let mut found = false
    let mut i = 0
    while i < per_conv.length() && found == false {
      let (c, n) = per_conv[i]
      if c == conv {
        per_conv[i] = (c, n + 1)
        found = true
      }
      i += 1
    }
    if found == false {
      per_conv.push((conv, 1))
    }
  }
  per_conv
}

///|
/// 对指定会话发消息(背压语义同会话壳;无会话 -1)。
pub fn KcpUdpHub::send_message_to(
  self : KcpUdpHub, conv : Int, payload : Bytes
) -> Int {
  match self.server.session_of(conv) {
    Some(session) => session.send_message(payload)
    None => -1
  }
}

///|
/// 收指定会话一消息(FIFO;无会话/无消息 None)。
pub fn KcpUdpHub::poll_message(self : KcpUdpHub, conv : Int) -> Bytes? {
  match self.server.session_of(conv) {
    Some(session) => session.poll_message()
    None => None
  }
}

///|
/// 在册 conv 清单。
pub fn KcpUdpHub::convs(self : KcpUdpHub) -> Array[Int] {
  self.server.convs()
}

///|
/// 闲置清扫:会话与地址表同拍清,返回被逐 conv 清单。
pub fn KcpUdpHub::sweep(
  self : KcpUdpHub, current : Int, idle_timeout : Int
) -> Array[Int] {
  let evicted = self.server.sweep(current, idle_timeout)
  let mut i = 0
  while i < evicted.length() {
    let _ = self.addrs.remove(evicted[i])
    i += 1
  }
  evicted
}
