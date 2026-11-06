# ブラウザで 3D を動かす

## ゴール

- デスクトップと同じ `Scene3d` のゲームが、書き換えなしでブラウザ（WebGL2）で動く。絵はデスクトップに合わせる。
- 速さは問わない。軽い 3D（部屋 1 つ・モデル数十・影 1 つ）が動けばよい。
- 2D のゲームの書き出しは今のまま（wasm の大きさも変えない）。

**やらないこと**: インスタンス描き・ブラウザの別スレッド・WebGPU・スマホ向けの速さの手当て・スマホの一人称の視点操作（iPhone に Pointer Lock が無い）。

エンジン拡張の相談は済み（人の依頼: 「3D の実装を動かすように実装していきましょう」2026-11-05）。

## 分かっていること（確かめた）

レビュー 1 回目は 64 点。下はその指摘を入れた形。

**GL の口**
- Render3d 系の GL の呼び出しは約 280 回。Render3d は `GlContext` を受け取っているが、呼び出しは LWJGL を直に叩いている。
- 名前の違いを除くと、本当に足すのは 21 種類。形の不足もある: `bufferData(int[])`・大きさだけの `bufferData`・`bufferSubData(float[])`・段つきの ARGB。
- `gl` を持たない関数が多い（`uploadMesh`・`putMatrix`・`beginScene`・`endFrame` など）。引数で渡す（`State` に入れると欄の読み取りの代金が毎回乗る）。`bin/fge refactor change-signature` を使う。

**WebGL2 で同じ形が無い物**

| 今の形 | 場所 | 意図の名前 | WebGL2 版 |
|---|---|---|---|
| `glGetTexImage` | `Material.flix:227`（2D の絵を 3D の材質へ貼る `mipCopyOf`） | `readTextureArgb` | 一時の FBO を READ_FRAMEBUFFER に付けて `readPixels`。描画の途中で呼ばれるので FRAMEBUFFER は替えない |
| `glDrawBuffer` + `glReadBuffer` | `Shadow.flix:88` | `useNoColorBuffer` | `drawBuffers([NONE])` |
| `DEPTH_COMPONENT24` + `GL_FLOAT` | `Shadow.flix:76` | `texImageDepth24` | UNSIGNED_INT |
| `GL_SAMPLE_ALPHA_TO_ONE` | `Material.flix:124` | `hasAlphaToOne` | 無い。ブラウザの cutout は discard に落とす（縁のなめらかさは近似） |
| BGRA の段つき | `Material.flix:243` | `texImageArgbLevel` | 今の `fgeTexImageArgb` を段つきにする |

**止まる物**
- `MessageDigest` が TeaVM に無い（`Mesh3d.flix:7`・`Texture3d.flix:8`）。形と絵を作る道が全部通る。`TMessageDigest` を足した（段 0）。ほかの使い手（`FontCache`・`WorldHash`・`DrawHash`・`RenderCache`・`Util.Checksum.sha256`）が届くかは段 2 の ERROR で見る。
- `java.util.HexFormat` も TeaVM に無い（Flix 標準の `Util.Codec.encodeHex`）。`THexFormat` が要る（`of`・`formatHex`。`decodeHex` が届くなら `parseHex` も）。
- 画像の解読はブラウザで常に `Err`（`WebLayer.flix:313`）。止まらず、絵の無いモデルで動くので見落としやすい。
- `uShadowMap` は影が無いと unit 0 のまま。描き先の色テクスチャが unit 0 に残ると、WebGL2 が feedback loop で draw を止める（段 0 で確定。読まない枝でも止まる）。影の無い場面は `putShadow` で毎回、1×1 の透明な黒を貼った unit 9 へ向ける（unit 7 のままだと何も貼っていない unit になり、macOS の GL がログへ書く。プログラムを作る時に向けると、描く途中で組む骨つきの版で use が替わり絵が変わる）。今の `unbindShadowMap` もブラウザで必須。
- `getUniformBlockIndex` の INVALID_INDEX は JS で 4294967295、LWJGL で -1。WebGl2 の JS 側で -1 に写す。
- WebGL2 の誤りは黙って進む。`getError` を読む所が無い。

**実ゲームの本道**
- 画面は常に `samples = 1`。ただし fps3d_lab と conduit_hive は Rgba16Float の MSAA 4 の Pass の中に 3D を描く。`bench/gl_parity` にこの場面は無い。

**読んで問題が無かった物**
- `sampler2DShadow` は使っていない。UBO は 4096 バイトで上限の中。`Objects.equals`・`floatToRawIntBits`・`toIntExact` は TeaVM にある。

## 段

### 段 0: ブラウザでしか分からない物を先に潰す（済み・2026-11-05）

結果: シェーダー 1,007 プログラムのコンパイルは全部通った。リンクで落ちたのは skin + lightmap の版だけで、これは組まれない組み合わせ。hash は JVM と一致。深度テクスチャ、RGBA16F の MSAA 4 と解決も通った。確かめたのは Chromium 152（ANGLE Metal）だけ。Windows・Android・Safari は段 4 で見る。

1. `Render3dGlsl` の全部の組み合わせを JVM で吐いて、WebGL2 でコンパイル・リンクする。
2. `TMessageDigest` を `engine_web/teavm/java/...` に足す。`Mesh3d` を作るだけの入口を TeaVM に通し、JVM と同じ hash が出ること、`asDoubleBuffer` の動きを見る。
3. 手書きの JS で確かめる: 深度テクスチャの FBO・feedback loop・RGBA16F の MSAA 4 と `blitFramebuffer` の解決。

### 段 1: Render3d を GlContext へ移す（済み・未コミット。デスクトップのふるまいは変えない）

- 21 種類と形の不足、上の表の意図の名前を `GlContext`・`LwjglGl`・`RecordingGl`・`WebGl2` に足す。
- `uShadowMap` の unit の変更は別のコミットにする（GL の呼び出しの並びが変わるため）。
- Render3d・Material・Shadow・Light から `org.lwjgl.*` を消し、`forbid.json` の `render-gl-body-desktop-import` に足す。
- `GlContext` を変えたら `make gl-jar-pin`・`make gl-jar-publish`。
- 確かめ方: `make gl-parity` が全一致。3D の GL のキャプチャが移す前とバイト一致（`bin/gl-capture.sh` の 3D は `bench/scene3d` だけ。材質・骨・lightmap は gl-parity の 20〜29 に頼る）。1 コマの時間の中央値の増えが 5% 未満。

結果: 1 コマの時間（`bench/scene3d` の p50 の中央値）は前 0.955 ms・後 0.925 ms（同じ測り方で ±10% 揺れる）。

### 段 2: ブラウザの入口につなぐ（済み・未コミット）

```flix
pub def withProject(rootDir, f)   = withProjectUsing(rootDir, (_, _) -> makeWarningRenderer(), f)
pub def withProject3d(rootDir, f) = withProjectUsing(rootDir, Render3d.makeRenderer, f)
```

- `Render3d` と `Scene3dRenderer` は pub でないので、WebMain から描き手を渡す形は取れない。上の 2 つの入口にする。
- `withProject` の道から Render3d へ届かなければ、2D の wasm は太らない。
- `handleDraw3d` は両方で使い、`runNoopDraw3d` はやめる。
- 2D の入口で 3D の場面が来たら、初回に 1 回警告する。`export-web` でも、`Scene3d` を使うのに `withProject` のままなら 1 行言う。
- `?glcheck=1` の時に毎回 `getError` を見る口を `fge-web.js` に足す。
- 確かめ方: `bench/scene3d`（obj だけで画像の解読が要らない）の 1 場面が映る。`getError` 0 件。2D テンプレの wasm の大きさが ±0.5% 以内。`export-web` の ERROR 0 件。

### 段 3: 絵の素材と入力（済み。2026-11-06 に人の別の PC のブラウザで、部屋の視点・Esc の解除・再開と 60 fps を確認）

- `fge.web.WebImages.decode(bytes)` を `@Async` で作る。Blob → `createImageBitmap(premultiplyAlpha:'none', colorSpaceConversion:'none')` → 一時の RGBA8 テクスチャ → FBO で `readPixels` → ARGB の int[]。2D canvas の `getImageData` は使わない（premultiply で色が崩れる）。置き場は `handleLoadProgress` の `imageDecoder`。
- pointer lock を `setMouseCaptured` へつなぐ。`pointerlockchange` で頼んでいない解除を見たら `fgeLatch.Escape` を立てる。断られたら次の操作で試し直す。
- `readBytes` で読む `.png` `.jpg` が束に入るかを見る（`cmd_exportweb.go:52,722`）。
- 絵の解読の秒数を `?loadtime=1` の `console.time` で測る（hash と Mip は 1 回測って口を消した: 解読 約 210 ms・hash 約 250 ms・Mip 約 200 ms。Mip はデスクトップの F3 と hitch の区間 `mip` で読める）。
- 確かめ方: 一人称の視点がマウスで動く。glb の絵が出る。

### 段 4: 絵を合わせる（済み・未コミット）

結果は `docs/backend-parity.md` の「ブラウザ（WebGL2）とデスクトップの絵」。段 4 の後の 2026-11-05 に、人の手元のスマホで `bench/scene3d` が 60 fps 安定（機種は未記録）。

- 合格の線: 同じ画面の差が 2/255 以下の画素が 99.9%。cutout の縁は除き、「近似」と `docs/backend-parity.md` に書く。
- `bench/scene3d` と fps3d_lab の msaa 4 の Pass を比べる。余裕があれば conduit_hive（素材 83MB・速さは問わない）。
- `agents-pack/AGENTS.core.md` の早見表と agent-eval のお題を足す。

## 次の版の移行ノートの下書き

- ブラウザ版で Scene3d を描くゲームは、`web/WebMain.flix` の `WebLayer.withProject` を `WebLayer.withProject3d` へ替える。2D のゲームは変えなくてよい（`withProject` は 3D を描かず、`export-web` と起動の時に 1 回言う）。
- `WebLayer.withWeb` は pub でなくなった。入口は `withProject` か `withProject3d`。
- ブラウザの `App.withMouseCapture` が本当に効く（pointer lock）。2D のゲームでも、宣言していれば頁で lock が掛かる。
- ブラウザの `LoadProgress.imageDecoder` が `Ok` を返す（前はいつも `Err`）。`Err` を前提に絵を飛ばしていたゲームは、絵が出るようになる。
- 3D の 1 コマの区間で、Mip を作る時間が `Draw` から別の区間 `mip` へ分かれる（/perf の `Draw` の数が読み比べで下がる）。
