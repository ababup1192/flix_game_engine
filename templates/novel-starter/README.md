# 消えた絵

flix_game_engine のノベル・推理テンプレート。雨の夜の洋館、停電した書斎から一枚の絵が
消えた。文章を読み、疑う相手を選ぶと物語が分岐し、選ぶたびに館の照明がひとつ消える。
文章・分岐・結末は全部シナリオ（`assets/talk/novel.yarn`。Yarn Spinner の書き方）なので、書き換えれば別の事件になる。

## 始め方

Flix コンパイラはエンジンリポの `bin/flix` ラッパ経由で呼ぶので、devbox shell の外でも動きます。
エンジンの場所が既定（生成時に埋め込み）と違うときは `ENGINE=/path/to/flix_game_engine` を付けてください。

| コマンド | 何をするか |
|---|---|
| `make run`    | ゲームを起動する（ウィンドウが開く） |
| `make debug`  | 保存即反映(watchFile)と F8 を有効にして起動 |
| `make check`  | 型検査だけ走らせる（一番速い確認） |
| `make test`   | テストを実行する |
| `make render-all`   | ギャラリー PNG を全部描き出す（決定的: title / choice / ending / menu） |
| `make render SHOT=choice` | その場面だけ `debug/choice.png` へ描き出す（複数は `SHOT="title ending"`） |
| `make reference-check`  | 描き出した絵をリファレンス画像とバイト比較する |
| `make reference-update` | いまの gallery をリファレンス画像として更新する |
| `make atelier-preview` | atelier/ の候補と assets/ の現行を debug/atelier/ に描き出す |

## 遊び方

クリック / Z / Enter で読み進める。選択肢は ↑↓（またはマウス）で選んで決定。
疑う相手を選ぶたびに館の灯りがひとつ消え、部屋が暗くなる。結末は 2 つ。
物語の途中の Esc でメニュー（物語が止まる・もう一度 Esc でつづき）、表紙の Esc で終了。
キーの割り当ては `assets/novel.keys.json`。

## 読む順（全体像のつかみ方）

**遊ぶ → 読む → JSON をいじる** の順で仕組みが見えます。

1. まず `make run` で遊ぶ（読み進めて、疑う相手を選ぶ）。
2. コードは **エントリ→状態→描画→入力** の順で読む:
   1. `src/Main.flix` … 部品を App に繋いで起動する目次。冒頭 doc に**毎フレームの流れ
      （入力→状態更新→描画 がどの行か）**が書いてある（`update = …` の 3 行）。まずここ。
      毎フレーム、App は系より先に物語の時計（`App.addClock`・メニューの間は `World.paceOf` が止める）を
      1 回だけ進め、実時間の今を `frame#realNow` で配る。
   2. `src/World.flix` … 進行の規則そのもの（行の送り・分岐・「疑うと灯りが消える」。純粋）。シナリオの現在地は
      `talk`（YarnRunner）で、今出している台詞か選択肢は `YarnRunner.shownOf` の 1 つ。`src/Talk.flix` が
      シナリオとコードの繋ぎ（話し手・タグ・最初に開くノードの enum）。
      冒頭 doc に**場面の移り変わりの図**（表紙→物語→結末→表紙）があり、遷移を起こす関数には
      doc に `[遷移: X→Y]` が付いている。まず `advance`（決定＝読み進める）と
      `pick`（選択肢を選ぶ）を読む。冒頭の「時計は 2 本」が、物語の時計（文字送り・灯りの演出）と
      実時間（雨・炎・埃・メニューの点滅）の分け方。
   3. `src/View.flix` … 状態を絵に写す（書斎・雨の窓・空の額縁・灯り・暗くするオーバーレイ・表紙を、何をどこに）。
   4. `src/NovelKit.flix` … ダイアログと選択肢のキット（UiDialog + UiTypewriter + UiSlots の束ね）。
   5. `src/Controls.flix` … キーの割り当て（`KeysDoc` の表で操作の意図へ写す）と Doc の読み直し。決定・カーソルで起きた出来事を
      `Emit.collectInto` で World に溜め、`sounds` が返事の音へ写す。灯りが消える演出は `src/LampFx.flix` の時刻表を
      音（`Timeline.soundsOnClock`）と絵（`flickerOf`）が同じ起点から物語の時計で読む。
   6. `src/render/SceneRender.flix` … 決定的な場面を PNG に描き出す（リファレンス画像とアトリエ）。
   7. `test/TestTrace.flix` … 性質テスト。でたらめなキーとクリックを画面なしで流し、「押さなければ返事は鳴らない」
      「灯りは疑う選択でだけ 1 つ減る」が、どう読み進めても崩れないかを見る（`PropertyTest.forAll`）。
3. シナリオは `assets/talk/novel.yarn`、手触り・色・絵は下の `assets/` の Doc を保存即反映でいじる。音の案は台本 `art/sfx.snd.star` を
   `bin/fge snd build art/sfx.snd.star` で `atelier/sfx/` へ書き出す（採用して `assets/sfx/` と project.json の
   `sounds` に載せるまでは無音。鳴らすと名前ごとに 1 回 warn）。

**いちばん小さい変え方**（保存即反映を体験する）: `make debug` で起動したまま
`assets/talk/novel.yarn` の 1 行を書き換えて `bin/fge yarn build assets/talk` を流すと、書き出した
`assets/talk/dialogue.json` をゲームが読み直し、開いているノードの頭から新しい文章が流れる。
`->` の後ろを変えれば選べる言葉が変わり、`#suspect` を消せばその選択で灯りが消えなくなる。
ノードを足して `<<jump ノード名>>` で繋げば事件そのものを作り替えられる。知らない話し手・タグ・ノードや
宣言の無い変数・型の違う式・読まない書き方（`<<once>>` など）は、build が行番号と直し方つきで止める
（変数と `<<if>>` の書き方は `bin/fge yarn help`）。行末の `<<if>>` が偽の選択肢は灰色で並び、選べない
（`assets/ui/choices.ui.json` の `labelOff`・色は palette の `@hint`）。

**書いた行を本物の画面で見る**: Studio の「会話」で `novel.yarn` を開くと、カーソルの行の画面（話し手・窓・選択肢・
書斎）が右に出る（窓なしのゲーム `E2e.serveHeadless` が `start talk node=… line=…` から撮る）。ターミナルなら
`bin/fge talk shot assets/talk/novel.yarn:40`、`make debug` で起動中のゲームをその行へ飛ばすなら
`bin/fge talk goto assets/talk/novel.yarn:40`（始まりは `src/Starts.flix` の `talk`）。

数値・色・絵・枠は `assets/` の Doc（保存即反映）:

- `assets/talk/novel.yarn` … シナリオ（文章・分岐・結末）。`bin/fge yarn build assets/talk` が `dialogue.json` に書き出し、`src/Talk.flix` が読む。
- `assets/novel.story.json` … 表紙とメニューの文言・灯りの数・話し手の呼び名。`src/StoryDoc.flix` が読む（material）。
- `assets/novel.keys.json` … キーの割り当て（決定・カーソル・メニュー・表紙での終了）。`src/KeysDoc.flix` が読む（tuning）。
- `assets/novel.kind.json` … 手触りの数値（文字送りの速さ・暗くなる度合い）。`src/KindDoc.flix` が読む（tuning）。
- `assets/novel.theme.json` … 場面の色票。`src/ThemeDoc.flix` が読む（material）。
- `assets/novel.sprite.json` … ドット絵（空の額縁）。entityId は `novel.sprites`（material）。
- `assets/ui/*.ui.json` + `assets/ui/palette.json` … ダイアログ・選択肢の枠と色（material）。

それぞれに Studio 用の schema が並んでいて、`project.json` の `editor.resources` が宣言しています。

## 絵の開発ループ

- `make render-all` で `gallery/` に決定的な PNG（表紙・分岐・結末）を描き出し、`make reference-update` で更新、`make reference-check` で防護。
- 候補のスプライト・テーマは `atelier/` に置き、`make atelier-preview` で `debug/atelier/` に描き出して目視。

## AI エージェント向け指針の配布（sync-agents）

エンジン側で `make sync-agents GAME=/path/to/このゲーム` を実行すると、エンジン共通の
エージェント指針（agents-pack/AGENTS.core.md）とこのゲームの `AGENTS.local.md` を連結した
`AGENTS.md` が生成され、共通スキルが `.claude/skills/` にコピーされます。`AGENTS.md` は
生成物なので直接編集せず、ゲーム固有の原則は `AGENTS.local.md` に書いて再 sync してください。
