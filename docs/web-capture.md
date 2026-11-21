# ブラウザの canvas を撮る（bin/fge web-capture）

ヘッドレスの Chrome を CDP（Chrome DevTools Protocol）で動かし、頁が読んだ canvas の画素（WebGL2 なら `readPixels`・WebGPU は下の「書き出した頁のコマを撮る」）を
PNG に書く道具。gl_parity の web 版（WebGL2 の絵と SoftRaster の絵を同じ物差しで比べる）の土台。
Node と Playwright は使わない（Go の bin/fge の中で WebSocket から CDP を話す・`go/internal/cdp`）。

```
bin/fge web-capture <URL> <出力.png> [--wait <秒>] [--size WxH] [--dir <書き出したフォルダ>] [--dev <語,語…>]
```

- `--wait` は頁の合図を待つ上限（既定 30 秒）。`--size` は頁の viewport（既定 800x600・deviceScaleFactor は常に 1）。
- `--dir` はそのフォルダを 127.0.0.1 の使い捨ての口で配り、`<URL>` を頁の道とクエリ（例 `index.html`）として読む（静的なサーバーを起こさずに済む）。
- `--dev` は頁の旗（下の「頁の旗」）を頁のどの script より先に `window.fgeDev` で入れる（例 `--dev capture:6,deferred:all,webgl2`）。知らない語は exit 2（頁は知らない語を捨てるが、道具の打ち間違いはその場で止める）。
- Chrome は `FGE_CHROME` → `/Applications/Google Chrome.app` など決まった場所 → PATH の `google-chrome` / `chromium` の順に探す。
  見つからなければ探した場所を全部並べて exit 1。
- 起こすのは `--headless=new --remote-debugging-port=0` と使い捨ての `--user-data-dir` の Chrome。止めるのは自分が起こした
  プロセスの組だけ（`Browser.close` → 5 秒で閉じなければその組へ SIGKILL）。人が開いている Chrome には触らない。
- 出力は「書いた PNG・Chrome の版・頁が名乗った描き手（`renderer`）」。
- 確かめ: `go/internal/cdp/testdata/webgl2_known.html`（scissor の clear とシェーダーの四角で既知の絵を描く頁）を撮り、
  全画素が期待どおりか（`go test ./internal/cdp/`。Chrome の無い機械と `-short` では飛ぶ）。
  2026-11-04・Chrome 156・ANGLE Metal（Apple M4 Pro）で 0 px の差。

## 頁の側の約束

道具は頁を開いた後、50ms ごとに `window` の 3 つの名前を覗くだけ。描き方・タイミングは全部頁が持つ。

| 名前 | 頁が置く物 | 道具の扱い |
|---|---|---|
| `window.fgeCaptureReady` | 撮る画素がそろったら `true` | `true` を見たら `fgeCapture()` を呼ぶ |
| `window.fgeCaptureError` | 失敗した時の理由の文字列（WebGL2 が取れない・シェーダーが通らない…） | 見えたらすぐ exit 1（待ち切らない） |
| `window.fgeCapture()` | `{width, height, rgba, origin?, renderer?}` を返す関数（Promise でもよい） | `rgba` を PNG にする |

- `rgba` は `width*height*4` byte の RGBA を base64 にした文字列。`gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, buf)` の並びのまま渡す。
- `origin` は `"bottom-left"`（既定・`readPixels` のまま。下の行が先）か `"top-left"`。道具が上の行を先に並べ直す。
- `renderer` は任意。`WEBGL_debug_renderer_info` の `UNMASKED_RENDERER_WEBGL` を入れておくと、どの GPU・ANGLE で撮ったかが出力に残る
  （SwiftShader に落ちていないかをここで見る）。

### 読む時刻（preserveDrawingBuffer: false のまま撮る）

WebGL2 のコンテキストは本番と同じ属性（`preserveDrawingBuffer: false`）で取る。この属性だと、rAF の処理を返して
合成された後の drawing buffer は消えてよい決まりなので、**描いた rAF の処理の中で、返す前に `readPixels` して
コピーを持っておく**。後から別のタスク（`fgeCapture()` の中）で読むと、消えた後の黒い画素が返ることがある。

```js
requestAnimationFrame(() => {
  drawFrame();                                   // 本番と同じ描き方
  const buf = new Uint8Array(w * h * 4);
  gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, buf);  // 同じ処理の中で
  const shot = { width: w, height: h, rgba: toBase64(buf), origin: "bottom-left" };
  window.fgeCapture = () => shot;
  window.fgeCaptureReady = true;
});
```

- 撮る大きさは drawing buffer（`gl.drawingBufferWidth/Height`）。canvas の `width/height` を design の大きさにしておけば、
  CSS の大きさや `--size` に関係なく design の画素で撮れる。
- 道具は撮る前に `Page.bringToFront` と `Emulation.setFocusEmulationEnabled` をかける。起動時の頁は `--headless=new` でも
  `visibilityState` が `hidden` で rAF が回らないため（Chrome 156・macOS で確かめた）。頁の側で visibility を見て止める
  作りでも撮れる。

## 書き出した頁のコマを撮る（頁の旗 capture:<n>）

`bin/fge export-web` の頁は頁の旗 `capture:<n>`（`web-capture --dev capture:<n>`・自前の CDP の道具は頁より先に `window.fgeDev = { capture: <n> }`）で上の約束を守る。canvas を design の大きさにし、dt を 1/60 に固定し、
「押して始める」を飛ばし、n コマ目を描き終えた所（`presentFrame` の頭・`Browser.frameDrawn`）で読む。
デスクトップの `FLIX_GE_HIDDEN=1 FLIX_GE_FRAME_SHOT=<フォルダ> FLIX_GE_FIXED_DT=1/60`（`bin/gl-capture.sh`）の `frame-<n>.png` と同じコマになる。

```
bin/gl-capture.sh <控え> bench/scene3d:
bin/fge export-web bench/scene3d --out <出力>            # 静的なサーバーで配る
bin/fge web-capture "http://127.0.0.1:<port>/index.html" <出力.png> --dev capture:6 --size 640x360 --wait 60
```

頁の既定の描き手は WebGPU（navigator.gpu）で、n コマ目の中間の texture を
同じ形（`origin: "bottom-left"`・canvas は opaque なので alpha は 1）で置く。`renderer` は `webgpu: <adapter>`。WebGPU を使えない頁
（`navigator.gpu` が無い・device が取れない）は理由を console に出して WebGL2 で描くので、`renderer` を見て WebGPU で撮れたかを確かめる。
`--dev` に `webgl2` を足すと WebGL2 で描く（`renderer` は WebGL2 の名前）。WebGL2 の絵と比べる時はこちら。
V1 の門は `make webgpu-v1-check-web`（`webgl2`・既定・WebGPU の無い頁を撮って比べる）。

```
bin/fge web-capture index.html <WebGL2 の絵.png> --dir <書き出したフォルダ> --dev capture:6,webgl2 --size 640x600 --wait 90
bin/fge web-capture index.html <WebGPU の絵.png> --dir <書き出したフォルダ> --dev capture:6 --size 640x600 --wait 90
bin/fge pixel-diff <WebGL2 の絵.png> <WebGPU の絵.png> --tolerance bench/webgpu_v1/tolerance.tsv --name <場面>
```

この頁は、止まった時（`fgeError`）に画面の字と同じ物を `fgeCaptureError` へ置く。道具は待ち切らず、その字で exit 1 になる。

同じ `--dev` に `glcheck`（GL の呼び出しごとに `getError` を見て、組ごとに 1 回 console へ言う・`fgeGlCheck` に回数）と
`loadtime`（絵の解読を 1 枚ごとに `console.time`・枚数と合計を `fgeDecodeTimes` へ）を足せる。Mip の時間はデスクトップの F3 と hitch の 3D の区間 `mip` で読む（ブラウザの頁には出ない）。
実測の結果は [backend-parity.md](backend-parity.md) の「ブラウザ（WebGL2）とデスクトップの絵」。

## 書き出しの門（ブラウザで wasm を読めるか）

`bin/fge export-web` は頁を書いた後の最後の段（⑨）で、書き出し先を 127.0.0.1 の使い捨てのサーバーで配り、ヘッドレスの Chrome で
次の頁を順に開く（頁ごとに Chrome を起こし直す）。どの頁も URL にクエリを付けず、頁の旗（下の「頁の旗」）を `window.fgeDev` で入れる。

| 段 | 開く頁 | 見る物 | 外れた時 |
|---|---|---|---|
| ⑨ | `index.html`・`{capture: 120, usedAssets: true}`（既定の WebGPU の頁） | 120 コマ目まで撮れるか・タイトルの 120 コマに使った素材の記録（後回しの候補の元） | `fgeCaptureError`（wasm の compile・instantiate・`main` の例外）で exit 1 |
| ⑨ | `index.html`・`{capture: 3, backend: "webgl2"}` | WebGL2 の頁でも 3 コマ目まで撮れるか（WebGPU を使えないブラウザが頼る道） | 同上 |
| ⑨' | `index.html`・`{capture: 120, net: "4g"}`（後回しがある時だけ） | 4G の届き方でタイトルが後回しの物を待って止まらないか | 止まれば門が赤（[web-export.md](web-export.md) の「起動の予算」）。頁が開けない時は知らせだけ |
| ⑨'' | `index.html`・`{net: "4g"}`（engine が待ちうる後回しか group がある時だけ） | 「タッチして開始」とタイトルの `startKeys` を押し、押した時の待ちが明けるまでの秒 | 測れなければ知らせだけ（門は見積もりで決める） |

`bin/fge web-check <書き出したフォルダ> --browser` は ⑨' と ⑨'' を流し直し、押した後の速さ（回線を絞らずに開き、「タッチして開始」が出たら押して、押してから最初のコマまでの秒と押してから波紋が描けるまでの ms）を表で出す（すぐ押す・CPU 1 倍の 1 回目と、
Service Worker が付いた後の 2 回目の起動）。`--cpu 4`（CPU を 4 倍遅くする・`Emulation.setCPUThrottlingRate`）と `--tap-delay 1.5`
（「タッチして開始」が出てから 1.5 秒置いて押す）を付けると、その条件の ⑨'・⑨''・速さをもう 1 回流して表と知らせに足す。
門（`checks.tapWaitSeconds` と赤）はいつも「すぐ押す・CPU 1 倍」の値だけで決める（門の判定が測る機械の速さで揺れない）。
頁の側の時刻は `window.fgeBootTimes`（`readyAt`・`tapAt`・`tapEventAt`・`tapPaintAt`・`firstFrameAt`。performance.now の ms）。
速さは書き出し（export-web）では測らない。値を `bundle.json` に残すと書き出すたびに版と sums が変わり、遊ぶ人の Service Worker のキャッシュが毎回入れ替わるため。
「押してから波紋まで」は押した後の最初の rAF の時刻から引いた値で、画面に出るまでより 1 コマ近く短い（下限の値として読む）。

## 頁の旗（道具が入れる window.fgeDev）

書き出した頁は、頁の旗を URL の `?fge=<語>,…`（人が打つ物）と、頁のどの script より先に置かれた `window.fgeDev`（道具が入れる物）から読む。
欄と語の一覧は [web-export.md](web-export.md) の「頁の旗」。道具は URL に旗を付けない（`WebLayer.devTools()` のゲームはクエリを Start に読む）。

- `bin/fge web-capture --dev <語,…>`: 語は `?fge=` と同じ（`capture:6`・`deferred:all`・`webgl2`・`usedassets`・`4g`・`webgpufail:canvas`…）
- 自前の CDP の道具: `Page.addScriptToEvaluateOnNewDocument` で `window.fgeDev = Object.assign(window.fgeDev || {}, { capture: 6, backend: "webgl2" });` を入れてから開く。
  欄は `fps` `backend` `net` `sw` `input` `orientation` `size` `glcheck` `loadtime` `capture` `deferred` `usedAssets` `webgpuFail`（値は JSON の真偽・数・字）
- Go の道具の中では `webPageSwitches`（go/exportweb_switches.go）の `initScript()`。字の決まりの答えは `testdata/web-switches.cases.json`（頁の読み手と Go の `--dev` の読み手が同じ表で確かめられる）

⑨ で止まった時は書き出し先を消さずに残す。⑨'' は押してから 40 秒で打ち切り、待ちが明けた後も 10 秒は途中の待ちを見るので、後回しの多いゲームではここが一番長い。
Chrome は後回しの無いゲームで 2 回、ある時は 3〜4 回起こすので、書き出しはその分延びる。

- 止めたい形: TeaVM は穴 0 件で訳し終えるのに、ブラウザが wasm を読む所でモジュールごと落ちる（頁は真っ白）。
  JSO の物を `Object` を受ける所へ渡すと起きる（Flix の `Object.isNull(jsoの値)` の 1 行でも）。どの書き方で落ちるかは前もって読みにくいので、
  JSO は `fge.web` の Java の普通の類に包んで渡す。
- Chrome が見つからない機械では確かめずに 1 行知らせて通す（探し方は上の `FGE_CHROME` と同じ）。`--no-browser-check` で飛ばせるが、
  ⑨'・⑨'' も飛ぶので bundle.json の `checks` に「飛ばした」と残り、web-check が ★ を出す（Chrome のある機械で `bin/fge web-check --browser` で流し直せる）。
  頁が合図を出すまで待つ上限は既定 90 秒・`FLIX_GE_WEB_CHECK_WAIT`（秒）で替える。
- 確かめ: `go test -run 'CheckWebLoads|WebMissingTitle|TapOutcome' ./`（`go/`。壊れた wasm を compile させる頁・WebGL2 の頁だけ止まる頁で赤になる事、通る頁で緑になる事、4G のタイトルの待ちと押した後の測りの読み方）。

## gl_parity とのつなぎ（案）

今の物差し（[backend-parity.md](backend-parity.md) の「機械での突き合わせ」）: `make gl-parity` が A 段階の scene を
GL と SoftRaster で 1 コマずつ描き、`bench/gl_parity/debug/gl/<scene>.png` と `debug/soft/<scene>.png` を RGB で比べる
（alpha は比べない・A 段階は 0 px が合格線）。web 版はこの 3 つ目の列 `debug/web/<scene>.png` を作り、同じ比べ方へ流す。

1. **頁**: フェーズ 3 の本線（`GlContext.webGl2()` と WebLayer・`bin/fge export-web`）で gl_parity の scene 表を描く入口を
   1 本組む（デスクトップの `Main.flix` が scene を順に描くのと同じ表を使う）。URL の query で
   `?scene=<名前>&frame=<n>` を受け、その scene を n コマ目（既定 1）まで描いたら、上の約束のとおり同じ rAF の処理の中で
   `readPixels` して `fgeCaptureReady` を立てる。query の名前は道具には関係なく、頁と make の間の決まり。
   - 本線への頼み事は 1 つだけ: **WebLayer の 1 コマを描き終えた直後（rAF を返す前）に呼ばれる差し込み口**。
     本番では何もしない。撮る時だけ `readPixels` を呼ぶ。
2. **撮る**: `bench/gl_parity/Makefile` に `web-run` を足す。A 段階の scene 名の一覧（`Scenes.flix` から出す口を 1 つ足す）を回し、
   静的サーバー（devbox の `jwebserver`・被らないポート・自分の pid だけ止める）で `export-web` の出力を配って、
   1 scene ずつ `bin/fge web-capture "http://127.0.0.1:<port>/?scene=<名前>" debug/web/<名前>.png --size <design の大きさ>`。
   1 枚 0.6 秒ほど（Chrome の起動込み）。数十 scene なら 1 本の Chrome で頁を開き直す形（同じ `cdp` に口を足す）に替える。
3. **比べる**: 既存の `make diff-dirs A=debug/soft B=debug/web`（harness の `PixelDiff` と同じ読み方）。A 段階で 1 px でも
   違えば exit 1 にする門は、今の `make run` の判定（A/B の段階分け）を `debug/web` にも当てる形で足す。
   GL の列とも並べる（`A=debug/gl B=debug/web`）と、「SoftRaster との差」と「デスクトップ GL との差」を分けて読める。
4. **字**: A 段階に字は無いので、字の場面は `bin/gl-capture.sh` の撮る口（LWJGL の GL）の絵と、同じ場面の web の絵を直に比べる。
5. **表**: backend-parity.md の対応表に WebGL2 の列を足し、実測の記録（Chrome の版と `renderer`）を書く。

同じ機械・同じ GPU（Chrome の ANGLE も Metal の上）なので A 段階は 0 px の見込み【推】。SwiftShader に落ちた時は
`renderer` に出るので、その回は比べずに止める（GPU の違いを差として読まない）。
