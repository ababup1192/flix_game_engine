# checkd — flix check / flix test の常駐高速化

## 何が嬉しいか

`flix check` は毎回 JVM とコンパイラをゼロから立ち上げるので、小さなパッケージでも
5〜10 秒かかる。`bin/fge checkd` はパッケージごとに flix repl を裏で 1 つだけ温めて持ち、
2 回目からの check を **0.5 秒前後**で返す。

```
bin/fge checkd [パッケージdir]  # check する (省略時はカレント)。見た目と exit code は素の check と同じ
bin/fge checkd --test [dir]     # test する (check と同じ常駐 repl を使う)
bin/fge checkd --stop [dir]     # そのパッケージの常駐を止める
bin/fge checkd --stop-all       # 常駐を全部止める (make checkd-stop と同じ)
```

examples の `make check` / `make test` は自動でこれを通る。**素の経路に戻したい時は
`CHECKD=0 make check` / `CHECKD=0 make test`**。

## どう動くか

```
make check ──> bin/fge checkd (クライアント)
                  │ TCP 127.0.0.1    常駐が無ければ自動で立てる。実ポートは
                  ▼                  ~/.cache/flix-checkd/<ハッシュ>/port に書いてある。
                  │                  会話に失敗したら素の bin/flix check に落ちる
               checkd 常駐 (パッケージごとに 1 つ)
                  │ パイプで :check を送り、結果を CLI と同じ見た目に整える
                  ▼
               flix repl (温まった JVM)
```

- 保存 → check だけでよい。ただし repl（flix 0.78）は書き換えをファイルの監視の知らせでしか取り込まず
  （`:reload` は無い）、macOS の JDK では監視が 10 秒おきの見回りになる。待たずに `:check` を送ると古い中身で
  緑が出るので、checkd は保存から約 11 秒待ってから送る（`go/internal/checkd/sources.go` の `watchLag`）。
  保存直後の check がその分遅いのはこのため
- 結果の正しさが常に最優先。少しでも怪しければ黙って素の check に落ちる

## flixlint の常駐で check する（試しの道・`CHECKD_BACKEND=server`）

`CHECKD_BACKEND=server make check`（heavy の中では `CHECKD=1` も）で、repl の代わりに flixlint の常駐（lint・refactor の索引と
同じ JVM・同じコンパイラ）に check を頼む。設計は `flixlint/docs/design/checkd-freshness.md`（flixlint のリポ）（C-2）。既定は repl のまま。

```
make check ──> bin/fge checkd ──> Unix ソケット (~/Library/Caches/flixlint/<根と identity の 16 字>.sock)
                                      ▼
                                  flixlint の常駐: Bootstrap → 書き換わったソースだけ addSource → Bootstrap.check
                                      │ 答え = 出力 + 終了コード + 検査したソースの版
                                      ▼
               クライアントがディスクから版を取り直し、同じ時だけ答えを使う（違えば頼み直し、3 回の後は素の flix check）
```

- 待ちが無い: ファイルの監視に頼らず、頼まれた時にソースを読んで渡すので、保存直後の 11 秒の待ちが要らない。
- 古い答えが出ない: 答えの版（ソース・flix.toml・packages.lock の中身の SHA-256 から作る 1 つの値）をディスクと比べる。
  式は flixlint の README "Resident server" が正で、`go/internal/checkd/testdata/resident` は flixlint のリリースの fixture の写し。
- 置き場と予算は `bin/lint-rules/hooks.json` の `checkd.server`（flixlint の版と shim の jar の sha256・ヒープ 3072 MB・寿命 30 分）。
  shim の jar は初回にリリースから取り、sha256 が合う時だけ `~/.cache/flix-checkd/flixlint/<版>/` に置く。
- 1 回ごとに `~/.cache/flix-checkd/<ハッシュ>/daemon.log` に `check via=server|fallback exit= version= retry= 秒` の 1 行。
- `bin/fge refactor` の索引（flixlint --spans）も、hooks.json に `checkd.server` があればこの常駐で作る（同じ shim の jar・ヒープ・寿命を渡すので
  socket は 1 本）。常駐で作る索引は heavy の枠を取らず、書き換えの後の確かめの `make check` は `CHECKD=1 CHECKD_BACKEND=server` で
  heavy の外で流す（heavy は既定で `CHECKD=0` を入れるため、枠の中では素の flix check になっていた）。

## test も同じ常駐で速くなる

check と test は 1 本の repl が両方受ける。温まった repl の `:test` は、素の
`flix test` (sokoban で 9〜12 秒) が **3〜4 秒**になる (約 3 倍)。exit code は
出力のまとめ行 (`Passed: N, Failed: M.`) から復元し、行が読み取れない出力なら
推測せず素の CLI に投げ直す。テスト本数・失敗本文は CLI と同じに出る。

注意が 2 つ:

- `:test` は 1 回ごとにメモリが数百 MB 増える (check より漏れが速い)。メモリの
  上限に当たったら repl をその場で使い捨てるので、直後の 1 回だけ遅くなるのは仕様
- repl には常に `-Djava.awt.headless=true` を付けて起動する。GLFW と AWT の初期化が
  ぶつかるとテストが固まるパッケージがあるため。checkd は run を
  扱わないので、常時付けて害はない

結果が疑わしい時の逃げ道は check と同じ: `CHECKD=0 make test` で素の経路に戻る。

## Claude Code から自動で走る (Stop / SubagentStop hook)

保存のたびではなく、**会話が止まる直前**（`Stop` / `SubagentStop`）に
`bin/fge hook-flix-work` が走り、作業ツリーで変わった `.flix` を
持つパッケージだけを検査する。かつては `PostToolUse`（保存のたび）で
走らせていたが、サブエージェントを並列に走らせると保存が秒間何度も届き、
常駐 (JVM) が増殖して機械が重くなった (2026-08-13 実測: load 183・空きメモリ
69MB)。編集の途中の型エラーを拾ってノイズになる問題もあった。

引き金を区切りへ移した上で、次の段階でさらにノイズを削る:

- **このセッションが触っていないパッケージは検査そのものをしない** — 複数の
  エージェントが並行で走ると、作業ツリーには他セッションが編集中の（赤くて
  当然の）パッケージも混ざる。それを拾って無関係な赤で他人のターンを止めない
  よう、「触った」の印を PostToolUse（保存のたび、検査はせず印を置くだけの
  軽い hook = `bin/fge hook-flix-touch`）が
  `~/.cache/flix-checkd/<パッケージのハッシュ>/touched-<session_id のハッシュ>`
  に残す。印の無いパッケージは検査もブロックもしない。**印を置くついでに、
  そのパッケージの常駐が居なければ起動だけ頼む**（CHECK は送らない）ので、
  作業の区切りが来る頃には温まっている
- **前回検査した時点から変わっていないパッケージは飛ばす**（差分の内容ハッシュを
  `~/.cache/flix-checkd/<ハッシュ>/stop-hash` に持つ）
- **差分が丸ごとコメント・空行だけなら型検査しない**（`//` `///` 行と空行だけの
  変更は型に影響しない）

NG が出れば `decision:block`（exit 2）で Claude に差し戻し、緑と自己申告した
まま終わるのを防ぐ。無限ループにならない歯止めは 2 つ:

- Stop hook のペイロードの `stop_hook_active`（前回このフックがブロックした
  結果、今まさに継続ターンに入っている印）が真なら、何もせず即 exit 0 で降りる
- ブロックした後、同じ内容のまま再び Stop が来ても、差分ハッシュが変わって
  いなければ検査済み扱いで飛ばす

常駐の起動予約には歯止めがある（`tooBusy()`）: 同じパッケージへは 90 秒に
1 回・load 平均が CPU 数を超えたら見送る・生きている常駐は機械の物理メモリから
決まる数まで（16GB なら **3 個**。`CHECKD_MAX_DAEMONS` で変えられる）。
Flix を並行で触るエージェントがその数までなら全員が温かい repl を持てて、
それ以上は素の CLI に落ちる（遅いだけで結果は同じ）。

**数の上限の式は 1 か所**（`bin/lint-rules/hooks.json` の `checkd.maxDaemons`）に
あり、起動予約の歯止めも常駐 1 本のメモリ予算もそこから引く。判定値は全部この
JSON が source of truth で、読めなければ既定値へ倒さず止まる。

中身は 2 つに分かれる。常駐そのもの（repl の起動・温め・使い捨て・TCP の口）は
`go/internal/checkd/`。常駐との通信（パッケージの根探し・PING / CHECK・起動予約）は
`go/internal/hooks/checkd.go` にまとまっていて、どのフックもここを通る。
1 ファイル分のペイロードを手で流し込んで返事を確かめる口は
`bin/fge hook-flix-edit`（settings.json には配線していない）。

## 常駐は勝手に片づく

デーモンが溜まって Mac を重くしないよう、自分で消える:

- 既定 10 分（環境変数 `CHECKD_IDLE_SEC` で変えられる、単位は秒）誰も
  check / test しなければ自殺する
- `flix.toml` や `lib/` の依存の実体 (symlink の先も見る) が変わったら、古い依存を
  握り続けないよう repl を作り直す (`make sync-engine-full` 後の check も安全)
- repl 1 本のメモリが上限（機械の物理メモリの 33% を常駐の数で割った値。16GB なら
  約 1.8GB）を超えるか、check / test 合計 200 回で使い捨てて立て直す
  （`CHECKD_RSS_MB` で変えられる）
- その上限に収まるよう、repl の JVM には `-Xmx`（上限からヒープの外に要る分を引いた
  値）で蓋をして起こす。蓋が無いと JVM は物理メモリの 1/4 まで自由に太り、1 回検査
  するたびに上限を超えて捨てられる = 常駐が 1 度も効かない。上限を上げても太る先が
  上がるだけなので、上限の側でなく repl の側に蓋をしている。
  蓋が足りずに JVM が `OutOfMemoryError` を出したときは、赤として持ち帰らず素の
  `flix check` に投げ直す（ソースが悪いわけではないので、偽の赤を出さない）

## 困ったら

```
make checkd-stop        # 全部止める。次の check が立て直すので、いつ打っても壊れない
```

check の結果がどうしても疑わしい時は `CHECKD=0 make check`(または `bin/flix check`)で
素の経路と比べる。常駐の記録は `~/.cache/flix-checkd/<ハッシュ>/daemon.log` にある。
`CHECKD_DEBUG=1` を付けると、クライアントがなぜ素の check に落ちたかを表示する。

## 対象外 (今はやらない)

- `make run` の常駐化 (repl は絵のウィンドウを出せないし、常時 headless とも相性が悪い)
- engine / engine_world 等パッケージ本体の test (まず examples で様子を見る)
- LSP (`flix lsp`) 経由の診断: 0.75.1 では CLI check と結果が食い違う偽エラーを
  出すことがあり不採用
- repl をやめ、Flix の内部 API（`Bootstrap.bootstrap` → `mkFlix`・`Flix.addSource`・`Flix.check`）を直接呼ぶ窓口に
  替えて約 11 秒の待ちを消す案: 試作で、待たずに検査でき偽の緑も出ないことは確かめた（2026-10 / flix 0.78）。
  見送ったのは得が小さいため — internet_dungeon（169 ファイル）では 1 文字変えても Typer がほぼ全部やり直しになり、
  2 回目の check は repl でも窓口でも 40〜60 秒で、縮むのは待ちの 11 秒だけ（テンプレ程度の大きさなら 0.5〜1.6 秒で返る）。
  代わりに Scala の内部 API に縛られ、flix の版を上げるたびに壊れうる。ゲームの check を速くするなら、Typer を重くしている
  大きな record の型を enum で包む方が効く（[flix-conventions.md](flix-conventions.md)）
