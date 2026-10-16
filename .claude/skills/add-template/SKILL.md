---
name: add-template
description: "templates/ にスターターを足す・更新する手順。reference/title.png・lint-palette・Doc 外形規約・画風の宣言・Studio への登録と swap-jar まで、どれか 1 つ欠けると Studio で「出ない / 絵がない / 作れない」になる 7 手順を出す。新しいジャンルのテンプレを作るとき、templates/ 配下を直すとき、make new-game が動かないとき、Studio のジャンルカードに絵が出ないときに使う。"
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

# テンプレートを足す・更新する

`templates/` の各スターターは `make new-game` の複製元であり、Studio の「ジャンル」の顔でもある。

## 2 系統ある

- **具体値式**（rpg / novel / race / tetris / platformer-starter）: 値をそのまま書く。**in-repo で
  `make -C templates/<name> check / test / render-all` が通りリファレンス画像を持つ**作り込み例。
  凝った演出もテストも載せられる。Studio の「はじめる」は複製で始まる。
- **トークン式**（game-starter）: `__NAME__` `__W__` などを埋めた最小の骨組み。
  in-repo ではビルドしない（`make new-game` が置換して初めて動く）。W/H を引数で決める素体。

## 空の抜け殻を置かない

`src/` の無いディレクトリを `templates/` に残すと、Studio のジャンルカードからは選べるのに複製しても動かない。
中身を作れないうちは Studio 側の `starter` を空にしておき、**ディレクトリごと作らない**
（存在しないパスを `starter` に書くのも同じ事故になる）。

## 手順

このチェックリストを回答にコピーし、埋めながら進める。
**どれか欠けると Studio で「出ない / 絵がない / 作れない」になる。**

```
- [ ] 1. templates/<genre>-starter/ を作った（rpg-starter を写経元に。具体値式ならリファレンス画像も生成する）
- [ ] 1b. Makefile は共有 mk を include するだけにした（共通ターゲットを書かない）
- [ ] 2. reference/title.png を用意した
- [ ] 3. make lint-palette が通った
- [ ] 4. Doc の外形規約を守った（全 Doc に version・schema は sections 方言）
- [ ] 5. 画風を宣言した（AGENTS.local.md + View.flix 冒頭の層の並び）
- [ ] 6. Studio に登録した（Genesis.flix の families の starter）
- [ ] 7. make swap-jar して Studio を Cmd+Q → 開き直した
```

### 1b. Makefile に共通ターゲットを書かない

`run` / `test` / `check` / `render` / `status` などの共通の口は engine の `mk/game.mk` が持つ。
テンプレの Makefile はそれを include し、`SHOTS`・`PALETTE`・`PALETTE_DEPS`・`RENDER_NOTE` と
そのテンプレ固有のターゲットだけを持つ（写経元は `templates/rpg-starter/Makefile`。
`-include local.mk` → `ENGINE ?= ../..` → ENGINE 不在の `$(error)` ガード → 空白を退避した
`include` の順で、この 4 つはそのまま写す）。

写すと engine を直しても既に産まれたゲームへ届かない（`upgrade-game` が運ぶのは flix.toml の
バージョンと `lib/` と agents-pack だけで、Makefile は取り残される）。

### 2. `reference/title.png` を必ず用意する

Studio のジャンルカードのサムネイルは `GET /genesis/title` がこれを読む（無いと空絵になる）。
生成に `title` シーンを 1 枚足してリファレンス画像を更新する。

更新は `make -C templates/<name> reference-update`。これが `gallery/*.png` を `reference/` へ写し、
**`reference/SHA256SUMS.txt` まで作り直す**。git に入るのはこの一覧と `title.png` だけで、
他のリファレンス画像 PNG は管理外（`make reference-check` は一覧と突き合わせて退行を見る）。
`SHA256SUMS.txt` を作り忘れると、clone した人の `make reference-check` が「リファレンス画像がまだ作られていません」で止まる。

**トークン式（game-starter）だけは `SHA256SUMS.txt` を持てない。** `__W__` を埋める前は
型検査が通らず描き出せないので、退行検知そのものが成り立たない（`TEMPLATE_DIRS` から
除外されているのも同じ理由）。`title.png` は Studio のサムネイル用に手で置く。
この 1 本を「期待値の更新し忘れ」として直そうとしない。

### 3. `make lint-palette` を通す

ドット絵（`*.sprite.json`）の `legend` に書いた意味色キーは、`*.theme.json` のトップレベル・
`paletteFile` の指す色票・直下の `palette` のどれかに実体が無いと Studio が仮色で塗り、
編集画面と実機で配色が食い違う。

派生色をコードで導いているなら、色票 JSON を生成する `make` ターゲットを作り、
`paletteFile` でそれを指す（`kaidan` の `Palette` モジュール + `palette` ターゲット +
テストが手本。テストで生成物と実機の色を pin する）。

### 4. Doc の外形規約を守る

[docs/doc-conventions.md](../../../docs/doc-conventions.md) に従う。全 Doc ファイルに `version` を入れる
（無いと Studio の健康診断が「version がありません」を出す）。

`*.schema.json` は Studio の **sections 方言**で書く（語彙リファレンス形式で書くと
Studio のフォームが「Expecting an OBJECT with a field named `sections`」で読めない。
語彙の解説は docs/ 側に置く）。詳しくは `/doc-design`。

### 5. 画風を宣言する

`AGENTS.local.md` に「## この画面の画風」を書き（色 3 つ・やらないこと 1 つ）、
`src/View.flix` の頭に層の並びと、各層が「絵の下限」の 5 性質のどれを受け持つかを書く。

**テンプレどうしで画風をそろえない** — 揃えると「この画風が正解」という手本になってしまう
（テンプレごとに別画風にしてある。現物は各 `AGENTS.local.md` の「## この画面の画風」宣言が正）。

**音と粒（パーティクル）も絵と同じ強さで意識する**。詳しくは [docs/audio.md](../../../docs/audio.md) と
`/visual-dict`。粒を出すときはまず `make module Q=粒` で逆引きを引く。

### 6. Studio に登録する

`flix_ge_studio` の `server/src/Genesis.flix` の families で、該当ジャンルの
`starter = "templates/<genre>-starter"` にする（starter が空だとゼロ生成フローのまま）。

### 7. Studio に反映する

`flix_ge_studio` で **`make swap-jar`**（動いている `.app` の同梱 jar を差し替え + 再署名）
→ Studio を Cmd+Q して開き直し。**`make jar` だけでは動いている .app に効かない**。

## 複製する

`make new-game GAME=/abs NAME=x TITLE=題名 TEMPLATE=<genre>-starter`

TITLE は自由文でよい（アポストロフィ・空白・記号も通る）。具体値式テンプレは自身の W/H・題名を
使う（引数の W/H・TITLE は反映されない — 作成後に project.json の「ゲームの題・画面」Doc で変える）。
