#!/usr/bin/env node
// T1 assert: hello.py exists and prints "hello agent-bench".
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const dir = process.argv[2] || ".";
const f = `${dir}/hello.py`;
if (!existsSync(f)) {
  console.error("missing hello.py");
  process.exit(1);
}
const src = readFileSync(f, "utf8");
if (!src.includes("hello agent-bench")) {
  console.error("hello.py does not contain expected string");
  process.exit(1);
}
const out = execFileSync("python3", [f], { cwd: dir, encoding: "utf8" }).trim();
if (out !== "hello agent-bench") {
  console.error(`unexpected output: ${JSON.stringify(out)}`);
  process.exit(1);
}
console.log("T1 passed");
