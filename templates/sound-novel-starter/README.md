# 夏草の駅

flix_game_engine のサウンドノベルの手本。十年ぶりに祖母の町へ帰った「私」が、幼なじみの千夏と、
祖母が遺した真鍮の鍵の行き先をたどる。5 分ほどで読み終わり、選び方で結末が 3 つに分かれる。

背景は描かずに実写の写真（Wikimedia Commons の CC0 / CC BY。出典は [CREDITS.md](CREDITS.md)）を使い、
**ぼかしと時間帯の色はゲームの中でシェーダーが付ける**（同じ昼の写真が、夕暮れにも夜にも朝にもなる）。
文章は小説のように画面いっぱいに積む NVL と、下の窓に 1 行ずつ出す ADV を、場面ごとに切り替える。
字は明朝（しっぽり明朝・OFL）。

## 始め方

Flix コンパイラはエンジンリポの `bin/flix` ラッパ経由で呼ぶので、devbox shell の外でも動きます。

| コマンド | 何をするか |
|---|---|
| `make run`    | ゲームを起動する（ウィンドウが開く） |
| `make debug`  | 保存即反映(watchFile)と F8 を有効にして起動 |
| `make check`  | 型検査だけ（一番速い確認） |
| `make test`   | テスト（規則・Doc の橋渡し・性質テスト） |
| `make render SHOT=nvl` | その場面だけ `debug/nvl.png` へ描き出す（場面は `title nvl adv choice night log load settings credits`） |
| `make render-all` | ギャラリー PNG を全部描き出す |
| `make flow FLOW=e2e/true_ending.flow` | 表紙から結末までを画面なしで流す（`e2e/bookmark.flow` は栞） |
| `bin/fge yarn build assets/talk` | シナリオを直した後に木（`assets/talk/dialogue.json`）を書き直す（エンジンの `bin/fge`） |
| `bin/fge snd build art/sfx.snd.star` | 環境音・効果音を作り直す（`atelier/sfx/` に書く。採用は `assets/sfx/` へ写す） |

## 遊び方

クリック / Enter / Space / Z で読み進める。文字が出ている途中で押すと全文が出る。
選択肢は ↑↓（またはマウス）で選んで決定。下の帯のボタンか、キーで:

| 操作 | キー |
|---|---|
| ログ（これまでの頁。ホイールでも開く） | L / PageUp |
| オート（読み終えて少し待つと送る） | O |
| スキップ（読んだ行だけ飛ばす。読んでいない行と選択肢で止まる） | K / Tab |
| 窓を隠す（写真だけを見る） | H / Esc |
| セーブ・ロード（栞 6 枚）・設定（文字の速さ・オートの待ち・音量） | 下の帯のボタン |

窓を開いている間は物語の時計が止まる（文字送り・待ち・オートが進まない）。キーの割り当ては `assets/novel.keys.json`。
栞・既読・設定は `saves/novel.json` に残る（遊んだ人ごとの物なので git には入れない）。

## ノベルゲームの機能と、どこで読むか

| 機能 | 書く所 | 読む所 |
|---|---|---|
| 台詞・地の文・話し手 | `assets/talk/natsukusa.yarn`（Yarn Spinner の書き方） | `World.absorb` / `showLine` |
| ルビ（`[ruby=よみ]字[/ruby]`） | 同上 | `View.placeLine`（エンジンの `RichText.placeRuby`） |
| 選択肢・条件つきの選択肢・変数 | `-> …` `<<if>>` `<<set>>` `<<declare>>` | `World.pick` / `moveChoice` |
| 背景の写真を時間帯の色でぼかして切り替える | `<<bg 写真 時間帯 秒>>` + `assets/novel.backdrops.json` | `src/Backdrop.flix`（ShaderDoc の `TexBlur`） |
| NVL ⇄ ADV・頁をめくる | `<<nvl>>` `<<adv>>` `<<clear>>` | `Page.show` / `World.cue` |
| 環境音（ループ）・効果音 | `<<ambience 名>>` `<<se 名>>` + `art/sfx.snd.star` | `Controls.ambience` / `soundOf`・音量は `assets/novel.mixer.json` のバス |
| 画面の演出（蛍・揺れ） | `<<fx fireflies>>` `<<shake>>` | `View.particles` / `Stage.shakeOffset` |
| 待ち | `<<wait 秒>>` | エンジンの YarnRunner が待つ |
| 文字送り・オート・スキップ・既読 | 速さは `assets/novel.kind.json` と設定の画面 | `World.step` / `autoOrSkip` / `markSeen` |
| ログ | 行数は `novel.kind.json` の `logMax` | `World.scrollLog`・`View.logPanel` |
| セーブ・ロード | — | `World.saveSlot` / `loadSlot`（YarnRunner のブックマーク）・`src/Saves.flix` |
| 設定 | 範囲は `World.rangeOf` | `World.adjust` / `withSetting` |
| 表紙・クレジット | `assets/novel.story.json`・`assets/novel.credits.json` | `View.title` / `View.credits` |

## 読む順

**遊ぶ → シナリオを読む → コードを読む → JSON をいじる** の順で仕組みが見えます。

1. `make run` で一度読み終える。
2. `assets/talk/natsukusa.yarn` を読む。頭のコメントに、書けるコマンドの一覧がある。
3. コードは **入口 → 状態 → 描画 → 入力** の順:
   1. `src/Game.flix` … 部品を App に繋ぐ目次。冒頭に**毎フレームの流れ**。`src/Main.flix` は Doc と栞を読んで起動するだけ。
   2. `src/World.flix` … 進行の規則（純粋）。シナリオの現在地は `talk`（YarnRunner）。まず `advance`（決定 = 読み進める）と
      `pick`（選択肢）、次に `absorb`（実行器の出来事を舞台・頁・ログへ畳む）。遷移を起こす関数の doc に `[遷移: X→Y]`。
      時計は 2 本: 文字送り・待ち・背景の切り替えは物語の時計 `storyClock`（窓を開くと止まる = `paceOf`）、
      表紙・クレジット・蛍の明滅・知らせは実時間 `realNow`。
   3. `src/Stage.flix` … 演出のコマンド（`<<bg>>` など）の意味と舞台の状態。`src/Page.flix` … NVL の頁と ADV の 1 行。
   4. `src/Backdrop.flix` … 写真をぼかして時間帯の色にするシェーダーの式（ShaderDoc を code で組む）。
   5. `src/View.flix` … 状態を絵に写す（背景と蛍は `frame`、文章・窓・表紙は `hud`）。
   6. `src/Controls.flix` … 入力の効き先（窓 → 選択肢 → ボタン → 本文）と音と Doc の読み直し。
4. `assets/*.json` の数値や色を変えて、`make debug` で保存即反映を見る（ぼかしの強さ・時間帯の色・文字の速さ・音量）。

## 素材を差し替える

- **写真**: `assets/bg/` に 960×540 の JPG を置き、`project.json` の `textures` と `assets/novel.backdrops.json` の
  `photos` に名前を足す。出典とライセンスは `CREDITS.md` と `assets/novel.credits.json` の両方に書く（CC BY は
  作者名・ライセンス・元の場所を画面にも出す）。ぼかすので、写真の解像度は低くてよい。
- **時間帯の色**: `novel.backdrops.json` の `grades`。夜は `exposure` を落とし `tint` を青へ、夕暮れは `sky` を橙へ。
- **字**: `project.json` の `fonts`。使う字だけに縮めた subset を置いている（シナリオに無い字を足したら作り直す）。
