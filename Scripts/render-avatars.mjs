#!/usr/bin/env node
// Fotografa os três avatares com fundo transparente para o seletor do app.
//   node Scripts/render-avatars.mjs [--port 8765] [--out Resources/Avatars]
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const option = (name, fallback) => (args.includes(`--${name}`) ? args[args.indexOf(`--${name}`) + 1] : fallback);
const base = `http://127.0.0.1:${option("port", "8765")}`;
const out = option("out", "Resources/Avatars");
mkdirSync(out, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const profile = mkdtempSync(join(tmpdir(), "avatars-"));
const debugPort = 9700 + Math.floor(Math.random() * 90);
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", ["--headless=new", `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`, "--window-size=540,960", "--use-angle=metal", "--no-first-run", "about:blank"], { stdio: "ignore" });

let targets;
for (let i = 0; i < 100 && !targets; i++) { targets = await fetch(`http://127.0.0.1:${debugPort}/json/list`).then((r) => r.json()).catch(() => null); if (!targets) await sleep(150); }
const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 1; const pending = new Map();
ws.onmessage = (e) => { const m = JSON.parse(e.data); const p = pending.get(m.id); if (p) { pending.delete(m.id); p(m.result); } };
const cdp = (method, params = {}) => new Promise((r) => { const i = id++; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async (expression) => (await cdp("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result?.value;

try {
  await cdp("Page.enable");
  await cdp("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } });
  await cdp("Page.navigate", { url: `${base}/?preview=1&avatars=${Date.now()}` });
  for (let i = 0; i < 600; i++) { if (await evaluate("!!(window.librasOverlay && window.librasOverlay.player.ready)")) break; await sleep(100); }

  for (const avatar of ["icaro", "hosana", "guga"]) {
    await evaluate(`window.librasOverlay.player.instance.SendMessage("PlayerManager", "Change", "${avatar}")`);
    await sleep(avatar === "icaro" ? 2500 : 6000);
    const { data } = await cdp("Page.captureScreenshot", { format: "png", clip: { x: 40, y: 10, width: 460, height: 560, scale: 1 } });
    writeFileSync(join(out, `${avatar}.png`), Buffer.from(data, "base64"));
    console.log(`${avatar}.png`);
  }
} finally {
  ws.close();
  chrome.kill("SIGTERM");
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
