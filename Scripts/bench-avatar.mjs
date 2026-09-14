#!/usr/bin/env node
// Mede quanto tempo o avatar leva para sinalizar cada tipo de glosa (Chrome headless).
//
// Pré-requisito: app rodando com a fila vazia. Uso:
//   node Scripts/bench-avatar.mjs [--port 8765] [--speeds 1,2,3] [--trials 2]
//
// Toca glosas direto no player do overlay (sem passar pela fila do app) e reporta
// a duração de playNow até o fim, em segundos.

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index === -1 ? fallback : args[index + 1];
};

const port = Number(option("port", "8765"));
const speeds = option("speeds", "1,2,3").split(",").map(Number);
const trials = Number(option("trials", "2"));
const only = option("only", null);
const base = `http://127.0.0.1:${port}`;

const cases = [
  ["1 sinal", "CASA"],
  ["2 sinais", "CASA JESUS"],
  ["4 sinais", "CASA JESUS VIDA PALAVRA"],
  ["1 sinal + [PONTO]", "CASA [PONTO]"],
  ["1 sinal + [INTERROGAÇÃO]", "CASA [INTERROGAÇÃO]"],
  ["soletrado 11 letras", "DISCERNIRMO"],
  ["composto inexistente", "NÃO_PRATICAR"],
  ["composto separado", "PRATICAR NÃO"],
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const profile = mkdtempSync(join(tmpdir(), "libras-bench-"));
const debugPort = 9800 + Math.floor(Math.random() * 100);
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
  "--headless=new", `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`,
  "--window-size=540,960", "--use-angle=metal", "--no-first-run", "about:blank",
], { stdio: "ignore" });

let socket;
let nextId = 1;
const pending = new Map();
const cdp = (method, params = {}) => {
  const id = nextId++;
  socket.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
};
const evaluate = async (expression) => {
  const { result, exceptionDetails } = await cdp("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (exceptionDetails) throw new Error(exceptionDetails.text);
  return result.value;
};

try {
  let targets;
  for (let i = 0; i < 100 && !targets; i++) {
    targets = await fetch(`http://127.0.0.1:${debugPort}/json/list`).then((r) => r.json()).catch(() => null);
    if (!targets) await sleep(150);
  }
  socket = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
  await new Promise((resolve) => (socket.onopen = resolve));
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result);
  };

  await cdp("Page.navigate", { url: `${base}/?bench=${Date.now()}` });
  for (let i = 0; i < 600; i++) {
    if (await evaluate("!!(window.librasOverlay && window.librasOverlay.player.ready)").catch(() => false)) break;
    await sleep(100);
  }

  // Toca uma glosa e devolve { total, first } em segundos.
  const play = (gloss, speed, id) => evaluate(`new Promise((resolve) => {
    const o = window.librasOverlay;
    o.settings.speed = ${speed};
    const start = o.traceTotal();
    const t0 = performance.now();
    o.player.playGloss(${id}, ${JSON.stringify(gloss)});
    const timer = setInterval(() => {
      const events = o.traceSince(start);
      const ended = events.find((e) => e[1] === "ended");
      if (!ended && performance.now() - t0 < 60000) return;
      clearInterval(timer);
      const origin = events.find((e) => e[1] === "send" && e[2] === "playNow")?.[0] ?? 0;
      const first = events.find((e) => e[1] === "counter" && Number(e[2]) > 0)?.[0];
      resolve({
        total: ended ? (ended[0] - origin) / 1000 : null,
        first: first ? (first - origin) / 1000 : null,
        reason: ended ? ended[3] : "timeout",
      });
    }, 20);
  })`);

  const selected = only ? cases.filter(([label]) => label === only) : cases;

  // Aquece: baixa e carrega todos os sinais uma vez.
  let id = 900000;
  for (const [, gloss] of selected) await play(gloss, 3, id++);

  const rows = [];
  for (const [label, gloss] of selected) {
    const row = { caso: label, glosa: gloss };
    for (const speed of speeds) {
      const totals = [];
      for (let t = 0; t < trials; t++) {
        const result = await play(gloss, speed, id++);
        console.log(`  ${label} @${speed}×: ${result.total?.toFixed(2)} s (1º sinal ${result.first?.toFixed(2)} s, ${result.reason})`);
        if (result.total != null) totals.push(result.total);
        await sleep(400);
      }
      row[`${speed}×`] = totals.length ? (totals.reduce((a, b) => a + b, 0) / totals.length).toFixed(2) : "—";
    }
    rows.push(row);

  }

  // Duas glosas seguidas vs. uma glosa com os dois sinais.
  if (!only) {
    const sequential = {};
    for (const speed of speeds) {
      const a = await play("CASA", speed, id++);
      const b = await play("JESUS", speed, id++);
      sequential[`${speed}×`] = (a.total + b.total).toFixed(2);
    }
    rows.push({ caso: "2 glosas seguidas", glosa: "CASA | JESUS", ...sequential });
  }

  console.table(rows);
} finally {
  try { socket?.close(); } catch {}
  chrome.kill("SIGTERM");
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
