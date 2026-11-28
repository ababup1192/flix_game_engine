# 字が窓からはみ出さない仕組み — 計画

## なぜ

3D の箱庭（`~/Documents/flix_ge_workspace/lamplighter`）のメッセージウィンドウで、2 行になった文言が窓の下枠に被っていた。
窓の高さをゲームが固定の数（46 px）で書き、字は `Render.textWrapped` が幅で折るので、行が増えた分だけ下へはみ出す。
検査（`bin/fge text-audit`）は気づかなかった。理由は 2 つ:

1. 表（`debug/ui-overflow.tsv`）は全場面の描き出し（`make render-all`）でしか書かれない。1 枚ずつ描く（`make render SHOT=<名前>`）間は表が無く、検査は「見ずに通す」。
2. `text-audit.json` の説明では、Overflow は「乗っている枠から**左右へ**はみ出し」。上下は見ていない。

汎用性: 会話の窓・説明の窓・通知の帯はどのゲームにもある。Unity の Content Size Fitter / TMP の preferredHeight・Godot の Label（autowrap）の最小の大きさ・
CSS の height: auto に当たる。

## 足す物

### A. 折り返した字の大きさを測る口（engine_world・純粋）

- `TextDraw.wrappedSize(text, atlas, fontSize, wrapWidth): Vec2.Vec2` — `Render.textWrapped` が描く時と**同じ折り方・同じ行の高さ**で、
  折った後の幅（一番長い行）と高さ（行数 × 行の高さ）を返す。字の改行（`\n`）も数える。
  - 折る規則を 2 か所に書かない。`Render.textWrapped` が中で使っている折り方（`bin/fge refactor show Render.textWrapped` から辿る）を
    そのまま呼ぶか、共通の関数へ出して両方から使う。
- `Flex.wrappedText(look: { atlas, fontSize, wrapWidth, tint, zIndex }, text): Flex.Node` — 大きさを `wrappedSize` で持つ葉。
  `Flex.box`（pad つき）の子に置けば、窓の大きさが字に合わせて決まる（今ある `Flex` / `UiLayout` の作りのまま）。
- 文字送りの途中（`String.takeLeft(n, text)`）でも窓の大きさが変わらないよう、「大きさは全文で測り、描くのは見せる分だけ」の形を取れること
  （`Flex.wrappedTextShowing(look, full, shown)` か、引数で。名前は今の `UiTypewriter` の言葉にそろえる）。

### B. 検査が 1 枚の描き出しでも動き、上下のはみ出しも見る

まず調べる: `debug/ui-overflow.tsv` をどこが書いているか（`bin/fge refactor search` と、`mk/game.mk` の render-all の道）。そのうえで:

1. `make render SHOT=<名前>` でも、その場面の行を表に書く（表の中のその shot の行だけ差し替える。ほかの場面の行は残す）。
2. Overflow を上下にも広げる（字の外接の箱が、乗っている板の箱から下・上へ出た量）。今ある許す仕組み（`text-audit.local.json` の allow）はそのまま効く。
3. 表が無い時に黙って通す今の動きは、`make render SHOT=` の後なら起きなくなる。`make lint` の出力の「見ていません」の 1 行はそのまま。

B の調べで「字が乗っている板」を今の表がどう決めているかが、手で置いた `Render.textWrapped` と背景の板（`RawDraw` や角丸の板）で
成り立たないと分かったら、**実装へ進まず、分かった事と案を報告して止まる**（決め方は相談して決める）。

## テスト（engine_world・engine_tools の該当するパッケージで）

1. `wrappedSize`: 1 行に収まる字は行の高さ 1 つ分・幅を超える字は 2 行分・`\n` で行が増える・空の字は高さ 0。
2. `wrappedSize` の行数が、`Render.textWrapped` の描く行数と同じ（同じ折り方を使っている事の確かめ）。
3. `Flex.box`（pad 8）に `wrappedText` を 1 つ置いた時、箱の高さ = 字の高さ + 16。
4. B: 板から下へ 5 px はみ出した字が Overflow の行になる・収まっている字は行にならない。

## 文書

- `docs/modules/ui.md` の逆引きに 1 行（「窓の大きさを中の文章に合わせる → `Flex.wrappedText` / `TextDraw.wrappedSize`」）
- `make api-digest`
- `agents-pack/AGENTS.core.md` の早見表に 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本
- B を入れたら `bin/lint-rules/text-audit.json` の note と `mk/game.mk` の説明

## やらない事

- 窓の絵（枠・角丸・皮）の新しい部品。大きさが決まれば、今ある板の描き方でよい
- 行頭の句読点のぶら下げを `Render.textWrapped` に足す事（`RichText` にはある。別の話）
- 版上げ・リリース・コミット
