# fge px の op（技法 → op → 仕上げ）

<!-- 生成物（bin/fge px ops --md）。直すのは go/internal/px の Op の構造体。 -->

指定（`<名前>.pxsrc.json`）の部品の `ops` に、上から順に当てる。書式は `docs/pxsrc.schema.json`、1 つの説明は `bin/fge px help <op>`。

## 早見表（描く物・技法 → op → 仕上げ）

| 描く物・技法 | op（→ は順に当てる・/ はどれか） | 仕上げ・検査 |
|---|---|---|
| 光と陰（小物の面） | `directional` | lint pillow・light-dir |
| 丸い体・キャラ | `shade_parts` | lint pillow・light-dir |
| 手前の物が落とす影 | `shade_mask` | — |
| 1px の線・ひげ・髪の線 | `line` | 既存の lint corner（角が 2 重なら pixel_perfect） |
| 曲線の段の角 | `aa_corners` | lint jaggy・orphan |
| 金属・石・木・布・葉 | `material` | 材質ごと（下の材質の表） |
| 空・斜面の階調・境目のディザ | `gradient_fill` | lint pillow・light-dir・banding |
| 色票に無い中間の色 | `dither_pair` | 既存の lint banding・flat-run |
| 葉・石の斑・草のタイル | `scatter_clusters` → `tile_preview` | 既存の lint orphan・2×2 に並べて見る（tile_preview） / lint seam |
| 遠景と近景・主役と背景 | `depth_fade` → `contrast` | lint value-sep（contrast で測る） / lint value-sep |
| 揺れ・呼吸・弾み（on の子も付いていく） | `sway` / `bob` / `squash` | lint orphan・anim（pop・loop）。欠けは pixel_perfect で整える / anim（bob・ground） / anim（area・ground） |
| 水・滝・流れ（波頭を 1px ずつ流す） | `wave_shift` | anim（pop・loop）。輪が閉じるようにコマの数 × speed を塊の幅に合わせる |

既定値はどれも仮置き（見本 10 題と作品 5 作の大きい見比べで決め直す）。強さは各 op の引数で選び、使わない技法は書かない。

## op の一覧

| 技法 | op | 何をするか | 仕上げ・検査 |
|---|---|---|---|
| 手打ち AA（2px 以上の段の角にだけ中間色） | `aa_corners` | 2px 以上の段の角の凹みにだけ、内側と外の色の中間に一番近いランプの色を 1px 置く（45° と直線には置かない。中間の色が無ければ置かない） | lint jaggy・orphan |
| 小物の陰影（縁で光と影を分ける） | `bevel` | 小物の陰の段: 光の側の縁を lit、影の側の縁（と影の向きへ 2 つ先が外の画素）を dark、中を face | 既存の lint banding |
| 陰影（平らな面は 1 色・光源は左上の 1 つ） | `bevel_box` | 角丸の板: 斜めの帯で 光・地・影、縁の 1px につや（光の側）と墨（影の側）、外側に墨の輪郭（格子は正方形） | 既存の lint banding |
| アニメ（溜め・弾み） | `bob` | 部品を上下に動かす（コマごとに -amp·sin。呼吸・浮遊・歩きの上下） | anim（bob・ground） |
| 背景の奥行き（遠いほど明度差が小さい）・主役と背景を分ける | `contrast` | 今の部品と相手（部品 against か地の色）の明るさ（Oklab の L）の平均の差を測るだけ（描かない） | lint value-sep |
| タイルの割れ目 | `crack` | 親（on）の塊の割れ目: 墨の 1px と、その右下に切り口のつや 1px | — |
| 垂れた紐・鎖（粒を交互の明暗で） | `curve` | 2 次ベジェを 1px の連なった線で引く（alt で 1 画素ごとに色を交互に・avoid の形の中は飛ばす） | 既存の lint corner |
| 背景の奥行き（遠いほど明度差が小さく、空の色・青へ寄る） | `depth_fade` | 遠い層ほど、塗った色を空の色 toward へ depth の割合で寄せ（明度差も縮む）、一番近い候補の色に置き換える（色は足さない。候補は spec の style があればその色の集合、無ければ spec のランプの色と toward） | lint value-sep（contrast で測る） |
| 陰影（光源は 1 つ（左上）。縁を一様に暗くしない） | `directional` | 光の向きだけで塗る陰（gradient_fill の field light・band 0 の短い書き方。縁を一様に暗くしない） | lint pillow・light-dir |
| ディザ（タイルパターン。50% の市松で中間を作る） | `dither_pair` | 色票に無い中間の色を、候補の 2 色の Bayer の混ぜで作って塊を塗る（Yliluoma の 2 色版） | 既存の lint banding・flat-run |
| 小さなアイコン（輪郭 + 平らな面 + 光の側のつや 1 段） | `emblem` | 塊をアイコンの作りで塗る: 縁（4 近傍で外に接する画素）を edge、光の側の縁のすぐ内側 1 段を top、残りを face | 地との明度差（縁の色が地に沈まないか） |
| 塊で形を作る | `fill` | 塊を 1 色で塗る | — |
| 向きの違うコマを鏡で作る | `flip` | 格子全体を左右（x）か上下（y）に返す（右向きのコマから左向きを作る） | — |
| 金属のつや（地・影・白 1〜2px の 3 段） | `glint` | 塊の光の来る角に size 画素のつや（light.gloss、無ければランプの最明段）を置く（縁の 1px は避ける） | lint orphan（つやは例外） |
| 白抜きの記号（駒の印） | `glyph` | 白抜きの記号: 形をつやの色で塗り、右下へ墨の影を 1px | — |
| 白抜きの記号（小さなカード・効果のアイコン） | `glyph_rows` | 文字の格子の白抜きの記号: '.' と空白でない字の画素を color で、その右下 1px に shadow の影（影を先に置く） | — |
| 陰影（光源は 1 つ・平らな面は 1 色）・ディザ（タイルパターン） | `gradient_fill` | 塊を明るさの場（光の向き・x・y・radial）でランプの段に塗る。段の境目は Bayer で混ぜ、band で混ぜる幅を選ぶ | lint pillow・light-dir・banding |
| 光の側を明るく・影の側を暗く（縁の線の明暗） | `light_bands` | 部品の塊の塗ってある画素を、中心から光の向き（light.dir）へどれだけ寄っているかで lit・base・dark の 3 段に塗り分ける | light-dir（段 3） |
| 1px の線 | `line` | 折れ線を 1px で引く（clip の部品なら親の塊の中だけ） | 既存の lint corner（角が 2 重なら pixel_perfect） |
| 左右対称に描く（片側を描いて写す） | `mirror` | 今の部品が描いた画素のうち side の側を、軸で左右に写す（左右対称の顔・道具・建物） | — |
| 輪郭（1 色の外側 1px） | `outline` | 部品の塊の外側 1px を 1 色で縁取る（sel_out の前身） | lint black-outline（部品ごとの色にするなら sel_out） |
| アニメ（パレットの回転。光のきらめき） | `palette_cycle` | 塊の中で colors の段をコマごとに step ずつ回す（光のきらめきの補助。水の流れは wave_shift の方が見比べで勝った） | anim（pop） |
| 寄せ木（かけらごとに別の系統の色） | `parquet` | 寄せ木: center から ramps の数に等分した扇ごとに、ランプ from の色をその扇のランプで塗り直す（from の墨は墨へ、ほかの段は斜めの帯で光・地・影へ。clip の部品なら親の塊の中だけ） | — |
| 1px を手で打つ（目・つや・星） | `put` | 画素を直に置く | 既存の lint orphan |
| 円の線（Aseprite の Ellipse の線） | `ring` | 1px の円を引く（ブレゼンハムの円。角の 2 重が出ず、どこでも 1 画素の太さ） | 既存の lint corner |
| 同じ記号を一回り小さく重ねる | `scaled` | macros の op の列を別の格子に描き、about を中心に scale 倍へ縮め（広げ）て、塗った画素だけ重ねる（近い画素を引く） | — |
| 質感（岩・レンガ・草）・塊と孤立 1px・草のタイル（Aseprite の Tiled Mode） | `scatter_clusters` | 塊の中に 2〜3px の小さな塊を散らして打つ（辺で接しない・1px の単発は出ない。wrap でタイルの端を回す） | 既存の lint orphan・2×2 に並べて見る（tile_preview） |
| 1 段ずつ塗る（Aseprite の Shading ink）・影の形を重ねる | `shade_mask` | 別の部品 of の塊を光と反対へ offset ずらした形で、今の部品に塗ってある色を by 段ずらす（手前の物が落とす影） | — |
| 陰影（丸い体・キャラ。光源は 1 つ） | `shade_parts` | 丸みのある部品を光の向きでランプの 4 段に塗る（前の部品の落とす影・外周の墨・別グループとの境目の線つき） | lint pillow・light-dir |
| 1 段ずつ塗る（Aseprite の Shading ink） | `shade_step` | 塗ってある色を、部品のランプの隣の段へ by 段ずらす（端で止まる・ランプの外の色は触らない） | — |
| アニメ（つぶしと伸ばし） | `squash` | 部品を縦に縮めて横に伸ばす（縦 1 − amount·sin・横 1 + amount·sin。足元を止める）。着地・弾み・呼吸 | anim（area・ground） |
| 手で打った小さな型を置く | `stamp` | 文字の格子を押す（colors が無ければ legend の文字で打ち、'.' は透明へ抜く） | — |
| アニメ（揺れ。根元を止めて先端を遅らせる） | `sway` | 部品の画素を行ごとに横へずらす（根元 0・先端ほど大きく・コマごとに sin）。木・草・旗・髪の揺れ | lint orphan・anim（pop・loop）。欠けは pixel_perfect で整える |
| 草のタイル（Aseprite の Tiled Mode。並べて継ぎ目を見る） | `tile_preview` | このスプライトをタイルとして扱う: 3×3 に並べた見本（<名前>.tile.png）を書き、端の継ぎ目を検査する（描かない） | lint seam |
| 同じ部品を何か所にも置く・コマで体を上下させる | `use` | macros の op の列を、今の部品の中で順に当てる（at でずらせる） | — |
| アニメ（水の波頭を 1px ずつずらす。見比べで palette_cycle に勝った） | `wave_shift` | 塊の外形は動かさず、中の模様（波頭・流れ）を行ごとにコマごとに speed px 横へ回す。水・滝・流れる雲の既定 | anim（pop・loop）。輪が閉じるようにコマの数 × speed を塊の幅に合わせる |

ほかの op（16px 前後の見比べで差が出なかった物。既定にしない。使う時は `bin/fge px help <op>`）: `ground_shadow`・`pixel_perfect`・`ramp_pick`・`rim_light`・`sel_out`

## 動きのコマ数の目安

待機 4〜8・歩き 6〜8・走り 4〜8・攻撃 8〜12・倒れ 6〜8（攻撃は少なすぎても多すぎても締まらない。frames は「始めの姿勢 → 順に起きること → 終わり方」の順に並べる）。

## 材質（部品の `material`）

手順を覚えずに `"material": "metal"` と書く。中身は既存の op の並びで、部品の `ops` の前に差し込む。

| 材質 | 何をするか | 引数 | 技法 | 仕上げ |
|---|---|---|---|---|
| `cloth` | 大きい面を 2 段のベタで塗り（最暗の段は使わない）、折り目の線を 1 段暗く、部品の色の輪郭 | `fold` 折り目の折れ線 [[x, y], ...]（省くと折り目なし）・`outline` sel_out で縁取る（タイルの目地を潰すなら false）（省くと true） | 陰影（平らな面は 1 色）・布の折り目 | lint pillow・light-dir |
| `foliage` | 葉の塊: directional の陰に明るい段と暗い段の小さな塊を散らし、部品の色の輪郭。sway で揺らせる | `cell` 葉の塊の間隔（1〜64）（省くと 3）・`seed` 散らし方の番号（0〜1.048576e+06）（省くと 0）・`sway` 揺れの幅（px。0 で揺らさない）（0〜16）（省くと 0） | 質感（葉）・塊と孤立 1px・アニメ（揺れ） | 既存の lint orphan・anim |
| `metal` | 光の向きでランプの全段をベタの帯に塗り（directional）、光の角に 1〜2px のつや、部品の色の輪郭 | `gloss` つやの画素の数（0 で付けない）（0〜8）（省くと 2）・`outline` sel_out で縁取る（タイルの目地を潰すなら false）（省くと true） | 金属のつや | lint orphan（つやは例外）・pillow |
| `stone` | directional の陰に、暗い段の小さな斑（2〜3px）を散らす（手組みの directional + scatter_clusters と同じ） | `cell` 斑の間隔（小さいほど密）（1〜64）（省くと 3）・`seed` 散らし方の番号（0〜1.048576e+06）（省くと 0）・`outline` sel_out で縁取る（タイルの目地を潰すなら false）（省くと true） | 質感（岩・レンガ） | 既存の lint orphan |
| `wood` | directional の陰に、横の短い木目の筋（2〜3px）を散らす（手組みの directional + scatter_clusters と同じ） | `cell` 木目の間隔（1〜64）（省くと 3）・`seed` 散らし方の番号（0〜1.048576e+06）（省くと 0）・`outline` sel_out で縁取る（タイルの目地を潰すなら false）（省くと true） | 質感（木） | 既存の lint orphan |

## 歩きの姿勢（frames の `pose`）

右を向いた横向き 1 方向のコマを作る（4 方向は carve と adopt）。役は `roles` で部品 id に当てる。角度は度・正で時計回り。

| 姿勢 | 役ごとの動き |
|---|---|
| `contact` | armB 回転 -20・ずらし [0, 0]・armF 回転 20・ずらし [0, 0]・legB 回転 25・ずらし [0, 0]・legF 回転 -25・ずらし [0, 0] |
| `down` | armB 回転 -10・ずらし [0, 1]・armF 回転 10・ずらし [0, 1]・body 回転 0・ずらし [0, 1]・head 回転 0・ずらし [0, 1]・legB 回転 15・ずらし [0, 0]・legF 回転 -15・ずらし [0, 0] |
| `passing` | legB 回転 0・ずらし [0, 0]・legF 回転 0・ずらし [0, 0] |
| `up` | armB 回転 5・ずらし [0, -1]・armF 回転 -5・ずらし [0, -1]・body 回転 0・ずらし [0, -1]・head 回転 0・ずらし [0, -1]・legB 回転 -10・ずらし [0, 0]・legF 回転 10・ずらし [0, 0] |

## 台本（`<名前>.px.star`）

単純な指定は JSON（pxsrc）、繰り返しや変化が要る所は Starlark（Python とほぼ同じ書き方）の台本で、道具を関数として呼ぶ。
`bin/fge px gen <名前>.px.star` で台本が書く pxsrc・JSON を書き出し、`bin/fge px build <名前>.px.star` は書き出さずにメモリの中で build する。

| 呼べる物 | 何をするか |
|---|---|
| `px.write_spec(path, value)` | pxsrc を書く（spec の検査を当ててから。assets/ の下と作業場の外には書けない） |
| `px.write_json(path, value)` | 色票などの JSON を書く（`style="python", indent=…` は Python の json.dump と同じ並び。写しの間だけ） |
| `px.hash01(x, y, seed)`・`px.noise1(x, seed)`・`px.rng(seed)` | 種つきのゆらぎ・乱数（rng は CPython の random.Random と同じ列。写しの間だけ） |
| `px.round(x, nd)` | Python の round（ちょうど半分は偶数へ） |
| `math.*` | sin・cos・tan・atan2・hypot・exp・log・pow・sqrt・floor・ceil・radians・pi。答えは正しく丸めた値で、OS・CPU で変わらない |

- 囲い: load は台本と同じフォルダと隣の `tools/` の `.star` だけ。ファイル・ネット・時刻には触れない。手数は 1 本 500000000 手まで。
- Starlark に無い物: class（dict と関数で書く）・`**`（`math.pow` か `x * x`）・set・連なった比較（`a <= x < b`）・bool の足し算。
- 決まり（今は advice）: 台本 1 本 600 行・pxsrc 1 本 500 KB・1 部品の put 200 画素・格子の半分を超える stamp・while。使われない関数は止める。

## 引数

### `aa_corners`

例: `{"aa_corners": {}}`

部品を描き終えたら、その範囲で検査 `sprite:jaggy` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `mix` | number | 外の色へ寄せる割合（0.5 = 真ん中）（0.1〜0.9）（省くと 0.5） |
| `against` | string | どの縁に当てるか: clear（絵の外形 = 外が透明な所だけ）・any（ほかの部品との境目にも）（省くと "clear"） |

### `bevel`

例: `{"bevel": {"shape": {"disk": [8, 8, 4]}}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `lit` | color | 光の側の縁の色（省くと "light"） |
| `face` | color | 中の色（省くと "mid"） |
| `dark` | color | 影の側の縁の色（省くと "shade"） |

### `bevel_box`

例: `{"bevel_box": {"radius": 3.2, "inset": 1}}`

格子全体に描く（部品の `at`・`use` の `at` でずらせない）。

| 引数 | 型 | 説明 |
|---|---|---|
| `radius` | number | 角の丸みの半径（0〜64）（省くと 6.5） |
| `inset` | number | 格子の縁からの余白（0〜64）（省くと 2） |
| `bands` | pair | 光・地・影の境目（0〜1。左上の角が 0）（省くと [0.3,0.72]） |
| `gloss_until` | number | 縁のつやを置く範囲（x+y が格子の幅のこの割合まで）（0〜2）（省くと 0.8） |

### `bob`

例: `{"bob": {"amp": 1}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `amp` | number | 上下の幅（px）（-16〜16）（省くと 1） |
| `phase` | number | 位相のずれ（1 周 = 1.0。部品ごとに揺れを遅らせる）（-1〜1）（省くと 0） |

### `contrast`

例: `{"contrast": {"against": "base"}}`

部品を描き終えたら、その範囲で検査 `value-sep` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `against` | string | 相手の部品 id（省くと light.ground の地の色） |
| `min` | number | 差の下限（0 で bin/lint-rules/px.json の valueSepMin）（0〜1）（省くと 0） |

### `crack`

例: `{"crack": {"points": [[3, 8], [6, 9], [9, 7]]}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `points` | vectors | 折れ線の点 [[x, y], ...]（小数も可。画素には偶数丸めで落とす）（必須） |

### `curve`

例: `{"curve": {"points": [[2, 2], [4, 12], [12, 10]], "color": "ink", "alt": "light"}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `points` | vectors | 始点・制御点・終点 [[x, y], [x, y], [x, y]]（必須） |
| `color` | color | 色（ink・shade・mid・light・ramp[i]・gloss・色キー。"" で透明へ抜く）（必須） |
| `alt` | color | 1 画素おきに置く 2 つ目の色（省くと color だけ） |
| `avoid` | shape | 画素の中心がこの形の中なら置かない（数にも入れない） |
| `steps` | int | 曲線を刻む数（多いほど取りこぼしが無い）（1〜10000）（省くと 400） |

### `depth_fade`

例: `{"depth_fade": {"depth": 0.5, "toward": "light"}}`

部品を描き終えたら、その範囲で検査 `value-sep` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `depth` | number | 遠さ（0 = そのまま・1 = 空の色）（0〜1）（省くと 0.5） |
| `toward` | color | 寄せる空の色（省くと light.ground の地の色）（省くと ""） |

### `directional`

例: `{"directional": {}}`

部品を描き終えたら、その範囲で検査 `pillow`・`light-dir` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `band` | number | 段の境目のディザの幅（0 = ベタの帯）（0〜8）（省くと 0） |
| `from` | int | 使う一番暗い段（0〜15）（省くと 0） |
| `to` | int | 使う一番明るい段（-1 で最明）（-1〜15）（省くと -1） |

### `dither_pair`

例: `{"dither_pair": {"color": "#808080"}}`

部品を描き終えたら、その範囲で検査 `sprite:banding`・`flat-run` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `color` | string | 狙いの色（#rrggbb か色キー）（必須） |
| `among` | rows | 混ぜる候補の色（省くと部品のランプ） |

### `emblem`

例: `{"emblem": {"shape": {"roundRect": [3, 3, 9, 9, 1]}}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `edge` | color | 縁の色（省くと "ink"） |
| `face` | color | 面の色（省くと "mid"） |
| `top` | color | 光の側（light.dir の上下）のつやの色（省くと "light"） |

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

### `glint`

例: `{"glint": {"size": 2}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `size` | int | つやの画素の数（1〜2 が目安）（1〜8）（省くと 2） |
| `color` | color | つやの色（省くと gloss か ramp[-1]）（省くと ""） |

### `glyph`

例: `{"glyph": {"shape": {"disk": [8, 8, 3]}}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |

### `glyph_rows`

例: `{"glyph_rows": {"at": [4, 4], "rows": ["##", "#."]}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `at` | point | 記号の左上 [x, y]（必須） |
| `rows` | rows | 記号の行（'.' と空白は外）（必須） |
| `color` | color | 記号の色（省くと "gloss"） |
| `shadow` | color | 右下 1px の影の色（省くと "shade"） |

### `gradient_fill`

例: `{"gradient_fill": {"field": "light", "band": 0.25}}`

部品を描き終えたら、その範囲で検査 `pillow`・`light-dir`・`sprite:banding` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `field` | string | 明るさの場: light（光の向き。directional）・y（上が明るい）・x（右が明るい）・radial（中心が明るい）（省くと "light"） |
| `band` | number | 段の境目のうちディザで混ぜる割合（1 = 全部・0.25 = 境目だけ・0 = ベタの帯）（0〜1）（省くと 1） |
| `from` | int | 使う一番暗い段（0〜15）（省くと 0） |
| `to` | int | 使う一番明るい段（-1 で最明）（-1〜15）（省くと -1） |
| `invert` | bool | 明暗を返す（省くと false） |

### `light_bands`

例: `{"light_bands": {"center": [7, 7], "cut": [1, -1]}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `center` | pair | 中心 [x, y]（画素の番号）（必須） |
| `cut` | pair | [a, b]: 光への寄り（光の向きの符号で dx・dy を足した値）が a より大きければ lit、b より小さければ dark（省くと [0,0]） |
| `lit` | color | 光の側の色（省くと "light"） |
| `base` | color | あいだの色（省くと "mid"） |
| `dark` | color | 影の側の色（省くと "shade"） |

### `line`

例: `{"line": {"points": [[3, 3], [8, 6]], "color": "ink"}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `points` | vectors | 折れ線の点 [[x, y], ...]（小数も可。画素には偶数丸めで落とす）（必須） |
| `color` | color | 色（ink・shade・mid・light・ramp[i]・gloss・色キー。"" で透明へ抜く）（必須） |

### `mirror`

例: `{"mirror": {"side": "left"}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `side` | string | 写す元の側: left（左を右へ）・right（右を左へ）（省くと "left"） |
| `axis` | number | 軸の x（画素の中心は整数・境目は .5。省くと部品の塊の外接箱の真ん中） |

### `outline`

例: `{"outline": {"color": "ink"}}`

部品を描き終えたら、その範囲で検査 `black-outline` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `color` | color | 縁の色（省くと "ink"） |

### `palette_cycle`

例: `{"palette_cycle": {"colors": ["shade", "mid", "light"]}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `colors` | rows | 回す色の並び（2 色以上）（必須） |
| `step` | int | 1 コマで進む段数（負で逆回り）（-16〜16）（省くと 1） |

### `parquet`

例: `{"parquet": {"from": "r", "ramps": ["r", "r"]}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `from` | string | 塗り直す元のランプの名前（必須） |
| `ramps` | rows | 扇ごとのランプの名前（start から時計回りに）（必須） |
| `start` | number | 最初の扇の始まりの向き（ラジアン。既定は真上）（省くと -1.5707963267948966） |
| `center` | pair | 扇の中心 [x, y]（省くと格子の中央） |
| `bands` | pair | 光・地・影の境目（0〜1。左上の角が 0）（省くと [0.3,0.72]） |

### `put`

例: `{"put": {"cells": [[4, 4], [5, 4]], "color": "light"}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `cells` | points | 画素の座標 [[x, y], ...]（必須） |
| `color` | color | 色（ink・shade・mid・light・ramp[i]・gloss・色キー。"" で透明へ抜く）（必須） |

### `ring`

例: `{"ring": {"center": [7, 7], "r": 3, "color": "ink"}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `center` | point | 中心の画素 [x, y]（必須） |
| `r` | int | 半径（画素の数）（0〜256）（必須） |
| `color` | color | 色（ink・shade・mid・light・ramp[i]・gloss・色キー。"" で透明へ抜く）（必須） |

### `scaled`

例: `{"scaled": {"macro": "eye", "scale": 0.5, "about": [8, 8]}}`

格子全体に描く（部品の `at`・`use` の `at` でずらせない）。

| 引数 | 型 | 説明 |
|---|---|---|
| `macro` | string | macros の名前（必須） |
| `scale` | number | 大きさの倍率（0.72 なら 0.72 倍）（0.01〜8）（必須） |
| `about` | pair | 縮める中心 [x, y]（必須） |

### `scatter_clusters`

例: `{"scatter_clusters": {"colors": ["shade"], "cell": 3, "seed": 1}}`

部品を描き終えたら、その範囲で検査 `sprite:orphan` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `colors` | rows | 打つ色の並び（塊ごとにハッシュで選ぶ）（省くと ["shade"]） |
| `kind` | string | 塊の型: blob（葉・石の斑）・line（木目の筋）・crack（ひび）（省くと "blob"） |
| `cell` | int | 散らす升目の大きさ（小さいほど密）（1〜64）（省くと 3） |
| `seed` | int | 散らし方の番号（variants の seed が足される）（0〜1.048576e+06）（省くと 0） |
| `keep` | number | 升目に塊を置く割合（0〜1）（0〜1）（省くと 1） |
| `wrap` | bool | タイルの端をまたいで反対側へ回す（並べた継ぎ目を隠す）（省くと false） |

### `shade_mask`

例: `{"shade_mask": {"of": "base", "offset": [1, 1]}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `of` | string | 影を落とす部品の id（この部品より前の列）（必須） |
| `by` | int | ずらす段数（負で暗く）（-8〜8）（省くと -1） |
| `offset` | point | 影のずれ [dx, dy]（省くと光と反対へ 1px） |

### `shade_parts`

例: `{"shade_parts": {"thick": 4, "group": "body"}}`

部品を描き終えたら、その範囲で検査 `pillow`・`light-dir` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `thick` | number | 丸みの厚さ（大きいほど縁から奥まで段が続く）（0.5〜64）（省くと 6） |
| `group` | string | 同じグループの部品どうしは影と境目の線を付けない（省くと ""） |
| `lines` | bool | 後ろの別グループの部品に接する縁を暗い段で締める（省くと true） |
| `flat` | bool | 丸みを付けず地の段で塗る（省くと false） |
| `bias` | number | 明るさの底上げ（正で明るく）（-1〜1）（省くと 0） |
| `outline` | color | 影の側の外周の色（"" で外す）（省くと "ink"） |
| `rim` | color | 光の側の外周の色（暗い材質を闇から抜く明るい縁。省くとランプの最暗段）（省くと ""） |

### `shade_step`

例: `{"shade_step": {"by": -1, "shape": {"rect": [3, 3, 3, 6]}}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `by` | int | ずらす段数（負で暗く・正で明るく）（-8〜8）（省くと -1） |
| `shape` | shape | 形（省くと部品の塊） |

### `squash`

例: `{"squash": {"amount": 0.2}}`

部品を描き終えたら、その範囲で検査 `sprite:orphan` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `amount` | number | 伸び縮みの強さ（0〜0.5 が目安）（0〜0.9）（省くと 0.2） |
| `phase` | number | 位相のずれ（1 周 = 1.0。部品ごとに揺れを遅らせる）（-1〜1）（省くと 0） |
| `anchor` | string | 止める所: bottom（足元）・center（真ん中）（省くと "bottom"） |

### `stamp`

例: `{"stamp": {"at": [3, 3], "rows": ["#.", ".#"], "colors": {"#": "light"}}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `at` | point | 左上の位置 [x, y]（必須） |
| `rows` | rows | 文字の行（必須） |
| `colors` | colormap | 文字 → 色の名前（書いた文字だけ置く） |

### `sway`

例: `{"sway": {"amp": 1}}`

部品を描き終えたら、その範囲で検査 `sprite:orphan` を回す。

| 引数 | 型 | 説明 |
|---|---|---|
| `amp` | number | 先端のずれの最大（px）（-16〜16）（省くと 1） |
| `curve` | number | 根元から先端への効き方（1 = まっすぐ・2 = 先端だけ大きく）（0.1〜8）（省くと 1） |
| `phase` | number | 位相のずれ（1 周 = 1.0。部品ごとに揺れを遅らせる）（-1〜1）（省くと 0） |
| `root` | string | 止める端: bottom（木・草）・top（髪・吊るした旗）（省くと "bottom"） |
| `ripple` | number | 根元から先端へ遅れて伝わる波の数（0 で全体が同じ向き。旗は 0.5 ほど）（0〜8）（省くと 0） |

### `tile_preview`

例: `{"tile_preview": {}}`

格子全体に描く（部品の `at`・`use` の `at` でずらせない）。

部品を描き終えたら、その範囲で検査 `seam` を回す。

引数は無い（`{}` と書く）。

### `use`

例: `{"use": {"macro": "eye", "at": [1, 0]}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `macro` | string | macros の名前（必須） |
| `at` | point | ずらす量 [dx, dy] |

### `wave_shift`

例: `{"wave_shift": {"speed": 1}}`

| 引数 | 型 | 説明 |
|---|---|---|
| `shape` | shape | 形（省くと部品の塊） |
| `speed` | int | 1 コマで流れる px（負で左へ）（-8〜8）（省くと 1） |
| `ripple` | number | 行が 1 つ下がるごとに足すずれ（0 で全部の行がそろって流れる・0.5 で斜めの波）（-4〜4）（省くと 0） |

## 形

部品の `shape` と op の `shape` に書く。鍵 1 つで種類を決め、ほかの鍵は種類ごとの引数。

| 形 | 値 | ほかの鍵 | 何か |
|---|---|---|---|
| `annulus` | [cx, cy, r, w] |  | 輪（中心から r の円に沿った、幅 2w の帯） |
| `capsule` | [ax, ay, bx, by, r] |  | 両端の丸い棒 |
| `disk` | [cx, cy, r] |  | 丸 |
| `ellipse` | [cx, cy, rx, ry] |  | 楕円 |
| `inter` | [形, 形, ...]（2 つ以上） |  | 積（全部の中） |
| `mask` | 文字の行 | `at` 左上の位置 [x, y]（省くと [0,0]） | rows で画素を直に指す（'.' と ' ' が外） |
| `path` | [[x, y], ...]（2 点以上） | `width` 太さ（0.1〜64）（省くと 1） | 折れ線に太さを付けた物（角と端は丸い） |
| `poly` | [[x, y], ...]（3 点以上） |  | 多角形（点を順に結ぶ） |
| `rbox` | [cx, cy, hw, hh, r] |  | 角丸の矩形（中心と半分の幅） |
| `rect` | [x, y, w, h] |  | 画素に揃った矩形（x..x+w-1・y..y+h-1 の画素） |
| `ref` | shapes の名前 |  | shapes の名前つきの形を引く |
| `rotate` | 回す量（周。正は時計回り） | `about` 回す中心 [x, y]（必須）・`of` 元の形（必須） | 形を回す（1 周 = 1.0） |
| `roundRect` | [x0, y0, x1, y1, r] |  | 画素の範囲で書く角丸の矩形（x0..x1・y0..y1 の画素を含み、角は内側へ r の丸。塗りの判定専用。smoothUnion・rounded には使えない） |
| `rounded` | 太らせる量 | `of` 元の形（必須） | 形を太らせて角を丸める |
| `smoothUnion` | [形, 形] | `k` つなぎの幅（0 より大きい）（省くと 1） | なめらかにつないだ和 |
| `star` | [cx, cy, rOut, rIn] | `n` 角の数（3〜64）（省くと 5）・`rot` 最初の角の向き（ラジアン。既定は真上）（省くと -1.5707963267948966） | 星（外と内の半径を交互に結ぶ多角形） |
| `taper` | [ax, ay, bx, by, r0, r1] |  | 先細りの棒（塗りの判定専用。smoothUnion・rounded には使えない） |
| `union` | [形, 形, ...]（2 つ以上） |  | 和（どれかの中） |

## 検査

| 検査 | 重さ | 何を見るか |
|---|---|---|
| `anim` | lint | anim: コマ列に bin/fge anim の pop・area・ground・bob・loop をかける（動きの op・pose・rotate を使うスプライト、か anim: true） |
| `black-outline` | advice | black-outline: 小さい絵（blackOutlineMaxSize 未満）で、外の縁が 1 色・絵の中で一番暗い色のまま一周している |
| `flat-run` | advice | 輪郭の段: 同じ長さの段が続く（直線に読まれる）・長すぎる直線（16px で 4px・32px で 6px を超える） |
| `flicker` | lint | flicker: コマの間で周り 8 画素が動かないのに色だけ変わる画素（ちらつき。palette_cycle と wave_shift の画素は除く） |
| `ground-contrast` | lint | 外周の画素と地の色の明るさ（Oklab の L）の差が小さく、輪郭が地に溶ける |
| `light-dir` | advice | light-dir: 塊の明るさで重みを付けた重心（明るい側 − 暗い側）が光の側（light.dir）に無い |
| `margin` | advice | margin: 動く絵が格子の左・右・上の縁に触れている（動く余白が無い） |
| `pillow` | advice | pillow: 塊の縁が光の側でも影の側でも同じように内側より暗い（縁からの距離で塗った陰） |
| `ramp-order` | lint | ramp-order: ランプの明るさ（Oklab の L）が暗 → 明に単調でない・隣の段の差が rampMinGap に足りない |
| `run-monotone` | lint | 曲線の段の長さが単調でない（3-2-1 は良い・1-2-1-2 と 3-2-1-4 は不可） |
| `seam` | lint | seam: タイルの端（左と右・上と下）の画素の明るさの差が、内側の隣り合う列の差の seamRatio 倍を超える（並べると継ぎ目が見える） |
| `sprite` | lint | bin/fge sprite の形の規則（orphan・connect・jaggy・banding・corner・silhouette） |
| `style` | gate | 機種の決まり（spec の style）: 使える色・1 コマの色数・升目ごとの色数・RGB の段数・大きさ |
| `value-sep` | lint | value-sep: contrast で測った部品と相手の明るさの差が下限（min か valueSepMin）を下回る |
