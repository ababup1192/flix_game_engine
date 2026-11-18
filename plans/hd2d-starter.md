# templates/hd2d-starter — 5 本目のテンプレート（HD-2D の昼の町を歩き回る）

人の決め: bench/hd2d_town/PLAN_final_video.md の 9 節（F9）。R1（この枝の上で作り、engine の枝と 1 回のリリースで出す。リリースはしない）・
T1（TileMap3d など地図から立体を組む作りはテンプレートに写しで持つ・engine 無改修）。手順は `.claude/skills/add-template/SKILL.md` の 1〜8。

## 中身

bench/hd2d_town のブラウザ版（`make explore` / `explore-web`）と同じ昼の町を歩き回る物。

- 操作: キー（矢印と WASD・2 つ押しで斜め）・パッドと画面のスティック（`frame#leftStick`・`web.virtualPad.stick`）。
- 歩く速さ 4.85 m/秒・コマ替え 0.24 秒・先頭の円の半径 0.3 m・隊列の間 1 m（explore.json の今の値）。
- ぶつかり: 地図から通れないマスの格子（CollisionGrid）・円を壁に沿って滑らせる・建物の北で足元が隠れる行と、軒の下の脇の列を塞ぐ（seenHeight 0.9・hideReach 8）。
- 仲間 2 人は先頭の通った道（FollowTrail）をなぞる。止まると息遣いのコマ。
- カメラ: 先読み 0（aheadMeters 0）・高さは遅れて追う（heightLagK 12）・引き 1.35・lensShift で水平のまま見下ろす。
- 広場のにぎやかし（屋台・行商人・風船の子ども・犬・立ち話の 3 人・馬車と馬・鳩）。鳩と風船は通れる。
- 描き方: 太陽の影（4096）・板の人形の影（withShadowCasterScale 0.6×0.8）・Physical の光の単位・後がけ（AgX・露出・DoF・色の掛け目・周りを暗く・FXAA）。
  板は来た順で同じ絵が続くと engine の instanced draw で 1 回になる（テンプレート側の手当ては要らない）。
- 描き方の重さ: explore.json の quality（shadowMapSize・depthOfField・post）。実機は環境変数 SHADOW_MAP・DOF・POST、ブラウザは頁の ?shadow=・?dof=・?post=。

## 入れない物（bench に残す）

撮影の台本（Route・Party の台本・BuildVideo・Video・FinalCut）・出来ていく演出（Buildup・TownGpu）・夜・夕方・霧・炎・氷（StageFx・TimeOfDay）・
音のファイル（BGM・効果音とも）・PeriTune の曲とクレジットのカード（explore.json の music 節・`WEB_BGM`・クレジットの字）・
板の draw の内訳と格子の字の地図（`make explore-draws` / `explore-grid`・BenchRun・BenchEnv の測る口）・1 コマの診断の HUD（debug=1）。

## 作る物の一覧

### src/（モジュールと受け持ち）

| ファイル | 中身 | 元 |
|---|---|---|
| `Main.flix` | 実機の入口（LwjglLayer・`App.loadAndLaunch`・環境変数のつまみ・`App.onRenderRequest(SceneRender.allShots)`） | Explore.main |
| `Game.flix` | App の組み立て（実機・ブラウザ・テストで共有）。`Resources.With[Res, World]`・系・View・後がけ・`withDocTable`・`withShots` | Explore.appOf |
| `Res.flix` | 描く元の束: Doc（map・look・explore・keys）・読み込んだ絵の表（Images.Loaded の Map）・組んだ町・動かない板・格子・レンズ・目の位置・立ち始めの床・足元の奥行き・隠れの決まり。`load`（絵を読む）と `build`（読んだ絵から組み直す。Doc の読み直しはこちらだけを使い、絵は読み直さない） | Explore.load / Res |
| `World.flix` | 遊びの状態だけ: `time` と `screen`。`Screen { Walk(Party) }`（1 画面でも enum から）。`Party` は非 pub の 1 case の enum + `pub type alias`（先頭の足元・向き・道・歩きの時計・動いたか・カメラの遅れ）。`initial`・`step`・`stepWith`（純粋） | Explore.World / step |
| `Facing.flix` | 向きの enum `Dir`（n・e・s・w）・字から読む・単位の向き・動きから近い 4 方向 | Route.Dir / Explore.dirOf |
| `Controls.flix` | 入力（キーとスティック → 長さ 0〜1 の向き）と Doc の読み直しの表（`Resources.reloadRow`: explore・keys・look・map。settle は World の先頭を通れるマスへ収める） | Explore.inputOf / ExploreDoc.loadKeys |
| `ExploreDoc.flix` | explore.json（歩きの手触り・カメラ・隊列・描き方の重さ）を読む。音の欄と music は持たない。隊列（party）と feetV・息遣いの秒はここへ移す（bench は台本 buildup_center.json から読んでいた） | ExploreDoc + Buildup.Plan の一部 |
| `KeysDoc.flix` | explore.keys.json（4 方向のキー） | ExploreDoc.loadKeys |
| `TownMap.flix` | 地図の Doc を読む（昼の町に要る欄だけ。下の「削る物」） | TownMap |
| `TileMap3d.flix` | 地図から面と板を組む（昼の町に要る物だけ） | TileMap3d |
| `Faces.flix` | 面（四角）と形にする口 | Faces（Owner を外す） |
| `Images.flix` | 絵を画素にする口（javax.imageio・decoder）・足元の楕円の影の絵 | Images（火袋とハローを外す） |
| `TownLook.flix` | 昼の見た目の Doc を読む（夜・時刻の移り変わりは持たない） | TownLook の頭 |
| `TownScene.flix` | 組んだ町と絵から 1 コマの 3D の場面（staticGroup・板・太陽・影・後がけ） | TownScene の昼の分 |
| `TownCamera.flix` | lensShift のレンズ・目の位置・遅れて追う量 | TownCamera |
| `CollisionGrid.flix` | 通れるマスの格子と円の滑り | CollisionGrid |
| `FollowTrail.flix` | 先頭の通った道 | FollowTrail |
| `Walkers.flix` | 隊列の 1 人の絵（向き → 帯の段と反転・息遣いのコマ） | BuildVideo.dirCell / idlePose |
| `View.flix` | 頭に層の並びと絵の下限 5 性質の受け持ち。1 コマの場面（町＋隊列＋にぎやかし）と後がけ | Explore.sceneOf |
| `Shots.flix` | ギャラリーの場面の World（title = 立ち始め・plaza = 広場・avenue = 北の大通り） | 新 |
| `render/SceneRender.flix` | 窓を開かず CPU（SoftRaster）で描き出す（make render / render-all） | Video.fullSceneOf |
| `render/ShotClock.flix` | 描き出しの時刻（後がけの時刻） | 同名 |
| `web/WebMain.flix` | ブラウザの入口（`?shadow=` などのつまみ） | web/WebMain |

### assets/

| ファイル | 中身 |
|---|---|
| `town.map.json` + `map.schema.json` | bench の `town_final.map.json` から、昼の町を歩き回るのに要る欄だけ（ground・height・shape・objects の格子・groundTiles・legend・margin・buildings・camera.frame・props・curbRaise・coping）。`walk`（撮影の台本）を外し、col 13 の行 37〜39 の 1・2・3（bench では隊列に置き換えていた町の人）を消す。`variants.step` は平らに上へ出す（curbRaise・coping） |
| `town.look.json` + `look.schema.json` | 昼の見た目（bench の `town.json` と同じ値） |
| `explore.json` + `explore.schema.json` | 歩きの手触り・カメラ・隊列（party の list）・描き方の重さ。music 節は無い |
| `explore.keys.json` + `keys.schema.json` | キーの割り当て |
| `sprites/*.png`・`tiles/*.png` | 昼の町が使う物だけ（読み込みで実際に引いた道の一覧で決める） |
| `PixelMplus10-Regular.ttf` | 描き出しのフォント（rpg-starter と同じ・CREDITS に書く）。HUD の字は出さない |
| `CREDITS.md` | 絵の出どころ（Codex で生成したドット絵とその条件・Poly Haven は使っていない）とフォント |

### 根

- `Makefile`（rpg-starter の頭の 4 つを写す・`SHOTS := title plaza avenue`・PALETTE は決めない・`precommit-local` なし）
- `project.json`（1280×720・textures は使う板の絵だけ・sounds は空・editor.resources・web 欄）+ `project.schema.json`（rpg-starter の写し）
- `flix.toml`・`devbox.json`・`.gitignore`（rpg-starter の写し）・`AGENTS.local.md`（画風の宣言）・`README.md`（遊び方と作り）
- `reference/title.png`・`reference/SHA256SUMS.txt`・`reference/ITEMS.tsv`（`make reference-update`）
- `test/TestTown.flix`（地図の読み・面の向きと uv・ハッシュ・カメラの式・段と階段の足元）・`test/TestExplore.flix`（格子・滑り・建物の北と脇・仲間の道・向き・先読み）・`test/TestDocs.flix`（Doc が読める・既定値と同じ）
- `lint/rules.flix` は持たない（下の「決めた事」）

### project.json の web 欄

`{ "startPrompt": "タッチして開始", "keysDoc": "assets/explore.keys.json", "orientation": "landscape", "virtualPad": { "stick": true } }`。
lossyImages 無し（ドット絵）・deferred 無し（待てる暗転が無い）。

## 削る物（写す物の中の、昼だけでは要らない分岐）

| 元 | 削る物 |
|---|---|
| TownScene | StageFx（炎・氷の材質・粒・空の映り込み・崖の光る縁）・街灯の点光源と点光源の影・火袋とハローの光る板・地面を這う霧の板・陽炎・夜の板の明るさ（lampLit・charLit・litToNightTint・BoardLight）・キャラの影の比べ用 4 案（Silhouette だけ残す）・extraLamps・withLook・memberBoard・sceneWith・postFlashAt の flash |
| TownLook | 夜・夕方・霧の欄（lamp*・lantern*・halo*・groundFog*・heightFog・boardLamplight・boardNightBase・charNight*・charGain・charToNight・glowAlpha・litToUnlit・pointShadows・heatHaze・stage*・extraLamps・charShadow）・時刻の移り変わり（Rows・Transition・TimeOfDay・Schedule・atRow・blend・nightfall・daybreak）・billboardTextures は Res が決める |
| TownMap | 地面の RockTop・SnowPath・SnowTop・Path・Dirt（昼の町は g・c・w だけ）・rockBoxes・rockBoxTop・tileOverrides・waterUv（PerCell だけ）・objectSprites・walk（台本・隊列）・walkPath・variants（curbRaise・coping は上へ） |
| TileMap3d | rockBoxQuads・materialKey と tileOverrides の上書き・skipNpcColumn・objectSprites の板 |
| Faces | Owner（出来ていく演出の部品分け） |
| Images | lanternGlowOf・halo・denseShadow |
| Explore | music・creditAlpha・クレジットのカード・debugItems・drawBreakdown・printGrid・gridText・BenchEnv・BenchRun |

## 決めた事

- **画面は enum**: `Screen { Walk(Party) }` の 1 case から（表紙を足す時は case を足す）。時刻は World の欄。
- **Doc の読み直し**: explore・keys・look・map を `Resources.reloadRow` で読み直す。絵は読み直さず、Res が持つ読み込んだ絵の表から組み直す
  （地図に新しい絵の名前を書いたら、その板は起動し直すまで出ない。WhyNot は Controls に書く）。
- **地図の schema**: `map.schema.json` を sections 方言で書く（格子は `grid`・建物と props は `list`・margin と camera は `record`）。
  doc-shape の除外は足さない。
- **画風**（AGENTS.local.md）: 昼の南欧の港町の石畳を斜め上から。色 3 つ＝下地: 砂岩とクリームの石灰岩（#e2d8c4）・主役: 旅の 3 人の服（ティールの外套 #3f8f86）・差し色: 朱（#d0583c・日除けと花だけ）。
  光＝淡い金（#fff0d6）・影＝空の青紫（#84a0dc）。やらない事: 黒い影と黒い輪郭（影は青紫まで・夜にしない）。
- **色の検査（palette）**: sprite.json を持たないので `make lint ONLY=palette` は検査する物が無く通る（PNG の色は生成の条件で決めた）。
- **lint/rules.flix**: 持たない（flixlint の規則はテンプレートの App の境目・View・規則の側の層の分け方が前提で、このテンプレートの層の数では足りないため。lint-flixlint は lint/rules.flix がある時だけ走る）。
- **描き出し**: CPU（SoftRaster）で design 320×180 × scale 4 = 1280×720。影の地図は描き出しでは 2048 に落とす（時間）。
- **音**: ファイルを 1 本も入れない。足す時の口（project.json の sounds・App.withSustained）は README に 1 行。

## 確かめる事

- `make -C templates/hd2d-starter check`・`test`・`render-all`・`reference-update`・`make lint ONLY=palette`・doc-shape
- Studio の worktree で Genesis.flix の families に HD-2D を足す → テスト → コミット（push しない）→ swap-jar（Studio が動いていれば入れずに報告）
- `make new-game GAME=<scratchpad の下> NAME=x TITLE=題名 TEMPLATE=hd2d-starter` → check・test・render 1 枚・音のファイルが 0 本
- 移行のメモ（docs/migrations/0.102.0.md に lensShift の欄）・早見表とお題（lensShift・Physical・点光源の影・withShadowCasterScale・HeightFog・Distortion の型紙・virtualPad.stick・板の instanced draw）

## 1 回目のレビュー（72 点）の後に直した所

上の表と食い違う所は、この節が正。

- **M1 小物の Doc を分ける**: `assets/town.decor.json` + `decor.schema.json`（広場の小物と NPC の list・18 件 → 見出しで「西の屋台」「東の子どもと犬」「北東の立ち話」「馬車」「鳩」に分ける）。地図から props を外す。読み直しは地図と別の行。
- **M2 地図の 3 階層を平らに**: building の roof を項目へ平らに出す（roofKind・ridge・pitchDeg・overhang）。格子は `"kind": "field", "type": "grid"`（rpg-starter の rows と同じ）。
- **M3 効かない欄を残さない**: look の shadowMapSize は持たない（explore.json の quality だけ）。地図の camera を外し、目の高さを決める 3 つ（frameWidth・frameV・frameGroundZ）は explore.json のカメラの group へ。legend は外し、字の意味は map.schema.json の grid の label と note に書く。heightStep は地図に残す（段の高さは地図ごとに決める値）。
- **M4 道の欄を外す**: explore.json の map・look・plan は持たない。Doc の道はコードで固定（`Res.mapPath()` など）。
- **M5 読み直しの fail-open**: 読み直しで読めなければ前の Res のまま `Log.fellBackThen` で 1 行。起動で地図・小物が読めなければ止める（`loadOrBug`・error-handling.md の「起動時の必須入力」）。look・explore・keys は fail-open（既定値）。テスト: 壊れた地図を読み直しても Res が変わらない。
- **M6 描き出しと実機で同じ View**: SceneRender は `View.frame` と `View.postOf(res, w)`（Game と同じ）を呼び、大きさは `View.size()`（1280×720）1 か所。描き出しは design 1280×720・scale 1。影の地図を落とすのは Quality のつまみ（`ExploreDoc.qualityWith`）を通す。
- **M7 テストの置き場**: `test/` はその場で書いた JSON だけ（地図の読み・格子・滑り・建物の北と脇・仲間の道・向き・先読み・Doc の fail-open・Shots のどの名前も World を組めて先頭が通れるマスに立つ・地図の読み直しの settle）。本物の Doc の具体値（立ち始めのマスが通れる・板の絵が全部 project.json の textures にある・広場の屋台が塞ぐ）は `sample-test/` + `new-game.exclude`（sound-novel-starter と同じ）。ただし「板の絵が全部 textures にある」はゲームでも守るべき性質なので test/ に置く（本物の Doc を読んで、名前の集合の包含だけを見る）。
- **M8 ブラウザの入口**: 根の `web/WebMain.flix`。つまみの読み（`Knobs.ofPairs`・純粋）は src の小さいモジュール `Knobs.flix`（環境変数を読む口は Main に置き、java.lang.System を Knobs に入れない）。確かめる事に `bin/fge export-web templates/hd2d-starter --check` を足す。
- **M9 lint/rules.flix を持つ**: tidepool の rules.flix を写し、「このゲームの表」の節を直す（View の入口 `View.frame`・Controls・入口の allowIn）。Makefile の `precommit-local` も写す。
- **M10 E2e と flow を持つ**: game-starter の E2e を写す（役 left・right・up・down・cancel、問い x・y・quit）。`e2e/walk.flow`（北へ歩いて広場の北へ着く）と `e2e/vocab.json`。
- **M11 README のテンプレートの表**（英・日）に行を足す。
- **任意から取る物**: ShotClock を持たない（昼は heightFog も陽炎も無い）。Prop → 絵の表を 1 つにし（TileMap3d）、読む道はそこと小物・隊列から作る。帯のコマ割りと 32 テクセル/m は `Walkers.cellOf` と `TownScene.texelsPerMeter()` の 1 か所。isCharacterSprite・withCamera・litLights・decorBoards の drop・Idle の enum（Step を外し idleStrip を必須に）・BoardLight・CharShadow・bloom の欄・staticBoards の WhyNot を削る。look と explore を group で束ね、全 Doc に version・title・note。終了の確認（Esc・閉じるボタン → 「終了しますか？」）を game-starter から写す（World の欄 quit）。AGENTS.local.md に早見表、AGENTS.core.md に「HD-2D の町を始める」の 1 行と agent-eval のお題 1 本。画風の「やらない事」は 1 つ「影を黒にしない（影は青紫まで）」にし、光と影の色は look の sunColor・ambient と結ぶ。palette は F9 の「色票は Look の Doc の色に合わせる」から外れる（sprite.json を持たないので色票を作らない）事を明記。web 欄の keysDoc は残す（ブラウザでもキーボードで歩けるようにキーの割り当てを渡す）。言葉は「台本」→シナリオ・「にぎやかし」→広場の NPC と小物・「息遣い」→待機モーション（idle）・「後がけ」→ポストプロセス。project.json は rpg-starter の並び（version・windowWidth・windowHeight）。
- **確かめる事に足す**: 3 枚の CPU 描き出しの時間・reference-check を 2 回流して同じ SHA・テンプレートの中で `../../bin/fge refactor search Town`・`make lint`（record-wrap・state-shape）。bench の測りのスクリプト（check-external・determinism・gl-capture）には入れない（テンプレートは TEMPLATE_DIRS で test-all と reference-check に入るので足りる）。

## 実装で決めた事（e9e34b7b の後・この節がいちばん新しい）

- lint/rules.flix は持たない（flixlint 0.9.0 が engine の Scene3d.LightUnits・Camera3d.lensShift を解けず、事実を集める所で止まる。bench/hd2d_town の refactor の索引が作れないのも同じ原因）。Makefile に WhyNot。flixlint が追いついたら tidepool-starter の物を写す。
- 地図の groundTiles を外した（町の材質の表と同じ絵だった）。隊列の tint を外した。web 欄の keysDoc を外した（スティックだけなので要らない）。ShotClock は持たない。
- 小物は `market.decor.json`（12 件）と `animals.decor.json`（6 件）。鳩と風船の「通れる」は小物の欄 passable（explore.json の passDecor は持たない）。
- 読み直しは map・decor・explore・look（カメラの角度が隠れるマスを決める）で格子を組み直して settle、keys は Doc を差し替えるだけ。読めない地図と小物は前の Res のまま 1 行言う（`Controls.mapReloaded` が理由を返し、`keptWarned` が言う）。
- 描き出しは design 1280×720・scale 1・影の地図だけつまみで 2048。4 枚で約 9 秒。
- 実装後のレビュー（78 点）の必須 4 件（look の読み直しの settle・ルートの README の表・読み直しの fail-open のテスト・explore.json の note の tint）を直した。
