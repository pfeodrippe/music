(() => {
  const databaseName = "score-local-v1";
  const storeName = "documents";
  const snapshotKey = "autosave.score";
  const audioKey = "latest-take.audio";

  const openDatabase = () => new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(storeName);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });

  const readStored = async key => {
    const database = await openDatabase();
    return new Promise((resolve, reject) => {
      const request = database.transaction(storeName, "readonly").objectStore(storeName).get(key);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  };

  const writeStored = async (key, value) => {
    const database = await openDatabase();
    return new Promise((resolve, reject) => {
      const transaction = database.transaction(storeName, "readwrite");
      transaction.objectStore(storeName).put(value, key);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
    });
  };

  const callWithBytes = (bytes, callback) => {
    const pointer = Module._score_web_alloc(bytes.byteLength);
    if (!pointer) throw new Error("Wasm allocation failed");
    try {
      HEAPU8.set(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength), pointer);
      return callback(pointer, bytes.byteLength);
    } finally {
      Module._score_web_free(pointer);
    }
  };

  const host = {
    canvas: null,
    audioContext: null,
    audioNode: null,
    audioPromise: null,
    microphoneStream: null,
    microphoneSource: null,
    midiAccess: null,
    mediaRecorder: null,
    recordingChunks: [],
    replayElement: null,
    lastPitchTime: 0,
    pendingSave: Promise.resolve(),
    devRevision: null,
    accessibilityRoot: null,
    accessibilityElements: new Map(),
    accessibilitySignature: "",

    initialize(canvas) {
      this.canvas = canvas;
      this.installPointerEvents();
      this.restoreSnapshot();
      this.startDevelopmentReload();
      navigator.storage?.persist?.().catch(() => {});
      if ("serviceWorker" in navigator) navigator.serviceWorker.register("service-worker.js").catch(error => console.warn("Offline install unavailable", error));
    },

    installPointerEvents() {
      const canvas = this.canvas;
      const forward = (kind, event) => {
        const bounds = canvas.getBoundingClientRect();
        const pointerType = event.pointerType === "pen" ? 1 : event.pointerType === "touch" ? 2 : 0;
        Module._score_web_pointer(
          kind,
          pointerType,
          event.pointerId,
          event.clientX - bounds.left,
          event.clientY - bounds.top,
          event.buttons,
          Number.isFinite(event.pressure) ? event.pressure : 0,
          event.tiltX || 0,
          event.tiltY || 0
        );
      };
      canvas.addEventListener("pointerdown", event => {
        canvas.focus();
        canvas.setPointerCapture?.(event.pointerId);
        this.ensureAudio();
        forward(1, event);
        event.preventDefault();
      }, {passive:false});
      canvas.addEventListener("pointermove", event => forward(0, event), {passive:true});
      canvas.addEventListener("pointerup", event => {
        forward(2, event);
        canvas.releasePointerCapture?.(event.pointerId);
        event.preventDefault();
      }, {passive:false});
      canvas.addEventListener("pointercancel", event => forward(3, event), {passive:true});
      canvas.addEventListener("contextmenu", event => event.preventDefault());
    },

    updateAccessibility(pointer, count) {
      if (!pointer || !count) return;
      const stride = 80;
      const decoder = this.accessibilityDecoder || (this.accessibilityDecoder = new TextDecoder());
      const items = [];
      for (let index = 0; index < count; index += 1) {
        const offset = pointer + index * stride;
        const id = HEAPU32[offset >> 2];
        const role = HEAPU32[(offset + 4) >> 2];
        const rect = [0, 1, 2, 3].map(part => HEAPF32[(offset + 8 + part * 4) >> 2]);
        const labelLength = HEAPU32[(offset + 24) >> 2];
        const flags = HEAPU32[(offset + 28) >> 2];
        const label = decoder.decode(HEAPU8.subarray(offset + 32, offset + 32 + labelLength));
        items.push({id, role, rect, flags, label});
      }
      const signature = items.map(item => `${item.id}:${item.role}:${item.rect.join(",")}:${item.flags}:${item.label}`).join("|");
      if (signature === this.accessibilitySignature) return;
      this.accessibilitySignature = signature;
      if (!this.accessibilityRoot) {
        const root = document.createElement("div");
        root.setAttribute("aria-label", "Score music studio controls");
        root.style.cssText = "position:fixed;inset:0;z-index:1;pointer-events:none;overflow:hidden";
        document.body.appendChild(root);
        this.canvas.setAttribute("aria-hidden", "true");
        this.accessibilityRoot = root;
      }
      const active = new Set();
      for (const item of items) {
        active.add(item.id);
        let element = this.accessibilityElements.get(item.id);
        if (!element) {
          element = document.createElement(item.role === 0 ? "div" : "button");
          if (item.role !== 0) element.addEventListener("click", () => {
            this.ensureAudio();
            Module._score_web_accessibility_activate(item.id);
          });
          this.accessibilityRoot.appendChild(element);
          this.accessibilityElements.set(item.id, element);
        }
        element.setAttribute("role", item.role === 0 ? "document" : item.role === 2 ? "tab" : "button");
        element.setAttribute("aria-label", item.label);
        if (item.role === 2) element.setAttribute("aria-selected", (item.flags & 1) !== 0 ? "true" : "false");
        else if (item.role === 1 && (item.flags & 4) !== 0) element.setAttribute("aria-pressed", (item.flags & 2) !== 0 ? "true" : "false");
        else element.removeAttribute("aria-pressed");
        element.style.cssText = `position:absolute;left:${item.rect[0]}px;top:${item.rect[1]}px;width:${item.rect[2]}px;height:${item.rect[3]}px;opacity:.001;pointer-events:none;border:0;padding:0;color:transparent;background:transparent`;
      }
      for (const [id, element] of this.accessibilityElements) {
        if (!active.has(id)) {
          element.remove();
          this.accessibilityElements.delete(id);
        }
      }
    },

    async ensureAudio() {
      if (this.audioContext) {
        if (this.audioContext.state !== "running") await this.audioContext.resume();
        return this.audioNode;
      }
      if (this.audioPromise) return this.audioPromise;
      this.audioPromise = (async () => {
        const AudioContext = window.AudioContext || window.webkitAudioContext;
        if (!AudioContext) throw new Error("Web Audio unavailable");
        const context = new AudioContext({latencyHint:"interactive"});
        const [module, _, pianoBank] = await Promise.all([
          fetch("audio_dsp.wasm").then(response => {
            if (!response.ok) throw new Error("Audio DSP download failed");
            return response.arrayBuffer();
          }).then(bytes => WebAssembly.compile(bytes)),
          context.audioWorklet.addModule("audio-worklet.js"),
          fetch("portable-grand.scorebank").then(response => {
            if (!response.ok) throw new Error("Sampled grand-piano bank download failed");
            return response.arrayBuffer();
          })
        ]);
        const node = new AudioWorkletNode(context, "score-audio", {
          numberOfInputs: 1,
          numberOfOutputs: 1,
          outputChannelCount: [2],
          processorOptions: {wasmModule: module}
        });
        node.port.onmessage = ({data}) => {
          if (data.type === "bank-status") {
            Module._score_web_sampler_status(data.status === 0 ? 1 : 2, data.regions || 0, data.samples || 0);
            return;
          }
          if (data.type === "pitch") {
            const now = performance.now();
            if (now - this.lastPitchTime < 80) return;
            this.lastPitchTime = now;
            Module._score_web_pitch(data.note, data.confidence);
          }
        };
        node.port.postMessage({type:"bank", bytes:pianoBank}, [pianoBank]);
        node.connect(context.destination);
        this.audioContext = context;
        this.audioNode = node;
        await context.resume();
        return node;
      })().catch(error => {
        this.audioPromise = null;
        console.error("Audio startup failed", error);
        Module._score_web_status(5);
        throw error;
      });
      return this.audioPromise;
    },

    sendAudioMidi(status, data1, data2) {
      this.ensureAudio().then(node => node.port.postMessage({type:"midi", status, data1, data2})).catch(() => {});
    },

    allNotesOff() {
      this.audioNode?.port.postMessage({type:"all-notes-off"});
    },

    metronome(accent) {
      this.ensureAudio().then(node => node.port.postMessage({type:"click", accent})).catch(() => {});
    },

    sendExternalMidi(status, data1, data2) {
      if (!this.midiAccess) return;
      for (const output of this.midiAccess.outputs.values()) output.send([status, data1, data2]);
    },

    async ensureInputs() {
      const results = [];
      results.push(this.ensureAudio());
      if (navigator.requestMIDIAccess && !this.midiAccess) {
        results.push(navigator.requestMIDIAccess({sysex:false}).then(access => {
          this.midiAccess = access;
          const connect = input => input.onmidimessage = event => {
            const [status = 0, data1 = 0, data2 = 0] = event.data;
            Module._score_web_midi(event.timeStamp || performance.now(), status, data1, data2);
            this.sendAudioMidi(status, data1, data2);
          };
          for (const input of access.inputs.values()) connect(input);
          access.onstatechange = event => { if (event.port?.type === "input" && event.port.state === "connected") connect(event.port); };
          return access;
        }));
      }
      if (navigator.mediaDevices?.getUserMedia && !this.microphoneStream) {
        results.push(navigator.mediaDevices.getUserMedia({audio:{echoCancellation:false,noiseSuppression:false,autoGainControl:false},video:false}).then(async stream => {
          this.microphoneStream = stream;
          const node = await this.ensureAudio();
          this.microphoneSource = this.audioContext.createMediaStreamSource(stream);
          this.microphoneSource.connect(node);
          return stream;
        }));
      }
      await Promise.allSettled(results);
      const ready = Boolean(this.midiAccess || this.microphoneStream);
      Module._score_web_status(ready ? 4 : 5);
      return ready;
    },

    openFile() {
      const input = document.createElement("input");
      input.type = "file";
      input.accept = ".musicxml,.xml,.mxl,.mid,.midi,.score,application/vnd.recordare.musicxml,application/vnd.recordare.musicxml+xml,audio/midi";
      input.style.display = "none";
      input.onchange = async () => {
        try {
          const file = input.files?.[0];
          if (!file) return;
          if (file.size > 64 * 1024 * 1024) throw new Error("Score exceeds the 64 MB import limit");
          const extension = file.name.toLowerCase().split(".").pop();
          const kind = extension === "mid" || extension === "midi" ? 2 : extension === "score" ? 3 : extension === "mxl" ? 4 : 1;
          const bytes = new Uint8Array(await file.arrayBuffer());
          const status = callWithBytes(bytes, (pointer, length) => Module._score_web_import(pointer, length, kind));
          Module._score_web_status(status === 0 ? 2 : 3);
          if (status === 0) Module._score_web_save_now();
        } catch (error) {
          console.error("Score import failed", error);
          Module._score_web_status(3);
        } finally {
          input.remove();
        }
      };
      document.body.appendChild(input);
      input.click();
    },

    openInstrument() {
      const input = document.createElement("input");
      input.type = "file";
      input.accept = ".scorebank,application/octet-stream";
      input.style.display = "none";
      input.onchange = async () => {
        try {
          const file = input.files?.[0];
          if (!file) return;
          if (file.size > 256 * 1024 * 1024) throw new Error("Instrument bank exceeds the 256 MB portable limit");
          const node = await this.ensureAudio();
          const bytes = await file.arrayBuffer();
          node.port.postMessage({type:"bank", bytes}, [bytes]);
        } catch (error) {
          console.error("Instrument import failed", error);
          Module._score_web_sampler_status(2, 0, 0);
        } finally {
          input.remove();
        }
      };
      document.body.appendChild(input);
      input.click();
    },

    exportSnapshot(bytes) {
      const blob = new Blob([bytes.slice()], {type:"application/vnd.recordare.musicxml+xml"});
      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob);
      link.download = "score.musicxml";
      link.style.display = "none";
      document.body.appendChild(link);
      link.click();
      Module._score_web_status(8);
      setTimeout(() => { URL.revokeObjectURL(link.href); link.remove(); }, 0);
    },

    exportTake(bytes) {
      const blob = new Blob([bytes.slice()], {type:"audio/midi"});
      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob);
      link.download = "score-take.mid";
      link.style.display = "none";
      document.body.appendChild(link);
      link.click();
      Module._score_web_status(8);
      setTimeout(() => { URL.revokeObjectURL(link.href); link.remove(); }, 0);
    },

    async startRecording() {
      const ready = await this.ensureInputs();
      this.recordingChunks = [];
      if (!ready || !this.microphoneStream || typeof MediaRecorder === "undefined") return;
      const preferred = ["audio/webm;codecs=opus", "audio/mp4", "audio/webm"].find(type => MediaRecorder.isTypeSupported(type));
      this.mediaRecorder = new MediaRecorder(this.microphoneStream, preferred ? {mimeType:preferred} : undefined);
      this.mediaRecorder.ondataavailable = event => { if (event.data.size) this.recordingChunks.push(event.data); };
      this.mediaRecorder.start(250);
    },

    stopRecording() {
      const recorder = this.mediaRecorder;
      if (!recorder || recorder.state === "inactive") {
        Module._score_web_status(6);
        return;
      }
      recorder.onstop = async () => {
        const blob = new Blob(this.recordingChunks, {type:recorder.mimeType || "audio/webm"});
        await writeStored(audioKey, blob).catch(error => console.warn("Audio take persistence failed", error));
        Module._score_web_status(6);
      };
      recorder.stop();
    },

    async replayAudio() {
      const blob = await readStored(audioKey).catch(() => null);
      if (!blob) return;
      if (this.replayElement) {
        this.replayElement.pause();
        URL.revokeObjectURL(this.replayElement.src);
      }
      this.replayElement = new Audio(URL.createObjectURL(blob));
      await this.replayElement.play().catch(error => console.warn("Audio replay needs another user gesture", error));
    },

    saveSnapshot(bytes) {
      const owned = bytes.slice().buffer;
      this.pendingSave = writeStored(snapshotKey, owned).catch(error => console.warn("Autosave failed", error));
      return this.pendingSave;
    },

    async restoreSnapshot() {
      const stored = await readStored(snapshotKey).catch(() => null);
      if (!stored) return;
      const bytes = new Uint8Array(stored);
      const status = callWithBytes(bytes, (pointer, length) => Module._score_web_restore(pointer, length));
      if (status === 0) Module._score_web_status(7);
    },

    startDevelopmentReload() {
      if (location.hostname !== "localhost" && location.hostname !== "127.0.0.1") return;
      setInterval(async () => {
        try {
          const revision = await fetch(`dev-revision.txt?t=${Date.now()}`, {cache:"no-store"}).then(response => response.ok ? response.text() : null);
          if (!revision) return;
          if (this.devRevision === null) {
            this.devRevision = revision;
          } else if (revision !== this.devRevision) {
            this.devRevision = revision;
            Module._score_web_save_now();
            await this.pendingSave;
            location.reload();
          }
        } catch (_) {}
      }, 750);
    }
  };

  globalThis.ScoreHost = host;
})();
