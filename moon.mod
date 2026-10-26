name = "thy1016/moonkcp"

version = "0.1.0"

readme = "README.md"

repository = "https://gitlink.org.cn/thy7/mbt.kcp"

license = "MulanPSL-2.0"

keywords = [ "kcp", "udp", "arq", "reliable-transport", "concurrency" ]

description = "MoonKCP — KCP 协议 MoonBit 纯实现（零 IO 零时钟纯状态机 ARQ 核心 + 会话壳 + async UDP adapter + 多会话服务端;C 参照差分对拍逐字节等价）"

import {
  "moonbitlang/async@0.22.4",
  "cc06b/mooncry@0.95.0",
}
