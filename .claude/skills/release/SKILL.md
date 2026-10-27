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

このチェックリストを回答にコピーし、埋めながら進める。

```
- [ ] 1. engine ソースが全てコミット済み（未コミットなら make release が中断する）
- [ ] 2. make bump FROM=x TO=y
- [ ] 3. コミット / push（push を忘れると gh が明示エラーを出す）
- [ ] 4. make release
- [ ] 5. lib/ を消したコピーで外部 fetch 検証
```

`make release` は sync → `test-par`（全量ゲート）→ `gl-parity` → build-pkg → `bundle-zip` →
`gh release create` を一括で回す。tag は現在の HEAD SHA に固定される。Release には
fpkg・toml と一緒に同梱用 zip も上がる。

### 公開だけを CI に任せる（gh にログインしていない所・クラウドのセッションから出す）

門（テスト）は手元で通し、公開は GitHub の Actions の `release`（`.github/workflows/release.yml`）がする。

```
- [ ] 1. engine ソースが全てコミット済み
- [ ] 2. make bump FROM=x TO=y → コミット / push
- [ ] 3. make release-verify（release と同じ門。通した commit を release/verified.txt に書く）
- [ ] 4. release/verified.txt をコミット / push
- [ ] 5. Actions の release を main で起動（CI が make release-publish）
- [ ] 6. lib/ を消したコピーで外部 fetch 検証
```

CI は、印の版が `VERSION` と同じか・印の commit から HEAD までの差が印だけか・タグがまだ無いかを見て
（`make release-marker-check`）、`sync` → build-pkg → `bundle-zip` → `gh release create` を流す。
3 の後に 1 行でも変えたら止まるので、3 からやり直す。CI ではテストを流し直さない（スナップショットが
OS と JRE のフォントの差でずれるため。`release-gate.yml` と同じ）。

`make bundle-zip`（単体でも打てる）は Studio に同梱する engine 一式（`bin/fge stage-engine`）を
`flix_game_engine-engine-v<バージョン>.zip` に固める。中身の一覧は
`bin/lint-rules/stage-engine.json` が source of truth で、組み立てた後に `check-refs --bundle` 相当の
照合まで通る。lwjgl（Maven）の種は入っていない（Studio 側が自分の `server/lib` から渡す）。

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
