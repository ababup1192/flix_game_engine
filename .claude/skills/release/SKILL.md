---
name: release
description: "このリポジトリの検証とリリースの手順。作業中にどこまでテストを回すか、リリース前の全量ゲート、生成のバイト一致比較をいつやるか、バージョンを上げて GitHub Release を作るまでを出す。make release / make bump を打つとき、バージョンを上げるとき、「リリースしたい」「公開して」と言われたとき、全部のテストを回すか迷ったときに使う。"
allowed-tools: Read, Grep, Glob, Bash
---

# 検証とリリース

## 作業中のループ（毎回やる）

**テストは絞って速く回す。全量の検証はリリース直前の 1 回だけ。**

- 変更が波及したパッケージだけ `make test-<name>`
- それ以外は `flix check`（コンパイル通過）で足りる
- テストを持たないパッケージ（templates 等）は常に check のみ

## 生成のバイト一致比較

**「挙動を変えていない」と主張するリファクタの時だけ**やる。機能追加リリースでは不要。

**`gallery/` は git 管理外なので `git status` では見えない。** 生成した絵の一致は
`make reference-check` の SHA 突き合わせで見る。

1. ルートの `make render-par`（不審なら逐次の `make render-all`）。どちらも各テンプレで
   全量の `make render-all` を打つ。テンプレ 1 本だけ確かめたいときは
   `make -C templates/<name> render-all`（`make render SHOT=<場面名>` は 1 枚だけなので
   リリースの全量ゲートには使わない）
2. `git status` で assets/sfx の差分ゼロを確認（音や素材の退行はここに出る）
3. `for d in templates/*/; do make -C "$d" bench; done` で全テンプレの絵が基準と一致するか確認
4. 基準を持たない絵は、生成し直した `gallery/` を自分で目視する
   （`.claude/skills/critique-render` の手順）

`bin/fge images` も併せて通す（生成した絵が git に紛れ込んでいないか）。

## リリース手順

公開は GitHub の Actions の `release`（`.github/workflows/release.yml`）の 1 本。手元は門（テスト）だけを通す。
このチェックリストを回答にコピーし、埋めながら進める。

```
- [ ] 1. make bump FROM=x TO=y → コミット / main へ push（どこで流してもよい）
- [ ] 2. 手元で make release（= make release-verify。通した commit を release/verified.txt に書く）
- [ ] 3. release/verified.txt をコミット / main へ push（2 と 3 の間に main へほかを入れない）
- [ ] 4. Actions の release を main で起動（CI が make release-publish）
- [ ] 5. lib/ を消したコピーで外部 fetch 検証（fpkg と toml に加え、GL の層の jar `fge-gl-<ハッシュ>.jar` も置き場の Release から取れて build と run が通るか）
```

手元の `make release` は release-guard → studio-parity → `sync` → `test-par-all`（全量ゲート）→ `gl-parity` を通して
印を書くだけで、公開はしない。CI は、印の版が `VERSION` と同じか・印の commit から HEAD までの差が印だけか・
タグがまだ無いかを見て（`make release-marker-check`）、`sync` → `gl-jar-publish` → build-pkg → `bundle-zip` → `gh release create` を
流す。tag は印を載せた commit に付く。2 の後に 1 行でも変えたら止まるので、2 からやり直す。
CI ではテストを流し直さない（スナップショットが OS と JRE のフォントの差でずれる。`release-gate.yml` と同じ）。
窓を開く門（`make determinism`・`make gl-capture-check`・`make smoke-devtools`）は `make release` に入っていないので、
`make sync-engine-full` の後に手元で流して緑を確かめてから 2 へ進む（`docs/flow.md` の決定性の門）。

配る物を手元で組まないのは、作業ツリーを写すと git の管理外の `debug/`・`gallery/`・`packages.lock` まで
同梱 zip に入るため（0.67.0・0.68.0 は tidepool-starter の録画で 1.2 GB になった）。CI のきれいな checkout から
組んだ物が正。

`make bundle-zip`（単体でも打てる）は Studio に同梱する engine 一式（`bin/fge stage-engine`）を
`flix_game_engine-engine-v<バージョン>.zip` に固める。中身の一覧は
`bin/lint-rules/stage-engine.json` が source of truth で、組み立てた後に `check-refs --bundle` 相当の
照合まで通る。lwjgl（Maven）の種は入っていない（Studio 側が自分の `server/lib` から渡す）。

## GL の層の jar の置き場（版とは別）

`flix.toml`（ルート）・`render_gl/flix.toml`・`engine_full/flix.toml` の `[jar-dependencies]` は、GL の層の jar を
**版のリリースでなく** Release `fge-gl-<ハッシュ>` の `fge-gl-<ハッシュ>.jar` から取る。ハッシュは `render_gl/java` の
`*.java` の中身と組み方（`--release` と LWJGL の版）から make が出す 12 桁で、Java を直した時だけ変わる。
版を上げても jar の行は変わらない（`make bump` は触らず、前後で `make gl-jar-pin-check` を通す）。

`render_gl/java` を直したら:

1. `make gl-jar-pin` … 3 つの flix.toml の jar の行を新しいハッシュへ書き換える（Java の変更と同じコミットに入れる）
2. 置き場を作る … 次のどちらか（どちらも、その Release と jar がもうあれば何もしない）
   - main へ push する → `.github/workflows/gl-jar.yml` が `make gl-jar-publish` を流す
   - main より先に作るなら手で `make gl-jar-publish GL_JAR_TARGET=<push 済みの commit か枝>`（`gh` の認証が要る。jar は作業ツリーから組むので、`render_gl/java` をその commit と同じにしておく）

忘れた時の門: コミットでは `bin/fge precommit` の localGate（ルートの `make precommit-local`）が、毎回
`make gl-jar-pin-check` を流す（1 秒かからない）。`make bump` も前後で流す。`make release` の release-guard も同じ検査を通し、
CI の `make release-publish` は版を出す前に `make gl-jar-publish` で置き場を埋める。

置き場の Release は `--prerelease --latest=false` で作る（「最新のリリース」は版のリリースのままにする。`bin/fge fetch-engine` が
`releases/latest` でそれを見る）。`make gl-jar` は同じ機械・同じ JDK なら同じソースから同じバイトの jar を作る（中の時刻は `--date` で固定。JDK や機械が違えばバイトはずれうるが、pin はソースのハッシュなので門は変わらない）。

`bin/fge export-web` は、書き出しの flix.toml（engine_full_web）が宣言する名前で `build/gl-jar` の jar を拾い、ゲームの `lib/external` へ置く。手元の書き出しは置き場の Release へ取りに行かない。

## こけやすいゲート（特にエンジン拡張のあと）

コミットや `make release` で止まる原因は毎回だいたい同じ。打つ前にここを潰す:

- **precommit ゲート**: コミットの瞬間に `bin/fge precommit` が走る。何で止まるかは
  `bin/fge precommit --files <ステージ予定のファイル…>` で**コミット前に素振りできる**。
  よく引っかかるのは ①pub 宣言・doc コメントを触ったのに `docs/api-digest.md` が古い
  （`make api-digest` で作り直してから一緒にステージ）②docs / skills を触った時の
  `make check-docs-sync`（AGENTS.md と agents-pack の sync 印ずれ・切れたリンク）
  ③`bin/fge jargon` の独自語
- **jargon は `bin/fge jargon <触ったパス…>` で素振りする**（コミットコマンドを
  人へ渡す前に自分で通す）。precommit 経由は `git diff --cached` を読むので、`git add` の
  後に直しても同じ指摘が出続ける
- **sync の出し忘れ**: engine / engine_world / engine_tools のソースを触ったら対応する
  `make sync-<name>` を通してからテストする。古い fpkg のまま緑になっても信用できない
- **lint 群は先に手で回す**: フック任せにせず `make lint-view lint-palette lint-ui lint-audio` を
  リリース前に一巡させる。既知の赤が残ったままだとゲートで止まる
- **`make test-par` の偽 FAIL**: ログが依存解決で途切れテスト 0 本なら並列の食い合い。
  当該パッケージを単体 `make test-<name>` で確かめ、必要なら `make release TEST=test`（逐次）
- **`make release` は未コミットで中断する**: `gallery/` や `NOTES.md` は git 管理外なので
  `git status` に出ない＝残っていても邪魔しない。出ている差分だけ全部コミットする

**全量ゲート**は `make test-par`（全パッケージ並列・実時間 ≈ 最遅パッケージ 1 本分・ログは `.test-logs/`）。
併せて `make gl-parity` を回して A 段階の全一致（全 scene 0 px）を確認する（GL と SoftRaster の絵の退行はテストに出ない）。
並列版に不審な挙動があれば逐次へフォールバックする（`make test` / `make release TEST=test`）。
