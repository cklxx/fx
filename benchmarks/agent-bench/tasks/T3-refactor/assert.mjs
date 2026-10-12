#!/usr/bin/env node
// T3 assert: output unchanged, function count <= 4, report() exists.
import { execFileSync, execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const dir = process.argv[2] || ".";
const expected = "circle: 12.56636\nsquare: 9\ntriangle: 10.0\n";
const out = execFileSync("python3", ["long.py"], { cwd: dir, encoding: "utf8" });
if (out !== expected) {
  console.error(`output changed:\n${JSON.stringify(out)}\nexpected:\n${JSON.stringify(expected)}`);
  process.exit(1);
}
const src = readFileSync(`${dir}/long.py`, "utf8");
const fns = (src.match(/^def /gm) || []).length;
if (fns > 4) {
  console.error(`too many functions: ${fns}`);
  process.exit(1);
}
if (!src.includes("def report(")) {
  console.error("missing report() helper");
  process.exit(1);
}
console.log("T3 passed");
