# 段 F: HDR の Pass・トーンマッピング・FXAA（rev3）

rev2 → rev3: 再レビュー 74 点。3D の emission を CPU で切らない・α は読む側で切る・blendPixelF の α の式・HdrImage を凍らせる・
トーンマップの既定 exposure と拡張 Reinhard・tonemapped が Ramp 等を受ける・色調の繋ぎ方（after）を決めた。

rev1 → rev2: レビュー 58 点。eff の口と CPU の Pass の宣言に形式が通っていない・CPU の HDR の画素の持ち方・α と負の値の書き込みの決まり・
RenderCache の鍵・トーンマップの白の点・事実の誤り（GLSL は 330 core・α は parity で比べない・名前の並び・Axis の重複）を直した。

## ねらい

3D の場面の白飛び（明るい床・松明のそば）と、細い物の縁のギザギザを消す。
今は Pass も最後の出力も 8bit（0..1）で、1 を超えた光はその場で切られる。ブルームのしきい値も 0..1 の目盛り。
「1 より明るい値を Pass に持ち、最後になめらかに 0..1 へ収める（トーンマッピング）」と「縁をならす後処理（FXAA）」を足す。

**合格線の柱: 今の 8bit の道（既定）は 1 bit も変えない**（make gl-parity の既存の全部の行・テンプレートの reference がバイト一致）。

## 決めたこと

### F0. 先に片づけるリファクタリング（絵は 1 bit も変わらない）

- R1. `HeadlessRender.PassSpec` と `Render.PassSpecRec` の `scale / basis` を `target = RenderTarget.Descriptor` 1 欄にまとめる（`HeadlessRender.targetOf` は消える）。次に欄を足す時も 1 か所。
- R2. eff の口を `beginTarget(spec: RenderTarget.TargetSpec)` に（`TargetSpec = { name, width, height, format, clear }`。欄が増えても op の形が変わらない）。
  直す所: `RenderTarget` の runNoop・`GlOffscreen`・`LwjglLayer` の handler・`Paint.beginTarget`・`App.renderPasses`・gl_parity の Main。
  gl_parity の Main（Main.flix:37-43）は App.renderPasses の写しなので、もう pub の `App.drawPassPlan` を repeats の回数だけ呼ぶ形にする（App に新しい pub は足さない）。
- R1・R2 は公開の型の欄を替えるので、移行メモ（0.73.0）に書き、`basis = ` を手で書いている TestRenderPasses・gl_parity の Main・HeadlessRender・Render を直す。
- R3. CPU の Clear の塗り（SoftRaster.flix:272-276・:588-593・HeadlessRender の Clear の分岐）を `fillClear` 1 本へ。

### F1. Pass の形式（`RenderTarget.Format`）と書き込みの決まり

- `pub enum Format with Eq, ToString { case Rgba8Unorm, case Rgba16Float }`（wgpu の TextureFormat の名前そのまま。段 G で `Rgba8UnormSrgb` を足せる並び）。
  `Descriptor = { scale, basis, format }`。既定は Rgba8Unorm（`defaultDescriptor` / `windowDescriptor` とも）。
  便利の口 `pub def withHdr(d: Descriptor): Descriptor = { format = Format.Rgba16Float | d }`。
  手でレコードを丸ごと書いているゲームは欄が足りず止まる → 移行メモ（0.73.0）。
- GL: `RenderTargetGl.create(w, h, format)`。Rgba16Float は `GL_RGBA16F` + `GL_HALF_FLOAT`（ゼロの ShortBuffer）。
  FBO が完成しない時は Rgba8Unorm で作り直し、名前ごとに 1 回だけ知らせる（今は println だけで描けない Pass が残る）。
  作り直しの鍵は (width, height, format)（beginTarget・prepareHistory。history は target と同じ形式）。
- Render3d の Design の中継 FBO（designTarget）の形式は、その時の描き先の形式に従う（鍵は (index, format)）。HDR の Pass の中で GPU と CPU が割れないように。
- **書き込みの決まり（GPU と CPU で同じ）**: 面の出力は rgb を [0, 65504]・α を [0, 1] に切る。
  GLSL の最後を `outColor = vec4(clamp(outColor.rgb, 0.0, 65504.0), clamp(outColor.a * uAlpha, 0.0, 1.0))` に（TestShader の期待の字も直す）。
  Rgba8Unorm の描き先は GL が書く前に 0..1 に切るので、8bit の絵は変わらない。
  float の描き先で src の α が 1 を超えると Normal の (1−α) が負になる — それを止めるため。この決まりが掛かるのは ShaderGen の面だけ（3D の frag は α が 1・sprite は下の読む側の clamp で足りる）。
- **α は読む所で 0..1 に切る**（GL の sprite のシェーダー `color.a = clamp(color.a, 0.0, 1.0)`・CPU の TexF の A・Rgba16f の Pass を sprite で貼る時）。
  Add は float の描き先で dst の α を溜める（a² + dA）が、溜まった値を混ぜ式に入れない。8bit の描き先では α はもともと 1 以下なので結果は変わらない。
  WhyNot: glBlendFuncSeparate で α の式を変えない — 8bit の ClearTransparent の Pass の α が変わり、それを貼った絵が変わる。
  α は parity で比べないので、engine_tools のテストで押さえる。
  `LoadOp.Clear(c)` の c は Rgba16Float の描き先では切らない（CPU も同じ）。
- ブレンドの式は今と同じ（Normal / Add / Multiply）。float の描き先では切らずに混ぜる。
  8bit の描き先へ Multiply する時は src が 1 に切られる（GL の決まり）ので、HDR の光マップで 1 を超えて明るくはできない（`Light.lightMapPass` の doc に 1 行）。

### F2. CPU の描き出し（SoftRaster）の Pass

- **持ち方**: `SoftRaster.PassImage = Argb8(BufferedImage) | Rgba16f(HdrImage)`（`HdrImage = { width, height, rgba = Vector[Float32] }`。HdrTexData と同じ型）。
  描いている間だけ領域の `Array[Float32]` を使い、描き終えたら Vector に凍らせて PassImage に入れる（領域の型が PassImage の全部の口に漏れないように）。Keep の前の中身は写してから描き足す。
  extraImages と passImagesOf の型を `Map[String, PassImage]` に替える（移行メモ 0.73.0）。
  WhyNot: float の BufferedImage（DataBufferFloat）にしない — Java2D の合成は描き先を int の ARGB に読み直すので、1 を超えた値が黙って消える。
- 書くたびに `Float.floatToFloat16 → float16ToFloat` で half に丸める（JDK 21）。GPU の途中の精度とは bit 単位ではそろわない → parity は近似（B）。
- `blendPixelF` の α は GL と同じ式: Normal は a·a + dA·(1−a)、Add は a·a + dA、Multiply は a·dA + dA·(1−a) = dA（glBlendFunc(DST_COLOR, ONE_MINUS_SRC_ALPHA) の 2 つの因子を α にも掛ける）。今の packOver（dst の α を残す）は写さない。
- **Rgba16f の描き先へ描く時**:
  - Drawable・字・箱・多角形は、Normal も含めて `blendedDraw` の形（8bit の下書きに描き → float の `blendPixelF` で混ぜる）。Graphics2D は HdrImage を触らない。
    Drawable は 1 つずつ下書きを通す。下書きは 0..1 なので、色が 1 を超える sprite は切られ、1 つの Drawable の中の重なりは 8bit に丸めてから混ぜる（近似。backend-parity.md に書く）。
  - 面は ShaderEval の値を切らずに、書き込みの決まり（F1）で切って `blendPixelF`。
  - 3D は SoftRaster3d の層を float 版で作り、同じく混ぜる。
- **読む時**:
  - 面の tex / blur（2D）は float のまま読む。`TexData` は今の形のまま残し、texEnv の値を `TexImage = Argb8(TexData) | Rgba16f(HdrTexData)` にして、compile の時点で `Node.Tex` / `Node.TexF` に分ける（画素ごとに分岐しない）。MipTex・Texture3d・ファイルの絵は 8bit のまま。
  - sprite・3D の材質・ビルボードが Rgba16f の Pass を読む時は、0..1 に切ってから読む（tint を掛ける前に切る分は GL と食い違う → backend-parity.md に「近似」）。
- `ShaderEval` の Shade.Rgb は切らない。切るのは書く所（`argbOfRgba` → `byteOf` / `blendPixelF`）。8bit の 2D の面の結果は bit 単位で同じ。
  3D の材質の評価（evalMaterial3）は albedo の clamp を残し、**emission は切らない**（負の値だけ 0 に切る）。
  emission は fog の後に正の値で足し、8bit の描き先は書く所で 0..1 に切るので、8bit の絵は bit 単位で同じ。Rgba16Float の描き先では 1 を超えた炎がそのまま残り、GPU（fogged + emission）と同じ。
- `RenderCache.imageDigest` は Rgba16f の時は half の bit を畳み、型の名前も digest に入れる（1 を超えた所だけ違う 2 枚を同じ物とみなさない）。
- `HeadlessRender` の `transparentLike`・`withPassImage`・`resampleNearest`・Keep の前の中身・Clear の塗り・history を PassImage の両方の case で通す。
- スクリーンショットと動画は最後が 8bit なので変えない。

### F3. テクセルの大きさを読む口（`Field.TexSize`）

- `Field.TexSize({ name = String, axis = Axis })`（Axis は既存の `ShaderDoc.Axis` の U / V）。答えはテクセルの数（Float）。
  - GPU: `float(textureSize(uTexN, 0).x)`（ShaderGen は全部 `#version 330 core` で、`textureSize` はもう 3D で使っている。uniform は足さない — 縮んだ Pass で registry の design の寸法を誤って入れる穴を作らない）。
  - CPU: texEnv の width / height（縮んだ Pass は GL と同じテクセルの数）。3D の材質の中では段 0 の寸法。
  - 名前の無い TexSize は 0（Div で割れば 0）。TexSize は texReads に入るので、3D の材質の絵の上限（maxMaterialTextures）でも 1 組として数える（doc に 1 行）。
- 読みとして数える: texNames / texReads（Nearest として数え、同じ名前の sampler があれば相乗り）/ renameTex / eqField / foldField / ShaderJson（`"texSize"`）/ resolvePassReads（history の別名・まだ描いていない Pass は黒の決まりに従う）。
- Studio の Shader エディタのフォーム 1 行（Studio のリポジトリの側。直すファイルは実装時に名前で書く）。

### F4. 後処理の部品（engine の新しいモジュール `PostProcess`）

Unity URP / Unreal の「Post Process」に合わせた名前。ShaderDoc の今の演算と bindings（Ref）で組み、新しい GLSL の節は作らない（CPU と GPU が同じ木を評価する）。

- `pub enum Tonemap with Eq, ToString { case AcesFitted, case Reinhard }`（AcesFitted = Narkowicz 2015 の近似 `x(2.51x+0.03)/(x(2.43x+0.59)+0.14)` を op(W) で割る。
  Reinhard は拡張 Reinhard `x(1 + x/W²)/(1 + x)`（W で 1 になり、折れ目ができない）。
- `pub def tonemapped(op: Tonemap, exposureStops: Float64, whitePoint: Float64, spec: ShaderDoc.Spec): ShaderDoc.Spec`
  — spec の Shade.Rgb の 3 本を bindings（`pp_r` / `pp_g` / `pp_b`）へ移し、2^stops を掛け、`op(x) / op(whitePoint)` を Sat で包んで出す。
  x の木は 1 回だけ評価される（Field → Field の関数にすると x を 4 回書き、GLSL も CPU の評価も 4 倍になる）。
  Solid・Rgb に加えて Ramp・Gradient・Cosine を受ける。係数の場は binding `pp_f` に移し、cycleRate を写してから 3 本にする。
  `pp_` の名前が spec の bindings と重なれば知らせる。
  `tonemappedWith(..., after: (Field, Field, Field) -> ShaderDoc.Shade, spec)`: トーンマップの後の値（binding `pp_tr / pp_tg / pp_tb` の Ref）を受けて、色調などを同じ面の中で掛ける。
  既定は exposureStops = 0.4・whitePoint = 4.0（`PostProcess.defaultExposure()` / `defaultWhitePoint()`）。
- `pub def luma709(r: Field, g: Field, b: Field): Field`（0.2126 / 0.7152 / 0.0722）。
- `pub def fxaaSpec(source: String): ShaderDoc.Spec` — FXAA 3.11 の PC の簡単な版
  （斜めの 4 点 NW/NE/SW/SE + 真ん中・REDUCE_MIN 1/128・REDUCE_MUL 1/8・SPAN_MAX 8）。
  隣の明るさは 1 点ずつ `Shift(of = luma709(Tex…))` の binding（Ref は Shift の中で読み直されない）。向きに沿った 4 点は Sampler Linear で読む。読みは約 27 回で、今のブルームと同じ桁。
  α は 1。読む Pass はトーンマップ済みの Rgba8Unorm・窓の画素（Window・scale 1）を前提とする（doc に書く）。
- HUD と UI はトーンマップしない（本編の面だけを包む）。

### F5. 色の空間（今回はやらない）

- 今はテクスチャもライトもガンマのままの値で足している（sRGB → 線形の変換が無い）。正しい線形の流れは全部のゲームとテンプレートの見た目を変えるので、段 G へ送る（テクスチャの sRGB 指定・mip の平均・最後のガンマを一度に決める）。
- **ガンマのままトーンマップする時の決まり**: AcesFitted(1.0)≈0.80・Reinhard(1.0)=0.5 で白が落ちる。whitePoint の正規化で決まるのは「W で 1 になる」ことだけで、
  今の白を戻すのは exposure の役目（既定 +0.4 stop）。正規化と exposure の既定で、8bit の 1.0 はおよそ 0.83〜0.9 になる（HUD は包まない）。
  チャンネルごとの圧縮で明るい色の色相が黄・白へずれるのは仕様とする。
  ガンマのまま足すので光が重なった所は明るすぎ、それを HDR が隠しきれない — 段 G で光の値を合わせ直す前提で、fps3d_lab の look.json に exposure と whitePoint を置き、数で合わせ直せるようにする。

## テスト・検証

- engine:
  - `Format` の既定・`withHdr`。
  - TexSize の JSON 往復・fold・renameTex・resolvePassReads（history・後ろの Pass）。
  - `PostProcess`: AcesFitted(0)=0・単調・whitePoint で 1 になる・拡張 Reinhard・既定で入力 1.0 → 0.83〜0.9・`tonemapped` が x の木を 1 回だけ持つ（bindings の数）・Ramp を包んでも係数の場が 1 回だけ・`pp_` の重なりを知らせる・`fxaaSpec` が組める・平らな絵では入力のまま。
  - TestShader の GLSL の最後の行の期待の字。
- engine_tools:
  - Rgba16f の Pass に Add で 1.5 を書き、0.5 倍して読むと 0.75（Rgba8Unorm なら 0.5）・half の丸め。
  - 書き込みの決まり（α 1.5 → 1・負の値 → 0・65504 を超える値 → 65504・Clear の 2.0 が残る）。
  - Normal の sprite・字・箱を Rgba16f の Pass へ（下書き → 混ぜる）。
  - RenderCache の鍵が、1 を超えた所だけ違う 2 枚の Rgba16f の絵を別の鍵にする。
  - emission 1.6 の 3D の材質を Rgba16f の Pass に描くと 1.6 が残る。同じ材質を 8bit に描くと今の絵とバイト一致。
  - Add を 3 回重ねた Rgba16f の Pass を Normal の sprite で貼った時、α が 1 として混ざる。
  - blendPixelF の α の式（Normal・Add・Multiply）。
  - Window 基準・float の Pass の縮め（resampleNearest）。
- gl_parity:
  - `hdrPass`: **A 段階**（RGB のバイト一致）。8bit の境目から離れた値で、LDR なら 10 段以上違う絵（切っていないことを機械で証明する）。
  - B 段階: `hdrWindowHalf`（Window 基準・scale 0.5 の Rgba16Float を Linear と TexBlur で読む）・`texSizeScaled`（縮んだ Pass の TexSize で 1 テクセルずつずらす）・`hdrMultiply`（dst が 1 を超える所へ Multiply）・`tonemap`・`fxaa`。
- 段 1 の合格線: make gl-parity の既存の全部の行と render-all がバイト一致。
- docs: backend-parity.md の表に 3 行（HDR の Pass・TexSize・tonemap / FXAA）と近似の 2 つ（1 を超える sprite・tint の順）。shader-doc.md と ShaderDoc.flix の Tex の「chan（0..1）」の doc を「8bit の Pass は 0..1・Rgba16Float は 1 を超える」に。

## ゲーム側（fps3d_lab）

- `scene`・`roomLow`・`bright`・`bloomA`・`bloomB`・`sceneBlur` を Rgba16Float に（history は無い）。
- `brightSpec` のしきい値を HDR の目盛りに。look.json 4 本の bloom* を合わせ直し、exposure・whitePoint を足す。
- 本編の面を `tonemappedWith(AcesFitted, …, after = 色調・かすみ)` で包む（色調は 0..1 前提なので、トーンマップの後で同じ面の中で掛ける）。
- FXAA: 本編の面を `post`（Rgba8Unorm・窓の画素）へ書き、`fxaaSpec("post")` の面を画面へ。
- 3D の松明のまわりの丸いにじみ（`flameGlows`）を外し、炎の emission を 1 を超える値にしてブルームでにじませる。
- 光の強さ（松明・窓・炎）を HDR の目盛りで合わせ直す。明るさの係数は 709 にそろえる（brightSpec が 709・lum が 601 で割れている）。

## 段取り

0. F0（R1・R2・R3。形式は足さない）→ 全部の絵がバイト一致
1. F1（GL の形式・書き込みの決まり）→ gl-parity の `hdrPass` は CPU の F2a が入るまで GL 側だけ確かめる
2. F2a（CPU の PassImage・面・3D・Clear・RenderCache）→ engine_tools のテスト・`hdrPass`（A）
3. F2b（Graphics2D の物を Rgba16f の描き先へ）
4. F3（TexSize）
5. F4（PostProcess）→ parity の残り
6. fps3d_lab に入れて前後を比べる（CPU の静止画と GPU の動画）
7. 文書（移行メモ・AGENTS.core の早見表・agent-eval のお題・api-digest）。段 E の分と一緒に
