#!/usr/bin/env node
// e2e.mjs: end-to-end phase-by-phase latency measurement for agent-bench.
//
// Phase chain (all timestamps in epoch ms):
//   P0 startup        = first t_start_ms        - spawn_epoch
//   P1a req ingress   = t_body_read_ms          - t_start_ms        (per request)
//   P1b TTFT          = t_first_byte_ms         - t_body_read_ms    (per request)
//   P1c headers       = t_headers_sent_ms       - t_first_chunk_ms  (per request, ~0)
//   P2  streaming     = t_last_byte_ms          - t_first_byte_ms   (per request, TPOT)
//   P2b resp teardown = t_end_ms                - t_last_byte_ms    (per request)
//   P3  inter-round   = t_start_ms[i+1]         - t_end_ms[i]       (client: parse+tool+build+send)
//   P4  teardown      = exit_epoch              - last t_end_ms     (render+exit)
//
// Usage: node e2e.mjs --profile flash,pro,slow --task T1,T4,T6 --reps 3 --out results/e2e-001
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
const profiles = (opt("--profile", "flash,pro,slow") || "").split(",").filter(Boolean);
const profileJson = opt("--profile-json", null);
const dumpBodies = opt("--dump-bodies", null);
const tasks = (opt("--task", "T1") || "").split(",").filter(Boolean);
const reps = parseInt(opt("--reps", "3"), 10);
const outDir = opt("--out", join(root, "results", "e2e-" + new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)));

const TASK_IDS = {
  T1: "T1-create-file", T2: "T2-fix-bug", T3: "T3-refactor",
  T4: "T4-multifile", T5: "T5-read-modify", T6: "T6-recover",
};
const SCRIPT_FOR = { T1: "t1-pro.json", T2: "t2-pro.json", T3: "t3-pro.json", T4: "t4-pro.json", T5: "t5-pro.json", T6: "t6-pro.json" };

function startSim(profile, scriptPath, timingLog) {
  const a = profileJson
    ? ["--profile-json", profileJson, "--port", "0", "--timing-log", timingLog, "--jitter", "0"]
    : ["--profile", profile, "--port", "0", "--timing-log", timingLog, "--jitter", "0"];
  if (scriptPath) a.push("--script", scriptPath);
  if (dumpBodies) a.push("--dump-bodies", dumpBodies);
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
          resolve({ child, port: JSON.parse(buf.slice(0, nl)).port });
        } catch (e) { reject(e); }
      }
    });
    child.stderr.on("data", (d) => process.stderr.write(`[sim] ${d}`));
    child.on("error", reject);
  });
}

function makeHome(port) {
  const home = mkdtempSync(join(tmpdir(), "e2e-home-"));
  const fxdir = join(home, ".fx");
  mkdirSync(fxdir, { recursive: true, mode: 0o700 });
  writeFileSync(join(fxdir, "settings.json"), JSON.stringify({
    providers: { sim: {
      protocol: "openai-chat-completions",
      base_url: `http://127.0.0.1:${port}/v1`,
      auth: { type: "none" },
      model_metadata: { "sim-model": { context_window: 32768, max_output_tokens: 2048, supports_tool_use: true } },
    }},
    provider: "sim", models: { sim: "sim-model" },
    permission_mode: "auto", permission: { bash: "allow", edit: "allow", read: "allow" },
  }) + "\n", { mode: 0o600 });
  return home;
}

function makeWork(taskId) {
  const work = mkdtempSync(join(tmpdir(), "e2e-work-"));
  const seed = join(tasksDir, TASK_IDS[taskId], "seed");
  if (existsSync(seed)) for (const f of readdirSync(seed)) cpSync(join(seed, f), join(work, f));
  return work;
}

async function runOne(profile, taskId, rep) {
  const scriptPath = join(replayDir, SCRIPT_FOR[taskId]);
  const timingLog = mkdtempSync(join(tmpdir(), "e2e-timing-")) + ".jsonl";
  const { child: sim, port } = await startSim(profile, scriptPath, timingLog);
  const home = makeHome(port);
  const work = makeWork(taskId);
  const prompt = readFileSync(join(tasksDir, TASK_IDS[taskId], "prompt.txt"), "utf8").trim();
  try {
    const spawnEpoch = Date.now();
    const child = spawnSync(fxBin,
      ["ask", "--auto", "--json", "--no-save", "--timeout", "120", prompt],
      { cwd: work, env: { ...process.env, HOME: home, FX_PROVIDER: "sim", FX_MODEL: "sim-model", NO_COLOR: "1" },
        timeout: 130000, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
    const exitEpoch = Date.now();
    const wallMs = exitEpoch - spawnEpoch;

    let j = null;
    try {
      const out = (child.stdout || "").trim();
      const idx = out.lastIndexOf('{"output"');
      if (idx >= 0) j = JSON.parse(out.slice(idx));
    } catch {}

    const timing = existsSync(timingLog)
      ? readFileSync(timingLog, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l))
      : [];
    const ok = timing.filter((r) => r.status === 200);

    // Phase decomposition
    const phases = { p0_startup: null, p4_teardown: null, requests: [] };
    if (ok.length > 0) {
      phases.p0_startup = ok[0].t_start_ms - spawnEpoch;
      phases.p4_teardown = exitEpoch - ok[ok.length - 1].t_end_ms;
      for (let i = 0; i < ok.length; i++) {
        const r = ok[i];
        const req = {
          seq: r.req_seq,
          p1a_ingress: (r.t_body_read_ms ?? r.t_start_ms) - r.t_start_ms,
          p1b_ttft: (r.t_first_byte_ms ?? r.t_first_chunk_ms) - (r.t_body_read_ms ?? r.t_start_ms),
          p1c_headers: r.t_headers_sent_ms != null && r.t_first_chunk_ms != null ? r.t_headers_sent_ms - r.t_first_chunk_ms : null,
          p2_streaming: r.t_last_byte_ms != null && r.t_first_byte_ms != null ? r.t_last_byte_ms - r.t_first_byte_ms : null,
          p2b_resp_teardown: r.t_end_ms - (r.t_last_byte_ms ?? r.t_first_chunk_ms),
          p3_gap_next: null,
          tokens: r.tokens,
          ttft_legacy: r.ttft_ms,
          prompt_tokens: r.prompt_tokens ?? null,
          prefix_hit_tokens: r.prefix_hit_tokens ?? null,
          prefix_hit_ratio_pct: r.prefix_hit_ratio_pct ?? null,
          prefill_ms: r.prefill_ms ?? null,
        };
        if (i + 1 < ok.length) req.p3_gap_next = ok[i + 1].t_start_ms - r.t_end_ms;
        phases.requests.push(req);
      }
    }
    const assertR = spawnSync("node", [join(tasksDir, TASK_IDS[taskId], "assert.mjs"), work], { encoding: "utf8", timeout: 30000 });
    return {
      profile, task: taskId, rep, wall_ms: wallMs,
      spawn_epoch: spawnEpoch, exit_epoch: exitEpoch,
      llm_rounds: ok.length, success: assertR.status === 0,
      tool_calls: (j?.tool_calls || []).map((t) => t.name),
      phases,
    };
  } finally {
    sim.kill();
    rmSync(home, { recursive: true, force: true });
    rmSync(work, { recursive: true, force: true });
    try { rmSync(timingLog); } catch {}
  }
}

async function main() {
  mkdirSync(outDir, { recursive: true });
  const runs = [];
  // With --profile-json, label runs by the JSON basename (e.g. "hit-90").
  const effProfiles = profileJson
    ? [profileJson.split("/").pop().replace(/\.json$/, "")]
    : profiles;
  const total = effProfiles.length * tasks.length * reps;
  let done = 0;
  for (const profile of effProfiles) {
    for (const task of tasks) {
      for (let rep = 1; rep <= reps; rep++) {
        done++;
        process.stdout.write(`[${done}/${total}] ${profile} ${task} rep${rep} ... `);
        try {
          const r = await runOne(profile, task, rep);
          runs.push(r);
          console.log(`${r.wall_ms}ms success=${r.success} rounds=${r.llm_rounds} p0=${r.phases.p0_startup}ms`);
        } catch (e) {
          console.log(`ERROR ${e.message}`);
          runs.push({ profile, task, rep, error: String(e.message), success: false });
        }
      }
    }
  }
  writeFileSync(join(outDir, "e2e-runs.jsonl"), runs.map((r) => JSON.stringify(r)).join("\n") + "\n");
  console.log(`\nWrote ${outDir}/e2e-runs.jsonl`);
}

main().catch((e) => { console.error(e); process.exit(1); });
