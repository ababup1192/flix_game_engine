# ノベルを作る（手本 sound-novel-starter の口）

ノベルの機能は手本 `templates/sound-novel-starter` にある。機能ごとの書く所と読む所の表は、手本の README.md の
「ノベルゲームの機能と、どこで読むか」。この文書は、エージェントの早見表（`agents-pack/AGENTS.core.md`）から外した細かい決まりを置く。

## 縦が基本（スマホ）

- project.json の design は縦の 540×1170・ウィンドウは縦長（360×780）・`web.portraitDesign` は残す
- 背景の写真は縦長で生成し 720×1560 に真ん中で切って、`novel.backdrops.json` の photos に `aspect`（横÷縦）を書く
- `<<camera>>` の x・y は画面（＝縦の写真）の幅・高さが 1
- flow は縦の 1 本（点は縦の design の座標・右の列も `tap x,y`）・`make tape` も縦の 1 本
- PC の窓を横に広げた時の左右の余白は背景を広げて塗る（`App.withLetterboxView`・[web-export.md](web-export.md) の「窓の余り」）
- 横のゲームから移す手順は `docs/migrations/0.101.0.md`。手本の `AGENTS.local.md` の「縦が基本」も読む

## 立ち絵と小物（`<<show>>`・`<<hide>>`・`<<move>>`）

- シナリオ: `<<show 名前 [表情] [at=位置] [from=端] [time=秒]>>`・`<<hide 名前>>`・`<<hide all>>`・`<<hide at=位置>>`・
  `<<move 名前 x= dx= scale= alpha= rotate= from= to=>>`（props の名前は小物として出る・何人何個でも出せ、`exclusive` の位置には 1 つ）
- 位置と人物・小物は `assets/novel.cast.json`（`slots` / `portraitSlots` / `cast` / `props`・`faces` は表情の名前・`layer` は重ね順・`attach.bg` で背景に付く絵）
- 絵は project.json の textures に `cast_<名前>_<表情>`（透過 PNG）。元の絵は `python3 art/cast/prepare.py <置き場>` で縮めて縁を埋め、
  `make lint-cast` が登録の抜けと縦横の比（Doc の `aspect`）を見る
- 重ね方と描き方は手本の Cast モジュール（apply・items）。セーブは `Saves.Mark` の `stage`（台詞の時点の舞台の全部 `Stage.Snapshot`。戻す時は舞台と頁をこの値で置き換える）

## 演出コマンドを 1 つ足す（`GameCommands`）

ゲームの `GameCommands.all()` に `Commands.Command` を 1 つ足す。セーブ・settle・素材待ちは書かない（どれも `Stage` にあるので汎用の道を通る。Saves や WorldRead に case を足さない）。

- `spec` = `YarnCommands.spec` の引数の表・`timing`（`Timed` / `Instant`）・
  `apply`（`Ctx`・引数・舞台 → 新しい舞台と `Commands.Out` の列（頁をめくる・音・合図））・`needs`（待つ素材）
- 後に残る値は `Stage` の `props`（`PropertyTween` の `game.` で始まる鍵。`tween`・`setName`・`trigger`・`delay`）に書いて `GameView.draw` で描く
  （`(層の数, 物)` を返す。背景 0・人物 500・小物 600 と同じ数で ViewStage が並べる）
- `make talk-vocab` で vocab.json（ゲームの命令）と vocab.std.json（テンプレートの命令。追随で上書き）に書き出すと、`bin/fge yarn build` が合わせて引数を見る
- テンプレートのコマンド（bg・window・text・speak・audio・fx・shake・overlay・camera・tween・show・hide・move）は `Commands.all()`
- 人物・背景・覆いを替える時は台本と同じ 1 行を `Commands.applyText` で当てる（Cast に直に触らない）
- 台本から `game.` の数を動かすのは `<<tween 鍵 値 time=>>`（`lair.arrive` が `game.lair.arrive`。`game.` は書かない）
- 3D の背景・歩いて替わる切り替え・HUD・ゲームの Doc と後から届く素材は `GameView.backdrop`・`GameCommands.backdropSwitch`・
  `GameView.hud`（文字の枠の覆いより奥か本文の上かの帯を付けて返す）・`GameRes`・`GameBoot` の口（テンプレートのファイルは直さない）
- `apply` は頁をめくった数 `Stage#pages` を読め、`Stage.withWindowHidden` で文字の枠と字を消せる（次の台詞で戻る）

### 待たせる（`Commands.Out.Wait`・`WaitOrTap`・`LineWait`）

| 出す物 | 待ち方 |
|---|---|
| `Commands.Out.Wait(秒)` | `<<wait>>` と同じ。押しても明けない |
| `Commands.Out.WaitOrTap(秒)` | 物語の時計で秒だけ待ち、送りの操作で明ける（明けた時はゲームが持つ背景の切り替えも終わりの形）。オートでは明けない・Silent とスキップでは 0 秒 |
| `Commands.Out.LineWait(秒)` | 後ろの時間を取らない命令（`<<audio>>` など）は止めず、次の台詞だけを待たせる。押すと明け、台詞・選択肢・`<<wait>>`・時間を取る命令で止まる（`GameCommands.backdropSwitch` の切り替えの秒もこれ） |

flow の reader は命令が出した待ちの間は押さない。移行の記録では `wait` にならず、その命令の `seconds` に入る。

## 引数を型付きで読む（`YarnCommands`）

引数の表を `YarnCommands.spec` と `YarnCommands.Param`（`num`・`choice`・`name`（Doc の ref）・`at`・`required`・`default`・`orWords`・`marker`・`scopedBy` ほか）で書き、
`YarnCommands.toJson` を vocab.json の `commands` に書き出すと、`bin/fge yarn build` が台本の `<<名前 位置 key=value>>` の型・範囲・知らない鍵・Doc に無い名前を実行の前に止める。
実行時は `YarnCommands.parse` → `Param.get`（見本 `go/internal/yarn/testdata/command-args.json`）。引数を `c#args` から手で読まない。

## 名前を Doc に置いて build で照らす（vocab.json の版 2）

会話の話し手・変数の表示名・最初のノード・描き出しの場面のノードを Doc に置き、台本の名前と build で照らす（名前を足すのに Flix を走らせない）。

- `"speakers": {"from": [{"doc": "../novel.story.json", "keys": "names"}]}`
- `"nodes": {"from": [{"doc": …, "path": "opening"}]}`
- `"nodeRefs"`（あるかだけ見る・届かないノードの起点に混ぜない）
- `"vars"`（表示名の無い変数を知らせる）
- `bin/fge yarn check <Doc>` は、その Doc を from に書いた語彙のフォルダを見る（手本 `templates/sound-novel-starter/src/Talk.flix` の vocabJson・場面は `templates/sound-novel-starter/assets/novel.shots.json`）

## ライターにシナリオを読ませる（`bin/fge yarn script`）

- `bin/fge yarn script <シナリオのフォルダ>`: シナリオ原稿の Markdown を build/yarn-script.md へ（名前「台詞」・〔演出〕・（間 N 秒）・◆ 選択肢・→ jump）
- `bin/fge yarn script --diff <直した.md> <フォルダ>`: 差分を .yarn のファイル:行と、そのまま貼れる行で出す
- 〔〕の言葉はフォルダの `script-notes.json` か、.yarn の冒頭の `//   <<名前 …>>  説明` の行
- テープの頁（`bin/fge tape`）は「映像 / グラフ」の切り替えと「シナリオ原稿 .md」のボタンを載せる

## 演出の既定をゲーム全体で替える（Doc の欄）

Flix は直さない。その行だけ替えるなら命令の引数（`time=`・`ease=`・`<<text align=>>`）。

| 替えたい物 | Doc の欄 |
|---|---|
| 暗転の止まり・背景の切り替えの秒と曲線・既定の切り替え方 | `novel.backdrops.json` の `black`（`fadeOut`・`hold`・`fadeIn` の比）・`defaultSeconds`・`defaultEase`・`defaultTransition` |
| 立ち絵の出入りの濃さの曲線・話し手を明るく・小物の重なり | `novel.cast.json` の `fadeEase`・`highlight`（`dim`・`seconds`・`voices` = 立ち絵の無い話し手・`narration` の `keep`）・`propsOnPage` と小物ごとの `onPage` |
| 文字の枠を消す秒・覆い・揺れ・字の大きさの名前 | `novel.kind.json` の `windowFadeSeconds`・`overlayStart`・`overlayLayer`・`shakes`・`textSizes` |
| 型ごとの字の揃え | `novel.theme.json` の `windows.<型>.align` |

## 画面の演出（背景・覆い・寄り・揺れ・音・粒）

| コマンド | 決まり |
|---|---|
| `<<bg 写真 transition=fade\|black\|wipe\|slide\|pan\|cut pace=walk\|run>>` | 既定は `novel.backdrops.json` の `defaultTransition` |
| `<<overlay 濃さ color= from= layer=stage\|screen>>` | 始まりと層の数は `novel.kind.json` の `overlayStart`・`overlayLayer` |
| `<<camera zoom= x= y=>>` | world の層だけ |
| `<<shake 名前\|px on=screen\|window\|絵の名前>>` | 名前は `novel.kind.json` の `shakes` |
| `<<audio ambience a,b volume= fade=>>`・`<<audio bgm 音>>`・`<<audio se 音 wait=true>>`・`<<audio all off>>` | 音量の名前 `volumes` と効果音の後に送れない秒 `lockSeconds` は `novel.mixer.json` |
| `<<fx 名前 once=true>>` | `novel.effects.json` の `particles`（`look`・`layer`） |

world の層は `ViewStage` が層の数で並べ、値は全部 `Stage` の `props`（`camera.*`・`overlay.*`・`audio.*`・`actor.<名>.*`）なので、セーブと settle は汎用の道を通る。

## メッセージ枠と話し手

- `<<window 型|clear|off|on time=>>`: 型は `novel.theme.json` の `windows`（`kind` nvl|adv・`place` bottom|center・`frame` panel|outline・`showName`・`quotes`。名前 Nvl・Adv は使えない）
- `<<text at= size= align= speed= lock=>>`: 大きさの名前は `novel.kind.json` の `textSizes`
- `<<speak 名前>>`: 字を出さずに話す。項目の `speakFx` で粒を出す
- `<<fx 名前 on=絵.点>>`: 引数の型 `Param.marker`。点は `novel.cast.json` の項目の `markers`・点から出せるのは `look: puff` の粒
- 台詞ごとに World が `cast.speaker` を書き、`novel.cast.json` の `highlight`（dim・seconds）でほかの人物を暗くする。項目の `hideWindow` で、出ている間は文字の枠を消す
- 表情は `Param.scopedBy` で名前ごとの `faces` を build が照らす

## 払い・タップで選ぶ選択肢（`#act:`）

- 組の全部に `#act:up|down|left|right|tap` を付けた選択肢（`#at:当たる物`・`#icon:絵`・`#mute`）は、ボタンを出さず案内を出して払いを待つ
  （`Gate`・`WorldRead.passGate`。選んだら `Choose` の道なのでセーブと戻るはそのまま）
- 案内の絵と色・矢印・端の帯・当たる物の矩形・輪は `novel.prompts.json`（`#at:`・`#icon:` の値は build がその鍵で照らす）
- キーは ↑↓←→ / WASD と `flickUp`・`flickDown`（ブラウザ版の縦の払い）、マウスはドラッグ。オートとスキップはゲートで止まる
- flow は `until gate=left|down` で待ち、`tap left` などの役のキーで選ぶ

## ブラウザ版で素材が届くまで待つ間の印

`novel.theme.json` の `loadingMark` = `dots`（右下の点 3 つ）/ `ring`（真ん中の回る輪と「読み込み中」のラベル）/ `none`（黒だけ）。
ラベルの字は `novel.story.json` の labels の `waiting`・知らない値は dots。描くのは View の `loadingMark`（待ちの黒 `holdLayer` と、写真がまだ届いていないセーブの枠のサムネが同じ関数を引く・動きは実時間）。
出すまでの秒は `novel.kind.json` の `holdMarkSeconds`。

## ゲームだけの値を flow の問いに載せる（`GameE2e.probes`）

場所・視聴者数・配信中か、のようなゲームだけの値を flow の問い（`until`・`expect`）と移行の記録に載せるには、
ゲームの持ち物 `<ゲーム>/src/GameE2e.flix` の `GameE2e.probes()` に `{ name, doc, read = Flow.Probe.Num|Text|Flag(…) }` を足す。

- テンプレートの `E2e.table` が自分の問いの後ろに並べ、移行の記録にも載る。テンプレートの問いと同じ名前は TestTape が止める
- テンプレートの `E2e.flix` は直さない
- シナリオの変数は書かなくても移行の記録に `$名前` で載る
