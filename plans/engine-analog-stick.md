# ゲームパッドのアナログスティックをゲームへ渡す — 計画

## なぜ

今のエンジンは、ゲームパッドの左スティックを上下左右のキーへ読み替えてゲームへ渡す（`GamepadMap`・`LwjglInput.padInputDown`）。
倒した角度と強さは捨てられるので、パッドでは 8 方向にしか動かせない。3D の箱庭（`~/Documents/flix_ge_workspace/lamplighter`）で
「360 度の向きへ、倒した強さの速さで歩く」「右スティックでカメラを回す」をするには、スティックの生の値が要る。

汎用性: 3D の歩き・2D の見下ろし・ツインスティックの照準・カメラの操作のどれにも要る値で、Unity の `Gamepad.leftStick`・
Godot の `Input.get_vector`・Bevy の `GamepadAxis` に当たる。キーへの読み替えは今のまま残す（メニューと 2D の 8 方向はそれで足りる）。

## 足す物

`App.Frame` に 2 欄:

```flix
leftStick = Vec2.Vec2,   // 左スティックの倒した向きと強さ。長さ 0..1・右が +x・上が +y（画面の座標と違い、上が正）
rightStick = Vec2.Vec2   // 右スティック。同じ決まり
```

- **遊び（デッドゾーン）を外した値**を渡す。丸い遊び: 長さ `d` が `deadzone`（既定 0.18）以下なら (0, 0)・超えたら
  `(d - deadzone) / (1 - deadzone)` へ伸ばし直して向きは保つ。長さは 1 で頭打ち。軸ごとに切らない（斜めが強くなる・十字に吸い付く）。
- パッドをつないでいない・読めない時は (0, 0)。
- 1 台目のパッドだけ（今の `LwjglInput.Pad` と同じ）。

## 通り道（`mouseDelta` と同じ道をなぞる）

`bin/fge refactor usages "App.Frame#mouseDelta"` と `bin/fge refactor search consumeMouseDelta` で出る所が、足す所の一覧:

| 所 | 足す物 |
|---|---|
| `Platform.Input`（engine の effect） | op `gamepadSticks(): { left = Vec2.Vec2, right = Vec2.Vec2 }`（読むだけ。消費しない） |
| `GamepadMap`（engine・純粋） | `stickOf(deadzone, rawX, rawY): Vec2.Vec2`（遊びを外す式。y は「上が正」へ直す。GLFW と SDL の生の軸は下が正） |
| `render_gl/LwjglInput` | `padAxis` で左（軸 0・1）と右（軸 2・3）を読み、`GamepadMap.stickOf` を通して op の答えにする。SDL3 と GLFW の両方 |
| ブラウザ版の入力（`web/` の Platform の handler と `fge-web.js`） | `navigator.getGamepads()` の 1 台目の `axes[0..3]` を同じ式へ。パッドの無い端末は (0, 0) |
| テストの偽物の handler（`Platform.Input` を張っている所の全部） | (0, 0) を返す |
| `App.Internal.Runner.readFrame` | `Platform.Input.gamepadSticks()` を読んで Frame の 2 欄へ |
| `App.frameOf`（Frame を組む所） | 既定は (0, 0) |
| `Flow.advance`・`App.Internal.InputScript`（手順の再生） | 記録の値を Frame へ戻す |
| `Flow.Record.frame`（遊んだ記録） | 値が (0, 0) でないコマだけ ` lstick=x,y` ` rstick=x,y` を書く（`look=` と同じ形）。読む側（`Flow.Parse`）も対に |
| flow の手の語 | `stick left 0.7,0.7 0.5`（左スティックを (0.7, 0.7) に 0.5 秒倒す。`hold` と同じ長さの書き方・`release stick left` で戻す）を足すかは、`Flow.Parse` の手の語の作りを見て決める。難しければ記録と再生（`lstick=`）だけでよい |

`left`・`right` のキーへの読み替え（`GamepadMap.table`）は変えない。スティックを倒すと、今までどおり上下左右のキーも押される。

## 決まり

- 系（update）で読んでよい値（遊んだ記録に残る・再生で同じ値が来る）。`diagnostics` のような「記録に残らない値」ではない。
- 記録の精度: 小数 4 桁に丸めて書き、読む（実機と再生で同じ値になるよう、**Frame に入れる前に丸める**）。
- `Frame` に欄を足すので、`{ .. | frame }` でなく字で全部の欄を書いている所は止まる。エンジンの中は直す。ゲームと
  テンプレートで止まる所があれば移行メモ（`docs/migrations/<版>.md`）に書く。

## テスト（engine_world・engine の該当するパッケージで）

1. `GamepadMap.stickOf`: 遊びの中は (0, 0)・遊びの縁のすぐ外は長さがほぼ 0・いっぱいで長さ 1・斜め 45 度の向きが保たれる・y の符号（生の -1 = 上 → +1）。
2. 記録と再生: `leftStick = (0.5, -0.25)` の Frame を `Flow.Record` で書き、`Flow.Parse` → 再生で同じ値の Frame が系へ届く。
3. (0, 0) のコマは記録の行に `lstick=` が出ない（既存の記録の字が変わらない）。
4. 偽物の handler で `readFrame` が 2 欄を埋める。

## 文書

- `docs/modules/input.md` に逆引きの 1 行（「パッドのスティックで 360 度に動かす → `frame#leftStick`」）
- `docs/api-digest.md` を作り直す（`make api-digest`）
- `agents-pack/AGENTS.core.md` の早見表に 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本（AGENTS.md の「新しい仕組みを入れたら」）
- `docs/flow.md` に `lstick=` / `rstick=` の説明

## やらない事

- 2 台目以降のパッド・トリガーの押し込みの量・振動
- キーボードやマウスからスティックの値を作る事（それはゲームの側の仕事。箱庭では、押して引く仮のスティックをゲームが持っている）
