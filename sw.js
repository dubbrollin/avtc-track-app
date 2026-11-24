// This old copy of the VYC track app has moved to
// https://vycregistration.avyouthathletics.org. This worker replaces the old
// offline one: it deletes every saved copy of the old pages, removes itself,
// and reloads any open tab so it lands on the redirect to the real site.
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys()
      .then(function (keys) { return Promise.all(keys.map(function (k) { return caches.delete(k); })); })
      .then(function () { return self.registration.unregister(); })
      .then(function () { return self.clients.matchAll({ type: 'window' }); })
      .then(function (tabs) { tabs.forEach(function (t) { t.navigate(t.url); }); })
  );
});
