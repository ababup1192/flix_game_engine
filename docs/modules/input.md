# 入力・当たり・物理

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| ホイールの生 delta を目盛りにまとめる | InputMap（wheelSteps） |
| 重なり判定・物理 | Collision / Physics2D |
| 当たり判定を JSON で宣言する | HitDoc + Hit（実例: `templates/platformer-starter/src/World.flix`） |
| キーが押された瞬間を取る | InputEdge |
| 複数キーを 1 つの操作にまとめる（WASD と矢印の両対応） | InputMap（実例: `templates/game-starter/src/KeysDoc.flix`） |
| 素の中心＋幅高の箱どうし・点×箱の重なりを聞く（接するのは外） | Hit.boxBox / pointBox |
| テスト用の入力フレームを組む | App.frameOf |
| e2e のテスト・動画の手順を 1 行 1 手で書いて画面なしで流す（待ちは問いが立つまで・失敗は行番号つき） | Flow（App.withFlow の表・`make flow FLOW=e2e/x.flow`・`bin/fge flow check`。実例: `templates/tetris-starter/e2e/clear_four.flow`） |
| でたらめなキー・マウス操作で「どう遊んでも崩れない決まり」を確かめる（性質テスト）・画面なしで実機と同じ経路を流す | PropertyTest（forAll / generate / firstBroken）+ App.trace（実例: `templates/tetris-starter/test/TestTrace.flix`） |

## モジュール 1 行紹介

- **Physics2D** — 物理を「積分・検出・反射・分離」の 4 つの純関数に切り出して合成する。
- **Collision** — たくさんの物体の中から、実際に重なっている組を見つけて返す。
- **Hit** — JSON で宣言した形（円・箱の列）で「触れているか」だけを聞く照会専用の判定。
- **HitDoc** — 当たりの形の宣言（hitbox.json）を読む codec。欠け・間違いは位置付きで断る。
- **InputEdge** — キーが「今まさに押された瞬間」か「押しっぱなし」かを見分ける。
- **InputMap** — 生のキーを「操作の意図」へ写す表。同じ意図に複数キーを並べられる（WASD と矢印の両対応など）。
- **Flow** — 1 行 1 手の手順書（e2e/<名前>.flow）を実機と同じ 1 フレームの経路（App.traceFrame）で流す。e2e のテスト・動画の手順・遊んだ記録の再生（docs/flow.md）。
- **Flow.Parse** — flow の読み手。全部の行を読み、読めない行を行番号と近い名前の案つきで全部返す（Go の bin/fge flow check と同じ文面）。
- **Flow.Cli** — flow を画面なしで流す headless の入口の中身（ゲームの E2e.play が呼ぶ。make flow / flow-vocab）。
- **PropertyTest** — 種で決まるでたらめな入力の列（キー・マウス・ホイール）を App.traceFrame で流し、決まりが崩れた最初の種とフレームを探す（property-based testing）。
