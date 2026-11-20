// fge-sw-off.js — project.json の web.serviceWorker が false の時に、bin/fge export-web が sw.js として置く。
// WhyNot: fetch を受けない — 受けなければ頁の物は全部素のネットへ行き、前の Service Worker のキャッシュは使われない。
// WhyNot: 開いている頁を読み直させない（clients の navigate）— 押して遊んでいる頁を消す。fetch を受けないので、そのまま遊んでいても古い物は出ない。
"use strict";

var FGE_SCOPE_PATH = new URL(self.registration.scope).pathname;

self.addEventListener("install", function (event) {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", function (event) {
  event.waitUntil(caches.keys().then(function (names) {
    return Promise.all(names.filter(function (name) {
      return name.indexOf("fge-sw:") === 0 && name.indexOf(":" + FGE_SCOPE_PATH + ":") > 0;
    }).map(function (name) { return caches.delete(name); }));
  }).catch(function () { /* 消せない時も外す */ }).then(function () {
    return self.registration.unregister();
  }));
});
