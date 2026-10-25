#!/usr/bin/env node
// bench.mjs — 吞吐模式跑批(茗篇 moonbit_throughput_ming.md §3;留证不作门):
// 编 C 参照 bench_driver + 跑 MoonBit bench_driver,读数成对 + 比值,
// 终判锚 KCPBENCH(非门——无 FAIL 语义,只报读数;进程崩则自然非零退出)。
//
// 用法(仓根):node moonkcp/workspace/bench.mjs

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");

const tmp = mkdtempSync(join(tmpdir(), "kcpbench-"));
const cbin = join(tmp, "cbench");
try {
  execFileSync(
    "gcc",
    [
      "-O2",
      "-I",
      "bak/kcp",
      "bak/kcp/ikcp.c",
      "workspace/bench_driver.c",
      "-o",
      cbin,
    ],
    { cwd: root, stdio: "pipe" },
  );
  const cOut = execFileSync(cbin, { encoding: "utf8", maxBuffer: 1024 * 1024 });
  const mOut = execFileSync(
    "moon",
    ["run", "workspace/bench_driver", "--target", "native", "--release"],
    { cwd: root, encoding: "utf8", maxBuffer: 1024 * 1024 },
  );
  const cLine = cOut.split("\n").find((l) => l.startsWith("KCPBENCH:C")) ?? "";
  const mLine = mOut
    .split("\n")
    .find((l) => l.startsWith("KCPBENCH:MOONBIT")) ?? "";
  const cPps = Number(cLine.match(/pps=(\d+)/)?.[1] ?? 0);
  const mPps = Number(mLine.match(/pps=(\d+)/)?.[1] ?? 0);
  const ratio = mPps > 0 ? (cPps / mPps).toFixed(1) : "?";
  console.log(mLine);
  console.log(cLine);
  console.log(`KCPBENCH moonbit=${mPps}pps c=${cPps}pps ratio=${ratio}x (64MB 纯核无损,窗 512,mss 1376)`);
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
