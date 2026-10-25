# Changelog

本文件面向**使用者**，记录每版对外可见的变化（API / 行为 / 兼容性 / 工程）。
判据与规范细节见 `spec.md`（本仓规范卷）。

## 0.1.0（2026-10-25）

首发版：KCP 协议的 MoonBit 纯实现，与 skywind3000/kcp C 参照保持差分
对拍逐字节等价。

### 对外 API

- **协议核心 `thy1016/moonkcp`**（零 IO 零时钟纯状态机）：
  - `Kcp::create` / `set_nodelay` / `set_wnd` / `set_mtu`（配置面）；
  - `send` / `recv` / `peeksize`（消息模式：MSS 分片 + 碎片合并，
    `recv` 带完整性门不产半截消息）；
  - `input` / `update` / `check`（报文结算 / 时间推进取帧 / 下次推进
    时刻——毫秒全注入，帧由宿主搬运）；
  - `stats` / `waitsnd` / `is_dead`（观测快照与生命期）。
- **会话壳 `KcpSession`**：`send_message`（waitsnd 水位背压，窗口满
  返 `-2`）/ `on_datagram` / `tick` / `poll_message`（FIFO）/ `is_dead`。
- **多会话服务端 `KcpServer`**：按报文头 conv 路由，未知会话自动建立，
  `max_sessions` 洪泛护栏（表满 `-4`），`sweep` 闲置回收。
- **UDP 适配器 `thy1016/moonkcp/adapter`**（native 门，`@adapter` 前缀）：
  - `KcpUdpPeer`：connected 客户端 / 单对端服务端；
  - `KcpUdpHub`：单 socket 多会话组合宿主（conv→地址自学习 + 闲置清扫）。

### 行为与保证

- 线面/载荷面 `FixedArray[Byte]`：发送侧载荷零拷贝共享；批拷走
  `unsafe_blit`（长度受控）。
- 接收守恒账：`rcv_accepted == rcv_queue + rcv_buf` 任意时刻成立。
- 与 C 参照差分对拍：确定性丢包（20%）+ 乱序 + 停摆场景下帧转录
  102 帧逐字节一致；探窗帧 sn/ts 残留语义与 C 模板段精确对齐。
- 收窗下限钳制 `imax(rcvwnd, WND_RCV)` 与 C 参照一致（收窗不低于 128）。

### 性能

- 纯核无损基准（64 MB，窗 512，MSS 1376，release）：约 77-89 万
  消息/秒/核（C 参照约 162-174 万，比值约 2.0-2.3）。

### 错误码

- `input`：`-1` 长度/conv 不符，`-2` 声明长度超余量，`-3` 非法命令；
- `send_message`：`-2` 背压拒收；`KcpServer::on_datagram`：`-4` 会话表满。
