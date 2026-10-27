# moonkcp spec

MoonBit KCP 协议纯实现——零依赖、零 IO、纯状态机。以 UDP 为底座的可靠有序 ARQ 协议,以 10-20% 带宽换 30-40% 延迟降低(相对 TCP)。

## 1. 材料面

| 材料 | 角色 |
|---|---|
| skywind3000/kcp(C 原始实现,.tests/kcp/) | 协议权威参照 + K5 差分对拍基准 |
| RFC 6298(RTT 平滑) | RTO 计算规范 |
| moonbitlang/async socket | K4 UDP adapter 底座 |

## 2. 裁定

| # | 裁定 | 理由 |
|---|---|---|
| D-KCP1 | **纯 MoonBit 实现**(零 FFI、零 IO、纯状态机) | KCP 是 O(1)/段数组操作;四后端全跑;差分测试用 C 参考版独立进程对拍(非 FFI 绑定) |
| D-KCP2 | update 循环 = 纯函数(`update(current) → 帧[]`) | 零时钟、ms 注入——与 lib/realtime hub 同律 |
| D-KCP3 | transport = adapter(async UDP socket 归 K4) | 协议核心零 IO |
| D-KCP4 | 全 Int 制(UInt 弃用) | itimediff 在 Int 32 位回绕下与 C IINT32 位等价(测试钉) |
| D-KCP5 | FASTACK_CONSERVE 变体 | 同本仓 C 参照(.tests/kcp `#define` 开) |
| D-KCP6 | 消息模式 only(stream=0) | 文档编辑场景是消息面;stream 追加模式不在需求面 |

### FEC 层裁定(役 K8,2026-10-27 拍;细目 = .mingspace/fec_ming.md)

| # | 裁定 | 理由 |
|---|---|---|
| D-FEC1 | 层位 = `fec/` 子包,纯形零 IO 零时钟 | 全后端移植;KCP 核心零沾(D-KCP1/2 不破);独立可测 |
| D-FEC2 | 线格式 = 12B 自描述头(group_id u32 / shard_index u8 / k u8 / m u8 / shard_total u8 / payload_len u16 / reserved u16,七字段) | k/m 入头 = 逐组参数:发侧单边拍板、收侧零协商;动态调 k 的 wire 前提一次做对(线格式持久合同) |
| D-FEC3 | 域参数 = 多项式 0x11D、生成元 2 | libfec 惯例;刀1 已知答案向量钉死后永不变 |
| D-FEC4 | 尾组不满 k 不闭组 | 零垫片开销;>m 丢失回落 ARQ |
| D-FEC5 | 线包 = KCP mtu + FEC 头 + 体长前缀(缺省 1400+14=1414 ≤ 路径 MTU 1500);更紧预算的路径,宿主建壳前先 `set_mtu(预算−14)` | 视频路径不赌路径 MTU;KCP mtu 让位 FEC 头 |
| D-FEC6 | 黄金门 = LCG 财产门(k×m 组合任意 ≤m 抹除逐字节相等)+ 带损集成门 | 确定性、无参照依赖、组合全覆盖;KCPDIFF 门原样不动(FEC 在核外) |
| D-FEC7 | 役名 K8 五刀:GF 内核 → RS 编解码 → FEC 帧层 → 会话接线 → 读数归档 | 接 K 系序列 |
| D-FEC8 | 缝 = 参数不是包:`open_group(k~, m~)` 逐组实参 + 宿主侧 `FecPolicy::decide(signals) -> Profile` 端口 | fec/ 纯包永不知「自适应」存在;最薄的缝 |
| D-FEC9 | 大gen 只吃策略词表(档位/阈值/滞回),FEC 数学内核不入 gen 链 | 内核的门 = 财产门;为 gen 而 gen 禁 |
| D-FEC10 | moonkcp 永不 import moonbole;合同 = Profile + 权重文件 + 策略 TOML 三件;策略/学习输出过钳制(k∈[1,kmax], m∈[0,mmax])才上组 | 依赖方向钉死(fixd 同款合同);护栏住端口包装层不住模型 |
| D-FEC11 | FEC 层六边形分层:`MdsCodec` 端口注入(RS = 缺省适配器,数学内核住端口外侧),线格式住 frame 适配器,FecTx/FecRx 纯机器零 IO | 换码 = 换适配器,层机器零改动;效应具名,K9 策略机可拾 |
| D-FEC12 | FEC 线格式词表 = `domain/fec_dialect.toml` 持久合同(kcp_dialect.toml 同律);载荷长双写——头 payload_len 镜像体内 body_len,直通读头、恢复径只认体内 | 12B 头随帧盖戳不可重建,片体随片重建——单一真相在受保护域;镜像一致性有门钉 |

## 3. 役账

| 役 | 范围 | 门 | 状态 |
|---|---|---|---|
| K1 | Segment codec(24B 头编解码) | 全字段往返 + 边界 | **完成**(5/5 绿) |
| K2 | ARQ 核心(input/flush/update/send/recv + 十方法) | 双端交叉注入(乱序/丢包/重复)收敛 | **完成**(并入 K3 门 23/23 绿) |
| K3 | KcpSession(会话壳/背压/消息队列) | 会话 API 往返 + 窗口满背压 + 有损收敛 | **完成**(23/23 绿,2026-10-25) |
| K4 | async UDP adapter(`adapter/` 子包,native 门) | 真内核 UDP 回环双实例 | **完成**(3/3 绿,2026-10-25) |
| K5 | C 差分对拍(`workspace/` 驱动对 + diff_gate.mjs) | 帧转录逐字节等 + 收敛讫数 | **完成**(KCPDIFF:PASS,20%/33% 丢失全同) |
| K6 | KcpServer conv 分离器 | 双 conv 不串线/自动建+护栏+收尸轮回/跨会话碎片合并 | **完成**(26/26 绿,2026-10-25) |
| K7 | KcpUdpHub 组合宿主 | 真 UDP 双客户端不串线/回程/洪泛/清扫/重建 5/5 | **完成**(28/28+5/5 绿,2026-10-25) |
| K8 | FEC 层(RS(k+m),`fec/` 子包,五刀) | 财产门(LCG k×m 组合抹除)+ 带损集成门(FEC 开无 RTO 等待) | **完成**(五刀+quicktest 三面讫,2026-10-27:fec 包 19/19(GF 5+RS 4+帧层 7+quicktest 3)+根包 35/35(含带损门 3)+adapter 5/5,wasm-gc 同绿+deny-warn 净+KCPDIFF:PASS;quicktest 三面=边界(线域 k+m≤255/编解码域 256 两级)/守恒律(LCG 多种子逐组记账精确等式+内容恰好一次)/公平性(窗口逐出 FIFO,片位公平由 MDS 穷举门定理级盖);边界面拨真:读侧域门 256→255(shard_total 单字节,验收等价)+FecTx 构造守卫;读数留证=fec_bench 编码 100/恢复 45/层直通 9 MB/s,RS(10,3)/1200B 片) |

## 4. KCP 协议线格式(24B 头 + data)

```
| conv: u32 | cmd: u8 | frg: u8 | wnd: u16 |
| ts: u32   | sn: u32  | una: u32 | len: u32 |
| data[len]                                  |
```

命令:PUSH=81(数据)/ACK=82(确认)/WASK=83(窗口探测)/WINS=84(窗口回应)

## 5. 坑账(MoonBit 语法,全编译器验证;详 todo.md)

1. 裸 `Array.remove(i)` 语句位 [4139] → `let _ =` 收口
2. 前导 `||`/`&&` 续行 [3002] → 拆短 let / 单行
3. `&` 与 `!=` 优先级 → `(x & M) != 0` 加括号
4. KcpSegment 全字段 mut(C 进窗原地改写线字段,直译同形)
5. `recv` 必须先 peeksize 完整性门(碎片未齐返 None)——会话壳边收边读必炸之点
6. 测试泵不可从 t=0 重启(ts_flush 跨泵续时)——泵带 start_ms 参
7. interval 缺省 100ms = flush 每 10 拍一发;cwnd 线性起步(1,2,3 帧/拍)——集成门要快节奏就 `session.kcp.interval = 10` + 起泵 1000 跳 epoch;RTO 自适应进程内 RTT(可缩到 min_rto 30ms),断言 RTO 等待先实测再钉

## 6. 变更记录

| 版本 | 日期 | 内容 |
|---|---|---|
| v0.13 | 2026-10-27 | **FEC 层全役收官(K8 五刀,35/35 绿)**:RS(GF(2^8)) k+m 组恢复;线格式 12B 自描述头携 k/m(逐组参数——动态调组形缝前置,D-FEC1~12 入 §2,合同 = domain/fec_dialect.toml);六边形 MdsCodec 端口(RS 缺省适配器);FecSession 组合壳 API 透传;门 = LCG 财产门 + 带损集成门(FEC 开 ≤8 拍 vs 关等 RTO 14 拍,KCPDIFF 不动);读数 = fec_bench 留证;自适应策略机(K9 候)判据入 todo |
| v0.12 | 2026-10-25 | 抽仓立户(thy1016/moonkcp 子模块 mbt.kcp,MulanPSL-2.0,发布 mooncakes 0.1.0,tag v0.1.0)+ examples 双示例(真 UDP 实跑)+ 性能役(基线重锚 release + 刀2a FixedArray[Byte]+unsafe_blit:343k→887k pps,对 C 比值 5.1×→2.0-2.3×,收兵) |
| v0.11 | 2026-10-25 | 差分加压(乱序+真停摆,102 帧无屏蔽逐字节全同;逮到 set_wnd 漏 imax 钳制直译偏差)+ K6 KcpServer conv 分离器 + 收尾役三件套(stats 观测面/sweep 闲置回收/K7 KcpUdpHub 组合宿主)+ 域门 cwd 迁移 |
| v0.10 | 2026-10-25 | bak/ 更名 .tests/(C 参照库藏)引用面回灌 |
| v0.9 | 2026-10-25 | **收尾役三件套**:观测面(KcpStats 快照 + xmit_total 超时重传计数 + last_active 活性戳)/ 闲置回收(KcpServer::sweep 宿主注入时钟清扫)/ K7 KcpUdpHub 服务端组合宿主(UdpServer + KcpServer + conv→Addr 表,真 UDP 多客户端回环门:路由不串线/回程/洪泛护栏/闲置清扫/逐后重建);28/28 + 5/5 + KCPDIFF:PASS |
| v0.8 | 2026-10-25 | K6 KcpServer conv 分离器:多会话路由/未知 conv 自动建/洪泛护栏(max_sessions,-4 弃包)/remove 收尸;tick 返 (conv, 帧) 宿主自持 conv→地址映射;26/26 绿 |
| v0.7 | 2026-10-25 | 刀1 Bytes 线格式端到端:send 零拷贝共享/帧 FixedArray 直写组装/input·recv 单趟 makei;KCPDIFF 全同证等价;bench 11.5×(12,072→138,553 pps),与 C 比值 146×→12.6×(茗篇 §2 回灌) |
| v0.6 | 2026-10-25 | 吞吐模式落码(bench 驱动对 + bench.mjs);实测钉账:MoonBit ~12k pps vs C 174 万,诊断主因 = 每字节 push vs memcpy;茗篇两卷(吞吐演进/混合 Ada 演进)落本地卷 |
| v0.5 | 2026-10-25 | **K1-K5 全役收官**。K5 差分对拍:C 参照 vs MoonBit 场景机逐行同构,LCG 带损(20%/高压 33% 一次性)转录逐字节全同,收敛讫数 3253/1475 全达;门 = `node moonkcp/workspace/diff_gate.mjs` |
| v0.4 | 2026-10-25 | K4 async UDP adapter 完成:B=UdpServer(recvfrom 学对端)/A=UdpClient(connected),帧数守恒锁步驱动,真内核回环 3/3 绿 |
| v0.3 | 2026-10-25 | K3 KcpSession 完成(背压/FIFO/判死透传);修 K2 recv 缺 peeksize 完整性门真 bug;探窗 WASK 路径断言钉死;23/23 绿 |
| v0.2 | 2026-10-25 | K2 ARQ 核心全量直译完成:input/flush/update/send/recv 十方法 + 有损收敛门 18/18 绿;裁定 D-KCP4~6;坑账入 spec |
| v0.1 | 2026-10-24 | K1 segment codec + 茗篇设计卷 + K2 骨架 |
