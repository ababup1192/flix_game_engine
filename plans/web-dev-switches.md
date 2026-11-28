# ブラウザ版の頁の旗を URL の 1 つの鍵（`?fge=`）と `window.fgeDev` にまとめる（設計・1 稿）

> 状態: 設計案（実装なし・engine / go / docs は未変更）。engine の変更を含むので、入れる前に人と相談する。
> 読んだ物: `engine_web/js/{fge-web.js,fge-sw.js,fge-sw-off.js,index.html}`・`engine_web/java/fge/web/Browser.java`・
> `engine_web/src/WebLayer.flix`・`engine_web/src/WebLayer/Internal/WebGpuLayer.flix`・`src/engine_world/App/DevTools.flix`・
> `engine_world/test/TestDevToolsBrowser.flix`・`go/exportweb_{browsercheck,tapcheck,page}.go`・`go/cmd_{webcapture,webbench,webcheck}.go`・
> `go/internal/cdp/{capture,page,input}.go`・`go/internal/tape/template.html`・`bin/web-pages-stage.sh`・`Makefile`（webgpu-v1-check-web・bench-web）・
> `bench/common/bench-overlay.js`・`bench/hd2d_town/{Makefile,web/measure.js}`・`templates/hd2d-starter/web/WebMain.flix`・
> `docs/{web-export,web-capture,startup,backend-parity}.md`・`docs/migrations/0.106.0.md`・`agents-pack/AGENTS.core.md`・`agents-pack/agent-eval/engine.json`・
> `plans/web-js-thin.md`（頁の JS のテストの組み方と、`AddInitScript` でテスト用の値を入れる前例）。
> Studio（`~/Desktop/flix_ge_studio`）は頁の旗を使っていない（URL の鍵の字で探して 0 件。Studio の preview は JVM の窓で、頁を開かない）。

## 0. 何を解くか

ブラウザ版の頁（`bin/fge export-web` の書き出し）は、URL のクエリを 2 つの用途に使っている。

1. **頁の旗**: `fge-web.js`（と Flix の一部）が読む、開発と測りの切り替え。
2. **ゲームの Start**: `WebLayer.devTools()` で起こすゲームは、クエリの最初の鍵を Start の名前、全部の鍵と値を Start の引数にする（`?talk=Lair&line=46`）。

両方が同じ場所に並ぶので、engine は「Start に混ぜない鍵の一覧」`App.DevTools.pageQueryKeys` を持つ。旗を足して一覧に足し忘れると、
旗が Start の名前になる（例 `?fps=1&talk=Lair` → Start は `fps`。知らない名前なので先頭の Start で開き、console に訳を出す）。
今の一覧は 7 つ（`input` `size` `orientation` `glcheck` `loadtime` `capture` `fps`）で、5 つ（`backend` `deferred` `net` `sw` `usedAssets`）を足す直しが別の担当で入っている。
**調べて分かった 13 個目**: `webgpuFail`（WebGpuLayer.prepare が読む、GL へ落ちる道を起こす旗）も一覧に無く、今も Start に混ざる。

人の方針は「クエリパラメータをあまり増やしたくない」。決めた形:

- 測る道具だけが使う物は URL から外し、道具が CDP で頁を開く時に `window.fgeDev = {…}` を頁のどの script より先に入れる。
- 人がスマホで試す物は `?fge=fps,webgl2,4g` の 1 つの鍵に並べる。engine が外すのは `fge` だけ（一覧は要らなくなる）。
- 前の鍵は 1 版のあいだ読んで console に「`?fge=…` に替わった」と出し、次の版で外す。

この文書は、その形を実装に落とすための棚卸しと手順。§9 に人に決めてもらう事をまとめた。

## 1. 今の 13 個の旗の棚卸し

「読む所」は全部 `engine_web/js/fge-web.js` の中（関数名か変数名）。Flix の側で読むのは `capture` と `webgpuFail` の 2 つだけ（`WebLayer.Internal.WebGpuLayer.prepare` が
`Browser.queryPairs()` を `queryValueOf` で引く）。そのほかの Flix の口（`Browser.isCoarsePointer`・`sizeOverride`・`wantsPortrait`・`isFrameCapture`）は
`Browser.java` の `@JSBody` が JS の変数（`fgeCoarseAtBoot`・`fgeSizeOverride`・`fgeWantsPortrait()`・`fgeCaptureFrame`）を読むだけで、URL を直に見ない。

| 鍵 | 値の形 | 読む所 | 書く所（URL を作る所・案内する所） | 使う人 |
|---|---|---|---|---|
| `capture` | 正の整数（コマ数） | `fgeCaptureFrame`（`fgeQueryParam`）・`fgeServiceWorkerStart`（撮る頁は登録しない）・`fgeNetStartClock` の時刻の起点・Flix の `WebGpuLayer.prepare`（`captureFrame`） | ⑨ `checkWebLoadsRecording`・⑨' `checkWebMissingTitle`・`cmdWebCapture` の使い方の字・`bin/web-pages-stage.sh` の 5.・Makefile `webgpu-v1-check-web`・docs/web-capture.md・docs/startup.md・早見表 180 行 | 道具 |
| `usedAssets` | `1` | `fgeUsedAssets`（`window.fgeUsedAssets`） | ⑨ `checkWebLoadsRecording`（`&usedAssets=1`）・docs/web-export.md・テスト `TestCheckWebLoadsRecordingReadsUsedAssetsFromTitlePage` | 道具 |
| `deferred` | `all` | 起動の関数の `await wasmLoad` の後（全部届くまで main を呼ばない） | `bin/web-pages-stage.sh`・Makefile `webgpu-v1-check-web`・docs/startup.md | 道具 |
| `loadtime` | `1` | `fgeDecodeTimes` | docs/startup.md・docs/web-export.md・sound-novel-starter/README.md | 道具（人も手で開いて console を見る） |
| `glcheck` | `1` | `fgeCheckedGl` | docs/backend-parity.md・docs/web-export.md | 道具（人も手で使う。fps3d_lab の確かめ） |
| `webgpuFail` | `prepare` / `canvas` | Flix `WebGpuLayer.prepare`（`queryValueOf("webgpuFail")`） | plans だけ（docs に無い） | 道具（手で落ちる道を確かめる時） |
| `net` | `4g` | `fgeNet4g`（`fgeNetGate`・`fgeNoteUsed`） | ⑨' `checkWebMissingTitle`・⑨'' `measureWebTapWait`・docs/web-export.md・docs/startup.md・早見表 136 行・`exportweb_deferred.go` などのコメント | 両方（門は道具・人も手で「開いてすぐ押す」を見る） |
| `fps` | `1` | `fgeWireFpsOverlay` | `bin/web-pages-stage.sh` の最後の行・`bench/hd2d_town/Makefile` の explore-serve・docs/web-export.md・早見表 131 行・お題 `web-measure-fps` | 人 |
| `backend` | `webgl2` / `gl`（ほかの値は既定の WebGPU） | `fgeBackendParam` → `fgeAskedWebGl2`・**書きもする**: `fgeFallbackToWebGl2` が WebGPU で落ちた時に `backend=webgl2` を付けて開き直す | ⑨ `checkWebLoadsRecording`（`&backend=webgl2`）・Makefile `webgpu-v1-check-web`・docs/backend-parity.md・docs/web-capture.md・早見表 108・131 行・お題 `try-webgpu-backend`・`bench/sprite_stress/RESULTS.md`（`ARGS` に `&backend=webgpu`） | 両方 |
| `sw` | `0` | `fgeServiceWorkerStart`（fge-web.js）・**fge-sw.js** の `fetch`（navigate の URL）と `fgeOwnClient`（頁の URL）・**頭の script**（Go の `webHeadScript` が index.html に書く、`!/[?&]sw=0(&|$)/`） | docs/web-export.md（「壊れた時に抜け出す口」）・早見表 139 行 | 人（遊ぶ人が抜け出す口） |
| `input` | `touch` / `mouse` | `fgeInputOverride`（正規表現で `location.search` を直に見る） | docs/startup.md・docs/web-export.md・早見表 118 行 | 人（PC で指の並べ方を見る） |
| `size` | `small` / `medium` / `large`（**WxH ではない**。WxH は `web-capture --size` の旗で、頁の鍵ではない） | `fgeSizeOverride`（正規表現） | docs/web-export.md・早見表 118 行 | 人 |
| `orientation` | `portrait` / `landscape` | `fgeOrientationOverride`（正規表現）→ `fgeWantsPortrait` | **Tape の頁** `go/internal/tape/template.html` の `syncStartBtn`（「はじめから遊ぶ」の href に `?orientation=`）・テスト `go/internal/tape/views_test.go`・docs/web-export.md | 人（と Tape） |

ゲームやベンチが自分で読む鍵（engine の物ではない・この計画では触らない）: bench の `knobsOfPairs` のつまみ（`n` `tex` `frames` …）、
`templates/hd2d-starter` の `Knobs.ofPairs`、`bench/hd2d_town/web/measure.js` の `measure`、Tape の頁の `view`。
どれも `Browser.queryPairs()` を自分で読むので、`fge` の鍵が残っていても「余った鍵は捨てる」で困らない（`Knobs.ofPairs` の doc の通り）。

### 1.1 頁の外から URL の旗を読む所が 3 か所ある（Service Worker）

`sw` だけは頁の JS の外でも読む。

1. `webHeadScript`（Go の文字列。書き出しが index.html の `<head>` に入れる。fge-web.js より先に動く）
2. `fge-sw.js` の `fetch`（navigate の URL）と `fgeOwnClient`（頁の URL）。**Service Worker は `window` を持たないので `window.fgeDev` を読めない。URL しか見られない**
3. `fge-web.js` の `fgeServiceWorkerStart`

## 2. `?fge=` の書き方

### 2.1 字の決まり

- `?fge=<語>,<語>,…`。区切りはコンマ（URL のままで打てる・`%2C` にしなくても `URLSearchParams` が読む）。
- 語は `名前` か `名前:値`。大文字と小文字を区別しない（スマホで打つ時の頭の大文字を許す）。
- 値を持つ旗は `名前:値`（`capture:120`・`webgpufail:canvas`）。
- 値が少数の決まった語の旗は、**値だけを書けばよい**（人が打つ物を短く）。下の表の「短い書き方」。
- 真偽の旗は名前だけ（`fps`・`glcheck`・`loadtime`・`usedassets`）。
- 知らない語は console に 1 行出して捨てる（止めない。今の `backend` の WhyNot「知らない値で止めない」と同じ考え）。
- 同じ旗が 2 回あれば後の語。

| 旗（`window.fgeDev` の欄の名前） | `fge=` の正式な書き方 | 短い書き方 | 前の鍵 |
|---|---|---|---|
| `fps: true` | `fps` | — | `fps=1` |
| `backend: "webgl2"` | `backend:webgl2` | `webgl2`・`gl` | `backend=webgl2` / `backend=gl` |
| `net: "4g"` | `net:4g` | `4g` | `net=4g` |
| `sw: false` | `sw:0` | `nosw` | `sw=0`（§2.3） |
| `input: "touch" \| "mouse"` | `input:touch` | `touch`・`mouse` | `input=…` |
| `orientation: "portrait" \| "landscape"` | `orientation:portrait` | `portrait`・`landscape` | `orientation=…` |
| `size: "small" \| "medium" \| "large"` | `size:small` | `small`・`medium`・`large` | `size=…` |
| `glcheck: true` | `glcheck` | — | `glcheck=1` |
| `loadtime: true` | `loadtime` | — | `loadtime=1` |
| `capture: <n>` | `capture:120` | — | `capture=120` |
| `deferred: "all"` | `deferred:all` | — | `deferred=all` |
| `usedAssets: true` | `usedassets` | — | `usedAssets=1` |
| `webgpuFail: "prepare" \| "canvas"` | `webgpufail:prepare` | — | `webgpuFail=…` |

例: スマホで重さを WebGL2 で見る `?fge=fps,webgl2`・PC でスマホの縦を指で `?fge=small,touch,portrait`・Start と一緒に `?talk=Lair&line=46&fge=fps`
（`fge` はクエリのどこに置いてもよい。今のように「Start の鍵を最初に」と気にしなくてよくなる）。
`webgpu`（前の `?backend=webgpu` に当たる）は語として受けて何もしない（既定と同じ）。

### 2.2 道具だけの旗も `fge=` で受ける（URL に鍵は増えない）

方針は「道具だけの物は URL から外す」。ここでの提案は、**読み手は 1 つ（同じ字の決まりで全部の旗を受ける）・案内を分ける**:
道具は `window.fgeDev` で入れ、docs と早見表は人の旗だけを `?fge=` で案内する。`glcheck`・`loadtime`・`webgpufail` を手で使う人
（docs/backend-parity.md・docs/startup.md に手順がある）は `?fge=glcheck` で打てる。鍵は `fge` 1 つのままなので、方針の「増やさない」は守れる。
受けない形（道具の旗は `fgeDev` だけ）にすると、手で確かめる人は DevTools の console から入れられない（`fgeDev` は頁の script より先に要る）。→ §9 の (2)。

### 2.3 `sw=0` は残す（抜け出す口の例外）

`?sw=0` は「壊れた Service Worker から抜け出す口」で、壊れているのは**遊ぶ人のブラウザに入っている前の版の `sw.js`** である。
前の版の `sw.js` は `?fge=nosw` を知らないので、新しい書き方で開いても前の版のキャッシュから返し、抜け出せない。頭の script（前の版の index.html）も同じ。
だから `sw=0` は 1 版で外さず、**ずっと読む**（新しい `fge-sw.js`・頭の script・fge-web.js は `sw=0` と `fge=nosw` の両方を見る）。
docs の案内は `?sw=0` のまま（遊ぶ人に伝える字が版で変わらない方がよい）。engine が Start から外す鍵は `fge` と `sw` の 2 つになる。→ §9 の (3)。

## 3. 頁が読む順と `window.fgeDev` の形

### 3.1 形

`window.fgeDev` は素の object。欄は §2.1 の表の左の列（JSON で書ける値だけ）。全部の欄が省略できる。

```js
window.fgeDev = { capture: 120, usedAssets: true, backend: "webgl2", deferred: "all", net: "4g" };
```

WhyNot: 字（`"capture:120,usedassets"`）で渡さない — Go の側で欄の名前の打ち間違いを型で止められない。object なら Go の struct（json の tag）から作れる。

### 3.2 読む順

旗ごとに、**最初に値を持っている所**を使う。

1. `window.fgeDev` の欄（道具が入れた物）
2. `?fge=` の語
3. 前の鍵（`?fps=1` など。1 版のあいだだけ。読んだら console に `[fge] ?fps=1 は ?fge=fps に替わった（次の版で読まなくなる）` を鍵ごとに 1 回）

例外（どちらも今のふるまいを守るため）:

- `backend`: どこか 1 つでも `webgl2` / `gl` と言えば WebGL2（順で上書きしない）。WebGPU で落ちて開き直した頁は URL に `webgl2` を持つが、
  `fgeDev` が別の値を持っていても開き直しを繰り返さないように。今の WhyNot「開き直す URL から `?backend` を外さない」と同じ理由。
- `sw`: `sw=0`（前の鍵）は §2.3 の通り期限なしで読み、知らせも出さない。

### 3.3 どこで読むか（頁の最初・wasm より前）

読み取りは**頁の始まりで 1 回**にし、結果を `window.fgeSwitches`（§2.1 の欄の形・欠けた欄は既定値）に置く。今 `fgeQueryParam` と正規表現で読む 13 か所は全部これを読む。

- 頭の script（`webHeadScript`）は fge-web.js より先に動き、`sw` を見る。Service Worker の登録（`fgeServiceWorkerStart`）は押した後・起動の後なので遅くてよいが、
  頭の script は wasm の preload より前に `sw` を知る必要がある。
- `fgeDev` は CDP の `Page.addScriptToEvaluateOnNewDocument`（cdp の `PageOptions.InitScript` / `Page.AddInitScript`）で入れるので、頭の script より先にある。
  開き直し（WebGPU で落ちた時の `location.replace`）でも毎回入る。

**おすすめ（案 A）**: 字の決まりの読み手を 1 つのファイル `engine_web/js/fge-switches.js`（副作用なしの関数 `fgeReadSwitches(search, dev)` が
`{ switches, legacy: [前の鍵…], unknown: [語…] }` を返す・30〜50 行）に置き、

- `bin/fge export-web` が頭の script の前に**中身を index.html に埋める**（要求が 1 本増えない）。頭の script が `window.fgeSwitches` を作り、`sw` を見る。
- `fge-web.js` は `window.fgeSwitches` を読む（無ければ自分で `fgeReadSwitches` を呼ぶ — 頭の script を持たないテストの頁のため）。
- `sw.js` は書き出しの時に `fge-switches.js` + `fge-sw.js` をつないで書く（Service Worker は `location.search` の代わりに navigate の URL と頁の URL の `search` を渡す）。

案 B: 読み手を fge-web.js・fge-sw.js・頭の script に 3 つ書く（今の `sw=0` の見方と同じ形）。ファイルは増えないが、`fge=` の字の決まりが 3 つに分かれ、
テストは書き出した頁を開く形でしか書けない。

案 A は `plans/web-js-thin.md` の決めた事（起動の前の段と SW は小さな JS の core のまま・テーブルのテストを headless Chrome で流す）と同じ向き。→ §9 の (4)。

### 3.4 index.html の起動役が読む物

`engine_web/js/index.html` の中には URL を読む script は無い（`wasm-gc-runtime.js` と `fge-web.js` を読むだけ）。書き出しが入れる
`webHeadScript` は `sw` だけを読み、`webBootScript` は何も読まない。案 A では `webHeadScript` の頭に `fgeReadSwitches` を置き、`sw` の見方を
`window.fgeSwitches.sw === false` に替える。

## 4. engine の変更点（相談の材料）

| 所 | 変更 |
|---|---|
| `engine_web/js/fge-switches.js`（新・案 A） | `fgeReadSwitches(search, dev)`。§2 の表を 1 つの配列で持つ（名前・正式な値・短い書き方・前の鍵・前の鍵の値の読み方） |
| `engine_web/js/fge-web.js` | `fgeQueryParam` を消し、13 か所を `fgeSwitches.<欄>` に替える（`fgeCheckedGl`・`fgeDecodeTimes`・`fgeCaptureFrame`・`fgeBackendParam`・`fgeInputOverride`・`fgeSizeOverride`・`fgeOrientationOverride`・`fgeUsedAssets`・`fgeNet4g`・`fgeWireFpsOverlay`・`deferred` の待ち・`fgeServiceWorkerStart`）。`fgeFallbackToWebGl2` の開き直しは `backend=webgl2` を足す代わりに `fge` の語に `webgl2` を足す（前の `backend` の鍵があれば消す）。前の鍵の知らせを 1 回ずつ出す。`fgeQueryPairs` はそのまま（外すのは Flix の側・今の WhyNot の通り） |
| `engine_web/js/fge-sw.js` | navigate と `fgeOwnClient` の `sw=0` の見方を `fgeReadSwitches(url.search, null).switches.sw === false` に替える（`sw=0` も読む） |
| `go/exportweb_page.go` `webHeadScript` | §3.4。`fge-switches.js` を埋める（`stampWebIndex` の中で） |
| `engine_web/java/fge/web/Browser.java` | `captureFrame()`（`return fgeCaptureFrame;`）と `webGpuFailMode()`（`return fgeSwitches.webgpuFail \|\| "";`）を足す |
| `engine_web/src/WebLayer/Internal/WebGpuLayer.flix` | `prepare` の `queryValueOf("capture")`・`queryValueOf("webgpuFail")` を上の 2 つに替え、`queryValueOf` を消す（`Browser.queryPairs` を読む所が engine の中から無くなる） |
| `src/engine_world/App/DevTools.flix` | `pageQueryKeys` を `Set#{"fge", "sw"}` + 移行の版だけの前の鍵 12 個（`fps` `backend` `net` `input` `orientation` `size` `glcheck` `loadtime` `capture` `deferred` `usedAssets` `webgpuFail`）に。次の版で前の鍵を消す。名前は残す（`browser` の doc が指している・テストが引く） |
| `engine_web/src/WebLayer.flix` | doc の `?backend=webgl2`・`?usedAssets=1`・`?net=4g`・`?orientation=portrait`・`?size=…` の字を `?fge=` / `fgeDev` に直す |

WhyNot（実装の時にコードに書く候補）: `pageQueryKeys` を消さない — `sw` が残り、移行の版は前の鍵も外す。一覧が 2 つになっても置き場所は Flix のテストで確かめられる 1 か所のまま。

engine の外へ出る約束の変化:

- **ゲームの Start に `fge` という名前を使えなくなる**（今は 7〜12 個の名前を使えないので、減る方向）。
- 前の鍵は次の版で Start の名前に戻る（例 `?fps=1` は「知らない Start `fps`」→ 先頭の Start で開き、console に訳。止まらない）。

## 5. Go の側の変更点

go/ は別の担当がリファクタ中（`cmd_exportweb.go` を段ごとに分ける・⑨ を `runWebBrowserChecks` 1 本にする・http サーバーを 1 つにまとめる）。
下は関数名で書き、**その担当が入った後に**当てる。

| 関数・所 | 今 | 替える形 |
|---|---|---|
| `cdp.Options`（internal/cdp/capture.go）と `cdp.Capture` | `OpenPage(PageOptions{Chrome, Width, Height})`。InitScript を渡す口が無い | `Options.InitScript string` を足し、`OpenPage` の `PageOptions.InitScript` へ渡す |
| 頁の旗を作る小さな型（新・main の package） | — | `webPageSwitches` struct（§2.1 の欄・`json:",omitempty"`）と `func (s webPageSwitches) initScript() string`（`window.fgeDev = <json>;`）。道具が開く全部の頁でこれを使う |
| ⑨ `checkWebLoadsRecording`（リファクタ後は `runWebBrowserChecks` の中） | `index.html?capture=<n>`・`&backend=webgl2`・`&usedAssets=1` | URL は `index.html`、`Options.InitScript` に `{capture:n, usedAssets:true}` と `{capture:n, backend:"webgl2"}`。誤りの字の `?backend=webgl2 の頁` は「WebGL2 の頁」に |
| ⑨' `checkWebMissingTitle` | `index.html?capture=<n>&net=4g` | `{capture:n, net:"4g"}` |
| ⑨'' `measureWebTapWait` | `cdp.OpenPage(cdp.PageOptions{})` に `index.html?net=4g`（**今は InitScript を使っていない**。依頼の「押した後の測りが使っている InitScript」は main の今の字には無い。リファクタの担当の枝で入っているかもしれない） | `PageOptions{InitScript: webPageSwitches{Net: "4g"}.initScript()}` |
| `rerunWebBrowserChecks`（web-check `--browser`） | ⑨' と ⑨'' を呼ぶだけ | 上を呼ぶので変更なし（字の案内だけ） |
| `cmdWebCapture`（web-capture） | URL をそのまま開く。使い方の字に `index.html?capture=6` | `--dev <語,語>` を足す（§2.1 の字の決まり。Go で `webPageSwitches` に読み、知らない語は exit 2 — 道具は厳しく・頁は甘く）。使い方の字を `index.html --dev capture:6` に。URL の `?capture=` は移行の版のあいだ頁が読む（知らせが出る） |
| `cmdWebBench`（web-bench） | `--query` をそのまま URL に | 変更なし（ベンチのつまみはゲームの側の鍵）。WebGL2 で測る時の案内を `--query 'n=20000&fge=webgl2'` に（RESULTS.md の `&backend=webgpu` は今の既定なので外す） |
| `bin/web-pages-stage.sh` の 5. | `web-capture "$dest/index.html?capture=3&deferred=all"` | `web-capture "$dest/index.html" --dev capture:3,deferred:all` |
| 同 最後の行 | スマホの URL に `?fps=1` | `?fge=fps` |
| Makefile `webgpu-v1-check-web` | `index.html?capture=6&deferred=all&backend=webgl2` など 3 つ | URL は `index.html` / `nogpu.html`、`--dev capture:6,deferred:all[,webgl2]` |
| `bench/hd2d_town/Makefile` explore-serve | `?fps=1&measure=1` | `?fge=fps&measure=1` |
| Tape `go/internal/tape/template.html` `syncStartBtn` | `TAPE.start + "?orientation=" + …` | §6.2 |

Go の字の決まりの読み手（`--dev`）と JS の `fgeReadSwitches` は同じ表を 2 つ持つことになる。食い違いは §7 の共通のテーブル（`testdata/web-switches.cases.json`）で止める。

## 6. 公開済みの頁・LP・docs に残る古い URL

### 6.1 どこに残るか

- **docs と早見表**: docs/web-export.md の「頁の旗」の表と Start の段落・docs/web-capture.md（例の URL と ⑨ の表）・docs/startup.md・docs/backend-parity.md・
  `agents-pack/AGENTS.core.md` の 108・118・131・136・139・180 行・お題 `try-webgpu-backend`・`web-measure-fps`・sound-novel-starter/README.md。
  過去の docs/migrations と plans は書き換えない（その版の記録）。
- **LP（novel-game-shelf）**: 古い鍵の字は 0 件（探した）。
- **gh-pages に置いたゲームの頁**: URL の鍵は人が開く時に付ける物で、頁の中には持たない。前の版の束はその版の fge-web.js を持つので、前の鍵で動き続ける。
  新しい版で書き出し直した頁に前の鍵で開くと、移行の版は知らせ付きで効き、次の版からは効かない（Start に混ざって先頭の Start で開く・止まらない）。
- **Tape の頁**: 「はじめから遊ぶ」の href を Tape の頁自身が作る（`syncStartBtn`）。§6.2。
- **人の手元のブックマーク・スマホの履歴**: `?fps=1` など。移行の版の知らせで気づける。

### 6.2 Tape の「はじめから遊ぶ」

Tape の頁（`bin/fge tape`）と隣の `play/`（ゲームの書き出し）は、作った時の engine が違うことがある（`bin/fge` は engine の根の物、`play/` はゲームが使う engine で書き出す）。
Tape が `?fge=portrait` を書いても `play/` が前の engine なら `fge` は Start の名前になり、縦にならない。

- 移行の版: Tape は**前の鍵 `?orientation=` のまま書く**（新しい engine も移行の版は読む）。
- 次の版（前の鍵を外す版）: `play/bundle.json` の engine の版（書き出しが残す物）を見て、新しければ `?fge=`、古ければ `?orientation=` を書く。
  `bundle.json` に engine の版が無い場合は、移行の版のうちに書き出しが書くようにしておく（§8 の S5）。
- `views_test.go` の 2 本（`Start != "play/index.html?orientation=portrait"`）は次の版で期待を分ける。

### 6.3 移行メモの文案（docs/migrations の次の版）

0.106.0.md が出ていなければそこへ、出ていれば 0.107.0.md へ足す。

```markdown
## ブラウザ版の頁の旗を `?fge=` の 1 つの鍵にまとめる

頁の URL で読む開発と測りの旗（`?fps=1`・`?backend=webgl2`・`?size=small` など）を `?fge=` の 1 つの鍵に並べる形へ替えた。
ゲームの Start（`?talk=Lair&line=46`）と旗が混ざらなくなり、旗をクエリのどこに置いてもよい。

| 前 | 後 |
|---|---|
| `?fps=1` | `?fge=fps` |
| `?backend=webgl2`（`?backend=gl`） | `?fge=webgl2` |
| `?net=4g` | `?fge=4g` |
| `?size=small&input=touch` | `?fge=small,touch` |
| `?orientation=portrait` | `?fge=portrait` |
| `?glcheck=1`・`?loadtime=1` | `?fge=glcheck`・`?fge=loadtime` |
| `bin/fge web-capture "index.html?capture=6&deferred=all"` | `bin/fge web-capture index.html --dev capture:6,deferred:all` |
| `?sw=0` | そのまま（壊れた Service Worker から抜け出す口。前の版の `sw.js` が読める字のまま残す） |

| 何が | どう |
|---|---|
| 前の鍵で開いた頁 | この版は今まで通り効き、console に `[fge] ?fps=1 は ?fge=fps に替わった` を出す。**次の版で読まなくなる**（Start の名前として扱われ、先頭の Start で開く） |
| ゲームの Start の名前 | `fge` と `sw` は使えない（前の版の 12 個から減った） |
| `WebLayer.devTools()` のゲームで Start と旗を一緒に使う | 「Start の鍵を最初に」は要らない。`?talk=Lair&fge=fps` でも `?fge=fps&talk=Lair` でもよい |
| 自前のスクリプトで頁を開いて撮る・測る | URL に `?capture=` などを付けず、`bin/fge web-capture --dev` を使う。CDP で開く自前の道具は、頁より先に `window.fgeDev = { capture: 6 }` を入れる（欄は docs/web-capture.md） |
| ベンチの `make bench-web ARGS=…` | WebGL2 で測るのは `ARGS='n=20000&fge=webgl2'` |
| テープ | この版は「はじめから遊ぶ」が前の `?orientation=` のまま（`play/` が前の engine でも縦で開く） |
| 古い engine | `?fge=` を知らないので、`fge` が Start の名前になり、先頭の Start で開く（旗は効かない） |
```

## 7. テスト

| 確かめる事 | 層 | 形 |
|---|---|---|
| `fge` と `sw` が Start に混ざらない・前の鍵（移行の版）が混ざらない・`fge` だけのクエリは Start 無し | Flix（`engine_world/test/TestDevToolsBrowser.flix`） | 今の `testPageKeysAreLeftOut`・`testOnlyPageKeysHaveNoStart` に `("fge", "fps,webgl2")` と `("sw", "0")` の行を足す。`webGpuFail`・`usedAssets` など今抜けている鍵の行も。次の版で前の鍵の行を消し、`fps` が Start になる行を 1 本足す |
| 字の決まり（短い書き方・`名前:値`・大文字・知らない語・同じ旗が 2 回・読む順 fgeDev → `fge=` → 前の鍵・`backend` の「どれか 1 つ」・`sw=0` は知らせなし） | JS の core（`fge-switches.js`）を headless Chrome で 1 回開き、テーブルを流す | `testdata/web-switches.cases.json`（1 行 = `search`・`dev`・期待の `switches`・`legacy`・`unknown`）。`plans/web-js-thin.md` §4.2 のテーブルのテストに乗る（そちらが先に入っていなければ、cdp で頁を 1 枚開く Go のテスト 1 本で流す・見込み 2 秒） |
| Go の `--dev` の読み手が JS と同じ答え | Go の単体（Chrome 無し） | 同じ `testdata/web-switches.cases.json` の `dev` を持たない行を Go の読み手に通す |
| 道具が `fgeDev` を入れ、URL に旗を付けない | Go（Chrome あり・`skipWithoutChrome`） | 今の `TestCheckWebLoadsFailsWhenOnlyWebGl2PageStops`・`TestCheckWebLoadsRecordingReadsUsedAssetsFromTitlePage` の偽の頁を `location.search` ではなく `window.fgeDev` を見る形に直し、偽の頁で `location.search !== ""` なら `fgeCaptureError` を立てる。cdp は `Options.InitScript` が `Capture` で効くテストを 1 本（今の `TestInitScriptOptionRunsBeforePageScripts` と同じ形） |
| `sw` の 3 か所（頭の script・`fge-sw.js`・fge-web.js） | Go（`exportweb_page_test.go`） | 頭の script に `fgeReadSwitches` が入り、`sw=0` と `fge=nosw` を見ること（字の検査）。Service Worker を動かすテストは `plans/web-js-thin.md` の §6 の別のステップに任せる |
| WebGPU で落ちた時の開き直しが `fge=…,webgl2` になり、繰り返さない | 手（と release の門） | `?fge=webgpufail:canvas` で開いて、1 回だけ開き直して WebGL2 で描くのを見る（今 plans/engine-webgpu.md で手で確かめている道） |
| 本物の束が通る | 既存の門 | export-web の ⑨・⑨'・⑨''（rpg-starter・sound-novel-starter）・`make webgpu-v1-check-web`。スマホは人に `?fge=fps,webgl2` と `?fge=fps` を開いてもらう |

## 8. ステップと見積もり（実時間）

前提: go/ のリファクタ（⑨ の 1 本化・サーバーの 1 本化）が入った後に S5 を当てる。S1〜S4 は go/ に触らない所から先に進められる（`exportweb_page.go` の頭の script だけは S5 に回す）。

| ステップ | 中身 | 見積もり |
|---|---|---|
| S0 | この文書を人と相談（§9） | — |
| S1 | `fge-switches.js` と `testdata/web-switches.cases.json`、テーブルを流すテスト | 1.5 時間 |
| S2 | fge-web.js の 13 か所・開き直し・前の鍵の知らせ・`Browser.java` の 2 口・`WebGpuLayer.prepare` | 1.5 時間 |
| S3 | `pageQueryKeys` と Flix のテスト（`make test-engine_world` 相当は `.layers` の中で） | 0.5 時間 |
| S4 | `fge-sw.js` と、書き出しで `sw.js` をつなぐ所 | 1 時間 |
| S5 | Go: `cdp.Options.InitScript`・`webPageSwitches`・⑨ / ⑨' / ⑨''・`web-capture --dev`・頭の script・Makefile・`web-pages-stage.sh`・`bundle.json` に engine の版（無ければ） | 2 時間 |
| S6 | docs・早見表 6 行・お題（直す 2 本・足す 2 本）・移行メモ・`forbid.json` の notice（任意） | 1.5 時間 |
| S7 | 確かめ: `make verify SUITE=affected GUI=1`・rpg-starter と sound-novel-starter の export-web・`make webgpu-v1-check-web`・人のスマホ | 1 時間 |
| 合計 | | **約 9 時間** |
| 次の版 | 前の鍵を消す（`pageQueryKeys` を `{"fge","sw"}` に・JS の前の鍵の表・Tape の分け方・テストの行） | 1 時間 |

早見表とお題（AGENTS.md の「新しい仕組みを入れたら」）:

- `agents-pack/AGENTS.core.md`: 108 行（`?backend=webgl2` → `?fge=webgl2`）・118 行（`?size=small&input=touch` → `?fge=small,touch`）・131 行（`?fps=1` → `?fge=fps`・`?fge=fps,webgl2` で比べる）・
  136 行（`?net=4g` → `?fge=4g`）・139 行（`?sw=0` は**そのまま**）・180 行（`?capture=<n>` → `web-capture --dev capture:<n>`・自前の CDP は `window.fgeDev`）。
  新しい 1 行の候補: 「ブラウザ版で Start（`?talk=…`）と頁の旗を一緒に使う」→「旗は `?fge=` にまとめる。順は気にしない」。
- `agents-pack/agent-eval/engine.json`: `try-webgpu-backend` の expect を `fge=webgl2`（移行の版は `backend=webgl2` も当たりにする）・`web-measure-fps` を `fge=fps`。
  足す: `web-start-with-fps`（「`?talk=Lair` で開いて fps も見たい」→ expect `fge=fps`・avoid `[?&]fps=1`）・`web-capture-dev`（「書き出した頁の 6 コマ目を WebGL2 で撮りたい」→ expect `--dev`・avoid `\?capture=`）。
  ゲームの足元で `make agent-eval ONLY=<お題>`。
- engine のリポだけの口は無い（`testdata/agent-eval/engine-repo.json` は触らない）。
- `bin/lint-rules/forbid.json`: Makefile・`.sh` で頁を開く行の `[?&](capture|usedAssets|deferred|net|backend)=` を notice で知らせる案（コミット時の forbid が見るのは今 `.flix`・`.java`・Makefile・project.json だけなので、`.sh` を見るなら precommit.json の when も足す）。任意。

## 9. 人に決めてもらう事

1. **この形で engine を変えてよいか**（engine_web の JS・Browser.java・WebGpuLayer・engine_world の `pageQueryKeys`）。
2. **道具だけの旗（`glcheck`・`loadtime`・`capture`・`deferred`・`usedassets`・`webgpufail`）も `?fge=` で受けるか**。おすすめは受ける（§2.2。鍵は増えない・手で使う手順が docs にある）。docs と早見表で案内するのは人の旗だけ。
3. **`?sw=0` を期限なしで残すか**。おすすめは残す（§2.3。抜け出す口は前の版の `sw.js` が読めないと効かない）。その結果 `pageQueryKeys` は `{"fge","sw"}` で、方針の「一覧は要らなくなる」は 2 つの一覧になる。
4. **読み手を 1 つのファイルにするか（案 A）、3 か所に書くか（案 B）**。おすすめは A（§3.3。`plans/web-js-thin.md` の JS の core と同じ向き・テーブルでテストできる）。A は書き出しが index.html と sw.js に中身を埋める仕事が増える。
5. **前の鍵を外した後の扱い**。決めた方針通り Start に戻す（`?fps=1` は先頭の Start で開く・console に「知らない Start」）か、JS が前の鍵の名前だけを持ち続けて「`?fge=fps` に替わった」を出し続けるか。おすすめは方針通り（表を 2 つ持ち続けない）。
6. **Tape の「はじめから遊ぶ」**: 移行の版は前の鍵で書き、次の版で `play/` の engine の版を見て分ける（§6.2）でよいか。

## 10. やらない事

- ゲームやベンチが自分で読む鍵（bench の `knobsOfPairs`・hd2d-starter の `Knobs.ofPairs`・`measure`・Tape の `view`）を `fge=` に入れない（engine の物ではない）。
- `fgeQueryPairs` の側で鍵を外さない（今の WhyNot の通り、外す一覧は Flix のテストで確かめられる所に 1 つ）。
- 頁の旗を project.json に足さない（旗は開く時の物。書き出しの設定と混ぜない）。
- デスクトップの環境変数（`FLIX_GE_BACKEND`・`FLIX_GE_PORTRAIT`・`START`）は替えない。
- 過去の docs/migrations・plans の URL を書き換えない。
- Service Worker を動かすテスト（登録・抜け出す口の通し）はこの計画では書かない（`plans/web-js-thin.md` の §6 の別のステップ）。

## 11. 読み直しで足した確かめ

- **WebGPU と WebGL2**: `backend` の決まり（§3.2 の例外）と、WebGPU で落ちた時の開き直し（`fgeFallbackToWebGl2` が URL を書く唯一の所）を §4 に入れた。⑨ は既定（WebGPU）と WebGL2 の 2 枚を開くので、`fgeDev` も 2 通り（§5）。WebGPU の無い頁（Makefile の `nogpu.html`）も `--dev` で撮る。
- **縦の design**: `orientation` と `size` は `fgeWantsPortrait` が起動の時に 1 回読む。読む時が変わらない（頁の始まりの `fgeSwitches` から読む）ので、縦を選ぶ時のふるまいは変わらない。テンプレートの描き出し（`Display.phonePortrait`）と Studio は URL を使わない。
- **Studio の preview と Tape の再生**: Studio は使わない（0 件）。Tape は「はじめから遊ぶ」の 1 か所だけ（§6.2）。Tape の撮り（flow）はデスクトップで、頁を開かない。
- **agent-eval と早見表**: §8 の最後に行とお題を挙げた。
- **`webgpuFail`**: 依頼の 12 個に無い 13 個目。今も Start に混ざる（§0）。
- **`size` の値**: 頁の鍵は `small|medium|large`。`WxH` は `web-capture --size` の旗（§1）。
- **押した後の測りの InitScript**: main の今の `measureWebTapWait` は `PageOptions{}` で、InitScript を使っていない（cdp の口はあり、Tape のテストが使う）。リファクタの担当の枝の状態を S5 の前に確かめる。
