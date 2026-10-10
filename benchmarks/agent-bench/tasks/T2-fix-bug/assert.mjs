#!/usr/bin/env node
// T2 assert: python3 buggy.py exits 0.
import { execFileSync } from "node:child_process";

const dir = process.argv[2] || ".";
try {
  const out = execFileSync("python3", ["buggy.py"], { cwd: dir, encoding: "utf8" });
  if (!out.includes("all assertions passed")) {
    console.error("assertions text missing");
    process.exit(1);
  }
  console.log("T2 passed");
} catch (e) {
  console.error("buggy.py failed:", e.message);
  process.exit(1);
}
