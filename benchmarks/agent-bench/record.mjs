#!/usr/bin/env node
// record.mjs: run a task against sim-server with its script, capture the
// actual trajectory (tool call sequence + timing), save to replay/<task>-recorded.json
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync, readdirSync, cpSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)));
const simBin = join(root, ".tools", "sim-server");
const fxBin = join(root, ".tools", "fx");

const args = process.argv.slice(2);
const opt = (n, fb) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : fb; };
const task = opt("--task", "T1");
const profile = opt("--profile", "pro");
const out = opt("--out", join(root, "replay", `${task.toLowerCase()}-recorded.json`));

const TASK_IDS = { T1: "T1-create-file", T2: "T2-fix-bug", T3: "T3-refactor", T4: "T4-multifile", T5: "T5-read-modify", T6: "T6-recover" };
const SCRIPT_FOR = { T1: "t1-pro.json", T2: "t2-pro.json", T3: "t3-pro.json", T4: "t4-pro.json", T5: "t5-pro.json", T6: "t6-pro.json" };

async function main() {
  const scriptPath = join(root, "replay", SCRIPT_FOR[task]);
  const timingLog = mkdtempSync(join(tmpdir(), "rec-")) + ".jsonl";
  const sim = spawn(simBin, ["--profile", profile, "--port", "0", "--timing-log", timingLog, "--script", scriptPath], { stdio: ["ignore", "pipe", "pipe"] });
  const port = await new Promise((res, rej) => {
    let buf = "";
    const t = setTimeout(() => rej(new Error("timeout")), 10000);
    sim.stdout.on("data", (d) => {
      buf += d;
      const nl = buf.indexOf("\n");
      if (nl >= 0) { clearTimeout(t); res(JSON.parse(buf.slice(0, nl)).port); }
    });
  });

  const home = mkdtempSync(join(tmpdir(), "rec-home-"));
  const fxdir = join(home, ".fx");
  (await import("node:fs")).mkdirSync(fxdir, { recursive: true, mode: 0o700 });
  writeFileSync(join(fxdir, "settings.json"), JSON.stringify({
    providers: { sim: { protocol: "openai-chat-completions", base_url: `http://127.0.0.1:${port}/v1`, auth: { type: "none" }, model_metadata: { "sim-model": { context_window: 32768, max_output_tokens: 2048, supports_tool_use: true } } } },
    provider: "sim", models: { sim: "sim-model" },
    permission_mode: "auto", permission: { bash: "allow", edit: "allow", read: "allow" },
  }) + "\n", { mode: 0o600 });

  const work = mkdtempSync(join(tmpdir(), "rec-work-"));
  const seed = join(root, "tasks", TASK_IDS[task], "seed");
  if (existsSync(seed)) for (const f of readdirSync(seed)) cpSync(join(seed, f), join(work, f));
  const prompt = readFileSync(join(root, "tasks", TASK_IDS[task], "prompt.txt"), "utf8").trim();

  const { spawnSync } = await import("node:child_process");
  const r = spawnSync(fxBin, ["ask", "--auto", "--json", "--no-save", "--timeout", "120", prompt],
    { cwd: work, env: { ...process.env, HOME: home, FX_PROVIDER: "sim", FX_MODEL: "sim-model", NO_COLOR: "1" }, encoding: "utf8", timeout: 130000 });
  const out7 = (r.stdout || "").trim();
  const j = JSON.parse(out7.slice(out7.lastIndexOf('{"output"')));

  // assert
  const a = spawnSync("node", [join(root, "tasks", TASK_IDS[task], "assert.mjs"), work], { encoding: "utf8" });
  const passed = a.status === 0;

  const timing = existsSync(timingLog) ? readFileSync(timingLog, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
  const traj = {
    task, profile, fx_version: "v0.0.13",
    recorded_at: new Date().toISOString(),
    steps: (j.tool_calls || []).map((t) => ({ name: t.name, status: t.status })),
    llm_rounds: timing.length,
    assert: passed ? "passed" : "failed",
    script: JSON.parse(readFileSync(scriptPath, "utf8")),
  };
  writeFileSync(out, JSON.stringify(traj, null, 2) + "\n");
  console.log(`recorded ${task}: rounds=${traj.llm_rounds} assert=${traj.assert} -> ${out}`);

  sim.kill();
  rmSync(home, { recursive: true, force: true });
  rmSync(work, { recursive: true, force: true });
  if (!passed) process.exit(1);
}
main().catch((e) => { console.error(e); process.exit(1); });
