#!/usr/bin/env node
// async_watchdog.mjs — async 测试挂起看门狗(借镜 fuwaroid:
// "饿死安全网是看门狗,不是测试框架")。
// 逐文件带时限跑 adapter 的 async 测试;挂起 = 超时杀进程 + HANG 判,
// 不拖死整条门链。终判锚 KCPWATCH:PASS / KCPWATCH:HANG:<file>。
//
// 用法(仓根):node moonkcp/workspace/async_watchdog.mjs [timeout_ms_each=60000]

import { execFileSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const eachTimeoutMs = Number(process.argv[2] ?? 60000);

const files = [
  "adapter/kcp_udp_test.mbt",
  "adapter/kcp_hub_test.mbt",
];

let hangFile = null;
const lines = [];
for (const file of files) {
  try {
    const out = execFileSync(
      "moon",
      ["test", file, "--target", "native"],
      { cwd: root, encoding: "utf8", timeout: eachTimeoutMs, maxBuffer: 8 * 1024 * 1024 },
    );
    const total = out.match(/Total tests: (\d+), passed: (\d+), failed: (\d+)/);
    if (total) {
      lines.push(`PASS ${file} ${total[2]}/${total[1]}`);
    } else {
      lines.push(`PASS ${file} (no summary parsed)`);
    }
  } catch (err) {
    if (err.killed === true) {
      hangFile = file;
      lines.push(`HANG ${file} (>${eachTimeoutMs}ms, killed)`);
      break;
    }
    // 真失败(非挂起):如实报失败并停
    const tail = String(err.stdout ?? "").split("\n").filter((l) => l.includes("failed") || l.includes("FAILED")).pop() ?? err.message;
    lines.push(`FAIL ${file} ${tail.trim()}`);
    hangFile = file;
    break;
  }
}

for (const line of lines) {
  console.log(`[KCPWATCH] ${line}`);
}
if (hangFile !== null) {
  console.log(`KCPWATCH:HANG:${hangFile}`);
  process.exit(1);
}
console.log("KCPWATCH:PASS");
