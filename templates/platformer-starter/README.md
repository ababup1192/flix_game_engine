# platformer_starter — 手触り重視のプラットフォーマー見本

コヨーテタイム完備の身体で 3 つの面(丘・洞窟・塔)を駆け、コインを集めて旗まで走る。
「Celeste の手触り × 初代マリオの構成 × この エンジンの Doc 駆動」の教科書。
ロジックは src/ + test/ 合計 2,972 行(上限 3,000 行 — `make loc` で実測できる)。
全部読める大きさを保つのがこのリポの決まり(AGENTS.local.md の設計制約)。

## 遊ぶ

```bash
make run     # ウィンドウが開く。←→(A/D)で歩き、Space/↑ でジャンプ、↓ で一方通行から降りる
             # B(Shift/X)を押しっぱなしで B ダッシュ — 最高速が上がり、離しても勢いが残る
make debug   # 保存即反映(watchFile)+ F1 一括リロード + F8 付きで起動
```

倒し方は踏みつけだけ。押しっぱなしで踏むと大きくバウンドする。
ハート 3 つ。落ちたらチェックポイント(ランタン)へ戻る。

## 読む順(コードの地図)

1. **`src/Main.flix`** — 配管の全体像。init / update / view と、GPU タイル層・視差レイヤ・HUD の繋ぎ。
2. **`src/World.flix`** — 全状態と 1 tick の進行(冒頭 doc に 1 周の地図)。
3. **`src/Physics.flix` + `src/Player.flix`** — 気持ちよさの正体。軸分離の当たり・
   可変ジャンプの導出式・コヨーテ / 先行入力 / 角の許し。**このゲームの読みどころ**。
4. **`src/Stage.flix` + `src/StageDoc.flix`** — rows(文字格子)→ 面。文字の対応表は Stage 冒頭。
5. **`src/View.flix` + `src/TerrainLayers.flix` + `src/LightGrid.flix`** — 絵。
   静的地形は GPU タイル層(1 draw call + マスごと照明 tint)、動く物だけ毎フレーム。
6. `src/Enemies.flix` / `src/Controls.flix` / `src/Theme.flix` — 敵 3 種・入力・色。

エンジン部品の逆引きは `make module Q=<やりたいこと>`（目次は engine リポの `docs/module-index.md`）。

## JSON をいじる(保存すると即反映)

| ファイル | いじると何が変わるか |
|---|---|
| `assets/player.motion.json` | ジャンプの重さ・歩速・ゆるし(コヨーテ秒など)+ カメラの追従。**まずここで遊ぶと楽しい** |
| `assets/platformer.rules.json` | 収支と進行(コイン/踏み/旗の点・ハートの数・clear と over の幕の長さ) |
| `assets/stages.stage.json` | 面そのもの(1 文字 = 1 タイル)。`#` 土 `X` 石 `=` 一方通行 `~` 動く床 `!` 消える床 `o` コイン `S` バネ `T` 松明 `c` チェックポイント `G` 旗 `P` 開始 `a/b/z` 敵 |
| `assets/enemies.enemy.json` | 敵のテンポ(速さ・索敵・発射間隔) |
| `assets/platformer.theme.json` | 色(空・主役・地形。#RRGGBB で上書き) |
| `assets/px.sprite.json` | ドット絵そのもの(文字格子) |
| `assets/ui.text.json` | 画面に出る文言(CLEAR! / GAME OVER) |
| `project.json` | ゲームの題・ウィンドウの大きさ・フォント |

壊れた JSON でも既定値で必ず起動する(fail-open)。

どれも `*.schema.json` を持ち、`project.json` の `editor.resources[]` に宣言してあるので
Studio(エディタ)のフォームからも編集できる。ドット絵の意味色キーの実色は
`assets/px.palette.json`(`make palette` の生成物)が Studio に教える —
**色を変えたら作り直す**(`make render-all` の前に自動で走る)。忘れると編集画面だけ仮色になり、
実機と配色が食い違う。

## 検証

```bash
make test     # ルール(手触り・収支・ギミック)と Doc 橋渡しのテスト
make playtest # bot に通しで遊ばせて「走れるか・詰まらないか」を測る
make render-all # 決定的な 4 場面を gallery/ に描き出す(title / hill / cave / tower)
make render SHOT=cave # その場面だけ debug/cave.png へ描き出す(複数は SHOT="hill cave")
make reference-check    # 描き出した絵を reference/ とバイト比較(リグレッション検知)
make reference-update   # いまの gallery を新しい基準として更新する
make probe    # 面の読み込み・1 tick・1 フレームの部品数を測る(重い一手の切り分け)
make loc      # src/ + test/ の合計行数(上限 3,000 行)
```

`make probe` は「固まった」の原因が絵かロジックかを数字で切る道具。
**1 フレームの部品数**が桁で違う面があれば、そこがカクつきの正体。
予算(1 フレーム 16ms)に対して OK / NG が出る。

手触りの数値(コヨーテ秒・バウンド高)も収支(コインの点・ハートの数)も、テストの
期待値は `player.motion.json` / `platformer.rules.json` の既定値から導くので、
バランス調整でテストは壊れない。**コードに直書きの数値を置かない**のがこの見本の芯 —
「いつ加点するか」の規則だけがコード側にあり、その規則が読む数値は全部 Doc に出ている。

### 面をいじったら `make playtest`

面白さは主観だが、**主観が壊れている面は数字にも出る**。`make playtest` は
「右へ走り、前が壁・穴・敵なら跳ぶ」だけの下手な bot に通しプレイさせて、
クリアできるか / 最高速で走れていた時間の割合 / 前進が止まった最長秒 /
見せ場(コイン・敵・跳躍)の空き時間 / ジャンプ回数を測る。
bot が通れる面は人間なら必ず通れる — ハマりと単調さの下限保証として使う。
合否の閾値は `src/render/Playtest.flix` の `goals()` に 1 箇所だけ置いてある。
