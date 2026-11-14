# まだ誰も使っていない部品

実装もテストもあるのに、採用がゼロ〜1 の部品。
**「無いから手組み」の前に必ず確認する。** 使い方は各ファイル冒頭の doc コメントが正。

数は、テンプレ 4・bench 6・実際のゲーム 19 の計 29 フォルダの src と test を字で数えた物（2026-11-14・`plans/webgpu/analysis-render-structure.md` の §3）。
3D の場面と post process の部品は [reference-3d.md](reference-3d.md)。

## 今も使用 0〜1（載せただけでは広まらなかった物と、名前から引けない物）

| 部品 | 使用 | 実体 | 1 行で何ができるか |
|---|---|---|---|
| `Scatter` | 0 | `engine_world/src/Scatter.flix` | どこまでスクロールしても同じ配置になる撒き物（星・草・埃）を無限に |
| `FxDoc`（fx.json） | 0 | `engine_world/src/FxDoc.flix`、schema は engine リポの `docs/fx.schema.json` | パーティクルを JSON で宣言（Studio で調整できる）。手組みの `Fx.derive` から昇格させる |
| `Material` の SurfaceFx | 0 | `engine_world/src/Material.flix` | チップ絵なしで地形に質感（粒・きらめき・鱗・泡・発光・染み） |
| `Render.masked` | 0 | `engine_world/src/Render.flix` | 絵を多角形で型抜きする（ガラス片・ちぎれた紙） |
| `Render.spriteFlipped` | 0 | `engine_world/src/Render.flix` | スプライトを左右・上下に反転する（キャラの向き）。`Render.flipH` は頂点の列用で別の物 |
| `Light.items` / `singleLightItems` / `multiLightItems`・`LightDoc` | 0 | `engine_world/src/Light.flix`, `LightDoc.flix` | 2D の暗い画面に光源を置く（全面の翳り + 光の輪）。Doc から読む形もある |
| `Light.lightMapPass` | 1 | `engine_world/src/Light.flix` | 光を Pass に Add で集めて Multiply で本編に掛ける光マップ |
| `Daylight` + `Calendar` | 1 | `engine_world/src/Daylight.flix`, `Calendar.flix` | 時刻 0..1 で空気色の幕・影の向きと長さ・ドット絵に当たる光の向きが回る（昼夜） |
| `Mirror` | 1 | `engine_world/src/Mirror.flix` | ドット絵の映り込み（鏡・ガラス・磨いた床） |
| `Render.striped` / `checker` | bench だけ / 1 | `engine_world/src/Render.flix` | 縞・市松を面に重ねる（布・床・注意帯） |
| `ShaderDoc.atWorld` | bench だけ | `engine/src/shader/ShaderDoc.flix` | 3D の material の模様（`fbm`・`worley`）を world の 2 軸の上で読ませる（uv の無い床や壁） |
| `Timeline` | 1 | `engine_world/src/Timeline.flix` | 演出の時刻表（動き・効果音・待ちを 1 つの並びに書く） |

## 数えていない物（前からこの表にあった物）

| 部品 | 実体 | 1 行で何ができるか |
|---|---|---|
| `Render.turned` / `turnedAll` | `engine_world/src/Render.flix` | 絵・集まりを傾ける（カードの傾き・振り子）。単位は回転数（1 周 = 1.0） |
| `Color.warm` / `cool` | `engine/src/core/Color.flix` | 光側を暖色・影側を寒色へ近づけて階調を増やす |
| `App.withPixelSnap` | `engine_world/src/App.flix` | 画素の升目に載せて輪郭をにじませない |
| `RawDraw.star` / `ellipse` / `sector` / `ngon` | `engine_world/src/RawDraw.flix` | 星・楕円・扇・正多角形。**box と circle の 2 択で我慢しない** |
| `UiShape` | `engine_world/src/UiShape.flix` | ui.json の中に circle / star / line をパラメトリックに置く |

## 広まった物（もう「使われていない」ではない。使い方は [reference.md](reference.md)）

`PxShade`（10 フォルダ）・`Render.vgrad`（11）・`Render.gradPolygon`（12）・`Render.clipped` / `clippedAll`・`App.withSpriteAtlases`。
この 5 つは表に載せた後に広まった。`vgrad`・`gradPolygon`・`PxShade` は、箱と円だけの View を止める lint と辞書が入った後に 10〜12 フォルダへ広がった
（止まった所で代わりの部品が示される物が広まり、表に載せただけの物は上に残っている）。
