# moonkcp 茗空间 — KCP 协议 MoonBit 实现

> 定位:独立模块。KCP = 纯用户态可靠有序 ARQ 协议(UDP 底座)。
> 六边形架构:**协议核心零 IO/零时钟**,端口向外,适配器在边界。

## 架构图(六边形)

```text
┌───────────────── 外部世界 ─────────────────┐
│           UDP socket / IP 网络              │
└─────────────────┬──────────────────────────┘
                  │ Bytes(编码后的 segment 帧)
        ┌─────────┴──────────┐
        │   transport port   │  ← 端口:send_frame(Bytes)/recv_frame()→Bytes
        │  (adapter: async   │
        │   UDP socket)      │
        └─────────┬──────────┘
                  │
        ┌─────────┴──────────┐
        │   KCP 协议核心      │  ← 纯状态机:segment codec + ARQ + 窗口 + 拥塞
        │   (零 IO/零时钟)   │     update(current_ms) → 输出帧
        └────────────────────┘
```

## 不变式

- 协议核心 **零 IO、零时钟、零宿主词**——ms 由调用方注入
- `update(current_ms)` 纯函数:输入时间戳,输出待写字节帧
- transport = adapter,可替换(UDP/SSE 模拟/内存管道/loopback 测试)
- 大 gen:协议词表(domain/kcp_dialect.toml)→ gen 生成 codec,协议即数据

## 目录

| 路径 | 职责 |
|---|---|
| `domain/kcp_dialect.toml` | 协议词表(TOML 数据面;segment 字段布局/命令常量/默认值) |
| `gen/main.mbt` | codec 生成器(读 TOML → 生成编解码 MoonBit 代码) |
| `segment.mbt` | Segment 结构 + 编解码(24B 头 + data) |
| `kcp.mbt` | KCP 状态机(snd_buf/rcv_buf/acklist/重传/拥塞) |
| `session.mbt` | KcpSession(send/recv 碎片化 + 窗口 + update 循环) |
| `spec.md` | 唯一追踪面 |
| `todo.md` | 役账(K1-K5) |
| `.mingspace/` | 茗空间(设计卷) |

## 役账

| 役 | 状态 |
|---|---|
| K1 Segment codec | **现役** |
| K2 ARQ 核心 | 待开 |
| K3 KcpSession | 待开 |
| K4 UDP adapter | 待开 |
| K5 C 差分对拍 | 待开 |
