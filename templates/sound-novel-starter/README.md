# 雪どけを待たない便り

flix_game_engine のサウンドノベルの手本。冬の山里で午前だけ郵便の配達を手伝う灯が、坂の上の工房の窓から
凍る場所を描いた地図を受け取り、木版画家の冬馬と便りを交わす。10 分ほどで読み終わり、選び方で結末が 3 つに分かれる。

背景は昼の光の実写風の絵（画像生成。作り方は [CREDITS.md](CREDITS.md)）を使い、
**ぼかしと時間帯の色はゲームの中でシェーダーが付ける**（同じ昼の絵が、夕方にも灯りの下にも夜にもなる）。
文章は小説のように画面いっぱいに積む NVL と、下のウィンドウに 1 行ずつ出す ADV を、場面ごとに切り替える。
字は明朝（しっぽり明朝・OFL）。

## 始め方

Flix コンパイラはエンジンリポの `bin/flix` ラッパ経由で呼ぶので、devbox shell の外でも動きます。

| コマンド | 何をするか |
|---|---|
| `make run`    | ゲームを起動する（ウィンドウが開く） |
| `make debug`  | 保存即反映(watchFile)と F8 を有効にして起動 |
| `make check`  | 型検査だけ（一番速い確認） |
| `make test`   | テスト（規則・Doc の橋渡し・性質テスト） |
| `make render SHOT=nvl` | その場面だけ `debug/nvl.png` へ描き出す（場面は `title nvl adv choice lane engawa night morning log save load settings ask credits`） |
| `make render-all` | ギャラリー PNG を全部描き出す |
| `make flow FLOW=e2e/true_ending.flow` | タイトル画面から結末までを画面なしで流す（`e2e/bookmark.flow` はセーブとロード） |
| `bin/fge yarn build assets/talk` | シナリオを直した後に木（`assets/talk/dialogue.json`）を書き直す（エンジンの `bin/fge`） |
| `bin/fge snd build art/sfx.snd.star` | 環境音・効果音を作り直す（`atelier/sfx/` に書く。採用は `assets/sfx/` へ写す） |

## 遊び方

クリック / Enter / Space / Z で読み進める。文字が出ている途中で押すと全文が出る。
選択肢は ↑↓（またはマウス）で選んで決定。下の帯のボタンか、キーで:

| 操作 | キー |
|---|---|
| 戻る（1 つ前の台詞から読み直す。ロールバック） | PageUp / R |
| バックログ（画面のボタンからも開く。中はホイールで遡る。台詞を押すとそこへ戻る） | L |
| オート（読み終えて少し待つと送る） | O |
| スキップ（既定は読んだ行だけ。選択肢の後に止めるかは設定） | K / Tab |
| クイックセーブ・クイックロード | F5 / F9 |
| ウィンドウを隠す（写真だけを見る） | H / Esc |
| セーブ・ロード・設定・タイトルへ | 下の帯のボタン |

ブラウザ版の指: タップと上下の払いで 1 行送る（`web.touchGestures` の `swipeUp` / `swipeDown` が `flickUp` / `flickDown` のキー。払いで選ぶ選択肢では上下の払い）・左へ払うと 1 行戻る・長押しでウィンドウを隠す（`longPress` が指の長押しだけの `touchHold` のキー。縦の画面の右の列の上ならボタンの名前を出し、オートはスキップに入る）。

- **セーブ・ロード**: 枠は 1 ページ 6 枠（2 列 × 3 行）。ページは「オート」「クイック」と番号の 3 ページ（Q / E で切り替え）。
  枠にはセーブした時の画面をそのまま縮めたサムネ・保存した日時・場所・話し手と台詞の頭が出る。上書き・削除（× か Delete）・
  読んでいる途中のロードは確認のウィンドウで尋ねる。オートセーブは場面（ノード）が変わるたびにオートのページの頭へ積む。
  ロードの画面は一番新しいセーブのページから開き、「続きから」は一番新しいセーブを読む。
- **設定**: 文字の速さ・オートの待ち・スキップする行（既読だけ / すべて）・選択肢の後のスキップ（止める / 続ける）・
  画面（ウィンドウ / 全画面）・全体と環境音と効果音の音量・ウィンドウの濃さ・初期設定に戻す。文字の速さの見本がその場で流れ、最大にするとノーウェイト（行を一度に全部出す）。
  スライダーはクリック・←→ に加えて、押したまま（指なら横へなぞったまま）動かしても変わる（離すまでは最初に掴んだスライダーだけが動く）。
- 閉じるボタンとタイトルへ戻るは確認のウィンドウを出す。ウィンドウを開いている間は物語の時計が止まる（文字送り・待ち・オートが進まない）。

キーの割り当ては `assets/novel.keys.json`。セーブ・既読・設定は `saves/novel.json` に残る（遊んだ人ごとの物なので git には入れない）。

## ノベルゲームの機能と、どこで読むか

| 機能 | 書く所 | 読む所 |
|---|---|---|
| 台詞・地の文・話し手 | `assets/talk/yukidoke.yarn`（Yarn Spinner の書き方） | `WorldRead.absorb` / `showLine` |
| ルビ（`[ruby=よみ]字[/ruby]`） | 同上 | `ViewText.placeLine`（エンジンの `RichText.placeRuby`） |
| 選択肢・条件つきの選択肢・変数 | `-> …` `<<if>>` `<<set>>` `<<declare>>` | `WorldRead.pick` / `moveChoice` |
| 背景の写真を時間帯の色でぼかして切り替える | `<<bg 写真 grade=時間帯 time=秒 [transition=fade\|black\|wipe\|slide\|pan\|cut] [pace=walk\|run]>>` + `assets/novel.backdrops.json`（`defaultTransition`） | `src/Backdrop.flix`（ShaderDoc の `TexBlur`） |
| メッセージ枠の型（NVL ⇄ ADV・置き場・字幕の形）・頁をめくる・文字の枠を消す | `<<window 型>>`（型は `assets/novel.theme.json` の `windows`。作例は `nvl` と `bottom`）`<<window clear>>` `<<window off\|on [time=]>>`（off は次の台詞で戻る） | `Page.show` / `Commands` の `window`・`ViewText`（頁の出来事 `Out`・めくった数は `Stage` の `pages`・消す値は `Stage.windowHiddenKey`） |
| 字の置き場・大きさ・揃え・速さ | `<<text at=top\|center\|bottom size=名前 align=left\|center speed=倍率 lock=秒>>`（大きさの名前は `novel.kind.json` の `textSizes`） | `ViewText`・`Stage.textScaleOf` |
| 話し手を明るく・字を出さずに話す・出ている間は枠を消す | 台詞の話し手（id は cast の鍵とそろえる）・`<<speak 名前>>`・`assets/novel.cast.json` の `highlight` と項目の `markers`・`speakFx`・`hideWindow` | `WorldRead.showLine`（`cast.speaker`）・`Cast.brightnessOf`・`Cast.hidesWindow` |
| 払い・タップで選ぶ選択肢（入力の案内） | `-> 本文 #act:up\|down\|left\|right\|tap [#at:当たる物] [#icon:絵] [#mute]`（組の全部に `#act:`）+ `assets/novel.prompts.json`（icons・arrow・edge・targets・pulse） | `Gate`・`WorldRead.passGate`・`Controls` の `gateInputOf`（払い・タップ・↑↓←→）・`Hint`（案内の絵）・e2e の問い `gate` |
| 環境音（ループ）・音楽・効果音 | `<<audio ambience 音[,音] [volume=] [fade=]>>` `<<audio bgm 音>>` `<<audio se 音 [wait=true]>>` `<<audio all off>>`（音量の名前 `volumes` と効果音の後に送れない秒 `lockSeconds` は `assets/novel.mixer.json`）（音は project.json の sounds の名前）+ `art/sfx.snd.star` | `Controls.ambience` / `soundOf`・音量は `assets/novel.mixer.json` のバス（名前が `amb_` で始まる音は環境音のバス・`se_` と `ui_` は効果音のバスへ振り分ける。ほかの名前は defaultBus）|
| 画面の演出（蛍・雪・立ちのぼる粒・揺れ・覆い・寄り） | `<<fx 名前 [once=true] [on=絵.点]>>`（粒の表と層の数は `assets/novel.effects.json`。点は `novel.cast.json` の `markers`・点から出せるのは `look: puff`） `<<shake [強さ] [on=screen\|window\|名前]>>` `<<overlay 濃さ [color=] [from=] [layer=stage\|screen]>>` `<<camera zoom= x= y=>>`（粒子の数・雪・揺れの強さ shakes・覆いの始まりと層の数は `assets/novel.kind.json`） | `ViewStage`（world の層を層の数で並べる・カメラと揺れ）/ `Stage.shakeOffset` |
| 待ち | `<<wait 秒>>` | エンジンの YarnRunner が待つ |
| 立ち絵と小物（何人・何個でも出す・表情や位置を替える・消す・端から滑る・動かす） | `<<show 名前 [表情] [at=位置] [from=left\|right\|top\|bottom]>>`・`<<hide 名前\|all [to=…]>>`・`<<hide at=位置>>`・`<<move 名前 x= y= dx= dy= scale= alpha= rotate= [from=] [to=] [time=]>>`（小物も同じ。props の名前は小物として出る。`exclusive` の位置には 1 つだけ。背景に付く絵は Doc の `attach.bg`）+ `assets/novel.cast.json`（位置・人物・小物。例は note）+ project.json の textures に `cast_<名前>_<表情>`。作例の物語では冬馬（3 表情）と手描きの地図（小物）を出す | `src/Cast.flix`（意味・重ね方・置き場所・描き方）・`View.castLayer`・セーブは `Saves.Mark` の `stage`（`Stage.Snapshot`）。素材は `python3 art/cast/prepare.py <元の絵の置き場>` で縮めて縁を埋め、`make lint-cast` で登録と縦横の比を見る。確かめ方: 描き出しの `cast-sample`・`portrait-cast-sample`・`portrait-cast-veil`（テスト用の絵 `assets/cast/_sample_plain.png` は `art/cast/sample.py` が作る） |
| 文字送り・オート・スキップ・既読 | 速さは `assets/novel.kind.json` と設定の画面 | `WorldRead.step` / `autoOrSkip` / `markSeen` |
| バックログ・そこへ戻る | 行数は `novel.kind.json` の `logMax` | `WorldLog.scrollLog` / `jumpTo`・`View.logPanel` |
| ロールバック | — | `WorldLog.rollback`（ログの各行に、その行を出した時のブックマークを持たせる） |
| セーブ・ロード・クイック・オート | ページと枠の数は `Saves.tabs` / `perPage` | `WorldSaves.writeSlot` / `loadFrom` / `quickSave`（YarnRunner のブックマークと、その台詞の舞台 `Stage.Snapshot` と頁と、ノードに入った時の舞台）・`src/Saves.flix`（JSON は version 3。version 2 も読む）・`WorldRead.restore`・`View.slotsPanel` |
| 確認のウィンドウ | 文言は `novel.story.json` の labels | `World.askFor`・`WorldMenu.answer`・`View.askLayer` |
| 設定 | スライダーの範囲は `novel.kind.json` の `*Slider` | `WorldSettings.adjust` / `activate` / `withLevel` / `withSide`・`View.settingsPanel` |
| タイトル画面・クレジット | `assets/novel.story.json`・`assets/novel.credits.json` | `View.title` / `View.credits` |
| スマホ（横持ち）の字とボタンの大きさ | `assets/novel.small.json` | `Layout.Fit.Small` |
| ブラウザ版で背景・音をタイトルの後に裏で取る（届く前の背景・環境音は暗転して待ち、20 秒で諦めて進む。一発の効果音は鳴らさず進む） | `project.json` の `web.deferred`（タイトルの写真と最初に鳴る音は入れない）・`web.compress`・秒は `novel.kind.json` の `hold*`・待つ間の印は `novel.theme.json` の `loadingMark`（`dots` = 右下の点 3 つ・`ring` = 真ん中の回る輪と labels の `waiting` の字・`none` = 黒だけ） | `Game.withAssetLoading`（Main と `web/WebMain.flix` だけが足す）・`WorldRead` の「素材の待ち」・`Controls.decodeBudget`・`View.holdLayer`・`View.loadingMark`。確かめ方: `bin/fge export-web` の大きさの表の「起動／後回し」・頁の `?loadtime=1`・描き出しの `hold`・`hold-ring`・`hold-none`・`portrait-hold-ring` |
| 縦の画面（基本の画面。スマホを縦に持った時も PC も同じ。沈めた写真の上に画面いっぱいの頁・右端にアイコンの列（しおり・ログ・オート）・右上の … のメニュー） | `project.json` の `web.portraitDesign`・字とボタンの大きさは `assets/novel.portrait.json`・列と … の積み方と大きさと長押しの秒は `assets/novel.rail.json` | `Layout.Fit.Portrait`・`Rail`（矩形と押しの判定 `Rail.judge`）・`View.portraitPage` / `portraitButtons` / `menuPanel` / `saveLoadPanel`・`WorldMenu.menuItems` / `saveLoadItems` / `longPressOf`。確かめ方: 描き出しの `portrait-<場面>`（`make render SHOT=portrait-nvl`）・`FLIX_GE_PORTRAIT=1 make run`・ブラウザ版の頁の `?orientation=portrait` |

## 読む順

**遊ぶ → シナリオを読む → コードを読む → JSON をいじる** の順で仕組みが見えます。

1. `make run` で一度読み終える。
2. `assets/talk/yukidoke.yarn` を読む。頭のコメントに、書けるコマンドの一覧がある。
3. コードは **入口 → 状態 → 描画 → 入力** の順:
   1. `src/Game.flix` … 部品を App に繋ぐ目次。冒頭に**毎フレームの流れ**。`src/Main.flix` は Doc とセーブを読んで起動するだけ。
      App の w は描く元と遊びの状態の組（エンジンの `Resources.With[Res.Res, World.World]`）。系・絵・問いは `Resources` の口で両方を受ける。
   2. `src/Res.flix` … 描く元: Doc とシナリオの木（`Controls.loadRes` が読む）。読むだけで、Doc の読み直しの時だけ替わる。
      規則と View は `res` を先頭の引数で受ける。
   3. `src/World.flix` … 遊びの状態の形（Doc は持たない）。下の図のとおり、今の場面（`Scene`）が持つ値はその場面の payload に入っていて、
      読んでいる間だけの値（シナリオの現在地 `talk`・頁・選択肢・ログ）は `Reading` の中にしか無い。
      開いている画面（`Panel`）と確認のウィンドウ（`ask`）も、そのカーソルを payload に持つ。
      規則は章ごとのファイルに分けてある: 読み進める `WorldRead`（まず `advance` と `pick`、次に `absorb` で
      実行器の出来事を舞台・頁・ログへ反映）・バックログと戻る `WorldLog`・セーブとロード `WorldSaves`・設定 `WorldSettings`・
      タイトルとボタンと確認のウィンドウ `WorldMenu`。遷移を起こす関数の doc に `[遷移: X→Y]`。
      時計は 2 本: 文字送り・待ち・背景の切り替えは物語の時計 `storyClock`（画面を開くと止まる = `paceOf`）、
      タイトル画面・クレジット・蛍と雪の粒子・知らせは実時間 `realNow`。
      規則は音を鳴らさず、返事を出来事（`Emit`）として出す。Controls が集めて音へ替える。
   4. `src/Commands.flix` … 演出のコマンド（`<<bg>>` など）の引数の表と意味。`src/Stage.flix` … 舞台の状態（時間で動く値は `PropertyTween`）。
      `src/GameCommands.flix`・`src/GameView.flix` … このゲームだけのコマンドと絵を足す口（テンプレートは空）。`src/GameE2e.flix` … このゲームだけの flow の問い（テンプレートの E2e が自分の問いの後ろに並べる）。`src/Page.flix` … NVL の頁と ADV の 1 行。
   5. `src/Backdrop.flix` … 写真をぼかして時間帯の色にするシェーダーの式（ShaderDoc を code で組む）。
   6. `src/View.flix` … 状態を絵に写す（背景と蛍・雪は `frame`、文章・ウィンドウ・タイトル画面は `hud`）。
      部品は World を丸ごと受けず、描く元（`Env.res`）・セーブ・時刻だけの `Env` と、その場面の payload（`Read`・`TitleItem` など）を受ける。
   7. `src/Controls.flix` … 入力の効き先（確認のウィンドウ → 画面 → 選択肢 → ボタン → 本文）と音と Doc の読み直し（`docTable`。読み直すのは Res で、シナリオの行だけ `WorldRead.settleDialogue` が World を収め直す）。
4. `assets/*.json` の数値や色を変えて、`make debug` で保存即反映を見る（ぼかしの強さ・時間帯の色・文字の速さ・音量）。

### 状態の図

```mermaid
stateDiagram-v2
    [*] --> Title
    Title --> Reading: はじめから / つづきから
    Reading --> Title: タイトルへ（確認のウィンドウ）
    Reading --> Credits: シナリオの終わり
    Credits --> Title: 流れ終わる・決定
    state Reading {
        [*] --> Closed
        Closed --> Log: バックログ
        Closed --> SaveSlots: セーブ
        Closed --> LoadSlots: ロード
        Closed --> Settings: 設定
        Closed --> Hidden: 隠す
        Log --> Closed
        SaveSlots --> Closed
        LoadSlots --> Closed
        Settings --> Closed
        Hidden --> Closed
    }
```

`Scene` は Title・Reading・Credits、`Panel` は Closed・Log・SaveSlots・LoadSlots・Settings・Hidden（タイトル画面からもロードと設定を開ける）。
確認のウィンドウ（`ask`）はどの画面の上にも重なり、開いている間は下の入力を受けない。

## 素材を差し替える

- **写真**: `assets/bg/` に縦の構図（9:19.5 前後・720×1560 など）の JPG を置き、`project.json` の `textures` と `assets/novel.backdrops.json` の
  `photos` に名前と `aspect`（横÷縦）を足す（作り方は AGENTS.local.md の「縦が基本」）。出典とライセンスは `CREDITS.md` と `assets/novel.credits.json` の両方に書く（CC BY は
  作者名・ライセンス・元の場所を画面にも出す）。ぼかすので、写真の解像度は低くてよい。
- **時間帯の色**: `novel.backdrops.json` の `grades`。夜は `exposure` を落とし `tint` を青へ、夕暮れは `sky` を橙へ。
- **字**: `project.json` の `fonts`。使う字だけに縮めた subset を置いている（シナリオに無い字を足したら作り直す）。
