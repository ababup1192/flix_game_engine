# HD-2D の町（hd2d-starter）

昼の南欧の港町を、旅の 3 人で歩き回るテンプレート。タイルの地図（1 文字 = 1 マス）から 3D の地面・段・水路・建物を組み、
木・街灯・人・広場の小物をドット絵の板として立てる（HD-2D）。カメラは水平のまま写す範囲を下へずらして見下ろす（`Camera3d.lensShift`）。

## 遊び方

- `make` … ウィンドウが開く。矢印キーか WASD で歩く（2 つ押しで斜め）・パッドの左スティックでも歩ける・Esc で終了の確認
- ブラウザ版（`bin/fge export-web`）は、スマホでは画面の左下のスティック（`web.virtualPad.stick`）で歩く。頁の `?shadow=1024&dof=0&post=0` で描き方を軽くできる
- 先頭は通れないマス（建物・水路・木・柵・屋台など）の四角に沿って滑り、仲間 2 人は先頭の通った道をなぞる。建物の北の、足元が屋根に隠れるマスは通れない

## 作り（src/）

| ファイル | 中身 |
|---|---|
| `World.flix` | 遊びの状態（先頭・向き・道・カメラの遅れ・時刻・終了の確認）と次の状態を作る規則。画面は `Screen` の enum |
| `Res.flix` | 描く元（Doc・読み込んだ絵・組んだ町・通れるマスの格子・カメラのレンズ）。絵は起動の時だけ読み、Doc の読み直しは読んだ絵から組み直す |
| `Controls.flix` | キーとスティック → 動く向き・Doc の読み直しの表 |
| `View.flix` | 3D の場面 1 枚（町・隊列・小物）・ポストプロセス・終了の確認の窓。頭に層の並びと絵の下限の受け持ち |
| `TownMap.flix`・`TownDecor.flix` | 地図と小物の Doc を読む |
| `TileMap3d.flix`・`Faces.flix` | 地図から面と板を組む（Godot の GridMap・Unity の Tilemap に当たる） |
| `TownScene.flix`・`TownLook.flix`・`TownCamera.flix` | 1 コマの 3D の場面・昼の見た目の Doc・レンズと目の位置 |
| `CollisionGrid.flix`・`FollowTrail.flix`・`Walkers.flix`・`Facing.flix` | 通れるマスと円の滑り・隊列の道・歩きの帯のコマ・向き |
| `Shots.flix`・`render/SceneRender.flix` | ギャラリーの場面（title・start・avenue・quit）と CPU の描き出し |
| `web/WebMain.flix` | ブラウザの入口 |

## Doc（assets/）

| Doc | 中身 |
|---|---|
| `town.map.json` | 地図（地面・高さ・マスの形・置く物・建物・地図の外） |
| `market.decor.json`・`animals.decor.json` | 広場の小物と NPC |
| `explore.json` | 歩きの手触り・隊列・立ち始め・カメラ・ぶつかり・描き方の重さ |
| `town.look.json` | 昼の見た目（カメラの角度・太陽と影・空と霞・ポストプロセス） |
| `explore.keys.json` | キーの割り当て |

素材の出典は `assets/CREDITS.md`。音のファイルは入っていない（足し方は `AGENTS.local.md` の早見表）。
