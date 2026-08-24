const cacheName = "score-webgpu-v13";
const applicationFiles = [
  "./score.html",
  "./index.html",
  "./score.js",
  "./score.wasm",
  "./audio_dsp.wasm",
  "./audio-worklet.js",
  "./portable-grand.scorebank",
  "./ACCURATE_SALAMANDER_LICENSE.txt",
  "./manifest.webmanifest",
  "./icons/score-icon-192.png",
  "./icons/score-icon-512.png"
];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(cacheName).then(cache => cache.addAll(applicationFiles)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key !== cacheName).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return;
  event.respondWith(fetch(event.request).then(response => {
    if (response.ok && new URL(event.request.url).origin === self.location.origin) {
      const copy = response.clone();
      caches.open(cacheName).then(cache => cache.put(event.request, copy));
    }
    return response;
  }).catch(() => caches.match(event.request)));
});
