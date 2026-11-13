const CACHE = "dmw-v47";
const APP_SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./js/config.js",
  "./js/toast.js",
  "./js/format.js",
  "./js/app.js?v=20261113-18",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await Promise.all(APP_SHELL.map(async (asset) => {
      try { await cache.add(asset); } catch (_error) { /* Keep installation resilient. */ }
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((key) => key.startsWith("dmw-") && key !== CACHE).map((key) => caches.delete(key)));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin) return;

  const isNavigation = request.mode === "navigate" || request.destination === "document";
  event.respondWith((async () => {
    try {
      const response = await fetch(request);
      if (response && response.ok) {
        const cache = await caches.open(CACHE);
        const cacheKey = isNavigation ? "./index.html" : request;
        await cache.put(cacheKey, response.clone());
      }
      return response;
    } catch (_error) {
      const cache = await caches.open(CACHE);
      const cached = await cache.match(request) || await cache.match(url.pathname);
      if (cached) return cached;
      if (isNavigation) {
        const shell = await cache.match("./index.html");
        if (shell) return shell;
      }
      return new Response(isNavigation ? "האפליקציה אינה זמינה כרגע במצב לא מקוון." : "המשאב אינו זמין במצב לא מקוון.", {
        status: 503,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
    }
  })());
});
