# 対応表 — web の技法 → エンジンの部品

## 目次

- グロー / bloom
- 放射グラデ（光だまり・暗くするオーバーレイ・vignette）
- 線形グラデ（空・水・空気色）
- 残像 / トレイル
- パーティクル
- 動く暗背景（霧・雲・水）
- コースティクス
- 画面揺れ
- 白フラッシュ / hitstop / スロー
- イージング / バネ
- 数の数え上げ・ルーレット
- 演出の時刻表（拍の並び・音の拍）
- ドット絵キャラ
- タイル地形
- 光の帯 / ハードシャドウ
- 角丸パネル / 枠
- UI の文字（枠に収める）

根拠: 6 ジャンル（弾幕STG / 森ARPG / レース / ホラーADV / 海中パズル / 雪山ローグ）を
canvas の狙い絵 → 実エンジンのヘッドレス生成（静止画 + 完全ループ GIF）で再現した実験。
以下の対応と癖はすべてその実験で実証・発見された物。`[新]` は 0.13.0 から。

| web の技法 | エンジンの部品 | 実証済みの作法・癖 |
|---|---|---|
| グロー / bloom | `DrawCmd.BlendMode.Add` + 柔らかい円 | `Render.glowAt` は同心円 24 輪・減衰カーブ固定。大半径は継ぎ目が見える → 半径違いを数枚重ねてディザする |
| 放射グラデ（光だまり・暗くするオーバーレイ・vignette） | **`Render.lightAt`（Add の明かり）/ `Render.darkAt`（Multiply の翳り）**が一次部品（組み込みテクスチャ 1 枚・アセット不要・GL と生成で同一画素）。面ごと塗るなら `ShaderDoc` の `radial` / `radialAspect` **[新]** + Gradient 面（SoftRaster が画素評価） | 円形の明かり・翳りはまず `lightAt` / `darkAt`（radius = 見た目半径 px・strength 0..1。光マップのレンダーターゲット（Pass）に Add で集めて Multiply で本編に掛けるのが定石）。`radial` は uv 空間なので非正方形 rect では楕円に歪む → **`radialAspect` に aspect を渡す**。0.12.1 以前は無いので、正方形 rect を大きく置いて回避する。`Light` は RadialGlow で生成したテクスチャ前提で、texturePath 無しの生成では使えない |
| 線形グラデ（空・水・空気色） | **`Render.vgrad(size, {top, bottom}, z)` / `Render.gradPolygon`** **[新]**（頂点色つきポリゴン） | 実装済み・SoftRaster も対応済み（`gradSample`）。**1px 色帯の積みは禁止** — 部品数がそのまま生成時間に乗る。任意方向・4 頂点別色は `gradPolygon`、縦のニ色は `vgrad` |
| 残像 / トレイル | 過去位置に減衰 α で再描画 | **動き専用** — 静止画では 1px 未満のズレで写らない |
| パーティクル | `Fx` / `FxDoc`（時刻の純関数） | burst / drift / gravity。状態を持たないので巻き戻し・生成と相性が良い。`FxDoc.parseWith(palette, json)` でテーマ色を `@名前` で引ける |
| 動く暗背景（霧・雲・水） | `ShaderDoc`（`fbm` / `fbmTile` / `warp` / `worley`） | Worley は等方スケールのみ（横長面で潰れる → CPU で組んで小矩形の Add 斑に退避）。**スクロールで継ぎ目を出したくない時は `fbmTile` [新]**（period 指定の周期 Fbm）。ループを閉じるだけなら `time` ノードで逆位相 2 層の「呼吸」でもよい |
| コースティクス | Worley の `f2mf1` | ShaderDoc で形が届かない時は CPU 計算 + 2×2px の Add 斑 |
| 画面揺れ | `CameraRig`（減衰ノイズ） | **動き専用**。生成では world 層だけ translate（UI・雨・HUD は外に出す） |
| 白フラッシュ / hitstop / スロー | 白矩形の α を減衰。止める・遅くするのは **`TimeScale`**（`gameDt` でゲームの時計ごと遅くし、光や揺れは `realAt` の実秒で動かす） | **動き専用** — 静止画に入れるなら α を実機の 1/3 程度に（常時の靄に見える）。dt を自前で 0 にして止めない（実時間が引けず動き出せなくなる） |
| イージング / バネ | `EcsTween.Easing` / `Curve` | 補間は `EcsTween.Easing`（`Linear` / `EaseIn` / `EaseOut` / `EaseInOut` の 4 つ。これ以外の名前は無い）。周期・揺れ・減衰バネは `Curve`（`sine` / `tri` / `arch01` / `pieces` / `dampedSpring`）。`Float64.exp` は標準にある（探せば大抵ある、が教訓） |
| 数の数え上げ・ルーレット | `EcsTween.steppedInt(start, end, easing, u)` | 前のフレームと値が変わった拍が「1 つ移った」拍（刻みの音を鳴らす所）。EaseOut でだんだん遅く止まるルーレット |
| 演出の時刻表（拍の並び・音の拍） | `Timeline` のクリップ（`toClips` / `startOf` / `startedBetween` / `durationOf`） | 重なってよい拍を Doc の秒から組む。音は「前のフレームと今の間に始まったクリップ」= `startedBetween` で鳴らす。全体の秒は `durationOf`（自前で足し算しない） |
| ドット絵キャラ | `PxSprite`（文字格子） + **`PxShade`** | scale は整数のみ。伸縮の中間コマは `PxSprite.runs` の矩形を中心周りに伸縮して回避。legend の色に α は持てない（Add 前提で色に織り込む）。**平らに塗った絵を読み込み直後に `PxShade.shadeDoc` へ通す** — ふち光・接地影・ディザ・粒が乗り、走行中の負荷は増えない |
| タイル地形 | `TileLayer` / `DualGrid` / `Terrain` | タイル角の丸めは明色の欠き取り（チャンファ）で DualGrid 風に。質感は `Material`（粒・きらめき・鱗・泡・発光・染み）を重ねる |
| 光の帯 / ハードシャドウ | 半透明ポリゴン（`Light` / `Shadow`） | 影は光源と反対へ伸ばす。長さは距離の逆数で減らすと自然 |
| 角丸パネル / 枠 | `DrawCmd.BoxStyle` / `Render.outline` / `outlineA` **[新]** | 半透明の枠は `Render.outlineA`（α を渡す）。`Render.outline` は枠 α=1 固定なので、0.12.1 以前は Item.Box + BoxStyle を直組みしていた |
| UI の文字（枠に収める） | `Text.measure`（採寸）/ `UiExtract.measureTexts`（world-entity UI の採寸口）/ `RichText.wrapLinesBy`（maxWidth で文字境界折り） | **文字を枠に入れるときは先に `Text.measure` で採寸してから枠を決める。** 枠が先に固定なら「折り返す(wrap)・fontSize を落とす・文言を縮める」のどれかを**明示的に選ぶ**（黙ってはみ出させない）。UiDialog 本文の折りは `RichText.wrapLinesBy`(maxWidth) が本番稼働中。ui.json の text ウィジェットは `"wrap": "auto"`（自分のレイアウト矩形の幅で折る）か数値（折り返し幅 px）、`"fit": true`（収まらなければ fontSize を段階的に縮める）を宣言すれば部品側で折れる（既定は off）。engine を直呼びするなら `Text.setWrapWidth` |
