// Service worker for the installable app. Pages and app files are fetched fresh whenever there is a connection
// (so every push shows up right away) and the last good copy is kept for when there isn't.
// Supabase (all app data, sign-in, uploads) is never cached — it always goes straight to the network.
var VERSION = 'vyc-app-46';
var SHELL = ['./', 'home.html', 'index.html', 'parent.html', 'coach.html', 'entries.html', 'results.html', 'schedule.html', 'team.html', 'team-hub.js',
  'theme.css', 'theme.js', 'config.js', 'shared.js', 'events.js', 'logo.png', 'manifest.webmanifest',
  'icons/icon-192.png', 'icons/apple-touch-icon.png'];
var CDN = ['cdn.tailwindcss.com', 'cdn.jsdelivr.net', 'cdnjs.cloudflare.com', 'fonts.googleapis.com', 'fonts.gstatic.com'];

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(VERSION).then(function (c) {
    return Promise.all(SHELL.map(function (u) { return c.add(u).catch(function () {}); }));
  }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return k !== VERSION; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

self.addEventListener('fetch', function (e) {
  var req = e.request;
  if (req.method !== 'GET') return;
  var url = new URL(req.url);
  // On the server (track.avyouthathletics.org) app data, sign-in, uploads, live updates and functions share this address: never cache them.
  if (url.origin === self.location.origin && /^\/(rest|auth|storage|realtime|functions)\/v1\//.test(url.pathname)) return;

  // Same-site pages and files: network first, fall back to the saved copy, then to the Home page.
  if (url.origin === self.location.origin) {
    e.respondWith(fetch(req).then(function (res) {
      if (res && res.ok) { var copy = res.clone(); caches.open(VERSION).then(function (c) { c.put(req, copy); }); }
      return res;
    }).catch(function () {
      return caches.match(req, { ignoreSearch: true }).then(function (hit) {
        return hit || (req.mode === 'navigate' ? caches.match('home.html') : Response.error());
      });
    }));
    return;
  }

  // Pinned CDN libraries and fonts: saved copy first (they never change), refreshed in the background.
  if (CDN.indexOf(url.hostname) !== -1) {
    e.respondWith(caches.open(VERSION).then(function (c) {
      return c.match(req).then(function (hit) {
        var net = fetch(req).then(function (res) { if (res && (res.ok || res.type === 'opaque')) c.put(req, res.clone()); return res; })
          .catch(function (err) { if (hit) return hit; throw err; });
        return hit || net;
      });
    }));
  }
  // Everything else (Supabase, Stripe, maps…) is left alone.
});

// App notifications: the msg-notify server function pushes { title, body, url, tag } for a new team message.
self.addEventListener('push', function (e) {
  var d = {}; try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || 'VYC Track & Field', {
    body: d.body || 'You have a new team message.', icon: 'icons/icon-192.png', badge: 'icons/icon-192.png',
    tag: d.tag || 'vyc-msg', renotify: true, data: { url: d.url || 'home.html' }
  }));
});
// Tapping the notification opens (or focuses) the app on the messages.
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || 'home.html', self.location.href).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) { if (list[i].url.indexOf(self.location.origin) === 0 && 'focus' in list[i]) { list[i].navigate(url); return list[i].focus(); } }
    return self.clients.openWindow(url);
  }));
});
