# MoonKCP examples

两个最小可跑示例:多会话 echo 服务端 + 对打客户端,走**真实 UDP 回环**
(127.0.0.1),演示自驱泵集成形状(有界等待 + 回泵,任一端先起都活)。

## 运行

```bash
cd examples

# 终端 1:服务端(打印监听地址,如 127.0.0.1:42218)
moon run server --target native

# 终端 2:客户端(把服务端打印的地址作为参数)
moon run client --target native -- 127.0.0.1:42218
```

预期:客户端 `sent 10, echoed 10`,服务端 `echoed 10 messages` 后双双
退出。

## 这组示例演示什么

- `KcpUdpHub`(服务端):单 socket 多会话,conv→地址自学习,按 conv
  回显,闲置会话可 `sweep` 回收。
- `KcpUdpPeer::connect_client`(客户端):connected UDP,构造即指向
  服务端,recv 只认该对端。
- **自驱泵**:`pump_out(t)` + 有界等待(`@async.with_timeout_opt`)+
  时钟推进——阻塞中等消息时时钟停走会活锁,这是真实时钟集成的关键
  形状(虚拟快钟测试里看不见)。

工作空间 `moon.work` 以 `..` 成员挂本 checkout——示例构建不依赖已发布
版本。

## rt-telnet(中继诊断 CLI)

对 `rt_relay` 中继的手动验收/诊断工具,两模式:

```bash
# 终端 1:中继
moon run ../rt_relay/cmd --target native

# 终端 2:监听者
moon run rt-telnet --target native -- 127.0.0.1:PORT listen bob doc1 12000

# 终端 3:发送者
moon run rt-telnet --target native -- 127.0.0.1:PORT send alice doc1 "hello"
```

alice 的 op 经中继扇出到 bob(排除发送者),bob 以净 JSON 打印。conv 每
次运行自动轮换(时间窗 ⊕ user 哈希)——客户端重启即新端点,中继陈旧
会话闲置老化。
