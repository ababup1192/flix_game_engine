# まだ誰も使っていない部品

実装もテストもあるのに、`templates/` で採用ゼロ〜1 の部品。
**「無いから手組み」の前に必ず確認する。** 使い方は各ファイル冒頭の doc コメントが正。

| 部品 | 実体 | 1 行で何ができるか |
|---|---|---|
| `PxShade` | `engine_world/src/PxShade.flix` | 平らに塗ったドット絵に、ふち光・接地影・ディザ・地肌の粒を読み込み時 1 回だけ乗せる（走行コスト 0） |
| `FxDoc`（fx.json） | `engine_world/src/FxDoc.flix`、schema は engine リポの `docs/fx.schema.json` | パーティクルを JSON で宣言（Studio で調整できる）。手組みの `Fx.derive` から昇格させる |
| `Render.vgrad` / `gradPolygon` | `engine_world/src/Render.flix` | 空・水面・光の帯を頂点色つきポリゴン 1 枚で（1px の細い面を積む代替） |
| `Daylight` + `Calendar` | `engine_world/src/Daylight.flix`, `Calendar.flix` | 時刻 0..1 で空気色の幕・影の向きと長さ・ドット絵に当たる光の向きが回る（昼夜） |
| `Scatter` | `engine_world/src/Scatter.flix` | どこまでスクロールしても同じ配置になる撒き物（星・草・埃）を無限に |
| `Render.turned` / `turnedAll` | `engine_world/src/Render.flix` | 絵・集まりを傾ける（カードの傾き・振り子）。単位は回転数（1 周 = 1.0） |
| `Render.striped` / `checker` | `engine_world/src/Render.flix` | 縞・市松を面に重ねる（布・床・注意帯） |
| `Render.clipped` / `clippedAll` | `engine_world/src/Render.flix` | 矩形で切り抜く（スクロールの表示範囲・小パネル・のぞき穴） |
| `Color.warm` / `cool` | `engine/src/core/Color.flix` | 光側を暖色・影側を寒色へ近づけて階調を増やす |
| `App.withPixelSnap` / `withSpriteAtlases` | `engine_world/src/App.flix` | 画素の升目に載せて輪郭をにじませない / ドット絵を 1 枚に生成して 1 体 = 1 クアッド |
| `Mirror` | `engine_world/src/Mirror.flix` | ドット絵の映り込み（鏡・ガラス・磨いた床） |
| `Material` の SurfaceFx | `engine_world/src/Material.flix` | チップ絵なしで地形に質感（粒・きらめき・鱗・泡・発光・染み） |
| `RawDraw.star` / `ellipse` / `sector` / `ngon` | `engine_world/src/RawDraw.flix` | 星・楕円・扇・正多角形。**box と circle の 2 択で我慢しない** |
| `UiShape` | `engine_world/src/UiShape.flix` | ui.json の中に circle / star / line をパラメトリックに置く |
