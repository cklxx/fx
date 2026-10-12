#!/usr/bin/env node
// T5 assert: report.md has heading, project, version, all items.
import { existsSync, readFileSync } from "node:fs";

const dir = process.argv[2] || ".";
const f = `${dir}/report.md`;
if (!existsSync(f)) {
  console.error("missing report.md");
  process.exit(1);
}
const src = readFileSync(f, "utf8");
const need = ["# Report", "agent-bench", "3", "alpha", "beta", "gamma"];
for (const s of need) {
  if (!src.includes(s)) {
    console.error(`report.md missing: ${s}`);
    process.exit(1);
  }
}
console.log("T5 passed");
