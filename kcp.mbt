// kcp.mbt — KCP ARQ 核心(K2;skywind3000/kcp ikcp.c 精确复刻;刀1 Bytes 化)
//
// 纯状态机:零 IO、零时钟——current 全注入,update 返回出帧,宿主投递。
// 数据面:send(应用消息按 mss 分片入 snd_queue) → update(区间到点则 flush) →
//        input(收报文:ACK 结算 / PUSH 入缓冲 / WASK·WINS 探窗) →
//        recv(应用读:碎片合并成整消息)。
// 队列四件套:snd_queue(应用已交未进窗)→ snd_buf(已发未确认)→
//            对端 rcv_buf(收到但非连续)→ rcv_queue(连续就绪待读)。
// 线面全 Bytes(K1 刀1):send 单片段零拷贝共享;帧组装 FixedArray 直写 +
// from_fixedarray;recv 单片段零拷贝直返。

///|
/// 无延迟档最小 RTO(ms)。
pub const RTO_NDL : Int32 = 30

///|
/// 常规档最小 RTO(ms)。
pub const RTO_MIN : Int32 = 100

///|
/// 初始 RTO(ms)。
pub const RTO_DEF : Int32 = 200

///|
/// RTO 上限(ms)。
pub const RTO_MAX : Int32 = 60000

///|
/// 探窗标志:需发 WASK(问对方窗口)。
pub const ASK_SEND : Int32 = 1

///|
/// 探窗标志:需发 WINS(报自己窗口)。
pub const ASK_TELL : Int32 = 2

///|
/// 默认发送窗口。
pub const WND_SND : Int32 = 32

///|
/// 默认接收窗口(必须 >= 最大分片数)。
pub const WND_RCV : Int32 = 128

///|
/// 默认 MTU(字节)。
pub const MTU_DEF : Int32 = 1400

///|
/// 默认 flush 间隔(ms)。
pub const INTERVAL_DEF : Int32 = 100

///|
/// 同段重发达此次数判链路死(state = -1)。
pub const DEADLINK : Int32 = 20

///|
/// 慢启动门限初值。
pub const THRESH_INIT : Int32 = 2

///|
/// 慢启动门限下限。
pub const THRESH_MIN : Int32 = 2

///|
/// 探窗间隔初值(ms)。
pub const PROBE_INIT : Int32 = 5000

///|
/// 探窗间隔上限(ms)。
pub const PROBE_LIMIT : Int32 = 120000

///|
/// 快速重传触发上限次数。
pub const FASTACK_LIMIT : Int32 = 5

///|
/// 32 位回绕有符号差:C `_itimediff(later, earlier) = (IINT32)(later - earlier)`
/// 直译。MoonBit Int 减法同为 32 位回绕,行为等价(测试钉住)。
fn itimediff(later : Int32, earlier : Int32) -> Int32 {
  later - earlier
}

///|
fn imax(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn imin(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn ibound(lower : Int32, middle : Int32, upper : Int32) -> Int32 {
  imin(imax(lower, middle), upper)
}

///|
/// KCP 状态机一实例(一条会话一实例;conv 双端一致)。
pub(all) struct Kcp {
  conv : Int32
  mut mtu : Int32
  mut mss : Int32
  mut snd_wnd : Int32
  mut rcv_wnd : Int32
  mut nodelay : Int32
  mut interval : Int32
  mut fastresend : Int32
  mut fastlimit : Int32
  mut nocwnd : Int32
  mut dead_link : Int32
  mut current : Int32
  mut updated : Int32
  mut ts_flush : Int32
  mut snd_una : Int32
  mut snd_nxt : Int32
  mut rcv_nxt : Int32
  mut ts_probe : Int32
  mut probe_wait : Int32
  mut probe : Int32
  mut rmt_wnd : Int32
  mut cwnd : Int32
  mut incr : Int32
  mut ssthresh : Int32
  mut rx_srtt : Int32
  mut rx_rttval : Int32
  mut rx_rto : Int32
  mut min_rto : Int32
  mut state : Int32
  mut xmit_total : Int32
  mut rcv_accepted : Int32
  mut last_active : Int32
  snd_queue : Array[KcpSegment]
  snd_buf : Array[KcpSegment]
  rcv_buf : Array[KcpSegment]
  rcv_queue : Array[KcpSegment]
  mut acklist : Array[(Int32, Int32)]
}

///|
/// 初始化:ikcp_create 默认值直译。
pub fn Kcp::create(conv : Int32) -> Kcp {
  {
    conv,
    mtu: MTU_DEF,
    mss: MTU_DEF - HEADER_SIZE,
    snd_wnd: WND_SND,
    rcv_wnd: WND_RCV,
    nodelay: 0,
    interval: INTERVAL_DEF,
    fastresend: 0,
    fastlimit: FASTACK_LIMIT,
    nocwnd: 0,
    dead_link: DEADLINK,
    current: 0,
    updated: 0,
    ts_flush: INTERVAL_DEF,
    snd_una: 0,
    snd_nxt: 0,
    rcv_nxt: 0,
    ts_probe: 0,
    probe_wait: 0,
    probe: 0,
    rmt_wnd: WND_RCV,
    cwnd: 0,
    incr: 0,
    ssthresh: THRESH_INIT,
    rx_srtt: 0,
    rx_rttval: 0,
    rx_rto: RTO_DEF,
    min_rto: RTO_MIN,
    state: 0,
    xmit_total: 0,
    rcv_accepted: 0,
    last_active: 0,
    snd_queue: [],
    snd_buf: [],
    rcv_buf: [],
    rcv_queue: [],
    acklist: [],
  }
}

///|
/// nodelay 配置(ikcp_nodelay 直译):nodelay 档位 / interval(ms) /
/// 快速重传触发(0 关)/ 是否关拥塞控制。传 -1 表示该项不动。
pub fn Kcp::set_nodelay(
  self : Kcp,
  nodelay : Int32,
  interval : Int32,
  resend : Int32,
  nc : Int32,
) -> Unit {
  if nodelay >= 0 {
    self.nodelay = nodelay
    if nodelay != 0 {
      self.min_rto = RTO_NDL
    } else {
      self.min_rto = RTO_MIN
    }
  }
  if interval >= 0 {
    let clamped = if interval < 10 {
      10
    } else if interval > 5000 {
      5000
    } else {
      interval
    }
    self.interval = clamped
  }
  if resend >= 0 {
    self.fastresend = resend
  }
  if nc >= 0 {
    self.nocwnd = nc
  }
}

///|
/// 窗口配置(ikcp_wndsize 直译):传 0 表示该项不动;rcv_wnd 有下限钳制
/// `imax(rcvwnd, WND_RCV)`(C 参照同式——收窗永不低于 128,差分门逮出的
/// 直译偏差,2026-10-25)。
pub fn Kcp::set_wnd(self : Kcp, sndwnd : Int32, rcvwnd : Int32) -> Unit {
  if sndwnd > 0 {
    self.snd_wnd = sndwnd
  }
  if rcvwnd > 0 {
    self.rcv_wnd = imax(rcvwnd, WND_RCV)
  }
}

///|
/// MTU 配置(ikcp_setmtu 直译;帧组装即席分配,无预留块)。
pub fn Kcp::set_mtu(self : Kcp, mtu : Int32) -> Int32 {
  if mtu < 50 || mtu < HEADER_SIZE {
    return -1
  }
  self.mtu = mtu
  self.mss = mtu - HEADER_SIZE
  0
}

///|
/// 待确认段总数(应用层流控参考)。
pub fn Kcp::waitsnd(self : Kcp) -> Int32 {
  self.snd_queue.length() + self.snd_buf.length()
}

///|
/// 接收窗口余量(对端通告用)。
fn Kcp::wnd_unused(self : Kcp) -> Int32 {
  if self.rcv_queue.length() < self.rcv_wnd {
    self.rcv_wnd - self.rcv_queue.length()
  } else {
    0
  }
}

///|
/// RTT 平滑(RFC 6298 同式;ikcp_update_ack 直译)。
fn Kcp::update_ack(self : Kcp, rtt : Int32) -> Unit {
  if self.rx_srtt == 0 {
    self.rx_srtt = rtt
    self.rx_rttval = rtt / 2
  } else {
    let mut delta = rtt - self.rx_srtt
    if delta < 0 {
      delta = -delta
    }
    self.rx_rttval = (3 * self.rx_rttval + delta) / 4
    self.rx_srtt = (7 * self.rx_srtt + rtt) / 8
    if self.rx_srtt < 1 {
      self.rx_srtt = 1
    }
  }
  let rto = self.rx_srtt + imax(self.interval, 4 * self.rx_rttval)
  self.rx_rto = ibound(self.min_rto, rto, RTO_MAX)
}

///|
/// snd_una 回缩:snd_buf 队首即新 una;空则追平 snd_nxt。
fn Kcp::shrink_buf(self : Kcp) -> Unit {
  if self.snd_buf.length() > 0 {
    self.snd_una = self.snd_buf[0].sn
  } else {
    self.snd_una = self.snd_nxt
  }
}

///|
/// una 结算:snd_buf 队首连续小于 una 的段全部确认移除。
fn Kcp::parse_una(self : Kcp, una : Int32) -> Unit {
  while self.snd_buf.length() > 0 && itimediff(una, self.snd_buf[0].sn) > 0 {
    let _ = self.snd_buf.remove(0)
  }
}

///|
/// 单 sn 确认:在 snd_buf 找到该 sn 移除(找不到静默)。
fn Kcp::parse_ack(self : Kcp, sn : Int32) -> Unit {
  if itimediff(sn, self.snd_una) < 0 || itimediff(sn, self.snd_nxt) >= 0 {
    return
  }
  let mut i = 0
  while i < self.snd_buf.length() {
    let seg = self.snd_buf[i]
    if sn == seg.sn {
      let _ = self.snd_buf.remove(i)
      break
    }
    if itimediff(sn, seg.sn) < 0 {
      break
    }
    i += 1
  }
}

///|
/// 快速重传记账(FASTACK_CONSERVE 变体,同本仓 C 参照):sn 之后
/// 且 ts 不早于本段 ts 的在途段 fastack 计数 +1。
fn Kcp::parse_fastack(self : Kcp, sn : Int32, ts : Int32) -> Unit {
  if itimediff(sn, self.snd_una) < 0 || itimediff(sn, self.snd_nxt) >= 0 {
    return
  }
  let mut i = 0
  while i < self.snd_buf.length() {
    let seg = self.snd_buf[i]
    if itimediff(sn, seg.sn) < 0 {
      break
    }
    if sn != seg.sn && itimediff(ts, seg.ts) >= 0 {
      seg.fastack += 1
    }
    i += 1
  }
}

///|
/// 记一笔待发 ACK(sn, 对端 ts)。
fn Kcp::ack_push(self : Kcp, sn : Int32, ts : Int32) -> Unit {
  self.acklist.push((sn, ts))
}

///|
/// 收到的 PUSH 段入 rcv_buf(去重 + 按 sn 升序插位),
/// 随后把连续前缀搬入 rcv_queue。
fn Kcp::parse_data(self : Kcp, newseg : KcpSegment) -> Unit {
  let sn = newseg.sn
  let too_far = itimediff(sn, self.rcv_nxt + self.rcv_wnd) >= 0
  let already_seen = itimediff(sn, self.rcv_nxt) < 0
  if too_far || already_seen {
    return
  }
  let mut insert_at = self.rcv_buf.length()
  let mut i = 0
  while i < self.rcv_buf.length() {
    let seg = self.rcv_buf[i]
    if seg.sn == sn {
      return
    }
    if itimediff(sn, seg.sn) < 0 {
      insert_at = i
      break
    }
    i += 1
  }
  self.rcv_buf.insert(insert_at, newseg)
  // 接收守恒账:PUSH 非重复入库即记账——
  // rcv_accepted == rcv_queue.length() + rcv_buf.length()(任意时刻可验)
  self.rcv_accepted += 1
  self.move_rcv_buf_to_queue()
}

///|
/// rcv_buf 连续前缀搬入 rcv_queue(rcv_nxt 推进)。
fn Kcp::move_rcv_buf_to_queue(self : Kcp) -> Unit {
  while self.rcv_buf.length() > 0 {
    let seg = self.rcv_buf[0]
    if seg.sn == self.rcv_nxt && self.rcv_queue.length() < self.rcv_wnd {
      let _ = self.rcv_buf.remove(0)
      self.rcv_queue.push(seg)
      self.rcv_nxt += 1
    } else {
      break
    }
  }
}

///|
/// 输入一报文(可含多段;ikcp_input 直译)。返回 0 / 负错码:
/// -1 长度或 conv 不符;-2 声明 len 超出;-3 非法 cmd。
pub fn Kcp::input(self : Kcp, datagram : Bytes) -> Int32 {
  let prev_una = self.snd_una
  let mut offset = 0
  let mut remaining = datagram.length()
  let mut flag = 0
  let mut maxack = 0
  let mut latest_ts = 0
  if remaining < HEADER_SIZE {
    return -1
  }
  while remaining >= HEADER_SIZE {
    let conv = read_u32(datagram, offset)
    if conv != self.conv {
      return -1
    }
    // 活性戳:合法对端报文即活跃(闲置回收判据;ms 注入面)
    self.last_active = self.current
    let cmd = datagram[offset + 4].to_int()
    let frg = datagram[offset + 5].to_int()
    let wnd = read_u16(datagram, offset + 6)
    let ts = read_u32(datagram, offset + 8)
    let sn = read_u32(datagram, offset + 12)
    let una = read_u32(datagram, offset + 16)
    let len = read_u32(datagram, offset + 20)
    offset += HEADER_SIZE
    remaining -= HEADER_SIZE
    if remaining < len {
      return -2
    }
    if cmd != CMD_PUSH && cmd != CMD_ACK && cmd != CMD_WASK && cmd != CMD_WINS {
      return -3
    }
    self.rmt_wnd = wnd
    self.parse_una(una)
    self.shrink_buf()
    if cmd == CMD_ACK {
      if itimediff(self.current, ts) >= 0 {
        self.update_ack(itimediff(self.current, ts))
      }
      self.parse_ack(sn)
      self.shrink_buf()
      if flag == 0 {
        flag = 1
        maxack = sn
        latest_ts = ts
      } else if itimediff(sn, maxack) > 0 && itimediff(ts, latest_ts) > 0 {
        maxack = sn
        latest_ts = ts
      }
    } else if cmd == CMD_PUSH {
      if itimediff(sn, self.rcv_nxt + self.rcv_wnd) < 0 {
        self.ack_push(sn, ts)
        if itimediff(sn, self.rcv_nxt) >= 0 {
          let base = offset
          let data = Bytes::makei(len, fn(j) { datagram[base + j] })
          let seg = KcpSegment::make(conv, cmd, frg, wnd, ts, sn, una, data)
          self.parse_data(seg)
        }
      }
    } else if cmd == CMD_WASK {
      self.probe = self.probe | ASK_TELL
    } else {
      // CMD_WINS:无需动作
    }
    offset += len
    remaining -= len
  }
  if flag != 0 {
    self.parse_fastack(maxack, latest_ts)
  }
  if itimediff(self.snd_una, prev_una) > 0 {
    let mss = self.mss
    if self.cwnd < self.rmt_wnd {
      if self.cwnd < self.ssthresh {
        self.cwnd += 1
        self.incr += mss
      } else {
        if self.incr < mss {
          self.incr = mss
        }
        self.incr += mss * mss / self.incr + mss / 16
        if (self.cwnd + 1) * mss <= self.incr {
          let safe_mss = if mss > 0 { mss } else { 1 }
          self.cwnd = (self.incr + mss - 1) / safe_mss
        }
      }
      if self.cwnd > self.rmt_wnd {
        self.cwnd = self.rmt_wnd
        self.incr = self.rmt_wnd * mss
      }
    }
  }
  0
}

///|
/// 应用下发一消息(按 mss 分片,frg 倒计;ikcp_send 消息模式直译)。
/// 返回字节数;超接收窗口分片数返回 -2。单片段零拷贝共享载荷。
pub fn Kcp::send(self : Kcp, payload : Bytes) -> Int32 {
  let length = payload.length()
  let mut count = if length <= self.mss {
    1
  } else {
    (length + self.mss - 1) / self.mss
  }
  if count >= WND_RCV {
    return -2
  }
  if count == 0 {
    count = 1
  }
  let mut offset = 0
  let mut remaining = length
  let mut i = 0
  while i < count {
    let size = if remaining > self.mss { self.mss } else { remaining }
    let data = if count == 1 {
      payload
    } else {
      let base = offset
      Bytes::makei(size, fn(j) { payload[base + j] })
    }
    let seg = KcpSegment::make(
      self.conv,
      CMD_PUSH,
      count - i - 1,
      0,
      0,
      0,
      0,
      data,
    )
    self.snd_queue.push(seg)
    offset += size
    remaining -= size
    i += 1
  }
  length
}

///|
/// 下一条消息字节数(碎片合并视角;ikcp_peeksize 直译)。
/// 队列空或碎片未齐返回 -1。
pub fn Kcp::peeksize(self : Kcp) -> Int32 {
  if self.rcv_queue.length() == 0 {
    return -1
  }
  let first = self.rcv_queue[0]
  if first.frg == 0 {
    return first.len
  }
  if self.rcv_queue.length() < first.frg + 1 {
    return -1
  }
  let mut length = 0
  let mut go = true
  let mut i = 0
  while i < self.rcv_queue.length() && go {
    let seg = self.rcv_queue[i]
    length += seg.len
    if seg.frg == 0 {
      go = false
    }
    i += 1
  }
  length
}

///|
/// 应用读一整消息(碎片合并);队列空或碎片未齐返回 None。
/// C ikcp_recv 序:先 peeksize 完整性判(负值拒读),后合并。
/// 单片段零拷贝直返;多片段 FixedArray 直写合并。
pub fn Kcp::recv(self : Kcp) -> Bytes? {
  if self.rcv_queue.length() == 0 {
    return None
  }
  if self.peeksize() < 0 {
    return None
  }
  let recover = self.rcv_queue.length() >= self.rcv_wnd
  let first = self.rcv_queue[0]
  let out = if first.frg == 0 {
    let _ = self.rcv_queue.remove(0)
    first.data
  } else {
    let total = self.peeksize()
    let fa : FixedArray[Byte] = FixedArray::make(total, 0b0)
    let mut off = 0
    let mut fragment = 1
    while self.rcv_queue.length() > 0 && fragment != 0 {
      let seg = self.rcv_queue.remove(0)
      let dl = seg.data.length()
      let mut j = 0
      while j < dl {
        fa[off + j] = seg.data[j]
        j += 1
      }
      off += dl
      fragment = seg.frg
    }
    Bytes::from_array(fa)
  }
  self.move_rcv_buf_to_queue()
  if recover && self.rcv_queue.length() < self.rcv_wnd {
    self.probe = self.probe | ASK_TELL
  }
  Some(out)
}

///|
/// 写 little-endian u16 到帧缓冲。
fn write_le_u16(fa : FixedArray[Byte], offset : Int32, value : Int32) -> Unit {
  fa[offset] = (value & 0xFF).to_byte()
  fa[offset + 1] = ((value >> 8) & 0xFF).to_byte()
}

///|
/// 写 little-endian u32 到帧缓冲。
fn write_le_u32(fa : FixedArray[Byte], offset : Int32, value : Int32) -> Unit {
  fa[offset] = (value & 0xFF).to_byte()
  fa[offset + 1] = ((value >> 8) & 0xFF).to_byte()
  fa[offset + 2] = ((value >> 16) & 0xFF).to_byte()
  fa[offset + 3] = ((value >> 24) & 0xFF).to_byte()
}

///|
/// 帧滚切:当前帧再加 need 字节将超 mtu 时,整帧成形收编、开新帧。
/// pending = 当前帧已攒的段引用;size_box = 当前帧字节数单格。
fn frame_roll(
  pending : Array[KcpSegment],
  size_box : Array[Int32],
  frames : Array[Bytes],
  mtu : Int32,
  need : Int32,
) -> Unit {
  if size_box[0] + need > mtu {
    frames.push(materialize_frame(pending, size_box[0]))
    let mut k = pending.length() - 1
    while k >= 0 {
      let _ = pending.remove(k)
      k -= 1
    }
    size_box[0] = 0
  }
}

///|
/// 帧成形:段引用序列 → 一条 Bytes(FixedArray 直写 + from_fixedarray)。
fn materialize_frame(pending : Array[KcpSegment], total : Int32) -> Bytes {
  let fa : FixedArray[Byte] = FixedArray::make(total, 0b0)
  let mut off = 0
  let mut i = 0
  while i < pending.length() {
    let seg = pending[i]
    write_le_u32(fa, off, seg.conv)
    fa[off + 4] = seg.cmd.to_byte()
    fa[off + 5] = seg.frg.to_byte()
    write_le_u16(fa, off + 6, seg.wnd)
    write_le_u32(fa, off + 8, seg.ts)
    write_le_u32(fa, off + 12, seg.sn)
    write_le_u32(fa, off + 16, seg.una)
    let data_len = seg.data.length()
    write_le_u32(fa, off + 20, data_len)
    let mut j = 0
    while j < data_len {
      fa[off + 24 + j] = seg.data[j]
      j += 1
    }
    off += 24 + data_len
    i += 1
  }
  Bytes::from_array(fa)
}

///|
/// flush(ikcp_flush 直译):ACK 先行 → 探窗 → snd_queue 进窗 →
/// 数据段首发/超时重发/快速重发 → 拥塞窗结算。返回出帧列表。
pub fn Kcp::flush_frames(self : Kcp) -> Array[Bytes] {
  let frames : Array[Bytes] = []
  if self.updated == 0 {
    return frames
  }
  let current = self.current
  let prior_cwnd = self.cwnd
  let pending : Array[KcpSegment] = []
  let size_box : Array[Int32] = [0]
  let seg_wnd = self.wnd_unused()
  // ACK 先行(末笔 ack sn/ts 记下——C flush 复用模板段,探窗帧携带
  // 上一条 ACK 的 sn/ts 残留;精确复刻同形,差分免屏蔽)
  let mut i = 0
  let mut last_ack_sn = 0
  let mut last_ack_ts = 0
  while i < self.acklist.length() {
    let (ack_sn, ack_ts) = self.acklist[i]
    last_ack_sn = ack_sn
    last_ack_ts = ack_ts
    frame_roll(pending, size_box, frames, self.mtu, HEADER_SIZE)
    let ack_seg = KcpSegment::make(
      self.conv,
      CMD_ACK,
      0,
      seg_wnd,
      ack_ts,
      ack_sn,
      self.rcv_nxt,
      Bytes::make(0, 0b0),
    )
    pending.push(ack_seg)
    size_box[0] += HEADER_SIZE
    i += 1
  }
  self.acklist = []
  // 探窗调度(rmt_wnd == 0 时指数退避排班)
  if self.rmt_wnd == 0 {
    if self.probe_wait == 0 {
      self.probe_wait = PROBE_INIT
      self.ts_probe = current + self.probe_wait
    } else if itimediff(current, self.ts_probe) >= 0 {
      if self.probe_wait < PROBE_INIT {
        self.probe_wait = PROBE_INIT
      }
      self.probe_wait += self.probe_wait / 2
      if self.probe_wait > PROBE_LIMIT {
        self.probe_wait = PROBE_LIMIT
      }
      self.ts_probe = current + self.probe_wait
      self.probe = self.probe | ASK_SEND
    }
  } else {
    self.ts_probe = 0
    self.probe_wait = 0
  }
  // 探窗命令(带末笔 ACK 残留 sn/ts,同 C 模板段语义)
  if (self.probe & ASK_SEND) != 0 {
    frame_roll(pending, size_box, frames, self.mtu, HEADER_SIZE)
    let wask = KcpSegment::make(
      self.conv,
      CMD_WASK,
      0,
      seg_wnd,
      last_ack_ts,
      last_ack_sn,
      self.rcv_nxt,
      Bytes::make(0, 0b0),
    )
    pending.push(wask)
    size_box[0] += HEADER_SIZE
  }
  if (self.probe & ASK_TELL) != 0 {
    frame_roll(pending, size_box, frames, self.mtu, HEADER_SIZE)
    let wins = KcpSegment::make(
      self.conv,
      CMD_WINS,
      0,
      seg_wnd,
      last_ack_ts,
      last_ack_sn,
      self.rcv_nxt,
      Bytes::make(0, 0b0),
    )
    pending.push(wins)
    size_box[0] += HEADER_SIZE
  }
  self.probe = 0
  // 生效窗口
  let mut cwnd = imin(self.snd_wnd, self.rmt_wnd)
  if self.nocwnd == 0 {
    cwnd = imin(cwnd, self.cwnd)
  }
  // snd_queue 进窗(sn 现场分配)
  while self.snd_queue.length() > 0 {
    if itimediff(self.snd_nxt, self.snd_una + cwnd) >= 0 {
      break
    }
    let newseg = self.snd_queue.remove(0)
    newseg.conv = self.conv
    newseg.cmd = CMD_PUSH
    newseg.wnd = seg_wnd
    newseg.ts = current
    newseg.sn = self.snd_nxt
    self.snd_nxt += 1
    newseg.una = self.rcv_nxt
    newseg.resendts = current
    newseg.rto = self.rx_rto
    newseg.fastack = 0
    newseg.xmit = 0
    self.snd_buf.push(newseg)
  }
  // 重发参数
  let resent = if self.fastresend > 0 { self.fastresend } else { 0x7FFFFFFF }
  let rtomin = if self.nodelay == 0 { self.rx_rto >> 3 } else { 0 }
  // 数据段:首发 / RTO 超时重发 / fastack 快速重发
  let mut change = 0
  let mut lost = false
  let mut p = 0
  while p < self.snd_buf.length() {
    let segment = self.snd_buf[p]
    let mut needsend = false
    if segment.xmit == 0 {
      needsend = true
      segment.xmit += 1
      segment.rto = self.rx_rto
      segment.resendts = current + segment.rto + rtomin
    } else if itimediff(current, segment.resendts) >= 0 {
      needsend = true
      segment.xmit += 1
      self.xmit_total += 1
      if self.nodelay == 0 {
        segment.rto += imax(segment.rto, self.rx_rto)
      } else {
        let step = if self.nodelay < 2 { segment.rto } else { self.rx_rto }
        segment.rto += step / 2
      }
      segment.resendts = current + segment.rto
      lost = true
    } else if segment.fastack >= resent {
      if segment.xmit <= self.fastlimit || self.fastlimit <= 0 {
        needsend = true
        segment.xmit += 1
        segment.fastack = 0
        segment.resendts = current + segment.rto
        change += 1
      }
    }
    if needsend {
      segment.ts = current
      segment.wnd = seg_wnd
      segment.una = self.rcv_nxt
      frame_roll(pending, size_box, frames, self.mtu, HEADER_SIZE + segment.len)
      pending.push(segment)
      size_box[0] += HEADER_SIZE + segment.len
      if segment.xmit >= self.dead_link {
        self.state = -1
      }
    }
    p += 1
  }
  // 尾帧收编
  if size_box[0] > 0 {
    frames.push(materialize_frame(pending, size_box[0]))
  }
  // 拥塞窗结算:快速重传 → ssthresh 折半 + cwnd 跳到门限+resent
  if change > 0 {
    let inflight = self.snd_nxt - self.snd_una
    self.ssthresh = inflight / 2
    if self.ssthresh < THRESH_MIN {
      self.ssthresh = THRESH_MIN
    }
    self.cwnd = self.ssthresh + resent
    self.incr = self.cwnd * self.mss
  }
  if lost {
    self.ssthresh = prior_cwnd / 2
    if self.ssthresh < THRESH_MIN {
      self.ssthresh = THRESH_MIN
    }
    self.cwnd = 1
    self.incr = self.mss
  }
  if self.cwnd < 1 {
    self.cwnd = 1
    self.incr = self.mss
  }
  frames
}

///|
/// 时间推进(ikcp_update 直译,纯形):到 interval 点则 flush,
/// 返回本次出帧(未到点返回空表)。
pub fn Kcp::update(self : Kcp, current : Int32) -> Array[Bytes] {
  self.current = current
  if self.updated == 0 {
    self.updated = 1
    self.ts_flush = self.current
  }
  let mut slap = itimediff(self.current, self.ts_flush)
  if slap >= 10000 || slap < -10000 {
    self.ts_flush = self.current
    slap = 0
  }
  if slap >= 0 {
    self.ts_flush += self.interval
    if itimediff(self.current, self.ts_flush) >= 0 {
      self.ts_flush = self.current + self.interval
    }
    self.flush_frames()
  } else {
    []
  }
}

///|
/// 观测快照(只读;运维/调试面)。rto_retransmits = C kcp->xmit
/// (超时重传累计;快速重传不计,同参照)。
pub(all) struct KcpStats {
  srtt : Int32
  rttval : Int32
  rto : Int32
  cwnd : Int32
  snd_wnd : Int32
  rmt_wnd : Int32
  in_flight : Int32
  queued : Int32
  rto_retransmits : Int32
  rcv_accepted : Int32
  rcv_queue_len : Int32
  rcv_buf_len : Int32
  last_active : Int32
}

///|
pub fn Kcp::stats(self : Kcp) -> KcpStats {
  {
    srtt: self.rx_srtt,
    rttval: self.rx_rttval,
    rto: self.rx_rto,
    cwnd: self.cwnd,
    snd_wnd: self.snd_wnd,
    rmt_wnd: self.rmt_wnd,
    in_flight: self.snd_buf.length(),
    queued: self.snd_queue.length(),
    rto_retransmits: self.xmit_total,
    rcv_accepted: self.rcv_accepted,
    rcv_queue_len: self.rcv_queue.length(),
    rcv_buf_len: self.rcv_buf.length(),
    last_active: self.last_active,
  }
}

///|
/// 下次该调 update 的时刻(ikcp_check 直译)——省空转用。
pub fn Kcp::check(self : Kcp, current : Int32) -> Int32 {
  if self.updated == 0 {
    return current
  }
  let mut ts_flush = self.ts_flush
  if itimediff(current, ts_flush) >= 10000 ||
    itimediff(current, ts_flush) < -10000 {
    ts_flush = current
  }
  if itimediff(current, ts_flush) >= 0 {
    return current
  }
  let tm_flush = itimediff(ts_flush, current)
  let mut tm_packet = 0x7FFFFFFF
  let mut i = 0
  while i < self.snd_buf.length() {
    let diff = itimediff(self.snd_buf[i].resendts, current)
    if diff <= 0 {
      return current
    }
    if diff < tm_packet {
      tm_packet = diff
    }
    i += 1
  }
  let mut minimal = if tm_packet < tm_flush { tm_packet } else { tm_flush }
  if minimal >= self.interval {
    minimal = self.interval
  }
  current + minimal
}
