package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// webPreload は index.html の head が版を知った所で先に取らせる 1 本（<link rel=preload>）。
// As は preload の as。fetch() で取る物は "fetch"（crossorigin を付ける）、<script> で読む物は "script"（付けない）。
// WhyNot: as と crossorigin を取り手と違えない — 違うと preload した物が使われず、同じ物を 2 回取る。
type webPreload struct {
	Path string
	As   string
}

// webPreloads は起動の最初に要る物を、起動を詰まらせる順に返す。
// bundle.json が届くまで素材を取り始められず、wasm が一番大きいので、この 2 本を先に出す。
func webPreloads(b webBundle) []webPreload {
	list := []webPreload{{"bundle.json", "fetch"}}
	if b.WasmBrotli != "" {
		list = append(list, webPreload{b.WasmBrotli, "fetch"}, webPreload{webBrotliDecoderFile, "script"})
	} else {
		list = append(list, webPreload{"classes.wasm", "fetch"})
	}
	return append(list, webPreload{"wasm-gc-runtime.js", "script"}, webPreload{"fge-web.js", "script"})
}

// stampWebIndex は index.html に起動役を入れる。head の終わりに版を確かめて preload を出す役、
// wasm-gc-runtime.js と fge-web.js の <script src> の所に、確かめた版の ?v= を付けて 2 つの js を順に読む役を置く。
// 起動役は version.txt をキャッシュを使わずに取り（13 バイト）、取れない時（オフライン・3 秒で返らない）は書き出した時の版 hash で読む。
// WhyNot: index.html に版を焼き込むだけにしない — GitHub Pages などの置き先は index.html にも max-age を付けて配り
// （ゲームの側からは変えられない）、古い index.html が残ると古い ?v= を通して前の版を丸ごと読む。
// 版の付いた URL（wasm・素材・js）は中身が変わると URL も変わるので、キャッシュに任せたままでよい。
func stampWebIndex(html, hash string, preload []webPreload) (string, error) {
	seen := map[string]bool{}
	first := -1
	for _, loc := range webScriptTagRe.FindAllStringSubmatchIndex(html, -1) {
		seen[html[loc[2]:loc[3]]] = true
		if first < 0 {
			first = loc[0]
		}
	}
	for _, name := range []string{"wasm-gc-runtime.js", "fge-web.js"} {
		if !seen[name] {
			return "", fmt.Errorf(`<script src="%s"> が無い。次: index.html の script の行を確かめる`, name)
		}
	}
	head := strings.Index(html, "</head>")
	if head < 0 || head > first {
		return "", fmt.Errorf("script の行より前に </head> が無い。次: index.html の head を閉じる")
	}
	rest := webScriptTagRe.ReplaceAllString(html[first:], "")
	return html[:head] + webHeadScript(hash, preload) + html[head:first] + webBootScript + strings.TrimLeft(rest, "\n"), nil
}

// webScriptTagRe は index.html の 2 つの js を読む行（行末の改行ごと）。
var webScriptTagRe = regexp.MustCompile(`<script\s+src="(fge-web\.js|wasm-gc-runtime\.js)"></script>\n?`)

// webHeadScript は head の起動役。版（fgeBootVersion）を決め、その版の preload を出す。
// 流れは docs/web-export.md の「版の確かめと preload」。
//
// WhyNot: 書き出した時の版の preload を、いつも version.txt より先に出さない — HTTP キャッシュの古い index.html だと古い ?v= を取り、
// 置き場は新しい中身を返すので、その 1 回分が丸ごと無駄になる。index.html を今ネットから取った（transferSize > 0）時だけ先に出す。
// WhyNot: その後に version.txt が別の版を返した時の 2 組目の preload を止めない — 起きるのは置き場の入れ替えの最中だけで、止めると起動の物を待つ。
// WhyNot: 自分の Service Worker の頁で version.txt を待たない — 起動の物は全部そのキャッシュにあり、往復 1 回分を待つだけになる。
// Service Worker が覚えている版の頁を返すので、版を上げた後の最初の起動では版が違い、1 回だけ読み直す。
// WhyNot: controller があるだけで自分の Service Worker と見ない — ドメインの根に置いた別のゲームの Service Worker がこの頁も受け持ち、
// index.html は HTTP キャッシュの古い物のことがある。
// WhyNot: 押した後は読み直さない — 遊び始めた所を消す。その時は古い版のまま遊び、次に開いた時に新しい版になる。
// WhyNot: 3 秒で打ち切った時に他の版のキャッシュを消させない — version.txt が答えていないので、今の版かどうか分からない。
func webHeadScript(hash string, preload []webPreload) string {
	items := make([]string, 0, len(preload))
	for _, p := range preload {
		items = append(items, fmt.Sprintf("[%q, %q]", p.Path, p.As))
	}
	return `<script>
(function () {
  var baked = "` + hash + `";
  var preload = [` + strings.Join(items, ", ") + `];
  var warmed = "";
  function warm(v) {
    if (warmed === v) return;
    warmed = v;
    preload.forEach(function (p) {
      var l = document.createElement("link");
      l.rel = "preload";
      l.as = p[1];
      l.href = p[0] + "?v=" + encodeURIComponent(v);
      if (p[1] === "fetch") l.crossOrigin = "anonymous";
      document.head.appendChild(l);
    });
  }
  var checked = new Promise(function (resolve) {
    var guess = { v: baked, known: false };
    setTimeout(function () { resolve(guess); }, 3000);
    try {
      fetch("version.txt", { cache: "no-store" })
        .then(function (r) { return r.ok ? r.text() : ""; })
        .then(function (t) {
          t = t.trim();
          resolve(/^[0-9a-f]{6,64}$/.test(t) ? { v: t, known: true } : guess);
        }, function () { resolve(guess); });
    } catch (e) { resolve(guess); }
  });
  var sw = navigator.serviceWorker && navigator.serviceWorker.controller;
  var controlled = !!sw && sw.scriptURL === new URL("sw.js", location.href).href && !/[?&]sw=0(&|$)/.test(location.search);
  var nav = performance.getEntriesByType ? performance.getEntriesByType("navigation")[0] : null;
  if (controlled || (nav && nav.transferSize > 0)) warm(baked);
  if (!controlled) {
    window.fgeBootVersion = checked.then(function (c) { warm(c.v); return c.v; });
    return;
  }
  window.fgeBootVersion = Promise.resolve(baked);
  checked.then(function (c) {
    var v = c.v;
    if (v === baked) {
      if (c.known) sw.postMessage({ type: "fge-sw-drop", keep: v });
      return;
    }
    if (typeof fgeAudio !== "undefined" && fgeAudio.started) return;
    try {
      if (sessionStorage.getItem("fge-sw-reload") === v) return;
      sessionStorage.setItem("fge-sw-reload", v);
    } catch (e) { return; }
    location.reload();
  });
})();
</script>
`
}

// webBootScript は body の起動役。head が決めた版（fgeBootVersion）の ?v= を付けて 2 つの js を順に読む。
const webBootScript = `<script>
fgeBootVersion.then(function (v) {
  ["wasm-gc-runtime.js", "fge-web.js"].forEach(function (name) {
    var s = document.createElement("script");
    s.src = name + "?v=" + encodeURIComponent(v);
    s.async = false;
    document.body.appendChild(s);
  });
});
</script>
`

// webServiceWorkerFile は書き出しの根に置く Service Worker（engine_web/js の webServiceWorkerSource から作る）。
// WhyNot: 頁の js と同じ ?v= の付いた URL で登録しない — 登録の URL が替わるたびに別の Service Worker として入れ直し、版をまたいでキャッシュを引き継げない。
const (
	webServiceWorkerFile   = "sw.js"
	webServiceWorkerSource = "fge-sw.js"
	webServiceWorkerIDMark = `"__FGE_GAME_ID__"`
)

// project.json の web.serviceWorker（書かなければ入れる）。
type webServiceWorkerSettings struct {
	ServiceWorker *bool `json:"serviceWorker"`
}

func resolveWebServiceWorker(raw json.RawMessage) (bool, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return true, nil
	}
	var s webServiceWorkerSettings
	if err := json.Unmarshal(raw, &s); err != nil {
		return false, fmt.Errorf("project.json の web.serviceWorker を読めない: %v\n  次: true か false にする", err)
	}
	return s.ServiceWorker == nil || *s.ServiceWorker, nil
}

// writeWebServiceWorker は engine_web/js/fge-sw.js の束の id の所を id に替えて out/sw.js に置く。
func writeWebServiceWorker(jsDir, out, id string) error {
	src, err := os.ReadFile(filepath.Join(jsDir, webServiceWorkerSource))
	if err != nil {
		return err
	}
	if !strings.Contains(string(src), webServiceWorkerIDMark) {
		return fmt.Errorf("%s に %s が無い。次: engine_web/js の Service Worker を確かめる", webServiceWorkerSource, webServiceWorkerIDMark)
	}
	quoted, err := json.Marshal(id)
	if err != nil {
		return err
	}
	sw := strings.Replace(string(src), webServiceWorkerIDMark, string(quoted), 1)
	return os.WriteFile(filepath.Join(out, webServiceWorkerFile), []byte(sw), 0o644)
}
