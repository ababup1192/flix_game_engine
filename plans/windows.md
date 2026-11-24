# Windows 対応（準備のフェーズ）

状態: 第 3 版。**5 節の #1〜#12 と 4 節・11 節・12 節を実装して作業枝に取り込んだ**（2026-11-23）。#8（flixlint の起動）は担当に渡し漏れ、取り込み後に足した。
Windows の上での確かめ（9 節の CI）はまだ。Linux の上で make を罠にした通し（install → fge new → check・test・lint・render-all）は make を 1 回も呼ばずに通った（14 節）。plans/onboarding.md（始め方）を macOS と Linux で通した後に、同じ始め方を Windows に載せるための準備。
レビューは 80 点以上でクリティカルな指摘が無ければ実装に入る（作者の判断）。第 1 版 66 点・第 2 版 76 点・第 3 版 84 点。答えは 10 節。

## 0. 決まっていること

- **Windows は必須**（2026-11-23）。対象は Windows のネイティブ。WSL は Linux と同じ道なので別に扱わない。
- **Git for Windows を前提にする**（2026-11-23・作者がおすすめを選んだ）。ゲームを作る（git init）・版を上げる（枝を切る）ので git はどのみち要り、
  Windows の git は Git for Windows で、bash・sh・perl・sed・sha256sum が付いてくる（make は付いてこない）。
  - Claude Code は Git Bash があればそれを Bash ツールと hooks に使う（code.claude.com の setup・hooks）。**hooks・AI が打つコマンド・engine の sh のスクリプトは Git Bash の上で動かす。**
  - WhyNot bash を一切使わない形（第 1 版）: hooks の 1 本の命令を bash と PowerShell の両方で動かす仕掛けと、bin/headless-run（540 行）を Go へ移す量が要る。
    git のために入る bash を使えば、作者 1 人が保守する量が小さく済む。
- **ゲームを作る人に make を入れさせない。** make を通っていた作業を Go の `bin/fge` に移す。make は macOS と Linux の人のための薄い別名として残す。
- **凍結した Studio は新しい版の engine に更新しない**（2026-11-23）。Studio の同梱 engine も go/ を持たないので、mk/jdk.mk を持つ新しい版に更新すると、
  bin/headless-run が `~/.flix_ge/jdk` を探して止まりうる（onboarding の担当の報告）。凍結を解く時に Studio が JAVA を渡す形にする。
- engine を直す人（作者・devbox）の手元は今のまま（macOS と Linux）。

## 1. 前提（公式の文書で確かめた事・2026-11-23）

| 事 | 出典 |
|---|---|
| Windows の Claude Code は Git Bash を必須にしない。あれば Bash ツールと hooks に使う（場所は `CLAUDE_CODE_GIT_BASH_PATH` で指定できる）。無ければ PowerShell | code.claude.com の setup・hooks |
| deep link（`claude-cli://open`）は Windows でも使える。開く端末は Windows Terminal → PowerShell → cmd の順 | deep-links |
| Claude Desktop は Windows で PowerShell のプロファイルを読まない。PATH はユーザーの環境変数で通す | desktop |

## 2. 今の Windows の道と、止まる所（2026-11-23 の棚卸しとレビュー）

- mk/game.mk:41-53 は Windows で JAVA と bin/flix.jar を直に使い、`CHECKD=0`・`FGE_NO_BASH=1`。make と sh が前提。
- ゲームの make のターゲットは約 30。run・debug・render・flow は bin/headless-run（bash）に頼る。
- **ゲームの Makefile そのものが設定になっている**: `PALETTE`・`PALETTE_DEPS`・`SHOTS`（render-all が先に作る物）・ゲームが足す lint（sound-novel の `lint: lint-cast`）・
  pre-commit が呼ぶ `precommit-local`・ゲーム固有のターゲット（rpg の `make bot`・`make balance`。rpg の AGENTS.local.md:92,132 で AI に案内している）。
- engine の Makefile の new-game は cp -R・find・perl -pi・sed・git・mvn-cache-share.sh。upgrade-game の中身は Go だが、先に流す engine-full-fresh は sh で、
  中で `make check` と `make -n` を起こす（upgradegame.go:547,557）。
- **Go が中で make を起こす所**: precommit（precommit.go:298,318,360。make が無いと何も言わずに通す）・flow/run.go:95・compare・useengine・upgradegame。
- **Go が人と AI に make を案内する所**: status・hooks・explain-error の出力（`make test`・`make engine-upgrade` など）と bin/lint-rules の 10 ファイル。
- AI が最初に打つ道具: `make api`・`make module`（AGENTS.core.md:20・awk と sed）・`make src`・`bin/fge refactor`（cmd_refactor.go:231,241,244 が `sh -c`）・talk（talk.go:292 が headless-run を直に起こす）。
- `.gitattributes` が無いので、Windows の autocrlf で sh と Makefile が CRLF になりうる。

## 3. 方針

1. **make を通っていた作業を Go のサブコマンドにする。make はその上の薄い別名。** macOS と Linux は今までどおり `make run`。中身は `bin/fge run`。
   Windows は `bin/fge run`（Git Bash でも PowerShell でも打てる。PowerShell では `bin\fge.cmd`）。
2. **Go のサブコマンドの中身は、engine の sh のスクリプトを Git Bash で起こしてよい。** bin/headless-run・bin/flix・java-resolve.sh・reference-*.sh は
   Windows では Git Bash の `bash` で起こす（場所は `CLAUDE_CODE_GIT_BASH_PATH` → Git for Windows の既定の場所 → PATH の順で探す）。
   macOS と Linux では今までどおり直に起こす。Go へ移すのは make だけでなく、Git Bash の上で動かない物（7 節）に限る。
3. **ゲームの設定は project.json に移す**（4 節）。Makefile は project.json を読む別名になる。
4. **人と AI への案内は「打つ形」を 1 つの関数で出す**（5 節）。
5. **移しにくい物は、最初の Windows 版の範囲から外す。** 外した物は Windows で打つと「macOS か Linux で」と 1 行出して止まる。AI に案内している所にも同じ 1 行を足す。

## 4. ゲームの設定を project.json へ（Makefile から移す）

project.json（ゲームの根・今もある）に宣言を足す。凍結した Studio が `studioTasks`（Runner.flix:309-325）で同じ形をしていたのにならう。

```jsonc
{
  "shots": ["main", "quit"],                     // 今の SHOTS（source of truth は Shots.names のまま。ここは render の一覧の写し）
  "prebuild": [{"out": "assets/x.palette.json", "deps": ["assets/x.theme.json", "src/Palette.flix"], "entry": "PaletteGen.main"}],
  "tasks": {                                      // ゲーム固有の作業（今のゲーム固有のターゲット）
    "bot":     {"entry": "Bot.main",     "about": "自動で遊ぶ"},
    "balance": {"entry": "Balance.main", "about": "収支を回す", "args": ["SEEDS"]}
  },
  "lint": ["lint-cast"],                          // make lint に足す物（中身も tasks に書く）
  "precommit": ["lint-flixlint"]                  // pre-commit で流す物（今の precommit-local）
}
```

- `bin/fge task <名前> [K=V…]` が tasks を流す。`bin/fge headless <Mod.entry> [K=V…]` は今の HEADLESS_RUN と同じ役（汎用）。
- テンプレート 6 つの Makefile のゲーム固有のターゲットを project.json へ移し、Makefile のターゲットは `bin/fge task <名前>` を呼ぶ 1 行にする。
  AGENTS.local.md の案内（rpg の `make bot` など）は `bin/fge task bot`（macOS と Linux では `make bot` も）にする。
- 既に産まれたゲームは触らない（Makefile のまま動く）。版上げの指示書（docs/migrations の手当て）に「project.json へ移すと Windows でも打てる」を書く。

## 5. Go へ移す物と、最初の Windows 版の範囲

| # | 作業（`bin/fge <作業>`） | 今の中身 | 移し方 | 最初の版 |
|---|---|---|---|---|
| 1 | `status`・hooks | `make -s status`（SessionStart）・bin/fge（sh） | SessionStart は `bin/fge status`。ほかの hooks は今の sh のまま（Git Bash）。searchfirst.go:293 の sh の bin/fge の exec は `os.Executable()` に | 入れる |
| 2 | 打つ形の案内 | status・hooks・explain-error・bin/lint-rules の 10 ファイルが `make <x>` を出す | `cmdhint` の 1 関数（作業の名前 → その OS の打ち方。make がある macOS と Linux では `make <x>`、無ければ `bin/fge <x>`）に通す。bin/lint-rules の文は `bin/fge <x>` で書く | 入れる |
| 3 | `new` | engine の Makefile の new-game | Go で写す・置き換える・git init・sync-agents（Go）・sync-fge-go。置き換えの規則は今の perl の 1 行と同じ（Studio の NewGame.flix は仕様とテストの答えとして見る）。make new-game はこれを呼ぶ別名 | 入れる |
| 4 | `check` | checkd（Go）・bin/flix・explain-error | 今の checkd を Windows でも使う（`CHECKD=0` の決め打ちを外す。checkd の flix.jar の引き方 resident.go:282,541 は bin/flix を Git Bash で起こすか、Go の javacmd で引く） | 入れる |
| 5 | `test` | flix test | Go から bin/flix を起こす | 入れる |
| 6 | `run`・`debug`・`render [SHOT…]/--all`・`headless`・`task`・`flow` | HEADLESS_RUN（bin/headless-run） | Go が bin/headless-run を（Windows では Git Bash で）起こす。prebuild（4 節）を先に流す | 入れる |
| 7 | `reference check / update` | reference-*.sh | Go の sha256（小さい・Git Bash の shasum の違いを避ける） | 入れる |
| 8 | `engine-upgrade [TO=…]` | upgrade-game（Go）＋ engine-full-fresh（sh）＋中の make check | 配った engine では engine-full-fresh は要らない。中の `make check`・`make -n` を #4 の Go に替える。11 節の差し替え | 入れる |
| 9 | `api`・`module`・`src` | make（awk・sed・find） | Go の apiindex（既にある）と module の索引を読む | 入れる |
| 10 | refactor・talk の中の sh | cmd_refactor.go:231,241,244 の `sh -c`・talk.go:292 の headless-run | `sh -c` を Go の exec に。talk は #6 の起動を使う | 入れる |
| 11 | precommit の中の make | precommit.go:298,318,360（make が無いと通す） | project.json の precommit（4 節）を Go で流す。make が無い時に知らせずに通すのをやめる | 入れる |
| 12 | flow/run.go:95・compare・useengine の make | | #6 の起動か、Go の作業に | flow は入れる・compare と useengine は後 |
| 13 | `run --seconds`（perl の fork） | | Go の子のプロセスの管理 | 後 |
| 14 | tape・migrate・dist・web-pages-stage・lint-huge-methods・strays・worktree-gc | ffmpeg・bash -c・git worktree | | 後（3 節の 5） |

- 作る順: #1 → #2 → #3 → #4 → #5 → #6 → #7 → #8 → #9 → #10 → #11 → #12。
- **#3 の new は onboarding の `fge new` の中身を置き換える。** onboarding の実装（`make -C <engine> new-game` を呼ぶ）を先に macOS と Linux で通し、#3 ができたら Go の new を直に呼ぶ。
- **起動の決まり（flix.jar・java・JVM の旗）は onboarding の後で 1 か所にまとめる。** 今 onboarding の担当が bin/flix・java-resolve.sh・javacmd を直している。
  まとめる先は Go の javacmd の隣に「足す」だけにし、bin/flix から Go に任せる形にはしない（engine の開発では fge-go が古い時がある）。

## 6. 配る物（onboarding の Windows の分）

- `install.ps1`（Release に添える・`irm <url> | iex`）: Git for Windows があるかを見る（無ければ入れ方を出して止める）。`fge-windows-amd64.exe` と
  `fge-SHA256SUMS.txt` を取り、`Get-FileHash` で照合し、`%USERPROFILE%\.flix_ge\bin\fge.exe` に置く。ユーザーの PATH に足す 1 行を出す（書き換えない）。
- Release の `fge-windows-amd64.exe`（go-build の 5 種に既にある）。arm64 の Windows は後。
- JDK: Zulu の Windows の zip（onboarding 2.4 と同じ版）。
- `.gitattributes`: engine とテンプレートに `* text=auto eol=lf`・`*.sh`・`Makefile`・`*.mk`・`bin/fge`・`bin/headless-run`・`bin/flix` を `eol=lf`・
  `*.cmd`・`*.ps1` を `eol=crlf`・画像と jar と fpkg を `binary`。
- git の pre-commit（sh・Git Bash で動く）の `-x bin/fge-go` が `fge-go.exe` を見つけるかは 9 節の確かめで見る（MSYS は `.exe` を補う見込み）。

## 7. Git Bash の上で気をつける事

- パス: Go から Git Bash へ渡すパスは `C:/x/y`（スラッシュ）にそろえる。Git Bash の中の `/c/x/y` を Go が受け取る所（スクリプトの出力を読む所）は両方を読む。
- symlink: Git Bash の `ln -s` は既定で写しになる。lib/cache は Windows では張らない（今の mvncache と同じ）。lint-rules-link・use-engine・fontbake の symlink は Windows では写しに替える。
- 改行: Go が書くファイルは LF。CRLF のファイル（flix.toml・*.json・Makefile の行）を読む所は CRLF でも読む。
- 実行ビット: Windows では見ない。読み取り専用は属性で。
- `uname`（sync-fge-go・bin/flix）: Git Bash では `MINGW64_NT-…`。今の分岐（Makefile:1287 の MINGW*）がある所はそのまま、無い所は Go の runtime.GOOS で。
- コンソールの文字コード: Go が起こす java に `-Dstdout.encoding=UTF-8`（onboarding で入れた）。PowerShell の端末の表示は、Go が出す最初の 1 行で
  文字化けしたら `chcp 65001` を案内する（Windows Terminal は既定で UTF-8）。

## 8. ダッシュボードと始め方の Windows の分

- `fge dashboard`・ワークスペースの頁・`fge open` は Go なので動く。`fge open` は `cmd /c start "" <url>`。
- ワークスペースの AGENTS.md・starters の文の中のコマンドは `bin/fge <作業>`。fge の絶対パスは `%USERPROFILE%\.flix_ge\bin\fge.exe` も併記。

## 9. 確かめ方

- **Windows の CI を足す**（GitHub Actions・workflow_dispatch と release の前）。今の Actions は ubuntu の release と gl-jar だけで、Go のテストも回していない。
  - Linux の job: Go のテスト（`go test ./...`）・`go-build`・配る zip（flix.jar は今の release の取り方と同じ）を組み、artifact で Windows の job に渡す
    （install.ps1 が公開済みの前の版を取ってしまうので、出す前の版を確かめるため）。
  - Windows の job（windows-latest）: artifact を `FGE_DOWNLOAD_URL` で配り、install.ps1 → `fge engines install` → `fge new ci_game` → `bin/fge check` →
    `bin/fge test` → `bin/fge reference update` → `bin/fge reference check`（テンプレートの SHA256SUMS は作者の手元の物なので、新しいゲームでは update から）→ `bin/fge render --all`（headless）。
  - **make と、Git Bash 以外の道具を「入っていない」にする**: PATH の先頭に、呼ばれたら記録を残して失敗する `make.cmd`・`make.exe` 相当の小さな物を置く
    （windows-latest には choco の make・Strawberry の perl・System32 の bash.exe（WSL）がある）。Git Bash は前提なので残す。
  - hooks: Claude Code の hooks の command を Git Bash で 1 つずつ起こし、終了コードと出力を見る。
- **Go が make を起こさない検査**: `bin/lint-rules/forbid.json` に、go/ の中の `exec.Command("make"` を止める 1 行（engine の開発だけで使う所は許す一覧に）。
- 人の手の確かめ（リリースの前に 1 回）: Windows の機械で install.ps1 → `fge dashboard` → カードから Claude → ゲームを作る → `bin/fge run`。
  Windows の機械が手元に無ければ、CI だけで出し、最初の利用者に確かめてもらう。

## 10. レビューへの答え

| 指摘（第 1 版・66 点） | 答え |
|---|---|
| C1 ゲームの Makefile が設定になっていて移す先が無い | 4 節で project.json へ・`bin/fge task`・`bin/fge headless` |
| C2 hooks の command を全部の OS で 1 本にできるか決まっていない・searchfirst の sh の exec | 0 節で Git for Windows を前提にし、hooks は Git Bash で今の sh のまま。SessionStart だけ `bin/fge status`。searchfirst は `os.Executable()`（5 節 #1） |
| C3 AI が最初に打つ道具（api・module・src・refactor・talk）が後 | 5 節 #9・#10 で最初の版に |
| C4 Go が出す make の案内と、Go が中で起こす make・precommit の fail-open | 5 節 #2（cmdhint）・#11・#12 |
| C5 CI が成り立たない（前の版を取る・PATH から外すと漏れる・SHA256SUMS） | 9 節（artifact・失敗する make・update から） |
| C6 Windows では動いている exe と開いている jar を置き換えられない | 11 節 |
| 起動の決まりのまとめ方・render-all の時間切れ・端末の文字化け・make hooks | 5 節の末尾・11 節・7 節 |
| もっと小さく: Git for Windows を前提に・run --seconds を外す・Studio は答えとして写す | 0 節・#13・#3 |
| （第 2 版）K1 headless-run の lib のリンクが Git Bash では丸写し | 12 節（ジャンクション） |
| （第 2 版）K2 開いている jar を差し替えられない | 12 節（指紋の入った名前） |
| （第 2 版）K3 プロセスの木を止められない | 12 節（Job Object） |
| （第 2 版）パスの形・bash の探し方・Stop の checkd・AF_UNIX・鍵の pid・project.schema・forbid | 12 節の「実装しながら決める物」 |

## 11. Windows で動いている物を差し替える時

- `fge-go.exe` の差し替え（sync-fge-go・engine-upgrade・status の配り直し・`fge self-update`）: 走っている exe は消せないが名前は替えられるので、
  今の物を `fge-go.exe.old` に名前を替えてから新しい物を置く。`.old` は次に起動した時に消す。
- lib の fpkg の差し替え（engine-upgrade）: checkd の常駐の JVM が開いているので、差し替えの前に `bin/fge checkd --stop` で常駐を止める。
- 時間: 走らせる・描き出す・render-all は Git Bash の headless-run の jar の作り置きで速いまま（Windows の今の毎回コンパイルをやめる）。
  Claude の Bash の 2 分の時間切れに当たる物（new・render-all）は、ワークスペースとゲームの AGENTS.md に「timeout を 600000 に」と書く（onboarding 2.6 と同じ）。

## 12. Git Bash の上の headless-run（jar の作り置き）を Windows で保つ

11 節の「速いまま」は headless-run の jar の作り置きが前提。Git Bash の上で崩れる所が 3 つあり、#6 の中で直す。

| 所 | 崩れ方 | 直し方 |
|---|---|---|
| headless-run:249 の `ln -sfn "$PWD/lib" "$proj/lib"` | MSYS の既定の `ln -s` は丸写しを作る。flix が依存を落とすのは写しの方になり、2 回目は写しの中に `lib/lib` を作り、指紋も毎回ずれる（mvn-cache-share.sh:46-47 は同じ理由で MSYS を外している） | MSYS の時だけ `cmd //c mklink /J`（ジャンクション。管理者の権限なしで張れる）。張れなければ毎回コンパイルする道へ移り、その旨を 1 行出す |
| headless-run:258-259 の `mv "$jar.tmp.$$" "$jar"` | Windows では、`run` のウィンドウや常駐の JVM が開いている jar を差し替えられない（ゲームを開いたまま render する、いつもの流れで止まる） | jar の名前に指紋を入れ、別の名前で置く（`headless-<指紋>.jar`）。今の名前は指紋の入った jar を指す小さなファイルにする。古い jar は開かれていなければ次の作り置きの時に消す |
| headless-run:544・bin/flix の最後の `exec` | MSYS の bash はネイティブの java を本当の exec でなく子のプロセスで起こす。時間切れや Ctrl+C で bash だけが落ち、java が残って jar を開いたままになる | #6 で Go が bash を起こす時は、Windows では Job Object（KILL_ON_JOB_CLOSE）に入れる。Go が止まれば木ごと止まる。#13 の `run --seconds` も同じ仕組みで作る |

- **指紋の入った jar の名前は Windows だけ**（第 3 版のレビュー）。`build/headless/headless.jar` を名前で直に読む所（go/internal/dist・jarshare・resident・
  mk/game.mk:216・mk/tape.mk・凍結した Studio の SharedJar）があるので、macOS と Linux は今の mv のまま。Windows では、それらの読み手が通る
  「今の名前が指す先を読む」1 関数を Go に置き、mk の 2 か所は Windows では範囲の外（#14）なので触らない。

実装しながら決める物（第 2 版のレビュー）:
- bin/flix の `FLIX_PRINT_JAR=1` は Git Bash では `/c/...` の形で返り、checkd が java の `-cp` に渡すと java.exe が読めない（resident.go:282）。bin/flix の側で MSYS の時に `cygpath -m` を通す。
- bash の探し方（3 節 2）: `CLAUDE_CODE_GIT_BASH_PATH` → Git for Windows の `bin\bash.exe`（`usr\bin` でない）。PATH からは探さない（System32\bash.exe は WSL を起こす物）。
- hooks の Stop の checkd は #4 が済むまで Windows では落ちる。#4 までは Windows では何もせず通す（作る順は #1 → #4 を先に）。
- checkd の常駐の AF_UNIX の socket は Windows 10 1803 以上と JDK 16 以上が前提。パスの長さは `%LocalAppData%` の下なので上限に収まる見込み。CI で 1 度確かめる。
- headless-run の鍵の pid（MSYS の pid）と Go の jarshare（builder.go:152・Windows の pid）は別のフォルダに置き、混ぜない。
- project.json に足す欄は project.schema.json に足し、凍結した Studio が知らない欄を読んでも壊れないことを確かめる。
- 9 節の forbid は `exec.Command("sh"`・`"bash"`・`"env"` も止める。bash は 3 節 2 の起動役 1 か所だけ許す。

## 13. 後に回す物

- 5 節の #13・#14。arm64 の Windows。
- PowerShell だけ（Git Bash が無い）の Claude Code。Git for Windows を前提にしたので、無い時は install.ps1 と `bin/fge status` が入れ方を出す。

## 14. 取り込み後の確かめ（2026-11-23・Linux のコンテナ）

今の作業枝から `bin/fge stage-engine`（リリースと同じ道）で配る engine を組み、手元の HTTPS サーバーで GitHub と Azul の形で配った。
PATH の先頭に、呼ばれたら記録して失敗する make を置いた（9 節の CI と同じ考え）。

| 確かめたこと | 結果 |
|---|---|
| `fge engines install latest` → `fge new tide-pool --template rpg-starter` | 通った（2 分 24 秒）。check → test（210 件緑）→ lint-flixlint → render-all |
| make が呼ばれた回数 | 0 |

見つけて直した物:
- lint-flixlint（5 節 #8）を担当に渡し漏れていて、make を起こしていた。`bin/fge lint-flixlint` を足した（flixlint の起動役は shellrun で Git Bash に）。
- perl まで罠にした回は、bin/headless-run の鍵を取る所が「鍵が無いのに取れない」まま待たずに取り直し続け、時間切れまで何も言わずに回った。
  移す先が無い時の perl の失敗は mv で移し、それでも取れなければ 5 回で loud_fallback に移す形にした。
  perl は Git for Windows に付いてくるので（0 節）、本番の前提では起きにくいが、置き場に書けない時にも同じ形で回るため直した。
- 9 節の CI の perl の罠は Git Bash の外の perl（Strawberry）だけで、0 節の前提と合っている（直す要は無かった）。
