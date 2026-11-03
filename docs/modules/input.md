# 入力・当たり・物理

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| ホイールの生 delta を目盛りにまとめる | InputMap（wheelSteps） |
| 重なり判定・物理（2D） | Collision / Physics2D |
| 3D の部屋を一人称で歩く（壁で止まる・段差を上る・坂・落ちる・扉に押される） | CharacterBody3d.moveAndSlide（箱は engine の CollisionShape3d.boxOfNode → CollisionWorld3d.build・docs/scene3d.md の「一人称で歩く」） |
| 当たり判定を JSON で宣言する | HitDoc + Hit |
| キーが押された瞬間を取る | InputEdge |
| 複数キーを 1 つの操作にまとめる（WASD と矢印の両対応） | InputMap（実例: `templates/game-starter/src/KeysDoc.flix`） |
| 素の中心＋幅高の箱どうし・点×箱の重なりを聞く（接するのは外） | Hit.boxBox / pointBox |
| テスト用の入力フレームを組む | App.frameOf |
| 一人称でマウスを動かして視点を回す（FPS のように・カーソルを窓にキャプチャする） | App.withMouseCapture + frame#mouseDelta（下の「一人称の視点」） |
| 右クリック・中ボタンを読む | frame#mouseClickedButtons（押した瞬間）・frame#mouseButtons（押している間）。mouseDown・mouseClicked は左だけ・flow は `mouse=right` |
| 窓がフォーカスを失った・取り戻したのを知る | frame#windowFocused |
| 遊んだ通りに再生して、最初に食い違ったフレームを指す | Flow.Record（DEBUG の起動で自動・`make flow FLOW=debug/flow-record/latest.flow`・指紋は App.withFingerprint） |
| 実機の記録が画面なしの再生と同じ World になるか（決定性の門） | engine の `make determinism`・World 全体の要約は WorldHash（`expect world=`）・外の値は App.withWorldSummaryMask（docs/flow.md） |
| ギャラリーの 1 枚と同じ World から実機で開く | App.withShots（`<ゲーム>/src/Shots.flix`）+ `SHOT=<場面> make run`（docs/flow.md） |
| e2e のテスト・動画の手順を 1 行 1 手で書いて画面なしで流す（待ちは問いが立つまで・失敗は行番号つき） | Flow（App.withFlow の表・`make flow FLOW=e2e/x.flow`・`bin/fge flow check`。実例: `templates/tidepool-starter/e2e/level1.flow`） |
| でたらめなキー・マウス操作で「どう遊んでも崩れない決まり」を確かめる（性質テスト）・画面なしで実機と同じ経路を流す | PropertyTest（forAll / generate / firstBroken）+ App.trace（実例: `templates/tidepool-starter/test/TestTrace.flix`） |

## モジュール 1 行紹介

- **CharacterBody3d** — 3D の部屋を一人称で歩く体（Godot の CharacterBody3D・Unity の CharacterController）。足元の点と足の着き方だけを持ち、向き・足音はゲームが持つ。壁は向きのある箱。
- **Physics2D** — 物理を「積分・検出・反射・分離」の 4 つの純関数に切り出して合成する。
- **Collision** — たくさんの物体の中から、実際に重なっている組を見つけて返す。
- **Hit** — JSON で宣言した形（円・箱の列）で「触れているか」だけを聞く照会専用の判定。
- **HitDoc** — 当たりの形の宣言（hitbox.json）を読む codec。欠け・間違いは位置付きで断る。
- **InputEdge** — キーが「今まさに押された瞬間」か「押しっぱなし」かを見分ける。
- **InputMap** — 生のキーを「操作の意図」へ写す表。同じ意図に複数キーを並べられる（WASD と矢印の両対応など）。
- **Flow** — 1 行 1 手の手順書（e2e/<名前>.flow）を実機と同じ 1 フレームの経路（App.traceFrame）で流す。e2e のテスト・動画の手順・遊んだ記録の再生（docs/flow.md）。
- **Flow.Parse** — flow の読み手。全部の行を読み、読めない行を行番号と近い名前の案つきで全部返す（Go の bin/fge flow check と同じ文面）。
- **Flow.Cli** — flow を画面なしで流す headless の入口の中身（ゲームの E2e.play・E2e.vocab が呼ぶ。make flow / flow-vocab）。
- **Flow.Record** — 遊んだ記録を flow と同じ文法で書く（DEBUG の起動が debug/flow-record/latest.flow へ。F8 のチケットに record.flow の写し）。
- **WorldHash** — 値（World）の中身を丸ごと辿る SHA-256（record は欄の名前の順・Lazy と JDK の物は見ない）。記録の最後の `expect world=` と、食い違った時の部分ごとの字（partsOf）。
- **PropertyTest** — 種で決まるでたらめな入力の列（キー・マウス・ホイール）を App.traceFrame で流し、決まりが崩れた最初の種とフレームを探す（property-based testing）。

## 一人称の視点（マウスを窓にキャプチャする）

FPS のようにマウスを動かした量で視点を回すときは、カーソルを窓にキャプチャする（Godot の `MOUSE_MODE_CAPTURED`・Bevy の `CursorGrabMode::Locked`）。

- **宣言**: `App.withMouseCapture(w -> w#looking)` で毎フレーム「キャプチャしたいか」を World から返す。App は値が変わったフレームだけ当てる。系の中で `Platform.Window.setMouseCaptured` を呼ばない
- **動き**: キャプチャしている間は矢印が消え、窓の端で止まらずに `frame#mouseDelta`（design px・右と下が正）に出る。yaw と pitch はこれに感度を掛けて回す。
  `frame#cursor` はキャプチャした時の位置で止まり、`mouseMoved` は偽になる（UI のホバーを狂わせない）。左ドラッグの差（`cursor#x - 前の x`）で回さない
- **慣習**: 窓をクリックしたらキャプチャ、Esc で放す。放した状態の Esc で終わる（確かめる）。Esc を放すのに使うなら `App.quitWhen` で既定の「Esc のエッジで終わる」を外す。
  放すと矢印はキャプチャする前の位置に戻る（GLFW の決まり。止めていた `frame#cursor` と同じ所）
- **フォーカス**: 窓のフォーカスが外れると OS が放し、戻るとキャプチャし直す（App は触らない）。`frame#windowFocused` で分かる。
  キャプチャを切り替えた拍・フォーカスが戻った拍の `mouseDelta` は 0（跳んだ量で視点が回らない）
- **F8**: 止めている間は放し（矩形を囲える）、再開した拍に宣言を当て直す。Studio の「止める」も同じ道を通る
- **感度と上下反転は Doc へ**（`walk.kind.json` など）。調整のたびにビルドしない
- **台本とテスト**: flow の `at=` と PropertyTest の cursor の動きは、前のフレームとの差が `mouseDelta` に入る（画面なしでも視点が回る）。CPU の描き出しは 0

