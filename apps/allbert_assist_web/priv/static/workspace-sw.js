const CACHE_NAME = "allbert-workspace-shell-v1.0.1";
const OFFLINE_SHELL_URL = "/workspace-offline.html";
const DEFAULT_SHELL_ASSETS = [
  OFFLINE_SHELL_URL,
  "/assets/css/app.css",
  "/assets/js/app.js",
  "/images/allbert-mark.svg",
  "/images/favicon-32.png",
  "/images/apple-touch-icon.png",
  "/favicon.ico",
];

const cacheShellAssets = async assets => {
  const cache = await caches.open(CACHE_NAME);
  const uniqueAssets = [...new Set(assets.filter(Boolean))];

  await Promise.all(
    uniqueAssets.map(async asset => {
      try {
        await cache.add(asset);
      } catch (_error) {
        // A stale dev asset should not prevent the offline shell fallback.
      }
    })
  );
};

const isShellAsset = url => {
  return (
    url.origin === self.location.origin &&
    (url.pathname.startsWith("/assets/") ||
      url.pathname.startsWith("/fonts/") ||
      url.pathname.startsWith("/images/") ||
      url.pathname === "/favicon.ico" ||
      url.pathname === OFFLINE_SHELL_URL)
  );
};

self.addEventListener("install", event => {
  event.waitUntil(cacheShellAssets(DEFAULT_SHELL_ASSETS).then(() => self.skipWaiting()));
});

const CACHE_PREFIX = "allbert-workspace-shell-";

const purgeOldCaches = async () => {
  const names = await caches.keys();
  await Promise.all(
    names
      .filter(name => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME)
      .map(name => caches.delete(name))
  );
};

self.addEventListener("activate", event => {
  // Delete superseded versioned caches (e.g. the v0.60 shell) before claiming
  // clients, so a cache-name bump does not orphan the previous cache forever.
  event.waitUntil(purgeOldCaches().then(() => self.clients.claim()));
});

self.addEventListener("message", event => {
  if (event.data?.type === "ALLBERT_WORKSPACE_CACHE_ASSETS") {
    event.waitUntil(cacheShellAssets(event.data.assets || []));
  }
});

self.addEventListener("fetch", event => {
  const request = event.request;
  const url = new URL(request.url);

  if (url.origin !== self.location.origin) return;

  if (request.mode === "navigate" && url.pathname.startsWith("/workspace")) {
    event.respondWith(fetch(request).catch(() => caches.match(OFFLINE_SHELL_URL)));
    return;
  }

  if (request.method === "GET" && isShellAsset(url)) {
    event.respondWith(
      caches.match(request).then(cached => {
        if (cached) return cached;

        return fetch(request).then(response => {
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
          return response;
        });
      })
    );
  }
});
