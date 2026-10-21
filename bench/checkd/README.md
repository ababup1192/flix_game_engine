# bench/checkd — checkd の作り直しの前と後を測る道具（段 C-0）

checkd（[docs/checkd.md](../../docs/checkd.md)）を作り直す前の基準と、作り直した後の比べに使う 3 本。
どれも**測る相手のパッケージを書き換える**ので、ゲームの作業場ではなく写しに向けて流す（`/bin/cp -cR` の APFS の写しで足りる。
写しの `.git` は元の作業場の git を指すので外しておく）。`bin/fge` はこの作業場の物を使う（作り直した版を測るなら、その版の作業場で流す）。

| 台本 | 何を数えるか | 流し方 |
|---|---|---|
| `stale.sh` | 古い答え: 壊す → すぐ checkd → 直す → すぐ checkd の往復で、壊した後に緑・直した後に赤を返した回数。どの経路で答えたか（常駐 / 素の CLI へ落ちた）も分ける | `bench/checkd/stale.sh <写し> [往復=200] [壊すファイル]` |
| `compare.sh` | checkd と素の `flix check` の答え（終了コードと、色・経過の秒・依存の解決の行・終わりの空行を落とした出力）が同じか。そのまま・型の誤り・構文の誤り・知らない名前・使わない変数の 5 つ | `bench/checkd/compare.sh <写し> [壊すファイル]` |
| `watchlag.sh`（`WatchProbe.java`） | JDK の WatchService が、保存を何秒後に知らせるか（flix の repl の FileWatcher と同じく、src/ の木の下のディレクトリを感度の指定なしで全部 register）。1 回ごとの遅れと、その時の load average | `bench/checkd/watchlag.sh <写し> [回数=30]` |

壊すファイルの既定は src/ の一番小さい `.flix`。壊し方はファイルの終わりに def を 1 行足すこと（直すのは元の中身へ戻すこと。止めても trap で戻す）。
記録は `<写し>/.checkd-c0/`（`stale.tsv`・`compare-<場合>.{checkd,cli}.{raw,txt}`・`watchlag.tsv`）。

## 作り直す前の基準（main d314c8aa の checkd・2026-10-21・Mac mini（Mac16,11）・internet_dungeon の写し）

- compare: 5 つとも同じ（終了コード・出力）。常駐が素の CLI へ落ちた回 0。素の CLI は出力の終わりに空行を 1 つ多く出す（checkd の scrub が落とす）。
- watchlag: JDK 21.0.8（Zulu）の `sun.nio.fs.PollingWatchService`、30 回で最小 0.02 秒・中央 1.42 秒・最大 1.90 秒・10 秒を超えた 0 回
  （load average 10〜23）。checkd が macOS で待つ 11 秒（`go/internal/checkd/sources.go` の `watchLag`）より短い。
- stale: 200 往復（check 400 回）で古い答え 0 回・素の CLI へ落ちた 0 回。どれも常駐が答え、1 回は平均 17.1 秒・最長 22.7 秒
  （保存からの 11 秒の待ちを含む。壊したファイルは src/scene/EndingScene.flix。load average 3〜37。混み具合の測りのため 73 往復で 1 度止め、残りの 127 往復を続けて流した数の和）。
  今の作りでは、11 秒待つことで古い答えは出ていない（作り直しは、この 0 回を保ったまま待ちを詰められるかを見る）。
