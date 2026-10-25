# .tests/kcp — C 参照(vendored)

- 源:skywind3000/kcp(MIT License,本目录 LICENSE 为其原文)
- 用途:K5 差分对拍参照——`workspace/diff_gate.mjs` / `workspace/bench.mjs`
  现场编译 `ikcp.c` 驱动参照进程,与 MoonBit 实现逐字节对帧
- 内容:仅 `ikcp.c` / `ikcp.h` / `LICENSE`(差分门的最小活料);
  上游全量见 github.com/skywind3000/kcp
- 协议常量与语义以本目录为权威参照;FASTACK_CONSERVE 在 ikcp.c 顶部
  `#define` 开启(MoonBit 侧同变体,已对齐)
