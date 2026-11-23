# Windows 対応（準備のフェーズ）

状態: 設計 第 1 版（相談中）。実装は未着手。plans/onboarding.md（始め方）を macOS と Linux で通した後に、同じ始め方を Windows に載せるための準備。
レビューは 80 点以上でクリティカルな指摘が無ければ実装に入る（作者の判断）。

## 0. 決まっていること（2026-11-23 の作者の判断）

- **Windows は必須。** 対象は Windows のネイティブ（WSL でない）。WSL は Linux と同じ道なので別に扱わない。
- **ゲームを作る人に make・bash・perl を入れさせない。** 要る作業は Go の `bin/fge` に移す。
- engine を直す人（作者・devbox）の手元は今のまま（macOS と Linux）。engine の開発を Windows でする必要は無い。

## 1. 前提（公式の文書で確かめた事・2026-11-23）

| 事 | 出典 |
|---|---|
| Windows の Claude Code は Git for Windows（Git Bash）を必須にしない。無ければ Claude のシェルと hooks は PowerShell で動く | code.claude.com の setup・hooks |
| hooks は 1 つずつ `"shell": "bash"` か `"powershell"` を指定できる。Git Bash が無い時、終了コード 0 と 2 以外は失敗扱い | hooks |
| deep link（`claude-cli://open`）は Windows でも使える。登録は HKCU の claude-cli、開く端末は Windows Terminal → PowerShell → cmd の順 | deep-links |
| Claude Desktop は Windows で PowerShell のプロファイルを読まない。PATH はユーザーの環境変数で通す | desktop |

→ **bash が無くても動く形を既定にする。** Claude の hooks・AI が打つコマンド・人が使う道のどれも、Go の実行ファイルを直に呼ぶ。

## 2. 今の Windows の道と、止まる所（2026-11-23 の棚卸し）

- mk/game.mk:41-53 は Windows で JAVA と bin/flix.jar を直に使い、`CHECKD=0`・`FGE_NO_BASH=1`。それでも make と sh は前提のまま。
- ゲームの make のターゲットは約 30。run・debug・render・flow は `bin/headless-run`（bash・540 行）に頼り、Windows では毎回コンパイル（30 秒以上）。
  `run RUN_SECONDS` は perl、reference-check / update は sh と shasum、lint-flixlint は bash の起動役、dist・web-pages-stage・lint-huge-methods は Windows では止まる。
- engine の Makefile の new-game は cp -R・find・perl -pi・sed・git・mvn-cache-share.sh（Go に無い。凍結した Studio の Flix 版だけ）。
  upgrade-game の中身は Go（upgradegame）だが、先に流す engine-full-fresh は sh で、中で `make check` と `make -n` を起こす（upgradegame.go:547,557）。
- hooks: SessionStart は `make -s status`。ほかは `"$CLAUDE_PROJECT_DIR/bin/fge"`（sh の起動役）。checkd は `bin/flix`（bash）で flix.jar を引く（resident.go:282,541）。
- git の pre-commit（sh）は `-x bin/fge-go` を見るので、Windows の `fge-go.exe` を見落として検査を飛ばす。
- `.gitattributes` が無いので、Windows の autocrlf で sh と Makefile が CRLF になりうる。

## 3. 方針

1. **作業を Go のサブコマンドにする。make はその上の薄い別名にする。** macOS と Linux の人と AI は今までどおり `make run` を打てる。
   中身は `bin/fge run` を呼ぶだけになり、Windows では `bin/fge run`（`bin\fge.cmd run`・`bin/fge-go.exe run`）を打つ。
   - WhyNot make を Windows に入れてもらう: 「make・bash・perl を入れさせない」（0 節）。make だけ入れても中の sh で止まる。
2. **AI に案内する書き方を `bin/fge <作業>` にそろえる。** AGENTS.core.md の早見表・skills・starters の文を、どの OS でも打てる形にする。
   make のターゲットは「macOS と Linux では `make <作業>` でもよい」と 1 行だけ残す。
3. **hooks は Go の実行ファイルを直に呼ぶ。** `bin/fge-go <フック名>` の形にする（Git Bash も PowerShell も、Windows では `bin/fge-go` から
   `bin/fge-go.exe` を引く）。SessionStart の `make -s status` は `bin/fge-go status` にする。
   - 実物で確かめる事: hooks の作業フォルダがゲームの根か（相対パスで呼べるか）。違えば `$CLAUDE_PROJECT_DIR`（bash）と `$env:CLAUDE_PROJECT_DIR`
     （PowerShell）を hook ごとの `shell` で分ける。8 節の確かめで決める。
4. **移しにくい物は、最初の Windows 版の範囲から外す**（4 節の表の「後」）。外した物は Windows で打つと「macOS か Linux で」と 1 行出して止まる。

## 4. Go へ移す物

| # | 作業（`bin/fge <作業>`） | 今の中身 | 移し方 | 最初の Windows 版 |
|---|---|---|---|---|
| 1 | `new` | engine の Makefile の new-game（cp・find・perl・sed・git・mvn-cache-share.sh） | Go で写す・置き換える（`__NAME__` などの置き換えは new-game の perl の 1 行と同じ規則）・git init・sync-agents（Go にある）・sync-fge-go。make new-game はこれを呼ぶ別名に | 入れる |
| 2 | `check` | checkd（Go）と bin/flix・explain-error | flix.jar と java を Go で決める（javacmd と同じ決まり。onboarding 2.5）。checkd の flix.jar の引き方（resident.go:282,541）を Go に | 入れる |
| 3 | `test` | flix test・with-sample-tests（sh） | Go から java + flix.jar で flix test。with-sample-tests は配らないので要らない | 入れる |
| 4 | `run [--seconds N] [--start …]`・`debug` | headless-run（bash）・perl の fork | まずは毎回 `flix run`（Windows の今の道と同じ・遅い）。時間で止めるのは Go の子のプロセスの管理で | 入れる（遅い） |
| 5 | `render [SHOT…] / --all`・`palette`・`flow`・`talk-vocab` | HEADLESS_RUN | 4 と同じ起動を使う | 入れる（遅い） |
| 6 | `reference check / update` | reference-*.sh（sh・shasum） | Go の sha256（小さい） | 入れる |
| 7 | `engine-upgrade [TO=…]` | engine の upgrade-game（Go）＋ engine-full-fresh（sh）＋中の make check | 配った engine では engine-full-fresh は要らない（IS_BUNDLE）。中の `make check` を #2 の Go の check に替える | 入れる |
| 8 | flixlint の起動（`lint-flixlint`・refactor・checkd が使う） | bash の起動役 | Go から java で起こす | 入れる |
| 9 | `status`・hooks | make -s status・bin/fge（sh） | 3 節の 3 | 入れる |
| 10 | jar の作り置き（headless-run の速さ・常駐） | headless-run（540 行・鍵・指紋・エントリポイントの拾い出し・常駐） | jarshare・resident・mvncache（Go に部品がある）を組んで移す | 後（#4・#5 を速くする） |
| 11 | tape・migrate | ffmpeg・bash -c | | 後 |
| 12 | dist・web-pages-stage・lint-huge-methods | git worktree・headless-run --build-only | | 後 |
| 13 | strays・worktree-gc・src / api / module（awk・sed） | sh | api と module は Go の apiindex で置き換えられるか見る | 後 |

- 作る順: #9（hooks が動かないと AI が使えない）→ #1 → #2 → #3 → #6 → #7 → #8 → #4・#5 → #10。
- **#1 の new は onboarding の `fge new` の中身を置き換える。** onboarding の実装（`make -C <engine> new-game` を呼ぶ）を先に macOS と Linux で通し、
  #1 ができたら `fge new` は Go の new を直に呼ぶ。make new-game（engine を clone した人が打つ物）は Go の new を呼ぶ別名にし、二重に持たない。
- **起動の決まりを 1 か所に。** flix.jar・java・JVM の旗（`--enable-native-access=ALL-UNNAMED`・`-Xss`・Java 24 以上の `--sun-misc-unsafe-memory-access=allow`・
  macOS の `-XstartOnFirstThread`・headless・`-Dstdout.encoding=UTF-8`）は今 bin/flix と mk/game.mk の Windows の行と headless-run に散っている。
  Go の 1 つの関数（javacmd の隣）にまとめ、bin/flix はそれを呼ぶ形にしてよい（macOS と Linux の bin/flix は残す。中身を Go に任せる）。

## 5. 配る物（onboarding の Windows の分）

- `install.ps1`（Release に添える・`irm <url> | iex`）: `fge-windows-amd64.exe` と `fge-SHA256SUMS.txt` を取り、`Get-FileHash` で照合し、
  `%USERPROFILE%\.flix_ge\bin\fge.exe` に置く。ユーザーの PATH に足すかは聞かずに案内だけ（install.sh と同じ）。
- Release の `fge-windows-amd64.exe`（go-build の 5 種に既にある）。arm64 の Windows は後。
- JDK: Zulu の Windows の zip（onboarding 2.4 と同じ版）。開き方は zip（tar.gz でない）。
- ゲームの `bin/fge-go.exe`: sync-fge-go が Windows 向けを置く（今も IS_BUNDLE で分けている・Makefile:1286-1291）。#1 で Go に移す。
- `.gitattributes`: engine とテンプレートに `* text=auto eol=lf`・`*.sh`・`Makefile`・`*.mk`・`bin/fge` を `eol=lf`・`*.cmd`・`*.ps1` を `eol=crlf`・画像と jar を `binary`。
- git の pre-commit（sh）の `-x bin/fge-go` を、`bin/fge-go` か `bin/fge-go.exe` のどちらかがあれば、に直す（Git for Windows がある人の pre-commit は sh で動く）。

## 6. パスと OS の違い

- パスの組み立ては `filepath`、外へ出す時（deep link の cwd・workspace.json・ログ）は絶対パス。workspace.json は OS の区切りのまま持つ。
- symlink: Windows では張らない（lib/cache は各ゲームに取る。今の mvncache と同じ）。lint-rules-link・use-engine・fontbake の symlink は Windows では写しに替える。
- 実行ビット: Windows では見ない。読み取り専用は `os.Chmod` で属性を付ける（engine の置き場）。
- `uname` を使う所（sync-fge-go・bin/flix）は Go の runtime.GOOS / GOARCH に。
- 改行: Go が書くファイルは LF。Windows の人がエディタで CRLF にしたファイルを読む所（flix.toml・*.json・Makefile の行を読む所）は CRLF でも読めるようにする。

## 7. ダッシュボードと始め方の Windows の分

- `fge dashboard`・ワークスペースの頁・`fge open` は Go なので、そのまま動く。`fge open` は `cmd /c start "" <url>`（onboarding 2.6）。
- `claude --desktop`（ダッシュボードのフェーズ 3）は x64 の Windows だけ（desktop の文書）。
- ワークスペースの AGENTS.md・starters の文の中のコマンドは `bin/fge <作業>` の形（3 節の 2）。fge の絶対パスは `%USERPROFILE%\.flix_ge\bin\fge.exe` も併記。

## 8. 確かめ方

- **Windows の CI を足す**（GitHub Actions の windows-latest・手で起こす workflow_dispatch と release の前）:
  install.ps1 → `fge engines install <版>` → `fge new ci_game --template game-starter` → `bin/fge check` → `bin/fge test` → `bin/fge reference check`。
  画面を開く run と render は CI では流さない（headless の render だけ流せるか見る）。make・bash・perl を PATH から外した状態で流す
  （windows-latest には Git Bash と make が入っているので、PATH から外して「入っていない人」と同じにする）。
- hooks: Windows の CI で、Claude Code の hooks の command を PowerShell で 1 つずつ起こし、終了コードと出力を見る（3 節の 3 の作業フォルダもここで決める）。
- 各 Go の作業のテスト: OS ごとの分かれ目（GOOS を引数で替えられる形）を Linux の CI で見る。
- 人の手の確かめ（リリースの前に 1 回）: Windows の機械で install.ps1 → `fge dashboard` → カードから Claude（PowerShell）→ ゲームを作る → `bin/fge run`。
  **Windows の機械を作者が持っているか確かめる**（無ければ CI だけで出し、最初の利用者に確かめてもらう）。

## 9. 後に回す物

- 4 節の表の #10〜#13（jar の作り置き・tape・dist・開発向けのターゲット）。
- arm64 の Windows。

## 10. 決めていないこと（相談）

1. Windows の機械で手の確かめができるか（8 節）。
2. 最初の Windows 版で run と render が毎回コンパイル（30 秒以上）でもよいか。速くする #10 を最初の版に入れるか。
