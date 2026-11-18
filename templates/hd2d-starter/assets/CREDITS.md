# 素材の出典とライセンス

このテンプレートの絵（タイル・板の絵・キャラ）は、どれもこのテンプレートの元になった HD-2D の試作のために画像生成で作ったドット絵です。
外の素材集（Poly Haven の CC0 のテクスチャや 3D の形を含む）は使っていません。音のファイルは入っていません。
絵を差し替えたら、ここも書き直してください。

## 絵（画像生成のドット絵）

作り方はどれも同じです。

1. Codex CLI の画像生成（OpenAI の画像生成）に、共通の画風の言葉と、1 枚ごとの頼みを渡して生成する。
   - 画風の言葉（全部の頼みで同じ）: 既存のゲームや作品を写さない独自の絵・昼の南欧の港町・砂岩とクリームの石灰岩（#e2d8c4・#cfc3ac）・
     漆喰の白い壁・くすんだテラコッタの瓦（#8e5444）・オリーブとセージの緑・淡いティールの水・差し色の朱（#d0583c）は日除けと花だけ・
     光は淡い金（#fff0d6）・影は空の青紫（#84a0dc・一番暗い所 #4c5c98）で灰や黒にしない・1 画素の暗い焦げ茶の輪郭・2〜4 画素の塊で描く・字やロゴを入れない。
   - 板の絵（キャラ・小物・木・街灯）は、マゼンタの無地の背景の上に間を空けて並べた 1 枚で頼み、見下ろし 45° 前後の角度で描かせる。
   - タイル（地面・壁・屋根・水・生垣）は、四方へ継ぎ目なく並ぶ正面の四角をマゼンタの溝で区切った 1 枚で頼む。
   - 先に生成した絵（手本の町の 3 枚・旅人と商人の歩きの帯など）を、絵柄をそろえる参考として次の頼みに添える。
2. 生成した 1 枚から、マゼンタを抜いて 1 つずつ切り出し、32 画素 = 1 m になるように縮め、色を減らしてドットの大きさをそろえる（試作の道具の手作業の工程）。

| ファイル | 中身 | 頼みの元 |
|---|---|---|
| `tiles/ground_grass.png`・`tiles/ground_cobble_fine.png` | 草地・細かい石畳 | 地面のタイル |
| `tiles/wall_stone*.png`・`tiles/wall_plaster*.png` | 石積みと漆喰の壁（窓・扉つきは壁に開口の絵を重ねた物） | 壁のタイル・壁の開口 |
| `tiles/roof_tile.png` | 赤い瓦の屋根 | 屋根のタイル |
| `tiles/water_canal.png` | 水路の水 | 水のタイル |
| `tiles/cliff_rock.png`・`tiles/cliff_lip.png` | 段の側面の岩とふち | 崖の岩のタイル |
| `tiles/hedge_leaf.png`・`tiles/stone_cut.png` | 生垣の葉・縁石と台座の切り石 | 箱の形の物のタイル |
| `props3d/crate_front.png`・`props3d/crate_top.png` | 木箱の面（木箱の板の絵から切り出した物） | 小物 |
| `sprites/tree_broadleaf.png`・`sprites/tree_cypress.png` | 広葉樹・糸杉 | 木 2 本 |
| `sprites/street_lamp_ornate.png` | 3 灯の飾り街灯 | 街灯 |
| `sprites/traveler_td.png`・`sprites/merchant_td.png` | 町の人（旅人・商人の立ち姿） | 見下ろしのキャラ |
| `sprites/traveler_walk4.png`・`sprites/merchant_walk4.png`・`sprites/girl_walk4.png` | 隊列の 3 人の歩きの帯（背中・右・正面 × 4 コマ） | 見下ろしの歩き |
| `sprites/traveler_idle.png`・`sprites/merchant_idle.png`・`sprites/girl_idle.png` | 待機モーション（向きごとに 2 コマ。歩きの帯の足をそろえたコマの腰より上を 1 画素下げて作った物で、描き足していない） | 歩きの帯から作った物 |
| `sprites/market_stall.png`・`peddler_idle.png`・`balloon_kid_idle.png`・`balloon.png`・`townsman_idle.png`・`townswoman_idle.png`・`elder_idle.png`・`carriage.png`・`horse.png`・`dog.png`・`pigeon.png` | 広場の屋台・行商人・風船の子ども・立ち話の 3 人・馬車と馬・犬・鳩 | にぎやかな広場の人と物 |
| `sprites/barrel.png`・`crate_td.png`・`flower_pot.png` | 樽・木箱・植木鉢 | 小物 |

## 字

- PixelMplus10（`PixelMplus10-Regular.ttf`）— M+ FONT LICENSE。終了の確認の窓の字に使います。
