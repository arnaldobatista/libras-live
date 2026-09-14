#!/usr/bin/env node
// Teste de ponta a ponta do overlay com Chrome headless (sem dependências).
//
// Pré-requisito: app rodando (make run). Uso:
//   node Scripts/e2e-overlay.mjs [--port 8765] [--shot build/e2e.png] "frase 1" "frase 2" ...
//   node Scripts/e2e-overlay.mjs --burst      (manda tudo de uma vez: testa aceleração e descarte)
//
// Para cada frase: POST /api/say → espera o overlay tocar e terminar → mede tempos.
// Sai com código 1 se alguma frase não terminar normalmente.

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  if (index === -1) return fallback;
  const [value] = args.splice(index, 2).slice(1);
  return value;
};

const port = Number(option("port", "8765"));
const shot = option("shot", null);
const burst = args.includes("--burst") ? (args.splice(args.indexOf("--burst"), 1), true) : false;
const chromePath = option("chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome");
const phrases = args.length
  ? args
  : ["Bom dia pessoal, sejam bem-vindos.", "Hoje vamos falar sobre acessibilidade.", "Obrigado pela presença."];

const base = `http://127.0.0.1:${port}`;
const debugPort = 9300 + Math.floor(Math.random() * 500);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(fn, timeoutMs, label) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const value = await fn();
    if (value) return value;
    await sleep(100);
  }
  throw new Error(`Tempo esgotado esperando ${label}`);
}

// ------------------------------------------------------------------ Chrome/CDP

const profile = mkdtempSync(join(tmpdir(), "libras-e2e-"));
const chrome = spawn(chromePath, [
  "--headless=new",
  `--remote-debugging-port=${debugPort}`,
  `--user-data-dir=${profile}`,
  "--window-size=540,960",
  "--use-angle=metal",
  "--disable-background-timer-throttling",
  "--disable-renderer-backgrounding",
  "--no-first-run",
  "about:blank",
], { stdio: "ignore" });

let socket;
let nextId = 1;
const pending = new Map();

function cdp(method, params = {}) {
  const id = nextId++;
  socket.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

async function evaluate(expression) {
  const { result, exceptionDetails } = await cdp("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (exceptionDetails) throw new Error(exceptionDetails.text);
  return result.value;
}

async function cleanup() {
  try { socket?.close(); } catch {}
  chrome.kill("SIGTERM");
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}

try {
  const version = await waitFor(
    () => fetch(`http://127.0.0.1:${debugPort}/json/list`).then((r) => r.json()).catch(() => null),
    15000,
    "Chrome headless"
  );
  const page = version.find((target) => target.type === "page");

  socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result);
  };

  await cdp("Page.enable");
  await cdp("Runtime.enable");

  const status = await fetch(`${base}/api/status`).then((r) => r.json()).catch(() => null);
  if (!status) throw new Error(`App não está respondendo em ${base}. Rode "make run" antes.`);

  console.log(`Abrindo overlay em ${base}/ ...`);
  const loadStarted = Date.now();
  await cdp("Page.navigate", { url: `${base}/?debug=1&bg=1e293b&e2e=${Date.now()}` });
  await waitFor(() => evaluate("!!(window.librasOverlay && window.librasOverlay.player.ready)"), 60000, "player pronto");
  console.log(`Player pronto em ${((Date.now() - loadStarted) / 1000).toFixed(1)} s`);

  const fps = await evaluate(`new Promise((resolve) => {
    let frames = 0; const start = performance.now();
    const tick = () => { frames++; performance.now() - start < 1000 ? requestAnimationFrame(tick) : resolve(frames); };
    requestAnimationFrame(tick);
  })`);
  console.log(`Renderização: ${fps} fps, página ${await evaluate("document.visibilityState")}`);

  if (burst) {
    const texts = args.length ? phrases : [
      "Boa noite a todos que estão chegando agora na transmissão de hoje.",
      "Antes de começar, quero agradecer a presença de cada um de vocês.",
      "Hoje vamos conversar sobre acessibilidade e inclusão das pessoas surdas.",
      "Também vamos mostrar como funciona a tradução automática para Libras.",
      "No final teremos um tempo para perguntas e respostas.",
      "Deixe seu comentário e compartilhe com seus amigos.",
    ];
    const before = await fetch(`${base}/api/status`).then((r) => r.json());
    const traceStart = await evaluate("window.librasOverlay.traceTotal()");
    const t0 = Date.now();
    for (const text of texts) {
      await fetch(`${base}/api/say`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text }) });
    }
    let peakLag = 0;
    const after = await waitFor(async () => {
      const status = await fetch(`${base}/api/status`).then((r) => r.json());
      peakLag = Math.max(peakLag, status.lag);
      return status.queued === 0 && status.playingID == null && Date.now() - t0 > 2000 ? status : null;
    }, 180000, "fila esvaziar");
    const trace = await evaluate(`window.librasOverlay.traceSince(${traceStart})`);
    const speeds = trace.filter((e) => e[1] === "send" && e[2] === "setSlider").map((e) => Number(e[3]).toFixed(2));
    const endings = trace.filter((e) => e[1] === "ended").map((e) => e[3]);
    console.log(`Rajada de ${texts.length} frases em ${((Date.now() - t0) / 1000).toFixed(1)} s`);
    console.log(`  tocadas: ${after.played - before.played} · descartadas: ${after.dropped - before.dropped} · atraso máximo: ${peakLag.toFixed(1)} s`);
    console.log(`  velocidades usadas: ${speeds.join(", ")}`);
    console.log(`  fins: ${endings.join(", ")}`);
    await cleanup();
    process.exit(endings.every((reason) => ["done", "counter"].includes(reason)) ? 0 : 1);
  }

  const results = [];
  for (const [index, text] of phrases.entries()) {
    const traceStart = await evaluate("window.librasOverlay.traceTotal()");
    await evaluate("window.librasOverlay.mark('say')");

    const response = await fetch(`${base}/api/say`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    if (response.status !== 202) throw new Error(`/api/say respondeu ${response.status}`);

    const trace = await waitFor(async () => {
      const events = await evaluate(`window.librasOverlay.traceSince(${traceStart})`);
      return events.some((event) => event[1] === "ended") ? events : null;
    }, 90000, `fim da frase ${index + 1}`);

    const at = (predicate) => trace.find(predicate)?.[0];
    const posted = at((event) => event[1] === "say");
    const playNow = trace.find((event) => event[1] === "send" && event[2] === "playNow");
    const firstSign = at((event) => event[1] === "counter" && Number(event[2]) > 0);
    const ended = trace.find((event) => event[1] === "ended");

    results.push({
      frase: text,
      glosa: playNow?.[3] ?? "—",
      "até tocar (s)": playNow ? ((playNow[0] - posted) / 1000).toFixed(2) : "—",
      "1º sinal (s)": firstSign ? ((firstSign - posted) / 1000).toFixed(2) : "—",
      "fim (s)": ((ended[0] - posted) / 1000).toFixed(2),
      motivo: ended[3],
    });

    if (shot && index === 0) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      mkdirSync(dirname(shot), { recursive: true });
      writeFileSync(shot, Buffer.from(data, "base64"));
    }
  }

  console.table(results);
  const final = await fetch(`${base}/api/status`).then((r) => r.json());
  console.log(`App: tocadas=${final.played} descartadas=${final.dropped} cache de sinais=${JSON.stringify(final.signs)}`);

  const failures = results.filter((row) => !["done", "counter"].includes(row.motivo));
  await cleanup();
  if (failures.length) {
    console.error(`${failures.length} frase(s) sem fim normal.`);
    process.exit(1);
  }
} catch (error) {
  console.error(error.message);
  await cleanup();
  process.exit(1);
}
