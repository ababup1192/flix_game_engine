# 始め方（install.sh と fge new）

状態: 設計 第 2 版（相談中）。実装は未着手。ダッシュボード（plans/dashboard.md）より先に作る（2026-11-23 の作者の判断）。
初回なのでレビューは 90 点以上で実装に入る（作者の判断）。第 1 版は 60 点。指摘とスパイクへの答えは 6 節。

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

### 2.2 Release に足す物（Makefile の `release-publish` の `gh release create`・:1127-1131）

- `fge-<os>-<arch>`: `go-build` が作る `bin/dist/fge-go-<os>-<arch>` のうち darwin と linux の 4 本を、`fge-` の名前で添える
  （利用者が打つ名前は `fge`。中身は fge-go と同じ）。と、その `fge-SHA256SUMS.txt`。
- `install.sh`: 添える時に版を埋める（`FGE_VERSION=0.109.0` の 1 行を書き込む）。latest の URL から取った install.sh が、
  同じ Release の fge を取る（版の食い違いが起きない）。
- **engine の zip に LWJGL の natives（`lib/external/lwjgl-*-natives-*.jar`）を入れる。** new-game は `render_gl/lib/external` から写すが（Makefile:1622-1626）、
  zip にはそれが無い。natives は lib/cache を通らないので、無いとゲームを作るたびに Maven Central へ取りに行き、続けて作ると 429 で止まる。
  stage-engine.json の `@maven-seed/external` を bundle-zip でも渡す（Studio と同じ物）。lib/cache の種は入れない（大きい・初回ビルドで取れる）。
- WhyNot 今の `SHA256SUMS.txt` に足す: 凍結した Studio の self-update がこの 1 行を読む。形を替えず、別のファイルにする。

### 2.3 fge が「全体の fge」として動く時

`fge` は engine の Go（fge-go）そのもの。`new`・`engines`・`self-update` は、どこから打っても全体の fge として動く
（engine やゲームの中の文脈を読まない。見分ける要が無い）。ゲームの中で使うのは、そのゲームの `bin/fge`。

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
   - **fetchengine に「単体で入れる」形（`--standalone`）を足す。** 今は Studio 向けで、`bin/flix` を Studio から持ち越す前提
     （stage-engine.json で `@flix-wrapper` が `owner: studio`・fetchengine.go:433-447）と、`bin/flix` に `/jre/` の字がある検査
     （:483-489）がある。standalone はこの 2 つを飛ばし、zip の `bin/flix`（リポの bin/flix と同じ・Makefile:1150）をそのまま使う。
     機械に合う fge-go を選び直す所（pickFgeGo）はそのまま使う。スパイク（6 節）で `--carry-from` 無しでは止まるのを確かめた。
2. **JDK を取る**: `~/.flix_ge/jdk/<配り元>-<版>/` に無ければ取る。配り元と版は engine の zip にある
   `bin/lint-rules/jdk.json`（新しく足す）で決める。今は `{"vendor": "zulu", "version": "25.0.3"}`（devbox.lock:277 が zulu-ca-jdk-25.0.3）。
   取り先は Azul の API（api.azul.com）と配布サーバー（cdn.azul.com）。照合は API が返す sha256。
   - WhyNot PATH の java を使う: マイナー版がずれるとフォントの計測がずれて絵が変わる（bin/flix:46-49）。engine の版ごとに固定する。
   - WhyNot Temurin（GitHub の Release から取れる）: devbox は Zulu。engine の作者の手元と配り元をそろえる。Temurin に替えるなら devbox も同時に替える。
   - devbox.lock と jdk.json の配り元・版が食い違ったら `make check-docs-sync` で止める。
3. **前提を確かめる**: make・perl・git が PATH にあるか。無ければ OS ごとの入れ方（macOS は `xcode-select --install`）を出して止める。
   macOS の make は 3.81（GNU make の古い版）で、通しの確かめもこの make で行う（engine の CI は devbox の gnumake なので、ずれに気づけない）。
4. **作る**: `make -C <engine> new-game GAME=<今のフォルダ>/<名前> NAME=<名前> TEMPLATE=<名> TITLE=<題> JAVA=<JDK の java>`。
   配った engine は `IS_BUNDLE` になり、engine の作業ツリーの検査（engine-full-fresh）を飛ばす（Makefile:1540-1543）。
5. **local.mk を書く**: new-game が書く `ENGINE ?= <engine の絶対パス>` を下の形に置き換え、`export JAVA := <JDK の java>` を書き足す。
   macOS と Linux では、ゲームの make は `$(ENGINE)/bin/flix` を呼び（mk/game.mk:55）、bin/flix は環境の `JAVA` を最初に見る
   （bin/java-resolve.sh:42）。WhyNot `JAVA =`（export 無し）: mk/game.mk の `JAVA ?= java` は Windows の時だけの行で（:41-42）、
   make の変数のままでは bin/flix に届かない。
   - bin/flix は PATH の `flix`（nix の物）があれば、その jar を先に使う（:59-67）。devbox を入れた人の手元では engine の flix.jar と
     食い違いうる。new-game の確かめで、使った jar を `FLIX_PRINT_JAR=1` で 1 行出す。
6. 最後に「次にやること」を出す（`cd <名前> && make run`・`make debug`・`claude`）。

- 名前の決まり（英小文字はじまり）は new-game がそのまま検査する。全体の fge は検査を写さない。
- テンプレートを選ぶ: `--template` が無ければ、`<engine>/templates/` の一覧を番号つきで出して選ばせる（端末でない時は game-starter）。
- `make new-game` の最後の案内の「Studio で開く」は消す（Studio は凍結）。
- **local.mk の ENGINE は flix.toml の版から決める**（`ENGINE ?= $(HOME)/.flix_ge/engines/<flix.toml の版>/engine`・plans/dashboard.md 14.1）。
  固定のパスを書くと、版上げの後に古い engine を読み続ける（7 節のスパイク）。JAVA も engine の jdk.json から同じように決める。
- 配った engine（git の作業ツリーでも go/ を持つ形でもない）で new-game を流すと、`fatal: not a git repository` と `cd: can't cd to go` が
  出る（スパイクで確かめた・止まりはしない）。初めての人を不安にさせるので、IS_BUNDLE の時は出さない。

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

## 6. レビュー（第 1 版・60 点）とスパイクへの答え

| 指摘・見つけた事 | 答え |
|---|---|
| fetchengine は `--carry-from` 無しでは止まる・`/jre/` の検査（スパイクでも止まった） | 2.4 の 1 に `--standalone` |
| local.mk の `JAVA =` は bin/flix に届かない | 2.4 の 5 で `export JAVA :=` |
| LWJGL の natives が zip に無く、作るたびに Maven へ行く | 2.2 で zip に入れる |
| devbox の JDK は Zulu | 2.4 の 2 で Zulu・配り元も jdk.json に |
| 公開は release.yml でなく release-publish・名前は bin/dist/fge-go-* | 2.2 |
| install.sh に版を埋める | 2.2 |
| macOS の make 3.81・PATH の flix を先に拾う・全体の fge の見分け | 2.4 の 3・5・2.3 |
| （スパイク）Adoptium の API はネットワークで止まりうる | Zulu に替えたので使わない。Azul も止まる所では、jdk.json の取り先を差し替えられるようにする（`FGE_JDK_URL`） |
| （スパイク）配った engine の new-game が雑音を出す | 2.4 の末尾 |

## 7. スパイクの記録（2026-11-23・Linux のコンテナ）

Release の zip を手で開いた engine（fetchengine は 6 節のとおり止まるので手で開いた）と、JDK 25.0.3（Zulu の代わりに同じ版の Temurin。
この環境は Azul にも Adoptium の API にも届かなかった）で流した。

| 確かめたこと | 結果 |
|---|---|
| v0.108.0 の zip を取って SHA256SUMS で照合 | 通った（10 秒） |
| 配った engine（IS_BUNDLE）で `make new-game … JAVA=<JDK>` | **通った**（2 分 41 秒。check → test → render-all まで）。`JAVA=` は子の make に届いた |
| LWJGL の natives | 作るたびに Maven Central から取った（2.2 で zip に入れる裏付け） |
| 雑音 | `fatal: not a git repository`・`cd: can't cd to go`・ログの日本語が `??????`（ロケールが無い時）。止まりはしない |
| v0.107.0 で作ったゲームを v0.108.0 の engine で `make upgrade-game` | **通った**（31 秒・check 緑）。skills・AGENTS.md・agent-eval・bin/fge-go・flix.toml・packages.lock が新しい版になった |
| 版上げの後の local.mk | **ENGINE は 0.107 のまま**。`make status` が「pack 古い（AGENTS.md は 0.108・engine は 0.107）→ engine 側で make sync-agents を再実行」と出し、その通りにすると skills が 0.107 に**戻る**。plans/dashboard.md 14.1 の「ENGINE を flix.toml の版から決める」が要る裏付け |

## 5. 決めていないこと

1. 作る先の既定: 今のフォルダの下（`./<名前>`）でよいか。plans/dashboard.md 13 節のワークスペースは、`fge add` で後から一覧に足す。
2. ffmpeg（Tape と動画を撮る時だけ要る）を fge が取るか、要る時に入れ方を出すだけにするか。案は後者。
