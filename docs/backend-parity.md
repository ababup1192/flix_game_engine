# 描画部の対応表（実機と生成した絵を食い違わせない）

絵を描く経路は 2 つある。**どちらも同じ指定（`GameEngine.Drawable` / `PolygonRenderCmd`）を
受け取り、同じ絵になっているべき**。

| 経路 | 誰が使うか |
|---|---|
| **GL**（`render_gl`） | 実機。`make run` で見える絵 |
| **SoftRaster**（`engine_tools`） | 生成・スナップショット・F8 注釈・エディタのプレビュー |

## なぜ表が要るか

この開発の流儀は 3 つとも「SoftRaster が実機と同じ絵を写している」前提に乗っている:

- 絵の開発ループ（生成して目視して直す）
- リグレッション防護（gallery とスナップショットのバイト比較）
- 「挙動を変えていない」の機械証明（生成前後のバイト一致）

SoftRaster が指定を黙って落とすと、**スナップショットは「実機と違う絵」を正しいものとして固定する**。
しかも穴は開きっぱなしになりやすい — 新しい属性を GL にだけ足しても実機では見えるので、
誰も困らないまま SoftRaster が置き去りになる（実際、傾き `rotation` はずっとそうなっていた）。

## 対応表

| 指定 | GL | SoftRaster | 備考 |
|---|:--:|:--:|---|
| position / scale / centered | ○ | ○ | |
| rotation（傾き） | ○ | ○ | 軸は四角の中心。式は両者で同一（`pos + size/2` まわり） |
| color（tint）/ alpha | ○ | ○ | |
| uvOffset / uvScale（部分矩形） | ○ | ○ | |
| 反転（scale の符号） | ○ | ○ | |
| zIndex の並び | ○ | ○ | (z, 追加順) の安定ソートで両者一致 |
| clip（切り抜き矩形） | ○ | ○ | 量子化は `DrawCmd.clipPixels` を共有 |
| blend（Add / Multiply） | ○ | ○ | 式は `SoftRaster.blendPixel` にテストで固定 |
| style（角丸・枠・縞・市松）on 単色 box | ○ | ○ | 枠の濃さ（borderAlpha）も両者対応 |
| 単色多角形の塗り | ○ | ○ | **縁だけ近似**: SoftRaster は Java2D の AA、GL は AA なし |
| 頂点色つき多角形（grad のグラデ） | ○ | ○ | 補間は同じ線形の式（扇割りは `DrawCmd.gradTriangles` を共有、式は `SoftRaster.gradSample` にテストで固定）。縁は両者とも画素中心判定で AA なし — 単色多角形とは縁の写りが違う |
| 多角形マスク付きスプライト（mask の型抜き） | ○ | ○ | **縁だけ近似**（単色多角形と同じ注記）: GL はステンシル・SoftRaster は Java2D の clip で、どちらも AA なしの硬い縁。mask はクアッドのローカル座標なので rotation・反転が両経路とも同じ式で追随する。グリフ（font_）は対象外。GL では mask 付き 1 体ごとに run の一括 draw から単発 draw に落ちる。レンダーターゲット（Pass）の中でも抜ける（ターゲットの FBO にもテクセル寸法のステンシルがある。gl_parity の passMask） |
| **style on テクスチャ / 文字** | ○ | **×** | 落とす。生成するときに件数を報告する |
| 文字の描き方 | SDF シェーダ | 出力解像度の TTF を直接 drawString | **近似**。小サイズでは生成した方がくっきり出る |
| 宣言シェーダーの面 | 本物の GLSL | `ShaderEval` の画素評価 | **近似**。式は揃えてあるが完全一致は保証しない |
| シェーダー面の tex 場（`Field.Tex`） | sampler uniform + sampler object | `texEnv`（画素表）を `ShaderEval` が標本 | 標本の量子化は**同一を保証する**: NEAREST（`floor` の釘打ち式）・CLAMP（端に張り付き）・8bit/255 の正規化・pass の上下逆の吸収位置（GL の uTexFlip だけが持つ）。テクスチャ値**以降**の float 合成は宣言シェーダー面と同じく近似。pass の alpha チャンネル（`chan:"a"`）は GL のブレンド副産物なので一致保証なし |
| レンダーターゲット（Pass） | ○ | ○ | sprite で貼るときの標本は最近傍（NEAREST）を**保証する** — 縮小→再拡大のピクセライズ/モザイクはこれに依存してよい。中の Shader 面も両経路で描く（gl_parity の passChain）。読みの決まり（まだ描いていない pass は黒・自分の名前は history）は `Render.resolvePassReads` 1 か所で書き換え、両経路が同じ結果を使う（passLaterRead）。**history（前のコマ）は突き合わせない** — 描き出しと GL の 1 枚撮り・動画は透明、窓だけが前のコマを写す |
| 縮んだ pass（`RenderTarget.Descriptor` の scale） | viewport でテクセル寸法へ縮める（投影は design のまま） | design 解像度で描き、GL がテクセルを塗る点で 1 画素拾う（面はその点で評価） | テクセルの格子にそろった座標（scale 0.5 なら偶数）の絵は**同一を保証する**（passHalf）。奇数座標の箱の縁も合わせてある（縦は「境目なら上」— GL のターゲットが上下逆格納のため）。面の中の式（市松の升目など）が標本点にちょうど乗る所は近似。割り切れない倍率（0.33 など）は B 段階（この Mac では 0 px） |
| tex 場の Linear（`sampler` 節） | sampler object の GL_LINEAR | `ShaderEval.sampleTexLinear`（同じ点・同じ重み） | **近似**: GPU は補間の重みを固定小数に丸めるので ±1/255 程度ずれうる（B 段階 linearRead。この Mac の実測は 0 px） |
| 面に渡す数（`param`） | uniform `uParamN`（float32） | `ShaderDoc.bindParams` で `const` に置き換えて評価（float64） | `const` と同じ扱い（gl_parity の paramRead は 8bit で半分に乗らない値で A 段階 0 px） |
| HDR の Pass（`RenderTarget.withHdr` → Rgba16Float） | `GL_RGBA16F` の FBO | `SoftRaster.PassImage.Rgba16Float`（書くたびに half に丸める） | 書き込みの決まり（面の rgb は [0, 65504]・α は [0, 1]）は両経路で同じ（hdrPass は A 段階 0 px）。読む側の補間とぼかしは half と float32 / float64 の丸めで ±1 が出る（B 段階 hdrWindowHalf）。**近似 2 つ**: (1) sprite・字・箱・多角形は 8bit の下書きに描いてから float で混ぜるので、1 を超える色の sprite は下書きで 1 に切られ、1 つの Drawable の中の重なりは 8bit に丸めてから混ぜる。(2) sprite・ビルボードが Rgba16Float の Pass を読む時、描き出しは 0..1 に切ってから tint を掛ける（GL は tint を掛けた後に書き込みで切る）ので、tint が 1 より小さい所で 1 を超えた値の写りが違う。3D の材質の tex 場が Rgba16Float の Pass を読む時は、GPU（`ShaderGen.compile3d`）は切らずに読んで光を掛け、書き込みで切る。描き出しは 0..1 に切ってから読むので、1 を超えた値を読む材質は、光で暗くなる所ほど明るさが違う |
| テクセルの数（`Field.TexSize`） | `float(textureSize(uTexN, 0))` | texEnv の絵の width / height | **同一を保証する**（整数の数。texSizeScaled は縮んだ Pass を 1 テクセルずつずらして読む B 段階で 0 px）。無い名前は描き出しが 0・実機は何も貼らない unit の寸法（ドライバ次第で、gl_parity では確かめていない） |
| トーンマップ・FXAA（`PostProcess`） | ShaderGen の GLSL（float32） | ShaderEval（float64） | 宣言シェーダーの面と同じ**近似**。曲線の式の丸めが 8bit の境目に落ちた平らな面が ±1（B 段階 tonemap）・FXAA は明るさの比べの境目と Linear の重みの丸めで斜めの縁の画素だけが割れる（B 段階 fxaa） |
| MSAA（`RenderTarget.withMsaa`） | 標本を持つ renderbuffer の FBO に描き、Pass を読む前に resolve。cutout の材質は alpha to coverage | **しない**（CPU の絵は MSAA の無い絵のまま） | **GL だけ**。差は物の縁の画素だけに出る（B 段階 msaaEdges は差の数に上限と下限を置き、下限で MSAA が効いていることを見る）。描き出しの鍵は samples を入れない（CPU の絵は samples によらず同じ） |
| 3D の空・半透明・両面（`Scene3dCmd#sky`・`withAlphaBlend`・`withDoubleSided`） | 空は画面いっぱいの四角・半透明は深度を書かない glBlendFuncSeparate・両面は GL_CULL_FACE を切る | 空は画素ごとの skyFill・半透明は 2 段目で遠い順に重ねる・両面は裏の三角形を捨てない | 3D の場面と同じ**近似**（B 段階 skyGradient3d・glassPane3d・doubleSided3d）。半透明の物の 2 枚が分け合う縁の画素は、CPU は左と上の縁を持つ方だけが塗る（GL のラスタライズの決まりと同じ考え） |
| 透明から始める Pass（`LoadOp.ClearTransparent`）の中の 3D の場面 | 場面の画素の α をそのまま Pass に書く | **出ない**（層を `SoftRaster.blendPixel` で重ねると Pass の α が 0 のまま残り、貼っても見えない） | **既知の穴**（3D の場面全部。半透明に限らない）。Pass の中に 3D を描くなら `Clear(色)` で始めるか、場面の background を Some にする。GL の側も、何も無い所に重ねた半透明は α を掛けた色が Pass に入り、貼る時にもう一度 α を掛ける |
| 倒した影（`Shadow.projectedRuns`） | gradPolygon（Multiply） | 同じ | 斜めの縁と頂点ごとの濃さは多角形の近似のまま（B 段階 castShadow） |
| `pow` の負の指数・`div` | float32 | float64 | 近似: 答えの上切り 1e6 の手前の大きな値・`div` の割る数が 0 に近い所（0 になるかが float32 と float64 で割れうる）は差が出うる |
| 組み込み放射テクスチャのスプライト（`Render.lightAt` / `darkAt`） | ○ | ○ | **一致**（radial scene が機械証明）。土台は `RadialBuiltin` の画素定義 — 減衰カーブは rgb だけに書き込み **alpha は常に 255**。alpha=255 なら Add は `d+s` の整数の足し算で GL（float 合成）と CPU（整数合成）の丸めが消える。Multiply（`darkAt`）は `d×s/255` が割り切れる下地（白・黒）でのみバイト一致 — 中間色の下地では ±1 の丸め差が出うる（GL は最近接丸め・CPU は切り捨て）。tint・strength の中間値も float 乗算が入るため一致保証は白 tint・strength=1.0 の範囲。もう 1 つの条件は四角の左上が画面内にあること — SoftRaster の出力矩形の丸め（`SoftRaster.ri` = 0 方向切り捨て）が**負座標で 1px 内側にずれ**、等倍の貼りが 1px 縮む（放射に限らず全スプライト共通の既知の穴。画面の左上からはみ出す置き方だけで踏む） |

## エンジンを拡張するときの手順

描画の指定を増やしたら（`Drawable` に属性を足す・新しい `Render.Item` を作る等）:

1. **GL と SoftRaster の両方に実装する**。片方だけなら次へ。
2. SoftRaster に実装しないなら、**`SoftRaster.dropped` に 1 行足して報告させる**。
   黙って落とすのは禁止 — 生成した絵が嘘をつく。
3. **この表を更新する**。
4. 軸や式が両者で揃っているかを、数値のテストか生成した絵の見比べで確かめる。
5. **塗った PNG のキャッシュの鍵（`DrawHash`）に入れる**。`Drawable` の引数や `RasterReq`・`SurfaceCmd` の欄を
   足すと `DrawHash.flix` がコンパイルで止まるので、そこで畳む。SoftRaster の入口に引数を足すなら
   `DrawHash.Frame` に入れて `RenderCache.writePng` から渡す（鍵と塗りを 1 か所の同じ値から作る）。
   入れ忘れると「絵が変わったのに同じ」と言う偽の緑になる（[render-cache.md](render-cache.md)）。

`SoftRaster.dropped` の報告は `HeadlessRender` が描き出すたびに出す:

```
[render] 描き出せない指定: style on textured sprite ×3 — 角丸・枠・縞・市松は単色の box にだけ描ける（title）
```

## 機械での突き合わせ（bench/gl_parity）

上の表の「同一を保証」の行は、`make gl-parity` が機械で確かめる。隠しウィンドウ
（`FLIX_GE_HIDDEN=1`）で GL を 1 コマずつ生成し、同じ scene 宣言を SoftRaster でも生成して
画素比較する（スナップショットは作らない — 基準は「もう片方の経路」）。回し方と scene の規約は
[bench/gl_parity/README.md](../bench/gl_parity/README.md)。

- 比較は 2 段階。**A 段階（同一保証の行だけを使った scene）は RGB バイト一致**が合格線で、
  1 画素でも違えば exit 1。近似の行（縁 AA・文字・float 合成）は数字の報告だけで落とさない。
- **alpha チャンネルは比較しない**（pass の alpha は GL のブレンド副産物 — 表の tex 場の行）。
- 実測記録（2026-08-11・第 1 陣 4 scene）: 単色 box + zIndex + Add/Multiply + 軸平行縞 +
  市松（boxes）、UV 部分矩形 + 反転 + 整数倍率の NEAREST（spriteNearest）、Pass の NEAREST
  整数倍拡大（passPaste）、tex 場の素通し読み（texField）— **全て差 0 px のバイト一致**。
  ±1 の引き直しが要る行は出ていない。
- 実測記録（2026-08-11・Wave F）: 光マップの配管（`Light.lightMapPass` の環境光 box +
  pass 内 Add + `lightMapOverlay` の Multiply 貼り。lightmap）— **差 0 px のバイト一致**。
- 実測記録（2026-08-11・放射）: 組み込み放射スプライト（`Render.lightAt` の Add 重ね置き +
  `darkAt` の白/黒下地 Multiply。radial）— **差 0 px のバイト一致**。かつては最大 ±8 の
  差があったが、放射テクスチャを alpha=255 形（カーブは rgb に書き込み）へ改めて解消した。
- 実測記録（2026-10-20・半透明の幕）: 画面いっぱいの幕（`Render.fade(0.5)`）を色の箱と sprite の上に重ねる形
  （確認の窓の後ろを薄める形。veil）— **差 0 px のバイト一致**。α は 0.5・色は偶数の k/255 に限る（重ねた答えが
  8bit で割り切れる組）。Match3 の動画で GPU と SoftRaster が違って見えた件は重ね方ではなく、面を書き出して貼る道
  （`VideoOut` の bakeSurfaces）が貼り絵を真ん中で置いていたずれだった（左上で置くよう直した）。
- A 段階の scene に入れてよい絵の条件（整数座標・k/255 の色・軸平行縞のみ等）と
  「±1 が実測されたらこの表へ実測根拠つきで追記して線を引き直す」の手順は
  bench/gl_parity/src/Scenes.flix の冒頭に固定してある。
- 描画経路（render_gl / SoftRaster / Frame / ShaderEval）を触ったら手で回す。
  CI には載せない（オフスクリーン GL を CI に用意しない判断はそのまま）。
