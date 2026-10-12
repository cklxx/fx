#!/usr/bin/env node
// agent-bench harness: runs fx against sim-server across profiles x tasks.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, cpSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)));
const simBin = join(root, ".tools", "sim-server");
const fxBin = join(root, ".tools", "fx");
const tasksDir = join(root, "tasks");
const replayDir = join(root, "replay");

const args = process.argv.slice(2);
const opt = (name, fb) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fb;
};
const profiles = (opt("--profile", "flash,pro,slow,flaky") || "").split(",").filter(Boolean);
const tasks = (opt("--task", "T1,T2,T3,T4,T5,T6") || "").split(",").filter(Boolean);
const reps = parseInt(opt("--reps", "3"), 10);
const quick = args.includes("--quick");
const outDir = opt("--out", join(root, "results", new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)));

const TASK_IDS = {
  T1: "T1-create-file", T2: "T2-fix-bug", T3: "T3-refactor",
  T4: "T4-multifile", T5: "T5-read-modify", T6: "T6-recover",
};
const SCRIPT_FOR = { T1: "t1-pro.json", T2: "t2-pro.json", T3: "t3-pro.json", T4: "t4-pro.json", T5: "t5-pro.json", T6: "t6-pro.json" };

if (quick) {
  // quick: 1 rep, skip slow
  // (handled below)
}
const effProfiles = quick ? profiles.filter((p) => p !== "slow") : profiles;
const effReps = quick ? 1 : reps;

function startSim(profile, scriptPath, timingLog) {
  const a = ["--profile", profile, "--port", "0", "--timing-log", timingLog];
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
        } catch (e) {
          reject(e);
        }
      }
    });
    child.stderr.on("data", (d) => process.stderr.write(`[sim] ${d}`));
    child.on("error", reject);
  });
}

function makeHome(port) {
  const home = mkdtempSync(join(tmpdir(), "bench-home-"));
  const fxdir = join(home, ".fx");
  mkdirSync(fxdir, { recursive: true, mode: 0o700 });
  const settings = {
    providers: {
      sim: {
        protocol: "openai-chat-completions",
        base_url: `http://127.0.0.1:${port}/v1`,
        auth: { type: "none" },
        model_metadata: {
          "sim-model": { context_window: 32768, max_output_tokens: 2048, supports_tool_use: true },
        },
      },
    },
    provider: "sim",
    models: { sim: "sim-model" },
    permission_mode: "auto",
    permission: { bash: "allow", edit: "allow", read: "allow" },
  };
  writeFileSync(join(fxdir, "settings.json"), JSON.stringify(settings) + "\n", { mode: 0o600 });
  return home;
}

function makeWork(taskId) {
  const work = mkdtempSync(join(tmpdir(), "bench-work-"));
  const seed = join(tasksDir, TASK_IDS[taskId], "seed");
  if (existsSync(seed)) {
    for (const f of readdirSync(seed)) cpSync(join(seed, f), join(work, f));
  }
  return work;
}

function runFx(home, work, prompt, timeoutSec) {
  const t0 = performance.now();
  const child = spawnSync(fxBin,
    ["ask", "--auto", "--json", "--no-save", "--timeout", String(timeoutSec), prompt],
    {
      cwd: work,
      env: { ...process.env, HOME: home, FX_PROVIDER: "sim", FX_MODEL: "sim-model", NO_COLOR: "1" },
      timeout: (timeoutSec + 10) * 1000,
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
    });
  const wallMs = performance.now() - t0;
  let j = null;
  try {
    // stdout may have non-JSON prefix lines ("Writing hello.py"); find last {...} block
    const out = (child.stdout || "").trim();
    const idx = out.lastIndexOf('{"output"');
    if (idx >= 0) j = JSON.parse(out.slice(idx));
  } catch {}
  return { wallMs, json: j, code: child.status, stdout: child.stdout, stderr: child.stderr };
}

function runAssert(taskId, work) {
  const r = spawnSync("node", [join(tasksDir, TASK_IDS[taskId], "assert.mjs"), work], { encoding: "utf8", timeout: 30000 });
  return r.status === 0;
}

function readTiming(timingLog) {
  if (!existsSync(timingLog)) return [];
  return readFileSync(timingLog, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
}

async function runOne(profile, taskId, rep) {
  const scriptPath = join(replayDir, SCRIPT_FOR[taskId]);
  const timingLog = mkdtempSync(join(tmpdir(), "bench-timing-")) + ".jsonl";
  const { child: sim, port } = await startSim(profile, scriptPath, timingLog);
  const home = makeHome(port);
  const work = makeWork(taskId);
  const prompt = readFileSync(join(tasksDir, TASK_IDS[taskId], "prompt.txt"), "utf8").trim();
  try {
    const { wallMs, json } = runFx(home, work, prompt, 120);
    const success = runAssert(taskId, work);
    const timing = readTiming(timingLog);
    const llmRounds = timing.length;
    const tokensOut = timing.reduce((s, r) => s + (r.tokens || 0), 0);
    const modelMs = timing.reduce((s, r) => s + Math.max(0, (r.t_end_ms || 0) - (r.t_start_ms || 0)), 0);
    const apiErrors = timing.filter((r) => r.status !== 200).length;
    // ttftc: first request arrival - process start (approx: first t_start - wall start)
    // We approximate ttftc as time from spawn to first tool request arrival.
    // Simpler: use wallMs - modelMs as harnessMs, ttftc from first timing row.
    let ttftcMs = null;
    if (timing.length > 0) {
      // t_start of first request minus run start ~= time to first LLM call.
      // We don't have absolute run start in timing; use wallMs - sum(gaps) approx.
      // For now: ttftc = wallMs - modelMs - (time after last response). Use first ttft.
      ttftcMs = timing[0].ttft_ms;
    }
    const okTiming = timing.filter((r) => r.status === 200);
    const prefixHitPct = okTiming.length
      ? okTiming.reduce((s, r) => s + (r.prefix_hit_ratio_pct || 0), 0) / okTiming.length
      : null;
    const prefillMs = okTiming.reduce((s, r) => s + (r.prefill_ms || 0), 0);
    return {
      profile, task: taskId, rep,
      wall_ms: Math.round(wallMs),
      ttftc_ms: ttftcMs,
      llm_rounds: llmRounds,
      tokens_out: tokensOut,
      model_ms: modelMs,
      harness_ms: Math.round(wallMs - modelMs),
      api_errors: apiErrors,
      success,
      prefix_hit_pct: prefixHitPct == null ? null : Math.round(prefixHitPct),
      prefill_ms: prefillMs,
      steps: json?.steps ?? null,
      tool_calls: (json?.tool_calls || []).map((t) => t.name),
    };
  } finally {
    sim.kill();
    rmSync(home, { recursive: true, force: true });
    // keep work dir on failure for debugging? No, clean up.
    rmSync(work, { recursive: true, force: true });
    try { rmSync(timingLog); } catch {}
  }
}

function stats(arr) {
  if (!arr.length) return { n: 0 };
  const s = [...arr].sort((a, b) => a - b);
  const mean = s.reduce((a, b) => a + b, 0) / s.length;
  const p50 = s[Math.floor(s.length / 2)];
  return { n: s.length, mean: Math.round(mean), p50: Math.round(p50), min: s[0], max: s[s.length - 1] };
}

async function main() {
  mkdirSync(outDir, { recursive: true });
  const runs = [];
  const total = effProfiles.length * tasks.length * effReps;
  let done = 0;
  for (const profile of effProfiles) {
    for (const task of tasks) {
      for (let rep = 1; rep <= effReps; rep++) {
        done++;
        process.stdout.write(`[${done}/${total}] ${profile} ${task} rep${rep} ... `);
        try {
          const r = await runOne(profile, task, rep);
          runs.push(r);
          console.log(`${r.wall_ms}ms success=${r.success} rounds=${r.llm_rounds}`);
        } catch (e) {
          console.log(`ERROR ${e.message}`);
          runs.push({ profile, task, rep, error: String(e.message), success: false });
        }
      }
    }
  }
  writeFileSync(join(outDir, "runs.jsonl"), runs.map((r) => JSON.stringify(r)).join("\n") + "\n");

  // Summary table: profile x task -> wall_ms stats + success rate
  let md = `# agent-bench results\n\nGenerated: ${new Date().toISOString()}\n`;
  md += `Profiles: ${effProfiles.join(", ")} | Tasks: ${tasks.join(", ")} | Reps: ${effReps}\n\n`;
  md += `| profile | task | n | wall mean (ms) | wall p50 (ms) | harness mean (ms) | rounds | prefix hit% | success |\n`;
  md += `|---|---|---|---|---|---|---|---|---|\n`;
  for (const profile of effProfiles) {
    for (const task of tasks) {
      const rs = runs.filter((r) => r.profile === profile && r.task === task && !r.error);
      const walls = rs.map((r) => r.wall_ms);
      const harn = rs.map((r) => r.harness_ms);
      const rounds = rs.map((r) => r.llm_rounds);
      const hits = rs.map((r) => r.prefix_hit_pct).filter((v) => v != null);
      const st = stats(walls), sh = stats(harn), sr = stats(rounds);
      const succ = rs.filter((r) => r.success).length;
      const hitStr = hits.length ? Math.round(hits.reduce((a, b) => a + b, 0) / hits.length) + "%" : "-";
      md += `| ${profile} | ${task} | ${rs.length} | ${st.mean ?? "-"} | ${st.p50 ?? "-"} | ${sh.mean ?? "-"} | ${sr.mean ?? "-"} | ${hitStr} | ${succ}/${rs.length} |\n`;
    }
  }
  md += `\n## Notes\n\n- wall_ms: spawn to exit. harness_ms: wall_ms - model_ms (model-side SSE time).\n- ttftc_ms: first-chunk latency of first LLM request (from sim timing log).\n`;
  writeFileSync(join(outDir, "summary.md"), md);
  console.log(`\nWrote ${outDir}/summary.md`);
  console.log(md);
}

main().catch((e) => { console.error(e); process.exit(1); });
