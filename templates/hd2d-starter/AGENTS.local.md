# このゲーム固有の設計原則

（ここに、このゲームだけの原則を書く。共通の作法はエンジン側の AGENTS.core.md が
sync で AGENTS.md に入るので、重複して書かない。書いたら engine 側で
`make sync-agents GAME=<このフォルダ>` を再実行して AGENTS.md に反映する。）

## この画面の画風

- 昼の南欧の港町の石畳を、斜め上から水平のカメラで見下ろす（HD-2D: 3D の町に 2D のドット絵の板を立てる）。主役は旅の 3 人の小さな姿と、石と漆喰の町に落ちる太陽の影。
- 色は 3 つ: 下地＝砂岩とクリームの石灰岩（#e2d8c4）、主役＝旅の 3 人の外套のティール（#3f8f86）、差し色＝朱（#d0583c・屋台の日除けと花と風船だけ）。
  光＝淡い金（`town.look.json` の sunColor #fff2db）・影＝空の青紫（ambient #262b3d に霞の #e0ebfa が掛かった色。#84a0dc 前後）。
- やらないこと: 影を黒にしない（太陽の影も足元の影も、一番暗い所で青紫まで。夜の場面にしない）。

## どこを直すか（早見表）

| したいこと | 直す所 |
|---|---|
| 地面・高さ・木や街灯・建物を足す | `assets/town.map.json`（1 文字 = 1 マス・字の意味は `map.schema.json`） |
| 広場の屋台・NPC・動物を足す | `assets/market.decor.json`・`assets/animals.decor.json`（新しい絵は `project.json` の textures にも足す） |
| 歩く速さ・隊列・カメラの引き・立ち始めのマス | `assets/explore.json` |
| 太陽・影・空・霞・ポストプロセス | `assets/town.look.json` |
| キーの割り当て | `assets/explore.keys.json`（パッドとスマホの画面のスティックは `frame#leftStick` で同じ口） |
| スマホで重い | `explore.json` の quality（影の地図・ぼけ・ポストプロセス）。ブラウザは頁の `?shadow=1024&dof=0&post=0` で試せる |
| 新しい画面（表紙・会話）を足す | `src/World.flix` の `Screen` に case を足し、`Controls.step` と `View` を match で分ける |
| 音を足す | 曲や効果音のファイルを `assets/` に置き、`project.json` の sounds に登録して `Game.app` に `App.withSustained`（BGM）・`App.withAudio`（効果音）を足す（engine の `docs/audio.md`） |

- 地図や小物の Doc は保存すると走っているゲームにその場で映る（読めない形で保存した時は前の町のまま 1 行言う）。新しい絵の名前を書いた時だけは起動し直す。
- 描き出し（`make render` / `render-all`）は CPU で描くので 1 枚 10 秒ほどかかる。影の地図は描き出しだけ 2048 に落としている（`src/render/SceneRender.flix`）。
