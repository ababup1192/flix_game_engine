# ドット絵・アニメの昇格計画(PxSprite / Timeline / Journey / Fx / ポスト面)

flix_ge_village の序章開発で確立した描き方・動かし方をエンジンへ昇格する計画。
**方針: 新しい仕組みを併設しない。既存機構に乗る。** 調査の結果、新設は
PxSprite の Doc と Journey(村の `Prologue.routeAt` の一般化)の2つだけで足りる。

## 既存機構との対応(調査済み)

| やりたいこと | 乗り先(既存) | 新設 |
|---|---|---|
| ドット絵のデータ化 | Doc 作法(JsonCodec/fail-open/watchFile/studio フォーム) | PxSpriteDoc(新) |
| 1体1クアッド描画 | `Render.Item.Sprite`(region/tint/flipH/V)+ `render_gl/src/Sprite.flix`(instanced・実測 N=5000@60fps) | 無し |
| 実行時アトラス生成 | `render_gl/src/Font.flix` の bakeFontAtlas と同型 | RGBA 版アップロード関数1本(~30行) |
| 区間アニメ | 村 `Prologue.routeAt` が原型 | Timeline/Journey(engine_world へ一般化) |
| 煙・雪・葉・木くず | `Fx`/`FxDoc`(fx.json) | emitter 種の追加のみ(新モジュール禁止) |
| 風揺れ | `Sway` | 無し |
| 夜のとばり・ビネット・寒色 | `Render.shaderFill` 全画面1枚+blend Multiply | ShaderDoc.Field に `radial` 程度 |
| ギャラリー/リファレンス画像 | HeadlessRender + make render-all/reference-check/reference-update | コンタクトシートのターゲット追加 |
| エディタ編集 | editor_server の Preview* の並び | PreviewSprite 追加 |
| 性能計測 | bench/sprite_stress(A/B背中合わせの流儀) | シナリオ1本追加 |

## PxSprite Doc(*.sprite.json)

- 文字格子+**意味色キー**(実色でなくテーマで解決)+名前付きコマ+anchor(足元原点)。
  AI はテキスト格子を直接読み書きでき、人間はエディタのマス目クリックで編集できる。
- 凡例(legend)はファイルに1個でコマ間共有。未定義文字は透明(fail-open)。
- コマは既存 Doc の rows 慣行に合わせる(studio のフォーム自動化に乗る)。
- flipX 時の anchor 鏡映は draw 側の規約。スケールは整数のみ(NEAREST 前提)。
- **tint の両立**: テーマ切替は低頻度 → テーマ別に生成し分け(watchFile で再生成、
  fontAtlas と同じライフサイクル)。寒色 mix・夜などの連続変化は `Render.Item.Sprite` の tint(乗算)
  とポスト面で。パレット LUT シェーダは作らない。
- 一点物の背景(家・山)はコード矩形のまま。全部をスプライト化しない
  (生成のバイト一致の機械的検証を守るため)。

## Timeline / Journey

- `Timeline`: 区間 {name, dur} の列+純サンプラ `at(t) → Option[{name, u}]`。
  逐次構造なので区間の重複バグ(村で起きた「遅出と夕暮れの重なりでキャラ消失」)が
  構造的に消える。尺は Doc から与える。
- `Journey`: 脚 {from, to, speed} の列 → `at(t) → {pos, walking, done}`。
  **ルールは done を、絵は pos を、同じ戻り値から読む**(API 契約で強制)。
  村の「帰宅ワープ」の再発防止はこの一元化で行う。
- 決定性: State には開始時刻だけ持たせ、進行は持たせない(Anim/Fx と同じ
  「時刻の純関数」原則 — リプレイ/Worldline がそのまま効く)。
- テストは「合計尺」「境界で Done」「到着時刻=距離/速度」だけ。絵はテストしない。

## フェーズ(1フェーズ=独立 revert 可)

- **R1 Timeline/Journey**(小): engine_world に新規+テスト。村の routeAt と
  if 閾値連鎖を置換し、村の bench(スナップショット)green で完了。
  - **✅ 完了(2026-07-21)**: `engine_world/src/Timeline.flix` / `Journey.flix` 新設
    (+TestTimeline/TestJourney、module-index 追記)。村側は routeAt(夕暮れ帰宅)・
    きのみ/薪/拾いもの/柿の往復の区間分けを Timeline に、流れ者の入場
    (arrived/pos/stepFrame が同じ Sample を読む)と夜明けの戸口→担当範囲を Journey に
    置換。食事(eaterItems)・施し(giverItems)は絶対閾値の芝居で、逐次減算化すると
    浮動小数の演算順が変わるため残置(コード中にコメント)。ルール側の尺
    (tripTotal 等)も同じ理由で数式のまま。検証: 序章ギャラリー debug/*.png
    26枚+all.png 全バイト一致、make check / test(204)/ bench(スナップショット 10)green。
  - **配布の暫定**: 村の `lib/github/ababup1192/flix_game_engine/0.7.1/*.fpkg` を
    ローカル `engine_full/artifact/engine_full.fpkg` への symlink に差し替えた
    (monorepo の sync-engine-full と同じ流儀。GitHub への push/release はしない)。
    **次回リリース(0.7.2)で正規の fpkg に差し替えること**。リリース版 0.7.1 の
    バックアップは同ディレクトリの `flix_game_engine-0.7.1.fpkg.release-backup`。
- **R2 PxSprite**(中): Doc+draw(第一段は box 列出力で生成バイト一致移行)→
  第二段でアトラス化(RGBA アップロード+PNG 共用で GL/SoftRaster 同一ソース)。
  PreviewSprite、コンタクトシートのギャラリー。
  - **✅ R2a 完了(2026-07-21)**: `engine_world/src/PxSpriteDoc.flix`(文字格子+legend
    +名前付きコマ+anchor、全フィールド fail-open・未定義文字は透明)と
    `PxSprite.flix`(draw = box 列出力。横連続の同色キーは 1 矩形へ結合 — 格子は
    セル重なりを持たないので被覆と最終色は結合前と同一)。flipX の anchor 鏡映
    (ax → w-1-ax)は draw 側の規約。TestPxSprite 7本(Doc橋渡し3+anchor/flip/
    面積保存/fail-open)、module-index・docs/sprite.schema.json 追記。engine_world
    テスト 634 green。配布は R1 と同じローカル symlink(make sync-engine-full)。
  - 村側: `assets/prologue.sprite.json` に villager(walk0/walk1/crouch —
    crouch は先頭に空行を足した同じ格子)・child・rabbit・berry・kaki・mushroom・
    mushroomPile・meat・riceBale・branch・woodBundle・woodEnd を、現行 box 列を
    読み解いて写経。流れ者は体色キー(body→wandererBody)、野のきのこの赤/茶傘は
    cap キーの resolver 差し替えで格子を共有。z の内部段差(woodBundle の z+1/z+2、
    riceBale の z+1)は単一 z へまとめた — 格子が「後勝ち」を色で織り込むため画素は
    不変(render_gl の stable sort が同 z の列順を保つ)。Doc は PrologueDoc.load が
    spritePath() から同居読みし、watchFile(Main)→ Controls.reloadPrologue の
    一本道に乗せた。家・蔵・山・川など一点物は触っていない。
    検証: 序章ギャラリー 27枚(26+all.png)全バイト一致、make check /
    test(204)/ bench(スナップショット 10)green。PreviewSprite・アトラス化・コンタクト
    シートのスナップショット化は R2b。
  - **✅ R2b 完了(2026-07-21)**: アトラス化+PreviewSprite+コンタクトシート+A/B 計測。
    - **アトラス化**: `engine_world/src/PxSpriteAtlas.flix`(純関数 — Doc×resolver →
      side/regions/ARGB 画素。棚詰めは RenderFont のシェルフ規則を `shelfPack` に関数化。
      Font 側は SDF 生成と癒着しているため据え置き — 規則は shelfPack のテストが pin)。
      GL 出口は `RenderTexture.loadTextureFromPixels`(+`updateTexturePixels` — watchFile
      再生成の差し替えはフレーム先頭のシステムからこれを呼ぶ。テーマ別生成し分けは
      resolver 差し替えで生成し直すだけ)。PNG 出口は既存 `SoftRaster.writeRadialPng` に
      `pixelAt` を渡す — **GL と headless が同一 Baked を読む**。
    - **両モード**: `PxSprite.draw`(box 列・既定 — 村の生成バイト一致を守る)と
      `PxSprite.drawQuad`(regionRect 付き Item.Sprite 1 個・opt-in)。App の view 経路は
      `Render.draw` → `Render.drawWith(getTextureInfo)` に差し替え(regionRect 無しは
      同一 Drawable = 挙動不変)。検証: SoftRaster で両モードを生成して全画素バイト一致
      (editor_server/test/TestPxSpriteRaster — 非反転/flipX とも diff 0)。
    - **PreviewSprite**: `editor_server/src/PreviewSprite.flix` + POST /preview/sprite。
      mode="frame"(1 コマ拡大)/"sheet"(全スプライト×全コマ×themes — sprite 指定で
      1 体に絞る = クリップ再生は静止コマ列で代替)。themes は [{name?, colors:{key:"#rrggbb"}}]、
      無いキーは決定的フォールバック色(fail-open)。返り値は既存 Preview の流儀
      (ok/png(base64)/width/height/sprites メタ/warnings/error)。特化ビューは状態を持たない。
    - **村のギャラリー**: SceneRender.prologue の末尾で debug/sprites.png(全スプライト×全コマ×
      2 resolver: villager 既定/wanderer 体色+赤傘)。c1_/c2_ 接頭辞を持たないので
      all.png には合流しない。**スナップショット化はまだしない(絵が動く時期のため)—
      安定後に代表場面+sprites.png をスナップショット昇格すること**。
    - **性能(bench/sprite_stress の BenchPx・同数背中合わせ)**: villager 6×10 で
      box 列 → 1 クアッド が N=500: 16.7→3.1ms / N=1900: 54.6→8.3ms(p99 11.2ms) /
      N=5000: 146.4→16.7ms。R3 予算(動的<2000・avg<8ms/p99<12ms)は 1 クアッドなら
      N=1900 で p99 内(avg は直前重区間の熱込みで 8.3ms)。box 列は数百体が上限。
    - 検証: engine 各パッケージ test green(engine_world 641 / editor_server 64)、
      村 make check / test(204) / bench(スナップショット 10) green、序章ギャラリー 27枚バイト一致。
      配布は R1/R2a と同じローカル symlink(make sync)。push/release なし。
- **R3 Fx+ポスト面+予算**(小〜中): fx.json に emitter 種追加、村の重ね矩形を
  shaderFill(Multiply)1枚へ、ShaderDoc に radial(Gen/Eval/Json の3面同時+一致テスト)。
  性能予算: 動的 PlacedItem < 2000/フレーム、frame avg < 8ms / p99 < 12ms。
  sprite_stress に box 列 vs 1quad の比較シナリオを追記。
  - **✅ 完了(2026-07-21)**:
    - **fx.json 方言拡張(新モジュール無し)**: FxDoc/Fx に `mode: "loop"`(常時系 —
      各粒が寿命ごとに生まれ直す。位相は粒ごとの乱数で分散・周回番号を種に混ぜて
      毎周別の個性・すべて t の純関数)、`spawn {w,h}`(発生源の広がり)、
      `accel {x,y}`(重力/風 — 位置は閉形式 ½at²)、emitter `seed`(決定的シードの
      上乗せ)、`parseWith(palette)`("@名前" の色キーを ui.json と同じ UiDoc.colorOf で
      解決)を追加。**既存 burst 文書はビット単位で不変**(新チャンネルのみ使用・
      既定値の加算は恒等 — TestFxVocab が pin。エンジン全 test green)。
      docs/fx.schema.json・module-index 追記。TestFxVocab 14本。
    - **村の置換は見送り(語彙のみ追加)**: 村の煙・雪・舞う葉・木くずは
      Vec2.sin の うねり位相(高さ依存)・Hash01 の固有チャンネル(85–88)・
      Palette.mix の粒ごと色式・Float64.floor のピクセル吸着を織り込んだ手組みで、
      Fx の乱数系統(splitmix64)とも数式(dir+speed の極座標)とも同値にならない —
      置換すればギャラリーのバイト一致が壊れるため、設計書の原則
      「語彙は追加・村の置換は同値になる物だけ」に従い村の描画は現状維持。
      (煙の筋 = loop+spawn+色キー、雪 = loop+spawn+accel、葉 = loop+accel(風)、
      木くず = burst+accel(重力) が新語彙の対応形 — 新規ゲームはこちらを使う。)
    - **radial(3面同時)**: ShaderDoc.Field.Radial({cx,cy}) = 中心距離場(Disk が
      マスクなのに対し生の距離 — Smoothstep でカーブを絞ってビネットに)。
      ShaderGen(`length((uv)-vec2(cx,cy))`)・ShaderEval(Vec2.length — 同じ式)・
      ShaderJson(kind "radial"・cx/cy 省略時 0.5)を同時に追加。TestShader に
      ノード GLSL スナップショット / CPU 代表点 / CPU⇔GLSL 同構造のパリティ /
      JSON 往復 GLSL バイト一致 / 省略時既定 の5本(engine 265 green)。
    - **ポスト面の headless 経路**: Render.blended が Item.Shader にも効くように
      +`Render.shaderSurfaces`(Shader 面の純データ抽出 — drawShaders の headless 版)、
      SoftRaster に `SurfaceCmd`/`renderWithSurfaces`(ShaderEval の画素評価 +
      blendPixel で z 合流 — mask は偶奇 point-in-polygon)、`HeadlessRender.renderPngWith`。
      既存 renderPng/renderToImage は署名不変(surfaces = Nil に委譲)。
    - **村の暗がりのポスト面化(見た目が変わってよい唯一の箇所)**:
      PrologueView.darkItems の「額縁ビネット(面12枚)+霧の柱(12本)+全画面とばり」を
      全画面1枚の shaderFill(blend Multiply・z=zDark)へ。ビネット =
      smoothstep(0.36, 0.86, radial)×0.30、霧(未開放時のみ・spec 名を分けて GL の
      プログラムキャッシュも分岐) = smoothstep(U:0.708→1.0)×smoothstep(V:0.30→0.36)×0.38、
      とばり = maxDarkness × max(0, -sin(2πt/dayLen))(Night.rawNight と同式)を
      **uTime からシェーダー内で組む — spec が時刻に依らず一定なので GLSL の
      再コンパイルはテーマ/開放状態の変化時だけ**。描き出しは SceneRender.shootPro
      (shaderSurfaces + renderPngWith)で GL と同じ数式(ShaderEval)を生成する。
      目視確認済み: 面の縞・額縁の継ぎ目が消え、角へ滑らかに沈むビネットと
      右肩上がりの霧のグラデになった。夜は Normal 重ねから Multiply になり
      「夜色へ引っ張る」→「夜色で沈める」に変わって窓明かりが映える。
    - **ギャラリー差分**: debug/ 27枚中、c1_01..c2_10 の26枚が暗がりの差分で変化
      (全場面にポスト面が乗るため — 差分はこの1系統のみ)、sprites.png はバイト一致。
      スナップショット(本編10枚)は経路を触っていないので全バイト一致(bench green)。
    - **性能予算の確定(動的 PlacedItem/フレーム — SceneRender.shootPro の機械計測)**:
      | 場面 | 動的 items | 静的(毎フレーム描かない) |
      |---|---|---|
      | 第1章 min(c1_08 凍える夜) | 683 | 2441 |
      | 第1章 max(c1_16 芽ぞろい) | 840 | 2441 |
      | 第2章 代表(c2_01 春) | 1151 | 2441 |
      | 第2章 max(c2_05 蔵パネル) | 1408 | 2441 |
      予算 < 2000/フレーム に **全場面で収まる**(最悪 1408・余裕 ≈30%)。
      frame 時間は R2b の BenchPx(box 列 vs 1 クアッドの背中合わせ — sprite_stress に
      追記済み)より、box 列でも N≈800〜1400 は avg < 8ms 圏内
      (N=500: 16.7ms は box 列 6×10 スプライト換算 = 矩形数十個/体の値。村の動的 items は
      「矩形1個 = 1 item」の数なので実負荷は N=1900 の 1 クアッド 8.3ms より軽い)。
      予算超過なし — 対策不要。将来 2000 に迫ったら PxSprite.drawQuad(opt-in)へ
      切り替えるのが第一手(R2b 実測で 6.6 倍)。
    - **検証**: エンジン全パッケージ test green(engine 265 / engine_world 655 /
      engine_tools 34 / editor_server 64 ほか)、村 make check / test(204) /
      bench(スナップショット 10)green。配布は R1/R2 と同じローカル symlink(make sync)。
      push/release なし。
  - **昇格完了。次はゲーム側のスナップショット昇格**(序章の代表場面 + sprites.png を
    絵の安定後にスナップショットへ — R2b の記録どおり)。

## studio 統合の原則(総合体験)

特化画面をポン置きしない。**すべての Doc 種は「汎用フォーム」と「特化ビュー」の
2面を持ち、同じファイル・同じ選択状態を共有する**(特化ビューは独自状態を持たない —
常にファイルが正。watchFile の一本道に両面がぶら下がる)。

- 特化ビューは、その Doc の**本来の表現**に一致させる: スプライト=マス目、
  テーマ=色板、fx=動く粒、配置 rows=シーンの上(ドラッグで x,y が書き変わる)。
- Doc 間の連結が総合体験の肝: スプライトの色キーは theme を解決して表示し、
  キーから該当色へジャンプできる。シーン上の物からフォームの行へ逆引きできる
  (preview_hitbox の矩形メタの逆引き)。テーマの色変更は開いている全ビューに即反映。
- PreviewSprite は「スプライト専用エディタ」ではなく、この規約の1適用例として作る。

## リスク

- ShaderDoc 語彙追加は Gen/Eval/Json の3面同期必須(片手落ちでスナップショット崩壊)。
- アトラス再ベイクは「フレーム先頭で差し替え」(fontAtlas と同じ)。
- Flix 0.71 の polymorphic effect 制約 — Timeline/Journey は純関数のみで影響なし。
