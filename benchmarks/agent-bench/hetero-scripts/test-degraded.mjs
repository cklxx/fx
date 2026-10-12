#!/usr/bin/env node
// Heterogeneous decomposition: quality simulation.
// Tests what happens when the "small model" (executor) makes mistakes.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, cpSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = "/home/hatch/workspace/fx-fork/benchmarks/agent-bench";
const simBin = join(root, ".tools", "sim-server");
const fxBin = join(root, ".tools", "fx");
const tasksDir = join(root, "tasks");

function startSim(profile, scriptPath) {
  const a = ["--profile", profile, "--port", "0"];
  if (scriptPath) a.push("--script", scriptPath);
  const child = spawn(simBin, a, { stdio: ["ignore", "pipe", "pipe"] });
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("sim-server start timeout")), 10000);
    child.stdout.on("data", (d) => {
      buf += d.toString();
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        clearTimeout(timer);
        try {
          const port = JSON.parse(buf.slice(0, nl)).port;
          resolve({ child, port });
        } catch (e) { reject(e); }
      }
    });
    child.stderr.on("data", (d) => process.stderr.write(`[sim] ${d}`));
    child.on("error", reject);
  });
}

function makeHome(port) {
  const home = mkdtempSync(join(tmpdir(), "hetero-home-"));
  const fxdir = join(home, ".fx");
  mkdirSync(fxdir, { recursive: true, mode: 0o700 });
  const settings = {
    providers: { sim: {
      protocol: "openai-chat-completions",
      base_url: `http://127.0.0.1:${port}/v1`,
      auth: { type: "none" },
      model_metadata: { "sim-model": { context_window: 32768, max_output_tokens: 2048, supports_tool_use: true } },
    }},
    provider: "sim",
    models: { sim: "sim-model" },
    permission_mode: "auto",
    permission: { bash: "allow", edit: "allow", read: "allow" },
  };
  writeFileSync(join(fxdir, "settings.json"), JSON.stringify(settings) + "\n", { mode: 0o600 });
  return home;
}

function makeWork(taskId) {
  const work = mkdtempSync(join(tmpdir(), "hetero-work-"));
  const seed = join(tasksDir, taskId, "seed");
  if (existsSync(seed)) {
    for (const f of readdirSync(seed)) cpSync(join(seed, f), join(work, f));
  }
  return work;
}

async function runCase(name, taskId, scriptPath, profile) {
  const { child: sim, port } = await startSim(profile, scriptPath);
  const home = makeHome(port);
  const work = makeWork(taskId);
  const prompt = readFileSync(join(tasksDir, taskId, "prompt.txt"), "utf8").trim();
  try {
    const t0 = performance.now();
    const child = spawnSync(fxBin,
      ["ask", "--auto", "--json", "--no-save", "--timeout", "120", prompt],
      { cwd: work, env: { ...process.env, HOME: home, FX_PROVIDER: "sim", FX_MODEL: "sim-model", NO_COLOR: "1" },
        timeout: 130000, encoding: "utf8", maxBuffer: 16*1024*1024 });
    const wallMs = Math.round(performance.now() - t0);
    const assert = spawnSync("node", [join(tasksDir, taskId, "assert.mjs"), work], { encoding: "utf8", timeout: 30000 });
    const success = assert.status === 0;
    console.log(`${name}: wall=${wallMs}ms success=${success} ${success ? "" : "| " + (assert.stderr || "").trim().split("\n")[0]}`);
    return { name, wallMs, success };
  } finally {
    sim.kill();
    rmSync(home, { recursive: true, force: true });
    rmSync(work, { recursive: true, force: true });
  }
}

const results = [];
// Baseline: correct script, pro profile
results.push(await runCase("T5-baseline-pro", "T5-read-modify", join(root, "replay/t5-pro.json"), "pro"));
// Degraded: missing item (small model mistake)
results.push(await runCase("T5-degraded-missing-item", "T5-read-modify", "/tmp/hetero/t5-degraded-missing-item.json", "pro"));
// Degraded: wrong path
results.push(await runCase("T5-degraded-wrong-path", "T5-read-modify", "/tmp/hetero/t5-degraded-wrong-path.json", "pro"));
// Baseline T6
results.push(await runCase("T6-baseline-pro", "T6-recover", join(root, "replay/t6-pro.json"), "pro"));

console.log("\nDone.");
