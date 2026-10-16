# z-index の範囲の地図（どの zIndex が何用か）

重なり順（zIndex）は 1 本の数直線だが、用途ごとに範囲で仕切ってある。
数の source of truth はコードの `ZBand`（engine/src/core/ZBand.flix）。この文書はその地図。

| 範囲の名前 | z の範囲 | 用途 | 決め方 |
|---|---|---|---|
| world | 0 〜 数百（慣習） | 背景・キャラ・エフェクトなどゲームの絵 | ゲームが自由に決める。`Depth` が使う範囲もここに入る |
| UI layer | layer × 10000 | ui.json の root ごとの層（`CanvasLayer.layerStride`） | UiRender が layer から加算する |
| Transition | 100000 | 画面を覆う切り替え演出の既定（`Transition.defaultZ`） | UI より手前・HUD の範囲より奥 |
| HUD の範囲 | 1,000,000,000 〜 +99,999,999 | `App.withHudView` の絵 | `composeScene` が `ZBand.liftHud` で持ち上げる。ゲームが書く z は 0..99,999,999（はみ出しは clamp・wrap しない） |
| エンジンデバッグの範囲 | 2,000,000,000 〜 +10 | fps・矩形注釈・トースト・スクラブ表示（Annotate） | エンジン専用。ゲームは使わない |

## 守られること

- **HUD は world に隠されない**: world がどれだけ大きい z（爆発 z=1000 等）を使っても、
  withHudView の絵は必ず手前。HUD の中の前後だけを HUD 側の z が決める。
- **デバッグ表示は何にも隠されない**: F8 の注釈・fps は HUD よりさらに手前。
- **速さは落ちない**: 範囲が混ざるフレームは描画部（render_gl の `mergedByZ`）が
  範囲番号で 2 段階に分けて並べ替え、スロット方式（counting sort）のまま処理する。

## 表は根・中は木（SortingLayer × ZStack）

z の数を決める所は 4 段に分ける（エンジンの範囲・画面全体の層・層の中・部品の中）。重なる所は 1 つにする。

| 段 | 何が決める | 置き場 |
|---|---|---|
| エンジンの範囲（world / UI / Transition / HUD / デバッグ） | 上の表（`ZBand`） | エンジン |
| 画面全体の層（場面・会話・確認・指している物・切り替え / HUD の中の区画） | `SortingLayer` の表（名前と範囲） | ゲームの `ZOrder.flix`（`instance SortingLayer[層の enum]`） |
| 層の中（場面の絵・窓・部品の並び） | `ZStack` の積んだ順（`of`・`zIndex`） | View が木を返す |
| 部品の中（胴 0・頭 1・持ち物 2） | 葉（`leaf`）の中の小さな z（0..31） | View |

```flix
// View は木を返す（z の数を書かない）
ZStack.of(leaf(veil) :: leaf(stands) :: leaf(frame) :: leaf(picture) :: leaf(chrome) :: Nil)
// 根で層ごとの木を 1 本の列にする（各層の底から詰める）
SortingLayer.compose(ctx, (Layer.Scene, scene) :: (Layer.Talk, talk) :: Nil)
// 場面の奥から出す説明の窓だけ、手前の層へ送る
ZStack.of(leaf(cards) :: ZStack.topLayer(Layer.Pointer, leaf(tipWindow)) :: Nil)
// 見下ろしの足元の順（1 人 = 1 つの子）
ZStack.of(people |> List.map(p -> ZStack.zIndex(Depth.orderAt(p.footY), leaf(p.parts))))
// 画面ごと動かす・縮める・薄める・切り抜く（中から送った物にも掛かる）
ZStack.mapItems(Render.scaledAllAround(1.0 + bump, center), tree)
```

- **1 部品 = 1 葉から始める。** 葉を割るのは「前の葉の最大 z < 次の葉の最小 z」を確かめてから。
  同じ z だった物を割ると、描画部の種類順（tiles → sprites → polygons → static → surfaces）が積んだ順に変わる。
- **z の付け替えをしない。** 移す・縮めるは `mapItems`（z を付け替える公開の関数は 0.35.24 で消した。残るのは木で書けない演出のための `ZLegacy` だけ）。
- **必ず手前の物は `topLayer(層, …)`。** z を大きくして手前に出さない。world（`Layer`）と HUD（`HudLayer`）は
  型が違うので、またいで送れない。送り元より奥の層へは送れない（送り元の手前に置いて知らせる）。
- **区画を越えたら止めない。** 天井で止め、`ViewCtx#warnOnce` で層の名前ごとに 1 回だけ知らせる。
  描き出しはこの口に集まった文面で止める（ゲームが `{ warnOnce = 集める口 | ctx }` で差し替える）。
- **木で書けない所だけ `ZLegacy`**: 描き上がった 1 フレームを丸ごと加工する演出（裂く・物ごとに 1 段上へ影を重ねる）のように
  葉の前後では書けない物は、`ZLegacy.rawZ(層, 段)` と `ZLegacy.zShiftedAll` で z の数を直に書く。ゲームから呼ぶと `bin/fge forbid`（zlegacy）が止めるので、`forbid.local.json` の除外に「なぜ木で書けないか」を 1 行。
  古い名前（`SortingLayer.z`・`Render.zShiftedAll`）と、消した物（`leafAbsolute`・`Depth.place` / `Bands` など）の置き換えは `docs/migrations/0.35.24.md`。
- **葉の中の z は 0..31 に収める（決まり。コードでは縛らない）。** 葉は中の z の幅をそのまま使うので、古い z=900 のままの葉は 901 段を使い、区画を越えて知らせが出る。
  名前を付けるなら葉を作るファイルに `def zText(): Int32 = 2` と書いてよい（表を持つパッケージでも、`bin/fge z-table` は表の外の 0..31 を止めない。32 以上と負の数は止める。範囲は `bin/lint-rules/z-table.json` の `leafZRange`）。
- **使い回し（キャッシュ）は入れない。** 木は毎フレーム組んで捨てる。費用は O(絵の数 + 節の数 × log + 送った物の数 × log)（log は zIndex と送り先の並べ替え）。mapItems は入れ子 1 段ごとに中の絵を 1 回ずつ写す（今の Render.*All と同じ）。

## ゲーム側の指針

- スコア・案内文・幕（モーダル）は `App.withHudView` に繋ぐ。world 側に文字を
  直書きすると高い z の絵に隠されうる（`bin/fge view` が匂いを警告する）。
- world の z を HUD の範囲（10 億）に自分で寄せない。範囲の仕切りはエンジンの仕事。
- z を数で決める所（`def zHero(): Int32 = 10`）は 1 つのパッケージで 1 ファイルに集める。
  散ると別のファイルどうしで同じ数を取り合い、どちらが手前かが描き順まかせになる。
  画面が増えて 1 ファイルに収まらなくなったら `ZOrder.flix` を表にして、他のファイルはそこから引く
  （`bin/fge z-table` がコミット時に警告する。全量は `make lint-z-table`）。
- 別の画面の部品を重ねたいときは、その画面の z の関数を借りずに、部品の列か木（`ZStack.Node`）を受け取って
  自分の木に積む。部品の中の z を外から動かしたいときは、部品の関数に z を引数で渡す。
- z を後から付け替えない（`z -> z / 4` で縮めると、付け替えた後の z がどの層に入るかが表から読めなくなり、
  他の層を越える）。層・帯の段から作り直す。
