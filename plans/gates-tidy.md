# 門の整理（gates.json・make verify SUITE=・make test にまとめる）の設計

状態: 設計 3 版（レビュー 1 回目 72 点・2 回目 86 点。2 回目の必須 3 件を反映）。2026-11-19・main v0.102.1・ブランチ gates-tidy。
元: plans/test-selection.md の 4 節「門ごとの入力が Makefile のレシピと precommit.json とコメントに散らばる」と相談事 2。
1（すぐ直す物）はコミット済み（cfb40972）。

test-selection は「新しいファイルを足さず precommit.json を広げる」を推していた。gates.json を別にしたのは、precommit.json が
ゲームへ配られてゲームのコミットでも走る表で、engine の Makefile の口の表を混ぜると配る先へ持ち込むため（配る物の都合。test-selection の 4 節・7 節も直す）。

## 1. 門の一覧を 1 つのデータに: 根の `gates.json`

engine のリポの門（make の口）を 1 行 1 つで持つ。**置き場は根**（`bin/lint-rules/` はゲームと Studio の同梱へフォルダごと配られる。
根のファイルは stage-engine.json・manifest.json が名指しした物しか運ばないので、gates.json は配られない）。

```json
{
  "note": "…（time の出典: plans/test-selection.md 1 節と .test-logs の実時間）",
  "runs": { "precommit": "コミットの時（bin/fge precommit）", "hook": "Claude の hook", "manual": "手で打つ",
            "release": "make release-verify の門（RELEASE_GATES）", "pre-release": "release の前に手元で（画面を開く門）" },
  "gates": [
    { "id": "test-engine", "about": "engine の flix test（1054 本）", "make": "test-engine",
      "input": { "prefixes": ["engine/src/", "engine/test/"] }, "runs": ["manual"], "time": "30s" },
    { "id": "test-release", "about": "全パッケージのテスト（テンプレートを含む・並列）", "make": "test-release",
      "runs": ["release"], "time": "1m52s" },
    { "id": "sync", "about": "…", "make": "sync", "prereq": true, "runs": ["release"], "time": "20s" },
    { "id": "docs-sync:rules", "about": ".claude/rules が docs/ と一致", "make": "check-docs-sync", "vars": { "ONLY": "rules" },
      "input": { "prefixes": ["docs/", ".claude/rules/", "agents-pack/rules/"] }, "samples": ["docs/x.md"], "runs": ["precommit", "manual"], "time": "0.1s" }
  ],
  "suites": { … 3 節 … }
}
```

- `input` は precommit.json の `when` と**同じ書き方・同じ go の型**（`precommit.Matcher`）。省くと「どの変更でも当たる」。
- `make` は口の名前だけ。引数は `vars`（`make <口> K=V …`）。
- `prereq: true` の門は、suite の中で落ちたら後ろを流さない（sync・sync-engine-full・go-build）。
- `runs` の `release` を持つ門の **make の口の名前**の集まりは Makefile の `RELEASE_GATES` と同じでなければ `--check` が止める（2 節）。
  release-guard・studio-parity・sync・test-release・gl-parity の 5 本が runs: release の門として載る。ci は載せない（workflows と比べないので）。
- flix test のパッケージも 1 本ずつ門として載せる（4 パッケージ + テンプレート 4 本）。`TEST_DIRS`・`TEMPLATE_DIRS` と `--check` で比べる。

### precommit.json と二重に持たない（案 B）

precommit.json は今のまま（コミットの時の検査の正・ゲームでも走る）。`bin/fge gates` が precommit.json の checks・docsSync・localGate と
hooks.json の artEdit を**読み込んで**一覧に混ぜる（runs=precommit / hook）。gates.json には書かない（書いたら `--check` が止める）。
案 A（precommit の checks を gates.json から引く）は、ゲームの precommit が engine の表を要るようになるので取らない。

## 2. `bin/fge gates`（go）と食い違いの検査

```
bin/fge gates                       一覧（id・runs・make・time・about。precommit.json と hooks.json の分も混ぜる）
bin/fge gates --files <パス…>       当たる門だけ（input に当たる物と input の無い物）。流さない。--json あり
bin/fge gates --suites              流し方の一覧（3 節）
bin/fge gates --suite <名前> [--dry-run]   流し方の門を順に make で流す（--dry-run は make の行を並べるだけ）
bin/fge gates --check               gates.json と Makefile の食い違い（check-docs-sync の 1 つ docs-sync:gates）
```

`--check` が見る事:
1. `make` の口が Makefile の明示の口に在る。一覧は `make -pRrq :` を **1 回だけ**流してデータベースから取る（make 3.81 で動くのを確かめた・
   0.1 秒）。直前の行が `# Not a target:` の項目（前提のファイル）は外す。`make -q <口>` は使わない（`test-%` のパターンで綴りの誤りも「在る」になり、`$(MAKE)` の行は -q でも走る）。
   `test-<名前>` の門だけはパターンの口なので 2 で見る。
2. `make -s gates-facts`（隠しの口）が出す `test-pkgs …`・`lint-names …`・`docs-sync-names …`・`release-gates …` と比べる:
   テストのパッケージ全部に `test-<名前>` の門・`vars.ONLY` の名前が LINT_NAMES / DOCS_SYNC_NAMES に在る・DOCS_SYNC_NAMES の全部に
   `docs-sync:<名前>` の門・`runs` に release を持つ門の make の口の名前の集まり = RELEASE_GATES。
3. suites の中の id が全部 gates に在る。
4. `docs-sync:*` の `samples`（見本のパス・必須）が自分の input と precommit.json の docsSync の `when` の両方に当たる（コミットで流れない検査を作らない）。
5. gates.json に precommit.json の checks の sub と同じ id を書いていない。

## 3. 流し方（suite）を 1 つの口で: `make verify SUITE=<名前> [DRY=1]`

人の追加の依頼: 「テストを流すパターン分けして、一発で make から呼べるといいかもね」。
名前つきのテストの組は業界では suite。口は `verify`（release の skill の verify と同じ語）。

- 中身は `bin/fge gates --suite <名前> [--dry-run]`。SUITE が無ければ一覧を出す。
  - WhyNot: `make test-<名前>` にしない — `test-%` はパッケージ 1 本のテストの口で、名前がテンプレートと取り合う。
- suite の中身は gates.json の `suites` に書く（Makefile には書かない）:

| 名前 | 中身 | 時間 |
|---|---|---|
| `quick` | 作業中の軽い確かめ: `check`（根の 4 パッケージの型検査）・`precommit-dry`・`lint`（既定の束）・`check-docs-sync` | 十数秒 |
| `test` | パッケージのテスト全部: `sync-engine-full`（prereq）・`test-release`（隠しの口。make test ALL=1 JOBS=6） | 約 2〜3 分 |
| `release` | リリースの全量: `release-verify` 1 本（release/verified.txt を書く。make release-verify と同じ。一覧で見つけやすくするために置く） | 約 3 分 |
| `gui` | 画面を開く門（release の前に手元で）: `sync-engine-full`（prereq）・`determinism`・`gl-capture-check`・`smoke-devtools`・`webgpu-v1-check-web` | 約 21 分 |
| `affected` | 差分から選ぶ（plans/test-selection.md の案 B の受け口）。今は `fallback: test` を流し、「差分から選ぶのはまだ。test を流します」と 1 行出す | test と同じ |

- 落ちた時: 門を 1 つずつ流し、赤でも次へ進み、最後に赤の門を並べて exit 1。ただし `prereq` の門が赤ならそこで止める。
  子の make が signal で止まった（Ctrl-C）・`bin/fge gates` が SIGINT / SIGTERM を受けた時は残りを流さず 130 で抜ける。
- 子の make の環境から `MAKEFLAGS`・`MFLAGS`・`MAKELEVEL` を外す（`make verify SUITE=quick ONLY=x` の ONLY が全部の門へ漏れるのを止める）。
  門へ渡したい変数は `ARGS="STUDIO=none"`（全部の門の make の行の後ろに付ける）。
- `make help` には Makefile の `##> make verify SUITE=<名前> | …（一覧は make verify）` の 1 行で出す（mk/common.mk の help を触らない＝ゲームに波及しない）。
- `precommit-dry`: `bin/fge precommit --files <ステージした物と作業ツリーの差分（追跡していない新しいファイルを含む）>`。
  jargon は `git diff --cached` を読むので、ステージしていない行は素振りで見ない（出力に 1 行出す）。
- heavy（同時に流す重い物の鍵）: `verify` を長い物の口に入れる（gui は 20 分を超える）。
- release の skill の「窓を開く門」の段落は `make verify SUITE=gui` 1 行に置き換え、並びの正を gates.json 1 つにする。

## 4. check-docs-sync を名前つきの小さな検査に分ける（実装 3）

- 1 本のレシピを `DOCS_SYNC_SH_<名前>`（lint の `LINT_SH_` と同じ形）に分け、`make check-docs-sync [ONLY=<名前>,…]` で流す。ONLY が無ければ全部
  （今と同じ）。1 つ落ちても後ろを流し、最後に落ちた名前を並べる。
- 今の 18 の検査 → load-copy を抜いて 17、+ gates（2 節の --check）で 18: claude-import・rules・px-ops・check-codes・skill-table・core-skills・
  core-bridge・skill-links・skill-frontmatter・skill-sync・old-prim-names・manifest・check-refs・api-index・api-digest・docs-links・template-claude・gates。
- LwjglLoad と HeadlessLoad の写しの検査は lint の仲間へ: シェルの 1 文を `LINT_SH_load-copy` に置き（`make lint ONLY=load-copy`・既定の束にも入れる。今 0 件）、
  毎コミット流れる `precommit-local` のレシピも `@$(LINT_SH_load-copy)` で同じ変数を使う（`$(MAKE)` を使わない。check-docs-sync から抜くとコミットで止まらなくなるため）。
- `.agents/skills` の WARN の塊は消す（`.agents/` がこのリポにも配った先にも無い事を確かめてから）。
- precommit の docsSync を「当たった名前だけ ONLY=」にするのは今回はしない（全部で 0.8 秒。test-selection の範囲に残す）。

## 5. 絞る旗（実装 4）

- `make gl-capture-check SCENES=<名前>,…`。名前は今の SKIP= と同じフォルダ名（`rpg-starter__title`）か、テンプレートのフォルダ名（`rpg-starter` = その場面全部）。
  bin/gl-capture.sh に `--only <名前>` を足し、撮る場面と、比べる時に読む行（2 回撮りどうし・基準のファイル）の両方を絞る（基準は全部の場面を持つので、絞らないと必ず食い違う）。
- `make go-test PKG=<名前>,…` → `go test ./internal/<名前>/...`。既定は `./...`。
- 名前の旗は人が決めた SCENES= と PKG= にする（ONLY= にそろえる案は、lint の ONLY と意味が違う＝名前の一覧でなく場所なので取らない）。

## 6. test の 4 つの口を `make test` にまとめる（実装 5）

```
make test                 engine と 3 層（今の make test と同じ）
make test ALL=1           テンプレートを含む（今の test-all）
make test JOBS=6          並べて流す（今の test-par。ログは .test-logs/）
make test ALL=1 JOBS=6    今の test-par-all
```

- レシピは xargs の道 1 本にまとめ、JOBS の既定は 1（逐次でも .test-logs に残り、status が読める）。逐次の時は最初の赤で止める（今の make test と同じ）。
- JOBS はコマンド行から来た時だけ効かせる（`$(origin JOBS)` が `command line`。シェルの環境の JOBS で勝手に並列にならない）。
- 古い `test-par`・`test-all`・`test-par-all` と `TEST_PAR_JOBS` は 1 リリース残す。新しい口を呼ぶ前に「[test] 次から make test ALL=1 JOBS=6」と 1 行出す。
- release の門: `RELEASE_GATES := release-guard studio-parity sync test-release gl-parity`。`test-release`（隠しの口）は
  `make test ALL=1 JOBS=$(or $(JOBS),$(TEST_PAR_JOBS),6)`。逐次に倒すのは `make release JOBS=1`。
  `TEST=` を渡された時は「古い書き方」と 1 行出し、RELEASE_GATES の真ん中を `$(TEST)` に置き換えて流す（verified.txt の gates の行にもその名前が出る。
  release-marker-check は gates の行を読まない）。1 リリース後に TEST= ごと消す。
  studio-parity の `$(MAKE) -C $(STUDIO)` には `MAKEOVERRIDES=` を付け、コマンド行の変数（JOBS・TEST・ALL など）を丸ごと Studio の Makefile へ渡さない。
- forbid.json に `make test-par-all` / `make test-all` / `make test-par` / `TEST=test` / `TEST_PAR_JOBS` を .md・Makefile・.json で止める規則を足す。
  skip に `docs/migrations/`・`plans/`・`NOTES.md`（過去の記録）。Makefile の別名の定義の行は unlessLine で外す。forbid.json はゲームへ配られるが、
  ゲームの Makefile にこの口は無く、当たるのはゲームの .md に engine の古い口を書いた時だけ（直してよい物）。
- 逐次（JOBS=1）は for の道に分け、最初の赤で止める（xargs -P 1 は子が非 0 でも次へ進む）。
- 追随: release の skill・verify の skill（「make verify SUITE=quick が作業中の既定・test / release / gui はリリース前」）・docs/performance.md・
  status.go の「make test / make test-par」・heavy_test・docs/flow.md・plans/test-selection.md（4 節・7 節の相談事 2・7 節 5 番の make test-changed → make verify SUITE=affected）。
- heavy: `verify` を長い物に丸ごと入れる（quick も長い物の枠で待つ。十数秒なので受け入れる）。

## 7. 新しい口の書き先とお題

engine のリポだけの口（`bin/fge gates`・`make verify SUITE=`・`make test ALL=1`・SCENES=・PKG=）はゲームで打てない。
agents-pack の早見表（ゲームへ配る AGENTS.core.md）とお題（ゲームの足元で流れる engine.json）に入れると、ゲームでは正解の口が無い。
→ engine の AGENTS.md の「検証」に書き、AGENTS.md の「新しい仕組みを入れたら」の行に「engine のリポだけの口は AGENTS.md の検証に書き、お題は足さない」を足す。
ただし `bin/fge gates` は fge-go の sub なのでゲームにも在る。ゲームで打つと「gates.json が無い（engine のリポでだけ使う）」と言って exit 2。

## 8. 相談点

1. 案 B（レビュー 1 回目も推し）。
2. 早見表とお題は engine の口なので足さない（レビュー 1 回目の推し）。依頼の「早見表に 1 行とお題 1 本」とずれるので報告で人に確かめる。
3. load-copy は precommit-local に足す（レビュー 1 回目も推し）。
