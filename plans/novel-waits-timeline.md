# サウンドノベルの「待ち」を Timeline 1 本に寄せる（設計とスパイク）

- 日付: 2026-11-16
- 範囲: テンプレート `templates/sound-novel-starter` の待ちの全部と、engine_world の `Timeline` に足す口。今回は設計とスパイクまで（本実装・merge・push はしない）。
- 親: [novel-vocab-n4-design.md](novel-vocab-n4-design.md) の 11.10〜11.12（L・N・(1)）と 14 章。
- スパイクの枝: `worktree-agent-a951ddd25bec3d964`（engine_world の `Timeline` に口を足し、テスト 31 本）。

## 1. なぜ

廃屋配信の移行で、待ちの不具合が続けて出た（L: reader が押すと明ける待ちの間に押す・N: ready が待ちの間も Ready・(1): 歩く `<<bg>>` の後の `<<wait 0.8>>` の秒で台詞が出る）。根は 2 つ。

- (a)「今待っているか」を、reader（`WorldRead.isPaused`）・ready（`WorldRead.isWaiting`）・送り（`WorldRead.advance` / `next` の `r#pause`）・毎コマ（`WorldRead.readOn` の `pause` と `YarnRunner.Shown.Waiting`）・送りの印（`ViewText.waitMark`）・セーブ（`markHere`）・ゲート（`gateOf`）が、それぞれ別の欄を見て決めている。時計も 2 本ある（命令の待ちは `Pause#until`、実行器の `<<wait>>` は `YarnRunner` の `waitUntil`）。
- (b) テストの道（`TestKit.stepBy` = `WorldRead.step` を直に呼ぶ）と App の毎コマの道（`App.advanceFrame` → `Controls.step` → `Controls.interact`・`World.paceOf` の時計）が違う。

### 1.1 (1) を読んで分かった事【推: コードを読んだだけで、流してはいない】

実行器は `<<wait 0.8>>` に着いた時（= 台詞を送った時）に `waitUntil = 今 + 0.8` を決める（`YarnRunner.flow` の Command の所）。一方で歩く `<<bg>>` の待ち（`Out.LineWait(5.4)`）は `Pause#until = 今 + 5.4` を持ち、`flowInstant` は `wait` の命令で止まって残りを `Pause#rest` に預ける。5.4 秒で待ちが明けると、実行器の 0.8 秒はとうに過ぎているので、次のコマの `readOn` が `Tick` してすぐ台詞を出す。つまり World の中だけでも、台詞は 5.4 + 0.8 = 6.2 秒ではなく約 5.4 秒で出る（今のテスト 4 本は「1 秒では出ず 6.5 秒には出ている」を見ているので通る）。2 本の時計が別々に進むこと自体が (a) の形（ただし 1.2 の通り、この並びの約 5.4 秒は古い版と同じで正しい）。App の道でだけ 0.8 秒で出る件は別の担当が直している（このファイルは触っていない）。

### 1.2 古い版はどう数えていたか（記録で確かめた）

合格線は「台詞・音の順と時刻が古い版と一致」。古い版の基準の記録 `~/Documents/flix_ge_workspace/haioku-n4-baseline/debug/migrate/baseline/flows/walk_tour/tape.json`（30 fps）を jq で読んだ:

| 何 | 記録の秒 | 出どころ |
|---|---|---|
| Entrance の `<<se se_door_heavy>>` と `<<wait 0.9>>` | 35.567 | sounds・events（kind=wait） |
| Inside の頭: `<<bg genkan dark 1.2>>`・`<<ambience amb_house>>`・`<<bgm bgm_suspense>>`・`<<wait 0.8>>` | 36.5（35.567 + 0.9 の次のフレーム） | sounds（ambience 2 つ）・events（kind=wait, node=Inside, seconds=0.8） |
| 歩きの音 `se_creak` | 38.733（bg から 2.233 秒） | sounds。walks.json の entrance_out → genkan の `sounds[t=2.2]` |
| Inside の最初の台詞「一歩入っただけで、…」（haioku.yarn 81 行目） | **41.933（bg から 5.433 秒）** | events（kind=line, seq=0） |

歩きの長さは古い版の `Walk.totalSeconds` = out の keys の最後の t（87 個 = 2.867 秒）+ arrive の最後の t（62 個 = 2.033 秒）+ `dissolveSeconds` 0.5 = **5.4 秒**。台詞は歩きの終わり（36.5 + 5.4 = 41.9）の次のフレーム（41.933）に出ている。6.2 秒（42.7）ではない。

2 つの報告はどちらも正しく、食い違いではなかった:
- レビュー役の読み「古い版の `readOn` は歩いている間は実行器の `<<wait>>` を進めない」は正しい（`Shown.Waiting if Option.isEmpty(Stage.walkingFor(...))`）。
- ただし実行器の `waitUntil` は `<<wait 0.8>>` に着いた時（bg と同じ 36.5）に 37.3 と決まっているので、歩きが終わって Tick した時にはもう過ぎていて、すぐ台詞が出る。だから移行の担当の「5.43 秒後」になる。

**決め: 歩く背景（LineWait）の後ろの `<<wait>>` は `atStartOf(歩きの Hold)` に置く**（歩きの頭から数えて重なり、台詞は遅い方の終わり = max(5.4, 0.8) = 5.4 秒）。後ろの命令は流さない（古い版も Tick までは次を流さない）。前に時間を取る待ちが無い `<<wait>>` は今までどおり `append`。

押した時も古い版に合わせる: 古い版の `advance` は歩きの途中で押すと `Stage.finishSwitch` で歩きだけを終え、`<<wait>>` の明ける時刻（37.3）はそのまま。Timeline では「押すと明ける Hold を、押した時刻で終わる長さに縮めて組み直す」で表す（3.6）。seek はスキップとロードにだけ使う。

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

## 3. 形: 1 ビート = Timeline 1 本（実行器は先に引き出さない）

**1 ビート** = 入力 1 回（送る・選ぶ・払う・はじめから・ロードの後の最初）から、次の台詞か選択肢を読み終えるのを待つ所まで。1 ビートに起きる事を 1 本の `Timeline` に並べ、再生位置（`Timeline.PlaybackLog` + 物語の時計）だけで「どの命令をもう当てたか・今待っているか・どの音を鳴らすか」を決める。

### 3.1 実行器との付き合い方（レビュー M1 の (a)）

実行器（`YarnRunner`）は先に全部引き出さない。`<<set>>` は出来事を出さずに実行器がその場で storage を書くので、引き出すと `<<wait>>` の後ろの `<<set>>` がビートの頭で当たってしまう（haioku.yarn 52→59・60 行、70→77 行、227→234 行。電池と電波が `<<wait>>` の秒だけ早く替わる）。実行器の位置（`talkCursorOf`・テープの位置・`markHere` のブックマーク）も先へ進んでしまう。

- 実行器が返した出来事（`<<wait>>` で止まった所か、台詞・選択肢まで）を 1 束として `Item` の列の後ろへ足す。
- 再生位置が表の終わり（クリップの終わりで一番遅い所）に着き、実行器が `<<wait>>` で止まっていれば、実行器を `Tick`（時刻は `waitUntilOf`）して次の束を後ろへ足す。足すのは `append` だけで、前に置いた物は動かない（3.5 の決まり）。
- 実行器の `waitUntil` は Tick の時刻を渡すためにだけ使う。いつ Tick するかは表が決める（時計は 1 本）。歩きと重なって数えている `<<wait>>`（1.2）は、表の上で `<<wait>>` の Hold が歩きの頭から始まるので、終わりは max(歩き, wait) になる。
- engine の `YarnRunner` は変えない。

World に持つ物（`World.Read#beat`）: その束までの `Item` の列・ビートを始めた物語の時刻 `origin`・`Timeline.PlaybackLog`・押して字を出し切る印（`reveal`）・素材の待ちの実時間の秒（諦めるまで数える）。時刻表は持たず、毎フレーム列から組み直す（`Timeline.flix` の決まり）。

毎フレーム（App の道とテストの道が同じ 1 つの関数を通る。4 章）: 押した手を当てる → 解ける待ちを解く・スキップなら次の待ちへ飛ぶ・表の終わりなら実行器を Tick、を変わらなくなるまで繰り返す → `startedOnWall` で頭を過ぎたクリップ（`Apply(i)` = 命令を当てる・`Typed(i)` = 字を出し始める・Hold の頭 = テープの wait）を当てる → `soundsOnWall` で音 → `waitingOf` を 1 か所で出す。reader・ready・送り・オート・送りの印・セーブ・ゲートは全部 `waitingOf` を読む。

### 3.2 クリップの名前（テンプレートの enum）

```
enum Key {
    Apply(Int32)   // i 番目の出来事を当てる時刻（長さ 0。台詞なら頁に積む）
    Hold(Int32)    // i 番目の出来事が出した待ち・実行器の <<wait>>
    Lock(Int32)    // 押しても送らない秒（lockSeconds・<<text lock=>>）。押した手を Read に届けない間
    Typed(Int32)   // 字を出し切るのを待つ（waitFor）
    Read(Int32)    // 台詞を読み終えるのを待つ（waitFor）
    Choose(Int32)  // 選択肢を選ぶのを待つ（waitFor）
    Gate(Int32)    // 払い・タップで選ぶのを待つ（waitFor）
    FadeOut(Int32) // 素材を待つ前の暗転（束の頭）
    Assets(Int32)  // 素材が届くのを待つ（waitFor）
    FadeIn(Int32)  // 暗転から戻し始める印（長さ 0）
    Done           // シナリオの終わり（<<stop>>・閉じた）
}
```

スパイクに入れたのは Apply・Hold・Typed・Read・FadeOut・Assets・FadeIn。Lock・Choose・Gate・Done は本実装で足す。

### 3.3 待ちの出どころ → Timeline の対応表

| # | 出どころ | Timeline で | 解く・終える | 音 |
|---|---|---|---|---|
| 1 | 実行器の `<<wait 秒>>` | LineWait の後ろなら `atStartOf(LineWait の Hold, Hold(i), 秒)`（歩きの頭から数えて重なる。根拠は 1.2 の記録の 5.433 秒）。それ以外は `append(Hold(i), 秒)`。実行器はここで止まり、後ろは Tick した時に足す | 時間で（押しても明けない） | — |
| 2 | `Out.Wait(秒)` | `append(Apply(i), 0)` + `append(Hold(i), 秒)`。LineWait の後ろで流した命令が出したら `atStartOf(LineWait の Hold, …)`（重なって、明けるのは遅い方）で、後ろは流さない | 時間で（押しても明けない） | — |
| 3 | `Out.WaitOrTap(秒)` | #2 と同じ置き方。`Item` は予定の秒と押して縮めた秒を別々に持つ | 押すと縮める（3.6） | 縮めた後ろの音は外すので鳴らない |
| 4 | `Out.LineWait(秒)` | #3 と同じ + 後ろの時間を取らない命令を、続いた LineWait の**最初**の頭へ `atStartOf(Hold(最初の i), Apply(j), 0)` で寄せる（間に別の LineWait があっても最初の頭）。時間を取る命令・`<<wait>>`・選択肢・押しても明けない待ちが来たら寄せるのをやめる。続く LineWait は前の LineWait の後ろに 1 つずつ並ぶ。`<<comment A>><<comment B>><<se x>>` の x は A と同じ頭で鳴り、B より前（古い版と同じ並びで、廃屋配信の音の順も合う。TestGameHooks.testASoundAfterTwoCommentsRingsWithTheFirst で固定）。寄せた命令の素材が届いていなくても寄せたまま（素材の待ちは束の頭に置く。#8）。歩く bg の後ろの時間を取る命令（Timed）は歩きの後ろへ回る（今のテンプレートの `flowInstant` に合わせた決め。2 本の比べには出ない） | #3 と同じ | 寄せた命令の音は LineWait の頭で鳴る |
| 5 | 背景の切り替えの歩き | #4 の `Hold(i)` に `withSoundAt(名前, 秒)`（`GameSwitch#sounds` をそのまま） | 縮めた・スキップで飛んだ所で `Stage.withGameSwitchFinished` | `Stage.gameSwitchSoundsBetween` は要らなくなる |
| 6 | 台詞 | `Apply(i)` は続いた LineWait の最初の頭（無ければ `append`）= 頁に積む時刻。その後に `waitFor(Typed(i))`（前の待ちが全部済んでから字を出し始める）と `waitFor(Read(i))` | Typed・Read は 3.4 | — |
| 7 | 押しても送らない秒 | 鳴らした命令の所に `Lock(i)` の Hold（押しても明けない待ちではなく、押した手を Read に届けないだけ） | 時間で | — |
| 8 | 素材を待つ間 | 束を足す時に、束の中（頭へ寄せる命令も含む）で届いていない素材の名前を全部集め、1 つでもあれば束の頭に `append(FadeOut(i), holdFadeSeconds)` + `waitFor(Assets(i))` + `append(FadeIn(i), 0)` を置き、その後に束をいつもどおり並べる（3.5）。FadeIn は戻し始めの印で、戻す絵は Stage の時計で動く。束の残りは戻し始めと同じ時刻から並ぶ（古い版の `holdIfMissing` の「bg と同じ時刻に暗転して待つ」に近い） | 3.4 | — |
| 9 | 選択肢・ゲート | `Apply(i)`（出す）+ `waitFor(Choose(i))` か `waitFor(Gate(i))` | 3.4 | — |
| 10 | オート・スキップ・ロード | 3.4 の表（スキップとロードは `skipToNextWait` と `resumeOn`） | — | 飛ばした区間は鳴らさない |
| 11 | 画面・確認のウィンドウ | 今のまま（物語の時計が止まれば再生位置も止まる） | — | — |
| 12 | flow の reader / ready | reader は `waitingOf == Input` の時だけ押す・ready は `Input` と `Choosing` 以外を `Busy` | — | — |

`waitingOf`（テンプレートの 1 か所）が返すのは `Free`（演出が流れているだけ）・`Blocking`（押しても明けない Hold の途中。押すと明ける Hold と重なっていてもこちら）・`Tappable`（押すと明ける Hold だけの途中）・`Typing`・`Input`・`Choosing`・`AtAssets`。

### 3.4 遊び方 × 待ち: 誰が・いつ resumeOn するか（レビュー M3）

| 待ち | Manual | Auto | Skip | Silent（ロード・戻る・始まりの場面） |
|---|---|---|---|---|
| Typed | 字を出し切ったフレーム（`Page.isDone`）にテンプレートが。押せば `Page.revealAll` してすぐ | Manual と同じ | 着いたフレームにすぐ（読んでいない行でスキップを止める設定なら、ここで Manual に戻して止まる） | すぐ |
| Read | 押した手（`Lock` の間は届けない） | 止まってからの秒（`waitedOn`）が `autoWait + 字数 × autoPerChar` を過ぎたフレーム（`Lock` の間は待つ） | `waitedOn ≥ skipInterval` | 目当ての台詞（Mark の行）の Read だけ解かずに止まる。それより前の Read はすぐ |
| Choose | 選んだ手（`pick`） | 解かない（Manual に戻さず待つ） | 設定の「選択肢の後」で止めるか待つ | ブックマークの入力（`Choose(i)`）をそのまま当てる |
| Gate | 払った手（`passGate`） | Manual に戻して待つ（今の `autoOrSkip` と同じ） | 同じ | ブックマークの入力をそのまま当てる |
| Assets | 名前の全部が届いたフレームか、実時間で `holdGiveUpSeconds` を過ぎて諦めたフレーム（暗転の Fade は物語の時計で進む・待つ間は `World.paceOf` が物語の時計を止める） | 同じ | 同じ（スキップは止める） | 届いていれば解く。届いていなければ解かずにそこで止まり、遊ぶ側の最初のフレームから暗転して待つ（古い版が当て直しの後に `holdIfMissing` へ入ったのと同じ） |

- **ロードと戻る**: `Saves.Mark` のブックマークを `YarnRunner.resume` で当て直すと、実行器はノードの頭から出来事を返す（`<<wait>>` は明ける時刻へ飛ばす）。返った列を台詞・選択肢ごとのビートに切り、目当ての Read に着くまでビートを何本も当て直す（ログから戻る `restore`・`reopenNode` も同じ。途中の Read は Silent の行のとおりすぐ解く）。Silent は音を時刻表から出さない。鳴り続ける音（環境音・音楽）はロードの後に Stage から鳴らし直す（今の `Controls.ambience` のまま）。
- 素材の待ちで止まった時、Silent の繰り返しはそれ以上進めない（届かない素材で回り続けない）。止まった所が遊ぶ側のビートの頭になる。

### 3.5 表を変えてよいのは 2 つだけ（レビュー M4）

`PlaybackLog` の `passed` は「解いた waitFor の数」なので、ビートの途中で waitFor を前の方へ差し込むと、解いた数が別の待ちを指してしまう。決め:

1. **後ろへ足す**（Tick した束を `append` する）。
2. **押すと明ける Hold を縮める**（今の時刻で終わる長さか 0 秒に。今より前の物の位置は動かない）。

これ以外の変え方はしない。素材の待ちは「束を足す時に、束の中で届いていない素材の名前を集め、1 つでもあれば束の頭に FadeOut + waitFor(Assets) + FadeIn を置く」と、足す時に一度だけ決める（足した後は消さない。暗転の途中で届いても、待ちに着いたフレームで `resumeOn` するだけ）。束の頭に置くので、待ちより前の時刻に後ろの物が来ず（`PlacedBeforeWait` にならない）、寄せる命令も歩きの頭のまま。

素材の要る命令ごとに後ろへ waitFor を置く形を採らない理由: 頭へ寄せた命令の後ろの waitFor は表の終わり（歩きの終わり）にしか置けず、続く寄せた命令が waitFor より前の時刻になって `build` が止める。スパイクの `testAMissingAssetOfAFlowedCommandHoldsTheWholeBatchFromFrameZero` が、歩く LineWait の頭へ寄せた命令の素材が届いていない並びで、0 フレーム目から暗転し、届いた 40 フレーム目から歩きと寄せた音が流れる事を見る。

engine のテスト `testShorteningTheRunningClipAndAppendingKeepThePlayhead` が「縮めても後ろへ足しても再生位置が続く」を見る。

### 3.6 押した時（レビュー M5）

- 読み終えを待っていれば Read を解く。字を出していれば出し切る（Typed を解く）。素材の待ちなら何もしない。
- 演出の途中なら、今から「次の Read・Choose・Gate・Assets」か「まだ始まっていない押しても明けない Hold の頭」までにある押すと明ける Hold を全部、今の時刻で終わる長さに縮める（まだ始まっていない物は 0 秒）。重なっている押しても明けない Hold と `<<wait>>` は残る。その先の Typed も全部出し切る（`reveal`）。古い版も 1 回押すとコメントの全部・歩きの終わり・字の全部出しが起きた。
- seek（一番遅い終わりへ飛ぶ）は使わない。歩きと重なって数えている `<<wait>>` まで飛ばし、表の時刻を 1 本しか動かせないため。
- 今のテンプレートとの違い: 今は歩きの後ろで流した命令が押しても明けない待ちを出すと、歩きごと押せない（`withPause` の WhyNot）。縮める形では歩きだけが終わり、音を聞かせる待ちは残るので、WhyNot の心配（音の途中で台詞が出る）は起きない。これを正にする（廃屋配信・血鱗とも `wait=true` は無い）。テンプレートのテストで 1 本固定する（段 3）。

### 3.7 engine_world に足した口

| 要る事 | 今 | 足した口 |
|---|---|---|
| 解いた待ちと飛んだ所を 1 つの値で World に持つ | `resume` は `List[Float64]`（解いた時刻だけ） | `Timeline.PlaybackLog`（外から作らせない型。`playbackLog()` で作る）・`resumeOn` |
| スキップ・ロードで次の待ちまで飛ぶ | 無い | `seekOn`（戻らない・waitFor を越えない。Godot `AnimationPlayer.seek`・Unity `PlayableDirector.time`・Bevy `seek_to`）・`skipToNextWait` |
| 再生位置・待っているか・待ちに着いてからの秒 | `playheadOf` / `isWaiting`（解いた時刻の列で） | `playheadOn` / `isWaitingOn` / `waitedOn`（オートの間） |
| 飛んだフレームの音（飛ばした区間は鳴らさない・飛んだ先ちょうどは 1 回） | `soundsOn` の `Seek` はそのフレームの音を全部落とす | `soundsOnWall` |
| 頭を過ぎたクリップ（命令を当てる・字を出し始める・テープの wait）を、飛んだ区間の物も含めて返す | 無い（音だけが出来事） | `startedOnWall(playback, prev, now, log, tl): List[a] with Order[a]`（Unity の Signal の retroactive・Bevy の AnimationEvent。境目は soundsOn と同じ・最初のフレームは prev ちょうどの操作より前から数える・O(クリップの数)）。束を後ろへ足した同じフレームでも、足したクリップの頭が今より前でなければ返る |

- 名前の On は「場面の時計（wall clock）の時刻で受ける」の意味（`Timeline.flix` の冒頭に 1 行）。`Player` は操作するキャラと取り違えるので `PlaybackLog` にした。
- 使う人のいない口（`skipToEndOf`・`activeAt`）は外した。古い `resume` / `playheadOf` / `isWaiting` は `PlaybackLog` の上の薄い包みにした（外のゲームとテンプレート・examples に使う所が無いのを grep で確かめた）。
- 公開の型シグネチャは変えていない（`Timeline` の enum の中身・古い口の型はそのまま）。

## 4. テストの道を App の道にそろえる

engine に要る物はもうある: `App.advanceFrame(app, frame, state, world)`（実機と同じく実時間と `addClock` の時計を進めてから系を流す）と `App.trace`（音と sustained まで）。

- `TestKit.stepBy(res, dt, w)` を `App.advanceFrame(Game.app(res, …), { dt = dt | App.emptyFrame() }, state, Resources.of(res, w))` に置き換える（`StepState` は `TestKit` が持ち回す。`World.paceOf` も `Controls.step` も `Controls.interact` も通る）。`readHearing` は `App.trace` で音まで見る。
- `WorldRead.step` を直に呼ぶ所（`Shots.settleWait`・`TestGameHooks.stepHearing` / `walkedIntoEvents` / サムネのテスト・`TestRules.testTheMigrateRecordKeepsTheScriptText`）は、テストは `TestKit` へ・`Shots.settleWait` は Silent の繰り返しへ寄せる。
- 押す手もフレームで渡す（`TestKit.advance` は `Controls.interact` に `justPressed` の入ったフレームを渡す）。規則の単体テストは残してよいが、待ちを見るテストは App の道だけにする。
- `TestKit.isWaiting` は消して `NovelBeat.waitingOf` を読む。
- テストの時刻はフレームの番号（整数）で書く（`i / 30.0` で作る壁の時刻は、Doc の秒を書いた時刻とビットまで同じになる）。

## 5. 時刻の一致の確かめ方（レビュー M6・M7）

- `bin/fge migrate diff` の events は順だけを見て、待ちを比べない。音の時刻は ±1 フレームで迷った差（`--strict` で止める）。**決め: 小さな口 `--times` を migrate diff に足す（段 0 で足し済み）**。line・choice・wait の `t` を、前の出来事からの間（フレームの数）で比べ、±1 フレームを超えたら迷った差にする（`--strict` で止める）。間で比べるのは、古い版が待ちの明けるたびに 1 フレーム遅れる事がある（walk_tour の 23.433 → 24.267・Closet の 191.067 → 191.6 → 192.133 は +1 フレームずつ、full_story の 181.567 → 182.067 → 182.567 はぴったり）ためで、足し上げると続く `<<wait>>`（haioku.yarn 194〜203 行の Escape など）でずれが積み上がる。古い版の 1 フレームは浮動小数の足し算の丸めで出たり出なかったりするので、真似ない。
- 段 3 の門: 廃屋配信の `make migrate-diff MIGRATE_DIFF_FLAGS="--strict --times"` で止める差が無い（残る差は `migrate-accept.json` に理由つきで）。
- テープの wait の出来事は `<<wait>>` の Hold の頭（`startedOnWall` で引く）の時刻で書く（古い版も bg と同じ 36.5）。
- `Item` は予定の秒と縮めた秒を別々に持つ（`commandedOf`・テープの frames の mid の `seconds` は予定の秒のまま。docs/migrate-diff.md の約束）。
- 台詞の時刻: 古い版は「歩く bg → 台詞」「コメント → 台詞」で、台詞を bg（最初のコメント）の時刻にすぐ積み、字だけを歩きの終わり（最後のコメントの後）へずらしていた。**決め: 古い版に合わせる**。台詞の `Apply`（頁に積む・テープの line の t・オートセーブ）は続いた LineWait の最初の頭、字を出し始めるのは Typed に着いた時（3.3 の #6）。これで line の t とオートセーブの時刻が古い版と同じになる。今のテンプレート（台詞ごと待たせる）からは line の t が変わるので、テンプレートのテストを直す。

## 6. セーブに載せる物（レビュー M2）

- 載せない: `PlaybackLog` と時刻表（どちらも物語の時計と実行器の位置から作り直せる。載せると版が替わった時に表と記録が食い違う）。
- ビートの途中でセーブした時は、ビートの頭の印（前のビートの Read の台詞の `Saves.Mark` = 今の `headMarkOf`）を書く。ビートの途中の実行器の位置は書かない。
- ロードはその印から Silent で当て直す（3.4）。目当ての Read で止まり、そこからの遊びは新しいビートで始まる。

## 7. テンプレートに残る物と engine に入る物

| engine_world（汎用） | テンプレート（ノベル固有の対応だけ） |
|---|---|
| `Timeline.PlaybackLog`・`playbackLog`・`resumeOn`・`seekOn`・`skipToNextWait`・`playheadOn`・`isWaitingOn`・`waitedOn`・`soundsOnWall`・`startedOnWall`（スパイク済み） | 新しい mod `NovelBeat`: `Item`（実行器の出来事 + `Commands.Out` + `Commands.timingOf` から作る）・置き方の決まり（LineWait の頭へ寄せる・`<<wait>>` と流した命令の待ちを頭から重ねる・台詞は続いた LineWait の最初の頭で積む）・`Key`・`waitingOf`・押した時の決まり（3.6）・3.4 の表・実行器を Tick する所 |
| 既存 `App.advanceFrame` / `App.trace`（テストの道） | `World.Read#beat`（`pause` と `hold` の `rest` / `last` を置き換える）・`TestKit` の 1 歩を App の道へ |
| — | 素材が届いたか・字を出し切ったか・押しても送らない秒（ノベルの事） |

置かない物: ノベルの `Item` や置き方の決まりを engine に入れない（実装が 1 つしかない所に層を置かない。`docs/flix-conventions.md` の「層を置く物差し」）。

「なるべく engine に」への残りの候補: 「押して終えられるクリップの印」と「今の再生位置で縮め、後ろの音を外す」純関数は、ノベルの `Item` を知らずに `Timeline.Step` の上で書ける（`withLengthCut(t, step)` のような形）。RPG の会話で 1 本小さくスパイクしてから入れるかを決める（今回はしていない）。

写経元（インターネットダンジョン）から写した所: 演出の拍を 1 本の表に置き、絵（View）も音も描き出しも同じ表を引く形（`src/BattleCue.flix`）と、表の長さを Doc（`assets/internet_dungeon.cue.json` の turnCue）に出して保存即反映で直せる形（`docs/timeline-widget-plan.md`）。ノベルでは表の中身が台本から来るので、Doc に出すのは既定の秒（`commentInterval`・`autoWait`・`skipInterval`・`holdFadeSeconds`）だけ。

## 8. スパイクの結果

`.layers/engine_world` で全量のテストを流した: **Passed 1547・Failed 0**（足したテスト 34 本を含む）。

- `engine_world/test/TestTimelinePlaybackLog.flix`（12 本・engine に残す）: 操作なしで歩き → 着いた音 → 待ちで止まる・seek で歩きを飛ばすと後ろの足音は鳴らず着いた音は 1 回・seek は待ちを越えない・待ちに着く前の早押しは数えない・飛んだ後の resume は待ちから続く・待ちに着いてからの秒・`skipToNextWait` は飛ばした音を鳴らさない・古い `resume` の列で待ちから続く・列の中の待ちに着く前の時刻は数えない（古い形は「着いた瞬間に解いた」と数えていた。`resume` は着く前の時刻を記録しないので、`resume` で作った列では同じ）・`startedOnWall` は頭で飛ばした区間の物も返す・resume をまたいでもクリップの頭は 1 回ずつ・縮めても後ろへ足しても再生位置が続く。
- `engine_world/test/TestTimelineNovelSpike.flix`（22 本・スパイク。本実装でテンプレートの `NovelBeat` とそのテストへ移し、engine からは消す）。フレームの番号（30 fps）で比べる:
  - (1) の並び（束 1: 歩く bg 5.4 秒・音 door / step → `<<audio>>` ×2 → `<<wait 0.8>>`、束 2: `<<set>>` → 台詞）: wait の頭 0・`<<set>>` 162（Tick した時。0 ではない）・台詞を積む 162・字を出し始める 162。wait が 6 秒なら字は 180。音は door / ambience / bgm が 0・step が 60。15 フレームで押すと歩きが終わり wait は残って `<<set>>` と字は 24・step は鳴らない。30 で押すと字は 30。待ちの判断は 0.5 秒 Blocking・1 秒 Tappable。歩き → 台詞は台詞を 0 で積み、字は 162。
  - 続くコメント（c1・ping・c2・c3 → 台詞）: ping 0・台詞を積む 0・字 135。15 で 1 回押すとコメントの全部が終わり字は 15。WaitOrTap なら ping は 45。歩きの後ろで流した押しても明けない待ち（6 秒）は、歩きを押して終えても残る（字は 180）。
  - 字・読み終え・次のビート: 30 で押すと字を出し切り、45 で押すと次のビート（`<<set>>` と台詞が 45）。押すまで次のビートは始まらない。オートは字を出し切った 60 + 45 = 105 で次へ。スキップは 0 で全部当て、歩きの音を鳴らさない。
  - 素材の待ち・ロード: 束の頭で 0 から暗転し 15 で待ちに着き、素材が 40 で届くと戻し始めと命令と字は 40。暗転の途中（5）で届けば 15 で通る。歩く LineWait の頭へ寄せた命令の素材が届いていなければ、束ごと 0 から暗転して待ち、40 から歩き（door）と寄せた音が流れ、足音は 100、字は 202。ロード（Silent）は時計を進めずに Read まで着き `<<set>>` も当てる・素材が無ければ Assets で止まって後ろを当てない・あれば通る。
- 今の World との比べは流していない（1.1 は読んだだけ）。本実装の段 1 で App の道のテストを足して確かめる。

## 9. 本実装の段取りと見積もり（実時間）

各段の門: `../../bin/fge refactor` で呼び手を洗ってから直す・テンプレートは `make test`（変わったパッケージだけ）・engine_world は `make sync-layers` の後 `.layers/engine_world` で `flix test`・コミット前に `bin/fge jargon <触ったパス>`。

| 段 | 中身 | 門 | 見積もり |
|---|---|---|---|
| 0 | engine の口を正式にする: `PlaybackLog` 一式・`startedOnWall`・`agents-pack/AGENTS.core.md` の早見表に 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本・`docs/modules/time.md` の行。`bin/fge migrate diff --times`（5 章。go/internal/migrate・docs/migrate-diff.md・go のテスト）。**済み**（この枝）。スパイクのテストは段 2 でテンプレートへ移す時に engine から外す | engine_world 全量・`go test ./internal/migrate/`・`make agent-eval ONLY=timeline-skip-and-signals` | 2 時間 |
| 1 | `TestKit` を `App.advanceFrame` / `App.trace` の道へ（挙動は変えない）。(1) を App の道で見るテストを足す。TestHold は実時間の dt と `World.paceOf` を通るようになるので一度赤くなりうる（直すのもこの段） | テンプレートのテストが全部緑（(1) の新しいテストは別の担当の直しの後に緑） | 3 時間 |
| 2 | `NovelBeat` と `World.Read#beat` を足し、今の道と並べて走らせる。並走のやり方: 実行器は今の道だけが進め、今の道が `absorbOne` で当てた出来事の束をそのまま beat の後ろへ足す（beat は Tick しない）。beat の `waitingOf` と今の `isWaiting` / `isPaused`、beat の `startedOnWall` と今の道が当てたフレームを比べ、食い違いをテストと flow で一覧にする | テスト緑・flow 6 本の指紋が同じ・食い違いが 3.6 と 5 章の決め（台詞を積む時刻・押した時）の所だけ | 3 時間 |
| 3 | 読み進める道の切り替え: `absorbFrom` / `pauseOrGo` / `flowInstant` / `readOn` の `<<wait>>` と `pause` を beat に。スキップ（毎フレーム `skipToNextWait`）も一緒に移す。実行器の Tick は beat が決める（`NovelBeat` に「Tick の条件は表の終わりと実行器が wait で止まっているの両方」の WhyNot を残す）。reader・ready・`advance`・`autoOrSkip`・`markHere`・`gateOf`・`waitMark`・`commandedOf` を `waitingOf` に。3.6 の新しい動きをテンプレートのテストで 1 本固定。`Pause` の型はまだ消さない（Silent が使う） | テスト緑（(1) も緑）・flow 6 本・廃屋配信の `migrate-diff --strict --times` | 6 時間 |
| 4 | Silent（ロード・戻る・始まりの場面: `restore` / `openAt` / `reopenNode` / `buildEntriesWithin` / `Shots.settleWait`）を beat の Silent の繰り返しに。ここで `Pause` を消す。テストに「ロードで 2 ビート以上を当て直し、目当てが 2 本目の Read」を 1 本足す | 描き出しの基準（SHA256SUMS）が同じ・TestTape・TestMigrate・TestSaves 緑 | 3 時間 |
| 5 | 素材の待ち（`Hold`）・Typed・オート・押しても送らない秒（Lock）を beat に。`World.paceOf` は `waitingOf` を読む | TestHold・TestCast・TestRules 緑・ブラウザ版の素材の待ちの flow | 3 時間 |
| 6 | テープの書き手を beat から読む: E2e（reader / ready）・FlowVideo・テープの events の wait（Hold の頭）・frames の mid の step / seconds（予定の秒）・`talkCursorOf` | TestTape・TestFlowVideo 緑・廃屋配信の `migrate-diff --strict --times` | 2 時間 |
| 7 | レビュー（1 回目で全部出させ、まとめて直して 2 回目）・廃屋配信と血鱗の追随 | レビュー 80 点以上で必須が直っている・2 本の比べ | 3 時間 |

合わせて約 25 時間（段 0 は済み・残り約 23 時間）（11.12 の段 11 の直し 1 つが 1〜2 時間だった実績から。段 3 は道の切り替えと読む所 8 つで重いので 6 時間）。

### 9.1 廃屋配信の比べで「前と同じ」を確かめる

1. 前の版の記録（`haioku-n4-baseline/debug/migrate/baseline`）はもうある。
2. 移行先（新しいテンプレートの上の廃屋配信）で `make migrate-new`、直しを足すたびに撮り直さずに `make migrate-diff MIGRATE_DIFF_FLAGS="--strict --times"`。
3. 見る物: events（line・choice・wait）の並びが同じ・line / wait の間が ±1 フレーム・音の時刻が ±1 フレーム・`Executed.Commanded` の秒（予定の秒）が同じ。食い違いが残る時だけ `migrate-accept.json` に理由つきで書く。
4. 段 2 の並走でも 1 回流し、食い違いが決めた所だけである事を先に確かめる。

### 9.2 血鱗への効き

血鱗の古い版には `Pause`（命令が出す待ち）が無く、待ちは `<<wait>>` だけ（レビューで確かめ済み）。だから 1.2 の重なりは起きず、`<<wait>>` は `append` で前の版と同じ並びになる見込み。払い・タップのゲートは `waitFor(Gate)` になり、`gateOf` が `waitingOf` を読むだけで形は変わらない。ブラウザ版の素材の待ちを使うなら段 5 の flow で一緒に見る。廃屋配信と同じく `migrate-diff --strict --times` で確かめる。

## 10. 決まった事と、相談したい事

決まった事:
1. `<<wait>>` の数え方は古い版と同じ（1.2 の記録。LineWait の後ろは `atStartOf`）。
2. `startedOnWall`（了承時の名前は `startedOnPlayer`。レビューの勧めで `Player` → `PlaybackLog` に替え、接尾も `OnWall` にそろえた）。
3. 実行器は先に引き出さず、表の終わりで Tick して後ろへ足す（3.1）。
4. 押した時は歩きだけを終え、流した命令の押しても明けない待ちは残す（3.6）。
5. 台詞を積む時刻と字を出し始める時刻を分け、古い版に合わせる（5 章）。
6. 時刻の比べは間で ±1 フレーム、`migrate diff --times` を足した（5 章・段 0）。
7. 素材の待ちは束の頭にまとめて置く（3.3 の #8・3.5）。

相談したい事:
1. スパイクのテスト `TestTimelineNovelSpike.flix` は engine に置いたまま枝にある。本実装の段 0 で外し、段 2 でテンプレートへ移す前提。

## 11. 本実装の記録（段 1〜3・2026-11-16）

枝 `novel-waits-timeline`（main 7fcf3cec から）。engine は触っていない（段 0 の口だけを使う）。

### 段 1（5eba847e）

- `TestKit.stepBy` を `App.advanceFrame`（実機と同じ 1 フレーム）に替え、出来事は World の events の差（`Emit.since`）で読む `stepHearing` を足した。`WorldRead.step` を直に呼んでいたテスト 4 か所も寄せた。
- 素材を諦める 2 本（TestHold）は、App の道だと `Controls.step` が stderr に 1 行言ってテストが落ちるので、規則だけの 1 歩（`TestKit.ruleStepBy`）のまま（WhyNot を残した）。
- (1) は flow の reader で流すと再現した: `<<jump>>` で入ったノードの頭の歩く `<<bg>>` の後の台詞が 25 フレーム（`<<wait 0.8>>` の秒）で出る（古い版は 163 フレーム）。台詞を送った所の歩きは 164 フレームで古い版と ±1。テスト `testAWalkingBg…OnTheAppPath` 2 本（162〜164 フレームで合格）を赤のまま入れた。

### 段 2＋3（並走を飛ばして切り替え）

- **段 2 の並走は飛ばした。** 並走のためだけの写しを World に持たせるより、切り替えて既存のテスト 578 本・flow 6 本・テンプレート自身の `migrate diff --strict --times`（段 1 の版との比べ）で見る方が安く、同じ物を確かめられたため。
- テンプレートに `NovelBeat`（純粋）を足し、`World.Read#pause` を `World.Read#beat`（`World.BeatRun`: ビート・頭の物語の時刻・このフレームの待ちの判断）に替えた。`World.Pause` は消した（Silent の当て直しは Commands.execute が待ちを落とすので Pause を使っていなかった。段 4 まで残す理由が無かった）。
- 人が読み進める道: 入力（送る・選ぶ・はじめから）で新しいビートを始め、実行器が返した束を待ち方で分けて並べる（命令は今の舞台に当ててみて出した待ちを読む）。毎フレーム `settleBeat` が「頭を過ぎた出来事を時刻の順に当てる → 字を出し切った Typed を解く（スキップなら次の待ちへ飛ぶ）→ 表の終わりで実行器が `<<wait>>` で止まっていれば Tick して続きを足す」を繰り返し、最後に `NovelBeat.waitingOf` を `BeatRun#waiting` に書く。reader・ready・送り・送りの印・セーブ・ゲートは全部 `waiting` を読む。
- 決めの細り: **実行器の `<<wait>>` は束の最初の出来事の頭から数える**（実行器が束を返した時刻 = 古い版の `waitUntil` の起点）。LineWait の頭と同じ時刻なので 1.2 の記録どおりになり、`<<audio se 音 wait=true>>` の後ろの `<<wait 2>>` も重なる（TestAudio の `testSeWaitAndAWaitBehindOverlap`。Commands の冒頭の WhyNot と同じ動き）。
- 押した時: 演出の途中なら `NovelBeat.tapped`（押すと明ける待ちを今まで縮める・縮めた歩きは終わりの形）→ ビートを進め、字も出し切る。
- 素材の待ち（Hold）は今の段の仕組みのまま、束を足す所（`feed`）で束の中の未着の素材を集めて束ごと預ける（N1 の「束の頭」）。届いたら `resumeHold` が束を足す。
- 字: 演出の待ちの途中は字を進めない（台詞は続いた LineWait の最初の頭で頁に積み、字は Typed に着いてから）。
- テスト: 待ちの中身（Pause・takeOut・rest）を直に作っていたテストは、`WorldRead.beginBeat`（出来事の束を新しいビートとして流し始める）で作る形に替えた。「切り替えの間に台詞は出ない」は「頁に積むが字は 0」に替えた（5 章の決め）。

### 門の結果

- テンプレート: check 緑・test 578 本緑（段 1 で赤だった (1) の 2 本も緑）・flow 6 本は全部 ok（フレームの数は段 1 の版と同じ。指紋は 4 本で変わった — 指紋は World の events の数を含み、比べの記録の差は 0 件なので、出来事の数え方だけの違いと見る）。
- テンプレート自身の `make migrate-new MIGRATE_DIFF_FLAGS="--strict --times"`（基準は段 1 の版で撮った物）: 止める違い 0・迷った差 0・比べたコマ 439 枚。落ちたのは「どの flow も通らない命令の行」15 行（flow がそこを通らないだけで、待ちの直しとは関係しない）。

- 描き出しの基準（reference-check）: 45 枚すべて一致・予算の内側。
- `wallOf` に 1 マイクロ秒を足した後の flow 6 本: 全部 ok。showcase は 2197 → 2193 フレーム・tape は 425 → 424 フレーム（待ちが明けるのが 1 フレーム早くなる所がある。前の版は浮動小数の足し算の丸めで 1 フレーム遅れる事があった）。テンプレート自身の `migrate diff --strict --times` は止める違い 0・迷った差 17 件（showcase と tape の画面の物の出ていた区間が 1〜4 フレーム早い。頭からの時刻で比べる欄なので遅れの分が積み上がる。間の比べ（--times）は全部 1 フレームの内）。5 章の決め（前の版の 1 フレームの遅れは真似ない）のとおり。
- 廃屋配信（haioku-n4-migrate）: test 598 本緑。`make migrate-new` → `migrate diff --strict --times`: 止める違い 3 件・迷った差 826 件・比べたコマ 676 枚（直す前は止める違い 5 件で、4 本の flow が出来事の並びで止まって後ろを比べていなかった）。(1) の所（Inside#0 の wait と最初の台詞の間）は差が消えた。残る止める 3 件はどれも直す前からある物: full_story・walk_tour の Inside#34/35 の音の順（bgm_suspense と se_comment。直す前の記録にも同じ差）・stairs の頭の amb_house（`start talk node=` で始める flow の舞台を Gate から流して作る差。bookmark・showcase は承認済みの同じ種類）。間の迷った差の多くは、続いたコメントの後ろの台詞で新しい版が 1 コメント（0.633 秒）遅い所で、古い版の flow の reader がコメントの間にも押していた（L）ため。テンプレートの reader は L の直しのとおり待ちの間は押さないので、承認か reader の取り決めの相談に回す。

### 廃屋配信で見つかって直した物

- 描き出しの場面（GameShots の settleWait: 実行器の明ける時刻へ据え直して進める）が止まらなかった: 頭 2.6 秒・今 3.5 秒の差が 0.8999… になり、実行器が 3.5 秒に明けると決めた `<<wait 0.9>>` がビートの上でまだ明けない。`WorldRead.wallOf` に 1 マイクロ秒を足した（WhyNot を残した）。束を足す時の過ぎた秒は 1 ミリ秒より短ければ置かない。
- 台詞を続いたコメントの最初の頭で先に積むと、後から当てる 2 つ目のコメント（台詞より上の行）でノードに入り直したと数え、台詞の番号が 0 に戻った。台本の順より後に当てる出来事では、ノードの入りと実行位置（talkCursorOf）を動かさない（`absorbOne` の inOrder）。
- 移行の記録の書き手（MigrateOut）: 台詞を先に積んだ後に記録される前の命令（続いたコメントの 2 つ目から）を「その台詞の次の出来事」に数えていて、台詞を出し終えたコマが撮れず、コメントの途中のコマの番号もずれた。台本の順より後に記録された命令（同じノードの同じ訪問で、もう記録した台詞より上の行）は、次の出来事に数えず、先に積んだ台詞の前の命令として番号と時間を取る命令の数を続ける（段 6 の一部を前出し）。
- `migrate diff --times` の許す幅を 1 フレーム + 1 ミリ秒にした（tape.json の t はミリ秒に丸めてあり、1 フレームの遅れが 0.034 秒に見える）。
- 廃屋配信の側で替えたのは、テンプレートが持つファイルの写し（NovelBeat・World・WorldRead・ViewText と待ちのテスト 5 本）と、GameShots の 1 行（`r#pause` を `WorldRead.isPaused` に）・engine の fpkg と packages.lock の指紋（段 0 の Timeline.PlaybackLog が要る）だけ。台詞と地の文は替えていない。

### レビュー 1 回目（74 点）の直し

- 必須 1: 当て直し（ノードを開き直す reopenNode など）が実行器の `<<wait>>` で止まると、ビートが空のまま誰も Tick せず止まっていた。当て直しが `<<wait>>` で止まったら、その待ち 1 つのビート（`NovelBeat.runnerWaitBeat`）を始める（`WorldRead.absorb` の終わり）。待ちの持ち主はビートだけになり、`isWaiting` と `markHere` の実行器を別に見る判断は消した。テスト: 作例の最初のノード（頭に `<<wait 2>>`）を開き直すと、待ちが明けて最初の台詞へ進む。
- 必須 2: 台詞を先に積んだ後に当たる命令の舞台が、その台詞の戻れる所（Mark）に入っていなかった。後から当てた時に、バックログの頭の戻れる所と、同じ所を書いたオートセーブの舞台を入れ直す（`WorldRead.refreshHeadMark`）。待ちの間のセーブを 1 つ前の台詞へ戻す形は、先に積んだ台詞がもう頁とバックログに出ていて、戻すと読んだ行がもう一度出るので採らなかった（WhyNot を残した）。テスト: 戻れる所に後の環境音が入り、戻すと環境音が残って先へ進む。
- 推奨: 押しても明けない待ちだけの間に押した時は何も替えない（縮める待ちが無ければ Paged も既読も出さない。押すと明ける待ちが重なっていれば縮める — WhyNot）。`advance` は `BeatRun#waiting` を読む。ビートの頭からの秒に足す幅は `NovelBeat.wallOf` 1 か所。`settleStep` は 1 回りに時刻表を 1 回だけ組む（読む口は組んだ表を受け取る）。MigrateOut の「台本の順より後に記録された命令」の判断は `nextFramesOf` の印 1 か所。go のテストに「1 フレーム + 2 ミリ秒は迷った差」を足した。歴史のコメントを消した。

### 置き方の決めの細り（音の順を古い版とそろえる）

- LineWait の後ろの命令は、時間を取る命令も含めて**続いた LineWait の最初の頭**へ寄せる（古い版は束の命令を全部その場で当てた。コメントの後ろの `<<bg>>` と `<<audio bgm>>` が 1 コメント遅れて、Inside#34 の音の順が食い違っていた）。
- 続いた LineWait どうしは前の LineWait の後ろに並ぶ（コメントは 1 つずつ間を空けて出る。最初の頭へ重ねるとコメントが全部同じ時刻に出て、効果音も 1 回にまとまる）。
- 承認（人の決め）: 続いたコメントの後ろの台詞が新しい版で 1 コメント遅い差は intended（古い版の flow の reader がコメントの間にも押していたため。ゲームの振る舞いの違いではない。reader の取り決め（待ちの間は押さない）は替えない）。stairs の頭の amb_house は bookmark・showcase と同じ種類として intended。

### 血鱗の洗い出しの穴（P〜V）の進み

- P（済み・86b3fcd1、レビュー 2 回目で直し）: version 2 の欄だけの枠（`Saves.StageForm.Partial`）は、当て直した舞台に背景・環境音・particles・mode を重ねる。人物は当て直した方（v2 の cast は使わない）。
- S（済み・86b3fcd1）: `GameE2e.drives()` を `E2e.table` の reader の後ろに並べる（ゲームの持ち物なので、追随するゲームは `drives() = Nil` を足す）。
- Q（済み・f3f1cd61）: `GameCommands.onLine(ctx, stage)`。台詞を頁に積む所で呼ぶ（選択肢は数えない・当て直しでも呼ぶ）。追随するゲームは `onLine` を足す。
- U（吸収済み）: flow の ready はビートの待ちだけを見るので、実行器の `<<wait>>` の間も Busy（`isWaiting` は `isPaused` と同じ物だったので `isPaused` 1 本にした）。
- R（済み・c88eb615）: `ThemeDoc.PortraitText.Frame(center)` と `ViewText.messageFrameOf`。
- T（済み）: `novel.story.json` の `gameLabels`（ゲームが決める鍵 → 言葉）と `StoryDoc.gameLabelOf(鍵, 既定, doc)`。`Label` の enum には足させない。
- V（済み）: GameView の頭に、立ち絵の矩形は `Cast.placedOf(ViewStage.castEnv(env, stage), stage#cast)` で引くと 1 行。
- レビュー 2 回目の推奨: 待ちの間のセーブは、先に積んだ台詞より前でまだ当てていない命令を試しに当てた舞台で Mark を作る（`WorldRead.withCommandsBehind`）。
- 廃屋配信: 止める違い 0（承認 9 件。台本の reader の押し方 L の 6 件と、頭の環境音 3 件）。

### 廃屋配信の絵の違い 3 件（迷った差の分析から）

- Gate の頭（0.4〜1.2 秒が暗い無地）: テンプレートの black は前の背景が無くても半分の秒を暗くなる側に使っていた（古い版の `dark` は前が無ければ全部の秒で明ける）。**直した**: 前の背景が絵を持たない（無い・blank）時は、暗い所から全部の秒で明ける（`ViewStage.isFromDark`）。
- Inside#35 → Upstairs の歩き: コメント（LineWait）の後ろの `<<jump>>` の先の歩く `<<bg>>` が、続いた LineWait として後ろに並び、コメントの秒（0.65 秒）だけ遅れて歩き出していた。古い版はコメントと同じ頭で歩き出す。**直した**: 背景を替えた命令の LineWait は `Kind.SwitchWait` で、続いた LineWait の最初の頭から重なる（コメントどうしは今まで通り後ろに並ぶ）。
- Found#0 の暗さ: blank の写真（暗闇）の地がテンプレートの夜の紺（10,13,20）で、古い版はほぼ黒（3,3,4）。**直した**: `novel.backdrops.json` の `ground`（地の色）で替えられるようにした（無ければ今の紺）。廃屋配信は追随の時に `"ground": "#030304"` 前後を書く。
- 廃屋配信はリリースのため止めてあるので、この 3 件の写しは再開の後。
