#!/usr/bin/env node
// T6 assert: fix.py prints "recovered: ModuleNotFoundError".
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";

const dir = process.argv[2] || ".";
if (!existsSync(`${dir}/fix.py`)) {
  console.error("missing fix.py");
  process.exit(1);
}
const out = execFileSync("python3", ["fix.py"], { cwd: dir, encoding: "utf8" }).trim();
if (out !== "recovered: ModuleNotFoundError") {
  console.error(`unexpected output: ${JSON.stringify(out)}`);
  process.exit(1);
}
console.log("T6 passed");
