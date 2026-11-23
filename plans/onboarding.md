# 始め方（install.sh と fge new）

状態: 設計 第 1 版（相談中）。実装は未着手。ダッシュボード（plans/dashboard.md）より先に作る（2026-11-23 の作者の判断）。

## 0. 決まっていること

- **最初は小さく。** 「触ってもらう」課題に直接つながる最小の形だけを作る。
- **入れる物は 1 本のバイナリだけ。** npm・devbox・engine の clone を利用者に要らせない。
- **対象は macOS と Linux。** Windows は、ゲームの make（make・bash・perl）を要らなくする計画が終わるまで対象外。

## 1. 今の始め方と、詰まる所

| 手 | 今 | 詰まる所 |
|---|---|---|
| 道具を入れる | devbox（jdk・flix・go・ffmpeg を nix で取る） | nix の初回は数 GB。README は Go と ffmpeg に触れていない |
| engine を手元に置く | `git clone` して `make sync` | Maven から取るので初回が長い。中断すると lock が残る |
| bin/fge を作る | `make go-build`（README に無い） | 無いと `make new-game` が「bin/fge-go がありません」で止まる |
| ゲームを作る | `make new-game GAME=/abs/path NAME=x` | GAME は絶対パス必須。engine の作業ツリーがきれいで main に入っている必要がある |

## 2. 新しい始め方

```sh
curl -fsSL https://github.com/ababup1192/flix_game_engine/releases/latest/download/install.sh | sh
fge new mygame                 # 今のフォルダに mygame/ を作る（--template rpg-starter など）
cd mygame && make run
claude                         # AGENTS.md・skills・hooks は fge new が置いてある
```

### 2.1 install.sh（Release に添える・約 60 行の sh）

1. `uname -s` と `uname -m` から `darwin|linux` × `amd64|arm64` を決める（それ以外は止める）。
2. 同じ Release の `fge-<os>-<arch>` と `fge-SHA256SUMS.txt` を curl で取り、照合する（`shasum -a 256` か `sha256sum`）。
3. `~/.flix_ge/bin/fge` に置く（`FGE_HOME` で替えられる）。PATH に無ければ、足す 1 行を出す（シェルの設定ファイルは書き換えない）。
- WhyNot raw.githubusercontent の main の install.sh: 版が付かない。Release に添えれば install.sh と fge の版がそろう。
- WhyNot GitHub Pages: Pages の設定がまだ無い。Pages はデモの置き場と一緒に後で足す。
- WhyNot シェルの設定を書き換える: 利用者の dotfiles を勝手に触らない（rustup と同じく案内だけ）。

### 2.2 Release に足す物（.github/workflows/release.yml と Makefile の bundle-zip）

- `fge-<os>-<arch>`（今の `go-build` が build/ に作る 5 種のうち darwin と linux の 4 本）と、その `fge-SHA256SUMS.txt`。
- `install.sh`。
- WhyNot 今の `SHA256SUMS.txt` に足す: 凍結した Studio の self-update がこの 1 行を読む。形を替えず、別のファイルにする。

### 2.3 fge が「全体の fge」として動く時

`fge` は engine の Go（fge-go）そのもの。engine の外（`~/.flix_ge/bin/fge`）から打たれた時だけ使えるサブコマンドを足す。

| コマンド | すること |
|---|---|
| `fge new <名前> [--template <名>] [--title <題>]` | 下の 2.4 |
| `fge engines` | `~/.flix_ge/engines/` にある版と、最新の版を出す |
| `fge self-update` | install.sh と同じ手順で fge を差し替える |

- 全体の fge が持つのはここまで（ランチャー・新規作成）。ゲームの中の作業（render・lint・dashboard）はそのゲームの `bin/fge`。
  WhyNot 全体の fge でゲームの作業もする: ゲームごとに engine の版が違う。古い版のゲームを新しい道具で触ると、Studio の追従の失敗が戻る。

### 2.4 fge new の中身

1. **engine を取る**: `~/.flix_ge/engines/<版>/` に無ければ、fetchengine（go/internal/fetchengine。`--version`・`--into` を持つ）で
   Release の zip を取り、照合して開く。版は既定で最新（`--engine <版>` で指定）。
2. **JDK を取る**: `~/.flix_ge/jdk/<版>/` に無ければ Adoptium の API から Temurin を取る。版は engine の zip にある
   `bin/lint-rules/jdk.json`（新しく足す。今は `{"major": 25, "version": "25.0.3"}`。devbox.lock と同じ）で決める。
   - WhyNot PATH の java を使う: マイナー版がずれるとフォントの計測がずれて絵が変わる（bin/flix:46-49）。engine の版ごとに固定する。
   - devbox.lock と jdk.json の版が食い違ったら `make check-docs-sync` で止める。
3. **前提を確かめる**: make・perl・git が PATH にあるか。無ければ OS ごとの入れ方（macOS は `xcode-select --install`）を出して止める。
4. **作る**: `make -C <engine> new-game GAME=<今のフォルダ>/<名前> NAME=<名前> TEMPLATE=<名> TITLE=<題> JAVA=<JDK の java>`。
   配った engine は `IS_BUNDLE` になり、engine の作業ツリーの検査（engine-full-fresh）を飛ばす（Makefile:1540-1543）。
5. **local.mk に書き足す**: new-game が書く `ENGINE ?= <engine>` の下に `JAVA = <JDK の java>`。
   mk/game.mk は `JAVA ?= java`（:42）なので、これでゲームの make が固定の JDK を使う。
6. 最後に「次にやること」を出す（`cd <名前> && make run`・`make debug`・`claude`）。

- 名前の決まり（英小文字はじまり）は new-game がそのまま検査する。全体の fge は検査を写さない。
- テンプレートを選ぶ: `--template` が無ければ、`<engine>/templates/` の一覧を番号つきで出して選ばせる（端末でない時は game-starter）。
- `make new-game` の最後の案内の「Studio で開く」は消す（Studio は凍結）。

## 3. 確かめ方

- `go/internal/onboarding`（仮）のテスト: OS と CPU の名前の対応・SHA256 の照合・local.mk の書き足し・テンプレート一覧。
  外への取りに行く所は、fetchengine のテストと同じく httptest のサーバーで置き換える。
- 通しの確かめ（手で 1 回・リリースの前）: 空の HOME で install.sh → `fge new` → `make run` が macOS と Linux で通る。
  CI に入れるのは Linux の `fge new` まで（画面を開かない check と test）。
- 新しい仕組みなので、agents-pack/AGENTS.core.md の早見表に 1 行（「engine の版を手元に揃える・新しいゲームを作る → `fge new`」）と、
  agents-pack/agent-eval/engine.json にお題を 1 本。

## 4. 後に回す物

- `fge upgrade`（版上げ）: plans/dashboard.md の 14 節。始め方が回ってから。全体の fge に置く。
- Homebrew・winget・Windows（make を要らなくする計画の後）。
- GitHub Pages のデモと、README の「インストールせずに遊ぶ」。

## 5. 決めていないこと

1. 作る先の既定: 今のフォルダの下（`./<名前>`）でよいか。plans/dashboard.md 13 節のワークスペースは、`fge add` で後から一覧に足す。
2. ffmpeg（Tape と動画を撮る時だけ要る）を fge が取るか、要る時に入れ方を出すだけにするか。案は後者。
