# ゲームパッド（キーへの読み替え・Start と Select・機種）

ゲームパッド（Xbox 配置）の入力は、エンジンがキーへ読み替えて `Frame#down` / `justPressed` に入れる。
ゲームはキーだけを見ればよく、パッドのための分岐は要らない。読むのは 1 台目のパッドだけ。

## 読む元（SDL3・GLFW）

- **パッドは SDL3（LWJGL の `lwjgl-sdl`）で読む**（`render_gl/src/SdlPad.flix`）。ウィンドウと GL は GLFW のまま。
  SDL3 の対応表は GLFW より広く、Steam なしの Steam Controller（2 代目を含む）も HIDAPI で直に読む。
- **Steam なしの Steam Controller は、本体がキーボード・マウスのふりをする（lizard mode: A = Enter・B = Esc・十字 = 矢印）。**
  GLFW だけではこれを gamepad として読めず、ゲームにはキーしか届かない（案内もキーボードの絵のまま）。
  SDL3 はパッドを開いている間、lizard mode を止める。
- SDL3 を始められない時（native が読めないなど）は stderr に 1 行出して GLFW で読む。GLFW ではつながっている
  joystick を全部見て、1 台目の gamepad を使う。
- 使うパッドが変わるたび、stderr に `[gamepad] …` の行が出る（名前とベンダー。GLFW の時は全部の joystick と GUID）。
  パッドが効かない時はまずこの行を見る。

## ボタン → キー（`GamepadMap.table`）

| パッド | キー | よくある使い道 |
|---|---|---|
| 十字キー・左スティック（0.5 より倒す） | `Up` `Down` `Left` `Right` | 移動・カーソル |
| A | `Z` | 決定 |
| B | `X` | 戻る・取り消し |
| X | `M` | |
| Y | `C` | |
| LB | `LeftShift` | |
| **Start**（Menu） | **`Menu`** | メニュー・ポーズを開く |
| **Select**（Back / View） | **`Backspace`** | |

- **1 ボタン = 1 キー。** 1 ボタンを 2 つのキーへ渡すと、1 押しで 2 つのキーが同じフレームに新しく押された扱いになり、
  決定が 2 連発する。
- **Start は `Enter` ではない（0.59.0 から）。** 前は Start が `Enter` を押していて、`Enter` を決定にしているゲームでは
  Start と決定を見分けられなかった。Start でメニューやポーズを開くなら `Key.Menu` を見る
  （キーボードでも開けるよう、`Key.Escape` 以外のキーと並べる。例: `pause = P :: Enter :: Menu`）。
- `Escape` はどのボタンにも渡さない（マップの上でゲームの終了を呼ぶ）。
- 表に無いボタン（RB・トリガー・スティックの押し込み・Guide）はキーにならない。

## 触ったか・機種（`Frame#padTouched`・`Frame#padKind`）

読み替えた後のキーからはキーボードと見分けられないので、案内に出すボタンの絵を替える判断はこの 2 つを読む。

| 欄 | 値 | 中身 |
|---|---|---|
| `padTouched` | `Bool` | パッドのどこかにいま触っているか |
| `padKind` | `GamepadMap.PadKind.Generic` | Xbox 配置の一般のパッド |
| | `GamepadMap.PadKind.Steam` | Steam Input を通したパッド（Steam Deck・Steam Controller・Steam が仮想にしたパッド） |
| | `GamepadMap.PadKind.Unknown` | つないでいない・gamepad として読めない |

- 機種は USB のベンダー（Valve = `28de`）とパッドの名前から決める（SDL3 は `GamepadMap.kindOfVendor`、
  GLFW は GUID から `GamepadMap.kindOf`）。パッドをつないだ時に 1 回だけ読む。
- Steam Input は多くのパッドを Xbox 配置の仮想パッドに見せるので、Steam から起動したゲームでは
  Switch や PlayStation のパッドでも `Steam` になりうる。ボタンの絵は Xbox 配置で出してよい。
- ウィンドウなし（`App.trace`・描き出し）は `Unknown`。flow の `pad` は `Generic`。
