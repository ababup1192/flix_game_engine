# 始め方（install.sh と fge new）

状態: 設計 第 3 版（相談中）。実装は未着手。ダッシュボード（plans/dashboard.md）より先に作る（2026-11-23 の作者の判断）。
初回なのでレビューは 90 点以上で実装に入る（作者の判断）。第 1 版 60 点・第 2 版 80 点。指摘とスパイクへの答えは 8 節。

## 0. 決まっていること

- **最初は小さく。** 「触ってもらう」課題に直接つながる最小の形だけを作る。
- **入れる物は 1 本のバイナリだけ。** npm・devbox・engine の clone を利用者に要らせない。
- **対象は macOS と Linux。** Windows は、ゲームの make（make・bash・perl）を要らなくする計画が終わるまで対象外。
- **engine を clone して直す人（作者）の手元の動きは変えない。** 新しい道は、配った engine（`IS_BUNDLE`・Makefile:53）の時だけ通る。

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

### 2.1 置き場（`~/.flix_ge/`・`FGE_HOME` で替えられる）

```
~/.flix_ge/
  bin/fge                       全体の fge（install.sh が置く）
  engines/<版>/                 engine の zip を開いた物（fetchengine が zip の 1 段目の engine/ を外して開く・fetchengine.go:420-429）
    Makefile  mk/  bin/  templates/  lib/external/（LWJGL の natives・2.3）
  jdk/<配り元>-<版>/bin/java     JDK。macOS の `Contents/Home` は fge が開く時に外し、どの OS でも `<dir>/bin/java` にそろえる
```

### 2.2 install.sh（Release に添える・約 60 行の sh）

1. `uname -s` と `uname -m` から `darwin|linux` × `amd64|arm64` を決める（それ以外は止める）。
2. 同じ Release の `fge-<os>-<arch>` と `fge-SHA256SUMS.txt` を curl で取り、照合する（`shasum -a 256` か `sha256sum`）。
3. `~/.flix_ge/bin/fge` に置く。PATH に無ければ、足す 1 行を出す（シェルの設定ファイルは書き換えない）。
- WhyNot raw.githubusercontent の main の install.sh: 版が付かない。Release に添えれば install.sh と fge の版がそろう。
- WhyNot GitHub Pages: Pages の設定がまだ無い。Pages はデモの置き場と一緒に後で足す。
- WhyNot シェルの設定を書き換える: 利用者の dotfiles を勝手に触らない（rustup と同じく案内だけ）。

### 2.3 Release に足す物（Makefile の `release-publish` の `gh release create`・:1127-1131 と `bundle-zip`・:1169-1181）

- `fge-<os>-<arch>`: `go-build` が作る `bin/dist/fge-go-<os>-<arch>` のうち darwin と linux の 4 本を `fge-` の名前で添える
  （利用者が打つ名前は `fge`。中身は fge-go と同じ）。と、その `fge-SHA256SUMS.txt`。
  WhyNot 今の `SHA256SUMS.txt` に足す: 凍結した Studio の self-update がこの 1 行を読む。形を替えず、別のファイルにする。
- `install.sh`: 添える時に版を埋める（`FGE_VERSION=<版>` の 1 行を書き込む）。latest の URL から取った install.sh が、同じ Release の fge を取る。
- **engine の zip に LWJGL の natives を入れる。** bundle-zip が `bin/fge stage-engine` に `--maven-seed` を渡し、`@maven-seed/external`
  （stage-engine.json）に `render_gl/lib/external/` のうち `lwjgl-*-natives-*.jar` と `fge-gl-*.jar` だけを入れる。全部の機種の分で約 13 MB
  （スパイクのゲームの lib/external の実測）。zip は今 117 MB。`@maven-seed/cache`（lib/cache の種）は入れない（大きい・初回ビルドで取れる）。
  - WhyNot natives を入れない: new-game は natives を `render_gl/lib/external` から写す（Makefile:1622-1626）が zip にはそれが無く、
    natives は lib/cache を通らないので、作るたびに Maven Central へ取りに行き、続けて作ると 429 で止まる（スパイクで取りに行くのを確かめた）。

### 2.4 JDK の版を 1 か所で決める: `mk/jdk.mk`（新しく足す・engine の zip に入る）

```make
# devbox.lock の jdk と同じ物（make check-docs-sync が比べる）。
FGE_JDK_VENDOR  := zulu
FGE_JDK_VERSION := 25.0.3
```

- 配り元は devbox と同じ **Zulu**（devbox.lock:277 が zulu-ca-jdk-25.0.3）。取り先は Azul の API（api.azul.com）と配布サーバー（cdn.azul.com）、
  照合は API が返す sha256。取り先は `FGE_JDK_URL` で差し替えられる（Azul に届かない所のため）。
- WhyNot PATH の java を使う: マイナー版がずれるとフォントの計測がずれて絵が変わる（bin/flix:46-49）。engine の版ごとに固定する。
- WhyNot JSON: make が読む。fge（Go）も `KEY := 値` の 2 行なら読める。1 か所に置いて両方が読む。
- WhyNot Temurin（GitHub の Release から取れる）: devbox は Zulu。engine の作者の手元と配り元をそろえる。替えるなら devbox も同時に替える。

### 2.5 ゲームが engine と JDK を見つける（git に入っている物だけで決まる）

**テンプレートの Makefile の ENGINE の既定を替える。** 今は `-include local.mk` の後に `ENGINE ?= ../..`（game-starter/Makefile:11-13）。

```make
-include local.mk
FGE_VERSION := $(shell sed -n 's/^"github:ababup1192\/flix_game_engine" *= *{ *version *= *"\([0-9.]*\)".*/\1/p' flix.toml)
ENGINE ?= $(if $(wildcard ../../mk/game.mk),../..,$(or $(FGE_HOME),$(HOME)/.flix_ge)/engines/$(FGE_VERSION))
```

- engine の中のテンプレート（`templates/x`）は今までどおり `../..`。`fge new` で作ったゲームは、**その時の flix.toml の版の engine** を指す。
  枝を替えても、worktree でも、ゲームを clone した別の機械でも、git に入っている Makefile と flix.toml だけで決まる。
- local.mk は、上書きしたい時だけに使う（engine を clone して直す人が `ENGINE := <clone>` と書く）。`fge new` は ENGINE を local.mk に書かない
  （new-game は IS_BUNDLE の時は `ENGINE ?=` の行を書かない）。
  - WhyNot local.mk に固定のパスを書く: local.mk は git の外なので、版を上げた後も古い engine を読み続ける（7 節のスパイク）。worktree と別の機械には無い。
- **engine が手元に無い時の案内を替える。** 今の `$(error ENGINE が見当たりません … local.mk に ENGINE を書け)`（game-starter/Makefile:27-29）を、
  ENGINE が `~/.flix_ge/engines/` の下の時は「engine <版> が手元にありません → `fge engines install <版>`」にする。
- **JAVA は engine の `mk/game.mk` が決める。** 配った engine の時だけ、`mk/jdk.mk` を読んで
  `~/.flix_ge/jdk/$(FGE_JDK_VENDOR)-$(FGE_JDK_VERSION)/bin/java` があれば `export JAVA :=` にする。**無ければ止めて**「`fge engines install <版>`」と出す。
  - WhyNot 無い時に PATH の java へ移る: bin/java-resolve.sh は JAVA が無いと何も言わずに PATH の java を使う（:42-45）。それが絵がずれる原因そのもの。
  - WhyNot `JAVA =`（export 無し）: mk/game.mk の `JAVA ?= java` は Windows の時だけの行で（:41-42）、macOS と Linux では
    `$(ENGINE)/bin/flix` を呼ぶ（:55）。bin/flix は環境の JAVA を最初に見る（bin/java-resolve.sh:42）ので、export が要る。
  - engine を clone して直す人（IS_BUNDLE でない）の手元は、今までどおり devbox の java。

### 2.6 全体の fge のサブコマンド

`new`・`engines` は、どこから打っても全体の fge として動く（engine やゲームの中の文脈を読まない）。ゲームの中の作業はそのゲームの `bin/fge`。

| コマンド | すること |
|---|---|
| `fge new <名前> [--template <名>] [--title <題>] [--engine <版>]` | 2.7 |
| `fge engines` | `~/.flix_ge/engines/` にある版と、Release の最新の版を出す |
| `fge engines install <版>` | engine の zip と、その版の `mk/jdk.mk` が指す JDK を取る（あれば何もしない） |
| `fge self-update` | install.sh と同じ手順で fge を差し替える |

- WhyNot 全体の fge でゲームの作業もする: ゲームごとに engine の版が違う。古い版のゲームを新しい道具で触ると、Studio の追従の失敗が戻る。

### 2.7 fge new の中身

1. **engine と JDK を取る**: `fge engines install <版>`（版は既定で最新）。
   - **fetchengine に「単体で入れる」形（`--standalone`）を足す。** 今は Studio 向けで、`bin/flix` を Studio から持ち越す前提
     （stage-engine.json で `@flix-wrapper` が `owner: studio`・fetchengine.go:433-447）と、`bin/flix` に `/jre/` の字がある検査（:483-489）がある。
     standalone はこの 2 つを飛ばし、zip の `bin/flix`（リポの bin/flix と同じ・Makefile:1150）をそのまま使う。
     機械に合う fge-go を選び直す所（pickFgeGo）はそのまま使う。
2. **前提を確かめる**: make・perl・git が PATH にあるか。無ければ OS ごとの入れ方（macOS は `xcode-select --install`）を出して止める。
3. **作る**: `make -C <engine> new-game GAME=<今のフォルダ>/<名前> NAME=<名前> TEMPLATE=<名> TITLE=<題>`。
   配った engine は `IS_BUNDLE` になり、engine の作業ツリーの検査（engine-full-fresh）を飛ばす（Makefile:1540-1543）。JAVA は 2.5 のとおり game.mk が決める。
4. 最後に「次にやること」を出す（`cd <名前> && make run`・`make debug`・`claude`）と、
   「配られた skills・rules・AGENTS.md の共通部は版上げで上書きされる。ゲーム用に変えたい時は AGENTS.local.md に書くか、別の名前のスキルを足す」の 1 行。
   同じ 1 行を agents-pack/AGENTS.core.md の頭にも足す。

- 名前の決まり（英小文字はじまり）は new-game がそのまま検査する。全体の fge は検査を写さない。
- テンプレートを選ぶ: `--template` が無ければ、`<engine>/templates/` の一覧を番号つきで出して選ばせる（端末でない時は game-starter）。
- new-game の直し（IS_BUNDLE の時だけ）: 最後の案内の「Studio で開く」を消す。`fatal: not a git repository`・`cd: can't cd to go` を出さない
  （スパイクで出た。止まりはしないが初めての人を不安にさせる）。
- ログの日本語が `??????` になる（スパイク。ロケールの無い所で java が標準出力を ASCII で書く）: bin/flix が java に `-Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8` を付ける。

### 2.8 版上げ（ダッシュボードのフェーズ 2 までのつなぎ）

`fge new` で作ったゲームの `make engine-upgrade`（`make -C $(ENGINE) upgrade-game`・mk/game.mk:166-167）は、ENGINE が flix.toml の版の engine を
指すので、そのままでは自分と同じ版へ上げるだけになる。フェーズ 2（plans/dashboard.md 14 節）で中身を替えるまでのつなぎ:

```sh
fge engines install 0.109.0
make engine-upgrade ENGINE=~/.flix_ge/engines/0.109.0
```

- 上げた後は flix.toml が 0.109.0 になり、2.5 の既定で ENGINE も 0.109.0 を指す（local.mk を書き換えない）。
- この 2 行を `make status` の「engine 版ズレ」の行と、AGENTS.core.md の早見表の `engine-upgrade` の行に、配った engine の時だけ出す。

## 3. 確かめ方

- `go/internal/onboarding`（仮）のテスト: OS と CPU の名前の対応・SHA256 の照合・`mk/jdk.mk` の読み方・JDK の開き方（macOS の Contents/Home を外す）・
  テンプレート一覧。外へ取りに行く所は、fetchengine のテストと同じく httptest のサーバーで置き換える。
- テンプレートの Makefile の既定（2.5）: engine の中では `../..`、外では flix.toml の版、が出ることを make の素振り（`make -pn`）で見る。
- `make check-docs-sync` に足す: devbox.lock の jdk と `mk/jdk.mk` の配り元・版が同じか。
- 通しの確かめ（手で 1 回・リリースの前）: 空の HOME で install.sh → `fge new` → `make run`、続けて 2.8 の版上げが macOS と Linux で通る。
  macOS は入っている make（3.81）で流す（engine の CI は devbox の gnumake なので、ずれに気づけない）。
  CI に入れるのは Linux の `fge new` まで（画面を開かない check と test）。
- 新しい仕組みなので、agents-pack/AGENTS.core.md の早見表に 1 行（「新しいゲームを作る・engine の版を手元に取る → `fge new`・`fge engines install`」）と、
  agents-pack/agent-eval/engine.json にお題を 1 本。

## 4. 後に回す物

- 版上げの本番の形（Inbox のカードから Claude に頼む）: plans/dashboard.md の 14 節。
- Homebrew・winget・Windows（make を要らなくする計画の後）。
- GitHub Pages のデモと、README の「インストールせずに遊ぶ」。

## 5. 決めていないこと

1. 作る先の既定: 今のフォルダの下（`./<名前>`）でよいか。plans/dashboard.md 13 節のワークスペースは、`fge add` で後から一覧に足す。
2. ffmpeg（Tape と動画を撮る時だけ要る）を fge が取るか、要る時に入れ方を出すだけにするか。案は後者。

## 6. 作る物の一覧（実装の順）

| # | 所 | 物 |
|---|---|---|
| 1 | engine の Makefile・stage-engine | bundle-zip に natives・`mk/jdk.mk`・Release に `fge-<os>-<arch>`・`fge-SHA256SUMS.txt`・install.sh |
| 2 | go/internal/fetchengine | `--standalone` |
| 3 | go（新しいパッケージ） | `fge new`・`fge engines [install]`・`fge self-update`・JDK を取って開く |
| 4 | templates/*/Makefile・mk/game.mk | ENGINE の既定（2.5）・engine が無い時の案内・JAVA を決める |
| 5 | Makefile の new-game・bin/flix | IS_BUNDLE の時の local.mk・案内・雑音・文字化け |
| 6 | agents-pack・check-docs-sync・agent-eval | 早見表の行・上書きの 1 行・jdk の比べ・お題 |
| 7 | README | 始め方を install.sh に。Studio は凍結中と 1 行 |

## 7. スパイクの記録（2026-11-23・Linux のコンテナ）

Release の zip を手で開いた engine（fetchengine は 2.7 のとおり止まるので手で開いた）と、JDK 25.0.3（Zulu の代わりに同じ版の Temurin。
この環境は Azul にも Adoptium の API にも届かなかった）で流した。

| 確かめたこと | 結果 |
|---|---|
| v0.108.0 の zip を取って SHA256SUMS で照合 | 通った（10 秒） |
| fetchengine で取る（`--carry-from` 無し） | **止まった**（「bin/flix は持ち越す物ですが、写す元を教わっていません」） |
| 配った engine（IS_BUNDLE）で `make new-game … JAVA=<JDK>` | **通った**（2 分 41 秒。check → test → render-all まで）。`JAVA=` は子の make に届いた |
| LWJGL の natives | 作るたびに Maven Central から取った |
| 雑音 | `fatal: not a git repository`・`cd: can't cd to go`・ログの日本語が `??????`。止まりはしない |
| v0.107.0 で作ったゲームを v0.108.0 の engine で `make upgrade-game` | **通った**（31 秒・check 緑）。skills・AGENTS.md・agent-eval・bin/fge-go・flix.toml・packages.lock が新しい版になった |
| 版上げの後の local.mk | **ENGINE は 0.107 のまま**。`make status` が「pack 古い（AGENTS.md は 0.108・engine は 0.107）→ engine 側で make sync-agents を再実行」と出し、その通りにすると skills が 0.107 に**戻る** |

## 8. レビューとスパイクへの答え

| 指摘・見つけた事 | 答え |
|---|---|
| （第 1 版）fetchengine は `--carry-from` 無しでは止まる・`/jre/` の検査 | 2.7 の 1 に `--standalone` |
| （第 1 版）local.mk の `JAVA =` は bin/flix に届かない | 2.5 で game.mk が `export JAVA :=` |
| （第 1 版）LWJGL の natives が zip に無い | 2.3 |
| （第 1 版）devbox の JDK は Zulu | 2.4 |
| （第 1 版）公開は release-publish・名前は bin/dist/fge-go-*・install.sh に版を埋める | 2.3 |
| （第 1 版）macOS の make 3.81・全体の fge の見分け | 3 節・2.6 |
| （第 2 版）置き場のパス `engines/<版>/engine` と `engines/<版>/` の食い違い | 2.1 で `engines/<版>/` にそろえた |
| （第 2 版）local.mk は worktree と別の機械に無い | 2.5 で git に入っている Makefile の既定で決める |
| （第 2 版）flix.toml の版の engine・JDK が手元に無い時 | 2.5 で `fge engines install <版>` を案内して止める・JDK が無ければ PATH の java へ移らず止める |
| （第 2 版）フェーズ 2 までの間、fge new で作った人は版を上げられない | 2.8 のつなぎ |
| （第 2 版）natives の出どころと大きさ | 2.3（render_gl/lib/external の natives と fge-gl・約 13 MB） |
| （第 2 版）JAVA を jdk.json から決める中身・macOS のパス | 2.4 で `mk/jdk.mk` に替えた・2.1 で `<dir>/bin/java` にそろえる |
| （第 2 版）文字化けへの答え・節の順 | 2.7 の末尾・節を並べ直した |
| （スパイク）Adoptium・Azul がネットワークで止まりうる | `FGE_JDK_URL` で差し替えられる |
| （スパイク）版上げの後に古い engine を読み続ける | 2.5 |
