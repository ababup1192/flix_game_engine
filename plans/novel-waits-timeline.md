# サウンドノベルの「待ち」を Timeline 1 本に寄せる（設計とスパイク）

- 日付: 2026-11-16
- 範囲: テンプレート `templates/sound-novel-starter` の待ちの全部と、engine_world の `Timeline` に足す口。今回は設計とスパイクまで（本実装・merge・push はしない）。
- 親: [novel-vocab-n4-design.md](novel-vocab-n4-design.md) の 11.10〜11.12（L・N・(1)）と 14 章。
- スパイクの枝: `worktree-agent-a951ddd25bec3d964`（engine_world の `Timeline` に口を足し、テスト 19 本）。

## 1. なぜ

廃屋配信の移行で、待ちの不具合が続けて出た（L: reader が押すと明ける待ちの間に押す・N: ready が待ちの間も Ready・(1): 歩く `<<bg>>` の後の `<<wait 0.8>>` の秒で台詞が出る）。根は 2 つ。

- (a)「今待っているか」を、reader（`WorldRead.isPaused`）・ready（`WorldRead.isWaiting`）・送り（`WorldRead.advance` / `next` の `r#pause`）・毎コマ（`WorldRead.readOn` の `pause` と `YarnRunner.Shown.Waiting`）・送りの印（`ViewText.waitMark`）・セーブ（`markHere`）・ゲート（`gateOf`）が、それぞれ別の欄を見て決めている。時計も 2 本ある（命令の待ちは `Pause#until`、実行器の `<<wait>>` は `YarnRunner` の `waitUntil`）。
- (b) テストの道（`TestKit.stepBy` = `WorldRead.step` を直に呼ぶ）と App の毎コマの道（`App.advanceFrame` → `Controls.step` → `Controls.interact`・`World.paceOf` の時計）が違う。

### 1.1 (1) を読んで分かった事【推: コードを読んだだけで、流してはいない】

実行器は `<<wait 0.8>>` に着いた時（= 台詞を送った時）に `waitUntil = 今 + 0.8` を決める（`YarnRunner.flow` の Command の所）。一方で歩く `<<bg>>` の待ち（`Out.LineWait(5.4)`）は `Pause#until = 今 + 5.4` を持ち、`flowInstant` は `wait` の命令で止まって残りを `Pause#rest` に預ける。5.4 秒で待ちが明けると、実行器の 0.8 秒はとうに過ぎているので、次のコマの `readOn` が `Tick` してすぐ台詞を出す。つまり World の中だけでも、台詞は 5.4 + 0.8 = 6.2 秒ではなく約 5.4 秒で出る（今のテスト 4 本は「1 秒では出ず 6.5 秒には出ている」を見ているので通る）。2 本の時計が別々に進むこと自体が (a) の形。App の道でだけ 0.8 秒で出る件は別の担当が直している（このファイルは触っていない）。

## 2. 今の待ちの出どころと、読む所

| # | 待ちの出どころ | 持つ所（型・欄） | 時計 | 読む所（判断している所） |
|---|---|---|---|---|
| 1 | 実行器の `<<wait 秒>>` | `YarnRunner` の `Shown.Waiting` + `waitUntil` | 物語の時計（`Clock.Time[Stage.Story]`）。実行器が台詞を送った時に決める | `WorldRead.readOn`（Tick）・`isRunnerWaiting`（`isWaiting`）・`markHere`・`walkActionsOf`・`Shots.settleWait`・`TestKit.isWaiting` |
| 2 | 命令の `Out.Wait(秒)`（`<<audio se 音 wait=true>>`・ゲームの命令） | `World.Read#pause`（`Pause{until, rest, last, tappable=false, passInstant=false}`） | 物語の時計（`until`） | `takeOut` → `withPause`・`pauseOrGo`・`readOn`・`next`・`pick`・`gateOf`・`markHere`・`isPaused`・`ViewText.waitMark`・`commandedOf`（記録の秒） |
| 3 | 命令の `Out.WaitOrTap(秒)` | 同じ `Pause`（`tappable=true`） | 同じ | 上の全部 + `isTapWait`（`advance` → `tapThroughPause` → `passTapWaits`） |
| 4 | 命令の `Out.LineWait(秒)`（ゲームの `backdropSwitch` の歩き・コメント） | 同じ `Pause`（`tappable=true, passInstant=true`） | 同じ | 上の全部 + `flowInstant`（時間を取らない命令を先に流す） |
| 5 | 背景の切り替えの歩き（`GameSwitch{seconds, sounds}`） | `Stage#switch#game`・`Stage#fadeFrom` | 物語の時計 | 待ちは #4 が持つ。音は `WorldRead.switchSounds` → `Stage.gameSwitchSoundsBetween`。押して明けた・スキップで `Stage.withGameSwitchFinished` |
| 6 | 字を出している間 | `World.Read#page`（`Page.step` が cps × `<<text speed>>` で進める）・`doneAt` | 物語の時計の dt | `advance`（`Page.isDone`）・ready（`Busy("typing")`）・reader・`autoOrSkip`（`doneAt` から数える） |
| 7 | 押しても送らない秒（`lockSeconds`・`<<text lock=>>`） | `Stage#props` の trigger（`Stage.isTextLocked`） | 物語の時計 | `next`・`tapThroughPause` |
| 8 | 素材を待つ間（ブラウザ版の後回しの背景・環境音） | `World.Read#hold`（`Hold{phase, phaseFrom, waited, names, rest, last}`） | FadingOut / FadingIn は物語の時計・Waiting は実時間の dt（物語の時計は `World.paceOf` が止める） | `step` → `stepHold`・`holdIfMissing`・`advance` / `pick`（`r#hold`）・`gateOf`・`Controls.interpret`（`World.isHolding`）・`Controls.decodeBudget`・`View`（`holdLayer`） |
| 9 | 押すと明ける（#3・#4 を押す） | #2 の `Pause#tappable` | — | `advance` → `tapThroughPause`（明けた後も続けて押すと明ける待ちを明ける） |
| 10 | 時間を取らない命令を先に流す | #4 の `Pause#passInstant` と `rest` | — | `flowInstant`（`isInstant` = `Commands.timingOf` が `Instant` で `wait` でない） |
| 11 | オート・スキップ | `World.Read#playback`・`doneAt` | 物語の時計 | `autoOrSkip`・`readOn`（スキップは `Pause` と `<<wait>>` を飛ばす）・`isSkippable` |
| 12 | ロード・戻る・始まりの場面（Silent） | `Commands.Replay.Silent`（音と待ちを落とす）・`settled`（`Stage.settle`） | — | `restore`・`openAt`・`reopenNode`・`buildEntriesWithin`（`<<wait>>` は明ける時刻へ Tick） |
| 13 | 画面・確認のウィンドウ | `World#panel`・`World#ask` → `World.paceOf`（物語の時計を止める） | — | `App` の `addClock`・`autoOrSkip`（`isFree`）・`stepHold` |
| 14 | flow（E2e）の reader と ready | `E2e.table` の drives / ready | flow の秒 | reader = `WorldRead.isPaused`・ready = `WorldRead.isWaiting` と `Page.isDone`・`FlowVideo.readyWaitSeconds`（10 秒） |
| 15 | テストの 1 歩 | `TestKit.stepBy`・`readHearing`・`settle` | `App.tickClocks` で物語の時計だけ進める | `WorldRead.step` を直に呼ぶ（`Controls.step`・`interact`・`paceOf` の道を通らない）。ほかに直に呼ぶのは `Shots.settleWait`・`TestGameHooks` の 3 か所・`TestRules` の 1 か所 |

## 3. 形: 1 ビート = Timeline 1 本

**1 ビート** = 入力 1 回（送る・選ぶ・はじめから・ロード）から、次の台詞か選択肢を読み終えるのを待つ所まで。1 ビートに起きる事を全部 1 本の `Timeline` に並べ、再生位置（`Timeline.Player` + 場面の時計）だけで「どの命令をもう当てたか・今待っているか・どの音を鳴らすか」を決める。

- World に持つ物（`World.Read#beat`）: そのビートの出来事の列（`Item` の列）・ビートを始めた物語の時刻 `origin`・`Timeline.Player`・当て終えた出来事の数。時刻表そのものは持たず、毎フレーム列から組み直す（`Timeline.flix` の決まり。数十行なら µs）。
- 実行器は「出来事の出どころ」だけにする。`<<wait>>` に着いたら、その場で `waitUntilOf` の時刻を渡して Tick し、次の台詞か選択肢まで全部引き出す（ビートの列が始めから全部分かる）。実行器の `waitUntil` は使わない（時計が 2 本にならない）。
- 毎フレーム: 表を組む → `playheadOn(今 − origin, player, 表)` → 新しく始まった `Apply(i)` の出来事を当てる → `soundsOnPlayer` で音 → 待ちの判断 `waitingOf` を 1 か所で出す。reader・ready・送り・オート・送りの印・セーブ・ゲートは全部 `waitingOf` を読む。

### 3.1 クリップの名前（テンプレートの enum）

```
enum Key { Apply(Int32) /* i 番目の出来事を当てる時刻（長さ 0） */, Hold(Int32) /* i 番目が出した待ち */,
           Typed /* 字を出し切る */, Read /* 読み終える（入力） */, Assets /* 素材が届く */, Fade(Int32) /* 素材の暗転 */ }
```

### 3.2 待ちの出どころ → Timeline の対応表

| # | 出どころ | Timeline で | 解く・終える | 音 |
|---|---|---|---|---|
| 1 | 実行器の `<<wait 秒>>` | `append(Hold(i), 秒)`（前の待ちが済んでから数える） | 時間で | — |
| 2 | `Out.Wait(秒)` | `append(Apply(i), 0)` + `append(Hold(i), 秒)`。LineWait の後ろで流した命令が出したら `atStartOf(LineWait の Hold, Hold(i), 秒)`（重なって、明けるのは遅い方） | 時間で（押しても明けない） | — |
| 3 | `Out.WaitOrTap(秒)` | #2 と同じ置き方。テンプレートが「押すと明ける Hold」と覚える | 押すと `seekOn`（押した時に途中だった Hold の一番遅い終わりへ。`activeAt` で引く） | 飛ばした区間の音は鳴らない |
| 4 | `Out.LineWait(秒)` | #3 と同じ + 後ろの時間を取らない命令を `atStartOf(Hold(i), Apply(j), 0)` で頭に寄せる。時間を取る命令・`<<wait>>`・台詞・選択肢・押しても明けない待ちが来たら寄せるのをやめて `append` に戻す | #3 と同じ | 寄せた命令の音は歩きの頭で鳴る |
| 5 | 背景の切り替えの歩き | #4 の `Hold(i)` に `withSoundAt(名前, 秒)`（`GameSwitch#sounds` をそのまま） | 押して飛んだ・スキップで `Stage.withGameSwitchFinished` を当てる（飛んだフレームの `Player` の差で知る） | `Stage.gameSwitchSoundsBetween` は要らなくなる |
| 6 | 字を出している間 | 台詞の `Apply(i)` の後に `waitFor(Typed)`。`Page.isDone` になったフレームでテンプレートが `resumeOn` | 押す = `Page.revealAll` してから `resumeOn` | — |
| 7 | 押しても送らない秒 | 今のまま（Stage の trigger）。`Read` の待ちを `resumeOn` する前に `Stage.isTextLocked` を見る | — | — |
| 8 | 素材を待つ間 | `append(Fade(i), holdFadeSeconds)` + `waitFor(Assets)` + `append(Fade(i+1), holdFadeSeconds)`。届いたか諦めた時にテンプレートが `resumeOn` | `World.paceOf` は `waitingOf == AtAssets` で止める | — |
| 9 | 押すと明ける | `seekOn` / `skipToEndOf`（`Player` に Seek を足す） | — | 飛ばした区間は鳴らさず、飛んだ先ちょうどの音は 1 回 |
| 10 | 時間を取らない命令を先に流す | #4 の置き方（`atStartOf`）。待ちの欄は要らない | — | — |
| 11 | オート | `Read` の待ちで止まってからの秒 = `waitedOn`。`autoWait + 字数 × autoPerChar` を過ぎたら `resumeOn` | — | — |
| 11 | スキップ | 毎フレーム `skipToNextWait`、`Typed` は即 `resumeOn`、`Read` は `waitedOn ≥ skipInterval` で `resumeOn` | — | 飛ばした区間は鳴らさない（今と同じ） |
| 12 | ロード・戻る・始まりの場面 | ビートを組んで `skipToNextWait` を `Read` まで繰り返す（Silent のまま。`Apply` は全部当てる） | — | `soundsOnPlayer` を呼ばない |
| 13 | 画面・確認のウィンドウ | 今のまま（物語の時計が止まれば再生位置も止まる） | — | — |
| 14 | flow の reader / ready | reader は `waitingOf == Input` の時だけ押す・ready は `Input` 以外を `Busy` | — | — |
| 15 | テストの 1 歩 | 4 章 | — | — |

`waitingOf`（テンプレートの 1 か所）が返すのは `Free`（演出が流れているだけ）・`Blocking`（押しても明けない Hold の途中）・`Tappable`（押すと明ける Hold だけの途中）・`Typing`・`Input`（`Read`）・`AtAssets`。

### 3.3 今の Timeline で表せない物（engine_world に足す）

| 要る事 | 今 | 足す口（スパイクで入れた物は ●） |
|---|---|---|
| 押して途中の演出を終える（歩きを押して終える） | `waitFor` は長さの決まらない待ちだけで、長さのあるクリップを途中で終える口が無い | ● `Timeline.seekOn` / `skipToEndOf`（Godot `AnimationPlayer.seek`・Unity `PlayableDirector.time`・Bevy `seek_to`） |
| スキップ・ロードで次の待ちまで飛ぶ | 無い | ● `Timeline.skipToNextWait` |
| 解いた待ちと飛んだ所を 1 つの値で World に持つ | `resume` は `List[Float64]`（解いた時刻だけ） | ● `Timeline.Player`（外から作らせない型。`player()` で作る）・`resumeOn` |
| 飛んだフレームの音（飛ばした区間は鳴らさない・飛んだ先ちょうどは 1 回） | `soundsOn` の `Seek` はそのフレームの音を全部落とす | ● `Timeline.soundsOnPlayer` |
| 再生位置・待っているか・待ちに着いてからの秒 | `playheadOf` / `isWaiting`（resume の列で） | ● `playheadOn` / `isWaitingOn` / `waitedOn`（オートの間） |
| 押した時に途中だった演出をまとめて引く | `stateOf` をタグごとに呼ぶ | ● `Timeline.activeAt` |
| 新しく始まったクリップ（命令を当てる時刻）を、飛んだ区間の物も含めて返す | 無い（音だけが出来事） | 提案 `Timeline.startedOnPlayer(prev, now, player, tl): List[a]`（Unity の Signal の retroactive・Bevy の AnimationEvent。音と違い、飛ばした区間の物も返す。スキップで飛ばした `<<set>>` も当てるため）。スパイクでは台詞の `Apply` を `stateOf` で見ただけ |

公開の型シグネチャは何も変えていない（`Timeline` の enum の中身・`playheadOf` / `resume` / `soundsOn` はそのまま。足したのは新しい名前だけ）。

## 4. テストの道を App の道にそろえる

engine に要る物はもうある: `App.advanceFrame(app, frame, state, world)`（実機と同じく実時間と `addClock` の時計を進めてから系を流す）と `App.trace`（音と sustained まで）。

- `TestKit.stepBy(res, dt, w)` を `App.advanceFrame(Game.app(res, …), { dt = dt | App.emptyFrame() }, state, Resources.of(res, w))` に置き換える（`StepState` は `TestKit` が持ち回す。`World.paceOf` も `Controls.step` も `Controls.interact` も通る）。`readHearing` は `App.trace` で音まで見る。
- `WorldRead.step` を直に呼ぶ所（`Shots.settleWait`・`TestGameHooks.stepHearing` / `walkedIntoEvents` / サムネのテスト・`TestRules.testTheMigrateRecordKeepsTheScriptText`）は、テストは `TestKit` へ・`Shots.settleWait` は `skipToNextWait` へ寄せる。
- 押す手もフレームで渡す（`TestKit.advance` は `Controls.interact` に `justPressed` の入ったフレームを渡す）。規則の単体テスト（`WorldRead.advance` を直に呼ぶ物）は残してよい（入力の解釈を見ないテスト）が、待ちを見るテストは App の道だけにする。
- `TestKit.isWaiting` は消して `NovelBeat.waitingOf` を読む。

## 5. テンプレートに残る物と engine に入る物

| engine_world（汎用） | テンプレート（ノベル固有の対応だけ） |
|---|---|
| `Timeline.Player`・`player`・`resumeOn`・`seekOn`・`skipToEndOf`・`skipToNextWait`・`playheadOn`・`isWaitingOn`・`waitedOn`・`soundsOnPlayer`・`activeAt`（スパイク済み） | 新しい mod `NovelBeat`: `Item`（実行器の出来事 + `Commands.Out` + `Commands.timingOf` から作る）・置き方の決まり（LineWait の後ろの時間を取らない命令を頭へ寄せる）・`Key`・`waitingOf`・押した時の決まり（途中の押すと明ける Hold の一番遅い終わりへ）・オートとスキップの秒 |
| 提案 `startedOnPlayer`（飛んだ区間も返すクリップの始まり） | `World.Read#beat`（`pause` と `hold` の `rest` / `last` を置き換える） |
| 既存 `App.advanceFrame` / `App.trace`（テストの道） | `TestKit` の 1 歩を App の道へ |
| — | 素材の待ち・字を出し切る・押しても送らない秒を `resumeOn` する所（何が届いたか・字を出し切ったかはノベルの事） |

置かない物: ノベルの `Item` や「LineWait の後ろを流す」決まりを engine に入れない（実装が 1 つしかない所に層を置かない。`docs/flix-conventions.md` の「層を置く物差し」）。2 本目（RPG の会話・カットシーン）が同じ形を欲しがった時に、置き方の決まりを `Timeline` の `Place` に足すかを決める。

## 6. スパイクの結果

engine_world の `Timeline` に 3.3 の ● を足し、`.layers/engine_world` で全量のテストを流した: **Passed 1533・Failed 0**（足したテスト 19 本を含む）。

- `engine_world/test/TestTimelinePlayer.flix`（8 本・engine に残す）: 操作なしで歩き → 着いた音 → 待ちで止まる・歩きを押して終えると後ろの足音は鳴らず着いた音は 1 回・seek は待ちを越えない・待ちに着く前の早押しは数えない・飛んだ後の resume は待ちから続く・待ちに着いてからの秒・`skipToNextWait` は飛ばした音を鳴らさない・`resumeOn` は古い `resume` と同じ再生位置。
- `engine_world/test/TestTimelineNovelSpike.flix`（11 本・スパイク。本実装でテンプレートの `NovelBeat` とそのテストへ移し、engine からは消す）:
  - (1) の並び（歩く bg 5.4 秒・押すと明ける・音 2 つ → `<<set>>` → `<<audio>>` ×2 → `<<wait 0.8>>` → 台詞）: 台詞は 6.2 秒のフレームで出る・`<<audio>>` 2 つは歩きの頭（0 秒）で当たる・音は door → ambience → bgm → step の順に 1 回ずつ・1 秒で押すと歩きが終わり台詞は 1.8 秒（`<<wait 0.8>>` は残る）・押した時は後ろの足音が鳴らない・`<<wait>>` の途中で押しても何も起きない・待ちの判断が 1 秒 Tappable / 5.8 秒 Blocking / 6.3 秒 Input。
  - コメントの LineWait（1.5 秒 → `<<audio se ping>>` → `<<jump>>` → 台詞）: 台詞は 1.5 秒・ping は 0 秒で鳴る・WaitOrTap なら ping も 1.5 秒まで待つ・歩きの後ろで流した命令が押しても明けない待ちを出すと歩きも押して明けない。
- スパイクで分かった落とし穴: 押した時に待ちごとに `skipToEndOf` を続けて当てると、飛んだ先でちょうど始まる `<<wait>>` まで「途中」に見えて飛ばしてしまう。押した時に途中だった物を先に `activeAt` で集め、一番遅い終わりへ 1 回で飛ぶ（スパイクの `tap`）。
- 今の World との比べは流していない（1.1 は読んだだけ）。本実装の段 1 で App の道のテストを足し、今の版で 5.4 秒前後に出る事を先に赤で確かめる。

## 7. 本実装の段取りと見積もり（実時間）

各段の門: `../../bin/fge refactor` で呼び手を洗ってから直す・テンプレートは `make test`（変わったパッケージだけ）・engine_world は `make sync-layers` の後 `.layers/engine_world` で `flix test`・コミット前に `bin/fge jargon <触ったパス>`。

| 段 | 中身 | 門 | 見積もり |
|---|---|---|---|
| 0 | engine の口を正式にする: `startedOnPlayer` を足す・`agents-pack/AGENTS.core.md` の早見表に 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本・api-digest は bump で | engine_world 全量・`make agent-eval ONLY=<お題>` | 1.5 時間 |
| 1 | `TestKit` を `App.advanceFrame` / `App.trace` の道へ（挙動は変えない）。(1) を App の道で見るテストを足す（今の版で赤 = 1.1 の確かめ） | テンプレートのテストが全部緑（(1) の新しいテストだけ赤のまま印を付ける） | 2 時間 |
| 2 | `NovelBeat` と `World.Read#beat` を足し、今の `pause` / 実行器の待ちと並べて走らせる（`waitingOf` と `isWaiting` / `isPaused` が食い違ったらテストで落とす。flow 6 本でも比べる） | テスト緑・flow 6 本の指紋が同じ・食い違いの一覧が (1) の形だけ | 3 時間 |
| 3 | 切り替え: `absorbFrom` / `pauseOrGo` / `flowInstant` / `readOn` の `<<wait>>` と `pause` を `beat` に。実行器の `<<wait>>` はその場で引き出す。reader・ready・`advance`・`autoOrSkip`・`markHere`・`gateOf`・`waitMark`・`commandedOf` を `waitingOf` に。`Pause` を消す | テスト緑（(1) も緑）・flow 6 本・廃屋配信の比べ（下） | 4〜5 時間 |
| 4 | 素材の待ち（`Hold`）・字を出し切る・オートを `beat` に。`World.paceOf` は `waitingOf` を読む | TestHold・TestCast・TestRules 緑・ブラウザ版の素材の待ちの flow | 3 時間 |
| 5 | スキップ・ロード・戻る・始まりの場面（Silent）を `skipToNextWait` に。`Shots.settleWait`・`FlowVideo` | 描き出しの基準（SHA256SUMS）が同じ・TestTape・TestMigrate 緑 | 2 時間 |
| 6 | レビュー（1 回目で全部出させ、まとめて直して 2 回目）・廃屋配信と血鱗の追随 | レビュー 80 点以上で必須が直っている・2 本の比べ | 3 時間 |

合わせて約 18〜20 時間（11.12 の段 11 の直し 1 つが 1〜2 時間だった実績から）。

### 7.1 廃屋配信の比べで「前と同じ」を確かめる

1. 前の版（古い廃屋配信のコミットを git worktree に出した物）で `make migrate-baseline`（済んでいれば写すだけ）。
2. 段 3 の後の移行先（新しいテンプレートの上の廃屋配信）で `make migrate-new`、直しを足すたびに撮り直さずに `make migrate-diff`。
3. 見る物（docs/migrate-diff.md）: events（line・choice・wait）の並びが同じ・台詞の時刻が `<<wait>>` の分だけ前の版に近づく（(1) が直る）・歩きの音と流した命令の音の時刻が前の版と同じ・`Executed.Commanded` の秒が同じ。食い違いが残る時だけ `migrate-accept.json` に理由つきで書く。
4. 段 3 の前（段 2 の並走）でも 1 回流し、食い違いが (1) の所だけである事を先に確かめる。

### 7.2 血鱗への効き【未確認】

- `<<wait>>` が前の命令の待ち（`Out.Wait`・`WaitOrTap`）の後から数えるようになる。血鱗に「待ちを出す命令の直後の `<<wait>>`」があれば、台詞の時刻が `<<wait>>` の秒だけ遅くなる（今は重なって消えていた）。移行の比べで前の版（古い血鱗）と照らし、前の版が後から数えていたなら直りになる。
- 払い・タップのゲートは `gateOf` が `waitingOf` を読むだけになり、形は変わらない見込み。
- 血鱗が素材の待ち（ブラウザ版）を使うなら段 4 の flow で一緒に見る。

## 8. 相談したい事

1. 1.1 の通り、今の World は `<<wait>>` を前の命令の待ちと重ねて数えている。Timeline に寄せると「前の待ちが済んでから数える」になり、(1) だけでなく同じ並びの全部で台詞が遅くなる。これを正にしてよいか（古い 2 本の版はどちらも後から数えていた【推】）。
2. `startedOnPlayer` の名前（Unity は Signal・Godot は method track・Bevy は AnimationEvent）。「クリップの始まりを、飛ばした区間の物も返す」口として、`startedOnPlayer` でよいか。
3. スパイクのテスト `TestTimelineNovelSpike.flix` は engine に置いたまま枝にある。本実装の段 2 でテンプレートへ移す前提。

## 9. 親の設計書から指す 1 行（案）

14 章の末尾に:

```
- （段 11 の後）待ちの判断が reader・ready・毎コマ・実行器の時計に割れている根（L・N・(1)）は、待ちを engine_world の Timeline 1 本（Timeline.Player）に寄せて直す: plans/novel-waits-timeline.md
```
