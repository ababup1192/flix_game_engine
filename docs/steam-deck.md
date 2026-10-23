# Linux・Steam Deck で遊ぶ（make dist-linux）

ゲームの jar・Linux x64 の JRE・起動の `run.sh` を 1 本の tar.gz にまとめる。Deck には Java も開発の道具も要らない。

## 作る（Mac か Linux で）

`make dist-linux`（ゲームの根で）→ `build/dist/<名前>-<コミット>-linux-x64.tar.gz` と `.sha256`。
変数・JRE の版・ほかの OS は [dist.md](dist.md)。

中身:

```
<名前>-<コミット>-linux-x64/
  run.sh          起動
  README.txt      Deck での置き方の短い版
  game/game.jar   ゲーム（LWJGL の Linux x64 の native 入り）
  game/assets/  game/project.json
  jre/            Temurin の JRE
```

## run.sh がすること

| 物 | どうするか |
|---|---|
| 書く物（`saves/`・`debug/`・ログ） | `~/.local/share/<名前>/` に置く。解いた場所は読むだけ（`assets/`・`project.json` はそこから symlink） |
| ログ | `~/.local/share/<名前>/logs/run.log`（1 つ前は `run.prev.log`）。ゲームモードでは端末が見えないので、落ちた時はまずここ |
| X11 / Wayland | X11 にそろえる（`DISPLAY` があれば `WAYLAND_DISPLAY` を外す）。`FGE_WAYLAND=1` で Wayland |
| LWJGL の native | `~/.cache/<名前>/lwjgl/` に解く（`/tmp` が noexec の機械で落ちないように） |
| java の旗 | `make run` と同じ（`-Xss32m -XX:MaxRAMPercentage=50`）。足すなら `FGE_JAVA_OPTS` |

## Deck に置いて遊ぶ

1. tar.gz を Deck へ運ぶ（USB・`scp`・デスクトップモードのブラウザ）。
2. デスクトップモードの Konsole で解く:
   ```sh
   mkdir -p ~/Games && tar xzf internet_dungeon-<コミット>-linux-x64.tar.gz -C ~/Games
   ~/Games/internet_dungeon-<コミット>-linux-x64/run.sh      # まずここでウィンドウが出るかを見る
   ```
   zip や FAT の USB を通すと実行権限が落ちる。その時は `chmod +x run.sh jre/bin/*`。
3. Steam を開き「ゲーム」→「ゲーム以外の物をマイライブラリに追加」→「参照」で `run.sh` を選ぶ（ファイルの種類を「すべて」に）。
4. ゲームモードへ戻り、ライブラリの「ゲーム以外」から起動する。

## 実機で確かめる項目

Mac では Linux の JRE を流せないので、下は実機でしか分からない。

| 項目 | 見る所 | 駄目な時 |
|---|---|---|
| 起動する | デスクトップモードで `run.sh` → ウィンドウが出る | `logs/run.log` の最後 |
| ゲームモードで全画面 | Gamescope がウィンドウを画面へ広げる。960×600×2 のウィンドウも Deck（1280×800）も 16:10 なので黒帯は出ない見込み | ウィンドウが小さいまま・黒い時は、画面の写真と `logs/run.log` を持ち帰る |
| デスクトップモードのウィンドウの大きさ | 1920×1200 のウィンドウが 1280×800 の画面からはみ出す見込み | 全画面へ切り替える口はゲームの側（engine の `setFullscreen`） |
| 音が鳴る | 効果音と曲 | OpenAL Soft（jar に入っている）が PipeWire の pulse 口を使う。`ALSOFT_DRIVERS=pulse` を試す |
| コントローラー | 十字・A・B が反応するか | Steam Input が Xbox の形のパッドとして見せる。反応しなければ Steam のコントローラー設定でキーボードの割り当て（矢印・Z・X） |
| セーブが残る | 1 日進めて終了 → 起動して「つづきから」 | `~/.local/share/<名前>/saves/` |
| 60fps で動く | 戦いの演出・パズルの連鎖 | `FGE_JAVA_OPTS=-XX:+UseZGC` を試す |
| Steam から起動しても落ちない | デスクトップモードの Konsole では出るのに、Steam から開くと出ない時 | Steam が足す `LD_LIBRARY_PATH` のライブラリを JRE・LWJGL が先に読んでいるかもしれない。起動オプションを `LD_LIBRARY_PATH= %command%` にして試す |
| 終わり方 | ゲームの終了・Steam ボタンからの終了で戻れる | |

## ウィンドウなしで中身だけ確かめる

描き出しの入口を渡すと、ウィンドウを開かずに jar と assets が読めるかを確かめられる（Linux の仮想環境や SSH 越し）。

```sh
FGE_ENTRY=SceneRender.one SHOT=title FGE_JAVA_OPTS=-Djava.awt.headless=true ./run.sh
# → ~/.local/share/<名前>/debug/title.png
```
