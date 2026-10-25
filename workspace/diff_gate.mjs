#!/usr/bin/env node
// diff_gate.mjs — K5 差分对拍门:同一场景机,C 参照(ikcp.c)vs MoonBit
// (moonkcp/workspace/diff_driver),帧转录逐行 diff,终判 KCPDIFF:PASS/FAIL。
//
// 用法(仓根):node moonkcp/workspace/diff_gate.mjs
// 依赖:gcc(moonkcp/bak/kcp 现场编译参照驱动)、moon(MoonBit 驱动现场跑)。

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");

const tmp = mkdtempSync(join(tmpdir(), "kcpdiff-"));
const cbin = join(tmp, "cdriver");
let verdict = "PASS";
let report = "";

try {
  execFileSync(
    "gcc",
    [
      "-O2",
      "-I",
      "bak/kcp",
      "bak/kcp/ikcp.c",
      "workspace/diff_driver.c",
      "-o",
      cbin,
    ],
    { cwd: root, stdio: "pipe" },
  );
  const cOut = execFileSync(cbin, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  const mOut = execFileSync(
    "moon",
    ["run", "workspace/diff_driver", "--target", "native"],
    { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );

  const cLines = cOut.split("\n").filter((l) => l.length > 0);
  const mLines = mOut
    .split("\n")
    .filter((l) => l.length > 0 && !l.startsWith("Warning") && !l.includes("required through"));

  if (cLines.length !== mLines.length) {
    verdict = "FAIL";
    report = `line count mismatch: c=${cLines.length} moonbit=${mLines.length}`;
  } else {
    const divergences = [];
    for (let i = 0; i < cLines.length; i++) {
      if (cLines[i] !== mLines[i]) {
        divergences.push({ line: i + 1, c: cLines[i], moonbit: mLines[i] });
        if (divergences.length >= 3) break;
      }
    }
    if (divergences.length > 0) {
      verdict = "FAIL";
      report = divergences
        .map((d) => `line ${d.line}:\n  c       = ${d.c}\n  moonbit = ${d.moonbit}`)
        .join("\n");
    }
  }

  // 收敛讫数核:done 行两行,字节计数须全达(A 发 3253 / B 发 1475)
  const doneC = cLines.filter((l) => l.startsWith("done "));
  if (verdict === "PASS") {
    if (doneC[0] !== "done b 7253" || doneC[1] !== "done a 1475") {
      verdict = "FAIL";
      report = `convergence incomplete: ${doneC.join(" / ")}`;
    }
  }

  if (verdict === "PASS") {
    report = `frames=${cLines.length - 2} transcript lines byte-identical, convergence 7253/1475`;
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

console.log(`KCPDIFF:${verdict} ${report}`);
process.exit(verdict === "PASS" ? 0 : 1);
