# エージェント共通指針（エンジン公式・全ゲーム共有）

エンジンの agents-pack から配られる共通部。ゲーム固有の方針は同じフォルダの `AGENTS.local.md` に書く。
lint・フック・make の口で止まる決まりはここに書かない（止まった所で hint が代わりの道具を示す）。

## .flix の名前を探す（grep の前に・最初の 1 手から）

| したいこと | 道具 |
|---|---|
| 名前の一部から宣言を探す | `bin/fge refactor search <語>` |
| 関数・型の本文だけを読む | `bin/fge refactor show <Mod.名前>` |
| 使う所・呼び手を全部（直す所の洗い出し） | `bin/fge refactor usages <Mod.名前> [--callers]` |
| 使われていない pub | `bin/fge refactor usages --unused` |

grep は別の mod の同じ名前を拾い、`use` で入れた素の名前を落とす。文字列・文書・JSON の値は grep のままで良い。詳しい表は `/flix-docs`。

## やりたいこと → 道具（早見表。まずここを引く）

1 行 1 件・80 字まで。行には名前だけ置き、詳しい所は `--help`・engine の docs・モジュール冒頭の doc へ。
表に無ければ `make module Q=<やりたいことの語>`、型と引数は `make api Q=<名前>`。ゲーム固有は `AGENTS.local.md`。

| やりたいこと | 使う道具 |
|---|---|
| 物を重ねる・手前と奥を決める | `ZStack.of` / `leaf` の木を根で `SortingLayer.compose` |
| 必ず手前に出す（確認の窓・ポーズ） | `ZStack.topLayer(層, 木)`・層は `SortingLayer` の enum |
| 見下ろしで人が木の裏に回る | `ZStack.zIndex(Depth.orderAt(足元のy), leaf(人))` |
| 画面ごと動かす・縮める・薄める | `ZStack.mapItems(Render.scaledAllAround(..))` |
| 閉じるボタンで「終了しますか？」・ゲームから終了 | `App.withCloseRequest` + `App.quitWhen` |
| 設定の画面でウィンドウ ⇄ 全画面をその場で切り替える | `App.withFullscreen`（World から宣言・系で `setFullscreen` を呼ばない） |
| パッドの Start でメニュー・ポーズを開く・パッドの機種（Steam か）で案内の絵を替える | Start は `Key.Menu`（`Enter` ではない）・Select は `Key.Backspace`・機種は `frame#padKind`（engine の `docs/gamepad.md`） |
| 隠れてはいけない表示（スコア・案内） | `App.withHudView` |
| 押す物を見た目の手前から選ぶ（窓の奥を押させない） | 描く木に `ZStack.hit` / `modal` → `SortingLayer.pickFrom` |
| UI のクリックを描いた所で当てる（字の下に並ぶボタン・字だけの項目） | `UiFocus.hitTestUiWith(atlasOf, ..)`・`UiFocusNav.targetsOfUiWith`（atlasOf は描く時と同じ） |
| 説明の窓をはみ出さず置く | `UiTooltip` + `ZStack.topLayer` |
| 演出の時刻表を書く・描く・鳴らす | `Timeline.build`+`withSound` → `soundsBetween`（時計は `soundsOnClock`）→ `App.withAudio` |
| 画面ごとの後処理（ブルーム・ぼかし）を半分の解像度で組む | `App.withPassPlan`（`targets` に `RenderTarget.Descriptor` の scale）+ pass の中の `Render.shaderFill`・なめらかに読むのは ShaderDoc の `sampler`（描き出しは `Render.passSpecsOf`） |
| 3D の場面を窓の画素で描く・白飛びを HDR とトーンマップで収める・縁を FXAA でならす | `RenderTarget.windowDescriptor()` / `withHdr` の Pass → 本編の面を `PostProcess.tonemappedWith` → 8bit の Pass を `PostProcess.fxaaSpec`（1 で切って白飛びを抑えない） |
| 面に毎フレーム変わる数（ピント・体力の割合）を渡す | ShaderDoc の `param` + `Render.withShaderParams`（Spec の Const に入れない） |
| 系・View の中で平方根・sin・cos・角（atan2）・π を使う | `Num.sqrt` / `Num.sin` / `Num.cos` / `Num.atan2` / `Num.pi` / `Num.tau`（`java.lang.Math` を呼ばない。Vec2 の旧い数の関数は 0.84.0 で消えた） |
| 面の中で光の向きや距離を計算する（平方根・長さ 1 にそろえる） | ShaderDoc の `math1` の `sqrt`（`UnOp.Sqrt`）・`ShaderDoc.lengthOf` / `normalized`（近い値で代わりにしない） |
| 3D の部屋・家具（メッシュを深度で前後させる）を 2D の画面に入れる | `Render.scene3d(at, Scene3d.scene(camera, size))`（`Mesh3d.fromObj` / `fromPolygons` → `Scene3d.meshInstance`）・描き出しは `Render.softSceneOf` → `HeadlessRender.renderPngSoft`（三角形を多角形で並べない。手本 `bench/scene3d`） |
| Blender で骨を入れたキャラ（.glb）を 3D の場面で動かす（歩く・敬礼など） | `Gltf.load` → `AnimationClip3d.sample`（混ぜるなら `Pose3d.blend`）→ `Pose3d.compute` → `Scene3d.withPose`（骨は GPU と SoftRaster の両方で曲がる。曲げを手で頂点に掛けない） |
| Blender でベイクした光（lightmap と 2 本目の UV）を 3D の部屋に貼る | glb は `Gltf.loadTexturedUsing(dec, Gltf.noTextureLimits(), path)`（TEXCOORD_1 → part の uvs2・`dec` は読み込みの頭で `LoadProgress.imageDecoder()`）→ lightmap の PNG は `Texture3d.decodeUsing(dec, bytes)` で場面の textures へ → `Scene3d.meshInstance(..) \|> Scene3d.withLightmap({ intensity = .. \| Scene3d.lightmap(Texture3d.name(t)) })`（光を材質の絵に混ぜ込まない・ベイクに入れた光は pointLights に入れない・骨つきには付かない・engine の `docs/lightmap.md`） |
| 3D の絵が多く「場面の絵が 256 MB を超えて使われている」と出る | `Gltf.loadTexturedUsing(dec, { normal = 1024 \| Gltf.noTextureLimits() }, path)`・`Texture3d.limitSize(1024)` で縮める → それでも足りなければ project.json の `scene3dTextureBudgetMB`・枚数は `scene3dTextureBudgetCount` |
| 懐中電灯（縁のぼけたスポット）を目から照らす | `Scene3d.spotLight(p, t, fov)` に `innerFovY = Some(..)`（縁を広くぼかす）を `spotLights` へ（点光源で代わりにしない・円錐を広げて range で縁を消さない・engine の `docs/scene3d.md`） |
| 3D の点光源が 8 本を超える | 光は全部 `pointLights` に入れる（engine が `Scene3d.pickLights` で目に近い 8 本を選ぶ。ゲームで近い順に選び直さない）。落とした数は `ctx#diagnostics`（View・HUD）の `scene3dCounts#droppedPointLights` / `droppedSpotLights`（初めて落とした時に 1 回知らせる）・画面なしのテストでは `Scene3d.droppedLightsOfScenes(Render.drawScenes3d(items))`（GL と CPU で同じ数） |
| 一人称でマウスで視点を回す（カーソルを窓にキャプチャする） | `App.withMouseCapture(w -> ..)` + `frame#mouseDelta`（design px）で yaw・pitch を回す。クリックでキャプチャ・Esc で放す（ドラッグの差で代わりにしない・engine の `docs/modules/input.md` の「一人称の視点」） |
| テストで入力・窓・描く op を偽物にする・機種の handler を自分で書く | 触る役の effect だけを張る: `Platform.Input`・`Platform.Window`・`Platform.FrameClock`・`Platform.Draw2d`・`Platform.Draw3d`・`Platform.GpuResources`・`Platform.Diagnostics`・`Platform.Annotation`（handler は effect ごとに 1 つずつ書く・`Input` は必ず `Platform.Input` と書く） |
| 自分で `renderCommands` を呼んで窓へ出す（bench・自前のループ） | `Platform.Draw2d.renderCommands` の後に `Platform.Window.presentFrame()`（1 フレームの終わりに 1 回・`renderCommands` は swap しない）。イベントの取り込みは 1 フレームに 1 回 `Platform.Window.pollEvents()`（`shouldClose` は問うだけ） |
| 系の中で sin・cos・pow を使う・系で IO を測る | `Num.sin`・`Num.cos`・`Num.asin`・`Num.log`・`Num.sqrt`・標準の `Float64.pow`・`Float64.exp`（ゲームの src の `unchecked_cast(… as _ \ {})` と `unsafe` は lint-forbid が止める・`App.launch` は純粋な `App[w, {}]` だけを受ける。系で IO を測る bench だけ `App.launchForBench`） |
| 右クリック・中ボタンを読む | `frame#mouseClickedButtons`（押した瞬間）・`frame#mouseButtons`（押している間）を `Set.memberOf(GameEngine.MouseButton.Right, ..)` で引く（`mouseDown`・`mouseClicked` は左だけ・`isMouseButtonPressed` を系から呼ばない）。flow では `mouse=right` |
| GPU と CPU の 1 コマの時間を debug 表示する | `app \|> App.withDiagnostics` → View か HUD で `ctx#diagnostics` → `FrameDiagnostics.summaryLines`（自前で nanoTime を測らない。GPU は 1〜2 コマ遅れの値） |
| 敵が多くて 1 コマが重い（規則の計算と描くのを重ねて縮める） | `app \|> App.withPipelinedRendering`（効果の無い `App[w, {}]` だけ。画面は 1 コマ前の World を描き、入力が画面に出るまでが 1 コマ遅れる。自前でスレッドを立てない）・60 fps より上を測るのは `FLIX_GE_NO_VSYNC=1`（垂直同期を待たない） |
| たくさんの物から近くの物だけを引く（群れの押し合い・範囲の当たり） | `SpatialGrid.buildBy` + `foldNearIndex`（`f` はその場のラムダ） |
| 群れが同じ相手を追う・共有の歩数の地図（塗り直しは秒で間引く） | `FlowField.build` + `downhill` / `stepsAt`・間引きは `Clock.tick` |
| F3 の診断の行を出す・出さないを切り替える | World には切り替えの `Bool` だけを置き、行は View か HUD で `ctx#diagnostics \|> Option.map(FrameDiagnostics.summaryLines)` から描く（系で `frame#diagnostics` を World へ写すと lint-forbid の `frame-diagnostics-in-system` が止める。再生と食い違うため） |
| 3D の家具・壁に木目や石の絵と凹凸（法線マップ）を貼る | 絵つきの .glb は `Gltf.loadTexturedUsing(dec, Gltf.noTextureLimits(), path)`（`dec` は読み込みの頭で `LoadProgress.imageDecoder()`）→ 部品は `model#parts`・絵は場面の `{ textures = model#textures | 場面 }` に渡す（渡さないと黒い）・コードの形は `Mesh3d.withBoxUvs` + `Scene3d.texturedMaterial` + `withNormalMap`・glb の emissive（`KHR_materials_emissive_strength` つき）も読んで光る（止めるなら `Scene3d.withoutEmission`・emission を差し替えても名前は替えなくてよい・差し替えても glb の強さ `emissionIntensity` は残る）・材質の情報は `part#gltfMaterial` |
| Blender で名前を付けた物（扉・調べる物・当たり判定の箱・印の点）を glb から名前で引く | `Model3d.findNode(name, model)` / `nodesWithPrefix("COL_", model)`（たくさん引くなら `nodesByName`）→ `node#world`・`node#localBounds`・`Model3d.nodeOrigin`（位置や大きさで探さない・座標を手で写さない。engine の `docs/scene3d.md`） |
| 3D の部屋を一人称で歩く（壁で止まる・段差を上る・坂・落ちる・扉に押される） | 箱は `Model3d.nodesWithPrefix("COL_", m) \|> CollisionShape3d.boxesOfNodes`（glb の `COL_*` のノード）→ `CollisionWorld3d.build(2.0, boxes)` → 毎コマ `CharacterBody3d.moveAndSlide(world, 扉の板, settings, 速さ, dt, body)`（自前で押し出し・床探しを書かない・地面と歩ける範囲も箱で入れる。engine の `docs/scene3d.md`） |
| 一人称で歩く体の範囲を見る・描く（体の箱・床の箱が坂か） | `CharacterBody3d.aabbOf(settings, body)`（`Mesh3d.Bounds`。箱にするなら `CollisionShape3d.boxOfBounds(Mat4.identity(), ..)` → `debugMesh`）・床の箱が坂かは `CharacterBody3d.isTilted(box)`（半径と高さから手で箱を組まない） |
| 一人称で見ている物を調べる（照準の先の物の名前・E で調べる・E で扉） | `Camera3d.forwardRay(cam)` → `Ray3d.pickNearest(ray, 距離, 的)`（的は `Ray3d.boxTargetsOf(n -> 鍵, nodes)`。壁も「壁」の鍵で入れて遮る。距離と向きの内積で代わりにしない） |
| 3D の場面の背景を空のグラデーション（天頂・地平・地面）にする | `{ sky = Some(Scene3d.gradientSky(天頂, 地平, 地面)) \| Scene3d.scene(..) }`（寄り方は `Scene3d.withSkyCurve`。2D の面を下に敷いて地平の高さを手で計算しない・地平の色をかすみの色にそろえると継ぎ目が消える） |
| 3D の窓ガラス・網・水面（向こうが透ける物） | 材質に `Scene3d.withAlphaBlend(true, m)`（裏から見えるなら `withDoubleSided(true, ..)`）・glb の `alphaMode: BLEND` / `MASK` は `Gltf.loadTexturedUsing` がそのまま当てる（cutout で代わりにしない・doubleSided は当てないので `part#gltfMaterial#doubleSided` を見てゲームが当てる） |
| 古い版から上げたら 3D の部屋の色・明るさが変わった（前の見え方に戻したい） | 戻す旗は無い（`scene3dLinearColor` は 0.84.0 で消えた・project.json に残すと lint-forbid が止める）。ambient・光の intensity と range を線形の目盛りで合わせ直す（engine の `docs/migrations/0.79.0.md`・`docs/scene3d.md` の「3D の色」。2D の絵は変わらないので 2D を直さない・色を自前で変換し直さない） |
| 3D の看板・溶岩・glb の emissive を強く光らせる（1 を超える明るさ） | `Scene3d.withEmissionIntensity(k, 材質)`（線形の倍率。Spec の emission に 1 を超える色を書かない・glb の emissive_strength は `Gltf.loadTexturedUsing` がここへ入れる） |
| 3D の手すり・金網・電線のような細い物が欠ける・ちらつく | 場面の Pass を `RenderTarget.withMsaa(4, RenderTarget.windowDescriptor() \|> RenderTarget.withHdr)`（cutout の縁も alpha to coverage でなめらかになる・画面なしの描き出しには掛からない）・それでも残る縁は `PostProcess.fxaaSpec` |
| 灯りの反対の地面へ倒した影（ドット絵の走りから） | `Shadow.projectedRuns`（`PxSprite.runs` を渡す） |
| 演出の待ちが先の拍で変わる（全部が済んでから始める・置き直さない） | `Timeline.afterAll`（基準ごとに間）→ `Timeline.build` |
| ポーズ・ヒットストップで止める・遅くする（遊びと実時間を分ける） | `App.addClock` + `Clock.Pace`・`frame#realNow` |
| 規則の奥の出来事で鳴らす（固定刻みでも 1 回） | `Emit.emit` → `Emit.collectInto` で World に溜め `Emit.since` |
| 粒（花びら・火の粉）に触れたかを規則で取る | `Fx.particlesOfAll(now, bursts)`（絵と同じ式の番号と中心）+ `Fx.touches` |
| テストで系に渡す 1 コマ（押したキー・dt・カーソル）を組む | `{ down = Set#{Key.Space}, justPressed = Set#{Key.Space}, dt = 0.016 \| App.emptyFrame() }`（字で `App.Frame` の全部の欄を書かない。前のコマとの差から作るなら `App.frameOf`） |
| どう遊んでも崩れない決まりを確かめる（性質テスト） | `PropertyTest.forAll`（画面なしで `App.trace` と同じ道） |
| テストで実機と同じ 1 コマ（時計・固定刻み・押した瞬間の持ち越し・系・音）を進める | `App.traceFrame`（`App.freshStepState()` から持ち回す）か列ごと `App.trace`（`App.Internal.*` は App の中身で、ゲームの src と test に書くと lint-forbid の app-internal が止める） |
| 画面なしで描く物を作る・Item を描く命令にする所を自分で呼びたい（`SoftRaster` や `Render` の中の関数） | 親のモジュールの関数（`SoftRaster.renderToImage`・`Render.toDrawables`・`Render.softSceneOf` など。`make api Q=Render.`）。`<モジュール>.Internal.*`（`Render.Internal`・`SoftRaster.Internal`）は中身で、ゲームの src と test に書くと lint-forbid の app-internal が止める。足りなければ engine に足すよう相談する |
| e2e・動画の手順を書いて画面なしで流す（失敗は行番号つき） | `e2e/<名前>.flow` + `App.withFlow`・`bin/fge flow check`・`make flow` |
| 好きな場面から起動・テスト・遊んだ通りに再生 | `App.withStarts`（`START=`・`startOrBug`）・記録は `make flow` で再生 |
| ギャラリーの 1 枚の World から実機で開く・実機の記録が再生と同じか | `App.withShots`（`<ゲーム>/src/Shots.flix`）+ `SHOT=<場面> make run`・engine で `make determinism`（台本 `FLIX_GE_INPUT_SCRIPT`） |
| 記録の再生が起動した時刻などの外の値で `expect world=` に止まる | `App.withWorldSummaryMask`（その欄だけ決まった値へ） |
| 実機の GL の絵が同じ起動で毎回同じかを、頭の数コマを撮って確かめる（2 コマ目以降も） | `FLIX_GE_FIXED_DT=1/60`（dt を固定）+ `FLIX_GE_HIDDEN=1` + `FLIX_GE_FRAME_SHOT=<フォルダ>` + `START=<場面>` で `make run RUN_SECONDS=30` を 2 回（撮る口は 64 枚で止まるだけで窓は閉じない）し、`frame-N.png` を比べる |
| 描き手（render_gl）を直した前後で、実機の GL の呼び出しの並び（関数・引数・戻り値・送ったバッファの CRC）が同じかを比べる | `FLIX_GE_GL_LOG=<ファイル>`（起動の分と頭の `FLIX_GE_GL_LOG_FRAMES` コマ・既定 6 を 1 行ずつ。コマは `--- frame n` で区切る）を上の撮り方と一緒に置いて 2 回起動し、ファイルを diff する（控える間は起動画面を描かない）（engine の作業場では gl-capture の場面で） |
| ブラウザ版に入れるフォントアトラスを前もって生成する・台詞や Doc の字がフォントに無い（ブラウザで字が出ない）のを書き出しの前に止める | `bin/fge font-bake <ゲーム> <出力>`（yarn・Doc の値・src の文字列リテラルの字を集め、デスクトップと同じアトラスを `<出力>/<fonts[].name>.fontatlas` と `fonts.json` に書く。どのフォントにも無い字は字と出所（ファイル:行）を出して 1 で止まる。生成するだけなら Flix から `FontAtlasBake.bakeProject`。字を手で数えて無い字を探さない） |
| 起動の読み込みが数秒かかる・起動画面でカーソルが応答なしのくるくるになる | 読み込みを `LoadProgress.mapWithProgress` / `parMapWithProgress` で区切る（実機は起動画面が進みウィンドウが応答する）・並列の仕事で絵を解くなら頭で `let dec = LoadProgress.imageDecoder()` を受け取り仕事へ渡す（`Gltf.fromGlbTexturedUsing(dec, ..)`・`Texture3d.decodeUsing(dec, ..)`。仕事の中から op は呼べない）・描き出しとテストの入口は `HeadlessLoad.handle`（絵を解かないなら `LoadProgress.runNoop` でもよい）・main は `App.loadAndLaunch(() -> 組む式)`（`make debug` でも Doc を読み直さない。engine の `docs/startup.md`） |
| 開発の道具（リモートデバッグ・flow の記録・ゲームの名簿・ヒッチの見張り・Doc の保存検知・F8 の注釈）を持たずに走らせる（ブラウザ版の入口など） | `App.launchWithDevTools(App.DevTools.none(), app)`（`App.debugFromEnv()` は呼ばず `withDebug` は値で・`App.launch` / `loadAndLaunch` はデスクトップの道具 `App.DevTools.desktop(env)` のまま）・`App.onRenderRequest` / `onShotRequest` は `Game.app` でなく `Main` で繋ぐ（lint `dev-request-outside-main`） |
| ゲームをブラウザ（PC の Chrome など）で遊べる形に書き出す | ゲームに `web/WebMain.flix`（`mod WebMain` の `pub def main`。Main と同じ App を `App.launchWithDevTools(App.DevTools.none(), app)` で、`with WebLayer.withProject(".") with WebFs.runFileRead with WebFs.runFileWrite` の上に。rpg-starter の物が写経元）を置き、`bin/fge export-web <ゲーム>`（出力 `<ゲーム>/build/web`。静的なサーバーで配る・セーブは localStorage・型検査だけは `--check`）。engine の作業場では先に `make sync-engine-full-web`。TeaVM の JSO は `fge.web` の外へ出さない（lint `teavm-jso-outside-fge-web`） |
| Scene3d のゲームをブラウザで動かす（3D が映らない・マウスの視点・glb の絵） | `web/WebMain.flix` の入口を `with WebLayer.withProject3d(".")` にする（`withProject` は 3D を描かず、`export-web` と起動の時に 1 回言う。wasm は 3D のぶん太る）。`LoadProgress.imageDecoder`・`App.withMouseCapture` はそのまま効く。頁の `?glcheck=1` は GL の誤りを console へ・`?loadtime=1` は絵の解読の時間を `console.time` へ出す（Mip の時間はデスクトップの F3 と hitch の 3D の区間 `mip`） |
| スマホ（指の小さい画面）の時だけ字とボタンを大きくする・並べ方を替える | View は `ctx#display#sizeClass == Display.SizeClass.Small`（`ViewCtx#display` に画面の大きさ・`designScale`・最後の pointer も）・当たりを取る系は同じ並べ方を `frame#sizeClass` から引く（World の結果を区分で変えない）。大きさは Doc に出す（手本 sound-novel-starter の `novel.small.json`・`Layout.Fit`）。PC から確かめるのは描き出しの ctx を `{ display = { sizeClass = Display.SizeClass.Small \| ctx#display } \| ctx }` にするか、ブラウザ版の頁を `?size=small&input=touch` で開く |
| ブラウザ版をスマホで遊べるようにする（十字キーとボタン・タップ・長押し・払う・向き） | project.json の `web`（`keysDoc`・`virtualPad: { dpad: true, buttons: [{label, action}] }`・`touchGestures: { longPress, swipeLeft, swipeRight }`・`orientation`）を `bin/fge export-web` が解く（操作の名前はキーの Doc の名前・手本 rpg-starter と sound-novel-starter）。ゲームの側はキーとクリックのまま（タップ = 離した時のクリック・縦のドラッグ = ホイール） |
| スマホを縦に持った時に縦長の画面で起動する（縦の並べ方を足す） | project.json の `web.portraitDesign: { "width": 540, "minHeight": 960 }`（スマホ（区分 Small）を縦に持ってブラウザで開いた時だけ、幅を固定・高さは描き先の比から決めた縦の design で起動・`orientation` は `any`）。View は `ViewCtx#display#orientation`（起動の時の design の向き）と `ViewCtx#visible#size`、当たりは `Display.orientationOf(frame#viewport)` と `frame#viewport` から同じ並べ方を引く。PC では頁の `?orientation=portrait`、デスクトップは `FLIX_GE_PORTRAIT=1`、画面なしの描き出しは `Display.phonePortrait(view, design)` と `ProjectLoader.portraitConfigOf`（手本 sound-novel-starter の `portrait-<場面>`） |
| ブラウザ版の書き出しを小さくする（絵・音・字のアトラス） | `bin/fge export-web` が書き出し先の中だけで png → WebP（既定は劣化なし）・wav → Opus・アトラス → gzip に替える（assets/ とデスクトップは変わらない）。強さは project.json の `web.compress`（`audioBitrateKbps`・`uncompressedAudio: [glob]`・`lossyImages: [{glob, quality}]`・`audio` / `images` を false で止める）。道具は ffmpeg（libopus）と cwebp・無ければ圧縮せずに書き出して大きさの表に 1 行 |
| macOS で窓を開くゲームの main の頭（`-XstartOnFirstThread` で起動し直す） | `if (LwjglLayer.ensureMainThread()) () else …`（GameEngine の同じ名前の関数は 0.84.0 で消えた） |
| 曲の拍・小節に乗せる | `Duration.Bars` / `ToNextBar` / `ToPickup` + `Timeline.tempo` |
| 演出の長さ・待ち・溜めの目安 | engine の `docs/pacing.md` |
| 音の名前を型で止める（一発と鳴り続ける音を取り違えない） | `Sfx[s]` / `Loop[s]` + `Sfx.collect` / `Loop.collect` |
| 曲の頭を 1 回だけ鳴らし本編をループ | `SfxSynth.renderLooped` + `App.withSustained` |
| 効果音・曲を作る・直す（音割れも検査） | 台本 `*.snd.star` か `*.sndsrc.json` を `bin/fge snd build` |
| 会話を人が書く・台詞と選択肢を順に出す・会話の中で数えて分ける | `*.yarn`（`<<declare>>` `<<set>>` `<<if>>` `{$x}` `visited`）を `bin/fge yarn build` → `Yarn.loadOr` + `YarnRunner.start` / `step`・値は `YarnRunner.valueOf` / `startWith` / `YarnStorage`・選べない選択肢は `DialogueOption` の `available` |
| ノベルのルビ・セーブとロード・実写の背景をぼかす | `[ruby=よみ]字[/ruby]` → `RichText.placeRuby`・`YarnRunner.bookmarkOf` / `resume`・ShaderDoc の `blur` 場（手本 `sound-novel-starter`） |
| 会話の行を本物の画面で見る・起動中のゲームをその行へ（変数の値を決めて） | Studio の会話・`bin/fge talk shot` / `goto`（始まり `talk node= line=`・`'$名前=値'` は `YarnStorage.withArgs` → `YarnRunner.startAtWith`） |
| 画面（表紙・遊ぶ・クリア）を足す・その画面だけの値を持つ | World の `screen` の enum に case と payload（手本 game-starter・tidepool-starter） |
| Doc・アトラス・シェーダーを World に平らに持たず外に出す | App の w を `Resources.With[res, w]`・`Resources.system` / `view` / `read`・読み直しは `Resources.reloadRow` |
| Doc が壊れたら既定値で続けて知らせる | `DocJson.loadOr` + `Log.fellBackThen` / `warnThen` |
| 知らせ（`Log.warnThen` など）を出す経路をテストで通す・知らせの文面を確かめる | `let (value, lines) = LogCapture.capture(() -> 式)`（stderr に出るとテストの実行器が FAIL にする。テストで System.setErr を自分で差し替えない） |
| 直した後に絵を確かめる | `make render SHOT=<場面>` → 仕上げ `make reference-check` |
| 描き出しの字の被り・z の外れを止める | `make render-lint`（許す物は `text-audit.local.json`） |
| 依存の向き（規則 → View → 入力の逆を呼ばない・ファイルの輪）・View に World を渡さない・テストの分岐を止める | `make lint-flixlint`（決まりは <ゲーム>/lint/rules.flix の冒頭。View の入口が World から In を組み、部品は In を受ける） |
| 直す前と後の絵・音・動画を比べる | `make compare BASE=<ref>` |
| ブラウザ（WebGL2）で描いた canvas の画素を PNG に撮る | `bin/fge web-capture <URL> <出力.png> [--wait 秒] [--size WxH]`（頁が `window.fgeCaptureReady` と `fgeCapture()` を出す・`export-web` の頁は `?capture=<n>` で dt を固定した n コマ目を撮らせる・engine の `docs/web-capture.md`） |
| 遊んでいて重くなる（動いた瞬間のカクつき）の原因を探す・直したか確かめる | `make debug`（音なしは `FLIX_GE_MUTE=1`）で遊ぶと重いコマだけ `debug/perf/hitches/<起動時刻>/f<コマ>/hitch.md` に出る（`make status` に件数）→ 読んで直す → 同じ手を `POST /perf?path=<flow>`（隠しウィンドウは `FLIX_GE_HIDDEN=1`）で流し、作ったシェーダーの数で比べる（engine の `docs/performance.md` の 11 節） |
| 動画が最後まで撮れたか（途中で止まった動画を見つける） | `bin/fge videos status`（Studio のギャラリーの動画） |
| 動画のコマ・自前のギャラリーで同じ絵を塗り直さない | `RenderCache.writeFramePng`（`SoftRaster.render*` は自動。docs/render-cache.md） |
| 人が見る動画・会話のプレビューを GPU で塗る | 動画 `VideoOut.writeFrames`（Pass を使う画面は `writeFramesWithPasses`）・1 枚 `GpuShot.shotOf`（`FGE_GPU`） |
| 描き出しに ShaderDoc の面と追加フォントを一緒に渡す（字の縁は本ごとに） | `HeadlessRender.renderPngFull(cfg, scene, name)`（`Scene` の `fonts`・本ごとの字の縁は `fontAntialias`） |
| 遊ぶ起動を速くする（src を変えていない 2 回目からコンパイルしない） | `make run` / `make debug`（engine の headless-run `--window main` が描き出しと同じ jar から流す）・裏で作るだけは `--build-only` |
| 起動して確かめるだけ（数十秒で自分で止め、ウィンドウを残さない） | `make run RUN_SECONDS=40`（プロセスの組ごと止め、時間で止めた時は成功で返る） |
| 描き出しを続けて流すたびの JVM の立ち上げを省く（render・reference-check・会話の撮り） | `HEADLESS_RESIDENT=1`（窓なしのゲームを常駐・入口は `<名前>Job(req): Int32` と `jobs()`）・`bin/fge resident status` / `verify` |
| F8 のチケット・閉じる | `debug/annotations/` の README → `world.json`・`bin/fge tickets close` |
| 直しが別の不具合を生んだ率 | `bin/fge tickets stats`（前の直しの候補は `suspects`） |
| ゲームの定義を引く | `make src Q=<名前>` |
| 文書が消えた名前・無いファイルを指していないか | `make lint-doc-refs`（古い記録は `doc-refs.local.json` の skip） |
| 関数・型の本文を読む・名前の一部で宣言を探す・ファイルの宣言の一覧（丸ごと読まない。理由は `/flix-docs`） | `bin/fge refactor show` / `search` / `outline` |
| 直す前に周り（本文・呼び手・呼ぶ先・型）を 1 回で見る | `bin/fge refactor context <名前>`・呼ぶ先の木は `trace` |
| 名前の使われ所・呼び手を探す（grep より先に・読むのは道具が出した行だけ） | `bin/fge refactor usages <名前>`・欄を書く所だけは `--write` |
| 使われない pub・use を探して消す・pub を外す | `bin/fge refactor usages --unused` → `remove-dead`・`make-private`・`remove-use` |
| fpkg で配るライブラリの pub を替える・消す（「索引の外にもいる」と断られた時。外の使い手は直らない） | 同じ操作に `--allow-external` |
| record の欄の直の読み書きを口の関数へ替える（口が無ければ作る） | `bin/fge refactor field-to-accessor` |
| 欄の読みを別の引数の同じ欄へ（`w#x` → `res#x`） | `bin/fge refactor retarget-field` |
| 関数・型 alias・enum を別の mod へ移す（呼ぶ所・case の修飾名と use も） | `bin/fge refactor move --def Mod.f --to Mod2` |
| 関数・型 alias・record の欄の名前を替える（sed で替えない） | `bin/fge refactor rename Mod.f --to g`・欄は `rename --label x --receiver T --to y` |
| 宣言の effect の列（`\ A + B`）を足す・外す | `bin/fge refactor change-signature --def Mod.f --add-effect E`・`--remove-effect E` |
| 手で直した後に、書き換えの後と同じ確かめを流す | `bin/fge refactor verify`（`--with-tests` で verifyTests） |
| record の型に欄を足し、組み立てる所すべてに値を入れる | `bin/fge refactor add-field` |
| 同じ形の式をまとめて書き替える（lint の規則の直しなど） | `bin/fge refactor rewrite --from --to`・`--rule <規則>` |
| 式を関数に出す・同じ形の写しも呼び出しへ | `bin/fge refactor extract-function <範囲> --name Mod.f --all` |
| record の型に名前を付け、同じ欄の組の所を全部その名前へ | `bin/fge refactor extract-type-alias --name Mod.T` |
| `case _` を書き出す・record や case の欄・引数を足す・消す・替える | `bin/fge refactor --help` |
| ゲームを配る（Java の無い Mac・Windows・Linux・Steam Deck で遊べる形に。jar・JRE・起動を 1 本に） | `make dist-macos` / `dist-windows` / `dist-linux` / `dist-all`（置き方は engine の `docs/dist.md`・Deck は `docs/steam-deck.md`） |
| 重い処理を順に流す | `bin/fge heavy <コマンド>`（`--help`・`--status`・`--history`） |
| 作業場を別の版のエンジンへ一時的に向ける | `bin/fge use-engine <版かパス>`・戻すは `--restore` |
| 案を並べて依頼主に選んでもらう | `reports/<名前>/proposal.json` → `bin/fge proposal` |
| ドット絵を描く・直す（台本・絵の種類で検査が決まる） | `/pixel-art` → `*.px.star` か `*.pxsrc.json`（`"kind"`）を `bin/fge px build` |
| 絵の周回を残す・戻す（次の手は next・止め時は stop） | `bin/fge px snap` / `rounds snap` / `restore`（出る案内に従う） |
| AI が素材（絵・音）を作る・直す | `atelier/` に書く（`assets/` はスロット。採用は swap） |
| 道具の選び方が文書で伝わるか測る | `make agent-eval`（お題は `agent-eval/*.json`） |

新しい仕組みを入れる人は、この表（ゲーム固有なら `AGENTS.local.md`）に 1 行と `agent-eval/` のお題を 1 本足し、
`make agent-eval ONLY=<お題>` で当たるのを確かめる。**足すのと対で、まとめられる行はまとめ、使われなくなった行は消す**。

## 判断の向き（機械では止められない物）

- **エンジンにある物（メニュー・スクロール・文字折り・当たり判定・地形・音のバス・長押し…）を自前で書かない**。ゲームに
  自前の物があってもエンジンの物を選ぶ。早見表で道具が決まればそのまま使い、表に無い時だけ `make module` / `make api` で引く。
  使い方はモジュール冒頭の doc と `templates/` が正。「一番高い API で書けたか」を疑う。
- **言葉は業界の語**（カタカナか英語）で、説明は平易に。造語・比喩・このリポだけの意味を作らない。
  名前は業界の語 → 他のエンジン（迷ったら Bevy）の順に探す。動詞は `load`/`fetch` 外から取る（失敗しうる）・
  `build`/`compute` 計算して作る・`with` 新しい値を返す・`to` 作り直す / `as` 見方だけ変える（`is`/`get` は lint が見る）。
- **取り違えは型で止める**。外から作らせない値は pub mod の中の非 pub の enum + `pub type alias`、音の名前は
  `Sfx[Shot]` / `Loop[Hum]`（`/flix-docs`）。新しく作る型と、直すついでの所から使う（一度に全部は替えない）。
- **データは Doc・振る舞いはコード**。調整する数値・rows・色・**プレイヤーの目に入る文言**は Doc（コードには既定値だけ）。
  描き方・演出の形・ルールはコード。ロジックを JSON に書き始めたら設計の匂い。
- **テストはルール・進行・収支と、JSON とコードの橋渡しだけ**。期待値は Doc の既定値から導く（`/quality-assurance`）。
- 生成したコードは初学者が読める形に（読む順の README・毎フレームの流れの doc は `templates/` にある形を保つ）。
- 区切りごとに `NOTES.md` の先頭へ「今どこまで・次やること」を 3 行。広い探索はサブエージェントに任せ、結論だけ返させる。
- 絵を描く前に `.claude/rules/drawing.md` を読む。入口はドット絵 `/pixel-art`・格子に乗らない絵 `/smooth-render`。
  絵を委ねる親は prompt に「N 周まで」と文で書かず、drawing.md の「絵の周回」を指す（周を任せる時は snap の `--max N`）。
- 作業に入る前に当たるスキル（一覧は末尾）を読む。サブエージェントには rules とスキルの自動読みが効かないので、
  委ねる親は読ませる rules とスキルを prompt で名指しする。
- フックの無いエージェントは手で: 最初に `make status`・`.flix` を直すたび `make check`・clone ごとに `make hooks`。
  スキルの実体は `.claude/skills/<名前>/SKILL.md`（Codex は `.agents/skills/`・`.codex/hooks.json` は project trust の後に効く）。
- 「engine の `docs/…`」はゲームの `Makefile` の `ENGINE` が指す所にある。
