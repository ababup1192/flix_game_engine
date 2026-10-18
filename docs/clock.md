# 型で分けた時計（Clock[c] / Time[c]）

ゲームの時刻を「どの時計で測ったか」の型つきで持つ仕組み。API は `engine_world/src/Clock.flix` の冒頭、
ゲームへの繋ぎ方は `App.addClock` の doc、手本は `templates/platformer-starter`（ポーズ・ヒットストップ）と
`templates/novel-starter`（メニュー）。

## 何を解くか

ゲームには進み方の違う時計が何本かある。

| 時計 | 止まるとき | 読む物の例 |
|---|---|---|
| 実時間 | 遊びでは止まらない（F8 のデバッグ停止とリモートのコマンドを処理したフレームは進まない） | ポーズメニューの点滅・背景の雨・ヒットストップの白い光 |
| 遊びの時計 | ポーズ・メニュー・ヒットストップ（遅くなる） | 主役と敵の動き・パーティクルの寿命・演出の時刻表と効果音 |
| 物語の時計（ノベル） | メニュー・バックログを開いている間 | 文字送り・演出の時刻表 |

どの時計の時刻も中身は秒の `Float64` なので、取り違えてもコンパイルが通る。誤りは遊んで初めて見つかる:
「ポーズ中もパーティクルが薄れる」「メニューから戻ると効果音がもう一度鳴る」「ヒットストップ中に光が止まる」。

`Clock.Time[c]` と `Clock.Clock[c]` の `c` は時計の名前の型で、違う時計の時刻を引く・比べる・同じ寿命や
時刻表に渡すと型検査が止める（E7491）。時計を型で分けるのは Bevy の `Time<Real>` / `Time<Virtual>` と同じ考え
（ここでは時計が `Clock[c]`、時刻が `Time[c]`）。

## 形

- **実時間** — `Clock.Time[Clock.Real]`。App が毎フレーム `frame#realNow` で配る。ゲームは実時間の時計を
  持たないので、時計を止める・2 回進める書き方は無い（World へ写すときに古い値を写し続ける、のような書き方までは止まらない）。View で読むなら系で World の欄へ写す（`{ realNow = frame#realNow | w }`）。
- **ゲームの時計** — 名前はゲームが空の enum で作る（`pub enum Play`）。`Clock.Clock[Play]` を World の欄に置き、
  `App.addClock({ clockOf, withClock, paceOf })` で宣言する。進めるのは App で、系（addSystem）より先に
  実フレームにつき 1 回だけ進む。系は `Clock.dtOf(w#play)` で遊びを進め、`Clock.nowOf(w#play)` で今を読む。
- **止める・遅くする** — ゲームは `paceOf: World -> Clock.Pace[c, r]` で宣言するだけ（`withSustained` と同じ
  「World から宣言を導き、App が適用する」形）。`Clock.Run` は `Running` / `Scaled(k)` / `Paused(r)`
  （`r` はゲームが決める止める理由の enum）、ヒットストップは `Clock.withSlow(合図の時刻, TimeScale.Plan)`。
  スローは合図からの**その時計の**秒で決まるので、ヒットストップ中にポーズしても戻れば続きから流れる。
- **寿命** — `Lifetime.Span[c]` と `fireOn` / `progressOn` / `aliveOn` / `remainingOn`（今の時刻 `Time[c]` を受ける。
  実時間の寿命は `frame#realNow` から）。
- **時刻表** — `Timeline.soundsOnClock(時計, 起点, 表)` は鳴らす区間 `(prev, now]` を時計から取るので、古い prev を
  渡せない。止めていたフレームは区間が空で、戻っても鳴り直さない。描く側は `Timeline.progressOn(時計, 起点, タグ, 表)`。
  止めている間に置いた起点は頭（0 秒）の音が鳴らない。止めている間に始める演出（ポーズメニューを開く）は実時間で
  `Timeline.soundsBetweenTimes(起点, { before = ws#before#realNow, after = ws#after#realNow }, 表)`。
  スローの Plan の秒は `Scaled(k)` を掛けた後の秒で数えるので、`Scaled(0.25)` と重なるとヒットストップは実時間で 4 倍に伸びる。
- **秒へ戻す** — `Clock.secondsOf` は周期の関数（`Anim.frameAt`・`Sway.wave`・`Fx.derive`）に渡す所だけ。
  差は `Clock.since(起点, 今)`、前後は `Time` のまま `<` `>` で比べ、ずらすのは `Clock.after(秒, 時刻)`。
- **起点の値** — `Clock.zero()`（時計の頭）・`Clock.never()`（まだ起きていない出来事。値はずっと昔なので、どの今から見ても
  演出が終わった過去になる）。描き出しとテストで決まった瞬間を撮るときだけ `Clock.startAt(秒)` と `Clock.after(秒, Clock.zero())`
  （src で数から時刻・時計を作ると、別の時計の時刻へ付け替えられる。`clock-made-time` が止める）。

```flix
pub enum Play
pub enum Halt { case PauseMenu }

// World の欄: play = Clock.Clock[Play]・hitAt = Clock.Time[Play]・realNow = Clock.Time[Clock.Real]

pub def paceOf(w: World): Clock.Pace[Play, Halt] =
    Clock.paceOf(if (isPaused(w)) Clock.Run.Paused(Halt.PauseMenu) else Clock.Run.Running)
        |> Clock.withSlow(w#hitAt, hitstopPlan(w))

app |> App.addClock({ clockOf = w -> w#play, withClock = (c, w) -> { play = c | w }, paceOf = World.paceOf })
    |> App.withAudio(ws -> Timeline.soundsOnClock(ws#after#play, ws#after#cueAt, Cue.timeline()))
```

### soundsSince と soundsOnClock

`Timeline.soundsSince(起点, 前の秒, 今の秒, 表)` は秒を World に持つゲームの関数（前後の秒は `withAudio` の
before / after から渡す）。`soundsOnClock` は `App.addClock` で時計を進めるゲームの関数（前後の秒は時計が持つ）。
時計を使い始めたプロジェクトでは、lint が `soundsBetween` / `soundsSince` / `progressSince` を止める。

## ジャンルごとの使い方

| ジャンル | 時計 | 止める・遅くする |
|---|---|---|
| アクション（platformer） | 遊び（`Play`）・実時間 | ポーズで `Paused`、踏みつけで `withSlow`（ヒットストップ）。光と点滅は実時間 |
| ノベル | 物語（`Story`）・実時間 | メニューで `Paused`。雨・炎の揺らぎ・メニューの点滅は実時間 |
| RPG・カードバトル | 戦い（`Fight`）・実時間 | 情報のウィンドウ・確認のウィンドウで `Paused`、説明を読む間は `Scaled(0.25)`、とどめで `withSlow` |
| パズル（落ち物） | 遊び・実時間 | ポーズで `Paused`。消えた列の演出の時刻表は遊びの時計で鳴らす |
| レース・リプレイ | 遊び・実時間 | リプレイのスロー再生を `Scaled(k)`、ゴールの瞬間を `withSlow` |
| リズム | 曲の時計は音の再生位置から取る（この仕組みの外） | 遊びの時計で曲の時刻を測らない（音とずれる） |

時計が 2 本要る（戦いと物語のように別々に止まる）なら `App.addClock` を 2 回呼ぶ。宣言の順に進む。

## 止まる誤りと止まらない誤り

試し（engine の spike/typed-clock）で platformer とノベルに当て、違う時計の時刻を混ぜる誤り 9 件がすべて
E7491 で止まり、型の無い形では全部通った。今の形で止まる見本は `testdata/lint/clock-types/mixing-stops`
（`sh testdata/lint/run.sh testdata/lint/clock-types/mixing-stops`）。

**型検査が止める物（E7491）**

1. 遊びの時計で生まれた寿命を、実時間の今で読む（ポーズ中も薄れる）
2. 遊びの時刻と実時間の今を比べる
3. 合図からの秒を、別の時計の今で測る
4. 時刻表の起点と、区間を持つ時計が違う（`soundsOnClock`）
5. 描く側の進みを、起点と違う時計で読む（`progressOn`）
6. 実時間の今を、遊びの時刻の欄にしまう
7. 実時間で生んだ寿命を、遊びの寿命の列に足す
8. ヒットストップの合図に、別の時計の時刻を渡す
9. 時計の欄に別の時計を書き戻す

**試しで止まらなかった物と、その塞ぎ方**

| 止まらなかった物 | 塞ぎ方 |
|---|---|
| `secondsOf` で秒へ戻してから引く・比べる・`after` で包み直す | lint-forbid の `clock-seconds-leak`（同じ行の形を見る。秒を返す自前の関数を挟む・行をまたぐ・括弧が 3 重より深い・2 つの秒を同じ関数に渡す（`Float64.max`）・型の無い古い API（`Lifetime.fire`）へ渡す形は見えない） |
| `Clock.after(Clock.since(Clock.zero(), 遊びの今), Clock.zero())` で別の時計の時刻へ付け替える・`Clock.startAt` で時計を手で進める | `clock-made-time`（src の `Clock.after(.., Clock.zero())`・`Clock.since(Clock.zero(), ..)`・`Clock.startAt`。render/ と test/ は見ない） |
| 同じフレームに時計を 2 回進める（1 回目の区間の音が消える） | 進めるのは App だけ（`App.addClock`）。ゲームのコードの `Clock.advance` / `App.tickClocks` は `clock-advance` が止める（test/ は見ない）。同じ欄を `addClock` で 2 回宣言する形は止まらない |
| 実時間の時計を止める | 実時間は App が `frame#realNow` で配り、ゲームは時計を持たない。`Clock[Real]` と書くと `clock-real-clock` が止める |
| 旧 `soundsBetween` に古い prev を渡す | `soundsOnClock` は区間を時計から取る。`App.addClock` のあるプロジェクトの `soundsBetween` / `soundsSince` / `progressSince` は `clock-old-sounds` が止める |
| `frame#dt` で遊びを進める（ポーズしても動く） | 機械では止めない（実時間で動かす物もある）。`App.addClock` の doc と手本で `Clock.dtOf` を使う |

## Flix で書くときの注意

- **`enum Stamp[_: Type](Float64)` の `[_: Type]`** — 型引数が中身に出てこない enum は、名前を付けると
  E8518（使っていない型引数）で止まる。名前を `_` にし、種は推論できないので `Type` と書く。
- **時計の名前の enum は pub** — 中身の無い `enum Play` は一度も作られないので、pub でないと E8176
  （使っていない enum）で止まる。`pub enum Play` の 1 行でよい。
- **欄の名前の衝突** — 時計の欄の名前が World の既存の欄と重なることがある（ノベルの `story` はシナリオの Doc）。
  その時は `storyClock` のように時計と分かる名前にする。時計の名前の型（`Story`）と欄の名前は別の物。
- **`run` は予約語** — `Pace` の欄が `mode` なのはこのため。

## テスト

- 決まり（止めて戻しても・スロー中でも音は 1 回・止めている間も実時間は進む）は `App.trace` で
  実機と同じ経路を流して確かめる（手本 `engine_world/test/TestClock.flix`・`templates/novel-starter/test/TestTrace.flix`）。
- 系を直に呼ぶテストは、先に `App.tickClocks(app, dt, w)` で実機と同じ 1 回の進みを組む（lint は test/ を見ない）。
- 時刻を手で置くときは `Clock.startAt(秒)` と `Clock.zero()`。`Clock.after(秒, Clock.zero())` で決まった時刻も作れる。
