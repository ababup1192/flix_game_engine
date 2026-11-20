// fge-sw.js — 書き出しの Service Worker。bin/fge export-web が書き出しの根へ sw.js として置き、束の id の所を替える。
// 何をどう返すかは docs/web-export.md の「起動の始まりと 2 回目からの起動」。
"use strict";

var FGE_GAME_ID = "__FGE_GAME_ID__";
var FGE_SCOPE = self.registration.scope;
var FGE_SCOPE_PATH = new URL(FGE_SCOPE).pathname;
var FGE_PREFIX = "fge-sw:" + FGE_GAME_ID + ":" + FGE_SCOPE_PATH + ":";
var FGE_META = FGE_PREFIX + "meta";
var FGE_VERSION_URL = FGE_SCOPE + "version.txt";
var FGE_INDEX_URL = FGE_SCOPE + "index.html";
var FGE_VERSION_RE = /^[0-9a-f]{6,64}$/;
// WhyNot: 頁の version.txt を毎回もう一度ネットへ出さない — 頁を開く時に index.html の所で確かめたばかりで、同じ答えを往復 1 回分待つだけになる。
var FGE_CHECK_REUSE_MS = 10000;
var fgeLatest = null;
var fgeCheck = null;

function fgeCacheName(version) { return FGE_PREFIX + "v" + version; }

self.addEventListener("install", function (event) {
  event.waitUntil(fgeCheckVersion(false).catch(function () { return null; }).then(function () { return self.skipWaiting(); }));
});

// WhyNot: 次に開くまで待たずに今の頁を受け持つ — 初めての頁が後から取る後回しの素材もキャッシュへ入り、2 回目の起動に間に合う。
self.addEventListener("activate", function (event) {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", function (event) {
  var req = event.request;
  if (req.method !== "GET" || req.url.indexOf(FGE_SCOPE) !== 0) return;
  var url = new URL(req.url);
  var path = url.origin + url.pathname;
  if (req.mode === "navigate") {
    if (path !== FGE_SCOPE && path !== FGE_INDEX_URL) return;
    // WhyNot: ?sw=0 の頁をキャッシュから返さない — 壊れたキャッシュで起動の途中に落ちると、頁の側の外す処理まで届かない。
    if (url.searchParams.get("sw") === "0") {
      event.waitUntil(fgeRemoveSelf());
      return;
    }
    var later = fgeLater(event);
    event.respondWith(later.until(fgeOrNetwork(fgeServeIndex(later), req)));
    return;
  }
  var version = url.searchParams.get("v");
  // WhyNot: Range の付いた物を受けない — 版のキャッシュは丸ごとの 200 だけを持ち、206 を作り直すより素のネットへ回す方が確か。
  if (path !== FGE_VERSION_URL && (!version || req.headers.has("range"))) return;
  var work = fgeLater(event);
  event.respondWith(work.until(fgeOwnClient(event).then(function (own) {
    if (!own) return fetch(req);
    return fgeOrNetwork(path === FGE_VERSION_URL ? fgeServeVersion() : fgeServeVersioned(req, version, work), req);
  })));
});

self.addEventListener("message", function (event) {
  var d = event.data;
  if (d && d.type === "fge-sw-cache" && Array.isArray(d.urls)) {
    event.waitUntil(fgeCacheUrls(d.urls).catch(function (e) { console.warn("[fge-sw] 先に入れられない: " + (e && e.message || e)); }));
  } else if (d && d.type === "fge-sw-drop" && typeof d.keep === "string") {
    event.waitUntil(fgeDropOtherVersions(d.keep, event.source && event.source.id).catch(function () { /* 次の頁が消す */ }));
  }
});

// fgeLater は fetch の後ろで続ける仕事（キャッシュへ入れる）を、応答と一緒に待たせる。
// WhyNot: 応答を返した後の then の中で event.waitUntil を呼ばない — respondWith を寿命の延長に数えない版では、その時にはもう呼べず例外になり、同じ物を 2 回取る。
function fgeLater(event) {
  var jobs = [];
  var done;
  event.waitUntil(new Promise(function (r) { done = r; }));
  return {
    add: function (p) { jobs.push(p.catch(function () { /* 入らなくても次にネットから取る */ })); },
    until: function (main) {
      main.then(function () { return null; }, function () { return null; }).then(function () { return Promise.all(jobs); }).then(done, done);
      return main;
    }
  };
}

// WhyNot: 自分の scope の頁でない物を受けない — ドメインの根に置いたゲームの Service Worker は、まだ自分のを持たない
// サブフォルダのゲームの頁も受け持つ。その頁の ?v= を根のゲームの版で入れると、版の違う物を混ぜる。
function fgeOwnClient(event) {
  if (!event.clientId) return Promise.resolve(true);
  return self.clients.get(event.clientId).then(function (c) {
    if (!c) return true;
    var p = new URL(c.url).pathname;
    return p === FGE_SCOPE_PATH || p === FGE_SCOPE_PATH + "index.html";
  }, function () { return true; });
}

function fgeOrNetwork(promise, req) {
  return promise.catch(function (e) {
    console.warn("[fge-sw] " + req.url + " を素のネットへ回す: " + (e && e.message || e));
    return fetch(req);
  });
}

function fgeRemoveSelf() {
  return self.registration.unregister().then(function () { return fgeDeleteCaches(function () { return true; }); });
}

// 書き出しのフォルダの物を消す。束の id を替えて書き出し直した時の古い id の分も入る。
function fgeDeleteCaches(drop) {
  return caches.keys().then(function (names) {
    return Promise.all(names.filter(function (name) {
      return name.indexOf("fge-sw:") === 0 && name.indexOf(":" + FGE_SCOPE_PATH + ":") > 0 && drop(name);
    }).map(function (name) { return caches.delete(name); }));
  });
}

// ── 版 ──
function fgeStoredVersion() {
  if (fgeLatest) return Promise.resolve(fgeLatest);
  return caches.match(FGE_VERSION_URL, { cacheName: FGE_META }).then(function (res) {
    return res ? res.text() : "";
  }).then(function (t) {
    t = t.trim();
    if (FGE_VERSION_RE.test(t) && !fgeLatest) fgeLatest = t;
    return fgeLatest;
  });
}

// fgeCheckVersion は version.txt をネットから取る。fromNav は頁を開いた所の確かめ。
// fgeReuseNavCheck は頁の version.txt に、その頁を開いた所で始めた確かめの答えを使う。
// WhyNot: 頁を開くたびの確かめに前の答えを使わない — 続けて開いた間に版が上がると、古い版のまま読み直さない。
function fgeReuseNavCheck() {
  if (fgeCheck && fgeCheck.nav && Date.now() - fgeCheck.at < FGE_CHECK_REUSE_MS) return fgeCheck.promise;
  return fgeCheckVersion(false);
}

function fgeCheckVersion(fromNav) {
  var check = { at: Date.now(), nav: fromNav, promise: null };
  check.promise = fetch(FGE_VERSION_URL, { cache: "no-store" }).then(function (res) {
    if (!res.ok) throw new Error("version.txt が " + res.status);
    return res.text();
  }).then(function (t) {
    t = t.trim();
    if (!FGE_VERSION_RE.test(t)) throw new Error("version.txt が版の形でない");
    return fgeSetLatest(t).then(function () { return t; });
  });
  check.promise.catch(function () { if (fgeCheck === check) fgeCheck = null; });
  fgeCheck = check;
  return check.promise;
}

// fgeCheckAfterNow は今より後に始める確かめの答え。続けて届いた物はまとめて 1 回の確かめで答える。
// WhyNot: 届いた 1 本ごとに確かめない — 版を上げた後の最初の起動は全部がキャッシュに無く、百本の version.txt が出る。
var FGE_CHECK_BATCH_MS = 2000;
var fgeCheckLater = null;
function fgeCheckAfterNow() {
  if (fgeCheckLater) return fgeCheckLater;
  fgeCheckLater = new Promise(function (resolve) { setTimeout(resolve, FGE_CHECK_BATCH_MS); }).then(function () {
    fgeCheckLater = null;
    return fgeCheckVersion(false);
  });
  return fgeCheckLater;
}

function fgeSetLatest(version) {
  fgeLatest = version;
  return caches.open(FGE_META).then(function (cache) {
    return cache.put(FGE_VERSION_URL, new Response(version + "\n", { headers: { "Content-Type": "text/plain" } }));
  });
}

// WhyNot: 新しい版が見えた所で古い版を消さない — 押して遊び始めた頁は古い版のまま続け（読み直さない）、後から取る物を古い版のキャッシュから取る。
// 消すと素のネットへ行き、置き場の新しい中身が古い版の URL で届く。
// WhyNot: 今の版でない頁の知らせでは消さない — 古い版の頁が新しい版のキャッシュを消す。
// WhyNot: 知らせてきた頁の他に、この scope の頁が開いている間は消さない — 別のタブで古い版のまま遊んでいるかもしれない。次に開いた時に消す。
function fgeDropOtherVersions(keep, senderId) {
  return Promise.all([fgeStoredVersion(), self.clients.matchAll({ type: "window" })]).then(function (got) {
    if (got[0] !== keep) return;
    var others = got[1].filter(function (c) { return c.id !== senderId && c.url.indexOf(FGE_SCOPE) === 0; });
    if (others.length > 0) return;
    return fgeDeleteCaches(function (name) { return name !== FGE_META && name !== fgeCacheName(keep); });
  });
}

function fgeServeVersion() {
  return fgeReuseNavCheck().catch(function (e) {
    return fgeStoredVersion().then(function (stored) {
      if (!stored) throw e;
      return stored;
    });
  }).then(function (version) {
    return new Response(version + "\n", { headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" } });
  });
}

// ── 頁 ──
// WhyNot: index.html を返す前に版の答えを待たない — 往復 1 回分が起動に乗る。返した後に頁が version.txt で確かめ、違えば読み直す。
function fgeServeIndex(later) {
  later.add(fgeCheckVersion(true));
  return fgeStoredVersion().then(function (version) {
    if (!version) return null;
    return caches.match(FGE_INDEX_URL, { cacheName: fgeCacheName(version) });
  }).then(function (hit) {
    return hit || fgeFetchIndex(FGE_INDEX_URL, "no-cache", later);
  });
}

// WhyNot: 返す頁をブラウザの HTTP キャッシュから取らない（no-cache）— 置き場が max-age を付けて配り、版の上がった後も古い頁が出る。
// WhyNot: 届いた頁を版を見ずに今の版の所へ入れない — 置き場の入れ替えの途中や HTTP キャッシュからだと別の版の頁が届く。
// 頁の中の版（起動役の baked）が、届いた後に始めた version.txt の答え（fgeCheckAfterNow）と同じ時だけ、その版の所へ入れる。
function fgeFetchIndex(url, mode, later) {
  return fetch(url, { cache: mode, credentials: "same-origin" }).then(function (res) {
    if (res.redirected) throw new Error("index.html が転送された");
    if (res.status !== 200 || res.type !== "basic") return res;
    var keep = res.clone();
    later.add(res.clone().text().then(function (html) {
      var m = /var baked = "([0-9a-f]{6,64})";/.exec(html);
      if (!m) return;
      return fgeCheckAfterNow().then(function (latest) {
        if (latest !== m[1]) return;
        return caches.open(fgeCacheName(latest)).then(function (cache) { return cache.put(FGE_INDEX_URL, keep); });
      });
    }));
    return res;
  });
}

// ── 版の付いた物 ──
// WhyNot: 覚えている版だけを見て入れない — 遊んでいる間に版が上がると、置き場の新しい中身が古い版の URL で届く。
// 届いた後に始めた version.txt の答えが同じ版の時だけ、中身はその版と言える（fgeCheckAfterNow）。
function fgeServeVersioned(req, version, later) {
  return caches.match(req.url, { cacheName: fgeCacheName(version), ignoreVary: true }).then(function (hit) {
    if (hit) return hit;
    return fetch(req).then(function (res) {
      if (res.status === 200 && res.type === "basic") later.add(fgePutChecked(req.url, version, res.clone()));
      return res;
    });
  });
}

function fgePutChecked(url, version, res) {
  return fgeCheckAfterNow().then(function (latest) {
    if (latest !== version) return;
    return caches.open(fgeCacheName(version)).then(function (cache) { return cache.put(url, res); });
  });
}

// 初めての頁は Service Worker が受け持つ前に起動の物を取り終えている。頁が取った URL を送ってくるので、HTTP キャッシュから写す。
function fgeCacheUrls(urls) {
  return fgeStoredVersion().then(function (stored) {
    return stored || fgeCheckVersion(false).catch(function () { return null; });
  }).then(function (version) {
    if (!version) return;
    var todo = urls.filter(function (u) { return typeof u === "string" && u.indexOf(FGE_SCOPE) === 0; });
    var puts = [];
    var later = { add: function (p) { puts.push(p.catch(function () { /* 1 本落ちても残りは入れる */ })); } };
    var next = function () {
      var u = todo.shift();
      if (u === undefined) return Promise.resolve();
      return fgeCacheOne(version, u, later).catch(function () { /* 1 本落ちても残りは入れる */ }).then(next);
    };
    return Promise.all([next(), next(), next(), next()]).then(function () { return Promise.all(puts); });
  });
}

function fgeCacheOne(version, u, later) {
  var url = new URL(u);
  var path = url.origin + url.pathname;
  var name = fgeCacheName(version);
  if (path === FGE_SCOPE || path === FGE_INDEX_URL) {
    return caches.match(FGE_INDEX_URL, { cacheName: name }).then(function (hit) {
      return hit ? null : fgeFetchIndex(u, "default", later);
    });
  }
  if (url.searchParams.get("v") !== version) return Promise.resolve();
  return caches.match(u, { cacheName: name, ignoreVary: true }).then(function (hit) {
    if (hit) return null;
    return fetch(u, { credentials: "same-origin" }).then(function (res) {
      if (res.status === 200 && res.type === "basic") later.add(fgePutChecked(u, version, res));
    });
  });
}
