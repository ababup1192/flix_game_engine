# ゲームを配る（make dist-linux / dist-macos / dist-windows / dist-all）

ゲームの jar・その OS の JRE・起動を 1 本の配布物にまとめる。遊ぶ人の機械には Java も開発の道具も要らない。
Steam Deck での置き方と実機で見る所は [steam-deck.md](steam-deck.md)。

## 作る（Mac か Linux で）

```sh
make dist-all                          # ゲームの根で。3 つとも → build/dist/
make dist-macos DIST_OUT=~/dist-out    # 1 つだけ・書き出す先を替える
```

| 変数 | 既定 | 中身 |
|---|---|---|
| `DIST_OUT` | `build/dist` | 書き出す先 |
| `DIST_VERSION` | ゲームの短いコミット（変更が残っていれば `-dirty`） | ファイル名に入れる版 |
| `DIST_NAME` | ゲームの根のフォルダ名 | 名前（英数字・`- _ .` だけ） |
| `DIST_INCLUDE` | `assets,project.json` | jar の隣に置く物（実行時に作業場からの相対で読む物） |

できる物（隣に `.sha256`）:

| OS | ファイル | 起動 | 書く物（セーブ・ログ） |
|---|---|---|---|
| Linux x64 | `<名前>-<版>-linux-x64.tar.gz` | `run.sh` | `~/.local/share/<名前>/` |
| macOS arm64（Apple Silicon） | `<名前>-<版>-macos-arm64.zip` | `<名前>.app` | `~/Library/Application Support/<名前>/` |
| Windows x64 | `<名前>-<版>-windows-x64.zip` | `run.bat` | `%LOCALAPPDATA%\<名前>\` |

- jar は `make run` と同じ物（`bin/headless-run --build-only`）。LWJGL の native は 3 つの OS の分が全部入っている。
- JRE は Temurin 21 の版を 3 つの OS でそろえて固定する（版と SHA-256 は `go/internal/dist/targets.go` の `Targets`）。
  1 回目だけ落とし（各 50 MB ほど）、OS のキャッシュ置き場の `fge-jre/` に置く。SHA-256 が合わなければ止まる。
- 起動は、書く物をユーザーの置き場へ回し、読む物（assets/・project.json）は配布物の中を指させてから、そこへ移って
  `FGE_ENTRY=main` で jar を流す（Linux と macOS は symlink・Windows はフォルダを junction・ファイルは写し）。
  配布物を読むだけの場所に置いても saves/ を作れ、版を上げてもセーブが残る。
- 起動の中身は Linux と macOS で 1 つ（`go/internal/dist/launch.sh`）、Windows は `run.bat`。OS ごとの差は `targets.go` の `Target`。
- Windows では作れない（jar を作る `headless-run` が bash）。

## 遊ぶ人への渡し方

### macOS（Apple Silicon）

1. zip をダブルクリックで解き、`<名前>.app` を「アプリケーション」へ移す。
2. 署名していないので、初回のダブルクリックは「開けません」で止まる。ダイアログを「完了」で閉じ、
   システム設定 →「プライバシーとセキュリティ」→ 下の方の「このまま開く」→ パスワード → もう一度ダブルクリック →「開く」。
   端末で済ませるなら `xattr -dr com.apple.quarantine /Applications/<名前>.app`。
3. 2 回目からはふつうにダブルクリックで開く。

Intel の Mac では動かない（JRE が arm64）。

### Windows x64

1. zip を右クリック →「すべて展開」（zip の中から直に run.bat を開くと動かない）。
2. `run.bat` をダブルクリック。コンソールは最小化で開き、数秒でゲームのウィンドウが出る。
3. 初回に「Windows によって PC が保護されました」と出たら「詳細情報」→「実行」。

### Linux x64・Steam Deck

[steam-deck.md](steam-deck.md)。

## 落ちた時

まずログ（`logs/run.log`・1 つ前は `run.prev.log`）を見る。置き場は上の表の「書く物」。

| 環境変数 | 中身 |
|---|---|
| `FGE_JAVA_OPTS` | java へ足す旗（既定の旗の後ろなので上書きできる） |
| `FGE_DATA_DIR` | 書く物の置き場を替える |
| `FGE_ENTRY` | 流す入口（既定 `main`。描き出しの入口を渡すとウィンドウなしで中身を確かめられる） |
| `FGE_WAYLAND=1` | Linux だけ。Wayland で開く（既定は X11） |

前の版の写しなど、symlink（Windows は junction）でない `assets` が書く物の置き場に残っていると、起動は止まる。
古い assets のまま動かないため。消してから起動し直す。
