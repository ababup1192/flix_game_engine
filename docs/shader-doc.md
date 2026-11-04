# shader.json（ShaderDoc）の書き方

面（矩形）を「画素ごとの計算」で塗るための宣言。単色の box をやめて、動く霧・水面・
vignette・熱い溶岩を **JSON の保存だけで即調整できる**形で置ける。

- 実体: `engine/src/shader/ShaderDoc.flix`（型）・`ShaderJson.flix`（読み書き）・
  `ShaderEval.flix`（CPU 評価 = 生成）・`ShaderGen.flix`（GLSL 生成 = 実機）
- **使える語彙は engine のバージョンで決まる**。知らない `kind` が 1 つでもあると Doc 全体が
  読めず、丸ごと既定値へ落ちる（絵が別物になるだけでエラーは出ないので気付きにくい）。
  下の表で **[新]** を付けた物は **0.13.0 から**（0.12.1 以前には無い）、
  **[新19]** を付けた物（tex 場: `tex` / `shift` / 色の `rgb`）は **0.19.0 から**。
  自分のゲームが引いているバージョンは `flix.toml` の `github:ababup1192/flix_game_engine` を見る。
- 呼び方: `Render.shaderFill(spec, rect, t, z)` / `Render.shaderFillMasked(spec, rect, polys, t, z)`
- 面全体の濃さは `Render.overItem(Render.fade(k), 面)`（0..1・場の alpha に掛かる）。Spec の場に `Const` で書き込んで毎コマ変えない — Spec が変わるたびに GL のシェーダーを作り直す
- 読み方: `ShaderJson.load(path)` は **fail-open**。`Result.getWithDefault(既定の Spec)` で受ける
- 保存即反映: Spec を Res の欄に置き、`Controls.docTable` に `Resources.reloadRow(id, path, …)` の行を足す（`templates/tidepool-starter/src/Controls.flix` が手本）

## 全体の形

```json
{
  "version": 1,
  "note": "この面は何で、どこをいじると何が変わるか（調整ノブの一覧）",
  "name": "水面",
  "cycleRate": 0.25,
  "shared": [ ["名前", { …場… }] ],
  "out": { "kind": "fill", "shade": { …色… }, "alpha": { …場… } }
}
```

- `cycleRate` … 0 より大きいと、色の位相が時間で回る（ゆっくり色が巡る）
- `shared` … 同じ場を 2 度書かないための束ね。`{"kind":"use","name":"…"}` で引く。
  **前方参照のみ**（自分より前に定義した名前だけ）。循環・未定義は読み込みエラー
- 知らないキーは読み飛ばされる。`note` は必ず書く（調整ノブの説明を人に残す）
- `version` は必ず書く（Doc 共通の外形規約。無いと Studio の健康診断が警告を出す —
  docs/doc-conventions.md）
- Studio でフォーム編集させるなら `shader.schema.json` は **sections 方言**で書く
  （doc-conventions.md「スキーマの書き方」。ここの語彙表をそのまま schema に
  書いても Studio は読めない — 語彙の参照先はこのファイルでよい）

## 場（Field）— 0〜1 の値を画素ごとに作る

`{"kind": "…", …}`。`of` / `a` / `b` を持つものは、その中にまた場を入れ子にできる。

**素材**

| kind | 主なキー | 何が出るか |
|---|---|---|
| `const` | `value` | 定数 |
| `uv` | `axis`("u"/"v") | 横 / 縦の位置（0〜1） |
| `fbm` | `octaves`, `scale`, `seed` | 雲・霧のムラ |
| `fbmTile` **[新]** | `octaves`, `scale`, `period{x,y}`, `seed` | **周期つき** fbm。スクロールしても継ぎ目が出ない |
| `worley` | `scale`, `seed`, `out`("f1"/"f2"/"f2mf1") | セル模様。`f2mf1` が網目（水のコースティクス） |
| `hash1` / `hash2` | `scale`, `seed`, (`comp`), (`bucket`) | 升目ごとの乱数（`hash2` は成分指定） |
| `tex` **[新19]** | `name`, (`chan`="r"/"g"/"b"/"a"、既定 "r") | 名前つきテクスチャ（pass の生成した絵や普通のテクスチャ）を今の uv で標本した 1 チャンネル |
| `texSize` **[新]** | `name`, `axis`("u"/"v") | 名前つきテクスチャの幅（`u`）・高さ（`v`）のテクセルの数。1 テクセルずつずらすなら `{"kind":"math2","op":"div","a":{"kind":"const","value":1},"b":{"kind":"texSize",…}}` を `shift` の `dx` / `dy` に。縮んだ pass は縮んだ後の数・3D の材質の中では段 0 の数・無い名前は 0（割れば 0） |
| `blur` **[新]** | `name`, (`chan`), `radius{x,y}`, `taps`(既定 24), `amount`（場） | テクスチャをぼかして標本した 1 チャンネル。今の uv のまわり `radius × amount` の円に `taps` 個の点を黄金角で撒いて平均する（GLSL と CPU で同じ点）。実写の背景をピンぼけにする・切り替えの頭でピントを外す（実例: `templates/sound-novel-starter/src/Backdrop.flix`） |

**形**

| kind | 主なキー | 何が出るか |
|---|---|---|
| `disk` | `cx`, `cy`, `radius`, `feather` | 縁がぼけた丸（池・光だまりの型抜き） |
| `radial` | `cx`, `cy` | 中心からの距離。**uv 空間なので横長の面では楕円に歪む** |
| `radialAspect` **[新]** | `cx`, `cy`, `aspect` | 縦横比を渡せる距離。**vignette はこちらを使う** |
| `scales` | `scale`, `stagger` | 鱗・瓦の並び |

**きらめき**

| kind | 主なキー | 何が出るか |
|---|---|---|
| `glints` | `scale`, `rate`, `density`, `seed` | 横に伸びた光の筋 |
| `sparkle` | `scale`, `rate`, `density`, `seed` | 菱形のちかちか |
| `ripples` | `freq`, `amp`, `speed`, `seed` | 横縞のうねり |

**座標をいじる**（中の `of` を、ずらした座標で読む）

| kind | 主なキー | 何をするか |
|---|---|---|
| `scaled` | `factor`, `scroll{x,y}`, `of` | 拡大 + 流す（`scroll` が流れの速さ） |
| `warp` | `amount`, `scale`, `seed`, `of` | ぐにゃりと歪ませる |
| `tile` | `tiles{x,y}`, `of` | 敷き詰める |
| `snap` **[新]** | `cells{x,y}`, `of` | 升目に量子化（ドット絵風） |
| `shift` **[新19]** | `dx`, `dy`, `of` | 場の分だけ座標をずらして読む（`dx`/`dy` は**外側の uv** で評価） |
| `swirl` | `cx`, `cy`, `strength`, `rate`, `of` | 中心ほど速く回す（渦） |
| `rotate` | `cx`, `cy`, `turns`, `rate`, `of` | まるごと回す（1 周 = 1.0） |
| `angle` | `cx`, `cy` | 中心から見た角度（放射の縞・花びら・螺旋） |

**加工**

| kind | 主なキー | 何をするか |
|---|---|---|
| `smoothstep` | `lo`, `hi`, `of` | しきい値でくっきりさせる（境の太さ = `hi`） |
| `quantize` **[新]** | `of`, `steps` | 段階の数を減らす（ポスタリゼーション） |
| `pow` | `of`, `p` | 明暗のカーブ。`p` が負なら逆数（底は 1e-6 で下切り・答えは 1e6 で上切り） |
| `math1` | `op`, `of` | `neg`/`abs`/`fract`/`floor`/`sin`/`cos`/`sat`/`oneMinus`/`sqrt`（負の数は 0 として扱う） |
| `math2` | `op`, `a`, `b` | `add`/`sub`/`mul`/`min`/`max`/`step`/`div`（`div` は `b` が 0 なら 0） |
| `sampler` **[新]** | `filter`(`"nearest"`/`"linear"`), `of` | `of` の中の `tex` / `blur` を、その補間で読む（入れ子は内側が勝つ・`use` の中までは届かない） |
| `param` **[新]** | `name`（英数字と `_`） | 面を置く時に渡す数（`Render.withShaderParams(Map#{"focus" => v}, 面)`）。毎フレーム変わる数（ピントの位置・体力の割合）はここで渡す — `const` に入れると実機は GLSL を作り直す。渡さなかった名前は 0（実機は `[render] 面 …: param '…'` を 1 回知らせる。描き出しは `Render.missingShaderParams` で同じ物を引ける） |
| `world` **[新]** | `axis`(`"x"`/`"y"`/`"z"`) | 3D のメッシュに塗る時の、画素の world の点の成分（左手系。X = 東・Y = 上・Z = 北）。`scaled`・`tiling`・`shift` などの uv の変換を受けない（いつも画素の world の値）。2D の面では 0（実機は `[render] 面 …: world / normal は…` を 1 回知らせる） |
| `normal` **[新]** | `axis`(`"x"`/`"y"`/`"z"`) | 3D のメッシュに塗る時の、外向きの単位の法線の成分（-1〜1）。uv の変換を受けない。2D の面では 0 |
| `vertexColor` **[新]** | `chan`(`"r"`/`"g"`/`"b"`/`"a"`) | 3D のメッシュに塗る時の、画素の頂点の色の成分（0〜1。`a` は 1）。置いた物の tint は入らない（tint は材質の色の後で掛かる）。uv の変換を受けない。2D の面では 1 |
| `mix` | `a`, `b`, `t` | 一定の割合で混ぜる |
| `blend` | `a`, `b`, `by` | 場で混ぜ具合を決めて混ぜる |
| `time` | `scale`, `offset` | 時刻そのもの（明滅・呼吸に） |
| `use` | `name` | `shared` に置いた場を引く |

## 色（Shade）— 場を色に変える

色は `"#rrggbb"` か `{"r":…, "g":…, "b":…}`（0〜1）。

| kind | キー | 使いどころ |
|---|---|---|
| `solid` | `color` | ベタ |
| `ramp` | `lo`, `hi`, `field` | 2 色の間を場で補間 |
| `gradient` | `stops`(`[[位置, 色], …]`), `field` | 多段のグラデ（空・水の深さ） |
| `cosine` | `a`, `b`, `c`, `d`, `field` | `a + b·cos(2π(c·場 + d))`。**`d` をずらすだけで別配色**になるので、ステージごとの色替えに向く |
| `rgb` **[新19]** | `r`, `g`, `b`（各: 場） | 3 つの場をそのまま rgb に（`tex`×3 でテクスチャの色を素通しするのが主用途）。**`cycleRate` は掛からない** |

`out` は `{"kind":"fill", "shade": …, "alpha": …}`。`alpha` も場なので、形（`disk` など）を
入れれば好きな輪郭に抜ける。

## すぐ使えるレシピ

### 1. ゆっくり動く暗い背景（単色 box の置き換え）

```json
{
  "note": "背景の霧。濃さ=smoothstep の lo/hi、流れ=scroll、粗さ=scale。",
  "name": "bg_mist",
  "cycleRate": 0.0,
  "out": {
    "kind": "fill",
    "shade": {
      "kind": "gradient",
      "stops": [[0.0, "#0b1020"], [0.6, "#151d33"], [1.0, "#26314f"]],
      "field": {
        "kind": "scaled", "factor": 1.0, "scroll": { "x": 0.01, "y": 0.006 },
        "of": { "kind": "fbm", "octaves": 3, "scale": 3.0, "seed": 5 }
      }
    },
    "alpha": { "kind": "const", "value": 1.0 }
  }
}
```

上下の位置で色を変えたいときは、`field` を `uv`(v) と `fbm` の重み付き足し算にする
（`math2` の `mul` で係数を掛けて `add`）。`templates/game-starter/assets/*.shader.json` が
その形。engine が新しければ `fbm` を `fbmTile` **[新]** に替え、`period` を整数にすると
スクロールしても継ぎ目が出ない。

### 2. 水面のコースティクス（網目）

`worley` の `out` を `"f2mf1"` にして `smoothstep` で細く締め、`ramp` で 2 色。
完成形は `templates/tidepool-starter/assets/caustics.shader.json`（水底の光の網を `shared` で
網とうねりに分けて組む実践形）。

### 3. vignette（画面の四隅を落とす）— `radialAspect` **[新]** が要る

画面いっぱいの矩形に敷き、`Render.blended(Multiply, …)` で重ねる。

```json
{
  "note": "四隅を落とす覆い。効きの強さ=stops の位置と暗い側の色、丸さ=aspect（画面の 横÷縦）。",
  "name": "vignette",
  "cycleRate": 0.0,
  "out": {
    "kind": "fill",
    "shade": {
      "kind": "gradient",
      "stops": [[0.0, "#ffffff"], [0.55, "#ffffff"], [1.0, "#404860"]],
      "field": { "kind": "radialAspect", "cx": 0.5, "cy": 0.5, "aspect": 1.6 }
    },
    "alpha": { "kind": "const", "value": 1.0 }
  }
}
```

`aspect` に面の 横÷縦 を渡すこと。`radial` のままだと横長の画面で楕円に歪む。

## tex 場 — テクスチャを場として読む **[新19]**

`{"kind":"tex","name":"…"}` で、名前つきテクスチャの画素を場として読める。名前は
**pass（レンダーターゲット）の名前**か、登録済みの普通のテクスチャ名。pass と組むと
「前段で生成した絵を歪めて読む」（ぼかし・陽炎・衝撃波・色調変換）が JSON だけで書ける。
- 標本は既定で**補間なし（NEAREST）・端は張り付き（CLAMP）**。`{"kind":"sampler","filter":"linear","of":…}` で包むと
  隣のテクセルとなめらかにつなぐ（GL の `GL_LINEAR` と同じ点と重み。読む側で選ぶので、同じ pass をくっきり読む所と
  なめらかに読む所を 1 枚の面に並べられる）。`shift` で端を越えても
  反対側へ回り込まない（実機は sampler object で通常テクスチャの REPEAT も封じる）
- 値は、8bit の絵（ファイル・Rgba8Unorm の Pass）なら 255 で割った 0〜1。Rgba16Float の Pass（`RenderTarget.withHdr`）は切らずに読むので 1 を超えることがある（α だけ 0〜1 に切る）。pass の上下逆格納は実機側が自動で吸収する（JSON は何もしない）
- **無い名前は黒（0.0）**になり、標準エラーに一度だけ知らせる。特に「pass を宣言しない
  フレームで名前だけ読む」と恒常的に黒のままなので、面を出すフレームでは pass も必ず宣言する
- `chan:"a"` を pass に使うのは**近似**。GL ターゲットの alpha チャンネルはブレンドの
  副産物で、生成（CPU）との一致は保証しない（rgb は一致の対象）

### `use`（shared）の意味 — 基準 uv で 1 回だけ

`use` は**座標変換（`scaled`/`warp`/`shift` など）の内側に書いても、面の基準 uv で
1 回評価した値**が返る（変換後の座標では読み直さない。GLSL が main 先頭で 1 回計算する
挙動が正で、CPU 評価もこれに揃えてある）。

- 帰結: **ぼかしのタップは `shared` で括れない**（`shift{of: use(...)}` は全タップ同値になる）。
  タップごとに `tex` をインライン展開すること
- 性能注記: shared は out から参照されなくても**画素ごとに必ず評価される**（unused な
  shared は合法だが黙って生成が重くなる。使わない束ねは消す）

### 3D の材質と `atWorld` — `use` の定義の側に書く **[新]**

3D のメッシュ（`Scene3d.withMaterial`）に塗る時、uv は (0, 0) で、uv を読む場（`fbm`・`worley`・`hash` …）は
どこでも同じ値になる。world の上で読ませるには `ShaderDoc.atWorld((Axis3.X, Axis3.Z), 場)` で包む
（world の 2 軸を uv として読ませる `shift`。床なら X と Z、東西を向く壁なら Z と Y）。
`use` は面の基準 uv で 1 回だけ評価するので、`atWorld(p, ref("rock"))` と外から包んでも world を読まない —
**`atWorld` は `shared` の定義の側に書く**（`("rock", atWorld(p, fbm))` と置いてから `use("rock")` で引く）。
材質は「光を当てる前の色」（out の色と α）と、任意で「自分で光る色」（`Scene3d.withEmission`。光の計算の後に足す）を返す。
材質は `Scene3d.material(spec) |> Scene3d.withParams(…) |> Scene3d.withCutout(true)` の形で作る（閉じた型。中身は `materialFieldsOf`）。

### 3D の材質で絵を読む（`tex` / `blur` / `uv`）**[新]**

- uv は頂点の uv（`Mesh3d.withUvs`・`fromTexturedPolygons`・`withBoxUvs`）。(0, 0) が絵の左上で、v は絵の下へ増える。
  uv の無い形では (0, 0)。uv とタンジェントは**読み込みの時に 1 回**付ける（毎コマ View で付けると、そのたびに中身の鍵の SHA を取り直す）。
- 絵の名前は `tex3d:` で始まれば場面の `textures`（`Texture3d.name`）、ほかは全体の登録（project.json の textures・レンダーターゲット）から引く。
  どちらにも無ければ 0（黒・透明）で、名前ごとに 1 回知らせる。
- 0〜1 の外の uv は材質の `Scene3d.withWrap`（既定は `Repeat`。`Clamp` は端の色を伸ばす）。2D の面の `tex` はいつも端の色を伸ばす。
- 1 つの材質が読める (名前, 補間) の組は `Scene3d.maxMaterialTextures()`（6）まで。7 組目からは 0 で描き、材質ごとに 1 回知らせる。
- 絵 1 枚 × 頂点の色なら `Scene3d.texturedMaterial(名前, FilterMode.Nearest)`。頂点の色が灰色の形（Kd の無い OBJ の材質は 0.6）に貼ると、その分だけ暗くなる。
- Spec の色（絵・頂点の色）は画面の値（sRGB の値）で書く。描き手が Spec の出口で線形の量へ戻してから光を掛ける（`docs/scene3d.md` の「3D の色」）。
- 3D の材質の `tex` と法線マップは段（mipmap）つきで読む。段は `Mip.build`（2 × 2 の平均。色の絵は線形の量で平均し、法線マップは値のまま）で作り、読む段は読む座標の画面の微分から
  `Mip.lodOf` の式で選ぶ（GL と描き出しで同じ）。`blur` と cutout の α は段 0 で読む。レンダーターゲットの名前は段を作らずに読む。
- 法線マップは `Scene3d.withNormalMap({ texture = 名前, strength = 1.0 })`（タンジェント空間・OpenGL 流＝緑が絵の上・赤が絵の右。
  Blender と glTF と同じ）。uv つきの形にだけ当たり、uv の無い形では形ごとに 1 回知らせて無視する。材質の wrap が掛かり、Linear で読む。
  光の計算は傾けた法線で行い、Spec の `normal` は当てる前の法線を読む。

### ぼかしのコスト（正直な試算）

- **同じ名前・同じ補間・同じ座標・同じ半径と taps の `tex` / `blur` は、チャンネルが違っても 1 回だけ読む**（GLSL で
  共通部分式として括り出す）。r・g・b の 3 本に書いても読む数は 1 本分。
- `blur` は `radius × amount` が 0 の画素では 1 点だけ読む（ティルトシフトのピントの帯が安くなる）。
- 大きくぼかすなら、本編の全面で読まず、**縮んだ pass**（下の「pass の連鎖」）で 1 回ぼかしてから Linear で読む。
  480×270 の全面は 129,600 画素、半分の pass は 32,400 画素、1/4 は 8,160 画素。

### pass の連鎖（pass の中の面・縮んだ pass）**[新]**

- pass の items の中の面も描かれる（本編と同じ z の決まり）。面は**前に宣言した pass**の今のコマの中身を読める。
- **自分の名前を読む**と前のコマの最後の中身（history）を読む。窓で遊ぶ時だけ効き、描き出しと 1 枚撮り・動画では透明。
  効き方は 1 コマあたりなので、尾の長さを秒で決めるなら遊びの時計の dt から係数を作る（docs/clock.md）。
- **まだ描いていない pass**（後ろに宣言した pass・このコマで宣言していない古い pass）を読むと黒になり、1 回だけ知らせる。
- 倍率は `App.withPassPlan` に `{ targets = Map#{ "名前" => { scale = 0.5 | RenderTarget.defaultDescriptor() } } | Render.passPlan(passes) }`。
- 3D や後処理を画面の解像度で描くなら、作り方を `RenderTarget.windowDescriptor()`（描き先の画素 × scale。窓の実際の大きさ・動画やスクリーンショットの書き出しの倍率に付いてくる）にする。
  scale は design でも窓でも 0 より大きく 1 以下で、外の値（2.0 など）は 1 に直して `[render] pass: … scale … の外` と 1 回知らせる。
  描き出し（CPU）では、Window の Pass を sprite で貼ると design の寸法に縮めた絵になる（面の tex で読むと書き出しの画素のまま）。
  描き出しは同じ計画を `Render.passSpecsOf` に渡す。sprite で貼ると常に Nearest（1 テクセルが塊になる）・なめらかに広げるなら面で `sampler` を通して読む。

### テクセルの数（`texSize`）と読みの数え方 **[新]**

- 実機は `float(textureSize(uTexN, 0).x)`、描き出しは texEnv の絵の寸法を読む（uniform で寸法を渡さないので、縮んだ pass でも
  GL と同じテクセルの数になる）。
- `texSize` も「読み」として数える: 同じ名前の `tex` / `blur` があればその sampler に相乗りし、無ければ Nearest の 1 組が増える。
  3D の材質の絵の上限（`Scene3d.maxMaterialTextures()`）でも 1 組。pass の読みの決まり（自分の名前は history・まだ描いていない pass は黒）も
  `tex` と同じに掛かる（まだ描いていない pass の寸法は 0）。

## 後処理（`PostProcess`）— トーンマップと FXAA **[新]**

1 を超える明るさを持てる pass（`RenderTarget.withHdr`）に本編を描き、最後に 0..1 へなめらかに収める（トーンマッピング）。
その後で縁のギザギザをならす（FXAA）。どちらも今の場と `shared` だけで組んだ Spec なので、実機と描き出しが同じ木を評価する。

```flix
// 本編の面（Rgba16Float の pass "scene" を読む）をトーンマップして、窓の画素の Rgba8Unorm の pass "post" へ。
let toned = PostProcess.tonemapped(PostProcess.Tonemap.AcesFitted, PostProcess.defaultExposure(),
                                   PostProcess.defaultWhitePoint(), mainSpec);
// 色調は 0..1 を前提にするので、トーンマップの後に同じ面の中で掛ける（after が受けるのは pp_tr / pp_tg / pp_tb の use）。
let warm = (field, k) -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = field, b = ShaderDoc.Field.Const(k) });
let graded = PostProcess.tonemappedWith(PostProcess.Tonemap.AcesFitted, 0.4, 4.0,
                                        (r, g, b) -> ShaderDoc.Shade.Rgb({ r = r, g = warm(g, 0.95), b = warm(b, 0.85) }), mainSpec);
// "post" を FXAA でならして画面へ。
let aa = PostProcess.fxaaSpec("post");
```

- **曲線**: `AcesFitted`（Narkowicz 2015 の ACES の近似を白の点の値で割る）・`Reinhard`（拡張 Reinhard `x(1 + x/W²)/(1 + x)`）。
  どちらも白の点 W でちょうど 1 になる（W が 0 以下なら白の点でそろえず、AcesFitted は式のまま・Reinhard は `x/(1 + x)`）。
  露出は `2^stops` を掛ける。既定は 0.4 stop・W = 4.0 で、8bit の白 1.0 は AcesFitted でおよそ 0.83〜0.9・Reinhard でおよそ 0.62 になる
  （ガンマのままの値をトーンマップするので、白を戻すのは露出の役目）。
- **露出の目安**: 色をガンマのまま扱う今は、既定の +0.4 では中間の明るさも持ち上がり、画面が白っぽくなる（AcesFitted で 0.3 → 0.55）。
  中間の明るさを保つなら −0.6 前後（0.3 → 0.3）。白の伸びより中間の色を優先する画面はこちらから始める。
- **名前**: 包んだ面の名前は `tonemap:曲線:露出:白の点:元の名前`（実機の program の控えは名前を鍵にするので、包む前の面と取り違えない）。
  `after` は名前に入らないので、after だけ違う面を同じコマに並べるなら元の Spec の名前を変えて渡す。`cycleRate` は 0 になる（往復は `pp_f` に写してある）。
- **形**: 色の場は `shared` の `pp_r` / `pp_g` / `pp_b` に 1 回だけ置く（Ramp・Gradient・Cosine は係数の場を `pp_f` に置き、
  `cycleRate` の往復も写す）。元の Spec の `shared` に `pp_` で始まるこれらの名前があると、トーンマップせずに元のまま描き、1 行知らせる。
- **FXAA** は斜めの 4 点と真ん中の明るさ（`luma709`）から縁の向きを出し、向きに沿った 4 点を Linear で読んで混ぜる（読みは 27 回）。
  読む pass は**トーンマップ済みの Rgba8Unorm・窓の画素**（`RenderTarget.windowDescriptor()`・scale 1）を前提にする。
  縮んだ pass では 1 テクセルが 1 画素にならず、ならし方がずれる。α は 1。
- HUD と UI はトーンマップしない（本編の面だけを包む）。

## 生成での注意

- 実機は GPU（`ShaderGen` が GLSL を作る）、生成は CPU（`ShaderEval` が画素ごとに評価）。
  **同じ Spec から両方が出るので絵は一致する**が、面が大きい・入れ子が深いほど生成は遅い。
- 生成に出なかった指定は `SoftRaster.dropped` に溜まる。実機と食い違ったらまずここを見る。
  バックエンド差の一覧は [backend-parity.md](backend-parity.md)。
- 時刻 `t` は呼ぶ側が渡す。スナップショットに生成するときは **`t` を固定**する（実時間を渡すと毎回変わる）。

## F8 の止めた画面と注釈のスクショでの見え方

止めた画面（F8・`/halt`）と注釈のスクショは、走っている間と**同じ `renderFrame` で 1 コマ全部を描く**
（シェーダー面は GPU で本物を描き、レンダーターゲットも描き直す）。F8 のズーム・パンは描く前の絵（PlacedItem）に
カメラと同じ式で掛けるので（`Annotate.applyInspectItems`）、面もほかの絵と一緒に動く。
スクショは、矩形を決めたフレームに等倍で塗ったコマを `saveAnnotation` が塗り直して撮る。

GL の無い経路（描き出しの `Render.draw` / `drawWith` だけを使う所）では面を次のどちらかで描く。
SoftRaster は `Render.shaderSurfaces` で面を受け取り、`ShaderEval` で本物を描く:

| 面の式 | `drawWith` での見え方 |
|---|---|
| テクスチャ 1 枚だけを読み、読む位置が `shift` だけで決まる（dx は u だけ・dy は v だけの 1 次式: `uv` と、`add` `sub`・片側が uv を含まない `mul` で組む。`min` `max` `step` は uv を含まない時だけ） | **そのテクスチャの読む範囲をそのまま貼る**。範囲は面の左上と右下で `shift` を評価して出す。灰色化・明るさなどの色の計算は落ちる |
| それ以外（場だけの面・`scaled` `warp` `tiling` `snap` `swirl` `rotate` の下で `tex` か `use` を読む・ずらし量が 1 次式でない・2 枚以上を読む） | **代表色 1 色のベタ塗り**（`ShaderDoc.representativeColor`。`rgb` は中間の灰） |

## Studio で触れるようにする

`<名前>.shader.schema.json` を隣に置くとフォームになる（手本:
`templates/game-starter/assets/shader.schema.json`）。方言は
[doc-conventions.md](doc-conventions.md) と `/doc-design` skill を参照。
