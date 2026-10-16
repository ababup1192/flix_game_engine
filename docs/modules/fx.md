# 粒と揺れ（Fx・FxDoc・Scatter・Sway）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| 粒（パーティクル・particle）を舞わせる | Fx / Scatter（実例: `templates/race-starter/src/World.flix`） |
| 疑似遠近のストリップ（横一列）ごとに立ち物・床を敷く | Scatter.strip（実例: `templates/race-starter/src/ViewScene.flix`） |
| 爆発・火花を fx.json で宣言して時刻から描く | FxDoc / Fx（sample / sampleAt）（実例: `templates/race-starter/assets/fx/spark.fx.json`） |
| 粒を輪に等分して撒く・破片を回しながら飛ばす | FxDoc（dir.mode: even / turn）（実例: `templates/race-starter/assets/fx/crash.fx.json` / `nitro-burst.fx.json`） |
| 蛍・湯気をその場でゆらゆら舞わせる | FxDoc（wobble） |
| 雨・火花・流星を速度方向の筋で描く | FxDoc（shape: streak / stretch） |
| 粒をふわっと明滅させる | FxDoc（カーブ pulse） |
| 撃つたびに出る効果を発生・寿命回収・描画で回す | Fx（burst / expire / drawAll）（実例: `templates/race-starter/src/World.flix`） |
| 揺れる演出を作る（浮遊・風のなびき） | Sway（実例: `templates/tetris-starter/src/View.flix`） |

## モジュール 1 行紹介

- **Fx** — たくさんの粒を、保存せず「今の時刻から計算」して並べる薄い仕組み。「撃つたびに出る」効果の器（burst / expire / drawAll）も持つ。
- **FxDoc** — fx.json（閉形式パーティクル）を Spec に読むパーサ。絵は Fx.sample が導く。語彙は mode: loop（常時系）/ spawn（発生源の広がり）/ accel（重力/風・½at²）/ seed（決定的シードの上乗せ）/ dir.mode: even（粒の番号で射出方向を等分 — 衝撃の輪・花火）/ turn（粒の傾き base・spread と回る速さ spin・spinSpread。単位は回転数で 1 周 = 1.0）/ wobble（位置の正弦揺らぎ amp・freq・vary — 蛍・湯気の有界運動）/ shape: streak + stretch（速度方向に伸びた筋 — 雨・火花・流星）/ カーブ pulse（1 と min の間の正弦明滅）/ parseWith（"@名前" の色キーをパレットで解決）。
- **Scatter** — どこまでスクロールしても同じ配置が再現される、無限の「物の撒き方」。field は見えている矩形を升目走査、strip は疑似遠近のストリップ 1 本（ストリップごとに見える幅が違う画面）を span + reach + cellsMax で敷き、画面外のセルは作る前に捨てる。fieldExcept は「ここだけ空ける」帯（主役の立つ帯・道・水面）をセル単位で落とす（落ちるセル以外は field と 1 個も変わらない）。
- **Sway** — 時刻から微小な揺れを作る純粋な道具（蓮の葉の浮遊・草や旗の風・吊るした物）。一様にずらせば浮遊（drift）、高さに比例して曲げれば根が止まって先だけしなる（wave）。掛け方は呼び側が決める。
