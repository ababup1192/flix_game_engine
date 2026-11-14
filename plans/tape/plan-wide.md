# テープ — PC・タブレット版とボタンの直しを本物の頁へ入れる計画（第 3 版・レビュー 72 → 86 → 91 点。91 点の残りの 2 つも入れた）

正は `plans/tape/mock-wide.html`（広い画面）と `plans/tape/mock.html`（スマホ）。言葉の仕様は `spec.md`・`spec-wide.md`。
人の判断（2026-11-14）: 広い画面は「概ね OK」・5 つの判断はおすすめ（チャプター常時・横長動画は 3 列で真ん中を広く・キーは表のまま・⌘S は 2 回押し・真ん中の線は固定）。
シートのボタンは ✕（右上）と黄色の確定（右下: ＋ 追加 / ✓ 適用 / ↓ 保存）。**人の指示で、モックを人に見せずに設計・実装へ進む**（レビューの「W1 の前に 375 幅を 1 枚見せる」は、この指示で行わない。代わりに W0 の画素の撮り比べで守る）。

## 今の作り（確かめた所）

- 雛形 `go/internal/tape/template.html`（888 行）は「mock.html に `mockFixes`（約 45 本）を当てた物」と一致することを `TestSampleRenderEqualsMockExceptListedFixes` が見る。直しは本物にだけある機能の全部（TAPE から引く・置き場の URL・ノードをまたぐ・分岐の href と `#t`・起動画面・videoBytes・鍵）
- `TestPageMatchesMockOnPhone` は 375 幅で mock.html と本物を 4 つの秒で撮り比べる（`.mock` だけ隠す）
- mock.html はボタンの直しで変わった（未コミット）ので、今の雛形はこの 2 本で落ちる
- mock-wide.html は 1176 行。mock.html を写して広い画面を足した物

## 方針: 決めた事はモックの側で先に片づけ、直し（mockFixes）を増やさない

モックだけの切り替え・決め打ち・広い画面のバグを mockFixes で直すと、直しが 15 本ほど増えて「何がモックとの違いか」を読み切れなくなる。見た目を変えない片づけはモックで先にやり、正を簡潔にしてから雛形へ当てる。

## 段

### W0 モックの片づけ（mock-wide.html を直す。見た目は変えない）
1. モックだけの切り替えを消す: `?chap` `?wideVideo` `?input` `?badge`・`Q`・`.formtag`（デバッグのラベル）・`FORM_NAME`・`.no-bin`（チャプター常時に決まった）。デバッグのラベルは消す
2. 横長の動画: 今 mockFixes にある `--frame-ratio` を入れる loadedmetadata の処理と `fitCanvas` を**モックへ入れ**（その 2 本の直しは W1 で消す）、同じ 1 本の listener で、動画の縦横比（videoWidth > videoHeight）から横長のクラスを付ける。CSS は `body.wide.wide-video` に限る（スマホの形に漏らさない）。比は `16/9` の決め打ちでなく `var(--frame-ratio)`。付けた後に `redraw()`（fitCanvas）と帯の引き直し（relayout）を呼ぶ
3. 分岐の番号: `focusBin(toFork)` を `focusBin(toFork, fork)` にし、`$("bfork" + fork)` で引く（分岐が 2 つ以上のテープで、押したマーカーの分岐へ飛ぶ）
4. strip のコマ: モックの TAPE の字に `strip: {file, count, w, h}` を足し、**スマホの部分も広い部分も**全部 TAPE.strip から引く形に書き換える（`thumbPos` の `87`・`34`、`.thumb` の `2992px`、`.chap .thumb` の `2640px`、チャプターの `* 30`、`film` の `* 88`、広い部分の `TILE * 88`・`TILE * 96 / 54`）。背景の画像もモックの CSS の `url(strip.jpg)` でなく JS から `--strip` に `TAPE.strip.file` を入れる形にそろえる。今の mockFixes の strip の直し（置き換え 5〜6 本・CSS の `var(--strip)`・`THUMB_W`/`CHAP_W`・`applyTape` の中の strip の行）は要らなくなる（W1 の表に入れる。`applyTape` の直しは strip の行だけを抜いて残す）
5. キー: 日本語の変換中（`e.isComposing || e.keyCode === 229`。Safari は確定のキーが isComposing 偽・keyCode 229 で届く）は Esc・⌘Enter を含めて何もしない。P は playUrl が無い（ボタンが出ていない）時は何もしない。P を早見にも足す
6. 形が変わった時（iPad を回す・窓が 1024 をまたぐ）は、開いている書きかけのシート（注釈・直し・pending）を閉じずに新しい置き場へ移す。ただし 2 列でチャプターのシートを開いたまま 3 列になった時は閉じる（左の欄と同じ中身が 2 つ出るため）。広い形からスマホへ書きかけのまま戻る時は scrim を付け直す
7. ⌘S: 書きかけの注釈・直しがある時は書き出しを開かず、トーストで「先に付けるか閉じてください」
8. 保存: マウスの広い形では共有シート（navigator.share）を飛ばし、downloads の口 → ダウンロードの順にする
9. マーカーから音の注釈を引く所は、注釈に欄を足さず（.md と localStorage の形は変えない）、名前が同じ音のうち時刻が一番近い物を選ぶ。見つからなければ選ばない（undefined のまま select しない）
10. 起動の順をモックの側で決める: 「applyTape → applyForm → 帯（buildTimeline）→ refresh → onTime(0) → 動画の取り」。applyForm が帯より先に走っても落ちないこと（wide の時の layoutTimeline / renderList）を確かめる。W1 で当てる直しは KEY と起動画面の差し込みだけにする
11. 同じ処理の 2 本持ちをまとめる: `relayout()`（applyForm と setZoom の両方から）・`.keys kbd` の CSS を 1 か所・`renderBin` は中身が変わった時だけ作り直し、手で欄を送っている間は scrollIntoView しない
12. spec-wide.md の「決めてほしい所」を「決まった事」に書き換え、5〜8 の決まり（変換中は効かない・P は playUrl が無ければ何もしない・⌘S は書きかけがあると開かない・マウスの広い形では共有シートを出さない）と 6 の端の扱いを足す（W2b のテストの期待値の出どころ）
13. 門（私が見る）:
   - 旧 mock.html（git の HEAD）と片づけた mock-wide.html を、375×667 の 4 つの秒（3.0 / 8.0 / 17.5 / 31.8）で**画素で**撮り比べて同じ
   - **作業中の mock.html（ボタンの直しの入った未コミットの物）**と片づけた mock-wide.html を、375×667 で 注釈のシート・文章を直す・書き出す・チャプター（分岐のカード）を開いた状態で**画素で**撮り比べて同じ
   - 広い画面 4 枚を撮り直して私が見る
   - 作業員がキーを 1 回ずつ押した記録（押したキー・前後の状態）

### W1 正の差し替え（雛形を新しいモックから作り直す）
1. mock.html ← 片づけた mock-wide.html。mock-wide.html を消す（git mv）
2. 当て直す直しの一覧を**先に**作る: 今の mockFixes を新しい mock.html に 1 本ずつ当て、当たらない物と、その書き換え先を表にする。分かっている物:
   - `const PPS = 56, TILE = …, KEY = …` の 1 行 → mock-wide では `let PPS`・`const KEY` に分かれ、TILE は `layoutTimeline` の中。KEY の直し（location.pathname 入り）だけを `const KEY` の行に当てる
   - 起動画面の CSS の差し込みの目印 `.toast.on …\n</style>` → 今の `</style>` の前の行に合わせる
   - 最後の起動の行 → W0 の 10 でモックの順が決まったので、直しは起動画面の script と fetchVideo と `#t` の差し込みだけ。`#t` が形の切り替えの後に効くことは W2a の 6 で固定
   - `id="fork${i}"` と `$("fork" + fork)` → `${forkId}${i}` と `bfork`（W0 の 3 で番号つきになった物）に合わせる
   - strip の直し 5〜6 本（`2992px`・`2640px`・`87`・`34`・`* 30`・`* 88`）→ W0 の 4 でモックが TAPE.strip から引くので消す。TAPE の字の差し替え（モックの `const TAPE` → 本物の JSON）に strip が入っていることを確かめる
   - `--frame-ratio` の loadedmetadata と `fitCanvas` の直し 2 本 → W0 の 2 でモックに入ったので消す
3. 門: `TestSampleRenderEqualsMockExceptListedFixes`・`TestPageMatchesMockOnPhone`（375 幅・違う画素 maxDiff 以下）・既存の全部の Go のテスト

### W2a 広い画面を本物で（直しと撮り比べ）
0. **最初に前提を確かめる**: cdp の今の口（Mobile）で 820×1180 を開き、`matchMedia("(pointer: coarse)").matches` と `(hover: none)` が真になるか。だめなら `Emulation.setEmulatedMedia` の features に pointer / hover を渡せるかを試し、それもだめなら InitScript で `matchMedia` を差し替える（頁のコードは触らない）（どれにしたかを報告）
1. **cdp の口を足す**（go/internal/cdp）: 窓の大きさを途中で変える（Emulation.setDeviceMetricsOverride）・マウスと指の切り替え（Emulation.setTouchEmulationEnabled と hover/pointer の media の上書き）・trusted なキー（Input.dispatchKeyEvent、修飾キーつき）・マウスの位置（Input.dispatchMouseEvent）・InitScript（visualViewport の差し替え用）。`openTapePage` に大きさと入力の引数
2. 本物にだけある機能を広い画面でも通す: 起動画面（全画面）・分岐の道のボタン（左の欄の中で隣の頁へ）・`#t`・ここから遊ぶ（行のノード）・ノードをまたぐ行・書き出す・鍵。必要な直しは mockFixes に足す（本数を報告に書く）
3. `TestPageMatchesMockWide`: 1440×900（3 列・8.0 秒で止め、台本 :25 を選んでインスペクタで「文章を直す」）・1180×820（3 列・16.7 秒で分岐のカードへ）・820×1180（タブレット縦・指）・900×700（2 列・台詞を選んだ所）で mock と本物を撮る。両方の頁で `caret-color: transparent`・focus を待つ（280ms の後）・マウスは吹き出しが出ない所に置く。閾値は最初に差の絵を目で見てから決める（既定 maxDiff を出発点に）
4. 形の境目と行き来: 719/720・1023/1024 の両側で形を確かめる。375 → 1440 → 375 と変えて、375 の絵が初めの絵と同じに戻る（DOM の置き場を元へ戻す所の壊れ止め）
5. 書き出しの .md が、広い形とスマホの形で一字も違わない
6. `#t` と形の切り替えの順: 1440×900 で `#t=20` を付けて開き、形が 3 列になった後でも帯の位置（scroller）と動画の秒が 20 に合っている（横長の動画でも 1 本）
7. other（13 コマ）を 1440×900 で開き、帯の background-size が `TILE * 13` になる。`TestOtherSampleLeavesNoMockNames` に `* 88` と `/ 54` を足す
8. 門（私が見る）: 4 枚の撮り比べの絵

### W2b 広い画面のテスト（キー・ボタン・横長）
1. キー（trusted）: Space・K・L（再生と 2 倍・4 倍は playbackRate / 送りの状態で見る。時間で見ない）・J（逆送りの状態で見る）・← →・Shift ← →・Home / End・[ ]・↑↓・N / M・E・R・O・P（playUrl がある時は href、無い時は何もしない）・Esc・⌘Enter・⌘S の 2 回（1 回目で開いて focus、2 回目で保存の口が呼ばれる）・⌘S で書きかけがある時は開かない・入力欄では ⌘Enter / ⌘S / Esc 以外が効かない・変換中の Esc と ⌘Enter では閉じない（`Input.dispatchKeyEvent` では isComposing を立てられないので、合成の `new KeyboardEvent("keydown", {key: "Escape", isComposing: true})` と keyCode 229 の 2 通りで確かめる。trusted でなくてよい）。P は href を見る（新しいタブは拾わない）
2. ボタン: ✕ で閉じる・押せない確定は薄くて押しても何も起きない・⌘↵ の表示はマウスの広い形だけ・形が変わっても書きかけが残る・2 列でチャプターを開いたまま 3 列になると閉じる・広い形からスマホへ書きかけのまま戻ると scrim が付く
3. 保存: downloads の口があれば使う・マウスの広い形で canShare が真でも共有シートを出さない・指の形では今までどおり
4. visualViewport（スマホの形だけ）: InitScript で visualViewport を差し替えて resize を出し、シートの下端がキーボードの上に来て確定のボタンが見える
5. 横長の動画（960×540 の試験の動画）は本物だけで確かめる: 3 列の列幅（216 / 300）・frame の比が動画の比・canvas が映っている矩形に重なる（`TestLandscapeVideoOverlaysWhereItIsShown` を 1440×900 でも）・375 幅では wide-video の CSS が効かない
6. 門: Go の全部のテスト。ここでレビュー役（最大 3 回・90 点）

### W4 出す
- テンプレートの `make tape` の口は変えない（頁は bin/fge が作る）。agents-pack の早見表に 1 行（広い画面とキー）・お題 1 本・docs/migrations
- リリース 0.95.0（人に聞いてから）。公開済みの 3 本の頁を作り直して置き場で差し替え、PC の幅とスマホの幅で開いて確かめる

## この計画でやらない（別の計画へ出す）

洗い出しの「案」6 つ（囲むの最中のキャンセル／完了・削除の取り消しトースト・つまみを払って閉じる・コピーの位置・ここから遊ぶに ↗・PC の「\」で元の文章）。スマホの見た目や流れを変えるので、人の返事 → モックを直す → 直しとテストを当て直す、の順で W4 の後に別に組む。

## 知っていて残す物

- 起動画面は 540×960 の縦に決め打ち。横画面のゲームを広い画面で開くと縦の帯の中に出る（今からある性質。横画面のゲームのテープを作る時に直す）
- mockFixes は増える（W2a で何本増えたかを報告させる）。いずれ本物の機能ごとに名前付きでまとめるか、TAPE から引く値を `applyTape` に集めて直しを減らす

## 監視

- 作業員の brief に、モックの場所・「ずれたら止まって報告」・refactor の表（.flix は触らない見込み）
- 段の終わりの門で、作業員が撮った絵を私がモックと並べて見る（W0・W2a）
- W2b の後にレビュー役

## 見積もり（直近のテープの段の実績から）

W0 3〜4 時間・W1 1〜2 時間・W2a 3〜4 時間・W2b 3〜4 時間・W4 1 時間
