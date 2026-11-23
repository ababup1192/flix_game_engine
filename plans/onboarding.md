# 始め方（install.sh とワークスペースのダッシュボード）

状態: 設計 第 5 版。**レビュー 91 点で実装に入る**（2026-11-23）。ダッシュボードの残り（plans/dashboard.md）より先に作る（2026-11-23 の作者の判断）。
初回なのでレビューは 90 点以上で実装に入る（作者の判断）。第 1 版 60 点・第 2 版 80 点・第 3 版 72 点（新しいレビュー役）・第 4 版 84 点・第 5 版 91 点。答えは 9 節。実装しながら決める物は 10 節。

## 0. 決まっていること

- **最初は小さく。** 「触ってもらう」課題に直接つながる最小の形だけを作る。
- **人が打つのは 2 つだけ。** install.sh の 1 行と `fge dashboard`。ゲームを作るのは、ダッシュボードのカードから開いた Claude（2026-11-23 の作者の判断）。
  `fge new`・`make new-game` は Claude が打つ物で、人向けの案内には出さない。
- **入れる物は 1 本のバイナリだけ。** npm・devbox・engine の clone を利用者に要らせない。Claude Code は別に入れてもらう。
- **対象は macOS と Linux。** Windows は、ゲームの make（make・bash・perl）を要らなくする計画が終わるまで対象外。
- **engine を clone して直す人（作者）の手元の動きは変えない。** 新しい道は、配った engine（engine の下に `go/` が無い・Makefile:53 の IS_BUNDLE と同じ見方）の時だけ通る。

## 1. 今の始め方と、詰まる所

| 手 | 今 | 詰まる所 |
|---|---|---|
| 道具を入れる | devbox（jdk・flix・go・ffmpeg を nix で取る） | nix の初回は数 GB。README は Go と ffmpeg に触れていない |
| engine を手元に置く | `git clone` して `make sync` | Maven から取るので初回が長い。中断すると lock が残る |
| bin/fge を作る | `make go-build`（README に無い） | 無いと `make new-game` が「bin/fge-go がありません」で止まる |
| ゲームを作る | `make new-game GAME=/abs/path NAME=x` | GAME は絶対パス必須。engine の作業ツリーがきれいで main に入っている必要がある |
| 次に何をするか | make help の約 30 行 | 人が読む入り方が無い。Claude に何を頼めばよいか分からない |

## 2. 新しい始め方

```sh
curl -fsSL https://github.com/ababup1192/flix_game_engine/releases/latest/download/install.sh | sh
fge dashboard                  # ブラウザで http://127.0.0.1:8790/ が開く
```

```
ワークスペースの頁（/）
 ┌ 新しいゲームを作ってみよう
 │  名前 [ tidepool ]   テンプレート（reference/title.png の絵つきのカード）
 │  [Claude Code で開く] [コピー]
 └─ 下書き:「tidepool という名前で、rpg-starter から新しいゲームを作って。できたら make run で動くか確かめて、次にやることを教えて」
                    ↓ Claude はワークスペースのフォルダ（~/flix-games）で起動し、そこの AGENTS.md を読む
Claude      fge new tidepool --template rpg-starter → 結果を報告
                    ↓
ワークスペースの頁   ゲームの一覧に tidepool が出る（[Claude Code で開く]・`make run` のコピー）
```

### 2.1 置き場

```
~/.flix_ge/                     （FGE_HOME で替えられる）
  bin/fge                       全体の fge（install.sh が置く）
  engines/<版>/                 engine の zip を開いた物（fetchengine が zip の一番上の engine/ フォルダを外して開く・fetchengine.go:420-429）。開いた後は読み取り専用
    .complete                   開き終えたマーカー（無ければ半端な物として取り直す）
  jdk/<配り元>-<版>/bin/java     JDK。macOS の `Contents/Home` は開く時に外し、どの OS でも `<dir>/bin/java` にそろえる。.complete も同じ
  latest.json                   Release の最新の版の控え（{version, checkedAt}・1 日 1 回まで問い合わせる）
  workspace.json                ゲームの一覧（{name, dir}）
  .lock                         engines と jdk を書く間の排他（flock）
~/flix-games/                   ワークスペースのフォルダ（既定・`fge dashboard --dir` で替えられる）
  AGENTS.md  CLAUDE.md          Claude 向けの案内（2.6）
  <ゲーム>/                     fge new が作る
```

### 2.2 install.sh（Release に添える・約 60 行の sh）

1. `uname -s` と `uname -m` から `darwin|linux` × `amd64|arm64` を決める（それ以外は止める）。
2. 同じ Release の `fge-<os>-<arch>` と `fge-SHA256SUMS.txt` を curl で取り、照合する（`shasum -a 256` か `sha256sum`）。
3. `~/.flix_ge/bin/fge` に置く。PATH に無ければ、足す 1 行を出す（シェルの設定ファイルは書き換えない）。最後に「次: `fge dashboard`」と、
   Claude Code が無ければその入れ方の 1 行。
- WhyNot raw.githubusercontent の main の install.sh: 版が付かない。Release に添えれば install.sh と fge の版がそろう。
- WhyNot シェルの設定を書き換える: 利用者の dotfiles を勝手に触らない（rustup と同じく案内だけ）。

### 2.3 Release に足す物（Makefile の `release-publish` の `gh release create`・:1127-1131 と `bundle-zip`・:1169-1181）

- `fge-<os>-<arch>`: `go-build` が作る `bin/dist/fge-go-<os>-<arch>` のうち darwin と linux の 4 本を `fge-` の名前で添える。と、その `fge-SHA256SUMS.txt`。
  WhyNot 今の `SHA256SUMS.txt` に足す: 凍結した Studio の self-update がこの 1 行を読む。形を替えず、別のファイルにする。
- `install.sh`: 添える時に版を埋める（`FGE_VERSION=<版>` の 1 行）。latest の URL から取った install.sh が、同じ Release の fge を取る。
- **engine の zip に LWJGL の natives を入れる。** stage-engine.json に `@natives`（owner は engine・zip に入る物）を新しく足し、bundle-zip が
  `render_gl/lib/external/` のうち `lwjgl-*-natives-*.jar` と `fge-gl-*.jar` だけを `lib/external/` に入れる。全部の機種の分で約 13 MB（スパイクの実測）。
  - WhyNot 今の `@maven-seed/external` を使う: owner が studio で、「zip に入れず、今の engine から写して持ち越す」扱い（fetchengine の carryOver）。
  - WhyNot natives を入れない: new-game は natives を `render_gl/lib/external` から写す（Makefile:1622-1626）が zip にはそれが無く、
    作るたびに Maven Central へ取りに行き、続けて作ると 429 で止まる（スパイクで取りに行くのを確かめた）。
- `agents-pack/workspace/`（2.6 のワークスペースの案内）は agents-pack ごと zip に入る（stage-engine.json に `agents-pack` がある）。

### 2.4 JDK を engine の版ごとに 1 つ固定する: `mk/jdk.mk`（新しく足す・engine の zip に入る）

```make
FGE_JDK_VENDOR  := zulu
FGE_JDK_VERSION := 25.0.3
```

- **配った engine で使う JDK は、OS によらずこの 1 つ。** 取り先は Azul の API（api.azul.com）と配布サーバー（cdn.azul.com）、照合は API が返す sha256。
  取り先は `FGE_JDK_URL` で差し替えられる（Azul に届かない所のため）。
- 固定する理由: 同じ人の手元で、JDK を入れ替えるたびにフォントの計測がずれて絵が変わらないようにする（bin/flix:46-49）。
  リファレンス画像はその人の手元で作るので、そろえる相手は「その人の過去の自分」。版を上げる時に JDK も一緒に上がる。
- WhyNot devbox とそろえる: devbox の JDK は OS ごとに違う（devbox.lock: aarch64-darwin は Zulu 25.0.3・Linux は nixpkgs の OpenJDK 25.0.5）。
  配った engine は devbox を使わないので、作者の手元とはそろわない。`make check-docs-sync` は主な版（25）が同じことだけを見る。
- WhyNot JSON: make と bin/java-resolve.sh（sh）と fge（Go）が読む。`KEY := 値` の 2 行なら 3 つとも読める。

### 2.5 engine と JDK を見つける（make の道と、make を通らない道を同じ決まりで）

**決まり（1 つ）**: ゲームのフォルダ `G` の engine は、
1. 環境変数 `ENGINE` → 2. `G/local.mk` の `ENGINE` →
3. `G/../../mk/game.mk` と `G/../../templates/` があれば `G/../..`（engine の中のテンプレート）→
4. `$(FGE_HOME または ~/.flix_ge)/engines/<G/flix.toml の flix_game_engine の版>`。

この決まりを 3 か所に置き、どれも同じ答えを出す:

| 所 | 中身 |
|---|---|
| テンプレートの Makefile の既定（6 つ同じ形・game-starter/Makefile:11-13 と :27-29） | 下の make の行 |
| Go: `go/internal/status/engine.go` に `ResolveEngineDir(G) (dir string, self bool)` を 1 本置く | 決まりの 1〜4 と、G 自身が engine の時の self 判定。**ReadEngineDir（:24-39）はこれに置き換える。FindEngineDir（:56-63）は消さず、ResolveEngineDir の答えに marker の有る無しを見る薄い包みにする**（talk は `bin/headless-run`、docshape は EngineMarker を marker にし、無い候補を飛ばす動きを持つ。docrefs.go:337 と makefiledup は self を使う）。呼び手: status・refactorhost・makefiledup・docshape・docrefs・talk・useengine.go:288・cmd_refactor.go:158 の engineDirOf・checkd/client.go:35-45 |
| テスト | 決まりの 4 通りで、make の素振り（`make -pn` の ENGINE）と Go の答えが同じことを見る |

```make
-include local.mk
FGE_VERSION := $(shell sed -n 's/^"github:ababup1192\/flix_game_engine"[^}]*version *= *"\([0-9.]*\)".*/\1/p' flix.toml)
ENGINE ?= $(if $(and $(wildcard ../../mk/game.mk),$(wildcard ../../templates)),../..,$(or $(FGE_HOME),$(HOME)/.flix_ge)/engines/$(FGE_VERSION))
```

- 枝を替えても、worktree でも、ゲームを clone した別の機械でも、git に入っている Makefile と flix.toml だけで決まる。
  WhyNot local.mk に固定のパスを書く: local.mk は git の外なので、版を上げた後も古い engine を読み続ける（8 節のスパイク）。worktree と別の機械には無い。
- `fge new` は ENGINE を local.mk に書かない（new-game は IS_BUNDLE の時は `ENGINE ?=` の行を書かない）。local.mk は engine を clone して直す人が上書きに使う。
- 版が読めなかったら（`FGE_VERSION` が空）make は止める。Go は止めずに空を返す（engine リポの中の engine/ などは flix.toml に依存の行を持たず、そこで道具を止めない）。engine が無い時の `$(error …)` は、4 の時は「engine <版> が手元にありません → `fge engines install <版>`」にする。
- `FGE_HOME` を既定から替えた人は、シェルで export しておく（make も Go も環境から読む）。install.sh がその 1 行も出す。

**JDK（make を通らない道でも同じになるように、java を探す所そのものに入れる）**:

| 所 | 足す決まり |
|---|---|
| bin/java-resolve.sh（:42-45） | engine に `go/` が無く `mk/jdk.mk` がある時は、`JAVA` が無ければ `~/.flix_ge/jdk/<配り元>-<版>/bin/java` だけを使う。**無ければ止めて**「`fge engines install <版>`」と出す（PATH の java へ移らない） |
| bin/headless-run（:486-490） | `fge_resolve_java` が失敗しても `${JAVA:-java}` で先へ進む作りを、配った engine の時は exit にする |
| go/internal/javacmd（Resolve・:33-48） | 同じ決まり。引数は **engine の場所**（ゲームの根でない）。「どれも無ければ "java"」をやめて error を返す |
| javacmd の呼び手 | checkd/resident.go:290 の `javaCmd(root)` は root がゲームの根（ゲームの bin/ に写した fge-go が動く）なので、先に ResolveEngineDir で engine を引いて渡す |
| `PathWorks()` の 2 か所（cmd_flixlint.go:35・cmd_refactor.go:148） | PATH の java が動くかだけを見て、devbox の jdk しか前に足さない（:167）抜け道。Resolve を通す形に替える（pre-commit の lint-flixlint・checkd の常駐・`bin/fge refactor` が通る道） |
| bin/flix（:62-72） | 配った engine では、隣の `bin/flix.jar` を nix の flix より先に使う |

- これで make（mk/game.mk）・Stop hook の checkd・git の pre-commit・Go の道具が同じ JDK を使う。mk/game.mk に JAVA の分岐は足さない。
- WhyNot 無い時に PATH の java へ移る: 何も言わずに別の JDK で描き、絵がずれる原因そのもの。
- `JAVA` を人が名指しした時はそれを使う（名指しは人の判断）。

### 2.6 ワークスペースのダッシュボード（`fge dashboard`・この計画で作るのは `/` の頁だけ）

- `fge dashboard` は、今のフォルダに flix.toml があればそのゲームの頁（plans/dashboard.md のフェーズ 1）、無ければワークスペースの頁を前面で立てる。
  この計画で作るのはワークスペースの頁だけ。ポートは 8790（塞がっていれば空いた番号）。安全の決まりは plans/dashboard.md の 6 節と同じ。
- 初めて立てた時: `~/flix-games/` を作り、最新の engine の `agents-pack/workspace/AGENTS.md` を写し、`CLAUDE.md` を `@AGENTS.md` の 1 行で置く
  （ゲームと同じ形）。engine が 1 つも無ければ先に `fge engines install <最新>` を流す（進み具合を頁に出す）。
- 頁の中身:
  - **新しいゲームを作ってみよう**のカード: 名前の欄・テンプレートの絵つきのカード（engine の `templates/*/reference/title.png` と README の頭）・
    `[Claude Code で開く]`（`claude-cli://open?cwd=<ワークスペース>&q=<下書き>`）・`[コピー]`。下書きは 2 節の文。
  - **ゲームの一覧**（workspace.json）: 名前・engine の版・`[Claude Code で開く]`（cwd はゲーム）・`make run` のコピー。
  - Claude Code の案内: deep link は一度 `claude` を起動して何か送った後でないと開けない（plans/dashboard.md 15.1）ので、カードの横にいつも
    「開かない時: 一度 claude を起動して何か送る」と、Claude Code が無い時の入れ方の 1 行。
  - 新しい版のお知らせ（latest.json が手元の最新より新しい時）: 「engine 0.109.0 が出ています」と、`fge engines install 0.109.0` のコピー。
- **ワークスペースの AGENTS.md の写し直し**: `fge dashboard` が立つたびに、手元の最新の engine の物と中身を比べ、違えば写し直す（人が書き足す欄は無い。
  人の方針はゲームの AGENTS.local.md に書く）。
- **ワークスペースの AGENTS.md（`agents-pack/workspace/AGENTS.md`・30 行ほど）**: 「ゲームを作る → `fge new <名前> [--template <名>]`、
  テンプレートの一覧 → `fge new --list`、作ったら一覧に出る（fge new が workspace.json に足す）、作った後はそのゲームのフォルダで作業する
  （ゲームの AGENTS.md に従う）」。fge は PATH に無いこともあるので `~/.flix_ge/bin/fge` の絶対パスでも書く。
  engine から配るので、engine の版に合う書き方になる（fge に文を埋め込まない）。要件:
  - **`fge new` は長い**（スパイクで new-game だけで 2 分 41 秒・初回は engine と JDK の約 300 MB も取る）。Claude の Bash の既定の時間切れ（2 分）に当たるので、
    「`fge new` は timeout を 600000 にするか、background で流して終わりを待つ」と書く。fge new は進み具合を 1 行ずつ出す。agent-eval のお題もこの形で当てる。
  - **作り終えたら作業を止める。** ワークスペースで起動した Claude には、ゲームの .claude/settings.json の hooks とゲームの skills が読まれない
    （起動したフォルダの物だけを読む）。作り終えたら「ダッシュボードのゲームのカードの [Claude Code で開く] から開き直してください」と人に言って止まる。

### 2.7 全体の fge のサブコマンド

`new`・`engines`・`self-update` は、どこから打っても同じに動く（engine やゲームの中の文脈を読まない）。ゲームの中の作業はそのゲームの `bin/fge`。

| コマンド | 打つ人 | すること |
|---|---|---|
| `fge dashboard` | 人 | 2.6 |
| `fge new <フォルダ名> [--template <名>] [--name <パッケージ名>] [--title <題>] [--engine <版>]` | Claude | 2.8 |
| `fge new --list` | Claude | テンプレートの名前・題・README の頭 |
| `fge engines` | Claude・人 | 手元の版と最新の版（latest.json を新しくする） |
| `fge engines install <版>` / `remove <版>` | Claude・人 | engine の zip と、その版の `mk/jdk.mk` が指す JDK を取る（あれば何もしない）/ 消す（使っているゲームが workspace.json にあれば止める） |
| `fge self-update` | 人 | install.sh と同じ手順で fge を差し替える |

- WhyNot 全体の fge でゲームの作業もする: ゲームごとに engine の版が違う。古い版のゲームを新しい道具で触ると、Studio の追従の失敗が戻る。

### 2.8 fge new の中身

1. **engine と JDK を取る**: `fge engines install <版>`（版は既定で手元の最新、無ければ Release の最新）。
   - **fetchengine に「単体で入れる」形（`--standalone`）を足す。** 今は Studio 向けで、`bin/flix` を Studio から持ち越す前提
     （stage-engine.json で `@flix-wrapper` が `owner: studio`・fetchengine.go:433-447）と、`bin/flix` に `/jre/` の字がある検査（:483-489）がある。
     standalone はこの 2 つを飛ばし、zip の `bin/flix`（リポの bin/flix と同じ・Makefile:1150）をそのまま使う。fge-go を選び直す所（pickFgeGo）はそのまま。
   - **排他と半端な物**: `~/.flix_ge/.lock` を取ってから書く（同時に 2 つの fge new・dashboard からの取得）。一時フォルダに開き、`.complete` を置いてから
     rename する。今の fetchengine は `RemoveAll(dest)` の後に Rename する（:304-307）ので、standalone では既にある `<版>/` を消さない
     （`.complete` があれば何もしない・無ければ一時フォルダに取り直してから入れ替える）。JDK も同じ。
   - 開いた後は読み取り専用（chmod a-w）。AI がその版の engine を直すと、同じ版の全部のゲームが変わってしまうため。
     `fge engines remove` は書けるように戻してから消す。new-game と upgrade-game が engine の中に書かないことは 8 節のスパイクで確かめた。
   - ディスク: 1 版で約 300 MB（zip 117 MB を開いた物と JDK）。足りない時は「`fge engines remove <使っていない版>`」を出す。
2. **前提を確かめる**: make・perl・git が PATH にあるか。無ければ OS ごとの入れ方（macOS は `xcode-select --install`）を出して止める。
3. **名前**: `<フォルダ名>` は `-` を許す。パッケージ名（new-game の NAME・英小文字はじまり・`[a-z0-9_]`）は `--name` か、フォルダ名の `-` を `_` に替えた物。
   それでも決まりに合わなければ、理由と `--name` の例を出して止める。
4. **作る**: `make -C <engine> new-game GAME=<今のフォルダ>/<フォルダ名> NAME=<パッケージ名> TEMPLATE=<名> TITLE=<題>`。
   配った engine は IS_BUNDLE になり、engine の作業ツリーの検査（engine-full-fresh）を飛ばす（Makefile:1540-1543）。JAVA は 2.5 の java-resolve が決める。
5. workspace.json に足す。最後に「次にやること」を出す（`cd <名前> && make run`・`make debug`）と、
   「配られた skills・rules・AGENTS.md の共通部は版上げで上書きされる。ゲーム用に変えたい時は AGENTS.local.md に書くか、別の名前のスキルを足す」の 1 行。
   同じ 1 行を agents-pack/AGENTS.core.md の頭にも足す。

- new-game の直し（IS_BUNDLE の時だけ）: 最後の案内の「Studio で開く」を消す。`fatal: not a git repository`・`cd: can't cd to go` を出さない（スパイクで出た）。
- ログの日本語が `??????` になる（スパイク。ロケールの無い所で java が標準出力を ASCII で書く）: bin/flix が java に `-Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8` を付ける。

### 2.9 新しい版のお知らせと、版上げ（ダッシュボードのフェーズ 2 までのつなぎ）

- **お知らせ**: `fge engines` と `fge dashboard` が 1 日 1 回まで Release の最新を問い合わせ、`~/.flix_ge/latest.json` に置く。
  ゲームの `make status` は、flix.toml の版より latest.json の版が新しい時に「engine 0.109.0 が出ています → make engine-upgrade TO=0.109.0」を出す。
  WhyNot 今の「engine 版ズレ」の行（status.go:452-466）を使う: ENGINE が flix.toml の版から決まるので、engine とゲームの版は常に同じになり、二度と出ない。
- **版上げ**: mk/game.mk の `engine-upgrade` に `TO=<版>` を足す。配った engine で TO がある時は
  `bin/fge engines install $(TO)` → `make -C $(or $(FGE_HOME),$(HOME)/.flix_ge)/engines/$(TO) upgrade-game GAME=$(CURDIR)`。
  ゲームの `bin/fge` は全体の fge と同じ fge-go（版はゲームの engine の版）なので、`engines install` をそのまま持つ（2.7 のとおり文脈を読まないコマンド）。
  ゲームの engine の版が `engines install` を持つより古い時は、全体の `~/.flix_ge/bin/fge` を呼ぶ。上げた後は flix.toml が新しい版になり、2.5 の決まりで ENGINE も新しい版を指す。
  clone した engine の時は今のまま（`make -C $(ENGINE) upgrade-game`）。
  - WhyNot `ENGINE=~/.flix_ge/...` を案内する: zsh（macOS の既定）は `=` の後の `~` を展開しない。`TO=<版>` なら人も Claude も打ち間違えない。
- 本番の形（ダッシュボードの Inbox のカードから Claude に頼む）は plans/dashboard.md 14 節。中身は同じ `make engine-upgrade TO=<版>`。

## 3. 確かめ方

- Go のテスト（新しいパッケージと既存の直し）: OS と CPU の名前の対応・SHA256 の照合・`mk/jdk.mk` の読み方・JDK の開き方（macOS の Contents/Home）・
  ResolveEngineDir の 4 通り（と make の素振りとの一致）・排他と `.complete`・名前の変換・テンプレート一覧。外へ取りに行く所は httptest で置き換える。
- java-resolve.sh: 配った engine で JDK が無い時に止まる・ある時はそれを使う・JAVA の名指しが勝つ、をシェルのテストで見る。
- `make check-docs-sync` に足す: `mk/jdk.mk` の主な版と devbox の jdk の主な版が同じか。テンプレート 6 つの ENGINE の既定の行が同じ形か。
- 通しの確かめ（手で 1 回・リリースの前）: 空の HOME で install.sh → `fge dashboard` → カードの下書きで Claude が `fge new` → `make run`、
  続けて `make engine-upgrade TO=<次の版>` が macOS と Linux で通る。macOS は入っている make（3.81）で流す。
  CI に入れるのは Linux の `fge new`（画面を開かない check と test）まで。
- 新しい仕組みなので、agents-pack/AGENTS.core.md の早見表に 1 行（「engine の新しい版に上げる → `make engine-upgrade TO=<版>`」）、
  ワークスペースの AGENTS.md に fge new の行、agent-eval にお題を 2 本（ワークスペースで「〇〇という名前でゲームを作って」・ゲームで「engine を最新に上げて」）。

## 4. 後に回す物

- ゲームの頁（Inbox・Tape・post / inbox）: plans/dashboard.md のフェーズ 1。ワークスペースからゲームの頁への中継は、ゲームの頁ができてから。
- 版上げの本番の形（Inbox のカードから Claude に頼む）: plans/dashboard.md の 14 節。
- Homebrew・winget・Windows（make を要らなくする計画の後）。GitHub Pages のデモと、README の「インストールせずに遊ぶ」。

## 5. 決めていないこと

1. ffmpeg（Tape と動画を撮る時だけ要る）を fge が取るか、要る時に入れ方を出すだけにするか。案は後者。

## 6. 作る物の一覧（実装の順）

| # | 所 | 物 |
|---|---|---|
| 1 | Makefile（bundle-zip・release-publish）・stage-engine.json | `@natives`・`mk/jdk.mk`・Release に `fge-<os>-<arch>`・`fge-SHA256SUMS.txt`・版を埋めた install.sh |
| 2 | go/internal/fetchengine | `--standalone`・排他・`.complete`・読み取り専用 |
| 3 | go（新しいパッケージ） | `fge engines [install/remove]`・JDK を取って開く・`fge new [--list]`・`fge self-update`・latest.json・workspace.json |
| 4 | go/internal/status/engine.go と使う所・checkd/client.go | `ResolveEngineDir`・status の「新しい版」の行 |
| 5 | bin/java-resolve.sh・go/internal/javacmd・bin/flix | 配った engine の JDK の決まり・flix.jar の順・文字化け |
| 6 | templates/*/Makefile（6 つ）・mk/game.mk | ENGINE の既定・engine が無い時の案内・`engine-upgrade TO=` |
| 7 | Makefile の new-game | IS_BUNDLE の時の local.mk・案内・雑音 |
| 8 | go（ダッシュボード）・agents-pack/workspace/ | `fge dashboard` のワークスペースの頁（2.6）・ワークスペースの AGENTS.md |
| 9 | agents-pack・check-docs-sync・agent-eval | 早見表の行・上書きの 1 行・jdk とテンプレートの比べ・お題 2 本 |
| 10 | README | 始め方を install.sh と `fge dashboard` に。Studio は凍結中と 1 行 |

## 7. 手順の小さな決まり

- 2.5 の版を読む sed は Go の depRe（upgradegame.go:53）と同じ形（`[^}]*version`）にそろえる。
- bench/* は ENGINE を持たないので 2.5 の影響を受けない。既に産まれたゲームは Makefile を書き換えないので今のまま（local.mk の ENGINE で動く）。

## 8. スパイクの記録（2026-11-23・Linux のコンテナ）

Release の zip を手で開いた engine（fetchengine は止まるので手で開いた）と、JDK 25.0.3（Temurin。この環境は Azul にも Adoptium の API にも届かなかった）で流した。

| 確かめたこと | 結果 |
|---|---|
| v0.108.0 の zip を取って SHA256SUMS で照合 | 通った（10 秒） |
| fetchengine で取る（`--carry-from` 無し） | **止まった**（「bin/flix は持ち越す物ですが、写す元を教わっていません」） |
| 配った engine（IS_BUNDLE）で `make new-game … JAVA=<JDK>` | **通った**（2 分 41 秒。check → test → render-all まで）。`JAVA=` は子の make に届いた |
| LWJGL の natives | 作るたびに Maven Central から取った |
| 雑音 | `fatal: not a git repository`・`cd: can't cd to go`・ログの日本語が `??????`。止まりはしない |
| v0.107.0 で作ったゲームを v0.108.0 の engine で `make upgrade-game` | **通った**（31 秒・check 緑）。skills・AGENTS.md・agent-eval・bin/fge-go・flix.toml・packages.lock が新しい版になった |
| 版上げの後の local.mk | **ENGINE は 0.107 のまま**。`make status` が「pack 古い → engine 側で make sync-agents を再実行」と出し、その通りにすると skills が 0.107 に**戻る** |
| 読み取り専用の engine（chmod -R a-w の写し）で new-game と upgrade-game | **どちらも engine の中に何も書かなかった**（流した後に engine の下で更新時刻の新しいファイルを探して 0 件。new-game 1 分 48 秒・Maven の取り物は 2 回目なので速い）。コンテナが root なので chmod では止まらず、書いた物を探す形で確かめた |
| 2.5 の make の行（GNU make 4） | `~/.flix_ge/engines/0.108.0`・`FGE_HOME` の差し替え・engine の中のテンプレートの `../..` の 3 通りとも期待どおり |

## 9. レビューとスパイクへの答え

| 指摘・見つけた事 | 答え |
|---|---|
| （第 1 版）fetchengine は `--carry-from` 無しでは止まる・`/jre/` の検査 | 2.8 の 1 に `--standalone` |
| （第 1 版）local.mk の `JAVA =` は bin/flix に届かない | 2.5 で java を探す所そのものに入れた |
| （第 1 版）LWJGL の natives が zip に無い | 2.3 |
| （第 1 版）公開は release-publish・名前は bin/dist/fge-go-*・install.sh に版を埋める | 2.3 |
| （第 1 版）macOS の make 3.81・全体の fge の見分け | 3 節・2.7 |
| （第 2 版）置き場のパスの食い違い | 2.1 で `engines/<版>/` にそろえた |
| （第 2 版）local.mk は worktree と別の機械に無い | 2.5 で git に入っている Makefile の既定で決める |
| （第 2 版）engine・JDK が手元に無い時 | 2.5 で止めて `fge engines install <版>` を出す |
| （第 2 版）fge new で作った人は版を上げられない | 2.9 の `make engine-upgrade TO=` |
| （第 2 版）natives の出どころと大きさ・JAVA の決め方・macOS のパス・文字化け・節の順 | 2.3・2.4・2.1・2.8・並べ直した |
| （第 3 版）Go の道具は local.mk か環境変数の ENGINE しか見ない | 2.5 で決まりを 1 つにし、Go の `ResolveEngineDir` と make の既定を同じにする（テストで一致を見る） |
| （第 3 版）JAVA を game.mk で決めても make を通らない道には届かない・bin/flix が nix の flix を先に拾う | 2.5 で java-resolve.sh・javacmd・bin/flix に入れた |
| （第 3 版）Linux の devbox の JDK は OpenJDK 25.0.5 で Zulu ではない | 2.4 で「devbox とそろえる」をやめ、engine の版ごとに 1 つ固定。check-docs-sync は主な版だけ |
| （第 3 版）版上げの行が出る所が無い | 2.9 で latest.json と status の新しい行 |
| （第 3 版）zsh で `~` が展開されない | 2.9 で `TO=<版>` |
| （第 3 版）`@maven-seed/external` は owner: studio | 2.3 で `@natives` を新しく |
| （第 3 版）同時に 2 つの fge new・半端な物・RemoveAll | 2.8 の排他・`.complete`・既にある物を消さない |
| （第 3 版）sed の決め打ち・`../../mk/game.mk` だけの見分け・FGE_HOME・ディスク・`-` 入りの名前・engine を AI が直す | 7 節・2.5・2.8 |
| （作者）人は make new-game を打たない。ダッシュボードから Claude に作ってもらう | 0 節・2 節・2.6 |
| （第 4 版）javacmd.Resolve にゲームの根が渡る所がある・「無ければ java」 | 2.5 の表で engine を渡す・error を返す |
| （第 4 版）flixlint と refactor は PathWorks で Resolve を通らない | 2.5 の表に足した |
| （第 4 版）headless-run は java が見つからなくても進む | 2.5 の表に足した |
| （第 4 版）FindEngineDir の self と marker・呼び手の漏れ・版が読めない時の Go | 2.5 の表と本文 |
| （第 4 版）fge new が Claude の時間切れ（2 分）に当たる・ワークスペースの Claude にはゲームの hooks が読まれない | 2.6 のワークスペースの AGENTS.md の要件 |
| （第 4 版）`$(FGE_HOME)` が空・ゲームの bin/fge が engines install を持つか・AGENTS.md の写し直し・読み取り専用の engine の remove | 2.9・2.6・2.8 |

## 10. 実装しながら決める物（第 5 版のレビュー・91 点）

- PathWorks の 2 か所: flixlint は java のパスを渡せない（cmd_flixlint.go:34）ので、配った engine の時は Resolve が返した JDK の bin を
  いつも PATH の頭に足す。pathWithEngineJava（cmd_refactor.go:167・今は DevboxBin だけ）をこの形にする。
- 版を上げて JDK が替わった時、checkd とヘッドレスの常駐が古い java で残らないか。checkd は StopStaleResident の判断に java のパスを入れる。
  ヘッドレスは resident/client.go の WithJava の比べで拾えるかを確かめる。
- macOS の一般ユーザーで、読み取り専用の engine と一時ファイルで止まる所が無いかを、リリース前の手の確かめで 1 回見る（スパイクは root のコンテナ）。
- flix.toml の版の engine が手元に無い時、Go の道具は黙らず status に「engine <版> が手元にありません → fge engines install <版>」を 1 行出す。
- latest.json が取れない（オフライン・回数制限）時は止めずに続ける。古い控えはそのまま使う。テストで決める。
- 古い版の bin/fge-go で新しい版の zip を開く時の前方互換: zip の並びの約束（一番上の engine/ フォルダ）を変えない。`--standalone` の照合を増やす時は古い版でも通るか見る。
- ワークスペースの AGENTS.md は `fge engines install` の後にも写し直す。

## 11. 作者に確かめていない決め事（2026-11-23 に一覧にして作者に見せた）

作者の判断を待つ物（◎）と、既定として決めた物（○・変えやすい）。

| | 決め事 | 節 |
|---|---|---|
| ◎ | Windows は対象外（ネイティブ）。WSL2 は Linux と同じ道で動く見込み（deep link は Windows 側の claude を開く恐れがあり、コピーで代える） | 0 |
| ◎ | JDK は配り元 Zulu・版 25.0.3 を engine の版ごとに固定し、Azul から取る（devbox とはそろえない） | 2.4 |
| ◎ | Claude Code は fge が入れない（人が別に入れる）。deep link は一度 claude で何か送った後でないと開けない | 0・2.6 |
| ◎ | ワークスペースで開いた Claude はゲームを作ったら止まり、人にゲームのカードから開き直してもらう | 2.6 |
| ○ | 置き場 `~/.flix_ge`・ワークスペース `~/flix-games` | 2.1 |
| ○ | install.sh は Release に添える（Pages でない）。シェルの設定ファイルは書き換えず、足す行を出すだけ | 2.2 |
| ○ | Release に `fge-<os>-<arch>` と別の `fge-SHA256SUMS.txt`（今の SHA256SUMS.txt は Studio のために変えない） | 2.3 |
| ○ | engine の zip に natives（約 13 MB）を入れる | 2.3 |
| ○ | 取った engine は読み取り専用。消すのは `fge engines remove` | 2.8 |
| ○ | 新しい版の問い合わせは 1 日 1 回まで（latest.json） | 2.9 |
| ○ | 版上げは `make engine-upgrade TO=<版>`（今の名前を残す） | 2.9 |
| ○ | テンプレート 6 つの Makefile の ENGINE の既定を替える（既に産まれたゲームは触らない） | 2.5 |
| ○ | フォルダ名の `-` はパッケージ名で `_` に替える | 2.8 |
| ○ | ffmpeg は fge が取らない（要る時に入れ方を出す） | 5 |
| ○ | JAVA を人が名指しした時はそれが勝つ | 2.5 |
