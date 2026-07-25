/* Minimal service worker: network-first passthrough (needed for PWA install).
 * No caching of authed pages — the console must always show live data. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (e) => {
  e.respondWith(
    fetch(e.request).catch(
      () => new Response('NWP Console is unreachable — are you on the mesh (VPN app connected)?',
        { status: 503, headers: { 'Content-Type': 'text/plain' } })
    )
  );
});
