# 描画の部品（Render・ZStack・層・図形・文字・切り替え）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| 箱や丸を並べて物・キャラを作りたくなった | PxSprite（+PxShade）/ gradPolygon / Terrain。RawDraw は下地とデバッグ用 |
| 描画物を矩形で切り抜く（スクロールの表示範囲・PiP。スクリーン空間） | Render（clipped / clippedAll）（実例: `templates/novel-starter/src/View.flix`） |
| 画面を覆う・晴らす切り替え演出（フェード・ワイプ） | Transition |
| 絵を傾ける・集まりを丸ごと傾ける（カードの傾き・振り子） | Render（turned / turnedAll）/ ui.json の rotation |
| スプライトが無い・読めないとき仮色の板にする（穴を開けない） | RawDraw.orBoxAt |
| 置き場所つきの絵に修飾を掛ける・列を丸ごと薄くする | Render.overItem / Render.fadeAll |
| 修飾パイプの末尾で置き場所を与える（`{ at = …, item = … }` の糖衣。中心置きは At 族） | Render.at |
| 列を丸ごと動かす・pivot 不動点で一様に拡縮する（Clipped の切り抜き矩形も追随） | Render.movedAll / Render.scaledAllAround |
| 太さのある線・棒を引く（法線を手計算しない） | RawDraw.lineSeg / Quad.strip |
| 文字を中央に置く・幅を測る | TextDraw.centered / TextDraw.width |
| 箱に枠線を付ける（半透明の枠も） | Render（outline / outlineA） |
| 同じ絵を色だけ変えて使い回す | Render.tinted |
| 部品の集まりを丸ごと手前・奥へ動かす | ZStack.of に積む順・ZStack.topLayer |
| 画面ごと動かす・縮める・薄める・切り抜く（中から手前の層へ送った物にも掛ける） | ZStack.mapItems(Render.scaledAllAround / movedAll / fadeAll …) |
| 画面を素材にする・複数光源・残像を作る（レンダーターゲットに描いてテクスチャとして貼り戻す） | Pass（`App.withPasses`）。ターゲットは design 解像度・宣言順に本編より先に描かれ、`Render.sprite(name, z)` で貼れる |
| Pass を描き出し（HeadlessRender の PassSpec）へ詰め替える（Shader 面の外し忘れを防ぐ） | Render.passSpecOf |
| 全面でない面（横長のストリップなど）から pass を等倍・鏡像で読む（陽炎・水面の映り込み） | Render.passStripDy（Shift の dy 場を作る） |

## モジュール 1 行紹介

- **Render** — 「何をどう見せたいか」だけ書いた Item を、描画部が食べられる形に変換する。
- **RawDraw** — 単色ベタの図形プリミティブ（box / circle / star / ellipse / sector / ngon など）。材料であって、View に直接並べる完成品ではない。正当な用途は HUD 下地・デバッグ描画・fail-open の仮板。
- **ZStack** — 描く順を「積んだ順」で決める木（leaf / of / zIndex / topLayer / mapItems）。z の数は葉の中の小さな前後（0..31）だけ。
- **SortingLayer** — 画面全体の層を名前で宣言する表（trait。ゲームが enum の instance で範囲を書く）と、層ごとの ZStack の木を 1 本の絵の列にする compose。区画を越えたら天井で止め、ViewCtx#warnOnce で 1 回だけ知らせる。
- **TextDraw** — 文字列を「中心をここに置きたい」で配置する。
- **RichText** — 一部だけ色や太さの違う文章をスパンの列として持ち、描画アイテムへ組む。
- **Quad** — 回転した矩形や太さのある線の、四隅の座標を計算する。
- **Bezier** — ベジエ曲線の平坦化と、曲線から作る描画部品。
- **Transition** — 進行度 t から画面を覆う/晴らす描画物を作る（フェード・ワイプ）。

## 矩形だけの画面から脱する（絵の下限）


`RawDraw.box` を並べただけの画面は未完成。求めるのは次の 4 つの**性質**で、**どの画風で
満たすかは自由**（画風はゲームごとに決める。詳しくは `docs/art-ref/visual-dict.md`、
シェーダーの語彙は [shader-doc.md](../shader-doc.md)）。下は手の一例。

| 満たす性質 | 手の例 |
|---|---|
| 面に階調か質感がある | ShaderDoc + Render.shaderFill / Render.vgrad・gradPolygon / Material（粒・きらめき・染み）/ Render.striped・checker / PxShade のディザ |
| 主役が背景から分離して読める | PxShade（ふち光・接地影）/ Render.glowAt / Render.outline / 明度差・色相差 |
| 層が分かれている（奥・主役・手前） | ZStack（積んだ順で描く木）+ SortingLayer（画面全体の層の表と compose）/ Transition の覆い（docs/z-bands.md「表は根・中は木」） |
| 時間が流れている | Fx・FxDoc（粒）/ Sway（揺れ）/ Anim（コマ替え）/ Scatter / Daylight |

光と影で色そのものを分けたいときは **Color.warm / Color.cool**。
