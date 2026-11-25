# 夜の校舎（retro3d-horror-starter）

1990 年代後半の家庭用 3D ゲーム機のような、粗い低ポリの一人称ホラーのテンプレート。木造 3 階建ての夜の校舎を歩き、
3 人の人物と話し、鍵を拾って閉じた部屋を開ける。PS1 風の描き方（`Scene3d.withPsx`）とテレビのにじみ（`PostStack.withCrt`）、
部屋の明るさを頂点の色にベイクした校舎、足音が主役の合成の効果音までを作り込んだ作例。

## 遊び方

- `make` … ウィンドウが開く。WASD / 矢印で歩く・Q/E と ←→ で向き・R/F で見上げる・見下ろす・Shift で走る・
  Space で話す / 拾う / 調べる・I で持ち物・M で紙の地図・クリックでマウスを視点に取り込み Esc で放す / 終了の確認
- `make web` … ブラウザ版を build/web へ書き出す（下の「ブラウザで遊ぶ」）

## コマンド

| コマンド | 何をするか |
|---|---|
| `make run`    | ゲームを起動する（ウィンドウが開く） |
| `make debug`  | 保存即反映(watchFile)と F8 を有効にして起動 |
| `make check`  | 型検査だけ走らせる（一番速い確認） |
| `make test`   | テストを実行する |
| `make render-all`   | ギャラリーの PNG を全部描き出す（CPU で描く・決定的） |
| `make render SHOT=corridor` | その場面だけ `debug/corridor.png` へ描き出す（場面の一覧は Makefile の SHOTS） |
| `make reference-check`  | 描き出した絵をリファレンス画像と比べる |
| `make reference-update` | いまの gallery をリファレンス画像として更新する |
| `make sfx`     | 効果音を全部合成し直して `assets/sfx/` へ書く（`src/render/SfxRender.flix`） |
| `make gallery-sounds` | 効果音の波形と高さの図を `debug/sounds.png` に描く |
| `make bundles` | 校舎の glb を束（`assets/school/bundle/`）へまとめ直す |
| `make video FLOW=e2e/video/corridor.flow OUT=corridor` | 歩く所の動画を `debug/video/` へ撮る（ffmpeg が要る） |
| `make flow FLOW=e2e/walk.flow` | 手順書（1 行 1 手）を画面なしで実機と同じ道に流す |
| `START="at x=-4.5 z=2 yaw=0" make run` | 始まりの登録簿（`src/Starts.flix`）の場面から起動する |

## ブラウザで遊ぶ

```sh
make web        # 校舎の束を作り直し（make bundles）、build/web へ書き出す（起動の予算 16 秒を超えたら止まる）
"$ENGINE/bin/py3" -m http.server 8000 --bind 127.0.0.1 --directory build/web
# → http://127.0.0.1:8000/ を開いて「タッチして開始」を押す（見終えたらサーバーを Ctrl-C で止める）
```

- 操作はデスクトップと同じ。スマホは画面の十字キーと「調べる」「持ち物」「地図」「走る」
- 起動で取るのは 1 階の建物と昇降口のまわりの小物（`bundle/floor1.glb`・`entrance.glb`）と足音だけ。1 階のほかの小物・人物・空気と戸の音・2〜3 階（`upper_a.glb`・`upper_b.glb`）は押した後に届いた物から足す（project.json の `web.deferred`）。
  2 階へ上がる時に上の階がまだ届いていなければ、届くまで階段で待つ。人物は届くまで見えず、話しかけられない
- 好きな所から開く: `http://127.0.0.1:8000/?at=1&x=-24.04&z=-1.5&yaw=180`（中央の階段の前）。重さは `?fge=fps`、4G の届き方のまねは `?fge=4g`
- 公開の前の門: `bin/fge web-check build/web --browser`

## 作り（src/）

| ファイル | 中身 |
|---|---|
| `Game.flix` | App の組み立て（実機・flow・テスト・描き出しが同じ物を使う）。冒頭にゲームループの全体像 |
| `World.flix` | 遊びの状態（足元・向き・歩いた歩数・訪れた部屋・持ち物・開けた戸・会話）と次の状態を作る規則 |
| `Res.flix` | 描く元（Doc・校舎の形・読み込んだ glb）。Doc を読み直した時だけ替わる |
| `Controls.flix` | キー → 歩き・Doc の読み込みと読み直しの表・ブラウザで届くまで待つ所 |
| `View.flix`・`SchoolView.flix`・`CastView.flix`・`ItemsView.flix`・`MapView.flix` | 3D の場面と HUD（部屋の名前・字幕・紙の地図・持ち物） |
| `School.flix`・`Layout.flix`・`Blocks.flix`・`Bundles.flix` | 校舎の配置の表（部屋・階段・壁の当たり・灯り）と束の読み込み |
| `Cast.flix`・`Items.flix`・`PaperMap.flix`・`RoomCaption.flix` | 人物と会話・持ち物と鍵・紙の地図・部屋の名前 |
| `Sounds.flix` | どの音をいつ鳴らすか（足音・戸・風・拾う）と続く音（空気・時計）・音の通り道 |
| `render/SceneRender.flix`・`render/SfxRender.flix`・`render/VideoRender.flix` | ギャラリーの描き出し・効果音の合成・動画 |
| `web/WebMain.flix` | ブラウザの入口 |

## Doc（assets/）

| Doc | 中身 |
|---|---|
| `night_school.look.json` | 暗さ・霧・月明かり・非常口の灯り・PS1 風の描き方・字幕の見た目 |
| `walk.kind.json` | 歩きの手触り（速さ・走り・1 歩の長さ・頭の揺れ） |
| `sound.kind.json` | 音の大きさと距離での聞こえ方（足音が主役） |
| `characters.kind.json` | 人物の置き場所と話しかけ方（台詞は `talk/night.yarn` → `bin/fge yarn build` で `talk/dialogue.json`） |
| `items.kind.json` | 拾える物と鍵のかかった部屋 |
| `player.keys.json` | キーの割り当て |
| `night_school.scenes.json` | ギャラリーの場面の題と一言 |

それぞれに Studio 用の schema（sections 方言）が並び、`project.json` の `editor.resources` が宣言している。

## 校舎を作り替える

校舎（`assets/school/school_floor*.glb`・`prop_*.glb`・`layout.json`）は Blender で作って書き出した物。
作り替えたら同じ形の `layout.json`（部屋・階段・壁の当たり・灯り・小物の置き場所）と glb を書き出し、`make bundles` で束を作り直す。
`tools/placeholder_layout.py` は箱だけの仮の校舎の `layout.json` を書く（glb が無い間はゲームが箱を絵として描く）。

## AI エージェント向け指針の配布（sync-agents）

エンジン側で `make sync-agents GAME=/path/to/このゲーム` を実行すると、エンジン共通の
エージェント指針（agents-pack/AGENTS.core.md）とこのゲームの `AGENTS.local.md` を連結した
`AGENTS.md` が生成され、共通スキルが `.claude/skills/` にコピーされます。`AGENTS.md` は
生成物なので直接編集せず、ゲーム固有の原則は `AGENTS.local.md` に書いて再 sync してください。

## クレジット

`CREDITS.md`（効果音はコードで合成した音・フォントは Kaisei Tokumin / SIL OFL 1.1）。
