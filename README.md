# MoonKCP

`thy1016/moonkcp` 是 KCP 协议的 MoonBit 纯实现：以 UDP 为底座的可靠有序
ARQ 传输库。协议核心为零 IO、零时钟的纯状态机，毫秒由调用方注入，帧由
调用方搬运；实现与 skywind3000/kcp C 参照保持差分对拍逐字节等价。

包结构：`thy1016/moonkcp`（协议核心与会话面）＋ `thy1016/moonkcp/adapter`
（async UDP 适配器，native 门）。

## 特性

- 协议核心：ACK 结算、选择性与超时重传、快速重传、窗口探针、拥塞门限，
  全量直译 C 参照。
- 会话壳 `KcpSession`：消息分片与碎片合并、发送水位背压、FIFO 收件队列。
- 多会话服务端 `KcpServer`：按报文头 conv 路由、未知会话自动建立、
  会话数上限护栏、闲置回收。
- UDP 适配器：`KcpUdpPeer`（双端直连）与 `KcpUdpHub`（单 socket 多会话
  组合宿主）。
- 观测面 `Kcp::stats`：RTT、RTO、拥塞窗、队列读数、接收守恒账。
- 差分对拍：与 C 参照在确定性丢包、乱序、停摆场景下帧转录逐字节一致。

## 安装

确保环境中已安装 MoonBit 工具链，然后在模块根目录：

```bash
moon add thy1016/moonkcp
```

协议核心在消费包的 `moon.pkg` `import` 块中添加 `"thy1016/moonkcp"`，
代码内以 `@moonkcp` 前缀使用；UDP 适配器另加
`"thy1016/moonkcp/adapter"`（`@adapter` 前缀）。

## 快速上手

### 协议核心（零 IO 零时钟）

宿主持有对端实例，按不大于 `interval` 的间隔注入当前毫秒并搬运帧：

```moonbit
let sender = @moonkcp.Kcp::create(1)
let receiver = @moonkcp.Kcp::create(1)
sender.set_nodelay(1, 10, 2, 1)
let _ = sender.send(payload)
let frames = sender.update(now_ms)
for frame in frames {
  let _ = receiver.input(frame)
}
match receiver.recv() {
  Some(msg) => // 整消息（碎片已合并）
  None => () // 暂无就绪消息
}
```

### 会话壳

```moonbit
let session = @moonkcp.KcpSession::new(1, 128)
let n = session.send_message(payload)   // 窗口满返回 -2（背压）
let code = session.on_datagram(datagram)
let frames = session.tick(now_ms)
```

### UDP 适配器

```moonbit
let hub = @adapter.KcpUdpHub::listen(128, 1024)   // 服务端：多会话
let peer = @adapter.KcpUdpPeer::connect_client(7, 128, hub.local_addr())
```

可运行示例见 `examples/`（echo 服务端与对打客户端）。

## API 总览

| 入口 | 作用 |
|---|---|
| `Kcp::create` / `set_nodelay` / `set_wnd` / `set_mtu` | 实例创建与配置 |
| `Kcp::send` / `recv` / `peeksize` | 消息下发（分片）、整消息读取、待读长度 |
| `Kcp::input` / `update` / `check` | 报文结算、时间推进取帧、下次推进时刻 |
| `Kcp::stats` / `waitsnd` / `is_dead` | 观测快照、待确认数、链路判死 |
| `KcpSession::send_message` / `poll_message` | 会话级收发（背压 / FIFO） |
| `KcpServer::on_datagram` / `tick` / `sweep` | conv 路由、全会话推进、闲置回收 |
| `@adapter.KcpUdpPeer` | 双端直连适配器 |
| `@adapter.KcpUdpHub` | 单 socket 多会话组合宿主 |

## 错误面

- `Kcp::input`：`-1` 长度不足或 conv 不符；`-2` 声明长度超出报文余量；
  `-3` 非法命令字节。
- `KcpSession::send_message`：`-2` 发送窗口满（背压拒收）；成功返回
  接受字节数。
- `KcpServer::on_datagram`：`-4` 会话表满，报文弃置。
- `Kcp::recv`：`None` 表示队列为空或碎片未齐。

## 设计边界

- 仅消息模式；KCP 的 stream 追加模式不提供。
- 协作式单运行时内使用，非线程安全；跨线程事件须经运行时进入。
- 协议核心全后端可移植；适配器因原生 socket 限 native 后端。
- 吞吐扩展按实测判据重估，当前未排期。

定位与演进的完整说明见 `spec.md`。

## 测试与验证

```bash
moon test --target native
node workspace/async_watchdog.mjs
node workspace/diff_gate.mjs
node workspace/bench.mjs
```

实测读数（2026-10-25）：

| 面 | 读数 |
|---|---|
| 单元与契约门 | 37 / 37 |
| C 参照差分对拍（20% 确定性丢包、乱序、停摆） | 102 帧逐字节一致 |
| 真 UDP 回环（双端直连与多会话宿主） | 5 / 5 |
| 纯核吞吐基准（64 MB，窗 512，release） | 约 77–89 万消息/秒/核 |

`.tests/kcp/` 内为差分对拍所用 C 参照（skywind3000/kcp 的 `ikcp.c` /
`ikcp.h` 精简收录，原件未修改），出处见 `.tests/README.md`。

## 许可证

- 本项目代码采用木兰宽松许可证第 2 版（MulanPSL-2.0，见 `LICENSE`）。
- `.tests/kcp/` 内 C 参照文件按 MIT 许可分发，版权归其原作者。
- 无背书声明：文中对拍与基准计数为本项目自测结果，不构成任何第三方
  的认证或背书。
