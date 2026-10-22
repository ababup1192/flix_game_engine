# checkd — make check の速い道

## 何が嬉しいか

`flix check` は毎回 JVM とコンパイラをゼロから立ち上げる。`bin/fge checkd` は check を flixlint の常駐（lint・`bin/fge refactor`
の索引と同じ JVM・同じコンパイラ）に頼み、変わったファイルだけを渡して検査させる。ゲーム（internet_dungeon）で 1 行変えた後の
`make check` は、前の repl の常駐の 15.15 秒に対して 5.11 秒（中央値。設計と測りは flixlint のリポの
`flixlint/docs/design/checkd-freshness.md` の C-2）。

```
bin/fge checkd [パッケージdir]  # check する (省略時はカレント)。出力と exit code は素の flix check と同じ
bin/fge checkd --test [dir]     # test する (素の flix test)
bin/fge checkd --stop [dir]     # そのパッケージの常駐を止める
bin/fge checkd --stop-all       # 記録のある常駐を全部止める (make checkd-stop と同じ)
```

examples の `make check` は自動でこれを通る。**素の check に戻したい時は `CHECKD=0 make check`**（`CHECKD_BACKEND=cli` でも同じ）。
`make test` はいつも素の `flix test`（下の「test は素の CLI」）。

## どう動くか

```
make check ──> bin/fge checkd ──> Unix ソケット (~/Library/Caches/flixlint/<根と identity の 16 字>.sock)
                                      ▼
                                  flixlint の常駐: Bootstrap → 書き換わったソースだけ addSource → Bootstrap.check
                                      │ 答え = 出力 + 終了コード + 検査したソースの版
                                      ▼
               クライアントがディスクから版を取り直し、同じ時だけ答えを使う（違えば頼み直し、3 回の後は素の flix check）
```

- 待ちが無い: ファイルの監視に頼らず、頼まれた時にソースを読んで渡す。保存の直後に check してよい。
- 古い答えが出ない: 答えの版（src/・test/ の .flix と flix.toml・packages.lock の中身の SHA-256 から作る 1 つの値）をディスクと比べる。
  式は flixlint の README "Resident server" が正で、`go/internal/checkd/testdata/resident` は flixlint のリリースの fixture の写し。
  symlink で束ねたソース（engine_full）も、読むのはリンクの先の中身なので同じ道で正しい。
- 置き場と予算は `bin/lint-rules/hooks.json` の `checkd.server`（flixlint の版と shim の jar の sha256・ヒープ 3072 MB・寿命 30 分）。
  shim の jar は初回にリリースから取り、sha256 が合う時だけ `~/.cache/flix-checkd/flixlint/<版>/` に置く。
- 1 回ごとに `~/.cache/flix-checkd/<ハッシュ>/daemon.log` に `check via=server|fallback exit= version= retry= 秒` の 1 行。
  常駐そのものの記録は socket の隣の `<名前>.log`。
- 常駐が無い・壊れている・答えない時は、1 回だけ起こし直し、それでも駄目なら黙って素の check に落ちる。
- 型の別名（`type alias`）が変わった時は、常駐（flixlint 0.8.5 から）がコンパイラのキャッシュを捨ててから検査する。
  Flix 0.78 の増分の compile は別名を引数の型にだけ使うファイルを型付けし直さず、触っていないファイルの呼び出しが
  「Extra label」で落ちていた（素の flix check は通る）。その回は全部を検査し直す分だけ遅い（internet_dungeon で 4〜5 秒・普段は 1〜4 秒）。
- `bin/fge refactor` の索引（flixlint --spans）も同じ常駐で作る（同じ shim の jar・ヒープ・寿命を渡すので socket は 1 本）。
  常駐で作る索引は heavy の枠を取らず、書き換えの後の確かめの `make check` は heavy の外で流す（heavy は既定で `CHECKD=0` を
  入れるため、枠の中では素の flix check になる）。

## test は素の CLI

テストはゲームのコードを動かすので、check と lint の常駐には入れない（固まり・`System.exit`・窓の初期化が常駐を巻き込む）。
常駐で組んで別の短い JVM で流す形も測ったが、ゲームではテストの実行（約 64 秒）がコンパイル（約 30 秒）より重くて縮まず、
コード生成のヒープが常駐の線を超えた（flixlint の checkd-freshness.md の C-T の記録）。`make test` と `bin/fge checkd --test` は
`-Djava.awt.headless=true` を付けた素の `flix test`。

## Claude Code から自動で走る (Stop / SubagentStop hook)

保存のたびではなく、**会話が止まる直前**（`Stop` / `SubagentStop`）に `bin/fge hook-flix-work` が走り、作業ツリーで変わった
`.flix` を持つパッケージだけを検査する。かつては `PostToolUse`（保存のたび）で走らせていたが、サブエージェントを並列に
走らせると保存が秒間何度も届き、常駐 (JVM) が増殖して機械が重くなった (2026-08-13 実測: load 183・空きメモリ 69MB)。
編集の途中の型エラーを拾ってノイズになる問題もあった。

引き金を区切りへ移した上で、次の段階でさらにノイズを削る:

- **このセッションが触っていないパッケージは検査そのものをしない** — 「触った」の印を PostToolUse（保存のたび、検査は
  せず印を置くだけの軽い hook = `bin/fge hook-flix-touch`）が
  `~/.cache/flix-checkd/<パッケージのハッシュ>/touched-<session_id のハッシュ>` に残す。印の無いパッケージは検査も
  ブロックもしない。**印を置くついでに、そのパッケージの常駐が居なければ裏で 1 回 check を頼んで起こす**ので、作業の
  区切りが来る頃には温まっている。区切りの検査は常駐が居る時だけ（居なければ起こすのを頼んで見送る）
- **前回検査した時点から変わっていないパッケージは飛ばす**（差分の内容ハッシュを
  `~/.cache/flix-checkd/<ハッシュ>/stop-hash` に持つ）
- **差分が丸ごとコメント・空行だけなら型検査しない**（`//` `///` 行と空行だけの変更は型に影響しない）

NG が出れば `decision:block`（exit 2）で Claude に差し戻し、緑と自己申告したまま終わるのを防ぐ。無限ループにならない
歯止めは 2 つ:

- Stop hook のペイロードの `stop_hook_active` が真なら、何もせず即 exit 0 で降りる
- ブロックした後、同じ内容のまま再び Stop が来ても、差分ハッシュが変わっていなければ検査済み扱いで飛ばす

常駐の起動予約には歯止めがある（`tooBusy()`）: 同じパッケージへは 90 秒に 1 回・load 平均が CPU 数を超えたら見送る・
生きている常駐は機械の物理メモリから決まる数まで（16GB なら **3 個**。`CHECKD_MAX_DAEMONS` で変えられる）・常駐 1 本
（`checkd.server.heapMB` + `checkd.daemon.heapHeadroomMB`）が物理メモリの `checkd.daemon.rssLimit.memoryShare` に収まらない
機械では予約しない。常駐が居るかは、checkd が状態の置き場に残す記録（`server`: socket・根・identity）の socket に
つながるかで見る。

判定値は全部 `bin/lint-rules/hooks.json` が source of truth で、読めなければ既定値へ倒さず止まる。中身は、check の
クライアント（常駐との口・版・起動・止め方）が `go/internal/checkd/`、フックからの使い方（パッケージの根探し・起動予約・
区切りの検査）が `go/internal/hooks/`。

## 困ったら

```
make checkd-stop        # 全部止める。次の check が立て直すので、いつ打っても壊れない
```

check の結果がどうしても疑わしい時は `CHECKD=0 make check`（または `bin/flix check`）で素の経路と比べる。
`CHECKD_DEBUG=1` を付けると、受けた版と頼み直しの数、素の check に落ちた訳を表示する。

## 対象外 (今はやらない)

- `make run` の常駐化
- engine / engine_world 等パッケージ本体の test
- LSP (`flix lsp`) 経由の診断: 0.75.1 では CLI check と結果が食い違う偽エラーを出すことがあり不採用
- Windows: checkd は flix.jar の場所を bash ラッパー (bin/flix) から引くので、template の make check は Windows で
  `CHECKD := 0`（素の check）のまま
