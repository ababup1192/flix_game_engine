# ブラウザの canvas を撮る（bin/fge web-capture）

ヘッドレスの Chrome を CDP（Chrome DevTools Protocol）で動かし、頁が WebGL2 の `readPixels` で読んだ画素を
PNG に書く道具。gl_parity の web 版（WebGL2 の絵と SoftRaster の絵を同じ物差しで比べる）の土台。
Node と Playwright は使わない（Go の bin/fge の中で WebSocket から CDP を話す・`go/internal/cdp`）。

```
bin/fge web-capture <URL> <出力.png> [--wait <秒>] [--size WxH]
```

- `--wait` は頁の合図を待つ上限（既定 30 秒）。`--size` は頁の viewport（既定 800x600・deviceScaleFactor は常に 1）。
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

## 書き出した頁のコマを撮る（?capture=<n>）

`bin/fge export-web` の頁は URL の `?capture=<n>` で上の約束を守る。canvas を design の大きさにし、dt を 1/60 に固定し、
「押して始める」を飛ばし、n コマ目を描き終えた所（`presentFrame` の頭・`Browser.frameDrawn`）で読む。
デスクトップの `FLIX_GE_HIDDEN=1 FLIX_GE_FRAME_SHOT=<フォルダ> FLIX_GE_FIXED_DT=1/60`（`bin/gl-capture.sh`）の `frame-<n>.png` と同じコマになる。

```
bin/gl-capture.sh <控え> bench/scene3d:
bin/fge export-web bench/scene3d --out <出力>            # 静的なサーバーで配る
bin/fge web-capture "http://127.0.0.1:<port>/index.html?capture=6" <出力.png> --size 640x360 --wait 60
```

この頁は、止まった時（`fgeError`）に画面の字と同じ物を `fgeCaptureError` へ置く。道具は待ち切らず、その字で exit 1 になる。

同じ `?` に `glcheck=1`（GL の呼び出しごとに `getError` を見て、組ごとに 1 回 console へ言う・`fgeGlCheck` に回数）と
`loadtime=1`（絵の解読を 1 枚ごとに `console.time`・枚数と合計を `fgeDecodeTimes` へ）を足せる。Mip の時間はデスクトップの F3 と hitch の 3D の区間 `mip` で読む（ブラウザの頁には出ない）。
実測の結果は [backend-parity.md](backend-parity.md) の「ブラウザ（WebGL2）とデスクトップの絵」。

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
