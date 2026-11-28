# engine の effect と handler の切り方 — 棚卸しと計画（相談用・未着手）

状態: 計画（git に入れない）。棚卸しの数は main `fbb169854`（v0.113.1）で取り、glb の `53103da69`・`33eb1ab0e` が入った今の main `33eb1ab0e`（docs/migrations/0.114.0.md あり）で、handler の数・runNoop を案内する所・段 2 で直す所を確かめ直した（glb の 2 つは handler に触っていない）。roadmap-2026-11.md の 6 番（7 の native の組み立ての口・8 のデスクトップのストリーミングの土台）。
**事実**はソース・移行メモ・コミットで確かめた。**推測**は「推測:」と書く。
スパイクの枝: `worktree-agent-a32ee4d6944ddb0cf`（コミット `0f52ea6ce`・main にマージしない）。

## 0. 結論

- **新しい effect は作らない。分ける eff も無い。** 0.80.0 で `GameEngine.Game` の 28 op を役割ごとの 10 個に分けた形（Platform.flix の頭の WhyNot）で足りている。
- op や欄を 1 つ変えた時の直しは**ゲームへ広がっていない**。広がるのは engine の中の偽物の handler（テスト）だった。ゲームの自前の handler は、ワークスペースの 38 フォルダとテンプレート 6 本で、
  **engine の eff に限れば** `GameEngine.Audio` の 1 か所だけ（1.2）。ほかに `Fs.FileRead`・`Fs.FileWrite` の偽物が 7 か所あるが、Fs は Flix の標準の eff で、engine の版で op が変わらない。
  0.113.0 の 2 つの変更も、ゲームの直しは 0 か所（1.3）。
- 直すのは 3 つの小物だけ（新しい pub 0・外す pub 3・ゲームが書き換える行 0・合わせて 2 時間前後）:
  1. engine_world のテストの描かない handler の組を 1 つにまとめる（スパイク済み: 4 ファイルで 79 行減・engine_world 1815 緑）。ViewCtx を欄を全部書いて組むテスト 2 つは、今ある `App.viewCtxOf` からの差し替えへ
  2. 使い手が engine の自分のテストだけになった 3 つの pub（`LoadProgress.runNoop`・`Platform.runNoopDraw3d`・`RenderTarget.runNoop`）を外す（物差しの「2 つ目が無くなった層は外す」）
  3. デスクトップのストリーミングと native の絵の読み書きで、替える所と変えない所を 8・7 の計画の頭に書く表を作る
- 8（ストリーミング）は eff を分けなくても入る。ただし今の `LwjglLoad.handleWith` は downloads を受けず中で `localDownloads()` を返すので、
  **render_gl の pub が 1 つ変わる**（引数を足すか、別の def を足す）。ストリーミングを入れるかは、窓の決定性が要る道（台本・`bin/determinism.sh`・`FLIX_GE_FRAME_SHOT`・`FLIX_GE_SPLASH_SHOT`・`make gl-capture-check`）を全部知る入口が決める。
  「裏のスレッドで解く」所は handler の外（`BackgroundLoad` の decode）なので、それも 8 の計画で決める（3.3・5）。

## 1. 棚卸しの事実

### 1.1 pub eff と op の数（main `33eb1ab0e` で同じ）

| モジュール | eff | op の数 | 置き場 |
|---|---|---|---|
| Platform | `Input` | 9 | engine/src/platform/Platform.flix |
| Platform | `Window` | 12 | 同 |
| Platform | `FrameClock` | 1 | 同 |
| Platform | `Draw2d` | 3 | 同 |
| Platform | `Draw3d` | 2 | 同 |
| Platform | `Tasks` | 2 | 同 |
| Platform | `GpuResources` | 7 | 同 |
| Platform | `Diagnostics` | 2 | 同 |
| Platform | `Annotation` | 1 | 同 |
| RenderTarget | `Target` | 3 | engine/src/platform/RenderTarget.flix |
| GameEngine | `Audio` | 9 | engine/src/platform/GameEngine.flix |
| （根） | `LoadProgress` | 4（`report`・`runTasks`・`imageDecoder`・`downloads`） | engine/src/platform/LoadProgress.flix |
| （根・render_gl） | `WebGpuDevice` | 1 | render_gl/src/WebGpuDevice.flix |
| Flix の標準 | `Fs.FileRead`・`Fs.FileWrite`（ほかに `Fs.FileTest`・`Fs.DirList`） | 標準のまま（engine の版で変わらない） | Flix の標準ライブラリ。docs/flix-conventions.md の「層を置く物差し」は機種の handler 一式に入れている |
| GameLogger | `GameLogger` | 5 | engine_world/src/GameLogger.flix |
| （根） | `Loop[s]`・`Emit[e]`・`Sfx[s]` | 1・1・1 | engine_world/src/ |

- `Platform.Services` = `Input + Window + FrameClock + Rendering + RenderTarget.Target + GameEngine.Audio + Diagnostics + Tasks`（`Rendering` = `Draw2d + Draw3d + GpuResources`）。
- op の形でなく **関数の record** で差し替える口が 2 つある: `ImageData.ImageDecoder`（欄 4・`LoadProgress.imageDecoder` が返す）と `LoadProgress.AssetDownloads`（欄 11・`downloads` が返す）。
  record にしている理由は、effect の handler がスレッドをまたがないから（並列の仕事の中で絵を解く・ループの中で取り具合を引く。LoadProgress.flix の op の doc）。既定で埋める関数がある: `ImageData.decoderOf`・`ImageData.failingDecoder`・`LoadProgress.localDownloads`。
- engine_world の 4 つ（GameLogger・Loop・Emit・Sfx）はゲームの論理の中の eff で、機種で差し替える物ではない。棚卸しの外に置く。

### 1.2 handler を実装している所（`handler <eff>` の行を数えた）

| eff | デスクトップ | ブラウザ | 画面なし・ベンチ | テストの偽物 | ゲーム |
|---|---|---|---|---|---|
| `Input` | LwjglInput | WebLayer | GlOffscreen・bench webgpu_v1/v2・`App.Internal.InputScript`（上に重ねる） | TestDeterminism | 0 |
| `Window` | LwjglLayer・WebGpuWindowLayer | WebLayer・WebGpuLayer | GlOffscreen・bench×2 | — | 0 |
| `FrameClock` | LwjglLayer | WebLayer | GlOffscreen・bench×2・InputScript（上に重ねる） | TestDeterminism | 0 |
| `Draw2d`・`Draw3d`・`GpuResources` | PaintHandlers（GL）・WebGpuPaint | WebLayer（Draw2d・Draw3d を下へ流す） | 同じ PaintHandlers・WebGpuPaint | engine_world/test の 4 ファイルに 6 組・`Platform.runNoopDraw3d`（使い手は engine/test の TestPlatform の 1 本だけ） | 0 |
| `RenderTarget.Target` | PaintHandlers・WebGpuPaint | （同） | — | engine_world/test の 2 ファイル（TestLetterboxView・TestStaticLayers）・`RenderTarget.runNoop`（使い手は engine_world/test の TestPassPlan・TestPreload3d だけ） | 0 |
| `Fs.FileRead`・`Fs.FileWrite` | 標準の handler（`Fs.FileRead.runWithIO` など） | `WebFs.runFileRead`・`runFileWrite`（engine_web/src/WebFs.flix） | 標準の handler・`ContentCache` が記録する handler を重ねる | engine のテストに 5 か所ほど | **7**（templates/sound-novel-starter/test/TestRules.flix 580・584 行と、ワークスペースの 6 フォルダの同じファイル） |
| `GameEngine.Audio` | LwjglLayer | WebLayer | — | — | **1**（templates/sound-novel-starter/test/TestAudio.flix・`audioSeconds` だけを見るのに 9 op を書く） |
| `Tasks` | LwjglLayer | `Platform.runTasksInPlace` | 同 | — | 0 |
| `Diagnostics` | PaintHandlers・WebGpuPaint | （同） | — | — | 0 |
| `Annotation` | LwjglLayer・WebGpuWindowLayer | — | GlOffscreen・bench×2 | — | 0 |
| `LoadProgress` | LwjglLoad | WebLayer | HeadlessLoad | engine/test 2 ファイル 4 か所・engine_world/test 3 ファイル 3 か所・`LoadProgress.runNoop`（使い手は engine/test の TestLoadProgress の 3 本だけ） | 0 |

- ゲームの数は、ワークスペース（`~/Documents/flix_ge_workspace` の 38 フォルダ）とテンプレート 6 本の .flix を数えた。`ImageData.ImageDecoder` を欄を全部書いて組む所も 0、
  `LoadProgress.AssetDownloads` は `{ missing = .. | LoadProgress.localDownloads() }` の形で組む所だけ（haioku 系の TestHold）。
- ゲームが読み込みの中で呼ぶ op は `LoadProgress.report`・`imageDecoder()`・`downloads()` だけ。ゲームの effect の行に `LoadProgress` を書いた行はワークスペースで 50 行（23 フォルダ）・テンプレートで 3 行。
- 画面なしの入口は、ほぼ全部が `HeadlessLoad.handle`（ワークスペースで 81 ファイル）。
- **「描かない・読まない」の pub の handler 3 つは、使い手が engine の自分のテストだけ**: `LoadProgress.runNoop`（TestLoadProgress の 3 本）・`Platform.runNoopDraw3d`（TestPlatform の 1 本）・
  `RenderTarget.runNoop`（engine_world/test の TestPassPlan・TestPreload3d）。src・テンプレート・bench・ワークスペースのゲームは 0（night_apartment のコメントに runNoop の名前が残るだけ）。
  docs/startup.md 48 行と agents-pack/AGENTS.core.md 123 行が「絵を解かないなら runNoop」と案内しているが、従ったゲームは無い。
- `LwjglLoad`（102 行）と `HeadlessLoad`（107 行）は doc 以外で同じ本体（スレッドの pool・javax.imageio のデコーダー・`localDownloads`）。層どうしが互いを見ないため 2 つある（両方の WhyNot）。
  同じである事は `make lint ONLY=load-copy`（Makefile 720 行・`pollMillis` と「PNG / JPEG を javax.imageio」から下を比べる・既定の lint に入っている）が守る。
  決まりは両方とも `LoadProgress.Conformance` で確かめ、downloads が全部届いている事もテストがある（`TestLwjglLoad`・`TestHeadlessLoad` の `testDownloadsHasNothingLeftToFetch`）。
- デスクトップの project.json の textures はすでに stb で解く（`LwjglAssets`・`STBImage.stbi_load`）。AWT（javax.imageio・BufferedImage）が残るのは:
  - `LwjglLoad` のデコーダー（glb の中の絵など、ゲームが読んだバイト）
  - GL の窓の読み出し: `GlReadback.readBoundImage`・`readBoundImageRgb`（BufferedImage を返す）・`readBoundPng`（中で `ImageIO.write`・GlReadback.flix 61 行）。`LwjglLayer` が frame の書き出し（LwjglLayer.flix 112 行の `readBoundPng`）と注釈（129 行の `framebufferImage` → `readBoundImageRgb`）で呼ぶ
  - BufferedImage を持ち回る所: `LwjglLayer.writePngFile`・`burnHighlight`・注釈の `capture`、`WebGpuWindowLayer.imageOf`・`frameImage`・`writeShot`、`GpuOffscreen.readImage`（画面なしの道具用）
- `FLIX_GE_INPUT_SCRIPT` を読むのは engine_world（`App.Internal.DevTools` 148〜161 行・`App.Internal.InputScript`）だけ。`FLIX_GE_FRAME_SHOT`・`FLIX_GE_SPLASH_SHOT` は render_gl の `LwjglEnv` が読む。
  render_gl は engine_world を見ず、engine_full には自分の mod が無い（src は層の symlink だけ）。

### 1.3 過去に op・欄を変えた時の直しの広がり

| 版 | 変えた所 | 直した所（移行メモの記述・コミットで数えた物） |
|---|---|---|
| 0.73.0 | `RenderTarget.Target.beginTarget` を spec 1 つに・`pixelScale` を足す | 自前の Target の handler（テストのモックを含む） |
| 0.74.0 | `LoadProgress` を足す | 画面なし・動画・flow・テストの入口に runNoop（型の誤りで止まる） |
| 0.80.0 | `GameEngine.Game` の 28 op と `ShaderEffect.Shader` の 3 op を役割ごとの 10 eff へ | 自前の handler・自前のループ（effect の名前の付け替え） |
| 0.81.0 | `LoadProgress` に `runTasks`・`imageDecoder` | 自前の LoadProgress の handler・`*Using` へ替える呼び出し |
| 0.85.0 | `Platform.Window.getDisplay` | 「テンプレ・ゲームには無い。engine の LwjglLayer・GlOffscreen・WebLayer だけ」（移行メモ） |
| 0.86.0 | `Platform.Tasks` を Services へ | 同じく engine の 3 つだけ（移行メモ） |
| 0.88.0 | `Draw3d.preload3d` を足す | 手で書いたテストの Draw3d の handler |
| 0.89.0 | `LoadProgress.downloads`・`ImageDecoder` に欄 2 つ（`decoderOf` を足した） | 自前の LoadProgress の handler・ImageDecoder の record（ここから `decoderOf` へ） |
| 0.91.0 | `Input.gamepadSticks` | 入力を差し替えるテストの handler |
| 0.101.0 | `Draw2d.fillLetterbox` | 自前の Draw2d の handler（ゲーム・テスト） |
| 0.105.0 | `AssetDownloads` に欄 5 つ | テストで組む record（`{ .. \| localDownloads() }` の形へ） |
| 0.113.0 | `Draw3d.preload3d` の戻り値を `Scene3d.PreloadProgress` へ（`c8af19b70`） | 機種の handler 3（PaintHandlers・WebGpuPaint・WebLayer）と `Platform.runNoopDraw3d`（テストにしか使い手が無い）。engine_world/test は 6 ファイル: handler の偽物が 4（TestLetterboxView・TestPassPlan・TestPreload3d・TestStaticLayers）、`ViewCtx` の record を全部の欄で組む所への `preload3d` の足しが 2（TestRenderScene3d・TestZStack）。src の `ViewCtx` の組み立て 2（`App.viewCtxOfFonts`・`App.Internal.Paint.baseCtx`）。**ゲーム 0** |
| 0.113.0 | `ImageDecoder` に `platformImageOfBytes`（`92686a25d`） | 機種の handler 1（WebLayer）。`decoderOf` が既定で埋めたので、ほかの直しは 0。**ゲーム 0** |

- 移行メモの表は「自前で書いているゲーム」に向けて書いてあるが、0.85.0 以降で実際に直したのは engine の中だけだった（1.2 の数）。
- 推測: 0.80.0 より前（`GameEngine.Game` 1 つの頃）はゲームのテストが自前の handler を書いていた。今のゲームに残っていないのは、0.80.0 の後に `App` と `HeadlessLoad.handle` の入口がそろったため。

### 1.4 glb の読み込みの今の形（main `33eb1ab0e` に入った `53103da69`・`33eb1ab0e`）

- `Model3d.loader(): Model3d.Loader \ LoadProgress + Fs.FileRead` が `LoadProgress.imageDecoder()` と project.json の `"gltf"`（`ProjectLoader.Project#gltf`）を 1 つの値にまとめる。
  `Model3d.Loader` は非 pub の enum + `pub type alias`（外から作れない）。`Model3d.load(loader, path)`・`Model3d.decode(loader, path, bytes)`・`Gltf.decodeWith`。
- ゲームは glb のために `ImageDecoder` を持ち回らなくなる（テンプレートの `Bundles.group` は `Model3d.Loader` を受ける）。ゲームが `ImageDecoder` の欄を読むのは 2D の絵を自分で解く所だけになる（hd2d-starter の `Images.flix` の `decoder#decode`・ワークスペースで 6 行）。
- `Model3d.loader()` は**読み込みの頭で** `imageDecoder()` を受け取る。runNoop の下なら glb を 1 つも解かない道でも止まるが、runNoop の下で読み込みを流すゲームは無い（1.2）。

## 2. 分けると得をする所の候補と比べ

物差し: 差し替える理由が今ある（実装が機種・テスト・画面なしで 2 つ以上違う）か。新しい pub・ゲームの直し・engine の直しを数で見る。

### 2.1 effect を分ける・作る案（どれも採らない）

| 案 | 得 | 費用 | 新しい pub | ゲームの直し | 決め |
|---|---|---|---|---|---|
| A. `LoadProgress` を 3 つに分ける（進み具合と仕事・絵のデコーダー・届いた素材） | 型に「絵を解かない読み込み」が出る。テストが 1 つだけ差し替えられる | 3 つの op は同じ機種から同じ組で来る（1.2 のどの行も 3 つを同じ handler が持つ）。入口の handler が 3 つに増える | eff 2 | 50 + 3 行の effect の行のうち、`imageDecoder`・`downloads` を呼ぶ関数の分 | 採らない。違う所は機種ごとに一緒に動き、分けて差し替える理由が無い |
| B. `imageDecoder` を op にする（record をやめる） | 欄を足しても record の作り直しが要らない | handler はスレッドをまたがない。並列の仕事の中で絵を解けなくなる | eff 1 | 全部の読み込み | 採らない（できない） |
| C'. `AssetDownloads` を eff にする | 同上 | ループの中で引くので、ループを包む `Services` に入る。Services を張る組 7 つ（1.2）に足す | eff 1 | 0 | 採らない |
| D. `Draw3d.preload3d` を別の eff へ | 0.113.0 の直しが Draw3d の handler に広がらなかった | 描く 3 つは同じ組から張る決まり（Platform.flix の「積む op と出す op」）。組が 4 つに増える | eff 1 | 0 | 採らない。テストの偽物は 2.2 の A で 1 か所になる |
| E. デスクトップのストリーミング用の eff（例: 裏で読む物の口） | — | `downloads` の record が同じ事をすでに持つ（ブラウザが使っている） | eff 1 | 0 | 採らない |

### 2.2 effect の形は変えずに、直しの広がりを止める案

| 案 | 得 | 費用（実時間） | 新しい pub | ゲームの直し | 決め |
|---|---|---|---|---|---|
| **A. engine のテストの描かない handler の組を 1 つにする**（見たい op だけ内側の handler で受け、残りを捨てる組へ流す） | 次に Draw2d・Draw3d・GpuResources・Target の op が増えても、テストで直すのは 1 か所。スパイクで 4 ファイル 79 行減（7） | 30 分（スパイク済み） | 0（テストの中の mod） | 0 | **採る（段 1）** |
| A2. LoadProgress のテストの偽物も同じく寄せる（engine_world/test の 3 か所） | 次に LoadProgress に op が増えた時の直しが 3 → 1 | 20 分 | 0 | 0 | **採る（段 1）**。engine/test の TestLoadProgress は、決まりに外れた handler をわざと書く検査なのでそのまま |
| C(i). **使い手がテストだけの 3 つの pub を外す**（`LoadProgress.runNoop`・`Platform.runNoopDraw3d`・`RenderTarget.runNoop`）。テストは段 1 の `FakeRendering`・`FakeLoad` か、その場の偽物へ | 物差しの「2 つ目が無くなった層は外す」。docs が案内する道が `HeadlessLoad.handle` 1 本になり、「絵を解かないなら runNoop・解くなら HeadlessLoad」の選び分けが消える | 30〜40 分 | **−3** | 0（使い手 0。移行メモに 1 行・forbid.json で代わりを示す） | **採る（段 2）** |
| C(ii). runNoop を残し、デコーダーを「受け取ったら止める」から「解こうとしたら止める」へ | 絵を解かない道が runNoop の下で止まらない | 15 分 | 0 | 0 | 採らない。引っかかる呼び手が 1 つも無い（src・テンプレート・ゲームで 0）ので、守る相手がいない |
| F. LoadProgress の handler を「部品の record + 既定値」から組む関数（`LoadProgress.handleFrom(parts, f)`・`parts = { downloads = .. \| defaultParts() }`。`LwjglLoad.handleWith(onReport, f)`・`HeadlessLoad.handleWith(onReport, f)` と引数の意味が違うので名前を分ける） | op を足しても `defaultParts` が埋める。0.105.0 の `localDownloads` と同じ形 | 1 時間 | 2〜3 | 0 | 今はやらない。LoadProgress に op を足す予定が無い（8 は render_gl の handleWith の引数を変えるだけで op は足さない・native も足さない）。次に op を足す版で一緒に入れる（6 の 2） |
| G. `ImageDecoder`・`AssetDownloads` を外から作れない型にする（非 pub の enum + pub alias） | 欄を足しても外が止まらない | 欄を読むゲームの行（ワークスペース 6・テンプレート 1・bench 2）を取り出す関数へ替える | 4〜6（取り出す関数） | 約 9 行 | 今はやらない。既定で埋める関数（`decoderOf`・`localDownloads`）で、0.113.0 の外の直しは 0 だった |
| H. 音を鳴らさない handler（`GameEngine.runSilentAudio(secondsOf, f)`） | ゲームの唯一の自前の handler（TestAudio の 9 op）が 1 行になる | 20 分 | 1 | 約 10 行（テンプレート 1） | 人に決めてほしい（6 の 3）。推す答えは、次に Audio に op を足す版で一緒に入れる |
| I. `LwjglLoad` と `HeadlessLoad` の本体を 1 つにする | 同じ 95 行を 2 回直さずに済む | 置き場が無い。engine は契約層（java.util.concurrent・javax.imageio を入れない）・render_gl と engine_tools は互いを見ない。HeadlessLoad を render_gl へ移すと engine_tools のテストが render_gl を要る | 0 | 0 | 採らない。3.3 のとおり、2 つは今後わざと違う物になる（デスクトップだけ stb とストリーミング）。分かれる時は `load-copy` の lint を外さず、比べる範囲を pool の部分（`pollMillis` から `runOnPool`・`collect` まで）に縮め、デコーダーを比べる外へ出す（native (a) の段で Makefile 720 行の sed の範囲を直す）。downloads と `handleWith` の行は今も比べる外（`pollMillis` の 1 行と「PNG / JPEG を javax.imageio」から下だけを見る）なので、8 で `handleWith` の形が分かれても load-copy は通る |


## 3. 決めた形と段

### 3.1 段 1: engine_world のテストの偽物を寄せる（40〜60 分・スパイクの枝の形のまま）

- `engine_world/test/FakeRendering.flix`: `FakeRendering.runNoop(f)` が `Platform.Rendering` と `RenderTarget.Target` を全部捨てる（preload3d は `Scene3d.noPreload()`・字の無い `atlas()`）。
  見たい op はテストの中で内側の handler として重ねる（Flix の handler は eff ごとなので、内側に置いた eff だけがそちらへ行く）。
  `RenderTarget.runNoop` は**使わずに写す**（FakeRendering の中に Target の handler を自分で持つ。スパイクもこの形）。これで `RenderTarget.runNoop` の使い手が 0 になり、段 2 で外せる。
- `engine_world/test` の LoadProgress の偽物 3 か所（TestApp・TestAppBackgroundLoad・TestBootWorld）を `FakeLoad.run(onReport, downloads, f)` へ（runTasks は `LoadProgress.runTasksInOrder` で順に回す・デコーダーは `failingDecoder`）。
- `ViewCtx` の record を全部の欄で組むテスト 2 つ（TestRenderScene3d・TestZStack）は、`FakeRendering.viewCtx()` を**足さず**、今ある `App.viewCtxOf(atlas, design)` に違う欄だけを重ねる形
  （`{ warnOnce = .. | App.viewCtxOf(FakeRendering.atlas(), { x = 1.0, y = 1.0 }) }`。design を `{1.0, 1.0}` で渡せば visible と display は今のテストと同じになる）へ替える。既定値から組む関数はもう pub にあり、テストの側に 2 つ目を作ると同じ既定値の写しが増えるため。
  `ViewCtx` に欄が増えても、直すのは `App.viewCtxOfFonts` と `App.Internal.Paint.baseCtx` の 2 か所になる。
- 緑とする測り: `make test-engine_world` が全部緑（スパイクで 1815）。engine の src は触らない（gallery・gl-parity は動かない）。

### 3.2 段 2: 使い手がテストだけの 3 つの pub を外す（45〜60 分・agent-eval の確かめを含む）

| 外す pub | 今の使い手 | 移す先 |
|---|---|---|
| `LoadProgress.runNoop` | engine/test/TestLoadProgress の 3 本（runNoop そのものを見るテスト） | テストごと消す。順に回す handler の決まりは `LoadProgress.runTasksInOrder` のテストと Conformance が見ている。engine/test から engine_tools（HeadlessLoad）・engine_world/test（FakeLoad）は見えないので、engine/test に偽物が要る時はその場で書く（今は TestBackgroundLoad の `withFake` 1 つで足りる） |
| `Platform.runNoopDraw3d` | engine/test/TestPlatform の 1 本（runNoopDraw3d そのものを見るテスト） | テストごと消す。描かない Draw3d が要るテストは engine_world/test の FakeRendering を使う |
| `RenderTarget.runNoop` | engine_world/test の TestPassPlan・TestPreload3d（段 1 で FakeRendering へ移る） | 段 1 の後は 0 |

- runNoop を案内している所を同じコミットで直す（main `33eb1ab0e` で 7 か所）:

  | 所 | 直し |
  |---|---|
  | docs/startup.md 48 行 | 「絵を解かないなら `LoadProgress.runNoop`」を消し、`HeadlessLoad.handle` だけに |
  | agents-pack/AGENTS.core.md 125 行 | 早見表の行から runNoop を消し、`HeadlessLoad.handle` だけに |
  | engine/src/platform/LoadProgress.flix 13 行と、runNoop の WhyNot（119 行） | 頭の handler の組の説明から `runNoop = 順に回す` を消す。WhyNot は関数と一緒に消える |
  | engine_tools/src/HeadlessLoad.flix 3・18 行 | 「runNoop ではなく」「runNoop の代わりに」の言い回しを消す（画面なしの入口はこれ 1 つ、と書く） |
  | engine/src/scene3d/Model3d.flix 117 行（`Model3d.loader` の doc） | 「runNoop の下では imageDecoder で止まるので」を「画面なしは HeadlessLoad.handle で包む」だけに |
  | bin/lint-rules/fallback.json 15 行（`LoadProgress.flix::imageDecoder` の bug! を許す行） | **消す**。`bin/fge fallback` は、除外に載っているのにそこに bug! が無い行を「古い除外」として exit 1 で止める（go/internal/fallback/fallback.go 317〜323 行）ので、runNoop を消して行を残すと lint が赤になる |
  | agents-pack/agent-eval/engine.json 454 行（お題 load-progress） | expect の `LoadProgress\.runNoop` を `HeadlessLoad\.handle` に替え（why は「描き出し・テスト・flow の入口は HeadlessLoad.handle を張る」）、`LoadProgress\.runNoop` を avoid へ移す（why は「段 2 の版で消えた口。画面なしの入口は HeadlessLoad.handle」）。ゲームの足元で `make agent-eval ONLY=load-progress` が当たるのを確かめる |

- docs/migrations/0.114.0.md 26 行も「runNoop の下では止まる」と書いているが、過去の移行メモは直さない。新しい版の移行メモの 1 行（下）で済ませる。
- 古い書き方を止める: `bin/lint-rules/forbid.json` に `LoadProgress\.runNoop|Platform\.runNoopDraw3d|RenderTarget\.runNoop` を 1 行（代わり: 画面なしの入口は `HeadlessLoad.handle`・テストの偽物は自分で書く）。呼べば型の誤りでも止まるが、代わりの物を言うのは forbid の行。
  forbid は .flix の文字列とコメント（`//` の後と `///` の行）を落としてから当てる（go/internal/forbid/forbid.go 174・202 行）ので、night_apartment/src/Controls.flix 96 行の doc コメントには当たらない。docs の .md と移行メモは forbid の見る種類の外。
- 移行メモに 1 行（使っていれば `HeadlessLoad.handle` へ。数えた範囲のゲームでは 0）。
- 緑とする測り: `make test-engine`・`make test-engine_world` 緑・`make lint ONLY=forbid` と `make lint ONLY=fallback` 緑（古い除外が残っていない）・`bin/fge refactor search runNoop` に 3 つが出ない（消えている）・`make check-docs-sync`（api-digest の作り直し）・ゲームの足元（テンプレートから作ったゲーム）で `make agent-eval ONLY=load-progress` が当たる（engine の早見表とお題を直したので、AGENTS.md の「新しい仕組みを入れたら」と同じ確かめ）。

### 3.3 段 3: 8 と 7 で替える所の表（20〜30 分・docs だけ）

次の表を **8（デスクトップのストリーミング）と roadmap 3 / 7（native）の計画の頭**に置き、docs/startup.md の「ブラウザで素材を後から取る」（78 行）の隣に「デスクトップで後から取る時に替える所」として短く写す。
docs/flix-conventions.md の「層を置く物差し」には入れない（あの節は層の決まりで、個々の差し替えの手順を置くと読む所が増える）。

| したい事 | 替える所 | 変えない所 |
|---|---|---|
| デスクトップで後回しの素材を届いた物から返す（roadmap 8） | **render_gl の pub が 1 つ変わる**: `LwjglLoad.handleWith(onReport, f)` は downloads を受けず、中で `localDownloads()` を返している（LwjglLoad.flix 22 行）。downloads の引数を足すか、`LwjglLoad.handleStreaming(onReport, downloads, f)` のような別の def を足す（後者なら今の呼び手は直さない）。`LwjglLayer.handleLoadProgress`・`withProject` にも、downloads を渡す口が 1 つ要る | `HeadlessLoad`（downloads を受ける引数を持たない = 画面なし・テスト・テープ・gallery は毎回同じ）。`BackgroundLoad`・`App.withBackgroundLoad`・ゲームの読み込みのコード |
| ↳ ストリーミングを入れるかを決める所 | **ゲームの Main の入口か engine_full**。決定性が要る道を全部知っている所でないと決められない。render_gl は `FLIX_GE_INPUT_SCRIPT` を読む engine_world を見ず、engine_full には今は自分の mod が無い（1.2）。既定は**入れない**にし、窓で決定性が要る道では入れない: 台本（`FLIX_GE_INPUT_SCRIPT`）・`bin/determinism.sh`（隠しウィンドウの DEBUG で実機の道 `LwjglLoad` を通して記録する）・`FLIX_GE_FRAME_SHOT`・`FLIX_GE_SPLASH_SHOT`・`make gl-capture-check`（実機の窓から撮る）。どの形で入口に置くか（環境変数・project.json の欄・`withProject` の別の入口）は 8 の計画で決める | — |
| デスクトップの絵の読み書きを AWT から stb へ（roadmap 3 の (a)） | 解く: `LwjglLoad.imageIoDecoder`（`decodeImageIo`）。GL の窓の読み出し: `GlReadback.readBoundImage`・`readBoundImageRgb`・`readBoundPng`（`ImageIO.write`）。BufferedImage を持ち回る所: `LwjglLayer.writePngFile`・`burnHighlight`・`framebufferImage`・注釈の `capture`、`WebGpuWindowLayer.imageOf`・`frameImage`・`writeShot`。どれも Annotation の handler と frame の書き出しの中で、eff の形は変えない。BufferedImage の代わりに画素の配列（幅・高さ・argb）を持ち回る型にそろえる | `HeadlessLoad` と engine_tools（画面なしの道具は JVM のまま javax.imageio。SoftRaster も AWT）。`GpuOffscreen.readImage`（画面なしの道具が使う。native の窓の道から呼ばれないかは 7 で確かめる） |

- 穴: デスクトップ（stb）と画面なし（javax.imageio）で JPEG の解き方が違う。推測: 数値が 1〜2 違う画素が出る。PNG は同じはず。
  確かめは roadmap 3 の仕事に渡す: `TestLwjglLoad` に「同じ PNG を `LwjglLoad` のデコーダーと javax.imageio で解いて同じ画素」を 1 本（render_gl から engine_tools は見えないので、比べる側は render_gl のテストの中で javax.imageio を直に呼ぶ）。
  project.json の textures は今でもデスクトップが stb（`LwjglAssets`）・画面なしが javax.imageio なので、新しい種類の差ではない。
- 推測: native-image は `App.onRenderRequest(SceneRender.allShots)`（retro3d-horror-starter の Main）から画面なしの描き出し（AWT）まで辿る。7 の計画で「native の main から開発の道具を外すか」を決める。handler の境目には関係しないので書くだけ。
- 緑とする測り: `make check-docs-sync`（docs/startup.md のリンクと参照）・`bin/fge jargon`（新しく書いた行の言葉）。

### 3.4 段の大きさ（合計）

| 段 | 実時間 | 新しい pub | 外す pub | ゲームが書き換える行 | 移行メモ |
|---|---|---|---|---|---|
| 1 | 40〜60 分（スパイク済み） | 0 | 0 | 0 | 不要 |
| 2 | 45〜60 分 | 0 | 3 | 0（数えた範囲） | 1 行（使っていれば `HeadlessLoad.handle` へ） |
| 3 | 20〜30 分 | 0 | 0 | 0 | 不要 |

## 4. 穴の塞ぎ方（型 → lint → docs）

| 穴 | 型と API の形 | lint・門 | docs |
|---|---|---|---|
| 画面なし・テストに、裏のスレッドで届く downloads が入る（毎回同じでなくなる） | **今すでに塞がっている**: `HeadlessLoad.handle` / `handleWith` は downloads を受ける引数を持たず、中で `localDownloads()` を返す。8 でもこの 2 つに引数を足さない（WhyNot を 1 行足す）。テスト `testDownloadsHasNothingLeftToFetch` が両方にある | 要らない | 3.3 の表 |
| 窓で決定性が要る道（台本・`bin/determinism.sh`・`FLIX_GE_FRAME_SHOT`・`FLIX_GE_SPLASH_SHOT`・`gl-capture-check`）に、届く時刻の揺れが入る | **型では縛れない**（どれも同じ `LwjglLoad` を通る）。既定を「入れない」にし、入れる判断を入口の 1 か所に置く（3.3） | **`make determinism`**（記録と画面なしの再生が同じ World か）と `make gl-capture-check`（2 回撮ってバイトで比べる）。8 の段の緑の測りに必ず入れる | 3.3 の表 |
| テストの偽物が op の追加で全部止まる | 段 1 で寄せる（op が増えたら直すのは `FakeRendering`・`FakeLoad` の 1 か所ずつ。`ViewCtx` の欄は `App.viewCtxOfFonts` と `baseCtx`） | 要らない | — |
| 使い手の無い「描かない・読まない」handler を、ゲームが案内どおりに選ぶ | 段 2 で外す（道は `HeadlessLoad.handle` 1 本） | forbid.json に 1 行（代わりを言う） | startup.md・AGENTS.core.md |
| `ImageDecoder` を欄を全部書いて組み、欄の追加で止まる | `decoderOf` で既定を埋める（今のまま。engine の外で全部の欄を書く所は 0） | 今は要らない。外に現れたら forbid.json に `platformImageOfBytes\s*=`（engine の外だけ）を 1 行 | api-digest の doc |
| `LwjglLoad` と `HeadlessLoad` の写しがずれる | 置き場が無く 2 つのまま（2.2 の I） | `make lint ONLY=load-copy`（既定の lint）。native (a) で分かれる時に比べる範囲を pool だけへ縮める | — |

## 5. やらない事

- effect を新しく分ける・作る（2.1 の A〜E）。違う所は機種ごとに一緒に動き、分けて差し替える理由が今無い。
- `LoadProgress` の handler を部品から組む関数（2.2 の F・`handleFrom`）。次に LoadProgress に op を足す版で一緒に入れる。
- `ImageDecoder`・`AssetDownloads` を外から作れない型にする（2.2 の G）。欄を読むゲームの行が替わり、得は今 0。
- `LwjglLoad` と `HeadlessLoad` の本体を 1 つにする（2.2 の I）。置き場が無く、今後わざと違う物になる。写しは load-copy の lint が守る。
- runNoop を残してデコーダーだけ「解く時に止める」へ替える（2.2 の C(ii)）。引っかかる呼び手が無い。
- テスト用に `FakeRendering.viewCtx()` を作る。既定値から組む `App.viewCtxOf` がもう pub にある（3.1）。
- デスクトップのストリーミングで「裏のスレッドで解く」所。`AssetDownloads` が持つのは「届いたか」までで、解くのは `BackgroundLoad.Group#decode`（App のループが予算の内で本体のスレッドで回す）。
  解く所を裏へ移すのは handler の外（engine の `BackgroundLoad` と `App.withBackgroundLoad`・`Platform.Tasks` を使うか）なので、8 の計画で決める。
- Fs の handler の手当て。Flix の標準の eff で、engine の版では op が変わらない（ゲームの 7 か所の偽物は直す理由が来ない）。
- Studio の側の手当て（凍結中）。

## 6. 人に決めてほしい事

1. **effect は分けない（0 の結論）でよいか** — 推す答え: よい。0.85.0 以降、engine の eff の op の追加でゲームが直した所は 0 で、直しは engine のテストの偽物に集まっていた。段 1〜3 は合わせて 2 時間前後・新しい pub 0。
2. **使い手がテストだけの 3 つの pub（`LoadProgress.runNoop`・`Platform.runNoopDraw3d`・`RenderTarget.runNoop`）を外してよいか** — 推す答え: よい。数えた範囲のゲームで使い手 0・docs の道が `HeadlessLoad.handle` 1 本になる。外すのは互換を壊す変更なので、版の区切り（移行メモに 1 行・forbid.json で代わりを言う）に乗せる。
3. **LoadProgress を部品から組む関数（2.2 の F・`handleFrom`）を、次に op を足す時の約束にしてよいか** — 推す答え: よい。今入れると pub が 2〜3 増えて、使う所が engine の 4 つだけ。
4. **音を鳴らさない handler（2.2 の H）を足すか** — 推す答え: 今は足さない。次に `GameEngine.Audio` に op を足す版で `GameEngine.runSilentAudio(secondsOf, f)` を一緒に入れる（engine の拡張なので、その時に相談）。
   その版の移行メモで「`GameEngine.Audio` の handler を自前で書いているテスト（sound-novel-starter から作ったゲームの TestAudio の 9 op）が止まる・`runSilentAudio` へ替える」と言う約束を添える。
5. **8 でストリーミングを入れるか決める所を、ゲームの Main の入口（または engine_full に mod を作る）にしてよいか** — 推す答え: よい。既定は入れない。どの形（環境変数・project.json・別の入口）にするかは 8 の計画で比べる。

## 7. スパイク

- 枝 `worktree-agent-a32ee4d6944ddb0cf`・コミット `0f52ea6ce`「スパイク: engine_world のテストの描かない handler の組を FakeRendering.runNoop 1 つにまとめる」。main にマージしない。
- 中身: `engine_world/test/FakeRendering.flix`（34 行・`runNoop` と `atlas`）を足し、TestLetterboxView・TestPassPlan・TestPreload3d・TestStaticLayers の 6 組の handler を置き換えた（7 行足して 79 行減。`atlas()` の 3 つの写しも消えた）。TestPassPlan・TestPreload3d が使っていた `RenderTarget.runNoop` も FakeRendering の中の Target の handler へ移り、枝の上では使い手が 0 になった（段 2 で外せる事の確かめ）。
- 分かった事:
  - 見たい op を持つ eff だけを内側に重ねる形で、どのテストも書けた（TestLetterboxView は Target と Draw2d を内側に・TestPreload3d は Draw3d と Draw2d を内側に）。
  - Flix の handler は eff の op を全部書く必要があるので、重ねられるのは **eff の単位まで**。op の単位で差し替えたい所（LoadProgress の downloads だけ・Audio の audioSeconds だけ）は、関数の引数か部品の record（2.2 の F・H）で受けるしかない。eff を分ける案 A の得は本来ここにあるが、その差し替えをしているのは engine のテストだけ（1.2）。
  - `make test-engine_world` は 1815 緑・失敗 0（5.3 秒）。コミットの前の検査（check-docs-sync・lint load-copy）も通った。
