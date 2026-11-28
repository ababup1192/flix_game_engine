# 場面に入る時に engine が自動で先に作る — 計画（実装の前・人の了承は A のまま 11-26）

状態: 計画（git に入れない）。engine main 12eb615ea（v0.114.0）の上で書き直した。人の決め「推す答え A のまま」（11-26）。engine_world の拡張は了承済み。この版で新しく増えた相談: render_gl と engine_web の handler 2 つに Bool を足す所（3.5）と、ゲームが自動を断る口（8 節の 2）。
**事実**はソースの行（main 12eb615ea を `bin/fge refactor` で引いた）か実測。**推測**は「推測:」と書く。
スパイクの枝: `spike/auto-preload`（`bd5e5293f`・0.113.0 の上・worktree `/Users/abab/Desktop/fge-auto-preload`・main に入れない）。差分は `engine_world/src/App/Internal/Paint.flix` の 75 行と `bench/scene3d/src/First.flix` の 4 行（`FIRST=auto`）。数字は 2026-11-25・M4 Pro・WebGPU（PC は Dawn・ブラウザは Chrome 156 のヘッドレス）・起動し直して 3 回。**0.114.0 では測り直していない**（段の中で測り直す）。
レビュー: 1 回目 68 点（必須 9・望ましい 12）→ 直した。2 回目 84 点（新しい必須 3・望ましい 5）→ 全部をこの版で直した。

## 0. 結論

engine が毎コマ、View が返した 3D の場面に載った `staticGroup` を名前で集める。**まだ作り終えていない名前**があれば、
(1) その名前を描き手への先に作る宣言（`Scene3d.PreloadCmd`）へ自動で足し、(2) 済むまで場面からその集まりを外して design 全体を黒で覆う。
**作り終えた名前は宣言から外す**（その後の作り直しは描き手の `ensure` が前の控えを描きながら進める）。

- **ゲームから見える新しい pub: 0**（断る口を作るなら 2。8 節の 2）。形の変わる pub は層の中の 2 つ（`RenderPaintHandlers.handleDraw3d`・`RenderPaint.Internal.WebGpuPaint.handleDraw3d` に Bool 1 つ・3.5）と `App.Internal.Paint.TileCache`（欄 1 つ。ゲームからは見えない）。足す pub は `ZBand.autoPreloadCover()` 1 つ（z の値。3.3）。
- **ゲームが書く行: 0**（集まりがみな最初の場面に出るゲーム）。遊ぶ最中に初めて見せる階があるゲームは、暗転を起動の 1 回にまとめたければ今の `withPreload3d` の `groups`・`scenes` で先に宣言する（3 行。4 節）。
- 効き: テンプレート retro3d-horror-starter は書き足し無しで最初の階の止まりが暗転に入る。night_school は暗転の手書き（約 12 行）を消せる。血鱗（blood-scale）は `staticGroup` を使わない（住処は instances）ので効かない（4 節）。
- `MultiMesh3d`・instances・骨つきの人物は対象にしない（黒の間も描くので、黒が出たコマでは黒の下で組まれる。後で相談。5 節・7 節）。
- 見積もり: **engine 7〜8.5 時間＋測りとゲームでの確かめ 2 時間**（7 節）。

## 1. 何を解くか

0.113.0 の `App.withPreload3d` の `groups`・`scenes` で、night_school の最初のコマは 735 → 106 ms に下がった（人がゲームで測った値）。ただし night_school は今、`staticGroup` の分だけで次を書いている（night_school の作業中の版・engine 0.114.0）:

| 書いている物 | 在りか（`bin/fge refactor show` で確かめた） |
|---|---|
| 宣言 | `Game.app` の `App.withPreload3d({ groups = .., scenes = .., textures = .. \| App.preload3d(..) })`（3 行） |
| 先に作る集まりと場面 | `View.preloadGroups`・`View.preloadScenes`（6 行） |
| 暗転の判定と黒の板 | `View.isDarkWhileBuilding`（`Scene3d.isPreloaded(ctx#preload3d)` と、タイトルか読んだままの校舎か）・`View.buildingDark`（z 8 の箱）（8 行） |
| 場面から外す分岐 | `View.frame` の `dark` の 2 か所（2 行） |

書き方を誤ると明滅するか、初めての止まりが戻る（載せた集まりは、前の控えが無ければ `Render3d.StaticRows.ensure` がそのコマで全部作る）。人の決め: 「何も考えずに書いても止まらない」・解く順は ① 型と API の形 → ② linter → ③ docs の表・段は 1 つ。

テンプレート retro3d-horror-starter は `withPreload3d` を使っていない（`School.groupOf` が階ごとに `staticGroup("f<番号>", ..)` を作り、`SchoolView.sceneOf` が `School.visibleFloors` の階だけ載せる）。だから今は、最初の階と、階段室に近づいて上下の階が初めて載ったコマで止まる。

## 2. 比べた候補（0.113.0 の上で測った・判断は変わらない）

bench/scene3d の `FIRST=1`（宣言なしで 30 コマ目に `staticGroup` を初めて載せる）・`COUNT=300 SHAPES=137 MATS=8 VERTS=600`。PC は `frame#dt` の最大・ブラウザは `fgeStats` の 1 コマの CPU の最大。

| 候補 | ゲームが書く行 | engine の行 | 新しい pub | PC 最悪のコマ | ブラウザ cpu 最悪 | 誤って書けるか |
|---|---|---|---|---|---|---|
| 宣言なし | 0 | — | — | 61.0 / 62.6 / 72.0 ms（split 47〜58） | 56.8〜58.8 ms | — |
| withPreload3d（`FIRST=preload`・0.113.0） | 約 20 | — | — | 先に作る間 12.1〜14.8・載せたコマ 14.5〜17.7 | 3.6〜4.1 | key・外す分岐・黒を誤ると明滅か止まり |
| **A: View の答えから自動で拾う**（スパイク） | **0** | 約 55（スパイク）→ 推測 150〜200（3 節の直しを入れて） | **0** | 14.1〜23.8（6 回のうち 1 回 33.2 = preload の 1 コマが 31 ms。0.113.1 で直した超過） | **15.8〜16.0**（間隔 16.8 = コマ落ち無し） | 書く物が無い |
| C: 手助けの関数だけ（机上） | 約 7 | 約 10 | 3 | withPreload3d と同じ | 同じ | key と外し忘れはゲームに残る |
| B: 場面の切り替えの型に先払いを持たせる（机上で落とした） | 約 5 | Runner に手が入る | 2 以上 | — | — | — |

- A の暗転は PC で 5〜6 コマ（120 Hz で約 0.05 秒）。ブラウザは推測: 約 7 コマ（split 55 ms ÷ 8 ms）。CPU を 4〜6 倍遅くすると推測: 30〜45 コマ（0.5〜0.75 秒）。
- A の PC の最悪は、暗転の間の preload の 1 コマ（9.4〜15.3 ms）か、明けた後に初めて見えるコマの draw（11〜21 ms・描き先の形式の pipeline と bundle）。後者は 3.3 の「黒の下で 1 コマ描く」で黒の間へ移す。
- B を落とした理由: 作り終えるまで切り替えを止めると描き手の実時間が World に入り、遊んだ記録・再生・headless で切り替わるコマがずれる（docs/scene3d.md「進み具合は View だけで読む」と同じ理由）。
- C を落とした理由: 行は減るが、key の決め方と外し忘れがゲームに残り、決めの ① を満たさない。

## 3. 決めた形（A）

### 3.1 今の口（main 12eb615ea で確かめた物）

| 物 | 在りか | この計画での使い方 |
|---|---|---|
| 1 コマを描き手へ渡す所 | `App.Internal.Paint.submitPainted`（Paint.flix 455〜501）。呼び手は `renderFrame`（`Runner.paintAndPresent`・`Runner.resumingStep`・`Halt.pausedStep`・`Hitch.perfPaint`・`Paint.paintOnce`）と `Runner.paintGuarded`（待ちの道 `Runner.emitSlow`・`Runner.showSlow`。**スパイクの後に入った道**） | A はここ 1 か所に入れる。呼び手 7 つは全部ここを通る |
| 宣言を組む所 | `App.Internal.Paint.preloadCmd`（key に Doc の世代と変種を足す） | 自動の物をここで作った `Scene3d.PreloadCmd` に足す |
| 次のコマの ViewCtx の進み具合 | `App.Internal.Paint.progressFor`（`TileCache#preload3d` の key が宣言の key と違えば `{ done = 0, total = 1 }`） | **控えに入れる key は宣言の key のまま**（自動の分は入れない）。WhyNot: 自動の分を足した key を入れると、`progressFor` が宣言だけの key と比べて毎コマ「済んでいない」になり、`ViewCtx#preload3d` が済まなくなる（スパイクもこの形） |
| 宣言の型 | `Scene3d.PreloadCmd`（`key`・`instances`・`textures`・`variants`・`groups`・`scenes`） | 変えない |
| 描き手の preload | GL `Render3d.Preload.preload`・WebGPU `Render3d.WebGpuRenderer.preload`。key が前と同じなら上げ直さない。替われば `upload`（GL）・`preloadCmd`（WebGPU）で宣言の instances と textures を読み直し、WebGPU は `settled` を空に戻す。毎コマ `prepareGroups` → `Render3d.Preload.stepGroups` → `StaticRows.prepareAhead` を全部の組に呼び、1 コマの予算（`StaticRows.frameBudgetNs` = 8 ms）まで作る | 変えない。key が替わるのは「まだ作り終えていない名前が増えた・替わった」時だけにする（3.2） |
| 宣言の組 | `Render3d.Preload.groupPairsOf` = groups × scenes の全部の組。同じ名前が 2 つあれば `@preload-group-names` を 1 回知らせる | 自動の物は宣言の名前と重ねない・場面は版が違う時だけ足す（3.4） |
| key の知らせ | `Render3d.Preload.noteRebuild`: 300 コマの内に 30 回で `@preload-key`（文は「withPreload3d の key が…」） | 自動の止めはこれより早く（20 回）止める（3.6） |
| 同じ集まりかの見方 | `StaticRows.ensure`・`prepareAhead` は name・variant（`carriedKeyOf`）・**items の参照**（`Entry#items` が `IdentityHashMap`）・外した鍵と tint（`isSameGroup`）で控えを探す。`TestStaticRows.testRemadeGroupValueRebuilds`「同じ中身でも作り直した値は別の集まり（中身は比べない）」 | 前の版の「値そのもので見る」は誤り。engine_world は (items の参照, removed, tint) で見る（3.2） |
| 作り直しの間 | `StaticRows.ensure`: 同じ名前・同じ variant の控えがあって items だけ違えば、前の控えを描きながら 1 コマ 8 ms ずつ作る（`shownWhileBuilding`）。前の控えが無い時と、外した鍵か tint だけ違う時はそのコマで全部作る | 作り終えた名前を宣言から外せる根拠（3.2） |
| 控えの手放し | `StaticRows.sweep`: `GlStatic.idleFrames`・`WebGpuStatic.idleFrames` = 128 コマ描かなかった集まりを手放す | engine_world は 120 コマ見なかった名前を忘れる（3.2） |
| 黒の z | `ZBand.loadingBase()` = 1,900,000,000。波紋（`LoadingView.rippleOf`）の z はちょうどこの値・`LoadingIndicator.Custom` は「loadingBase から上」。HUD の範囲は 1,000,000,000〜+99,999,999 | 黒は `ZBand.autoPreloadCover()` = `loadingBase() - 1`（3.3） |
| 場面を包む物 | `Render.Item` のうち 3D の場面を持つのは `Scene3d` と `Clipped` だけ | 走査はこの 2 つ・本編の items と Pass の items |

### 3.2 名前ごとの状態

engine_world は `TileCache` に名前 → 状態の表を 1 つ持つ（`autoGroups`）。

| 状態 | 入る時 | 宣言に足すか | 黒 |
|---|---|---|---|
| 作っている（Building） | View に初めて出た名前・忘れた後にまた出た名前 | 足す（最新の値 1 つ。値が替われば差し替えて key を替える） | このコマに描き手が返した進み具合が済んでいなければ黒。**View から消えても済むまで状態は残り、黒も続く** |
| 作り終えた（Ready） | 進み具合が済んだコマ（宣言の全部が済んだコマ） | **足さない**（items の参照が替わっても足さない。作り直しは描き手の `ensure` が前の控えを描きながら進める） | 出さない |
| （無し） | Ready の名前が 120 コマ View に出なかった | — | — |

- 値が同じかは **(items の参照, removed, tint)** で見る（`StaticRows` の `isSameGroup` と items の `IdentityHashMap` に合わせる）。engine_world の中で `unchecked_cast(items as Object)` を参照で比べる。WhyNot: 中身を比べない — 中身の比べは省きたい仕事と同じ重さになる（`StaticRows` の WhyNot と同じ）。
- WhyNot（作り終えた名前を宣言に持ち続けない）: 持ち続けると、(a) Doc の読み直しや束の到着で参照が替わるたびに key が替わり、描き手が宣言の instances と textures を遊ぶ最中に読み直す（`Preload.upload` の WhyNot は「key が替わるのは起動と束の時だけで暗転の内」と置いている）、(b) 毎コマ全部の組に `prepareAhead` が走り、古い控えの `lastUsed` が更新され続けて捨てられない、(c) Studio でつまみを動かすたびに数えが進み 3.6 の止めに当たる、(d) 自動の物が増え続ける。外すと (a)〜(d) がまとめて消える。代わりに、置き場の上限で捨てられた後の止まりが戻る（3.7）。
- 120 コマで忘れる WhyNot: 描き手は 128 コマ描かなかった控えを手放す（`idleFrames`）。それより先に忘れれば、また出た時に「作っている」へ戻り、控えが残っていれば `prepareAhead` がそのコマで当たって済む（黒は出ない。3.3 の決めで済んだコマには黒を出さない）、手放されていれば黒の間に作り直す。忘れないと、手放された後にまた出た時、前の控えが無いので `ensure` がそのコマで全部作って止まる。
- 宣言（`withPreload3d`）にある名前は表に入れない（宣言に足さない）。ただし黒は同じ扱いで決める: **宣言の groups の名前が View に出て、このコマの進み具合が済んでいなければ、外して黒**（宣言の進み具合が一度済んだコマで、そのコマの宣言の名前を「済んだ名前」に入れ、以後は宣言の key が替わっても黒にしない。作り直しは描き手が前の控えを描きながら進める。**宣言の名前は忘れない**（宣言にある間は描き手が毎コマ `prepareAhead` で `lastUsed` を新しくするので控えが手放されず、忘れる理由が無い。忘れると、束で key が替わって済まない間に久しぶりの階へ戻った時に遊ぶ最中に暗転する）。
- 宣言の名前と版は、宣言の key ごとに `TileCache` に覚え、key が替わったコマだけ `groups`・`scenes` を読み直す（今の「描き手が key の替わった時だけ読む」約束を崩さない）。これで宣言を持つゲーム（night_school）も暗転の手書きが要らない（4 節の注・6.1 のテスト 4）。

### 3.3 毎コマの黒

| 条件 | 黒 |
|---|---|
| 「作っている」名前があり、このコマに描き手が返した進み具合が済んでいない | 場面（本編と Pass）からその名前の集まりを外し、design 全体へ黒（z `ZBand.loadingBase() - 1`） |
| 前のコマが黒で、このコマで済んだ | **集まりを載せて描き、黒はこのコマまで残す**（明けた後の初めてのコマに乗る draw の側の初回 = 描き先の形式の pipeline と bundle の積み、PC 11〜21 ms を黒の下へ移す）。次のコマで明ける |
| 前のコマが黒でなく、このコマで済んだ（小さな集まりが最初の 1 回の 8 ms の内で済んだ） | 黒を出さない（黒の無かった所に 1 コマだけ黒が出るのを防ぐ） |

- 進み具合は**そのコマに描き手が返した値**で決める（前のコマの値を使わないので 0 / 1 の明滅が起きない）。
- 黒の z: `ZBand.loadingBase() - 1`（HUD の範囲より手前・待ちの表示より奥）。WhyNot（`loadingBase()` ちょうどにしない）: 波紋が同じ z で、同じ z の中は種類の順（tiles → sprites → polygons …）で描くので、積む順で奥へ置けない。`ZBand` に `autoPreloadCover()`（= `loadingBase() - 1`）を 1 つ足す（docs/z-bands.md の「数の source of truth はコードの `ZBand`」に合わせる。engine の層の中の pub で、ゲームの書き方は変わらない）。docs/z-bands.md の表に 1 行足す。
- 黒は design の大きさの箱（余りの letterbox には出ない。余りは今まで通りの色）。
- 黒の下でも、集まりを外した場面（instances・ビルボード・MultiMesh3d）と 2D は今まで通り描く。

### 3.4 宣言に足す場面（groups × scenes の組を増やさない）

- 場面の版は engine_world で `Scene3d.Output`（色か奥行きの書き出し）と `Scene3d.preloadVariantKey(Scene3d.preloadVariantOf(場面))`（奥行きの書き出しは既定の版）から作る。WhyNot（`StaticRows.carriedKeyOf` を使わない）: render_gl にあって engine_world から呼べず、alpha to coverage は描き手しか知らない（coverage の版は描き手が `prepareGroups` の中で作る）。`Render3d.passVariantOf` = `shaderVariantOf` = `Scene3d.preloadVariantOf`（色の場面）・既定（奥行き）なので同じ答えになる（テスト 1 本で押さえる）。
- 自動の場面は、View が返した場面を `groups = Nil` にした物を版ごとに 1 つ（光・霧・psx の版が描く時と同じになる）。
- **宣言の場面に同じ版がある時は、自動の場面を足さない**（自動の集まりは宣言の場面と組になり、それで足りる）。宣言の場面に無い版の時だけ足す。WhyNot: `groupPairsOf` は groups × scenes の全部の組を作るので、足すと「宣言の集まり × 自動の場面」の描かない版の行まで作って控えに残る。型を変えずに防げるのはここまで。
- 限界: 宣言の場面に無い版を自動で足した時は、宣言の集まりのその版も作る（仕事と控えが増える。版の違う場面で描くゲームは、宣言の scenes にその版も入れれば消える。docs に 1 行）。

### 3.5 撮る文脈では先に作らない（スパイクの後に分かった事）

黒は描き手の実時間（8 ms の予算）で決まるので、同じ操作でも黒が明けるコマは回ごとに違う。撮りの門がこれを拾うと揺れる:

| 撮り | 通る道 | 今の作り |
|---|---|---|
| `make gl-capture-check`（既定の場面に `bench/scene3d:` がある・2 回撮って SHA を比べる） | 実機の窓（`FLIX_GE_FRAME_SHOT` と、既定は `FLIX_GE_FIXED_DT`。`DT=off` の時は固定しない）→ `Runner.paintAndPresent` | 黒を出すと揺れる |
| gallery・1 枚撮り | `GpuShot.shotOf` → `Paint.paintOnce` → `GlOffscreen.handle` / `GpuOffscreen.handleWebGpu` | 同上（描き手は GPU なので進み具合が途中の値になる） |
| ブラウザの撮る頁（`?fge=capture:<n>`・`webgpu-v1-check-web` は rpg-starter だけで今は当たらない） | `WebLayer.withWeb` / `WebLayer.Internal.WebGpuLayer.runPage`（`Screen#captureFrame`） | 同上 |
| VideoOut・headless（SoftRaster） | `App.Internal.Paint.drawPassPlan` か CPU の描き手 | 当たらない（`submitPainted` を通らないか、`noPreload` を返す） |

決め: **撮る文脈の描き手は、先に作る宣言を受けても何もせず `Scene3d.noPreload()`（済んでいる）を返す**（計画を持たない描き手と同じ答え）。engine_world は黒を出さず、集まりは今まで通り描いたコマで作る → 画素は今と同じ。
- 口: `RenderPaintHandlers.handleDraw3d(ahead: Bool, paint, f)` と `RenderPaint.Internal.WebGpuPaint.handleDraw3d(ahead: Bool, paint, f)`。`ahead = false` なら `preload3d` は `k(Scene3d.noPreload())`。
- 渡す所（6 か所・`refactor usages --callers` で数えた）: `LwjglLayer.withGl`・`LwjglLayer.Internal.WebGpuWindowLayer.runWindow` は `env#fixedDt` と `env#frameShotDir` がどちらも None の時だけ true。`GlOffscreen.handle`・`GpuOffscreen.handleWebGpu` は false。`WebLayer.withWeb`・`WebLayer.Internal.WebGpuLayer.runPage` は撮る頁（`captureFrame > 0`）で false。
- WhyNot（engine_world の `renderFrame` に Bool を足して切らない）: engine_world は dt の固定も撮る頁も知らない（どちらも render_gl と engine_web の中の値）。知らせる口を足すと pub が増え、`paintOnce` だけ切っても gl-capture の窓の道が残る。
- WhyNot（撮る文脈で予算を無くして全部作り切る形にしない）: `StaticRows.prepareAhead` の予算は render_gl の中の固定値で、外から替える口が要る。作り切っても画素は「描いたコマで作る」と同じ。
- 副作用: 撮る文脈では、宣言を読んで自分で暗転を描くゲーム（今の night_school）も暗転しなくなる。今もその暗転は実時間で決まり撮りが揺れていたので、揺れが消える方へ変わる（night_school の gallery の絵が変わりうる・ゲームのリポの仕事）。

### 3.6 止めと数え方

- 自動の止め: 「作っている」名前が増えた・値が替わって key が替わったコマが **300 コマに 20 回**に達したら止める。**Doc の世代（`tileCache#gen`）が替わったコマは数えない**（読み直しで全部の集まりを作り直すゲームの、Studio の調整を止めにしない）。
- 作り終えた名前は数えに入らない（3.2）。engine の bench/hd2d_town は 15 コマごとに同じ名前 `"settled"` の集まりを作り直す（`BuildVideo.regroupEvery`）が、作り終えた後なので数えない。毎コマ新しい名前を出す（名前に時刻を混ぜる）・作り終える前に毎コマ値を作り直す、の 2 つだけが当たる。
- WhyNot（30 回にしない）: 描き手の `@preload-key`（300 コマに 30 回）が先に鳴り、「withPreload3d の key」を直せという誤った文が出る。
- 止めた時の知らせ（1 回・`@auto-preload-off`）: 「staticGroup の名前か値が 300 コマに 20 回替わった — 名前に時刻を混ぜていないか・毎コマ作り直していないか（集まりは読み込みで 1 回作って Resources に持つ）。自動で先に作るのをやめ、描いたコマで作る」。止めた後も宣言（`withPreload3d`）は今まで通り効く。
- 毎コマの重さ: engine_world の走査は本編と Pass の items を 1 巡（`Scene3d` と `Clipped` だけ見る）と、名前の表の引き。集まりが無いゲームは何も足さない。描き手の側は、作り終えた名前を外すので `prepareAhead` を呼ぶのは「作っている」名前の数だけ（ふだんは 0）。推測: 1 巡は数 μs（段で毎コマの p50 を、名前が 50 個ある場面でも比べる）。

### 3.7 限界（docs に書く物）

- 黒が明けるのは宣言の全部が済んだ時（進み具合が 1 つの数のため）。全部の階を宣言で先に作るゲームで、宣言がまだ済まない間に新しい名前が出ると、その分も暗転が延びる。
- 遊んでいる最中に新しい名前が出るたびに黒くなる（PC 5〜7 コマ・ブラウザ推測 7 コマ・CPU 4〜6 倍で推測 30〜45 コマ）。区画を順に載せるゲームでは pop-in の方が向く（8 節の 2 の断る口）。
- Pass（鏡・ミニマップ）だけに出る集まりでも、design 全体が黒くなる。
- 「作っている」名前は View から消えても済むまで黒が続くので、階段室に近づいてすぐ引き返しても作り終えるまで黒い（CPU 4〜6 倍で約 0.5 秒）。点滅を止める代わりの代償。
- 作り終えた自動の名前は、約 128 コマ描かないと描き手が控えを手放し、次に出た時にまた黒くなる。避けたい集まりは宣言（`withPreload3d`）に入れる。
- `ViewCtx#preload3d` は自動の物の分を含んだ値になる（宣言の key が替わっていなければ、描き手が返した値をそのまま渡す）。
- 置き場の上限で作り終えた物を捨てると、作り終えた名前は宣言に無いので、次に描くコマで `ensure` が全部作って止まる（黒にしない。遊んでいる最中に画面が消える方が害が大きい。bench の置き場が捨てた回数は 0）。宣言（`withPreload3d`）に入れた集まりは捨てにくい（今まで通り）。
- 束が届く前に同じ名前の仮の `staticGroup`（中身が少ない）を出すと、それが「作り終えた名前」になり、届いた後は仮の物を描きながら作るので数コマ階が欠けて見える（テンプレートは届く前に小物だけの集まりを出すが、届く前から欠けているので今より悪くはならない）。
- 撮る文脈（3.5）では黒を出さず、描いたコマで作る（今と同じ止まりが撮りの中にはある）。
- 止まりの見張り（`Hitch.perfPaint`）は黒のコマも 1 コマとして数える（黒の間の preload の 1 コマが報告に出うる。黒の間は人に止まりとして見えないが、見張りは見分けない）。F8 の注釈の書き出しは画面の絵を写すので、黒の間に押すと黒い絵になる（注釈は黒の上なので枠と字は出る）。
- 自動を止めた後（3.6）は、今まで通り描いたコマで作る。

## 4. ゲームとテンプレートでの効き

| ゲーム | 今 | A の後 | 書く行 |
|---|---|---|---|
| テンプレート retro3d-horror-starter | 宣言なし。最初の階・階段室で上下の階が初めて載ったコマで止まる | 最初の階は暗転に入る（書き足し 0）。上下の階は、初めて載った時と、**しばらく（128 コマ = 120 Hz で約 1 秒・60 Hz で約 2 秒）見なかった後に階段室へ戻るたびに** PC 5〜7 コマ・CPU 4〜6 倍で約 0.5 秒黒くなる（作り終えた名前は宣言から外すので、描き手が控えを手放す・3.2）。今の main でも同じ道で戻るたびに `ensure` がそのコマで全部作って止まっている。`visibleFloors` の境目を行き来しても、済むまで黒が続くので点滅しない | 0。上下の階の黒を起動の 1 回にまとめるなら、全部の階を宣言する 3 行（`App.withPreload3d({ groups = 全部の階, scenes = 場面 :: Nil \| App.preload3d(key, _ -> Nil) })`・key は束の届いた数）。8 節の 3 で決める |
| night_school（engine 0.114.0・作業中） | 宣言（全部の階・人物・絵）＋自分で暗転（z 8・タイトルと読んだままの校舎の間だけ） | 暗転の手書き（`isDarkWhileBuilding`・`buildingDark`・`View.frame` の分岐）を消す。宣言は残す（全部の階を起動の暗転で作り、控えを持ち続けるため。黒は engine が宣言の名前にも出す — 下の注） | −約 12 行（ゲームのリポの仕事） |
| 血鱗（blood-scale・engine 0.114.0） | 住処の glb を instances で描く（`Lair3d.Room#statics: List[Instance3d]`） | 効かない | 0 |
| bench/scene3d | `FIRST=1`・`FIRST=preload` | `FIRST=auto` を足す（スパイクの 4 行） | — |
| bench/hd2d_town | 15 コマごとに `"settled"` を作り直す | 最初の 1 回だけ黒（作り終えた後の作り直しは黒にしない・数えない） | 0 |

注（night_school）: 宣言の名前は自動の表に入らないが、黒は同じ扱いで決める（3.2 の最後）。night_school は宣言を残したまま暗転の手書きを消せる。宣言の key が束の到着で替わった後は、一度済んだ名前なので黒にしない — ここは今の night_school の「読んだままの校舎（version 0）の間だけ暗転」と同じ振る舞い。6.1 のテスト 4 で押さえる。

## 5. ほかの計画との重なり

| 計画 | 重なり | 決め |
|---|---|---|
| plans/engine-first-use-hitches.md（段 0〜4 は入った・段 3 の `withPreload3d` の groups・scenes と `ViewCtx#preload3d` の上に乗る） | この計画は段 3 の「ゲームが書く約 20 行」を消す物。(b')・③'（glb の鍵・絵の往復）とは別の所 | 重ならない。段 3 の限界「場面の描き先の形式の pipeline と bundle は先に作らない」は 3.3 の黒の下の 1 コマで黒の間に移す。#3（骨つきの初めて 35 ms）・#4（材質の初めて）は残る（7 節の後で相談） |
| plans/engine-multimesh.md（枝 `multimesh`・0.115.0 予定。`Scene3dCmd.multiMeshes` を足す・`StaticRows`・`WebGpuRenderer`・`First.flix`・docs/scene3d.md・早見表・engine.json・`WebLayer.flix` に触る） | **`MultiMesh3d` の材質と形は自動で先に作る対象に入らない**。黒は集まりのためだけで、黒の間も場面の multiMeshes は描くので、黒が出たコマでは同じ場面の MultiMesh の材質も黒の下で組まれる。遊ぶ最中に初めて出す MultiMesh は、multimesh の計画 3.4 のとおり `App.preload3d(key, Scene3d.meshInstance(形, Mat4.identity()) \|> Scene3d.withMaterial(材質) :: Nil)` で先に上げる | 集まりを外すのは `{ groups = .. \| cmd }` の欄の差し替えなので multiMeshes の欄とぶつからない。黒の間に集まりを外しても数コマなので `@static-group-hint`（120 場面続いたら）は鳴らない。**multimesh を main に入れた後に始める**（同じファイルの差分を後から重ねる） |
| plans/engine-background-load-priority.md（0.115.0 予定・`App.Internal.BackgroundLoad`・`LoadWait.Context`・`BackgroundLoad.Internal` に触る） | 門（`withLoadGate`）が「解けた」まで待つようになると、門が明けた直後のコマに初めての集まりが載る → A の黒がそこへ続く（待ちの表示 → 数コマの黒 → 場面）。待ちの道（`Runner.showSlow`）も `submitPainted` を通るので、待ちの表示は黒の上に出る | 触るファイルが別（こちらは `App.Internal.Paint` と handler 2 つ）。並べて進めてよい。解くコマ（束 35 ms）と preload の 8 ms が同じコマに乗るのは今の宣言と同じ |
| plans/engine-web-glb-worker.md（書き直し中・engine_web の `WebLayer` と `fge-web.js` に触る） | 束が届いた後の作り直しは向こうの 1 章のとおり `ensure` の作り直し（1 コマ 8 ms）が受け持ち、A は黒を出さない（作り終えた名前）。こちらが触るのは `WebLayer.withWeb`・`WebGpuLayer.runPage` の handler の 1 引数だけ | 小さくぶつかる（同じファイル）。こちらを先に入れる |
| plans/engine-city-scale.md（区画を順に載せる） | 新しい区画が出るたびに黒くなる | 8 節の 2 の断る口（pop-in）で受ける |

順: multimesh（段 2）を main へ → この計画 → glb-worker。background-load-priority とは並べてよい。

## 6. 確かめ方

### 6.1 テスト

engine_world（`engine_world/test/TestPreload3d.flix` に足す）。今の偽の `Platform.Draw3d`（`opsWith`）は `noPreload()` を返すだけで描いた場面も記録しないので、**返す進み具合をコマごとに選べる形と、描いた場面の groups と黒の箱を記録する形へ広げる**（7 節の見積もりに入れた）。

1. 初めての名前は、済むまで場面から外れて黒（黒の z は `ZBand.loadingBase() - 1`）
2. 前のコマが黒で済んだコマは集まりを載せ、黒はまだ残る。次のコマで明ける
3. 前のコマが黒でなく、最初のコマで済んだ時は黒を出さない
4. 宣言と同じ名前の集まりは自動の宣言に足さない（宣言の groups に同じ名前が 2 つ並ばない）・宣言が済むまで外れて黒・済めば明ける。一度済んだ宣言の名前は、key が替わって済まない間に 120 コマ以上ぶりに出ても黒にならない
5. 宣言の場面に同じ版がある時は自動の場面を足さない・無い版の時だけ足す
6. 同じ集まりを 2 つの場面（本編と Pass）で描いても、自動の物は 1 つ・明ける
7. Clipped の中の場面の集まりも拾って外す
8. 「作っている」名前が View から消えても、済むまで黒が続く（境目の行き来で点滅しない）
9. 作り終えた名前で items の参照だけ替わった集まりは外さない・黒にしない・宣言に足さない
10. 作り終えた名前が 120 コマ出ず、また出た時は「作っている」に戻り、描き手がそのコマで済んだと返せば黒を出さない
11. 「作っている」間に値（参照・removed・tint のどれか）が替わったら、宣言に足す物も最新の値 1 つ
12. 描き手が `noPreload()` を返す（撮る文脈・CPU）時は黒にならない
13. 名前が替わり続けたら 20 回で自動をやめ、知らせは 1 回。Doc の世代が替わったコマは数えない。「作っている」途中で止めに当たったら、そのコマで黒が明ける
14. 宣言の key が黒の途中で替わっても、黒は「作っている」名前で決まり明滅しない
15. `Halt.pausedStep` で止めた画面（同じ World を描き直す）でも、黒は描き手の進み具合で明ける
16. 待ちの表示（`Default` の波紋・輪と `Custom`）は黒の上に出る
17. 版の作り方（`Output` と `preloadVariantOf`）が `Render3d.passVariantOf` と同じ答え（色・奥行き・+ps・+pu・+psx）— この 1 本だけ render_gl のテストに置く（engine_world は render_gl を見ない）

render_gl: `handleDraw3d(false, ..)` の時に `preload3d` が描き手を呼ばず `noPreload()` を返す（GL を 1 本・WebGPU は `TestWebGpuScene3dDawn` に 1 本）。

### 6.2 画素の門

- gallery の SHA（`make reference-update` が要らない事）・`make gl-parity` が 0 px・`make gl-capture-check SCENES=scene3d` を 2 回撮って同じ SHA。`DT=off` でも頭のコマが黒くならない（`FLIX_GE_FRAME_SHOT` で切る）。
- engine_web の 2 か所はユニットテストで見られないので、bench/scene3d をブラウザへ書き出し（`make bench-web-export BENCH=scene3d`）、`bin/fge web-capture "index.html?scene=field&group=1" <png> --dir build/bench-web/scene3d --dev capture:6` を WebGPU と `capture:6,webgl2` で 2 回ずつ撮って SHA が同じ（黒が出ない）事を見る。
- 画素の差が出たら入れる前に止めて人へ。

### 6.3 1 コマの重さ（初めて描くコマの ms）

場の条件は bench/scene3d/RESULTS.md の「初めての 1 回」と同じ `COUNT=300 SHAPES=137 MATS=8 VERTS=600`。

| 場 | 機械 | 測り方 | 線 |
|---|---|---|---|
| bench/scene3d `FIRST=auto` | PC（Dawn） | `make run SCENE=field GROUP=1 FIRST=auto COUNT=300 SHAPES=137 MATS=8 VERTS=600` の `frame#dt` の最大と `cpuPhases`（split・draw・preload）・起動し直して 3 回 | 最悪のコマ 33 ms 以下 |
| 同上 | Chrome 1 倍 | `make bench-web BENCH=scene3d ARGS='scene=field&group=1&first=auto&n=300&shapes=137&mats=8&verts=600'` の 1 コマの cpu の最大（`fgeStats`）・3 回 | 50 ms 以下 |
| 同上 | Chrome の CPU 4 倍・6 倍（スマホの代わり） | 7 節の `web-bench --cpu <倍>` を足して同じ ARGS で 3 回（足さない時は手で: DevTools の Performance の CPU を 4x / 6x にして頁を開き、明けた後にコンソールで `fgeStats.summary()`） | 線は置かない（記録する）。1 倍と同じ形（暗転の間の 1 コマ ≒ 予算＋最後の仕事）かを見る |
| テンプレートのブラウザ版 | Chrome 1 倍・4 倍・6 倍 | `?fge=fps` で起動 → 押す → 1 階を奥へ歩く → 階段室へ近づく を 3 回。`?fge=fps` の表示は CPU の**中央値**なので、止まりは `fgeStats.summary()` の cpu.max と lag.max で読む。`fgeStats` は 600 コマ（約 10 秒）の輪なので、**区間ごと**（起動〜押した後の暗転が明けるまで・1 階を歩く・階段室へ近づく）に区間の頭で `fgeStats.reset()`、終わりで `summary()` を取る | 1 倍で cpu.max 50 ms 以下（束を解くコマを除く。解くコマは background-load-priority の線） |
| night_school | PC・Chrome 1 倍 | 暗転の手書きを消し、宣言は残して手の並び（起動 → 1 階を歩く → 2 階へ → 人物に話す） | 最初のコマが 106 ms 以下（今の値）・最初の束が届いた後の初めてのコマに階の欠けと止まりが無い |

- 毎コマの重さ: 止まり以外のコマの p50 が 1 割以上増えない（first-use-hitches 0.1 と同じ線）。bench/scene3d の field に名前を 50 個に分けた集まり（区画のつもり）を載せた場面でも測る（`FIRST=auto` に `GROUPS=50` を足す・推測 15 分）。
- 数字は bench/scene3d/RESULTS.md の「初めての 1 回」へ（0.114.0 の上で測り直した値として）。

## 7. 段（1 つ）と見積もり

| 中身 | 緑とする測り | 実時間 |
|---|---|---|
| ① `App.Internal.Paint.submitPainted` に A（3.2〜3.4・3.6: 名前の表・(items の参照, removed, tint) での比べ・作り終えた名前を外す・120 コマで忘れる・宣言の名前の黒・版ごとの場面と宣言の場面との突き合わせ・黒の下で 1 コマ・前のコマが黒の時だけ残す・20 回の止めと Doc の世代の除き・黒の z）。持ち回しは `TileCache` に欄 1 つ。偽の描き手を広げる | 6.1 の engine_world 16 本 | 4〜5 時間（スパイク 1.5 時間・直しが 3 節の 10 か所・テスト 16 本と偽の描き手） |
| ② `handleDraw3d` 2 つに `ahead` と、呼び手 6 か所（3.5）・版の一致のテスト | render_gl 3 本・6.2 の画素の門（gl-capture の 2 回・ブラウザの撮りの 2 回） | 1.5 時間（GL と WebGPU の窓・offscreen・ブラウザ 2 つ。`make sync-engine-full`・`make sync-layers` と型検査） |
| ③ docs・早見表・お題: docs/scene3d.md の「動かない物の集まりを先に作る」を 3.2・3.3・3.7 に書き替え（「中身が無い間は staticGroup を View に出さない」「版の違う場面は宣言の scenes にも入れる」を 1 行ずつ）・docs/z-bands.md に黒の行。`agents-pack/AGENTS.core.md` 87 行（今は「isPreloaded が済むまで載せずに暗転を描く」）を書き替え。agent-eval の今のお題 `preload-static-groups`（expect に `isPreloaded`）を「engine が自動で暗転する・書く物は無い（全部の階を起動にまとめるなら groups と scenes の宣言だけ）」に直し、avoid に「`isPreloaded` を読んで集まりを外す暗転を手で書く」を足す | `make agent-eval ONLY=preload-static-groups` が当たる・`make check-docs-sync` | 1 時間 |
| ④ 測り: bench/scene3d に `FIRST=auto` と `GROUPS=50`、6.3 の PC・Chrome 1 倍・4 倍・6 倍、テンプレートのブラウザ版、night_school（ゲームの手元で暗転を消した版を流すだけ・コミットはゲームのリポ） | 6.3 の線 | 2 時間 |
| ⑤ `bin/fge web-bench --cpu <倍>`（`cdp.PageOptions.CPUThrottle` はもうある・`go/exportweb_browsercheck.go` が使っている） | go のテスト 1 本 | 30 分 |

合わせて **engine 7〜8.5 時間＋測り 2 時間**。8 節の 2 で断る口を「作る」と決めたら＋1〜1.5 時間（pub 2・PopIn と Off のテスト・docs・早見表 1 行・agent-eval のお題 1 本）。根拠: スパイク 1.5 時間・0.113.1 の preload の直し・0.112.0 の割り当て減らし（約 2 時間）。

- linter: `Scene3d.isPreloaded(` を forbid に入れない。WhyNot: pub は残り、タイトルの「読み込み中」の字のような正しい使い方でも鳴る。誤った書き方（読んで集まりを外す暗転）は 1 行の正規表現で見分けられないので、docs の表と agent-eval のお題で止める（AGENTS.md の順の ③）。
- render_gl の Preload と StaticRows には手を入れない（handler の 1 引数だけ）。
- ゲームの追随（night_school の約 12 行を消す）はゲームのリポの仕事。テンプレートは 8 節の 3 で決めた形を同じ段で入れる（決めが (b) なら 3 行・30 分を足す）。
- 後で相談: 描き手が `staticGroup` ごとに済んだかを返せば、黒は見えている物だけで決まり、3.7 の 1 つめが消える（render_gl の Preload に触る）。
- 後で相談: 骨つきの人物（first-use-hitches #3・35 ms）と MultiMesh3d・instances の初めての材質と形（#4）を、View の答えから拾って `Scene3d.meshInstance` で自動の宣言へ足す案（黒にはしない。次に出た時から効く形になるので、効くのは 2 回目の場面に入る時から）。

## 8. 人に決めてほしい事

**2026-11-26 人が推す答えで了承。** 1 黒の見た目の口は作らない／2 断る口 `App.withAutoPreload3d(Cover|PopIn|Off)` を作る（+1〜1.5 時間）／3 テンプレートは全部の階を宣言して起動の 1 回にまとめる／4 作り終えた名前は自動の宣言から外す／5 `ZBand.autoPreloadCover()` を足す／6 撮る文脈では先に作らない（handler 2 つに Bool）／7 `?fge=fps` に cpu の最大を足す。


1. 黒の見た目を替える口を作るか。作るなら新しい pub ではなく、今の `App.withLoadingIndicator`（`LoadingIndicator.Custom`）に乗せる（作らなければ新しい pub は 0・黒一色。night_school は今の z 8 の黒と違い、カメラの乱れと HUD も覆う）
2. **ゲームが自動を断る口を作るか**。区画を順に載せるゲーム（plans/engine-city-scale.md・hd2d_town の積み上げ）では、新しい名前のたびに design 全体が黒くなる（CPU 4〜6 倍で推測 0.5〜0.75 秒）。案: `App.withAutoPreload3d(App.AutoPreload3d.Cover | PopIn | Off)`（pub 2・既定 Cover）。PopIn = 「作っている」間は集まりを外して描き、黒を出さない（済んだコマで現れる）。Off = 今まで通り描いたコマで作る。推す: 作る（pub 2）。作らないなら pub 0 のまま、3.7 に「断れない」と書く
3. テンプレートの上下の階: (a) 黒のまま（初めてと、約 1〜2 秒離れてから階段室へ戻るたびに黒。今の main は同じ時に止まっている）、(b) テンプレートで全部の階を宣言する（3 行。宣言にある間は描き手が控えを持ち続けるので、黒は起動の 1 回だけ）、(c) 2 の PopIn。推す: (b)
4. 作り終えた名前を宣言から外す（3.2）でよいか。外すと key の揺れ・毎コマの仕事・増え続ける限界・止めの誤りが消え、置き場の上限で捨てられた後の止まりが戻る（宣言に入れた集まりは捨てにくいまま）。持ち続けると逆
5. 黒の z を `ZBand.autoPreloadCover()` = `loadingBase() - 1`（HUD より手前・待ちの表示より奥・`ZBand` に値を 1 つ足す）でよいか
6. 撮る文脈（dt を固定した窓・`FLIX_GE_FRAME_SHOT` の窓・1 枚撮り・ブラウザの撮る頁）の描き手は先に作らない（3.5）でよいか。render_gl と engine_web の handler 2 つに Bool を足す
7. （任意）`?fge=fps` の表示に直近 2 秒の cpu の最大を足すか（今は中央値だけで、止まりを人が見るにはコンソールで `fgeStats.summary()` を打つ。`fge-web.js` の 1 行）
