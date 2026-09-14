/*
 * Libras Live — overlay do avatar (browser source do OBS).
 *
 * Recebe glosas do app por WebSocket, toca no player Unity do VLibras
 * e devolve eventos de reprodução (ready / playing / ended).
 *
 * Parâmetros de URL:
 *   bg=transparent|00ff00   cor de fundo (padrão: transparente)
 *   avatar=icaro|hosana|guga
 *   subtitles=0|1           legenda do próprio avatar
 *   debug=1                 painel com estado, fala e glosa
 *   ws=ws://host:porta/ws   endereço do WebSocket (padrão: mesmo host)
 *   signs=proxy|direct      sinais via cache do app ou direto do VLibras
 *   gloss=TEXTO             toca uma glosa ao carregar (teste sem app)
 *   preview=1               prévia dentro do app: não conta como overlay visível na fila
 */
(() => {
  "use strict";

  const DIRECT_SIGNS_URL = "https://dicionario2.vlibras.gov.br/2018.3.1/WEBGL/";
  const UNITY = { PLAYER: "PlayerManager", CUSTOMIZATION: "CustomizationBridge" };
  const APPEARANCE_KEY = "librasLive.appearanceRevision";
  const SETTLE_MS = 1200; // espera após carregar antes de aceitar glosas
  const REVEAL_MS = 400; // tempo para as cores da aparência chegarem antes de mostrar o avatar
  const STALL_MS = 30000; // sem progresso por esse tempo = player travado
  const END_GRACE_MS = 1500; // após o último sinal, espera o evento de fim

  const params = new URLSearchParams(location.search);
  const servedByApp = location.protocol.startsWith("http") && params.get("signs") !== "direct";

  const settings = {
    avatar: params.get("avatar") || null,
    subtitles: params.has("subtitles") ? params.get("subtitles") === "1" : false,
    speed: 1,
    signsBaseUrl: servedByApp ? `${location.origin}/signs/` : DIRECT_SIGNS_URL,
    appearance: "", // JSON de personalização ("" = original)
    appearanceRevision: null,
  };

  const $ = (id) => document.getElementById(id);
  const debug = params.get("debug") === "1";
  $("debug").hidden = !debug;

  const bg = params.get("bg");
  if (bg && bg !== "transparent") {
    document.body.style.background = /^[0-9a-f]{3,8}$/i.test(bg) ? `#${bg}` : bg;
  }

  function setDebug(id, value) {
    if (debug) $(id).textContent = value;
  }

  // Página oculta (aba em segundo plano, janela minimizada) roda o Unity a ~0 fps e os sinais
  // ficam lentíssimos. O app ignora overlays ocultos ao decidir quando avançar a fila.
  // No OBS a fonte de navegador é sempre visível.
  const isPreview = params.get("preview") === "1";
  const isVisible = () => !isPreview && document.visibilityState !== "hidden";
  // O Unity limpa a tela com branco transparente (1,1,1,0) e as bordas do avatar se misturam com esse
  // branco. O WebKit (prévia dentro do app) compõe o canvas como pré-multiplicado e isso vira um contorno
  // branco serrilhado; limpando com preto transparente as bordas saem limpas. O OBS (Chromium) não precisa.
  function useTransparentBlackClear() {
    const prototypes = [window.WebGLRenderingContext, window.WebGL2RenderingContext].filter(Boolean).map((type) => type.prototype);
    for (const prototype of prototypes) {
      const clearColor = prototype.clearColor;
      prototype.clearColor = function (red, green, blue, alpha) {
        return alpha === 0 ? clearColor.call(this, 0, 0, 0, 0) : clearColor.call(this, red, green, blue, alpha);
      };
    }
  }

  function updateVisibility() {
    record("visibility", [document.visibilityState]);
    send({ type: "visibility", visible: isVisible() });
  }
  document.addEventListener("visibilitychange", updateVisibility);

  // ---------------------------------------------------------------- WebSocket

  let socket = null;
  let reconnectDelay = 500;

  function wsUrl() {
    if (params.get("ws")) return params.get("ws");
    if (!location.protocol.startsWith("http")) return null;
    return `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`;
  }

  function send(message) {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(message));
    }
  }

  function connect() {
    const url = wsUrl();
    if (!url) return;

    socket = new WebSocket(url);
    setDebug("dbg-ws", "conectando");

    socket.onopen = () => {
      reconnectDelay = 500;
      setDebug("dbg-ws", "conectado");
      send({ type: "hello", loaded: player.ready, visible: isVisible() });
      if (player.ready) send({ type: "ready", visible: isVisible() });
    };

    socket.onmessage = (event) => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      handleMessage(message);
    };

    socket.onclose = () => {
      setDebug("dbg-ws", "desconectado");
      socket = null;
      setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 5000);
    };

    socket.onerror = () => socket && socket.close();
  }

  function handleMessage(message) {
    switch (message.type) {
      case "gloss":
        if (typeof message.speed === "number") settings.speed = message.speed;
        if (message.text) setDebug("dbg-text", message.text);
        player.playGloss(message.id, message.gloss);
        break;
      case "config":
        player.applyConfig(message);
        break;
      case "stop":
        player.stop();
        break;
      case "caption":
        setDebug("dbg-text", message.final ? message.text : `… ${message.text}`);
        break;
    }
  }

  // ------------------------------------------------------------------- Player

  const player = {
    instance: null,
    loaded: false,
    ready: false,
    avatar: null, // avatar atual informado pelo Unity
    current: null, // { id, gloss, started, stallTimer, endTimer }
    pending: null, // glosa recebida antes do player ficar pronto

    load() {
      $("loading").hidden = false;
      if (isPreview) useTransparentBlackClear();
      this.instance = UnityLoader.instantiate("gameContainer", "vlibras/playerweb.json", {
        onProgress: (_, progress) => {
          $("loading").querySelector(".fill").style.width = `${Math.round(progress * 100)}%`;
        },
        compatibilityCheck: (_, accept, deny) => {
          if (UnityLoader.SystemInfo.hasWebGL) return accept();
          setDebug("dbg-player", "sem WebGL");
          send({ type: "error", message: "WebGL indisponível" });
          deny();
        },
      });
    },

    unity(method, value, object = UNITY.PLAYER) {
      if (!this.instance) return;
      record("send", value === undefined ? [object, method] : [object, method, value]);
      if (value === undefined) this.instance.SendMessage(object, method);
      else this.instance.SendMessage(object, method, value);
    },

    // Cores e logo: o JSON vai direto para o CustomizationBridge (sem baixar de URL).
    applyAppearance() {
      if (!this.loaded || !settings.appearance) return;
      this.unity("ApplyJSON", settings.appearance, UNITY.CUSTOMIZATION);
      storeAppearanceRevision(settings.appearanceRevision);
    },

    changeAvatar(avatar) {
      // Trocar para o avatar que já está carregado reinicia o boneco e trava o próximo playNow.
      if (!avatar || avatar === this.avatar) return;
      this.avatar = avatar;
      this.unity("Change", avatar);
    },

    onLoaded() {
      this.loaded = true;
      setDebug("dbg-player", "iniciando");

      this.unity("initRandomAnimationsProcess");
      this.unity("setBaseUrl", settings.signsBaseUrl);
      this.unity("setSlider", settings.speed);
      this.unity("setSubtitlesState", settings.subtitles ? 1 : 0);
      this.changeAvatar(settings.avatar);

      // O primeiro playNow logo após o carregamento pode ficar preso em "carregando".
      setTimeout(() => this.onReady(), SETTLE_MS);
    },

    onReady() {
      this.ready = true;
      this.applyAppearance();
      // Só mostra o canvas com o avatar pronto e já com as cores: esconde a tela branca de abertura do Unity.
      setTimeout(() => {
        $("loading").hidden = true;
        document.body.classList.add("player-ready");
      }, REVEAL_MS);
      setDebug("dbg-player", "pronto");
      send({ type: "ready", visible: isVisible() });

      if (this.pending) {
        const { id, gloss } = this.pending;
        this.pending = null;
        this.playGloss(id, gloss);
      }
    },

    applyConfig(config) {
      if (config.avatar) settings.avatar = config.avatar;
      if (typeof config.subtitles === "boolean") settings.subtitles = config.subtitles;
      if (typeof config.speed === "number") settings.speed = config.speed;
      if (config.signsBaseUrl && !params.get("signs")) settings.signsBaseUrl = config.signsBaseUrl;

      if (typeof config.appearanceRevision === "number" && config.appearanceRevision !== settings.appearanceRevision) {
        settings.appearance = config.appearance || "";
        settings.appearanceRevision = config.appearanceRevision;
        const applied = storedAppearanceRevision();
        // Voltar à aparência original só recarregando o player (o JSON não desfaz a logo nem as cores).
        if (config.appearanceReload && applied !== null && applied !== config.appearanceRevision) {
          storeAppearanceRevision(config.appearanceRevision);
          record("appearance", ["reload"]);
          location.reload();
          return;
        }
        this.applyAppearance();
        if (!settings.appearance) storeAppearanceRevision(config.appearanceRevision);
      }
      if (!this.loaded) return;

      if (config.avatar && config.avatar !== this.avatar) {
        this.changeAvatar(settings.avatar);
        // Reaplica depois que o novo avatar carrega.
        setTimeout(() => this.applyAppearance(), 1500);
      }
      if (typeof config.subtitles === "boolean") this.unity("setSubtitlesState", settings.subtitles ? 1 : 0);
      if (typeof config.speed === "number") this.unity("setSlider", settings.speed);
      if (config.signsBaseUrl) this.unity("setBaseUrl", settings.signsBaseUrl);
    },

    playGloss(id, gloss) {
      if (!gloss) return;
      if (!this.ready) {
        if (this.pending) send({ type: "ended", id: this.pending.id, reason: "replaced" });
        this.pending = { id, gloss };
        return;
      }

      this.finishCurrent("replaced");
      setDebug("dbg-gloss", gloss);

      const current = { id, gloss, started: false, stallTimer: null, endTimer: null };
      this.current = current;
      this.start(current);
    },

    start(current) {
      this.unity("setSlider", settings.speed);
      this.unity("playNow", current.gloss);
      this.armStallTimer(current);
    },

    // Vigia: sem nenhum progresso por muito tempo, libera a fila para não travar a live.
    // (Reenviar a glosa não ajuda: o Unity trata o reenvio como fim da reprodução.)
    armStallTimer(current) {
      clearTimeout(current.stallTimer);
      current.stallTimer = setTimeout(() => {
        if (this.current === current) this.finishCurrent("stalled");
      }, STALL_MS);
    },

    stop() {
      if (this.pending) send({ type: "ended", id: this.pending.id, reason: "stopped" });
      this.pending = null;
      this.unity("stopAll");
      this.finishCurrent("stopped");
    },

    finishCurrent(reason) {
      const current = this.current;
      if (!current) return;
      clearTimeout(current.stallTimer);
      clearTimeout(current.endTimer);
      this.current = null;
      record("ended", [current.id, reason]);
      send({ type: "ended", id: current.id, reason });
    },

    // CounterGloss conta sinais concluídos. Ao chegar no total, o fim é iminente;
    // se o evento de estado não vier, encerra por aqui.
    onCounter(counter, total) {
      send({ type: "progress", counter, total });
      const current = this.current;
      if (!current || total <= 0 || counter <= 0) return;

      this.armStallTimer(current);
      if (counter < total) return;

      clearTimeout(current.endTimer);
      current.endTimer = setTimeout(() => {
        if (this.current === current) this.finishCurrent("counter");
      }, END_GRACE_MS);
    },

    onStateChange(isPlaying, isPaused, isLoading) {
      const current = this.current;
      if (!current) return;

      if (isPlaying && !isPaused) {
        if (!current.started) {
          current.started = true;
          send({ type: "playing", id: current.id });
        }
      } else if (!isPlaying && !isLoading && current.started) {
        this.finishCurrent("done");
      }
    },
  };

  // Revisão da aparência já aplicada nesta página (sobrevive ao recarregamento da própria aba).
  function storedAppearanceRevision() {
    try {
      const value = sessionStorage.getItem(APPEARANCE_KEY);
      return value === null ? null : Number(value);
    } catch {
      return null;
    }
  }
  function storeAppearanceRevision(revision) {
    try {
      if (typeof revision === "number") sessionStorage.setItem(APPEARANCE_KEY, String(revision));
    } catch {}
  }

  // Registro circular dos eventos do Unity (window.librasOverlay.trace no console).
  const trace = [];
  const traceStart = performance.now();
  let traceShifted = 0; // entradas descartadas do início do registro circular
  function record(name, args) {
    trace.push([Math.round(performance.now() - traceStart), name, ...Array.from(args, String)]);
    if (trace.length > 2000) {
      trace.shift();
      traceShifted += 1;
    }
  }

  // Callbacks chamados pelo build Unity do VLibras.
  const toBool = (value) => value !== "False" && value !== false && value !== 0;
  const traced = (name, fn) => (...args) => {
    record(name, args);
    return fn(...args);
  };

  window.onLoadPlayer = traced("onLoadPlayer", () => player.onLoaded());
  window.updateProgress = () => {};
  window.onPlayingStateChange = traced("state", (isPlaying, isPaused, _interval, isLoading) =>
    player.onStateChange(toBool(isPlaying), toBool(isPaused), toBool(isLoading))
  );
  window.CounterGloss = traced("counter", (counter, total) => player.onCounter(Number(counter), Number(total)));
  window.GetAvatar = traced("avatar", (avatar) => {
    player.avatar = String(avatar);
    send({ type: "avatar", avatar: player.avatar });
  });
  window.FinishWelcome = traced("welcome", () => {});

  // Exposto para testes manuais no console.
  window.librasOverlay = {
    player,
    settings,
    send,
    trace,
    mark: (name) => record(name, []),
    // Posição absoluta no registro e eventos a partir dela (estável mesmo com o registro circular).
    traceTotal: () => traceShifted + trace.length,
    traceSince: (position) => trace.slice(Math.max(0, position - traceShifted)),
  };

  if (params.get("gloss")) player.pending = { id: 0, gloss: params.get("gloss") };

  player.load();
  connect();
})();
