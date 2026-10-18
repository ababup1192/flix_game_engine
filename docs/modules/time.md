# 時間と動き（Timeline・Tween・ヒットストップ・長押し・時計）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| 値を滑らかに動かす（tween・補間） | EcsTween / Curve |
| 整数を 1 つずつ動かす（数え下がり・数え上がり・巡って止まるルーレット） | EcsTween（steppedInt） |
| 演出の時刻表（動き・効果音・待ちを 1 本に書く。拍・小節で書いて秒はテンポから。音を絵と同じクリップに付ける） | Timeline（build / buildOrPanic / append / join / atEndOf / insert / withSound / waitFor → stateOf / progressOf / soundsOn / soundsBetween。手順は `engine_world/src/Timeline.flix` 冒頭） |
| 演出の長さ・待ち・溜めの目安（窓の出入り 200〜300ms・待ちは 1 秒まで・溜めは 15F・音と絵のずれ） | docs/pacing.md（目安の表と出典。曲に乗る演出は拍へ読み替えて Timeline に書く） |
| ポーズ・メニューで止める・ゆっくりにする・ヒットストップで音が鳴り直す・止めても動く物（点滅・雨）を分ける | Clock（型で分けた時計 Clock[c] / Time[c]・Clock.Run / Pace / withSlow）+ App.addClock・実時間は frame#realNow（docs/clock.md。実例: `templates/platformer-starter`・`templates/novel-starter`） |
| 途中で始まる演出（起点の時刻を World に持つ）の音と進みを、同じ時刻表から引く | 時計を使うゲームは Timeline.soundsOnClock(時計, 起点, 表) / progressOn(時計, 起点, タグ, 表)（実例: `templates/novel-starter/src/LampFx.flix`）。秒を World に持つゲームは Timeline.soundsSince(起点, 前の時刻, 今の時刻) / progressSince(起点, 今, タグ) |
| 曲に乗せる（次の小節の頭まで伸ばす・頭から n 拍目まで・次の小節の頭の n 拍前） | Timeline（Duration.ToNextBar / ToBeat / ToPickup。テンポは Timeline.tempo に譜面の bpm を渡す） |
| ヒットストップ・スローモーション（hitstop・ゲームの時計を一時的に遅くする） | TimeScale |
| 長押しで決める・飛ばす（会話のスキップ・消去の確認） | HoldPress |
| 一続きの振り付け(歩く→拾う→戻る)の現在区間を時刻から引く | Timeline（build の append で並べ、stateOf / progressOf で引く） |
| 経路(脚の列)の現在地・歩き量・到着を時刻から引く | Journey（実例: `templates/rpg-starter/src/World.flix`。住人巡回） |
| イベントシーン(カット列)を世界の状態を見ながら順に演じる | SceneSeq |
| 一定間隔で合図を出す・残り時間を数える | Clock（実例: `templates/rpg-starter/src/World.flix`） |
| 一過性演出（発火→寿命）の経過・進行・生存を時刻から引く | Lifetime（時計の型つきは Span[c] と fireOn / progressOn / aliveOn / remainingOn） |
| ゲームの中の時計と暦を回す（分・時・日・季節・年） | Calendar |

## モジュール 1 行紹介

- **Calendar** — ゲームの中の時計と暦。実時間の秒を分・時・日・季節・年へ換算し、日またぎを合図する。
- **Clock** — 経過時間を貯めて「一定間隔で合図」「残り時間を数える」を数値だけで扱う（tick / countdown）。もう 1 層は型で分けた時計: Time[c]（時計 c で測った時刻）と Clock[c]（今と前のフレームの時刻）。違う時計の時刻を混ぜると型検査が止める。ゲームの時計は App.addClock で宣言し、App が毎フレーム 1 回進める（止める理由 Run・ヒットストップ Slow は World から Pace で宣言）。実時間は frame#realNow。
- **Lifetime** — 一過性のもの（発火して時刻で進み寿命で消える）の「誕生時刻＋長さ」から経過・進行(0..1)・残り・生存を now の純関数で導く。得点ポップ等の表示期間や Fx.Burst の寿命に使う（now から導くので巻き戻しに強い）。
- **Curve** — 時間や進行度から、放物線の山・周回・揺れなどの値を計算する、状態を持たない小さな関数の詰め合わせ。
- **EcsTween** — 値をある値から別の値へ、時間をかけて滑らかに動かす（補間する）。整数を 1 つずつ動かすのは steppedInt（数え下がり・ルーレット）。
- **Journey** — 脚(出発点・行き先・速さ)の列を「時刻の純関数」で歩く。到着判定(done)と絵の位置(pos)を同じ戻り値で返す。
- **Motion** — 物の動かし方の小さな道具箱（等速移動と往復運動）。
- **Timeline** — 演出の時刻表。動き・効果音・待ちを 1 本に並べ（append / join / atStartOf / atEndOf / insert = 決まった時刻 / withDelay / waitFor）、長さは秒・拍・小節と ToNextBar / ToBeat / ToPickup（次の小節の頭の n 拍前）で書く。build が秒の表を組み、書き間違い（同じ名前・前方参照・待ちに音など）は Err。描く側は stateOf / progressOf、鳴らす側は soundsOn（Enter / Play / Seek・二分探索。待ちの無い表は soundsBetween(前の秒, 今の秒)）で同じクリップを読む。待ちは playheadOf / resume。組んだ表のクリップは clipOf / clipsOf（Clip）で引く。履歴・巻き戻しは Worldline（別物）。
- **TimeScale** — ヒットストップ・スロー。合図からの実秒で「止める → 遅く流す → 等速へ戻す」を決め、毎フレームの dt を gameDt で直す（ゲームの時計ごと遅くする）。光や揺れは realAt の実秒で動かせる。
- **HoldPress** — 長押しで決める。押している間だけ秒を貯め、満ちたフレームで 1 回だけ合図、合図の後は離すまで貯めない。押した瞬間の拍そのものは InputEdge。
- **SceneSeq** — カット列の逐次シーケンサ骨格。perform（カットを 1 コマ演じる）と idle（尽きたあと時間だけ流す）を注入し、Skip・打ち切りは notes に残す（fail-open だが無音ではない）。

## 進行 4 抽象の分業（どれも「列を順に消化する」が、決め手が違う）

| 抽象 | 決め手 | 向く場面 |
|---|---|---|
| Timeline（build） | 尺が既知（待ちは waitFor で挟める）で拍が重なってよい。絵と音を同じクリップから引く | 振り付け（歩く→しゃがむ→戻る）・演出の時刻表（WARNING → カットイン → ターン 1・会話の窓・連鎖） |
| Journey | 脚の列（出発点・行き先・速さ）の時刻純関数 | 経路の現在地・到着判定 |
| Replay | 入力が固定。入力列を tick へ流す再生 | プレイの再現・自動操作 |
| SceneSeq | 世界を見て尺が決まる再生。終わりは世界の状態から判定 | イベントシーン（カット列） |
