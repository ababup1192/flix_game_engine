# お題（両方の組で同じ）

作業場は自分の組のフォルダ（`c1/` か `c2/`）。画風は そのフォルダの `AGENTS.local.md`、色は `assets/palette.json`（自分で作る）。
sprite.json の書き方は engine の `templates/rpg-starter/assets/rpg.chars.sprite.json` と同じ形
（`version`・`title`・`paletteFile: "assets/palette.json"`・`legend`（1 字 → 色の名前）・`sprites.<名前>.frames.<コマ名>` = 行の配列。`.` は透明）。
オリジナルの題材で描く（既存のゲームのキャラや絵を真似しない）。

## A. キャラ（`assets/a_char.sprite.json`）
- 32×32。灯台守の見習いの少女: 黄色い雨合羽（フード付き）・長靴・片手に小さな手提げランプ。正面寄りの 3/4、立ち姿。
- スプライト `idle` に 4 コマ（`f0`〜`f3`）の待機アニメ（息をする）。`f0` が立ち絵を兼ねる。
- コマの長さは sprite に `"delaysMs": [f0, f1, f2, f3 の ms]` か `"delayMs": 共通` で書ける（既定 200ms）。

## B. 地面タイル（`assets/b_tiles.sprite.json`）
- 16×16 を 4 種: スプライト `grass`・`dirt`・`cobble`（石畳）・`water`（各 1 コマ `f0`）。真上から。
- それぞれ同じタイルを並べた時に継ぎ目が見えないこと（上下左右で回る）。種類どうしの境はつなぎタイルを作らず、そのまま隣に置く。
- 並べの見本は決まった並び `GGDD/GGDC/WGCC/WWCC`（G=grass, D=dirt, C=cobble, W=water）で作られる。

## C. 小さな場面（`assets/c_scene.sprite.json`）
- 64×48。夜の路地の焼き芋の屋台（リヤカー型・提灯 1 つ・釜の煙突）。背景に建物の壁か塀。
- 動くのは **煙突から立つ湯気だけ**。スプライト `scene` に 6 コマ（`f0`〜`f5`）。湯気以外の画素は全コマ同じ。

## 絵にする道具（PIL 無しの python。DEVELOPER_DIR を前に付ける）
```
cd spikes/pixel-skill/<組>
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 ../render.py png assets/a_char.sprite.json ../out/<組>/a
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 ../render.py png assets/b_tiles.sprite.json ../out/<組>/b
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 ../render.py tiles assets/b_tiles.sprite.json ../out/<組>/b GGDD/GGDC/WGCC/WWCC --map G=grass,D=dirt,C=cobble,W=water
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 ../render.py png assets/c_scene.sprite.json ../out/<組>/c
```
出た PNG（8 倍）は Read で見られる。GIF は帯（`*.strip.png`）で見る。
色と形の検査は `../../../bin/fge px check assets/<名>.sprite.json`（門は `art/pixel.colorgate.json`）。
周は `../../../bin/fge rounds snap <名> assets/<名>.sprite.json assets/<名>.sprite.json` で残す（作業場のフォルダで流す）。

## 守ること
- ゲーム・Studio・Aseprite の窓を開かない。エンジンのコードは触らない。自分の組のフォルダと `out/<組>/` の外に書かない。
- 相手の組のフォルダ（`c1/` か `c2/` のもう一方）と `out/` のもう一方は見ない。
