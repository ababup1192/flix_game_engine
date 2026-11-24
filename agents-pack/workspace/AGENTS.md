# Flix_GE のワークスペース

**この案内は、ワークスペースのフォルダ（ゲームの外）で作業する時だけの物。**
ゲームのフォルダの中で作業している時は、このファイルを無視し、そのゲームの AGENTS.md だけに従う
（Claude Code は上のフォルダの CLAUDE.md も読むので、ゲームの中でもこのファイルが見えることがある）。

このフォルダには Flix_GE（Flix 製の 2D ゲームエンジン）で作ったゲームが並ぶ。人はブラウザのダッシュボード（`fge dashboard`）から、ここで Claude を開く。日本語で会話する。

## fge の場所

`fge` が PATH に無い時は絶対パスで打つ（`FGE_HOME` を決めている時はその下の `bin/fge`）。

- macOS・Linux: `~/.flix_ge/bin/fge`
- Windows: `%USERPROFILE%\.flix_ge\bin\fge.exe`

## ゲームを作る

1. テンプレートの一覧: `fge new --list`
2. 作る: `fge new <フォルダ名> --template <テンプレート名>`（このフォルダで打つ。`<フォルダ名>/` ができ、ダッシュボードのゲームの一覧に出る）
   - **`fge new` は長い**（初回は engine と JDK の約 300 MB を取り、作るだけで 2〜3 分）。Bash の既定の時間切れ（2 分）に当たるので、
     timeout を 600000 にするか、background で流して終わりを待つ。進み具合は 1 行ずつ出る。
   - 名前が決まりに合わない時は、理由と `--name` の例が出るので、それに従って打ち直す。
3. 作り終えたら、このフォルダでは続けない。`fge open <フォルダ名> --prompt "<続きの指示>"` を打ち、ゲームのフォルダの Claude Code を
   新しい端末で開いて渡す。続きの指示は、人の頼みのうち残った物（例:「bin/fge run で動くか確かめて、次にやることを教えて」）。
4. 人に「新しい端末で続けてください」と言って止まる。`fge open` が開けなかった時は、端末に貼る 1 行が出るので、それを人に見せる。

ゲームの作業をこのフォルダの Claude でしないのは、ゲームの .claude/settings.json の hooks と skills が、起動したフォルダの物しか読まれないため。

## engine

- 手元の版と Release の最新: `fge engines`
- 取る: `fge engines install <版|latest>`・消す: `fge engines remove <版>`（使っているゲームがあれば止まる）
- `~/.flix_ge/engines/` の下は直さない（読み取り専用。同じ版の全部のゲームが変わる）。
- ここで `make new-game` を打たない（`fge new` が engine を取ってから流す）。

このファイルは `fge dashboard` と `fge engines install` が、手元の最新の engine の物で写し直す。書き足してもいずれ上書きされる。
