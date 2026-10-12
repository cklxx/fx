import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, cpSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const root = "/home/hatch/workspace/fx-fork/benchmarks/agent-bench";
const simBin = join(root, ".tools", "sim-server");
const fxBin = join(root, ".tools", "fx");
const tasksDir = join(root, "tasks");
function startSim(profile, scriptPath) {
  const a = ["--profile", profile, "--port", "0", "--timing-log", "/tmp/hetero/timing.jsonl", "--script", scriptPath];
  const child = spawn(simBin, a, { stdio: ["ignore", "pipe", "pipe"] });
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("timeout")), 10000);
    child.stdout.on("data", (d) => { buf += d.toString(); const nl = buf.indexOf("\n");
      if (nl >= 0) { clearTimeout(timer); resolve({ child, port: JSON.parse(buf.slice(0, nl)).port }); } });
    child.on("error", reject);
  });
}
function makeHome(port) {
  const home = mkdtempSync(join(tmpdir(), "hetero-home-"));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    providers: { sim: { protocol: "openai-chat-completions", base_url: `http://127.0.0.1:${port}/v1`,
      auth: { type: "none" }, model_metadata: { "sim-model": { context_window: 32768, max_output_tokens: 2048, supports_tool_use: true } } } },
    provider: "sim", models: { sim: "sim-model" }, permission_mode: "auto",
    permission: { bash: "allow", edit: "allow", read: "allow" } }) + "\n", { mode: 0o600 });
  return home;
}
async function runCase(name, taskId, profile) {
  try { rmSync("/tmp/hetero/timing.jsonl"); } catch {}
  const scriptPath = join(root, "replay", { "T5-read-modify": "t5-pro.json", "T6-recover": "t6-pro.json" }[taskId]);
  const { child: sim, port } = await startSim(profile, scriptPath);
  const home = makeHome(port);
  const work = mkdtempSync(join(tmpdir(), "hetero-work-"));
  for (const f of readdirSync(join(tasksDir, taskId, "seed"))) cpSync(join(tasksDir, taskId, "seed", f), join(work, f));
  const prompt = readFileSync(join(tasksDir, taskId, "prompt.txt"), "utf8").trim();
  try {
    const t0 = performance.now();
    spawnSync(fxBin, ["ask", "--auto", "--json", "--no-save", "--timeout", "120", prompt],
      { cwd: work, env: { ...process.env, HOME: home, FX_PROVIDER: "sim", FX_MODEL: "sim-model", NO_COLOR: "1" }, timeout: 130000, encoding: "utf8" });
    const wallMs = Math.round(performance.now() - t0);
    let timing = [];
    try { timing = readFileSync("/tmp/hetero/timing.jsonl", "utf8").trim().split("\n").filter(Boolean).map(l => JSON.parse(l)); } catch {}
    const ttfts = timing.map(r => r.ttft_ms);
    console.log(`${name}: wall=${wallMs}ms rounds=${timing.length} ttft_per_round=[${ttfts.join(",")}]`);
  } finally { sim.kill(); rmSync(home, { recursive: true, force: true }); rmSync(work, { recursive: true, force: true }); }
}
await runCase("T5-pro", "T5-read-modify", "pro");
await runCase("T5-ultrafast", "T5-read-modify", "ultrafast");
await runCase("T6-pro", "T6-recover", "pro");
await runCase("T6-ultrafast", "T6-recover", "ultrafast");
