# e2e の手順 flow・始まりの登録簿・遊んだ記録（0.47.0）

試し（ゲームのブランチ `ababup1192/id-x-e2e` の `src/flow/`）を、エンジンの物にした。
手順は 1 行 1 手のテキスト `e2e/<名前>.flow`（Maestro の flow と `runFlow` に合わせた形）。
使い方の全文は `engine_world/src/Flow.flix` の冒頭。ゲームが書く物の手順は `docs/migrations/0.47.0.md`。

| | 足した物・変えた物 | 何を解くか |
|---|---|---|
| 0 | フレームを流す中心を `App.traceFrame` 1 本に（`Replay`・`ReplayScript` を消した） | 実機・trace・性質テスト・/step・手順で 1 フレームの中身が食い違う |
| 1 | `Frame#padTouched`・`App.withCursor`・`App.addOutput`・`App.withDocTable` | 毎フレームの系が IO を持つと、/step や手順を流すだけでセーブが書かれる |
| 2 | `App.withStarts`（`START`・`GET /starts`・`POST /start`・`App.startOrBug`） | 好きな場面から起動・テスト・手順を始める場所が、動画ごとの手組みに散る |
| 3 | `Flow`（読み手・実行器・`bin/fge flow check`）・`App.withFlow`・/step の文法 | 動画とテストの手順を Flix で書くと、直して確かめる 1 回が 30〜100 秒かかる |
| 4 | 記録（`debug/flow-record/latest.flow`）・`App.withFingerprint` | 遊んで出た不具合を、その通りに再生して最初に食い違ったフレームを指す |

## 0 実行器を 1 つに

1 フレームの中身（実時間の時計 → `addClock` の時計 → 系（固定刻みならその回数）→ 一発の音と鳴り続ける音を導く）は `App.traceFrame` だけが持つ。
実機の `launch`（Running のフレーム）・`trace`・`PropertyTest`・手順の実行器・リモートの `/step` は、どれも `traceFrame` を呼ぶ。
Doc の読み直しは `traceFrame` の手前で同じ関数（watchFile・reloadOn の関数）を当てる —— 実機は保存とキーで、記録の再生は `reload` の行で。

**決めたこと:**
- `/step` は固定刻み（`withFixedStep`）を見るようになった。前は「手順 1 行 = 系 1 回」にするために見ていなかったが、
  それだと固定刻みのゲームだけ /step と実機で進み方が違う。手順の 1 フレームは実機の 1 フレームと同じ物にする。
- `/step` の中で系が直に鳴らす音（`GameEngine.Audio`）・直に読むキーは差し替えない。入力は Frame から、音は withAudio から読む決まりなので、
  差し替えの代わりに 1 の外出しで系から IO を抜く。
- `Replay`（engine_world）と `ReplayScript`（engine_tools）は使う所がエンジンのテストだけだったので消した（移すより消す）。

## 1 IO を毎フレームの処理の外へ

系（`addSystem` / `App.game` の update）は純粋に書ける形にそろえ、外へ出す物は App の口で宣言する。

| 口 | いつ App が触るか | 例 |
|---|---|---|
| `Frame#padTouched` | 毎フレーム読む（`GameEngine.Game.isGamepadTouched`） | 案内のキーの絵をパッドのボタンへ替える |
| `Frame#padKind` | 毎フレーム読む（`GameEngine.Game.gamepadKind`。つないだ時に 1 回だけ GLFW から決める） | 案内のボタンの絵をパッドの機種で替える（[gamepad.md](gamepad.md)） |
| `App.withCursor(w -> CursorSpec)` | 毎フレームの宣言。変わったフレームだけ当てる。F8 で止めている間は十字に上書き | マウスの矢印を隠す・形を変える |
| `App.withCloseRequest(f)` | 閉じるボタンを押したフレームで `f(world)` を 1 回。F8 で止めている間は `f` を呼ばずにその場で閉じる（持ち越さない） | 「終了しますか？」を出す |
| `App.addOutput({ keyOf, write, onJump })` | 実機のフレームの後の鍵が最後に書いた鍵と違えば 1 回 `write` | セーブを書く（`onJump = Skip`） |
| `App.withDocTable(表)` | 表から監視・F1 の一括読み直し・表示中の名乗り（`onJump = Write` の出力）を配線する | Studio の「表示中」の印（`debug/active-docs.json`） |

**決めたこと:**
- 書くのは実機の Running のフレームの後だけ（鍵は読み直しと系の後の World から取る）。`/step`・`trace`・手順・F8 で止めている間は書かない。
- 跳んだ拍（起動・`START`・`/start`・`/step`・`/flow?apply`・F8 の巻き戻しからの再開）の扱いは `onJump` で選ぶ:
  `Skip` = 跳んだ先の鍵を「書いた」ことにする（セーブを作り物の場面で上書きしない）・`Write` = 次の実機のフレームで書く（跳んだ先の Doc も名乗る）。
- `write` が書けなかった時の扱いは `write` が持つ（`ActiveDocs.write` は黙って続ける。セーブは決まり 3 の 1 行を言う）。
- 表示中の Doc は `DocTable.activeDocs(表, w)` から導く（ゲームは World に `activeDocsWritten` の欄を持たなくてよい）。
  ~~`ActiveDocs.step`~~ は消した（`ActiveDocs.write` が残る）。
- `padTouched` は押しっぱなしと同じ「今の様子」なので、固定刻みの持ち越し（押した瞬間だけを次のフレームへ渡す）には入れない。
- `launch` の効果に `Fs.FileWrite` が入った（`main` は既定のハンドラで足りる）。

## 2 始まりの登録簿（App.withStarts）

`App.Start[w] = { name, doc, build = (新しく作った初期の World, 引数の Map) -> Result[String, w] }`（純粋）。

- 新しく作った初期の World = `init` + 起動時の系 + Doc を全部読み直した物（`App.freshWorld`。読み直しは `reloadOn` の関数 =
  `DocTable.reloadAll`、無ければ監視の関数を登録順に）。走っている World は渡さない
  （渡すと「さっきまで遊んでいた World」に場面が依存し、手順・テスト・記録の再生で同じ場面にならない）。
- 引数の値が `@パス` ならエンジンがそのファイルを読んで中身を渡す（無ければその引数は無い）。セーブを読む始まり
  （タイトルの「つづきから」）は `start title save=@saves/slot1.json` と書き、build は文字の中身から組む（build は純粋なまま・読んだ中身は記録に残る）。
- `withStarts` を繋いだゲームは、起動も登録簿を通る: `START` が無ければ先頭の始まり（引数は `Start#args` の既定）。
- `/start` は固定刻みの持ち越しと手の様子も初めに戻す（flow の `start` と記録の再生も同じ）。止めている間の onRequest は履歴の先頭にも置く（`/resume` で消さない）。
- 起動: 環境変数 `START="feedHome t=10"`（手順の `start` の行と同じ形）。無ければ先頭の始まり。知らない名前は近い名前の案を出して起動しない。
- リモート: `GET /starts`（名前・説明の一覧）・`POST /start?name=feedHome&t=10`（新しく作った World から組み直して差し替える）。
- テスト: `App.startOrBug(app, 名前, 引数)`（組めなければ `bug!`。テストの前提が破れた所）。

## 3 手順 flow（e2e/<名前>.flow）

```
# 1 行 1 手。# から後ろはコメント
fps 60                         先頭の設定: fps・ready on|off・ゲームが宣言した設定（look night など）
start title                    幕の頭（始まりの登録簿の名前と key=value）。start のたびに新しい幕
tap confirm                    1 フレーム押して離す（役の名前・キー Z,Enter・点 120,80 = クリック）
hold right 0.5                 押しっぱなし（長さは秒か 30f。書かなければ release まで）
release right
wait 0.8                       何も触らない（押しっぱなしの物はそのまま）
until choice max 10            問いが立つまで待つ。max は必須・当たったら失敗
expect lines>=4                ここで立っていなければ失敗（フレームは使わない）
drive reader until scene=end max 120   名前付きの操作に任せて問いが立つまで
mark cleared                   ここのフレームに名前を付ける（動画の切り出しの印）
run open_menu.flow             別の flow の手をここへ入れる（同じフォルダ・8 段まで）
```

手の語は閉じた一覧（`start tap hold release wait until expect drive mark run` と設定の `fps ready`、記録が書く `reload request close rewind`）。
問いは `名前`（真偽）・`!問い`・`問い&問い`・`名前=文字`・`名前<数`（`< <= = >= > !=`）・`fp=指紋`。

**ゲームが出す表（`App.withFlow`）:**

| 欄 | 型 | 何に使う |
|---|---|---|
| `roles` | `w -> InputMap.Table[String]` | 役の名前 → キー（表の先頭のキーを押す）。Doc で割り当てを変えるゲームは World から |
| `probes` | `List[{ name, doc, read = Flow.Probe[w] }]`（`Num`・`Text`・`Flag`） | until・expect の問い |
| `drives` | `List[{ name, doc, act = (待った秒, w) -> Flow.DriveAct }]`（`Tap(役)`・`Idle`・`Restart`） | 人の代わりに押す操作（会話を読み終えて送る など）。待った秒は drive の始まりか最後の `Restart`・`Tap` から |
| `ready` | `w -> Flow.Ready`（`Ready`・`Busy(理由)`。既定はいつも `Ready`） | tap・hold の前に、入力を受けられるまで自動で待つ（10 秒まで）。今の World で問う（1 フレーム遅れてよい） |
| `replies` | `Option[w -> Int64]`（返事の通し番号。既定は見ない） | 押した後、固定刻みで持ち越した押した瞬間が消化されるまでに番号が進まなければ、押した行の番号つきで失敗 |
| `options` | `List[(名前, 値の候補)]` | ヘッダの設定（動画の見た目など。値は実行器の外のゲームが読む） |

**決めたこと:**
- 自動の待ち（`ready` を宣言したゲーム）があるので、手順に「押せるまで待つ行」を書かない。スパイクで home_to_board の 11 行が 5 行になった。
  `ready off` だけが待ちと返事の確かめを止める（記録はこれ。書いたフレームでそのまま押す）。`ready` を宣言していないゲームの `ready on` は check が止める。
- 前のフレームで押していたキーをもう一度 tap するなら、間に離すフレームを 1 つ挟む（実機でも離さずに 2 回は押せない）。
- 1 フレームの経過秒はナノ秒に丸める（実機の経過秒もナノ秒から来る。丸めないと flow で流したフレームの記録が再生で合わない）。
- until と drive は `max` 必須。打ち切りは失敗で、行番号・フレーム・使った問いの今の値・`statusLine` を言う
  （スパイクで、今の動画 2 本が黙って途中までを返していたのが見つかった）。
- 語彙（役・問い・始まり・操作・設定・キー・ready と replies の宣言の有無）は、描き出しの jar を作った時（`bin/headless-run`）と
  `make flow` のたびに `e2e/vocab.json` へ書き出す（`bin/headless-run` は名前が `.vocab` で終わる入口を全部流す。flow はゲームの
  `E2e.vocab` = `Flow.Cli.writeVocabOf`。会話の手順など、ほかの語彙も同じ契機に乗れる）。近い名前の案は Flix の `Suggest`・Go の `go/internal/suggest`。
  `bin/fge flow check`（Go・JVM なし）がそれを読み、知らない名前に行番号と近い名前の案を付けて止める。語彙が src より古ければそう言う。
- 再生と手順の決定性は、系が純粋（`ef = {}`・乱数は World の種）なことに頼る。記録の再生は最初の指紋で食い違いを言う。
- リモートの `POST /step` の本文は flow の文法（`idle N` → `wait Nf`・`press K` → `tap K`・`hold K N` → `hold K Nf`）。
  `POST /flow`（本文か `?path=`）は新しく作った World から流して結果の表を返す（`?apply=1` で最後の World へ差し替える）。ビルドせずに手順を回す口。
  ゲームのループの中で流すので 1 回 36,000 フレーム（60fps で 10 分）まで。
- リモートの `POST /perf?path=<flow>` は flow を決まった刻みで流した World の列を、実機の GL で 1 コマずつ塗って測り、ヒッチの記録と同じ判定で `hitch.md` を書く（`/step` は塗らない。更新は前もって流し終えているので、測るのは塗る側だけ）。engine の `docs/performance.md` の 11 節。

## 4 記録

DEBUG の起動は、起動から全部のフレームを `debug/flow-record/latest.flow`（前の回は `previous.flow`）に flow の文法で書く
（`FLOW_RECORD=0` で止める・`FLOW_RECORD=<パス>` で置き場所）。F8 のチケットには、その時点までの写し `record.flow` が入る。

```
# recorded 2026-10-19T12:00:00Z（App の記録・起動から全部のフレーム）
ready off
start title save=@saves/slot1.json +assets/rules.json=b64:eyJ… +saves/slot1.json=b64:eyJ…   始まり（読んだファイルの中身つき）
wait 37f ns=16612345,16701234,…              同じ入力が続くフレームは 1 行（実際の dt はナノ秒で全部残す）
tap Z at=120.0,80.0 ns=16666667              最初のフレームはマウスの位置も
hold Down ns=… / release Down ns=…
wait 1f keys=Left,Z new=Z ns=…               押している物の丸ごと・押した瞬間が差分から出ない時だけ new=
expect fp=1a2b3c4d                           60 フレームごとの指紋（App.withFingerprint）。再生で最初の食い違いの行を指す
# fp phase=Playing|lines=3|…                 指紋の元の文字
reload assets/rules.json +assets/rules.json=b64:…   保存で読み直した（F1 は reload key）
request /cheat q=b64:…                       onRequest のルートが World を変えた
close                                        窓の閉じるボタン（withCloseRequest）
rewind 30                                    F8 の巻き戻しから再開した
# ext 1200                                   それでも説明の付かない外からの変化（指紋が前のフレームの後と違う）
```

**決めたこと:**
- World は書き出さない。再生は「始まり + 読んだファイルの中身 + 全部のフレーム」から作り直す（World の直列化を各ゲームに書かせない）。
- 読んだファイルは `Fs.FileRead`（read・readLines。readBytes は拾わない）をハンドラで包んで拾う（`Flow.Record.captureReads`）（新しく作った World の読み直し・監視の読み直し・F1・
  `onRequest`）。再生は同じ中身を返すハンドラで流す。始まりの `@パス` の引数はそのまま書き、読んだ中身は `+パス=b64:…` で同じ行に載せる。
- 押した瞬間・クリック・マウスの動きは、記録した前のフレームとの差分から出ない時（F8 で止めていた間に押した・離した）だけ `new=`・`click`・`moved` で残す。
- 指紋の欄はゲームが選ぶ（`withFingerprint(w -> 文字)`）。Doc の中身や絵のアトラスは入れない（4 万フレームで遅くなる）。
- F8 のチケットの写しの末尾は `rewind <表示中までの戻り>` と `mark ticket`（再生するとチケットの瞬間に着く）。

## やらない事

- 手順に条件分岐・繰り返し・変数を足さない（Maestro の flow と同じく、分岐は呼ぶ側の別の flow）。
- World の直列化（スナップショットからの再開）は作らない。始まりの登録簿と記録の再生で足りる。
- 画面の比べ（スクリーンショットの差分）は手順に入れない。絵は今までどおり描き出しと `make compare`。

## 確かめた数（0.47.0 の本実装）

| 測った物 | 結果 |
|---|---|
| tetris の `e2e/clear_four.flow`（12 手・377 フレーム） | `make flow` で 6.8 秒（jar を作り直さない回。Flix を組み直さない） |
| novel の `e2e/doubt_dealer.flow`（9 手・750 フレーム） | 9 秒 |
| `bin/fge flow check`（JVM なし） | 書き間違い 13 行を行番号と近い名前の案つきで全部（`testdata/lint/flow-check`。Flix の読み手も同じ文面） |
| tetris を DEBUG で起動した記録（実時間・/step・/resume・/start・保存の読み直しを混ぜた 214,800 フレーム） | 再生で指紋 3,785 個がすべて一致 |
