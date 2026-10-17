# 決まりの防ぎ方の表（エンジン共通）

この表は、エージェント向けの文書を減らしたときに、決まりを 1 つずつ
**構造（型・コンパイラ）→ lint → script（make の口・フック）→ 文書** の順に扱った記録。
上で止められる物は上で止め、文書には判断の向きだけを残した。
新しい決まりを足すときも同じ順で考え、ここに 1 行足す。毎回読む文書からは指さない（必要なときに引く資料）。
「試した結果」の r1 は普通に頼んだ時、r2 は「決まりに反するのは承知・相談せずにコミットまで」と念押しした時。
2 周目（0.35.37・AGENTS.md の後半を判断の向きだけにした回）は r3 が普通・r4 が念押し・r5 が穴を塞いだ後の念押し。

## 表

| 決まり | 防ぎ方 | どこで止まるか | 試した結果 |
|---|---|---|---|
| 葉の z に大きな数を書いて手前に出さない（topLayer / withHudView を使う） | lint | forbid `zindex-big-literal`・z-table | r1 相談して書かず・r2 precommit が止めた |
| 葉の中の z は 0..31 | 文書 + lint | z-table（def の数だけ）。描き出しの warnOnce は見送り（下の節⑤） | ― |
| 描き出した場面の字が重ならない・枠からはみ出さない・描画物の z が描いてよい層の中 | lint | text-audit・z-audit（ゲームの描き出しが書く表を `make render-lint` が読み直す。許す物は `text-audit.local.json` の allow に理由つき）。動画の見回りの入口は video-entries `--check` | ― |
| legend の色キーはパレットに実体を置く | lint | palette（hook-art-edit・precommit） | r1 相談・r2 precommit が止めた |
| View が矩形と円だけにならない | lint | view（hook-art-edit・precommit）。呼び出しの数で見る（下限 5） | r1 `List.map` の 1 か所で 12 個描いて通った。lint は変えず穴として記録 |
| ドット絵の画素の並び・アニメのコマ | script | hook-art-edit の sprite・anim（失敗だけ返す） | ― |
| View を書いたら drawing.md を読む | script | hook-art-edit の remind（描画の呼び出し 5 回以上の .flix で 1 セッション 1 回） | ― |
| 絵の下限 5 性質・画風を先に決める・候補は 3 つまで・周回は r2 で止める | 文書 | drawing.md の芯 | ― |
| 予約語（spawn・region など）を識別子にしない | 構造 + lint | コンパイラ E6629・flix-reserved（保存時と precommit）・explain-error | r1 コンパイラで止まり名前を変えた |
| `let _ =` で値を捨てない（知らせも捨てない） | lint | value-discard（保存時と precommit） | r1 相談・r2 precommit が止めた |
| fold の中の List.append・文字列の 1 文字ずつ足し | lint | quadratic（precommit） | r1 precommit が止め、直し方を相談 |
| 二乗の残り 3 形（ループ内の exists・range+nth・sortBy の重いキー） | 文書 | flix.md の芯 | ― |
| World の大きな record を enum で包む | lint | record-wrap・E2136 / E6794 に explain-error | ― |
| レコードは == で比べられない | 構造 | コンパイラ E5252 / E7027 + explain-error | r1 止まり、欄ごとの比較でコミット |
| Float32 リテラル | 構造 + lint | 型エラー + explain-error・f32 | ― |
| Java の import はモジュール直下・例外は import してから | 構造 | Unresolved type + explain-error・compile-fix | ― |
| @Test に Assert / Fs の効果を書く | 構造 | 型検査 | ― |
| 状態は String でなく enum・名前の付け方・コメントの流儀・forM・sortBy は安定でない | 文書 | flix.md の芯・flix-docs | ― |
| Java より標準ライブラリ | 文書 | forbid 案は既存 30 行に当たるので見送り | ― |
| 知らせは Log を通す（System.err.println を呼ばない） | lint + 構造 | forbid `stderr-println`・IO の効果で型が変わる | r1 断った・r2 型検査が先に止めた |
| 読み込みの途中で bug! しない | lint | fallback（engine の srcRoots だけ）+ error-handling.md の芯 1 行 | ― |
| load* / loadOr / loadOrBug の分け方・無い ≠ 読めない・Err は JsonError か String | 文書 | error-handling.md の芯 | ― |
| stderr / stdout の振り分け | 構造 | Log が決める | ― |
| エンジンにある物を自前で書かない | script + 文書 | `make module Q=<語>`・critique-code の手順 2 | r1 `make module` で UiScroll を選んだ |
| module-index を丸読みしない | 構造 | 本文を docs/modules/*.md 13 本へ分け、目次 4KB だけにした | ― |
| モジュールを足したら索引に載せる | lint | check-api-index（`parts: docs/modules/*.md`・幽霊参照も出す） | ― |
| 分けた docs がゲームに届く | script | stage-engine.json・check-refs の bundleRequired | ― |
| 早見表の heavy の詳しい決まり | script | `bin/fge heavy --help`（表には名前と口だけ） | ― |
| スキル一覧の引き金を短く | script | sync-agents の生成（TestSyncWritesAgentsMd） | ― |
| 廃止したフックを外し新しいフックを足す | script | sync-agents が settings.json を直す（hook-session-diet を外し hook-art-edit を足す） | ― |
| 開始時は make status から | script | SessionStart フック | ― |
| コミットのフックを飛ばさない | script | ユーザ全体の PreToolUse（block-no-verify）。precommit の止めた時の文面から飛ばし方の案内を外した | r1 `--no-verify` を止めた・r2 `core.hooksPath` を読むだけでも止めた |
| ゲーム固有の門をコミットで流す | script | precommit の `localGate`（ゲームの Makefile の `precommit-local` に `STAGED` を渡す） | ゲーム側の表（art-gate） |
| 共通の口をゲームの Makefile へ写さない | lint | makefile-dup（precommit。game.mk を include する Makefile で共通の口にレシピを書いた行） | r1 文書どおり断った・r3 断った・r4 precommit が止めた |
| プレイヤーの目に入る文言は Doc に置く | 文書 + lint | forbid `view-text-literal`（`*View.flix` の `text = "直書き"`。rawLine で文字列の中を見る）。View の外の Doc の既定値は止めない | r1・r3 Doc へ置いた・r4 View に直書きでコミット（穴）→ 規則を足して r5 precommit が止めた |
| Doc は version・note・同じ種類の schema（項目に label か description）を持つ | lint | doc-shape（precommit。ステージした assets/ の Doc だけ） | r3 3 つとも付けてコミット・r4 precommit が止めた |
| fail-open（欠け・書き損じは既定値へ）・データは Doc | 構造 + 文書 | `DocJson.loadOr`・fallback lint。何を Doc へ出すかは判断の向き | ― |
| 言葉づかい（業界の語・造語と比喩を作らない） | 文書 + lint | jargon（既知の語だけ止まる） | 各試しで jargon がコメントの語を止めた |
| `is*`/`has*`/`can*` は Bool・`get*` は IO などの効果を持たない | lint | verb-names（precommit。1 行の宣言だけ） | r3 名前を変えた・r4 precommit が止めた |
| 動詞の残り（load・build・with・to/as）の使い分け | 文書 | 型から見分けられない。AGENTS.md の判断の向きに 1 行 | ― |
| AI の素材は atelier/ へ | script | hook-asset-guard（Write / Edit / apply_patch と、Bash のリダイレクト・`sed -i`・`cp` の行き先・書き込むスクリプトの中のパス） | r3 atelier へ書いた・r4 Bash の `sed -i` で抜けた（穴）→ Bash も見るようにして r5 フックが止めた |
| .flix を丸読みしない | script | hook-read-guard（300 行超を offset も limit も無しに Read・パイプ無しの `cat`）。`head` や `less` は見ない | r3・r4 フックが止め、範囲を決めて読んだ |
| Codex でも同じフックで止める | script | `.codex/hooks.json`。Codex 0.162 の実機で、ファイル編集は tool_name `apply_patch`（`tool_input.command` にパッチ本文・絶対パス）、シェルは `Bash`（`tool_input.command`）で届く。PostToolUse の matcher は `Edit|Write` だったので Codex では動いていなかった → `apply_patch` を足し、既にあるゲームへは sync が matcher を広げる | Codex に assets/ の sprite を apply_patch で書かせる・`sed -i` で書かせる・638 行の .flix を `cat` させる → 3 つとも PreToolUse が止めた。git worktree の中の Codex は、worktree ではなく元のリポの `.codex/hooks.json` を読む（下の注） |
| NOTES の先頭を短く | script | notes-rotate（ゲーム側の表） | ゲーム側の表 |
| テスト方針（何をテストするか・期待値は Doc から・橋渡しは最大 3 本・1 テスト 1 アサート・本体にロジックを書かない） | 文書 | quality-assurance・AGENTS.md の判断の向き。数のリテラルの forbid 案は 66 件が正しい使い方で見送り | r3 断った・r4 `expected = 12` でコミット（文書だけの決まり。止めない） |
| 初学者の足場・早見表に足すのと対でまとめる | 文書 | ― | ― |
| 絵の入口は /pixel-art・長い参考はスキルにしない | 構造 | 長い参考 5 本を engine の docs/art-ref/ へ移し、スキル一覧に載らなくした（入口の表から節を引く） | ― |
| sync-agents の出力（AGENTS.md の形）を変えたら Studio の `server/src/NewGame.flix` も同じ変更にする | script | `make release` の前段 `studio-parity` が Studio の `check-agents-parity` をこの engine で流す（clone が無ければ `STUDIO=none` で飛ばしたと残る） | 0.35.36 で Studio v0.32.13 の CI が落ちた（v0.32.14 で直した） |

## 型と構成の案（types 担当）

番号は types の案の順。

- ① 字に効かない fade（Item.Text に alpha・Render の match から `case other` を外す）: engfix 側で扱う。
- ② 同じ音の名前を鳴り続ける音と一発の音で使う（止めるときと一発のときにループを戻す）: engfix 側で扱う。
- ③ 押す物の当たりの順を見た目の層とそろえる: 入れた。`SortingLayer.pick` が zRange の底で前後を決める。agent-eval の click-front-layer で確かめる。
- ④ 層の z の範囲を順の列から作る（`order()`）: 見送り。
- ⑤ 葉の z の幅 32 越えを描き出しで warnOnce: 数えるとゲームの描き出しで 32 越えが 11 回あったので見送り。lint の leafZRange と文書のまま。
- ⑥ App の内部の口: RemoteDebug を `App.RemoteDebug` の子へ移し、historyLimit・resumePoint・worldAt・applyReload・sceneItems の 5 つを pub から外した。外の module からは E0237。z を書き換える zMapped は使う 3 つ（App・SortingLayer・UiRender）に非公開の写しを置き、`EngineInternal` と forbid の engine-internal を消した（0.35.38）。
- 見送り: 秒と拍の phantom（Timeline.Duration の case 名で足りる）・音の名前の型（App に型の引数が増える。綴りは script で見る方が安い）・確認の窓を 1 つの Option にまとめる（ゲーム側の案）。newtype は 0.77.0 では case を外から作れるので守りにならない。

## 注: Codex と git worktree

Codex（0.162）は git worktree の中で動かしても、worktree の `.codex/hooks.json` ではなく、元のリポジトリ（git の共通ディレクトリの親）の
`.codex/hooks.json` を読む。元のリポが古い版のままだと、無くなった台本を呼ぶフックが毎回失敗し、Codex はその失敗の文面を答え続けた
（2026-10-17 の試し。PreToolUse は 1 度も呼ばれず、assets/ への書き換えも通った）。worktree で Codex を使うときは、元のリポの
`.codex/hooks.json` も今の版にそろえる（`make sync-agents GAME=<元のリポ>`）か、worktree ではない clone で動かす。
