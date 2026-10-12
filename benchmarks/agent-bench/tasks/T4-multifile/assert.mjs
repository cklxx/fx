#!/usr/bin/env node
// T4 assert: util.py, logic.py, main.py exist and python3 main.py prints "hi bench".
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";

const dir = process.argv[2] || ".";
for (const f of ["util.py", "logic.py", "main.py"]) {
  if (!existsSync(`${dir}/${f}`)) {
    console.error(`missing ${f}`);
    process.exit(1);
  }
}
const out = execFileSync("python3", ["main.py"], { cwd: dir, encoding: "utf8" }).trim();
if (out !== "hi bench") {
  console.error(`unexpected output: ${JSON.stringify(out)}`);
  process.exit(1);
}
console.log("T4 passed");
