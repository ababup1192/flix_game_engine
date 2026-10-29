# 後処理（post-process）のためのエンジン拡張 — 設計

状態: 設計のみ（未実装）。作業場 `fge-postfx`（ブランチ `feat/postfx-spike`・v0.71.0 起点）。
試すのは `make sync-engine-full` で作る `engine_full/artifact/package.fpkg` を
`/Users/abab/Desktop/hd2d_lab/lib/` に差し込む形。本体へはまだ入れない。

**engine/ の拡張なので、実装の前にこの文書で相談する（AGENTS.md）。** 人に決めてほしい所は §8 にまとめた。

改訂 2（レビュー 78 点 → 指摘 1〜20 を反映）。改訂 3（実装後・再レビューの指摘 A〜I と実装で決まった所を反映。§9）。

---

## 0. 解く壁と、この文書の答えの一覧

| # | 壁 | 答え（要点） | 節 |
|---|---|---|---|
| 1 | Pass の中で `Render.shaderFill` が描かれない。Pass を加工して次の Pass へ渡せない | Pass の中の Shader 面を本編と同じ道で描く。読む名前の判断は engine_world の純粋な書き換え 1 回で決め、GL と描き出しは同じ結果を使う。まだ描いていない Pass を読む（forward reference）と黒、自分の名前を読むと前のコマの history（history buffer / feedback） | §2 |
| 2 | Pass が design 解像度固定・読むと NEAREST | 倍率は Pass の計画（`Render.PassPlan` の `targets`）で名前ごとに opt-in。補間は **読む側**の `sampler` 節（Unity Shader Graph の Sampler State と同じ置き場）で opt-in | §3 |
| 3 | `blur` が 1 チャンネルずつで同じ点を 3 回読む・`amount = 0` でも全部読む | 同じテクスチャを同じ座標で読む式を共通部分式として括り出す（CSE / hoist。API は変えない）。半径が 0 なら 1 点だけ読む | §4 |
| 4 | `pow` の負の整数指数が 1 になる・割り算が無い | 負の指数を直す（底は 1e-6 で下切り・答えは 1e6 で上切り）。`math2` に `div`（0 で割ると 0）を足す | §5 |

後方互換の決まり: **既存の JSON・ゲームのコードは 1 文字も変えずにコンパイルが通り、同じ絵を出す**。
破る所は §8 の「振る舞いが変わる所」に全部書いた（どれも今は「描かれていない」物が描かれる向きか、不具合の修正）。

---

## 1. 現状の読み解き（なぜ Pass の中で Shader 面が描かれないのか）

Shader 面が落ちる所は 5 か所ある（GL 2・CPU 3）。どれか 1 つだけ直しても描かれない。

| 場所 | 何をしているか |
|---|---|
| `engine_world/src/App.flix` `App.renderPasses` | Pass の items を `Render.withoutShaders` に通してから `renderCommands`。`drawShaders` / `drawSurface` を呼ばない |
| `render_gl/src/Paint.flix` `RenderPaint.paintTarget` | `renderFrameMixed` へ渡す `surfaces` が `frameArgsBase` の `Nil` のまま。`pendingShaderHolder`（`drawSurface` が積む置き場）は画面側の `submitFrame` でしか取り出さない — Pass の中で `drawSurface` を呼んでも、**その面は画面の方に描かれてしまう**（今は App が呼ばないので表に出ていない） |
| `engine_world/src/Render.flix` `Render.passSpecOf` | 描き出しの宣言へ下ろすとき `withoutShaders`（GL が描かないので合わせていた） |
| `engine_tools/src/HeadlessRender.flix` `renderPassImageFonts` の `Keep` / `ClearTransparent` の枝 → `SoftRaster.renderPassImageFonts` | `drawAllInto(image, req, Nil, …)` で surfaces を常に `Nil` |
| 同 `renderPassImageFonts` の `Clear(c)` の枝 | `SoftRaster.renderToImageCachedAntialias({ background = c | req }, Nil, …)` で surfaces が `Nil` |

加えて、`RenderTargetGl.create` の FBO には**ステンシルが無い**。`shaderFillMasked`（と mask 付き sprite）は
Pass の中では GL で抜けない（docs/backend-parity.md に既知の穴として書いてある）。

解像度と補間:

- `RenderPaint.beginTarget` はテクスチャを `w × h` で作り、registry にも `w × h` で載せる。`paintTarget` は
  `designW = tw` として `renderFrameMixed` を呼ぶので、`calcViewport(tw, th, tw, th)` = 全面・倍率 1。
  投影行列は起動時に design 寸法で各 program に 1 回だけ差してある（`RenderPaint` の `setProjectionMatrix`）。
  **頂点は design px のまま GPU に行き、viewport が fb の画素へ縮める**ので、viewport を小さくすれば
  投影を差し替えなくても縮小して描ける（`calcViewport` は整数倍でなく縦横比を保つだけ）。
- 頂点シェーダーに画素への丸め（ピクセルスナップ）は無い（`render_gl/src/Shader.flix` の `gl_Position` は投影を掛けるだけ）。
- tex 場の読みは `RenderSprite.createSurfaceSampler`（NEAREST + CLAMP の sampler object 1 個）を全部の unit に bind。
  ターゲットのテクスチャ自身の filter も NEAREST（sprite で貼る道）。
- `activeTargetHolder` は `(w, h, LoadOp)` だけで、開いているターゲットの名前を持っていない。
- CPU 側 `ShaderEval.sampleTex` は `floor(u*w)` の釘打ち式（NEAREST）。`blurTex` はチャンネルごとに `taps` 回呼ぶ。
- `HeadlessRender.renderGifWithPasses` の決まり: **Pass の Keep はコマをまたがない・毎コマ透明から始める**（GIF は途中のコマから見られるので、頭出しの位置で絵が変わる物はスナップショットに固定できない）。

`pow`:

- `ShaderGen.powProduct` も `ShaderEval.powProduct` も `k = max(0, n)` で、負の整数は `k = 0` → `1.0`。
  非整数の負（`-0.9999`）は `pow()` に行くので、hd2d_lab はそれで逃げている（底 0 で GLSL は未定義・CPU は無限大）。

---

## 2. (a) Pass の中で Shader 面を描く（Pass の連鎖）

### 2.1 決まり

1. **描く順は宣言順**（今と同じ）。Pass の中の Shader 面は本編と同じく `(zIndex, 追加順)` で sprite・多角形と合流する。
2. **前に宣言した Pass は「このコマの中身」を読む。**（`scene` → `bright` → `bloom` の連鎖がこれで組める）
3. **自分の名前を読むと、前のコマの history（このコマを描き始める前の中身）を読む。** LoadOp に依らない —
   `Clear` の Pass でも、描く前に写しておくので「前のコマを歪めて・色を変えて読む」feedback が書ける
   （`Keep` は上から描き足すだけ）。
   - 作った直後・寸法が変わって作り直した直後は全画素透明。
   - **窓を開いて遊ぶ時（`LwjglLayer`）だけ本物の history を持つ。** 描き出し（PNG・GIF）と GL の 1 枚撮り・動画
     （`GlOffscreen`）は、毎コマ「1 コマ目」として透明を読む（§2.4・§2.5。GIF の今の「毎コマ透明から」の決まりに合わせる）。
4. **まだ描いていない Pass を読む（forward reference）と黒。** 宣言順で後ろの Pass も、このコマで宣言していない名前の古いターゲットも同じ扱い。
   GL の素のままだと前のコマの中身が見えてしまうが、描き出しには前のコマが無いので絵が割れる。前のコマが欲しいなら 3. の history で明示する。
   - これで A → B → A のような循環は成り立たない（循環には必ず forward reference が入る）。
5. **同じ名前の Pass を 2 回宣言したら、2 つ目以降は描かない**（同じテクスチャへ 2 度描くと、GL は Keep の時だけ重ね、CPU は上書きで、割れる）。
6. 名前に `@` を含む Pass は宣言できない（`@history` の別名と混ざらないように）。描かずに知らせる。
7. 本編（画面）からの読みは今のまま。本編がこのコマで宣言していない古いターゲットを読む件は、知らせるだけで書き換えない（§8 の 2）。

3〜6 は Shader 面の tex 場にも `Render.sprite(名前)` にも同じに効く（§2.2 の書き換えが両方を替えるので）。

**history を使う効果はコマ数に依る**（docs/clock.md の観点）。「自分の名前を 0.9 倍で読む」は **1 コマあたりの式**なので、
60Hz と 144Hz で尾の長さが変わる。尾を秒で決めたいゲームは、遊びの時計の 1 コマの長さから係数を作って Spec に入れる:

```flix
// 尾が halfLife 秒で半分になる係数（1 コマぶん）。frame#dt は遊びの時計の 1 コマの秒。
let keep = Float64.pow({ base = 0.5 }, frame#dt / look#trailHalfLife);
… Field.Bin({ op = BinOp.Mul, a = Field.Const(keep), b = Field.Tex({ name = "trail", chan = chan }) }) …
```

`dt` は View に渡る World の側で持つ（Spec の Doc は `trailHalfLife` の秒だけを持つ）。ポーズ中は dt = 0 → 係数 1 で尾が止まる。

### 2.2 判断は engine_world の純粋な書き換え 1 回（GL と CPU が同じ結果を使う）

```flix
// engine_world/src/Render.flix

/// 本編より先に描く Pass の列と、名前ごとのターゲットの作り方（§3.1）をまとめた 1 つの宣言。
/// 組む時は `{ targets = m | Render.passPlan(passes) }` の形で書く（欄を足してもゲームの字が止まらないように）。
pub type alias PassPlan = { passes = List[Pass], targets = Map[String, RenderTarget.Descriptor] }
pub def passPlan(passes: List[Pass]): PassPlan

/// Pass の列の中の、読み方・宣言の問題（知らせる物の一覧）。
pub enum PassPlanIssue with Eq, ToString {
    case ReadsLaterPass({ pass = String, reads = String })          // 宣言順で後ろの Pass を読む
    case ReadsUndeclaredTarget({ pass = String, reads = String })   // このコマで宣言していない古いターゲットを読む
    case DuplicatePass(String)                                      // 同じ名前の 2 回目以降
    case ReservedPassName(String)                                   // 名前に '@' を含む
    case UnknownDescriptor(String)                                  // targets に宣言の無い Pass 名
}

/// 書き換えた列と、問題の一覧。
/// - forward reference（後ろの Pass・このコマで宣言していない古いターゲット）を読む名前 → 必ず存在しない名前（`@missing:<name>`）
/// - 自分の名前 → `<name>@history`
/// - 2 回目以降の同名 Pass・'@' を含む名前の Pass → 列から外す
/// 書き換えるのは Pass の items の中だけ（Shader 面の Spec の tex / blur の name と、sprite の texture）。
pub def resolvePassReads(knownTargets: Set[String], plan: PassPlan): { plan = PassPlan, issues = List[PassPlanIssue] }

/// 自分の history の別名（GL の RenderPaint と描き出しが同じ字を使う）。
pub def historyName(name: String): String = name + "@history"
```

- 読む名前 = Pass の items の Shader 面の `ShaderDoc.texNames` ＋ sprite の texture 名。Pass 数 × 面の数の一巡（Pass は数枚なので二乗にならない）。
- `knownTargets` = 「これまでに Pass として宣言したことのある名前」。普通のテクスチャ名と古いターゲットを見分けるのに使う。
  **増えるだけ**（GPU にターゲットが残っている間は名前も残る）。App は `TileCache#passTargets` に持って毎コマ足す。
  描き出しは 1 コマしか無いので空集合（= 古いターゲットは存在しない）。
- Spec の書き換えは `ShaderDoc` に `renameTex(f: String -> String, spec): Spec`（`foldField` の兄弟の写し替え）を 1 本足して使う。
- テクスチャの名前は GLSL に出ない（出るのは texReads の正典順の番号だけで、どの名前を bind するかは描画依頼が運ぶ）ので、
  書き換えた後の Spec の GLSL は元と同じ字。program のキャッシュ（鍵は spec#name・当たりは `ShaderGen.eqSpec`）が毎コマ作り直さないよう、
  **`eqSpec` は tex / blur の名前を比べず、texNames の正典順の番号を比べる**（`TestShaderGenEqSpec.testRenamedTexStillEqual`）。
- 「存在しない名前」は GL も CPU も今の「無い名前」の道に乗る: tex 場は黒（0）、sprite は貼らない。どちらも 1 回だけ「見つからない」が出るので、
  App / HeadlessRender は `issues` の知らせ（どの Pass がどの名前を読んだか）を先に出す。

`App.renderFrame` は `resolvePassReads` の結果だけを `renderPasses` に渡し、`issues` を `warnOnce` で知らせる。
描き出しは `Render.passSpecsOf`（§2.4）の中で同じ関数を呼ぶ。**GL 側（RenderPaint）は順序の判断を持たない。**

### 2.3 GL 側の実装

| ファイル | 変更 |
|---|---|
| `engine_world/src/App.flix` | `withPassPlan(f: w -> Render.PassPlan)` を足し、`withPasses(f)` は `withPassPlan(w -> Render.passPlan(f(w)))` の薄い形に。`App.Rec#passes` は `w -> Render.PassPlan` に替える（内部の欄）。`renderPasses` は書き換え後の列で、本編と同じく `Render.drawShaders(buildProgram, p#items)` → `drawSurface` を積み、`withoutShaders` した残りを `renderCommands`。`noteSurfaceZ` も Pass ごとに通す。効果の行に `ShaderEffect.Shader` が増える（呼び手の `renderFrame` は既に持っている）。`knownTargets` をループの状態に足す |
| `render_gl/src/Paint.flix` `RenderPaint.submitFrame` / `paintTarget` | ターゲットが開いている枝でも `pendingShaderHolder` を取り出して `surfaces` に渡す（画面の枝と同じ 3 行） |
| 同 `activeTargetHolder` | `(w, h, LoadOp)` に **名前**を足す（history の別名を作るのに要る） |
| 同 history | `historyRef: Map[String, RenderTargetGl.Entry]`。`paintTarget` の頭で、このコマの面の texNames か sprite の texture に `historyName(開いている名前)` があれば: ① history の Entry を（無い・寸法が違えば作り直して）用意、② **clear の前に** `glBlitFramebuffer`（READ = ターゲット・DRAW = history・NEAREST、GL 3.0 で足りる）で写す、③ registry と targetNames に `<name>@history` を載せる（上下逆格納なので flip も効く）。順序の判断はしない（App が書き換え済み） |
| 同 history の方針 | `RenderPaint` に「history を写すか、毎回透明にするか」の旗を 1 つ。`LwjglLayer`（窓）は写す、`GlOffscreen`（1 枚撮り・動画）は**毎回透明で塗る** — `App.paintOnce` は初めて出る字が欠けると最大 3 回描き直すので、写す方にすると 2 回目以降の history が 1 回目の結果になり CPU と割れる。透明なら何度描き直しても同じ絵になる |
| 同 history の後始末 | history を捨てるのは**ターゲットの作り直しの時だけ**: `beginTarget` で寸法が変わった時に、同じ名前の history の Entry も捨てて registry とターゲットの表から外す（次に要る時に新しい寸法で作る = 透明から）。history は registry に **design 寸法**で載せる（sprite で貼っても縮まない） |
| 同 scissor | `glBlitFramebuffer` は scissor に切られる。`renderFrameMixed` はコマの終わりで必ず `GL_SCISSOR_TEST` を外す（既存の決まり）ので、`paintTarget` の頭では外れている前提に立つ。前提が崩れても気づけるよう、blit の直前に `glDisable(GL_SCISSOR_TEST)` を 1 行置く（毎コマ 1 回で安い） |
| 同 `evictShaderPrograms` | pin する集合に「このコマの Pass の面の program」も入れる（今は `lastFrame#surfaces` = 画面の面だけ）。入れ忘れると Pass の面の program が追い出され、uniform が `-1` に落ちて黙って絵が壊れる（同じファイルの既存のコメントの事故と同型） |
| `render_gl/src/Target.flix` `RenderTargetGl.create` | （§2.6・別の段）`GL_DEPTH24_STENCIL8` の renderbuffer を**テクセル寸法で**付ける |

### 2.4 描き出し（CPU）側の実装

| ファイル | 変更 |
|---|---|
| `engine_tools/src/HeadlessRender.flix` `PassSpec` | `surfaces = List[SoftRaster.SurfaceCmd]` と `scale = Float64`（§3.1）を足す |
| `engine_world/src/Render.flix` | `passSpecsOf(textureInfoOf, plan): { specs = List[{…PassSpec と同形…}], issues = List[PassPlanIssue] }` を足す。中で `resolvePassReads(Set.empty(), plan)` を通し、drawables は `withoutShaders` から・surfaces は `shaderSurfaces(items)`・scale は `targets` から。既存の `passSpecOf(textureInfoOf, p)` は surfaces を入れ scale = 1.0 の形で残す（書き換えはしない 1 枚用） |
| `HeadlessRender.renderPassImageFonts` / `SoftRaster.renderPassImageFonts` | surfaces を受けて `drawAllInto` に渡す。`Clear` の枝（`renderToImageCachedAntialias`）にも同じ surfaces を渡す |
| 同 history | 自分の history の別名 `<name>@history` には、**全画素透明の 1 枚**を images に入れる（PNG も GIF も「1 コマ目」。GIF の毎コマ透明の決まりそのまま）。縮んだ pass では Pass の絵と同じく 2 枚（design 寸法を名前で・テクセル寸法を `SoftRaster.texelsName` で） |
| `HeadlessRender.renderPngFull` | `issues` を `[render]` 行で知らせる。値段の記録（items.tsv の `surfaces`）に Pass の面も足す |

`Render.ShaderSurface` と `SoftRaster.SurfaceCmd` は同じ欄の構造レコード（`rect, spec, time, mask, zIndex, blend`）— 実装の最初に型が合うことを確かめる。
`PassSpec` に欄を足すと、レコードの字で組んでいる所（engine の中では `bench/gl_parity/src/Main.flix` の 1 か所）が止まる。
ゲームは `passSpecOf` / `passSpecsOf` を通すので止まらない（テンプレートに Pass を使う物は無い — 確認済み）。

**描き出しのキャッシュの鍵（DrawHash）で気を付ける所**: DrawHash は `PassSpec` を持たない。Pass の中身は `Inputs#images`
（名前 → 画素の SHA-256）で、面の Spec は `ShaderJson.toJson` の字で鍵に入る。だから:

- **`sampler` 節と `div` を `ShaderJson` の書き出しに必ず入れる**（入れ忘れると、Linear に替えても鍵が同じで古い PNG が返る偽の緑）。
- Pass の画像は **テクセル寸法の絵**（texEnv 用）と **design 寸法に広げた絵**（sprite 用・§3.1）の 2 枚になる。images には
  テクセル寸法の絵を Pass の名前で入れる（広げた絵はそれから決まるので鍵に要らない）。history の透明の 1 枚も `<name>@history` で入れる。
- `DrawHash.usedTextures` は面の texNames と sprite の texture から名前を拾うので、書き換え後の `@history` / `@missing:` の名前も拾う。
  `@missing:` は images に無い名前としてスキップされる（鍵の材料にならない）ことを確かめる。

### 2.5 GL の 1 枚撮り・動画と history

`GlOffscreen` は history を毎回透明にする（§2.3）。窓で遊ぶ時だけ history が効くので、**history の絵は gl_parity で突き合わせない**。
目で確かめる道を別に置く: hd2d_lab に history を使う試しの場面を 1 つ足し、`make run` で窓を開いて F8 の注釈のスクショで見る。

### 2.6 Pass の中の mask（ステンシル）

ターゲットの FBO に depth-stencil の renderbuffer（`GL_DEPTH24_STENCIL8`・**テクセル寸法**）を付け、作り直し・捨てるときに一緒に扱う。
これで `shaderFillMasked` と mask 付き sprite が Pass の中でも GL で抜ける（CPU は今でも抜いている — 実機の方が描き出しに揃う）。
1 枚あたりテクセル数 × 4 byte（480×270 で約 0.5MB）。

### 2.7 テスト

| どこ | 確かめること |
|---|---|
| `engine_world/test/TestRender.flix`（`resolvePassReads`） | 3 本の Pass `a`→`b`→`c` で、`b` が `a` を読む・`a` が `c` を読む・`b` が `b` を読む時の issues = `[ReadsLaterPass({pass="a", reads="c"})]`（1 回の `assertEq`） |
| 同 | 同じ書き換えで、`a` の面の tex 名が `@missing:c`・`b` の面の tex 名が `b@history`・`b` の中の `a` は `a` のまま（名前の List で 1 回） |
| 同 | `Render.sprite("c", z)` を `a` に置くと sprite の texture も `@missing:c` になる（面と sprite が同じに扱われる） |
| 同 | `a` を 2 回宣言 → 列は 1 本・issues = `[DuplicatePass("a")]` |
| 同 | `knownTargets = {"old"}` で `a` が `old` を読む → `ReadsUndeclaredTarget`、普通のテクスチャ名 `tiles` を読む → issue なし |
| 同 | `targets` に Pass に無い名前 `ghost` → `UnknownDescriptor("ghost")` |
| 同 | `passSpecsOf` が Shader 面を surfaces に残し、drawables には入れない（面 1 枚 + box 1 個 → (surfaces 1, drawables 1)） |
| `engine_tools/test/TestRenderPasses.flix` | Pass の中の Shader 面（Solid 色）が Pass の画像に塗られる（`Clear` と `ClearTransparent` の 2 本 — 落とす所が 2 枝あるため） |
| 同 | 2 段の連鎖: Pass `a` に box、Pass `b` に `a` を tex で素通しする面 → `b` の画素 = box の色 |
| 同 | history: `Clear` の Pass が自分を読む面を持つとき、読んだ値は透明（0） |
| 同 | forward reference は黒（0） |
| `bench/gl_parity` A 段階 scene `passChain` | Pass 内の素通しの面（tex を rgb で読むだけ）を 2 段。**バイト一致**（素通しの tex 場は既に A 段階） |
| 同 A 段階 scene `passLaterRead` | Pass `a` の面が後ろの `b` を読み、`a` の sprite が `b` を貼る。GL も CPU も「面は黒・sprite は貼らない」でバイト一致（GL が前のコマを見せていないことの証拠。2 コマ以上回してから撮る） |
| 同 scene `passMask` | Pass の中の `shaderFillMasked`（整数座標の矩形 mask）。2.6 の後で A 段階に入れる |
| （突き合わせない） | history の絵。§2.5 の目視の道 |

### 2.8 リスク

- **Pass の中に Shader 面を置いていたゲームは、絵が変わる**（今は黙って落ちている物が描かれ始める）。リポジトリの中では hd2d_lab だけ。
- forward reference の封じは、Pass の中の sprite が後ろの Pass を貼っていたゲームの GL の絵を変える（今は前のコマの中身が出ている）。リポジトリの中には無い。
- 同名の Pass の 2 回目を描かなくなる（今の GL は 2 回描く）。リポジトリの中には無い。
- history の写しは「自分を読む Pass がある時だけ」1 回の blit。毎コマ テクセル寸法 1 枚ぶん — 安い。

### 2.9 選ばなかった案

- **GL 側（RenderPaint）で「このコマで描いた名前」を数えて封じる**: Shader 面の bind にしか効かず、Pass の中の `Render.sprite(後ろの Pass)` は GL では古い中身・CPU では貼らない、と割れる。書き換えを engine_world の 1 か所にすれば両方が同じ名前を見る。
- **forward reference = 前のコマを読む（GL の素のまま）**: 描き出しで前のコマが無く、PNG と実機が割れる。
- **Pass を依存の順に自動で並べ替える（Bevy の render graph のように）**: 今の「宣言順に描く」が分かりやすく、並べ替えの規則を覚える必要が出る。
- **history を禁止する**: Keep で足りない feedback（ズームしながら尾を引く・色が抜けていく）が書けなくなる。写しの費用は小さい。
- **GIF で前のコマの history を渡す**: 既存の `renderGifWithPasses` の決まり（Keep もコマをまたがない・途中のコマから見られる）と逆になる。変えるなら §8 の 3 で決める。

---

## 3. (b) Pass ごとの解像度の倍率と、読み方（Nearest / Linear）

ここは 2 つに分けた。**倍率は Pass（ターゲット）の性質、補間は読む側の性質。**

理由: 本物のブルームでは、同じ `scene` を **`bright` は Linear で半分の解像度へ縮めて読み**（縮めるときに隣の画素をならしたい）、
**本編の post は Nearest で読む**（windowScale 2 の画面でドット絵をにじませない）。ターゲットに filter を 1 つ持たせると、
どちらかを諦めることになる。読む側で選べれば 1 枚のターゲットで両方が書ける。Unity Shader Graph の **Sampler State** 節
（Sample Texture に「どの filter で読むか」を渡す）と、Godot の sampler の `filter_linear` ヒントと同じ置き場。

### 3.1 倍率（`RenderTarget.Descriptor`）

#### API

```flix
// engine/src/RenderTarget.flix
/// ターゲットの作り方（毎コマの中身 = Render.Pass とは別に、名前ごとに 1 つ）。
/// wgpu / Unity の TextureDescriptor・RenderTextureDescriptor と同じ分け方:
/// LoadOp は「描くたび」の性質なので Pass に、寸法は「テクスチャを作る時」の性質なのでここに置く。
/// scale = design 解像度に掛ける倍率（Unity の renderScale・Godot の scaling_3d_scale と同じ語）。
/// 0 より大きく 1 以下。範囲外・非有限は 1.0 に落として 1 回だけ知らせる（docs/error-handling.md の「既定値で続ける」）。
pub type alias Descriptor = { scale = Float64 }

/// 既定（design 解像度そのまま）。組む時は `{ scale = 0.5 | RenderTarget.defaultDescriptor() }` の形で書く —
/// 欄を足したとき（HDR の色の形式など）に、ゲームの字が止まらないように。
pub def defaultDescriptor(): Descriptor = { scale = 1.0 }

/// ターゲットのテクセル寸法。どの経路もこの 1 本で決める（GL・描き出し・App が別々に丸めると 1px 割れる）。
/// 各軸 max(1, ceil(design × scale))。scale = 1 なら design そのもの。
pub def sizeOf(design: Vec2.Vec2, d: Descriptor): (Int32, Int32)
```

**倍率の置き場は `Render.PassPlan#targets` の 1 か所**（§2.2）。実機は `App.withPassPlan`、描き出しは `Render.passSpecsOf` が
同じ `PassPlan` を読むので、片方だけ倍率を書き忘れて実機と描き出しが黙って割れる、という形が作れない
（`RenderConfig` には欄を足さない）。`PassSpec#scale` は `passSpecsOf` が埋める。
`targets` に書いて Pass に無い名前は `UnknownDescriptor` で 1 回だけ知らせる（綴り違いで倍率が効いていないのに気づけるように）。

**`Render.Pass` には欄を足さない。** `Pass` は `{ name, clear, items }` のレコードの字で組まれていて
（hd2d_lab・`Light.lightMapPass`・bench）、欄を足すと全部コンパイルで止まる。

JSON: エンジンは Descriptor の JSON を持たない。倍率はゲームの Doc（hd2d_lab なら `look.json` の `bloomScale` など）に置き、View で組む（`/doc-design` の「繰り返し調整する数値」）。

#### `eff Target` の型は変えない

`beginTarget(name, width, height, clear)` の `width` / `height` の意味を「design と同じ値」から
「`RenderTarget.sizeOf` のテクセル寸法」へ広げるだけ（型は同じ）。ハンドラ 3 本（LwjglLayer・GlOffscreen・runNoop）の
型は変わらない。doc コメントの「design 解像度と同じ値を渡すこと」は書き直す（§6 の段 8）。

#### GL 側

| 場所 | 変更 |
|---|---|
| `App.renderPasses` | `RenderTarget.sizeOf(design, 名前の Descriptor)` を `beginTarget` に渡す |
| `RenderPaint.beginTarget` | テクスチャは `w × h` で作る（今どおり。寸法が変わったら作り直し・history も捨てる）。**registry へは design の寸法（`screenW × screenH`）で載せる** — `Render.blit` / `blitRegion` / `sprite` の大きさと region の UV は registry の寸法で決まるので、縮んだターゲットも今の式のまま design 全面に貼れる（region の `src` も design px のまま） |
| `RenderPaint.paintTarget` | `designW/H` は design（`screenW/H`）を渡し、`fbW/H` を `w × h` にする |
| `RenderFrame.renderFrameMixed` のターゲットの枝 | viewport を `calcViewport` でなく `(0, 0, fbW, fbH)` にする（design 全面 → ターゲット全面に縦横別の倍率で写す）。scissor の換算は既に `scaleX` / `scaleY` 別。倍率 1 なら `calcViewport(W,H,W,H) = (0,0,W,H)` なので今と同じ |

投影行列は差し替えない（頂点は design px のまま・viewport が縮める）。ピクセルスナップは今も無いので変わらない。
倍率が割り切れない寸法（270 × 0.25 = 67.5 → 68）は、design 全面がテクスチャ全面に写る（縦だけ 68/270 倍）。
uv（0..1）で読む限りどこもずれない。

#### `Render.sprite(name, z)` で貼るときの拡大

- 大きさは registry の design 寸法なので、`Render.blit(name, design, z)` は今と同じく全面ぴったり。
- **sprite で貼る道は常に Nearest**（テクスチャ自身の filter は NEAREST のまま）。半分の Pass を sprite で貼ると 2px の塊になる
  （モザイク・低解像度の味としてそのまま使える）。なめらかに拡大したい時は、`shaderFill` の面で `sampler(linear)` を通して読む（§3.2）。

#### 描き出し（CPU）側 — GL と同じ点を読む

GL は縮んだターゲットのテクセル `(i, j)` を、design 座標の点 `p = ((i+0.5)·W/w, (j+0.5)·H/h)` で塗る
（ラスタライズの判定もシェーダー面の uv もこの点）。CPU はこう合わせる:

1. Pass を **design 解像度（scale 1）で今どおり描く**。ただし Shader 面だけは、各画素の uv を
   「その画素を最後に拾うテクセルの点 `p`」で評価する（`SoftRaster.drawSurface` に「標本点を寄せる」引数を 1 つ）。
   拾われない画素は評価を飛ばす（CPU の時間のほとんどは面の評価なので、半分の Pass なら評価は 1/4）。
2. 描き終えた design 解像度の絵から、テクセル `(i, j)` へ `p` を含む画素（`floor(p)`）を 1 つ拾って `w × h` の絵にする。
3. `Keep` の prev（`w × h`）は、1. の前に design 解像度へ「画素 `(x, y)` ← テクセル `floor((x+0.5)·w/W)`」で広げる。
   この広げ方と 2. の拾い方は往復で元のテクセルに戻る（`w ≤ W` なら `(floor(p)+0.5)·w/W` は必ず `(i, i+1)` に入る）。
4. 描き出しの画像の表は 2 つ持つ: **sprite 用は design 寸法**（3. と同じ式で広げた絵 — GL の Nearest の拡大と同じ式）、
   **tex 場の読み用（texEnv）はテクセル寸法そのまま**。

一致の範囲: 整数座標の矩形・整数倍の sprite・Nearest の tex 読みは、倍率 1/2・1/4 で GL と同じテクセルを読む
（`p = 2i+1` と、CPU の画素中心 `2i+1.5` が、整数の縁をまたがないため）。小数の縁・多角形・字は近似（今の倍率 1 と同じ扱い）。
`SoftRaster.RasterReq#scale`（`Int32`）は変えない（スケールの小数化は 78 か所に及ぶので避けた）。

#### テスト

| どこ | 確かめること |
|---|---|
| `engine/test`（`RenderTarget.sizeOf`） | (480×270, 0.5) → (240,135)・(480×270, 0.25) → (120,68)・(480×270, 1.0) → (480,270)・scale 0 / 2.0 / NaN → (480,270)。1 回の `assertEq` |
| `engine_world/test`（`passSpecsOf`） | `targets` の倍率が `PassSpec#scale` に入り、書かなかった名前は 1.0 |
| `engine_tools/test/TestRenderPasses.flix` | scale 0.5 の Pass の画像の寸法 = `sizeOf` |
| 同 | 整数座標の box（x=2..6）を描いた scale 0.5 の Pass のテクセル 1..2 が box 色・0 と 3 が背景 |
| 同 | scale 0.5 の Pass を `Render.blit` で貼った本編が、design 全面を 2px の塊で覆う（左上 2×2 が同じ色） |
| 同 | Keep + scale 0.5 で、何も描かない Pass の画像が prev のテクセルのまま（3. の往復） |
| `bench/gl_parity` A 段階 scene `passHalf` | scale 0.5・整数座標の box と整数倍 sprite を描き、`blit` で貼る。**バイト一致** |
| 同 B 段階 scene `passQuarterOdd` | 270 / 4 の割り切れない寸法。差の数だけ報告 |

### 3.2 読み方（`sampler` 節）

#### API

```flix
// engine/src/ShaderDoc.flix
/// tex / blur がテクスチャを読むときの補間（wgpu の FilterMode・Unity の Point/Linear と同じ 2 択）。
pub enum FilterMode with Eq, ToString { case Nearest case Linear }

// Field に 1 case
/// of の中の tex / blur を、filter の補間で読む（Unity Shader Graph の Sampler State 節）。
/// 入れ子なら内側が勝つ。use（shared）の中までは届かない — use は基準 uv で 1 回だけ評価する決まりと同じで、
/// shared の側に自分の sampler を書く。
case Sampler({ filter = FilterMode, of = Field })
```

JSON: `{"kind":"sampler","filter":"linear","of":{…}}`（`filter` は `"nearest"` / `"linear"`）。`tex` / `blur` 自身の形は変えない
（`Field.Tex({ name, chan })` に欄を足すと、レコードの字で組んでいるゲームが止まるため。hd2d_lab・sound-novel-starter が該当）。

#### 実装

| ファイル | 変更 |
|---|---|
| `ShaderDoc` | `foldField` / `remappedChild`（uv は曲げないので `None`）/ `renameTex`（§2.2）に 1 case。**`texReads(spec): List[(String, FilterMode)]`** を正典順（今の texNames と同じ「bindings → 色 → alpha の初出順」）で。`texNames` は残す（名前だけ・重複なし） |
| `ShaderGen` | uniform の番号を `(名前, filter)` の組ごとに振る。`fieldExpr` に「今の filter」を 1 つ通す。**sampler を使わない Spec は組 = (名前, Nearest) で今と同じ並びなので、GLSL は 1 文字も変わらない**。Spec の比較（`TestShaderGenEqSpec` が見ている所）に 1 case |
| `ShaderEffect.ShaderRenderCmd` | `texNames: List[String]` を `texReads: List[(String, ShaderDoc.FilterMode)]` に替える（組むのは `Render.drawShaders` だけ — engine の中で閉じる） |
| `RenderPaint` / `RenderSprite` | sampler object を 2 個（NEAREST + CLAMP・LINEAR + CLAMP）作り、bind ごとに選ぶ（`SurfaceTexBind` に `sampler` を足す）。テクスチャ自身の filter は NEAREST のまま（sprite の道を変えない） |
| `ShaderEval` | `Node.Tex` / `Node.TexBlur` に filter を持たせ、Linear は `sampleTexLinear`（下の式）。`compile` が scope を下ろす |
| `ShaderJson` | `"sampler"` の読み書き（**書き出しを忘れると DrawHash の鍵が変わらない** — §2.4）。schema（`templates/*/assets/shader.schema.json`）に kind を 1 つ |
| `Render.drawWith` の「テクスチャ 1 枚だけ読む面を sprite に落とす」判定 | `sampler` の下の tex は落とさない（代表色側へ）。sprite に落とすと Nearest になって実機と変わる |

CPU の Linear の式（GL の `GL_LINEAR` + `CLAMP_TO_EDGE` と同じ点・同じ重み）:

```
x = u·w − 0.5,  y = v·h − 0.5
x0 = floor(x), fx = x − x0   （y も同じ）
4 点 (x0, y0) (x0+1, y0) (x0, y0+1) (x0+1, y0+1) を各軸 [0, w−1] / [0, h−1] に張り付けて読む（8bit / 255）
値 = mix(mix(t00, t10, fx), mix(t01, t11, fx), fy)
```

pass の上下逆格納は、GL が読む v を `1 − v` にするだけなので、上の式を正立の画像に当てた値と一致する（式が上下に対称）。

一致の範囲: **読む点は同じ。重みは GPU が固定小数（たいてい 8bit）に丸めるので ±1/255 程度ずれうる** → backend-parity.md に
「近似（補間の重みの丸め）」の行を足す。Nearest の行（同一保証）はそのまま。

#### テスト

| どこ | 確かめること |
|---|---|
| `engine/test`（`ShaderEval`） | 2×1 の画像（黒・白）を Linear で読む: u = 0.25（左のテクセルの中心）→ 0.0・u = 0.5（2 つの境目）→ 0.5・u = 0.0（端の張り付き）→ 0.0。タプルで 1 回 |
| 同 | `sampler` の入れ子は内側が勝つ（外 Linear・内 Nearest の tex が Nearest の値） |
| `engine/test`（`ShaderGen`） | sampler を使わない既存の Spec の GLSL が前と同じ（既存のテストがそのまま緑なこと） |
| 同 | 同じ名前を Nearest と Linear で読む Spec は uniform が 2 本（`uTex0` / `uTex1`）になる |
| `engine/test`（`ShaderJson`） | `"sampler"` の往復・`filter` の綴り違いは `Err` |
| `bench/gl_parity` B 段階 scene `linearRead` | 半分の Pass を Linear で全面へ読む。差の最大と画素数を報告（A 段階には入れない） |

### 3.3 リスク

- **viewport の全面化**: ターゲットの枝だけ。倍率 1 は今と同じ値になることを gl_parity A 段階（既存の passPaste・lightmap）で確かめる。
- `ShaderRenderCmd` の欄替えで render_gl の `drawSurface` が変わる。テストは render_gl に少ない → gl_parity の texField（A 段階）が最初の網。
- 倍率を Studio で毎コマ動かすと、ターゲットを毎コマ作り直す（GPU のメモリは古い方を必ず捨てる今の道で増えない）。スライダーを放すまで重い。
- 描き出しの「標本点を寄せる」面の評価は、式がずれると Pass の中の面だけ GL と割れる。gl_parity の `passChain` を scale 0.5 でも 1 本回す。

### 3.4 選ばなかった案

- **Pass（ターゲット）に filter を持たせる（依頼の形・Unity の RenderTexture.filterMode / Bevy の ImageSampler）**: §3 冒頭の理由（同じ `scene` を
  bright は Linear・post は Nearest で読めない）。加えて sprite の道まで Linear になると、CPU 側に「回転・mask 付き sprite の双線形」を
  書く必要が出る。読む側に置けば一致の検証は `ShaderEval` の 1 か所で済む。
- **`tex` / `blur` に `filter` の欄を足す**: JSON は後方互換だが、Flix のレコードの字で組んでいるゲームが止まる。
- **`Render.Pass` に `scale` の欄を足す**: 同じくレコードの字で止まる。
- **倍率を `App.withTargetDescriptors` と `RenderConfig#targetDescriptors` の 2 か所で配線する（改訂 1 の案）**: 片方を忘れると実機と描き出しが黙って割れる。`PassPlan` 1 つにまとめた。
- **倍率を `Full | Half | Quarter` の enum にする**: 割り切れない寸法を扱えれば enum にする理由が無く、Doc のスライダーでも触れる小数にした。
- **投影行列をターゲットごとに差し替える（等方の 1/4 を守るため、テクスチャを `ceil` 寸にして余白を持たせる）**: 全 program（キャッシュの宣言シェーダーも）の uniform を差し直すことになり、`blit` の大きさも 1〜2px 割れる。
- **GLSL で双線形を手で書く（`texelFetch` 4 回 + 自前の重み）**: CPU とバイト一致にできるが、blur 24 点 × 4 = 96 回読む。ハードの補間を使い、近似として扱う方を取った。
- **CPU の SoftRaster を小数の倍率で直接描く**: `sf` が 78 か所で単一のスカラー。縦横別にするのは大きな作り替えで、Java2D の小数倍のラスタライズが GL と同じ点を塗る保証も無い。

---

## 4. (c) RGB をまとめて読むぼかし・amount = 0 で点を読まない

### 4.1 同じ読みを共通部分式として括り出す（CSE / hoist・API は変えない）

**同じテクスチャ・同じ読み方（filter）・同じ座標・同じ半径と taps の `tex` / `blur` は、チャンネルが違っても 1 回だけ読む。**
これを ShaderDoc の決まりとして doc に書く。r・g・b の 3 本を書く今の JSON のまま、読む数が 1/3 になる。

- GLSL（`ShaderGen`）: `tex` は `texture(uTexN, …)`、`blur` は `sg_blur(…)` の呼び出しの字（チャンネルの `.r` を除いた所）を鍵にし、
  **2 回以上出る鍵だけ** `vec4 sgr0 = …;` に括り出して（hoist）、その文で使う直前に置く（bindings の文の途中でも）。
  呼び出しの字は `vUv`・`uTime`・uniform・前に宣言した binding の変数だけで閉じているので、括り出してよい（式に分岐は無い）。
  - 1 回しか出ない鍵は括り出さないので、1 チャンネルしか読まない Spec の GLSL は変わらない。
  - **同じ引数で r・g・b を読む Spec は GLSL の字が変わる（絵は同じ）**: hd2d_lab の post と、sound-novel-starter の `Backdrop`（r・g・b の blur を同じ引数で読む）が該当。
    描き出しは CPU なので PNG のバイトには効かない（§4.3 で確かめる）。
  - 実装は `fieldExpr` に「読みの字 → 置き換え」の口を 1 つ通し、1 回目で数え、2 回目で置き換える（region の Ref で数える）。
- CPU（`ShaderEval`）: **GLSL 側を先に入れ、描き出しの時間を測ってから決める**（段 3b）。入れる時は、`compile` が同じ鍵の `Tex` / `TexBlur` に
  同じ組番号を振り、画素ごとの `env`（今 binding を置いている配列）の後ろに組ごとの控え（読んだ座標・半径と 4 チャンネルの答え）を置き、
  座標と半径が `==` で同じならチャンネルを取り出すだけにする。各チャンネルの足し算の順は今と同じなので、答えはバイト単位で今と同じ。

hd2d_lab の post（tilt 24 点 × 3 + bloom 24 点 × 3 = 1 画素 144 回）が GPU では 48 回になる。

### 4.2 半径が 0 なら 1 点だけ読む

`sg_blur` の頭に `if (radius.x == 0.0 && radius.y == 0.0) return texture(…);`。CPU の `blurTex` も同じ分岐。
`radius × amount` が 0 の画素（ティルトシフトのピントの帯）は 1 回読みになる。

- 答えは「同じ値を taps 回足して taps で割る」から「その値そのもの」に変わる。浮動小数の最後の 1 桁が変わりうる。
  `SoftRaster.argbOfRgba` の `byteOf` は四捨五入（`ri` = +0.5 して切り捨て）なので、k/255 のちょうど半分の所でない限り 8bit の答えは変わらない。
  それでも **blur を使うテンプレート（sound-novel-starter の Backdrop）の `reference/SHA256SUMS.txt` が変わらないこと**をこの段の合格線にする。
- ターゲットに mipmap は無いので、分岐の中の `texture()` の微分は答えに効かない（mipmap を入れる時は `textureLod` に替える — WhyNot として GLSL の横に書く）。
- GPU は隣の画素がまとまって同じ分岐に入るほど得をする。ピントの帯はひと続きなので効く。

### 4.3 テスト

| どこ | 確かめること |
|---|---|
| `engine/test`（`ShaderEval`） | `blur` で amount = 0 の値 = 同じ点の `tex` の値（`assertEq`） |
| `engine/test`（`ShaderGen`） | 3 チャンネルの blur の Spec の GLSL に `sg_blur(` の呼び出しが 1 回（関数の宣言を除く）。1 チャンネルだけの Spec の GLSL は前と同じ |
| 同（段 3b を入れる時） | r・g・b の 3 本の blur の答え = 1 本ずつ別の Spec で評価した答え（タプルで 1 回） |
| 描き出し | sound-novel-starter・hd2d_lab の場面の PNG が前とバイト一致（`make render` + SHA256SUMS） |

### 4.4 リスク

- 共通部分式の括り出し（CSE）の鍵は「生成した GLSL の字」なので、uv の式の字が 1 文字でも違えば別の読み（安全側に外れるだけ・まとまらないだけ）。
- GLSL の字が変わった Spec は program を作り直す（起動時に 1 回。キャッシュの鍵は GLSL の字）。

### 4.5 選ばなかった案

- **色（vec4）を返す節を足す（依頼の形）**: 今の語彙は「場 = 1 個の値」で閉じていて、色を返す節を足すと場の型が 2 つになる
  （場の合成・`use`・JSON の検査・Studio のフォームの全部が 2 種を扱う）。`Spec` の形に欄を足す形（色の shared）は、
  レコードの字で `Spec` を組んでいるゲームが全部止まる。共通部分式の括り出しなら API も JSON も変わらず、読む数だけが減る。
- **GLSL コンパイラーの共通部分式の消去に任せる**: ループと `texture()` を含む関数呼び出しが確実にまとまる保証は無い（ドライバ次第）。

---

## 5. (d) `pow` の負の整数指数・割り算

### 5.1 `pow`

| 指数 p | GLSL | CPU |
|---|---|---|
| p ≥ 0（今と同じ） | 整数は反復積・非整数は `pow(max(0, x), p)` | 同じ |
| p < 0 の整数 | `min(1e6, 1.0 / 反復積(max(1e-6, x), −p))` | 同じ順の積の逆数を 1e6 で上切り |
| p < 0 の非整数 | `min(1e6, pow(max(1e-6, x), p))` | `Float64.pow` に同じ底・同じ上切り |

- 底の下切り `1e-6` と答えの上切り `1e6` は `ShaderDoc` に定数として置き、Gen と Eval が同じ物を読む（片方だけ直して割れないように）。
- 上切りが要る理由: 底 1e-6 で p ≤ −7 のとき、GPU（float32）は積が 0 に潰れて `1/0 = inf`、CPU（float64）は有限の大きな値になって割れる。
  1e6 で切れば両方とも 1e6 にそろう。上切りより手前の大きな値（1e4〜1e6 の辺り）は float32 と float64 の差が出うる → backend-parity.md の近似の行に書く。
- 負の指数で底が 0 以下のとき、今の GLSL は未定義・CPU は無限大。これが 1e6 になる（hd2d_lab の `-0.9999` は底が 0.02 以上なので変わらない）。

### 5.2 割り算（`div`）

- `BinOp.Div`、JSON は `{"kind":"math2","op":"div","a":…,"b":…}`。**b が 0 なら 0**。
  0 で割った画素が無限大・NaN になり、黒や白の点で潰れるのを止める（Unity / Godot の Divide は素の割り算だが、ここは CPU と同じ答えを出すことを優先）。
- GLSL は関数にする: `float sg_div(float a, float b) { return b == 0.0 ? 0.0 : a / b; }` を **div を使う Spec にだけ**足す
  （`usesBlur` と同じ形の `usesDiv`。式に直に `(b == 0.0 ? 0.0 : a / b)` と書くと b の式を 2 回書くことになり、b に tex や blur が入ると読みが倍になる）。
  使わない Spec の GLSL は変わらない。
- b が 0 に近い所（1e-7 など）は、float32 と float64 で b が 0 になるかならないかが割れうる。backend-parity.md の近似の行に書く。
- `recip`（1/x）は足さない — `div(const 1, x)` で書ける。語を増やさない。
- `ShaderJson` の書き出しに `"div"` を入れる（入れ忘れると DrawHash の鍵が変わらない — §2.4）。

### 5.3 テスト

| どこ | 確かめること |
|---|---|
| `engine/test`（`ShaderEval`） | pow(2, −1) = 0.5・pow(2, −2) = 0.25・pow(0, −1) = 1e6・pow(0.5, −30) = 1e6（上切り）・pow(4, 0.5) = 2（今と同じ）。タプルで 1 回（誤差のある所は epsilon） |
| 同 | div(1, 4) = 0.25・div(1, 0) = 0 |
| `engine/test`（`ShaderGen`） | p = −1 の GLSL が `1.0 /` を含む。div を使う Spec にだけ `sg_div` の宣言が入る |
| `engine/test`（`ShaderJson`） | `"div"` の往復 |

---

## 6. 実装の順番（それぞれで `flix check` と描き出しが通る単位）

各段の合格線: 触ったパッケージの `make test-<name>`・ほかは `flix check`・`make sync-engine-full` が通る・
hd2d_lab の lib に差して `make render` が通る。描画経路を触った段は `make gl-parity`（A 段階が差 0 px）。

| 段 | 中身 | 触るパッケージ | 合格線に足すもの |
|---|---|---|---|
| 1 | §5 pow の負の指数・`div`（`sg_div`） | engine（ShaderDoc / Gen / Eval / Json）・schema | — |
| 2 | §4.2 半径 0 で 1 点 | engine（Gen / Eval） | sound-novel-starter の SHA256SUMS が変わらない |
| 3a | §4.1 共通部分式の括り出し（GLSL のみ） | engine（Gen） | hd2d_lab の GL の見た目が同じ（目視）・PNG がバイト一致 |
| 3b | §4.1 の CPU の読みの控え（3a の後に描き出しの時間を測って、効く時だけ） | engine（Eval） | hd2d_lab の PNG がバイト一致・描き出しの時間の前後 |
| 4a | §2 の Pass の中の Shader 面 ＋ `resolvePassReads`（forward reference を黒・同名・`@` の名前・宣言の無い Descriptor の知らせ）＋ `PassPlan` / `withPassPlan` / `passSpecsOf` ＋ LRU の pin | engine（ShaderDoc.renameTex）・engine_world（App / Render）・render_gl（RenderPaint）・engine_tools（HeadlessRender / SoftRaster）・bench | gl_parity に `passChain`・`passLaterRead` |
| 4b | §2 の history（`@history` の別名・blit・後始末・GlOffscreen は透明） | render_gl（RenderPaint / LwjglLayer / GlOffscreen）・engine_tools | TestRenderPasses の history（透明）・hd2d_lab の試しの場面を窓で目視（§2.5） |
| 5 | §2.6 ターゲットのステンシル | render_gl（Target / RenderPaint） | gl_parity に `passMask` |
| 6a | §3.1 倍率の GL 側と `sizeOf`（`RenderTarget.Descriptor`・App が `sizeOf` を渡す・registry は design 寸法・viewport の全面化） | engine（RenderTarget）・engine_world（App）・render_gl（RenderPaint / RenderFrame） | 既存の gl_parity A 段階が全部差 0 px（倍率 1 で変わらないこと） |
| 6b | §3.1 倍率の CPU 側（design 解像度で描いて GL の標本点で拾う・面の標本点を寄せる・prev を広げる・images を 2 枚） | engine_tools（HeadlessRender / SoftRaster） | gl_parity に `passHalf`（A）・`passQuarterOdd`（B） |
| 7 | §3.2 `sampler` 節（Linear） | engine（ShaderDoc / Gen / Eval / Json / ShaderEffect）・engine_world（Render）・render_gl（RenderPaint / RenderSprite） | gl_parity に `linearRead`（B） |
| 8 | 文書と網（下の一覧） | docs・agents-pack | ゲームの足元で `make agent-eval ONLY=<お題>` |

段 1〜3 は engine の中だけで閉じ、ほかの段と独立に入れられる。段 4a〜6b は同じ `RenderPaint` を触るので同じ人が続けて持つ（並行させない）。
段ごとにレビュー役を立てて 90 点を越えてから次へ（AGENTS.md・各段の終わりに `/critique-code`）。

段 8 で直す文書（doc コメントを含む）:

- docs/shader-doc.md（tex・blur・「ぼかしのコスト」・pass の節・`sampler` / `div` / 共通部分式の決まり）
- docs/backend-parity.md（Pass の行・Linear の行・pow の上切りと div の 0 付近の近似の行・history は突き合わせない）
- docs/headless-render-recipe.md（`PassPlan` と `passSpecsOf`）
- `Render.Pass` の doc（「M1 では描かれない」を消す）・`Render.passSpecOf` の doc（「withoutShaders で外す」の文）・`App.withPasses` / `App.Rec#passes` のコメント
- `HeadlessRender.PassSpec` の doc（「withoutShaders で外してから」）・`renderGifWithPasses` / `renderPngWithPasses` の doc
- `eff RenderTarget.Target.beginTarget` の doc（「design 解像度と同じ値を渡すこと」→ テクセル寸法）・`RenderTarget.LoadOp` の doc（history との関係）
- `agents-pack/AGENTS.core.md` の早見表 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本（「半分の解像度の Pass で本物のブルームを組む」）・`make api-digest`
- docs/performance.md の「3 つの門」へ 1 行（Pass の倍率で面の画素数を減らす）

性能の目安（480×270・1 画素 = 1 回の面の評価）:

| 形 | 1 コマの画素数 |
|---|---|
| 全面の post 1 枚 | 129,600 |
| scale 0.5 の Pass 1 枚 | 32,400 |
| scale 0.25 の Pass 1 枚 | 8,160（120×68） |

blur の点の数を掛けた数が GPU の読みの数。全面の post で blur（24 点）を読むと 129,600 × 24 ≈ 310 万回 / コマ（チャンネルごとならその 3 倍）。
§4.2 でピントの帯は 1 回読みに落ち、ブルームを 1/4 で組めば 8,160 × 24 ≈ 20 万回で済む。

---

## 7. 試作ゲーム（hd2d_lab）側の使用例

前提: `look.json` に `bloomScale`（0.5）・`bloomThreshold`・`blurScale`（0.5）を足し、`LookDoc` で読む。
下の Flix は形を示すための物（細かな名前は hd2d_lab の今の `View.flix` に合わせて直す）。

### 7.1 Pass の計画（列と倍率を 1 つで）

```flix
pub def passPlanOf(w: In): Render.PassPlan =
    let look = LookDoc.rec(w#look);
    let black = RenderTarget.LoadOp.Clear(Color.rgb(0.0, 0.0, 0.0));
    let passes =
        Light.lightMapPass(lightCfg(w)) |> withSkyLight
            // 平らな石畳（場面の Pass より前に描く — 場面の Pass が読むので）
            :: flatGroundPass()
            // 場面: 遠近の地面（shift の面）を world の中に z を決めて入れられる（§7.4）
            :: { name = "scene", clear = RenderTarget.LoadOp.Clear(ThemeDoc.rec(w#theme)#bg),
                 items = List.append(world(w), Light.lightMapOverlay(lightCfg(w)) :: lampGlows(w)) }
            // 明るい所の抜き出し（半分の解像度・scene を Linear で縮めて読む）
            :: { name = "bright", clear = black, items = fullFill(brightSpec(look), w#t) :: emissive(w) }
            // ぼかし 2 回（1/4 の解像度・前の Pass を Linear で読む）
            :: { name = "bloomA", clear = black, items = fullFill(blurOf("bright", look#bloomRadius, look), w#t) :: Nil }
            :: { name = "bloomB", clear = black, items = fullFill(blurOf("bloomA", look#bloomRadius * 0.5, look), w#t) :: Nil }
            // ピントの外用に、場面全体を半分の解像度でぼかした 1 枚
            :: { name = "sceneBlur", clear = black, items = fullFill(blurOf("scene", look#tiltRadius, look), w#t) :: Nil }
            :: Nil;
    let at = s -> { scale = s | RenderTarget.defaultDescriptor() };
    { targets = Map#{ "bright" => at(look#bloomScale), "bloomA" => at(look#bloomScale * 0.5),
                      "bloomB" => at(look#bloomScale * 0.5), "sceneBlur" => at(look#blurScale) }
      | Render.passPlan(passes) }

def fullFill(spec: ShaderDoc.Spec, t: Float64): Render.PlacedItem =
    Render.shaderFill(spec, { position = Vec2.zero(), size = p(wd(), ht()) }, t, 0)
```

Main と描き出しは同じ `passPlanOf` を読む（倍率を 2 か所に書かない）:

```flix
// Main
|> App.withPassPlan(Resources.read((res, w) -> View.passPlanOf(View.inputOf(res, w))))

// SceneRender.shoot
let prepared = Render.passSpecsOf(texInfo, View.passPlanOf(input));
prepared#issues |> List.forEach(i -> println("[render] ${i}"));
HeadlessRender.renderPngWithPasses(cfg, prepared#specs, drawables, polygons, surfaces, name);
```

### 7.2 本物のブルーム（明るい所を抜く → ぼかす → 足す）

```flix
// 明るさ = 0.2126 r + 0.7152 g + 0.0722 b。しきいより上だけを残す。
// r・g・b を別々に tex で読んでも、同じ座標の読みは 1 回にまとまる（§4.1）。
def brightSpec(look: LookDoc.Rec): ShaderDoc.Spec =
    let read = chan -> Field.Sampler({ filter = FilterMode.Linear,
                                       of = Field.Tex({ name = "scene", chan = chan }) });
    let luma = add(add(mul(k(0.2126), read(TexChan.R)), mul(k(0.7152), read(TexChan.G))),
                   mul(k(0.0722), read(TexChan.B)));
    // しきいの上を 0..1 に伸ばす: (luma − th) / (1 − th)。割り算は div（§5.2）。
    let over = Field.Bin({ op = BinOp.Max, a = k(0.0),
        b = Field.Bin({ op = BinOp.Div, a = sub(luma, k(look#bloomThreshold)), b = k(1.0 - look#bloomThreshold) }) });
    let chan = c -> mul(read(c), Field.Ref("over"));
    { name = "bright", cycleRate = 0.0, bindings = ("over", over) :: Nil,
      out = Out.Fill({ shade = Shade.Rgb({ r = chan(TexChan.R), g = chan(TexChan.G), b = chan(TexChan.B) }),
                       alpha = k(1.0) }) }

// 前の Pass を Linear でぼかして素通しする面（bloomA・bloomB・sceneBlur で共用）
def blurOf(src: String, radius: Float64, look: LookDoc.Rec): ShaderDoc.Spec =
    let b = chan -> Field.Sampler({ filter = FilterMode.Linear,
        of = Field.TexBlur({ name = src, chan = chan, radius = { x = radius / aspect(), y = radius },
                             taps = ShaderDoc.blurTaps(look#bloomTaps), amount = k(1.0) }) });
    { name = "blur_" + src, cycleRate = 0.0, bindings = Nil,
      out = Out.Fill({ shade = Shade.Rgb({ r = b(TexChan.R), g = b(TexChan.G), b = b(TexChan.B) }),
                       alpha = k(1.0) }) }
```

`emissive(w)`（灯り・窓）は `bright` の Pass に足すので、しきいに届かない暗い灯りもブルームに乗せられる（今の `glow` の Pass の役目を吸収）。

### 7.3 半分の解像度のぼかしで作るティルトシフト（本編の post）

```flix
def postSpec(look: LookDoc.Rec): ShaderDoc.Spec =
    // ピントの帯（0 = くっきり・1 = ぼかし）は今の式のまま。
    let v = Field.Uv({ axis = ShaderDoc.Axis.V });
    let dist = Field.Un({ op = ShaderDoc.UnOp.Abs, of = sub(v, k(look#focusCenter)) });
    let tilt = Field.Smoothstep({ lo = look#focusHalf, hi = look#focusHalf + Float64.max(0.01, look#focusRamp), of = dist });
    // くっきり = 場面を Nearest で（ドット絵を崩さない）。ぼかし = 半分の sceneBlur を Linear で（段も粒も出ない）。
    let sharp = chan -> Field.Tex({ name = "scene", chan = chan });
    let soft  = chan -> Field.Sampler({ filter = FilterMode.Linear, of = Field.Tex({ name = "sceneBlur", chan = chan }) });
    let bloom = chan -> Field.Sampler({ filter = FilterMode.Linear, of = Field.Tex({ name = "bloomB", chan = chan }) });
    let vig = …（今のまま）;
    let channel = chan -> mul(add(Field.Blend({ a = sharp(chan), b = soft(chan), by = Field.Ref("tilt") }),
                                  mul(k(look#bloomStrength), bloom(chan))), Field.Ref("vig"));
    { name = "hd2d_post", cycleRate = 0.0, bindings = ("tilt", tilt) :: ("vig", vig) :: Nil,
      out = Out.Fill({ shade = Shade.Rgb({ r = channel(TexChan.R), g = channel(TexChan.G), b = channel(TexChan.B) }),
                       alpha = k(1.0) }) }
```

本編の post は blur を 1 つも持たず、1 画素で読むのは 3 枚 × 1 回（§4.1 でチャンネルがまとまる）。
ぼかしの重さは `sceneBlur`（32,400 画素 × taps）と `bloomA/B`（8,160 画素 × taps）に移る。
全面で `blur(amount = tilt)` を使う今の形を残す場合でも、§4.2 でピントの帯は 1 回読みになり、§3.2 の `sampler(linear)` で包めば 2px の段が消える。

### 7.4 遠近の地面を場面の Pass に入れる

```flix
// world(w) の地面の層（今の頂点で遠近を掛けた石畳の代わり）
Render.shaderFill(groundShiftSpec(), { position = Vec2.zero(), size = p(wd(), ht()) }, w#t, groundZ())

// groundShiftSpec の 1/t は div で（pow(t, −0.9999) の逃げをやめる）
let inv = Field.Bin({ op = BinOp.Div, a = k(1.0), b = t });
```

`groundFlat` は `scene` より**前**に宣言する（後ろに置くと forward reference で黒になり、`ReadsLaterPass` が 1 回出る）。
地面は `scene` の中で家・旅人・霧と z で重なり、その上から post のティルトシフトとブルームが掛かる。

---

## 8. 人に決めてほしい所

1. **補間を読む側（`sampler` 節）に置く** — 依頼は「Pass ごとの Nearest / Linear」。同じ `scene` を bright は Linear で縮めて読み、post は Nearest で読むため（§3 冒頭・§3.4）。Pass ごとの既定の filter も別に欲しいか。（レビューでは賛成）
2. **本編がこのコマで宣言していない古いターゲットを読む件**は、知らせるだけで書き換えない（今の GL は古い中身・CPU は黒）。Pass の中と同じく黒に書き換えれば実機と描き出しがそろうが、今の GL の絵が変わる。
3. **history は窓で遊ぶ時だけ**。描き出し（PNG・GIF）と GL の 1 枚撮り・動画は毎コマ透明（既存の GIF の「毎コマ透明から」に合わせた）。
   GIF と動画で尾を引く絵を見たいなら、`renderGifWithPasses` の決まり（コマをまたがない）を変えることになる — その時は Keep も一緒にまたがせるかを決める。
4. forward reference は黒（前のコマを読ませない）・同名 Pass の 2 回目は描かない・`@` を含む名前は禁止（§2.1）。
5. **倍率は小数（0 < scale ≤ 1）**。割り切れない寸法も許し、design 全面 → テクスチャ全面に写す。CPU の一致は整数座標の絵だけ（§3.1）。1 より大きい倍率（超解像）は今回入れない。（レビューでは賛成）
6. **倍率の置き場は `PassPlan` 1 つ**（`App.withPassPlan` を足し、`withPasses` はその薄い形に）。
7. sprite で貼る道は常に Nearest・ターゲットにステンシル（DEPTH24_STENCIL8・テクセル寸法）・色を返す節を足さない・`div` は 0 割りで 0（レビューでは賛成）。
8. pow の負の指数の答えを 1e6 で上切りする（底の下切り 1e-6 と組）。
9. 今回入れない物: HDR の色の形式（RGBA16F。8bit のターゲットは 1.0 で切れるので、しきいの上の明るさが残らない — ブルームの質に効く次の一手）、
   ぼかしの重み（今は円の中に均一。ガウスの重みや横・縦に分けたぼかし）、mipmap による縮小の連鎖、`Render` に全面の面を 1 行で置く助け（`fullFill` 相当）。どれを次に回すか。

### 振る舞いが変わる所（後方互換の例外）

| 変わる所 | 誰に効くか |
|---|---|
| Pass の中の Shader 面が描かれる | Pass に `shaderFill` を置いていたゲーム（リポジトリの中では hd2d_lab のみ） |
| Pass の中で後ろの Pass・古いターゲットを読むと黒（sprite は貼らない） | Pass の中の sprite で後ろの Pass を貼っていたゲーム（リポジトリの中には無い） |
| 同名の Pass の 2 回目を描かない | 同じ名前を 2 回宣言していたゲーム（無い） |
| Pass の中の mask が GL でも抜ける（段 5） | Pass に mask 付き sprite / `shaderFillMasked` を置いていたゲーム |
| pow の負の指数 | 負の整数（今は 1 になる不具合）・負の非整数で底が 0 以下（今は未定義 / 無限大） |
| blur の半径 0 | 浮動小数の最後の桁（8bit の答えは変わらない見込み・段 2 の合格線で確かめる） |
| 同じ引数で r・g・b を読む Spec の GLSL の字 | hd2d_lab・sound-novel-starter の Backdrop（絵は同じ） |
| `PassSpec` に欄 / `ShaderRenderCmd` の欄替え | レコードの字で `PassSpec` を組む所（bench のみ）/ `ShaderRenderCmd` を組む所（engine の中のみ） |
| `BinOp` に case（`Div`）/ `Field` に case（`Sampler`） | `BinOp` / `Field` を網羅で match しているゲーム（リポジトリの中のゲーム・テンプレートには見つかっていない。engine の中は `foldField` `remappedChild` ShaderGen ShaderEval ShaderJson の比較と読み書きが止まるので、そこで足す） |
| `App.Rec#passes` の型 | App の内部の欄。`withPasses` の形は変わらない |

---

## 9. 実装で決まった所（改訂 3）

設計から変えた・足した所だけ書く。

| 所 | 決まり |
|---|---|
| 名前 | `PassReadIssue` → `Render.PassPlanIssue`（payload は `(Pass の名前, 読んだ名前)` の組・`Eq` を持たせるため record にしない）。補間は `ShaderDoc.FilterMode`（`Nearest` / `Linear`） |
| history の別名 | `RenderTarget.historyName`（engine に置く — engine_tools は engine_world に依存しないので Render には置けない） |
| knownTargets | `App.TileCache#passTargets`（ループと `paintOnce` が既に持ち回す値に載せた。1 枚撮りは毎回空 = 描き出しと同じ） |
| `passSpecOf` | 1 枚用として残し、doc に「Pass の列は `passSpecsOf` を通す」。`bin/lint-rules/forbid.json` に `pass-spec-of-map`（`List.map(Render.passSpecOf …)` を止める） |
| 描き出しの縮んだ pass | `SoftRaster.renderPassImageScaled`（design 解像度で描いて GL の標本点で拾う）・`SoftRaster.resampleNearest`（縮める・広げるの 1 本）・`SoftRaster.texelsName`（tex 場が読むテクセル寸法の絵の名前） |
| 縦の拾い方 | 標本点がちょうど画素の境目に乗った時、縦は**上の画素**を拾う（`SoftRaster.pickedPixel`）。GL のターゲットは上下逆格納なので、design の上の縁に乗った点を含めない。これで奇数座標の箱の縁も scale 0.5 でバイト一致する |
| gl_parity の A 段階の条件 | 縮んだ pass では、面の中の式（市松の升目など）の境がテクセルの標本点に乗らないこと（升目の境が箱の中心から cell ごと — 偶数にそろえる）。scene に `exact`（false = B 段階）と `targets`・`repeats` を足した |
| GLSL の括り出し | `fieldExpr` が読みの呼び出しを印で囲み、`finishReads` が全部の文で数えて 2 回以上の物だけ `vec4 sg_rN` に括り出す。1 回きりの読みの GLSL は変わらない |
| 3b（CPU の読みの控え） | 入れていない（GLSL 側だけ。描き出しの時間を測ってから決める） |

