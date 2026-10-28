# shader.json（ShaderDoc）の書き方

面（矩形）を「画素ごとの計算」で塗るための宣言。単色の box をやめて、動く霧・水面・
vignette・熱い溶岩を **JSON の保存だけで即調整できる**形で置ける。

- 実体: `engine/src/ShaderDoc.flix`（型）・`ShaderJson.flix`（読み書き）・
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
| `pow` | `of`, `p` | 明暗のカーブ |
| `math1` | `op`, `of` | `neg`/`abs`/`fract`/`floor`/`sin`/`cos`/`sat`/`oneMinus` |
| `math2` | `op`, `a`, `b` | `add`/`sub`/`mul`/`min`/`max`/`step` |
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
完成形は `templates/rpg-starter/assets/town.shader.json`（水路の水面を `shared` で網とムラを
分けて足し合わせる実践形）。

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
- 標本は**補間なし（NEAREST）・端は張り付き（CLAMP）**。`shift` で端を越えても
  反対側へ回り込まない（実機は sampler object で通常テクスチャの REPEAT も封じる）
- 値は 8bit を 255 で割った 0〜1。pass の上下逆格納は実機側が自動で吸収する（JSON は何もしない）
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

### ぼかしのコスト（正直な試算）

3×3 ガウス RGB = `tex` 読み 27 回 + 約 50 ノードの JSON。`shared` はタップに効かない
（`use` は基準 uv で凍る）。**カーネル 5×5 以上が常用になったら専用ノード（または
シェーダーチェーン Wave）を相談すること。**

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
