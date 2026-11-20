package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// webPreload は index.html の head が版を知った所で先に取らせる 1 本（<link rel=preload>）。
// WhyNot: As と crossorigin を取り手と違えない — 違うと preload した物が使われず、同じ物を 2 回取る。
// fetch() で取る物は "fetch"（crossorigin を付ける）、<script> で読む物は "script"（付けない）。
type webPreload struct {
	Path string
	As   string
}

// WhyNot: 並びを替えない — bundle.json が届くまで素材を取り始められず、wasm が一番大きいので、この 2 本を先に出す。
func webPreloads(b webBundle) []webPreload {
	list := []webPreload{{"bundle.json", "fetch"}}
	if b.WasmBrotli != "" {
		list = append(list, webPreload{b.WasmBrotli, "fetch"}, webPreload{webBrotliDecoderFile, "script"})
	} else {
		list = append(list, webPreload{"classes.wasm", "fetch"})
	}
	return append(list, webPreload{"wasm-gc-runtime.js", "script"}, webPreload{"fge-web.js", "script"})
}

// WhyNot: index.html に版を焼き込むだけにしない — GitHub Pages などの置き先は index.html にも max-age を付けて配り
// （ゲームの側からは変えられない）、古い index.html が残ると古い ?v= を通して前の版を丸ごと読む。
// 起動役が version.txt をキャッシュを使わずに確かめる。
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

var webScriptTagRe = regexp.MustCompile(`<script\s+src="(fge-web\.js|wasm-gc-runtime\.js)"></script>\n?`)

// 流れは docs/web-export.md の「版の確かめと preload」。
//
// WhyNot: 書き出した時の版の preload を、いつも version.txt より先に出さない — HTTP キャッシュの古い index.html だと古い ?v= を取り、
// 置き場は新しい中身を返すので、その 1 回分が丸ごと無駄になる。index.html を今ネットから取った（transferSize > 0）時だけ先に出す。
// WhyNot: その後に version.txt が別の版を返した時の 2 組目の preload を止めない — 起きるのは置き場の入れ替えの最中だけで、止めると起動の物を待つ。
// WhyNot: 自分の Service Worker の頁で version.txt を待たない — 起動の物は全部そのキャッシュにあり、往復 1 回分を待つだけになる。
// Service Worker が覚えている版の頁を返すので、版を上げた後の最初の起動では版が違い、1 回だけ読み直す。
// WhyNot: controller があるだけで自分の Service Worker と見ない — ドメインの根に置いた別のゲームの Service Worker がこの頁も受け持ち、
// index.html は HTTP キャッシュの古い物のことがある。
// WhyNot: Service Worker を見る所の例外で止めない — sandbox の iframe（opaque origin）では navigator.serviceWorker を読むだけで SecurityError になり、
// ここで止まると fgeBootVersion が決まらず何も読まない。
// WhyNot: 押した後は読み直さない — 遊び始めた所を消す。その時は古い版のまま遊び、次に開いた時に新しい版になる。
// WhyNot: 読み直しを版ごとに 1 回にしない — 置き場の入れ替えの最中は version.txt が 2 つの版の間で揺れ、読み直しが止まらない。1 つのタブで 60 秒に 1 回まで。
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
  var sw = null;
  try {
    var c = navigator.serviceWorker && navigator.serviceWorker.controller;
    if (c && c.scriptURL === new URL("sw.js", location.href).href && !/[?&]sw=0(&|$)/.test(location.search)) sw = c;
  } catch (e) { sw = null; }
  var nav = performance.getEntriesByType ? performance.getEntriesByType("navigation")[0] : null;
  if (sw || (nav && nav.transferSize > 0)) warm(baked);
  if (!sw) {
    window.fgeBootVersion = checked.then(function (c) { warm(c.v); return c.v; });
    return;
  }
  window.fgeBootVersion = Promise.resolve(baked);
  checked.then(function (c) {
    if (c.v === baked) {
      if (c.known) sw.postMessage({ type: "fge-sw-drop", keep: c.v });
      return;
    }
    if (typeof fgeAudio !== "undefined" && fgeAudio.started) return;
    try {
      var last = Number(sessionStorage.getItem("fge-sw-reload-at") || 0);
      if (Date.now() - last < 60000) return;
      sessionStorage.setItem("fge-sw-reload-at", String(Date.now()));
    } catch (e) { return; }
    location.reload();
  });
})();
</script>
`
}

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

// WhyNot: 頁の js と同じ ?v= の付いた URL で登録しない — 登録の URL が替わるたびに別の Service Worker として入れ直し、版をまたいでキャッシュを引き継げない。
// WhyNot: web.serviceWorker が false の時に sw.js を置かない形にしない — 登録済みの人は sw.js が 404 でも登録が外れない（Chrome も Safari も）。
// 自分を外す sw.js（webServiceWorkerOffSource）を置けば、次に開いた時の更新の確かめで全員から外れる。
const (
	webServiceWorkerFile      = "sw.js"
	webServiceWorkerSource    = "fge-sw.js"
	webServiceWorkerOffSource = "fge-sw-off.js"
	webServiceWorkerIDMark    = `"__FGE_GAME_ID__"`
	webSumsFile               = "sums.json"
)

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

func writeWebServiceWorker(jsDir, out, id string, on bool) error {
	if !on {
		return copyFile(filepath.Join(jsDir, webServiceWorkerOffSource), filepath.Join(out, webServiceWorkerFile))
	}
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

// writeWebSums は出力の木（index.html・version.txt・sums.json を除く全部）の 1 本ずつの sha256 を sums.json に書き、
// その sums.json の sha256 の頭 12 字を版として返す。
// WhyNot: 版を木のハッシュ 1 本にしない — Service Worker は置き場の入れ替えの最中に届いた物（新しい版の URL に古い中身）を見分けられず、
// 入れたら次の版まで残る。1 本ずつのハッシュの表があれば、入れる前に中身を照らせる。表のハッシュが版なので、表そのものも版と照らせる。
// WhyNot: wasm と bundle.json だけから作らない — Doc や fge-web.js だけを直した書き出しで版が変わらず、置き先のキャッシュが古い物を配る。
func writeWebSums(out string) (string, error) {
	sums := map[string]string{}
	err := filepath.WalkDir(out, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, err := filepath.Rel(out, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if rel == "index.html" || rel == "version.txt" || rel == webSumsFile {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		h := sha256.Sum256(data)
		sums[rel] = hex.EncodeToString(h[:])
		return nil
	})
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(sums)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(out, webSumsFile), data, 0o644); err != nil {
		return "", err
	}
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])[:12], nil
}
