#!/usr/bin/env node
// replay.mjs: replay a recorded trajectory with sim-server in script mode,
// verify tool-call sequence matches and assert passes.
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync, readdirSync, cpSync, existsSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)));
const simBin = join(root, ".tools", "sim-server");
const fxBin = join(root, ".tools", "fx");

const args = process.argv.slice(2);
const opt = (n, fb) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : fb; };
const trajPath = opt("--trajectory", null);
const profile = opt("--profile", "zero");
const verify = args.includes("--verify");

if (!trajPath) { console.error("usage: replay.mjs --trajectory <file> [--profile zero] [--verify]"); process.exit(2); }

const TASK_IDS = { T1: "T1-create-file", T2: "T2-fix-bug", T3: "T3-refactor", T4: "T4-multifile", T5: "T5-read-modify", T6: "T6-recover" };

async function main() {
  const traj = JSON.parse(readFileSync(trajPath, "utf8"));
  const task = traj.task;
  // write the embedded script to a temp file for sim-server
  const scriptTmp = mkdtempSync(join(tmpdir(), "replay-")) + ".json";
  writeFileSync(scriptTmp, JSON.stringify(traj.script));

  const timingLog = mkdtempSync(join(tmpdir(), "replay-")) + ".jsonl";
  const sim = spawn(simBin, ["--profile", profile, "--port", "0", "--timing-log", timingLog, "--script", scriptTmp], { stdio: ["ignore", "pipe", "pipe"] });
  const port = await new Promise((res, rej) => {
    let buf = "";
    const t = setTimeout(() => rej(new Error("timeout")), 10000);
    sim.stdout.on("data", (d) => {
      buf += d;
      const nl = buf.indexOf("\n");
      if (nl >= 0) { clearTimeout(t); res(JSON.parse(buf.slice(0, nl)).port); }
    });
  });

  const home = mkdtempSync(join(tmpdir(), "replay-home-"));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    providers: { sim: { protocol: "openai-chat-completions", base_url: `http://127.0.0.1:${port}/v1`, auth: { type: "none" }, model_metadata: { "sim-model": { context_window: 32768, max_output_tokens: 2048, supports_tool_use: true } } } },
    provider: "sim", models: { sim: "sim-model" },
    permission_mode: "auto", permission: { bash: "allow", edit: "allow", read: "allow" },
  }) + "\n", { mode: 0o600 });

  const work = mkdtempSync(join(tmpdir(), "replay-work-"));
  const seed = join(root, "tasks", TASK_IDS[task], "seed");
  if (existsSync(seed)) for (const f of readdirSync(seed)) cpSync(join(seed, f), join(work, f));
  const prompt = readFileSync(join(root, "tasks", TASK_IDS[task], "prompt.txt"), "utf8").trim();

  const t0 = performance.now();
  const r = spawnSync(fxBin, ["ask", "--auto", "--json", "--no-save", "--timeout", "120", prompt],
    { cwd: work, env: { ...process.env, HOME: home, FX_PROVIDER: "sim", FX_MODEL: "sim-model", NO_COLOR: "1" }, encoding: "utf8", timeout: 130000 });
  const wallMs = Math.round(performance.now() - t0);
  const out7 = (r.stdout || "").trim();
  const j = JSON.parse(out7.slice(out7.lastIndexOf('{"output"')));

  const a = spawnSync("node", [join(root, "tasks", TASK_IDS[task], "assert.mjs"), work], { encoding: "utf8" });
  const passed = a.status === 0;

  let seqOk = true;
  if (verify) {
    const got = (j.tool_calls || []).map((t) => t.name);
    const want = (traj.steps || []).map((s) => s.name);
    seqOk = JSON.stringify(got) === JSON.stringify(want);
    if (!seqOk) console.error(`sequence mismatch:\n got: ${JSON.stringify(got)}\nwant: ${JSON.stringify(want)}`);
  }

  const timing = existsSync(timingLog) ? readFileSync(timingLog, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
  const modelMs = timing.reduce((s, x) => s + Math.max(0, (x.t_end_ms || 0) - (x.t_start_ms || 0)), 0);

  console.log(JSON.stringify({ task, profile, wall_ms: wallMs, harness_ms: Math.round(wallMs - modelMs), rounds: timing.length, assert: passed ? "passed" : "failed", sequence: seqOk ? "match" : "MISMATCH" }));
  sim.kill();
  rmSync(home, { recursive: true, force: true });
  rmSync(work, { recursive: true, force: true });
  if (!passed || !seqOk) process.exit(1);
}
main().catch((e) => { console.error(e); process.exit(1); });
