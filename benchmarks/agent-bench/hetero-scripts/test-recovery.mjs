import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, cpSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = "/home/hatch/workspace/fx-fork/benchmarks/agent-bench";
const simBin = join(root, ".tools", "sim-server");
const fxBin = join(root, ".tools", "fx");
const tasksDir = join(root, "tasks");

function startSim(profile, scriptPath) {
  const a = ["--profile", profile, "--port", "0", "--script", scriptPath];
  const child = spawn(simBin, a, { stdio: ["ignore", "pipe", "pipe"] });
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("timeout")), 10000);
    child.stdout.on("data", (d) => {
      buf += d.toString();
      const nl = buf.indexOf("\n");
      if (nl >= 0) { clearTimeout(timer); resolve({ child, port: JSON.parse(buf.slice(0, nl)).port }); }
    });
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
async function runCase(name, scriptPath) {
  const { child: sim, port } = await startSim("pro", scriptPath);
  const home = makeHome(port);
  const work = mkdtempSync(join(tmpdir(), "hetero-work-"));
  for (const f of readdirSync(join(tasksDir, "T5-read-modify", "seed"))) cpSync(join(tasksDir, "T5-read-modify", "seed", f), join(work, f));
  const prompt = readFileSync(join(tasksDir, "T5-read-modify", "prompt.txt"), "utf8").trim();
  try {
    const t0 = performance.now();
    const child = spawnSync(fxBin, ["ask", "--auto", "--json", "--no-save", "--timeout", "120", prompt],
      { cwd: work, env: { ...process.env, HOME: home, FX_PROVIDER: "sim", FX_MODEL: "sim-model", NO_COLOR: "1" }, timeout: 130000, encoding: "utf8" });
    const wallMs = Math.round(performance.now() - t0);
    // Check what fx output says
    const out = (child.stdout || "");
    const hasError = out.toLowerCase().includes("error");
    const assert = spawnSync("node", [join(tasksDir, "T5-read-modify", "assert.mjs"), work], { encoding: "utf8" });
    console.log(`${name}: wall=${wallMs}ms success=${assert.status === 0} fx_mentions_error=${hasError}`);
  } finally { sim.kill(); rmSync(home, { recursive: true, force: true }); rmSync(work, { recursive: true, force: true }); }
}
await runCase("T5-invalid-arg", "/tmp/hetero/t5-degraded-invalid-arg.json");
