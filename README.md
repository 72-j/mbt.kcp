# MoonKCP

`thy1016/moonkcp` 是 KCP 协议的 MoonBit 纯实现——以 UDP 为底座的可靠有序
ARQ 传输库。协议核心为零 IO、零时钟的纯状态机（毫秒由调用方注入，帧由
调用方搬运），其上提供会话壳（背压 / 碎片合并 / 生命期）、多会话服务端
（conv 分离 / 洪泛护栏 / 闲置回收）与 async UDP 适配器（双端直连与服务端
组合宿主）。实现与 skywind3000/kcp C 参照保持差分对拍逐字节等价。

包结构：`thy1016/moonkcp`（协议核心与会话面）+ `thy1016/moonkcp/adapter`
（async UDP 适配器，native 门）。

## 特性

- 纯状态机核心：`Kcp::create` 到 `check` 全量直译 C 参照——ACK 结算、
  选择性与超时重传、快速重传（FASTACK_CONSERVE 变体）、窗口探针、拥塞
  门限；`update(current)` 返回出帧，无任何隐藏时钟与系统调用。
- 会话壳 `KcpSession`：应用消息按 MSS 分片与碎片合并，`waitsnd` 水位
  背压，FIFO 收件队列，链路判死透传。
- 多会话服务端 `KcpServer`：按报文头 conv 路由，未知会话自动建立，
  `max_sessions` 洪泛护栏，闲置回收（`sweep`，时钟由宿主注入）。
- async UDP 适配器：`KcpUdpPeer`（客户端直连 / 服务端单对端）与
  `KcpUdpHub`（单 socket 多会话组合宿主，conv→地址自学习）。
- 观测面 `Kcp::stats`：RTT 平滑值、RTO、拥塞窗、在途与队列读数、超时
  重传计数、接收守恒账（`rcv_accepted == rcv_queue + rcv_buf` 恒等可验）。
- 差分对拍保证：与 C 参照驱动在同场景机（确定性丢包 + 乱序 + 停摆）下
  帧转录逐字节一致；等价性由门锚定，不靠逐函数目测。

## 安装

确保环境中已安装 MoonBit 工具链，然后在模块根目录：

```bash
moon add thy1016/moonkcp
```

协议核心在用到它的包的 `moon.pkg` `import` 块中添加 `"thy1016/moonkcp"`，
代码内以 `@moonkcp` 前缀使用；UDP 适配器另加
`"thy1016/moonkcp/adapter"`（`@adapter` 前缀，仅 native 后端）。

## 快速上手

### 纯核驱动环（零 IO 零时钟）

宿主持有两个对端实例，每拍注入当前毫秒、搬运帧——传输介质无关：

```moonbit
let sender = @moonkcp.Kcp::create(1)
let receiver = @moonkcp.Kcp::create(1)
sender.set_nodelay(1, 10, 2, 1)   // 低延迟档：interval 10ms / 快速重传 2
let _ = sender.send(Bytes::makei(64, fn(i) { i.to_byte() }))
// 每拍（间隔不大于 interval）：
let frames = sender.update(now_ms)
for frame in frames {
  let _ = receiver.input(frame)
}
match receiver.recv() {
  Some(msg) => // 整消息（碎片已合并）
  None => // 暂无就绪消息
}
```

### 会话壳

```moonbit
let session = @moonkcp.KcpSession::new(1, 128)  // conv 与背压水位
let n = session.send_message(payload)           // 窗口满返 -2（背压拒收）
let code = session.on_datagram(datagram)        // 宿主投递报文，就绪消息入队
let frames = session.tick(now_ms)               // 等价 update，返回待发帧
```

### UDP 适配器

```moonbit
// 服务端：一条 socket 服务多会话，按 conv 路由
let hub = @adapter.KcpUdpHub::listen(128, 1024)
// 客户端：connected UDP，指向服务端地址
let peer = @adapter.KcpUdpPeer::connect_client(7, 128, hub.local_addr())
// 驱动：peer.pump_out(t) 出帧、hub.recv_one() 收报、hub.pump_out(t) 回帧
```

## API 总览

| 入口 | 作用 |
|---|---|
| `Kcp::create` / `set_nodelay` / `set_wnd` / `set_mtu` | 建实例与配置（nodelay 档位、窗口、MTU） |
| `Kcp::send` / `recv` / `peeksize` | 应用消息下发（分片）/ 整消息读取 / 待读长度 |
| `Kcp::input` / `update` / `check` | 报文结算；时间推进并取帧；下次推进时刻 |
| `Kcp::stats` / `waitsnd` / `is_dead` | 观测快照；待确认数；链路判死 |
| `KcpSession::send_message` / `poll_message` | 会话级收发（背压 / FIFO） |
| `KcpServer::on_datagram` / `tick` / `sweep` | conv 路由；全会话推进；闲置回收 |
| `@adapter.KcpUdpPeer` | 双端直连（connected 客户端 / 单对端服务端） |
| `@adapter.KcpUdpHub` | 单 socket 多会话组合宿主 |

## 错误面

- `Kcp::input` 返回码：`-1` 长度不足或 conv 不符；`-2` 声明长度超出报文
  余量；`-3` 非法命令字节。
- `KcpSession::send_message` 返回 `-2` 表示发送窗口满（背压拒收，应用
  侧择时重试）；成功返回接受字节数。
- `KcpServer::on_datagram` 另有 `-4`：会话表满，报文弃置（洪泛护栏）。
- `Kcp::recv` 返回 `None`：队列空或碎片未齐（完整性门，不产半截消息）。

## 设计边界

- 仅消息模式：KCP 的 stream 追加模式不提供；文档同步与控制面按消息
  语义设计。
- 协作式单运行时内使用：非线程安全；跨线程事件须经运行时进入。
- 协议核心全后端可移植；`adapter` 因原生 socket 限 native 后端。
- 吞吐扩展（队列环形化等）按实测判据重估，当前未排期；基准读数见下节。

定位与演进的完整说明见 `spec.md`。

## 测试与验证

```bash
moon test --target native
node workspace/async_watchdog.mjs   # async 门挂起看门狗
node workspace/diff_gate.mjs        # C 参照差分对拍
node workspace/bench.mjs            # 吞吐基准（留证不作门）
```

实测读数（2026-10-25）：

| 面 | 读数 |
|---|---|
| 单元与契约门 | 37 / 37 |
| C 参照差分对拍（20% 确定性丢包 + 乱序 + 停摆，2000 拍） | 102 帧逐字节一致，收敛全达 |
| 真 UDP 回环（双端直连 + 多会话宿主） | 5 / 5 |
| 吞吐基准（64 MB，窗 512） | 约 15 万消息/秒/核（C 参照约 170 万） |

`bak/kcp/` 内为差分对拍的 C 参照（skywind3000/kcp 的 `ikcp.c` / `ikcp.h`
精简 vendored，原件未修改），出处与取舍见 `bak/README.md`。

## 许可证

- 本项目代码采用木兰宽松许可证第 2 版（MulanPSL-2.0，见 `LICENSE`）。
- `bak/kcp/` 内的 C 参照文件按 MIT 许可分发，版权归其原作者；原始文件
  未作语义修改。
- 无背书声明：文中对拍与基准计数是本项目自测结果，不代表 KCP 原作者
  或任何第三方的认证与背书。
