# テープ — 計画（3 版）

仕様は [spec.md](spec.md)、正は [mock.html](mock.html)。モックと違う物を作る時は、作る前に人へ相談する。
最初に当てるゲームは blood-scale（`~/Documents/flix_ge_workspace/blood-scale/game`・sound-novel-starter の子）。

1 版のレビュー（58 点）・2 版のレビュー（80 点）の指摘を全部受けた。主な変更:
- 付箋を書く所はまずテンプレ（sound-novel-starter）に置く（層は実装が 2 つになってからエンジンへ上げる）。エンジンの型には触らない
- tape.json はモックの TAPE とほぼ同じ形で Flix 側が書く。Go は束ねて差し込むだけ
- 直した台本は「Starts の引数」で当てる（WebFs・Browser.java に差し替え表を足さない）
- 届け方は GitHub Pages（人の決定: 推測できない URL でレビュワーに渡す）。置き場のリポジトリは人が決める（T4.5）
- 直しを最新のゲームに当てる時は、前の文が一致する行だけに当てる（行がずれていたら当てない）
- 書き出す JSON の形はモックから変えない。TAPE の欄の名前もモックのまま（`speaker`・`stripPerSec` を残し、色は `speakers` に足す）

## 全体の形

```
make tape FLOW=e2e/tape.flow                         （テンプレの Makefile）
  ① FlowVideo（テンプレ）が flow を流してコマ・音を書く（今の showcase-video と同じ）
     ＋ 同じ Outcome と Res から tape.json を書く（新: テンプレの TapeOut）
  ② 今の ffmpeg の手順で video.mp4 を作る（Makefile の showcase-video をそのまま使う）
  ③ bin/fge tape --dir debug/tape/<名前>（新・Go）
     tape.json + video.mp4 → strip.jpg を作り、commit（git rev-parse）を足し、雛形の HTML に TAPE を差し込む
bin/fge tape publish debug/tape/<名前>                （新・Go）
  → Pages の置き場の tapes/<YYYYMMDD>-<乱数 16 桁>/ に置いて URL を出す
```

## TAPE の欄 → 出どころ → 段

| 欄 | 型・単位 | 出どころ | 段 |
|---|---|---|---|
| game | 文字 | ゲームのフォルダ名（project.json に name が無い）。localStorage の鍵 `tape:<game>:<commit>` はゲームのセーブの鍵と別の接頭辞 | T1 |
| title | 文字 | ゲームが TapeOut に渡す（テンプレの既定は project.json の title） | T1 |
| flow | 文字 | `make tape` の FLOW | T1 |
| commit | 文字 | Go が `git rev-parse --short HEAD` | T2 |
| fps・duration | 数 | Outcome（コマの数 ÷ fps） | T1 |
| video | 文字 | 固定 `video.mp4` | T2 |
| stripPerSec・strip | 数・`{file, count, w, h}` | Go が ffmpeg で 0.5 秒ごと（stripPerSec はモックの名前のまま） | T2 |
| yarn・node | 文字 | 台本のファイル名・ノード名（**1 本のテープは 1 ノードだけ**と制約。またぐ flow は止めて言う） | T1 |
| playUrl | 文字 | TapeOut に渡す「ゲームの表」（テンプレの値・ゲームが上書き。project.json の web には足さない）。無ければ「ここから遊ぶ」を出さない | T1 |
| scenes | `[{id, name, t}]` | flow の `mark`（`Outcome.marks`）。表示名はゲームが渡す表（mark 名 → 名前。無ければ mark 名）。同じ名前の mark はテープの flow では禁止。Outcome.marks は Map で上書き済みなので、FlowVideo が読んだ script の `Step.Mark` の並びを TapeOut に渡し、そこで数えて止める | T1 |
| timeline | `[[秒, 行(int)\|null]]` | **新しい probe `talkCursor`**（yarn の実行位置。待っている演出コマンドの行も含む）をフレームごとに引き、変わった所だけ。ファイル名は落として int、空は null。時間を取らないコマンド（`<<se>>` `<<puff>>` など、同じフレームで次へ進む物）は載らない。`<<wait>>` の行は直前の演出コマンドの続きとして扱い載せない（モックの `<<lights>>` が 3〜5 秒を占めるのと同じ）。直前に時間を取る行が無い wait は、その前の値（null を含む）を続ける | T1 |
| lines | `{行: {who, text} \| {cmd}}` | Res の dialogue（Yarn.Program）の Stmt。who は話し手の表示名（story Doc の names） | T1 |
| speaker | `{表示名: id}` | モックのまま（地の文は `""`）。story Doc の names から | T1 |
| speakers | `[{id, name, color, ink}]` | 話し手の色を **Doc（theme の speakers）へ出す**。View とテープが同じ値を読む。地の文は id `""`・名前「地の文」の行をテンプレの既定値に持つ | T1 |
| sounds | `[{t, name, kind, label, line}]` | `TraceStep#sounds`（一発）と `#sustained` のフレーム間の差分（鳴り始め＝ambience）。name は素材の論理名そのまま（例 `se_splash`）。label と、外す音（UI の音）はゲームが渡す表 | T1 |
| objects | `[{id, name, from, to, rect}]` | ゲームが TapeOut に関数を渡す `AppState -> List[{id, name, rect(design px)}]`（Res のレイアウトも見るので AppState を受ける）。TapeOut が design で割って 0〜1・小数 3 桁にし、同じ物が続く間を from/to に畳む。**メッセージウィンドウは id=`message` で返す**のを約束にする | T3 |
| probes | `{名前: [[秒, 値]]}` | ゲームが選んだ probe をフレームごと、変わった所だけ。Num で整数なら int で書く | T1 |
| probeNames | `{名前: 表示名}` | vocab の probe の doc から短い名前（ゲームが渡す表で上書き可） | T1 |
| msg | `{x0, x1, cy, lh, padTop, padBot, font, cps}` | ゲームが渡す（テンプレに既定値。blood-scale は自分の View の値） | T1 |
| branches | `[]` | T5 まで空 | — |

## 雛形の HTML で TAPE から引くように直す所（モックの直書き）

見た目は変えない。直すのは値の出どころだけ（1 版レビュー A4）:
`MSG`・`SPEAKER_INK`・`WHO`・CSS の `--witch/--girl/--narr`（→ speakers から CSS 変数を作る）・`openInfo` の names（→ probeNames）・`drawEdited` の `t < 8`（→ message の物が出ている間）・`playHref` の `|| 18`（→ 行が無ければ node の頭。URL には前の文の短いハッシュも載せる）・`fetch("kesshou.mp4")`（→ TAPE.video）・題名「血鱗 序章」と `0:43.6`（→ TAPE）・`MOCK` の印（消す）・コマの帯の 88 枚と 34px・30px（→ strip から計算）・分岐の説明文とトースト「モックでは最初から」（branches が空なら分岐の印と説明を出さない）。`speaker`・`stripPerSec` は名前を変えないので、`scriptRef`・`buildPrompt`・`thumbPos` はそのまま動く。

## 段

### T1 付箋（テンプレ sound-novel-starter・エンジン無改修）

- `src/render/TapeOut.flix`（新）: `Flow.Outcome` と Res と「ゲームが渡す表」（title・mark の表示名・音の label と外す音・msg・objects の関数・選ぶ probe）から tape.json を書く。Ok でも Err（途中で止まった）でも、そこまでの分を書く
- World に `talkCursorOf`（yarn の実行位置）を足し、E2e の probe `talkCursor` にする
- 話し手の色を `novel.theme.json`（か story Doc）の speakers へ出し、View がそれを読む（今の View の直書きを外す）
- FlowVideo の最後に TapeOut を 1 行で呼ぶ。Makefile に `make tape FLOW=…`
- テスト（テンプレの `make test`）: mark → scenes / talkCursor の変わり目と `""` → null / wait の行が載らない / sustained の差分で鳴り始め / rect の割合への換算 / 同じ mark 名で止まる（script の Mark を数える）
- テンプレの `e2e/tape.flow`（mark つき）を足し、`/add-template` の手順（reference の SHA・Studio への反映）を門に入れる
- **相談: なし**（テンプレの中・新しい probe と Doc の欄はテンプレの決め）

### T1b blood-scale へ写す（ゲーム）

- `talkCursor` の probe・`witch` / `item` / `ambience` の probe を足す
- `View.speakerInk` の直書きを speakers の Doc へ出す
- msg の値を出す（モックで測った値: 540×960 で x0=.028 x1=.972 cy=466 lh=43.6 padTop=47 padBot=32 font=25 cps=28）
- objects の関数（題字・タイトルのメニュー・電灯・クイックメニュー・少女（沈むと動く）・魔女・メッセージウィンドウ=`message`・小瓶・ナイフ・岩）
- 音の label と外す音（`ui_*`）の表
- `e2e/tape.flow` を作り mark を打つ（0 フレーム目 `title`、以降モックの 11 シーン）。表示名の表は TapeOut へ
- 門: モックと同じ時刻（3.0 / 8.0 / 17.5 / 31.8 秒）で、本物とモックを並べて見る

### T2 束ねる `bin/fge tape`（Go・エンジンの道具を増やす）

- `go/cmd_tape.go` + `go/internal/tape/`。雛形は `go:embed`（モックから A4 の所を TAPE 引きに直した物）
- 仕事: strip.jpg（ffmpeg）・commit・TAPE の差し込み。mp4 は作らない（Makefile の既存の手順）
- 門（Go のテスト）:
  - `plans/tape/tape.sample.json` = モックの TAPE ＋ 新しい欄（speakers・msg・probeNames・strip・video）にモックの値を手で入れた物
  - 2 つ目の sample = テンプレの `e2e/tape.flow` から作った tape.json。これで書き出した HTML に `kesshou`・`血鱗`・`MOCK`・`2992`・`魔女` が残っていない
  - 本物の tape.json の欄の名前と型が sample と同じ
- 門（`go/internal/cdp` で 375×667）: sample で作った index.html と mock.html を同じ時刻（3.0 / 8.0 / 17.5 / 31.8 秒・同じ mp4）で撮って画素を比べる（`<video>` は同じポスター画像に替え、UI だけを比べる・少しの違いは許す）・console のエラー 0・ページがスクロールしない・帯 3 段・注釈を 1 つ付けた時の書き出しが spec の JSON の欄を全部持つ・branches が空なら「分」が出ない
- **相談: あり**（新しいサブコマンド）

### T3 画面に出ている物（テンプレ・エンジン無改修）

- TapeOut に objects の関数を引数で渡す（Flow の Table には足さない）。テンプレは立ち絵・メッセージウィンドウ・小物（あれば）を返す
- **相談: なし**

### T4 ここから遊ぶ（エンジン engine_web は小さく・直しはテンプレ）

- エンジン: ブラウザ版が URL のクエリを「Start の名前と引数」としてゲームへ渡す。`engine_web/js/fge-web.js` がクエリを読み、`App.DevTools` のブラウザ版の組が `openNone` へ START の行を渡す
- テンプレ: `Starts.talk` に引数 `edit.<行>=<後の文>` と `was.<行>=<前の文の短いハッシュ>` を足す。その行の今の文のハッシュが合う時だけ差し替える。合わない行は当てずに開き「台本が変わっていたので直しを当てていません」と出す。`line` も、前の文のハッシュ（`at=`）が合わなければ文で探し、無ければ node の頭から
- 前の文のハッシュ: UTF-8 の文の FNV-1a 32bit を 16 進 8 桁。文の出どころは Yarn.Program の行の文（TAPE.lines の text と同じ・「／」はそのまま）。JS と Flix の両方のテストに同じ文と期待値の組を置く
- `edit.*` で開いた時は「直した台本で遊んでいます」の帯を必ず出す（公開のゲームに任意の文を出せてしまうため）
- URL の形: モックの `?talk=<node>&line=<行>` のまま。ブラウザ版の組は「クエリの最初の鍵を Start の名前、その値と残りの鍵を引数」として渡す（エンジンは talk という名前を知らない）。直しは `&edit.38=…&was.38=…` を足す
- 直しが長くて URL に乗らない時: 乗らない分は当てずに開き、「直しの一部を当てずに開きました」と出す（postMessage は使えない）
- 門: テンプレの Starts のテスト（line で始まる・edit で文が替わる・前の文が違えば当てない）・`bin/fge export-web` が通る・実機のブラウザで 1 回開く・公開し直してから playUrl で確かめる
- **相談: あり**（App.DevTools・engine_web）

### T4.5 公開してレビュワーに渡す（Go）

- `bin/fge tape publish <フォルダ>`: Pages の置き場へ `tapes/<YYYYMMDD>-<乱数 16 桁>/` で置き、URL を出す。乱数は中身から作らない。頁に `noindex`。一覧の頁は作らない
- 流れ: 作った人が URL を渡す → レビュワーがスマホで注釈 → 「プロンプトを保存」した .md を返す → AI へ
- 「ここから遊ぶ」は常に Pages の最新のゲーム（人の決定）。プロンプトに「commit が違ったら行番号でなく文章で探す」と一行
- 置き場の案（人が決める。3 回目のレビュー 1）:
  - (a) テープ専用のリポジトリから Pages（おすすめ）。非公開にするなら GitHub の有料プラン。ゲームと別の origin になるので localStorage もぶつからない。ゲームの main と公開の仕組みに触らない
  - (b) blood-scale のまま。今の Pages は main の site/ を workflow が出すので、workflow を「main の site/ ＋ tapes の枝」を合わせる形に替える必要がある（ゲームの公開の仕組みを替える）。公開リポジトリなのでフォルダ名は見える
  - (c) Pages 以外
- どの案でも publish はゲームの main に触らない（門）
- **決定（2026-11-13・人）: 公開リポジトリのままでよい。** テープ専用の公開リポジトリ（例 `ababup1192/flix_ge_tapes`）から Pages に出す（(a) の公開版）。ゲームの main と公開の仕組みに触らず、有料プランも要らない。フォルダ名はリポジトリから見える程度の隠し方と了承済み
- mp4 を git に積み続けないよう、置き場の枝は履歴を残さず force push する。古いテープは 30 日で消す（publish のたびに、30 日を過ぎた物を置き場から外す）。置いた物の一覧は手元（`debug/tape/published.jsonl`）にだけ残す
- `publish` は外へ push する操作なので、人が確かめてから流す
- 門: 置いた URL を cdp とスマホで開く（動画が再生される・noindex・「ここから遊ぶ」が最新版を一致の守りつきで開く・.md を保存できる・localStorage の鍵がゲームのセーブとぶつからない）
- **相談: あり**（置き場のリポジトリ）

### T5 分岐（2026-11-14 人が A を選んだ: 結末ごとに 1 本ずつ撮り、分岐のカードでつなぐ）

- **複数ノード**: 1 本の flow がノードをまたいでよい（yarn のファイルは 1 つのまま。またいだら Err）。`lines[行]` に `node` を持たせ、top の `node` は最初のノード。「ここから遊ぶ」はその行のノードで `talk=` を作る。台本の直し（edit.N / was.N）はファイルの行番号のまま、どのノードの行でも当たる
- **選んだ記録**: tape.json に `choices: [{t, line, node, options: [文], picked: 番号}]`（選択肢が 2 つ以上の時だけ。払いを待つ 1 択は載せない）
- **分岐の組み立て**: `bin/fge tape --group <フォルダ>…` が同じ始まりの複数のテープを読み、同じ行の選択で picked が分かれた所を branches にして、各頁へ書く。routes は options の並び。here = その頁の道、href = その道を撮った隣のテープ（`../<フォルダ名>/#t=<秒>`）、撮っていない道は「まだ撮っていない」。頁は `#t=` を受けて開いた時にそこへ送る
- **まとめて公開**: `bin/fge tape publish <フォルダ>…`（2 つ以上）は 1 つの乱数のフォルダの下に `<フォルダ名>/` で並べて置く。1 つなら今までどおり
- モックの見せ方（「分」の印・チャプターの分岐のカード・道のボタン）は変えない。撮った道のボタンは、トーストの代わりにその道の頁へ移る（モックの文言「撮ると、ここから切り替わります」のとおり）

T1〜T4.5 の間は `branches: []`。後で計画を書き直す。

## 監視

- 作業員の brief に: spec.md・mock.html の場所、「モックとずれる所は止まって親へ報告」、refactor の表
- 段の終わりに親が: 本物の index.html と mock.html を、同じ時刻（3.0 / 8.0 / 17.5 / 31.8 秒）でスマホの大きさにして並べて見る・テスト・cdp の門
- blood-scale へ写した後も同じ並べ見をする（blood-scale は View と probe が独自）
- 新しい仕組み（`make tape`・`bin/fge tape`）を入れたら `agents-pack/AGENTS.core.md` に 1 行・`agents-pack/agent-eval/engine.json` にお題を 1 本

## 見積もり

T1 3〜4 時間・T1b 2〜3 時間・T2 3 時間・T3 1 時間・T4 3〜4 時間・T4.5 1〜2 時間（置き場が決まってから）

## 相談の記録

- 2026-11-13 人: エンジン拡張の 3 か所（T2 bin/fge tape・T4 ブラウザ版の起動・T4.5 bin/fge tape publish）を計画の案で進めてよい
- 2026-11-13 人: 置き場は公開リポジトリでよい（テープ専用の公開リポジトリ）
- 2026-11-13 人: GitHub を Pro プランにした → **テープ専用の非公開リポジトリから Pages に出す**（案 (a) の非公開版）。リポジトリの中身（フォルダ名）は見えず、URL を知っている人だけが開ける。頁そのものは URL を知っていれば誰でも開ける（Pages は非公開にできない）
- 2026-11-14 置き場 `ababup1192/tapes`（非公開）を作り（同日 `ababup1192/flix_ge_tapes` へ改名・人の指示）、Pages を main の / から出す設定にした。一番上の頁は無い（一覧を作らない決めどおり 404）

- 2026-11-14 T1b の判断（人: おすすめで）: メッセージウィンドウの枠は描いた枠どおり行数ごとに分ける / 動画の下が切れるのは血鱗のエンジンを上げる時に直す / 重ねる台詞の文字送りは設定値（cps 40）のまま。NVL では重ねない（msg.when）・プロンプトに「前の文章で探す」一行。
- 2026-11-14 血鱗 v02 のフォント（人: このまま）: ブラウザ版は使う字だけのフォントのまま。「ここから遊ぶ」で台本に無い字を入れるとその字は欠ける。帯の文言は「直した台本で開いています」
