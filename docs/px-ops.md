# fge px の op（技法 → op → 仕上げ）

<!-- 生成物（bin/fge px ops --md）。直すのは go/internal/px の Op の構造体。 -->

指定（`<名前>.pxsrc.json`）の部品の `ops` に、上から順に当てる。書式は `docs/pxsrc.schema.json`、1 つの説明は `bin/fge px help <op>`。

| 技法 | op | 何をするか | 仕上げ・検査 |
|---|---|---|---|
| 陰影（平らな面は 1 色・光源は左上の 1 つ） | `bevel_box` | 角丸の板: 斜めの帯で 光・地・影、縁の 1px につや（光の側）と墨（影の側）、外側に墨の輪郭（格子は正方形） | 既存の lint banding |
| タイルの割れ目 | `crack` | 親（on）の塊の割れ目: 墨の 1px と、その右下に切り口のつや 1px | — |
| 塊で形を作る | `fill` | 塊を 1 色で塗る | — |
| 向きの違うコマを鏡で作る | `flip` | 格子全体を左右（x）か上下（y）に返す（右向きのコマから左向きを作る） | — |
| 白抜きの記号（駒の印） | `glyph` | 白抜きの記号: 形をつやの色で塗り、右下へ墨の影を 1px | — |
| 1px の線 | `line` | 折れ線を 1px で引く（clip の部品なら親の塊の中だけ） | 既存の lint corner（角が 2 重なら pixel_perfect） |
| 輪郭（1 色の外側 1px） | `outline` | 部品の塊の外側 1px を 1 色で縁取る（sel_out の前身） | lint black-outline（段 3） |
| pixel-perfect（Aseprite の Pencil の Pixel Perfect） | `pixel_perfect` | 1px の線の L 字の角（ダブル）を左上から順に抜く | 既存の lint corner |
| 1px を手で打つ（目・つや・星） | `put` | 画素を直に置く | 既存の lint orphan |
| 陰影（丸い体・キャラ。光源は 1 つ） | `shade_parts` | 丸みのある部品を光の向きでランプの 4 段に塗る（前の部品の落とす影・外周の墨・別グループとの境目の線つき） | lint pillow（段 3） |
| 1 段ずつ塗る（Aseprite の Shading ink） | `shade_step` | 塗ってある色を、部品のランプの隣の段へ by 段ずらす（端で止まる・ランプの外の色は触らない） | — |
| 手で打った小さな型を置く | `stamp` | 文字の格子を押す（colors が無ければ legend の文字で打ち、'.' は透明へ抜く） | — |
| 同じ部品を何か所にも置く・コマで体を上下させる | `use` | macros の op の列を、今の部品の中で順に当てる（at でずらせる） | — |

## 引数

### `bevel_box`

例: `{"bevel_box": {"radius": 3.2, "inset": 1}}`

格子全体に描く（部品の `at`・`use` の `at` でずらせない）。

| 引数 | 型 | 説明 |
|---|---|---|
| `radius` | number | 角の丸みの半径（省くと 6.5） |
| `inset` | number | 格子の縁からの余白（省くと 2） |
| `bands` | pair | 光・地・影の境目（0〜1。左上の角が 0）（省くと [0.3,0.72]） |
| `gloss_until` | number | 縁のつやを置く範囲（x+y が格子の幅のこの割合まで）（省くと 0.8） |

### `crack`

例: `{"crack": {"points": [[3, 8], [6, 9], [9, 7]]}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `points` | points | 折れ線の点 [[x, y], ...]（必須） |

### `fill`

例: `{"fill": {"color": "shade"}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `color` | color | 色（ink・shade・mid・light・ramp[i]・gloss・色キー。"" で透明へ抜く）（必須） |

### `flip`

例: `{"flip": {"axis": "x"}}`

格子全体に描く（部品の `at`・`use` の `at` でずらせない）。

| 引数 | 型 | 説明 |
|---|---|---|
| `axis` | axis | "x" は左右・"y" は上下（省くと "x"） |

### `glyph`

例: `{"glyph": {"shape": {"disk": [8, 8, 3]}}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |

### `line`

例: `{"line": {"points": [[3, 3], [8, 6]], "color": "ink"}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `points` | points | 折れ線の点 [[x, y], ...]（必須） |
| `color` | color | 色（ink・shade・mid・light・ramp[i]・gloss・色キー。"" で透明へ抜く）（必須） |

### `outline`

例: `{"outline": {"color": "ink"}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `color` | color | 縁の色（省くと "ink"） |

### `pixel_perfect`

例: `{"pixel_perfect": {"color": "ink"}}`

部品を描き終えたら、その範囲で検査 `sprite:corner` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `color` | color | この色の画素だけを相手にする（省くと部品の全部） |

### `put`

例: `{"put": {"cells": [[4, 4], [5, 4]], "color": "light"}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `cells` | points | 画素の座標 [[x, y], ...]（必須） |
| `color` | color | 色（ink・shade・mid・light・ramp[i]・gloss・色キー。"" で透明へ抜く）（必須） |

### `shade_parts`

例: `{"shade_parts": {"thick": 4, "group": "body"}}`

格子全体に描く（部品の `at`・`use` の `at` でずらせない）。

| 引数 | 型 | 説明 |
|---|---|---|
| `thick` | number | 丸みの厚さ（大きいほど縁から奥まで段が続く）（省くと 6） |
| `group` | string | 同じグループの部品どうしは影と境目の線を付けない（省くと ""） |
| `lines` | bool | 後ろの別グループの部品に接する縁を暗い段で締める（省くと true） |
| `flat` | bool | 丸みを付けず地の段で塗る（省くと false） |
| `bias` | number | 明るさの底上げ（正で明るく）（省くと 0） |
| `outline` | color | 影の側の外周の色（"" で外す）（省くと "ink"） |
| `rim` | color | 光の側の外周の色（暗い材質を闇から抜く明るい縁。省くとランプの最暗段）（省くと ""） |

### `shade_step`

例: `{"shade_step": {"by": -1, "shape": {"rect": [3, 3, 3, 6]}}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `by` | int | ずらす段数（負で暗く・正で明るく）（省くと -1） |
| `shape` | shape | 形（省くと部品の塊） |

### `stamp`

例: `{"stamp": {"at": [3, 3], "rows": ["#.", ".#"], "colors": {"#": "light"}}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `at` | point | 左上の位置 [x, y]（必須） |
| `rows` | rows | 文字の行（必須） |
| `colors` | colormap | 文字 → 色の名前（書いた文字だけ置く） |

### `use`

例: `{"use": {"macro": "eye", "at": [1, 0]}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `macro` | string | macros の名前（必須） |
| `at` | point | ずらす量 [dx, dy] |

## 形

部品の `shape` と op の `shape` に書く。鍵 1 つで種類を決め、ほかの鍵は種類ごとの引数。

| 形 | 値 | ほかの鍵 | 何か |
|---|---|---|---|
| `capsule` | [ax, ay, bx, by, r] |  | 両端の丸い棒 |
| `disk` | [cx, cy, r] |  | 丸 |
| `ellipse` | [cx, cy, rx, ry] |  | 楕円 |
| `inter` | [形, 形, ...]（2 つ以上） |  | 積（全部の中） |
| `mask` | 文字の行 | `at` 左上の位置 [x, y]（省くと [0,0]） | rows で画素を直に指す（'.' と ' ' が外） |
| `path` | [[x, y], ...]（2 点以上） | `width` 太さ（省くと 1） | 折れ線に太さを付けた物（角と端は丸い） |
| `poly` | [[x, y], ...]（3 点以上） |  | 多角形（点を順に結ぶ） |
| `rbox` | [cx, cy, hw, hh, r] |  | 角丸の矩形（中心と半分の幅） |
| `rect` | [x, y, w, h] |  | 画素に揃った矩形（x..x+w-1・y..y+h-1 の画素） |
| `ref` | shapes の名前 |  | shapes の名前つきの形を引く |
| `rotate` | 回す量（周。正は時計回り） | `about` 回す中心 [x, y]（必須）・`of` 元の形（必須） | 形を回す（1 周 = 1.0） |
| `rounded` | 太らせる量 | `of` 元の形（必須） | 形を太らせて角を丸める |
| `smoothUnion` | [形, 形] | `k` つなぎの幅（0 より大きい）（省くと 1） | なめらかにつないだ和 |
| `star` | [cx, cy, rOut, rIn] | `n` 角の数（省くと 5）・`rot` 最初の角の向き（ラジアン。既定は真上）（省くと -1.5707963267948966） | 星（外と内の半径を交互に結ぶ多角形） |
| `taper` | [ax, ay, bx, by, r0, r1] |  | 先細りの棒（塗りの判定専用。smoothUnion・rounded には使えない） |
| `union` | [形, 形, ...]（2 つ以上） |  | 和（どれかの中） |

## 検査

| 検査 | 重さ | 何を見るか |
|---|---|---|
| `flat-run` | advice | 輪郭の段: 同じ長さの段が続く（直線に読まれる）・長すぎる直線（16px で 4px・32px で 6px を超える） |
| `ground-contrast` | lint | 外周の画素と地の色の明るさ（Oklab の L）の差が小さく、輪郭が地に溶ける |
| `run-monotone` | lint | 曲線の段の長さが単調でない（3-2-1 は良い・1-2-1-2 と 3-2-1-4 は不可） |
| `sprite` | lint | bin/fge sprite の形の規則（orphan・connect・jaggy・banding・corner・silhouette） |
