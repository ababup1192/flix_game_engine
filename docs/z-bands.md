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

## ゲーム側の指針

- スコア・案内文・幕（モーダル）は `App.withHudView` に繋ぐ。world 側に文字を
  直書きすると高い z の絵に隠されうる（`bin/fge view` が匂いを警告する）。
- world の z を HUD の範囲（10 億）に自分で寄せない。範囲の仕切りはエンジンの仕事。
- z を数で決める所（`def zHero(): Int32 = 10`）は 1 つのパッケージで 1 ファイルに集める。
  散ると別のファイルどうしで同じ数を取り合い、どちらが手前かが描き順まかせになる。
  画面が増えて 1 ファイルに収まらなくなったら `ZOrder.flix` を表にして、他のファイルはそこから引く
  （`bin/fge z-table` がコミット時に警告する。全量は `make lint-z-table`）。
- 別の画面のモジュールが決めた z（`CardsView.zPickCard()` や `use CardsView.{zPickCard}`）を借りない。
  その z がどの帯・層の物かは貸した側にしか書かれておらず、貸した側が数を動かすと借りた側の前後も
  黙って変わる。要るなら表から自分で引く（これも `bin/fge z-table` が警告する）。
