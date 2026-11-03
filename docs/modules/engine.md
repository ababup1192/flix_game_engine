# エンジンの奥（engine/src: core・render・トップレベル）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> ここに載るのは主に engine_world の各モジュールが内部で使う下請けの型・関数で、ゲームから直に触ることは少ない。
> 詳しい説明は `engine/src/<パス>.flix` 冒頭の doc コメント。

## 描画の 2 つの経路（Drawable と PlacedItem）

このエンジンには描画物を組み立てる経路が歴史的に 2 つある。

- **PlacedItem 経路**（`engine_world` の `Render.Item` + `App.withView`）。**新しく作るゲームは
  必ずこちら**を使う。位置つきの絵を値として返すだけの宣言的な組み方で、CameraRig・
  DualGrid・Fx など engine_world の道具はすべてこの経路の上に乗る。
- **Drawable 経路**（`engine/src/render/drawable/Camera.flix` と `Projection.flix`、および
  `view = None` で `GameEngine.Drawable` を自分で組むゲーム）。**一部のゲームだけが
  使う古い経路**で、新規のゲームでは使わない。Sprite / Rect / Polygon / Arc / Text /
  TileLayer / Tileset / Transform / Visual といった `render/` 配下の描画物の型も、
  もともとはこの経路のノード型（Godot のノードに近い作り）で、PlacedItem 経路は
  これらを直接は使わず `core/DrawCmd` を土台に `Render.Item` を組む。
  例外は **Text** だけで、PlacedItem 経路の文字描画も内部で `Text.toDrawables` に
  委譲する共有の下請けになっている。

**BootFontData.flix は生成物**（`make boot-font` で生成し直す）。手で編集しない。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| ゲームとエンジンの境界の共有型・効果（描画・入力・音・時間）を知りたい | GameEngine |
| ゲームパッドのボタンがどのキーになるか（Start = Menu・Select = Backspace）・つないだパッドの機種（Steam か） | GamepadMap（table / kindOf。ゲームは Frame#padKind を読む。[gamepad.md](../gamepad.md)） |
| プロセスの環境変数を読む・終了コードで終える（入口の頭の 1 か所。奥へは引数で渡す） | ProcessEnv（snapshot・exitWith。常駐の入口は App.Headless.envOf(req)） |
| 効果音・BGM の再生／停止・音量・高さ（pitch）の低レベル効果口を知りたい（`GameEngine.Audio`） | GameEngine（Audio 効果）/ AudioStreamPlayer（呼び口。鳴り続ける音は engine_world の App.withSustained。詳しくは [audio.md](../audio.md)） |
| WAV ファイルの中身（形式・波形データの位置・ループ点）を読み解きたい | AudioUtil（ループ点は loopPointsOf。smpl チャンク） |
| engine の fpkg 読み込みを consumer 側で trigger したい | EngineSentinel |
| project.json を読み込んでエンジン設定と scene 一覧を得たい | ProjectLoader |
| 起動の読み込みの進み具合を起動画面へ知らせる・読み込み中もウィンドウを応答させる（区切りごと・並列で読む） | LoadProgress（report / mapWithProgress / parMapWithProgress。描き出し・テストは runNoop。[startup.md](../startup.md)） |
| ファイルから作る重い値を、読んだファイルの中身が同じ間だけ取っておく（窓なしのゲームの初めの World・kit） | ContentCache（loadOrBuild。更新時刻は見ない） |
| 既定値で続けたことを人へ 1 行知らせたい | Log（文面と出し先の決まりは [error-handling.md](../error-handling.md) の決まり 3） |
| ある処理が N の二乗で割り当てていないかをテストで確かめたい | AllocMeter（絶対バイトは見ず、N を増やしたときの比だけを見る。呼ぶのはテストから） |
| 面をシェーダーで塗る「宣言データ」の型そのものを知りたい | ShaderDoc |
| シェーダー宣言を GLSL のソースへ変換する仕組みを知りたい | ShaderGen |
| シェーダーの式を GPU なしで評価したい（テスト・SoftRaster の描き出し） | ShaderEval |
| shader.json を読み書きしたい | ShaderJson |
| 1 を超える明るさの Pass を 0..1 に収めたい（トーンマップ・露出・白の点）・縁のギザギザをならしたい（FXAA）・明るさ（709）を場で作りたい | PostProcess（tonemapped / tonemappedWith / fxaaSpec / luma709。使い方は [shader-doc.md](../shader-doc.md) の「後処理」） |
| 面の中でテクスチャ（Pass）のテクセルの数を読む・1 テクセルずつずらす | ShaderDoc.Field.TexSize（`Div(Const(1), TexSize)` がずらす量） |
| 入力・ウィンドウ・時計・描く・GPU の資源の effect を知りたい（テストの偽物を役割ごとに張る） | Platform（`Platform.Input`・`Window`・`FrameClock`・`Draw2d`・`Draw3d`・`GpuResources`・`Diagnostics`・`Annotation`、束は `Platform.Services`） |
| シェーダー面を描く・GPU のプログラムを作る effect を知りたい | Platform.Draw2d.drawSurface・Platform.GpuResources.buildProgram（型は DrawCmd.SurfaceRenderCmd） |
| 1 コマで作ったシェーダー・足した字・塗りと swap の時間を知りたい（ヒッチの記録の材料） | FrameDiagnostics |
| GPU と CPU の 1 コマの時間・3D の置いた物と draw call の数を画面の隅に出す（2D と 3D で共通） | engine_world の App.withDiagnostics → frame#diagnostics → FrameDiagnostics.summaryLines（gpuNs・gpuPasses・scene3dCounts） |
| 位置ベクトルの足し引き・長さ・回転を計算したい | Vec2 |
| (x, y) から Vec2 を 1 行で作りたい（リスト内の型注釈を消す） | Vec2.v2 |
| マス目やピクセルなど整数の (x, y) を計算したい | Vec2i |
| 矩形の当たり・包含・膨張を計算したい | Rect2 |
| HUD やデバッグ表示の z-index の範囲（どの範囲が何用か）を知りたい | ZBand（範囲の地図は docs/z-bands.md） |
| 色（sRGB-linear）を作る・GL の uniform に渡したい | Color（core 側の基礎型。ゲーム側の色操作は engine_world の Color を参照） |
| 時間の長さ（継続・経過・残り）を型で扱いたい | Duration |
| 1 フレームぶんの描画命令の共通の型を知りたい | DrawCmd |
| GPU が割り当てるリソース（VAO・テクスチャ id）を型で包みたい | GpuHandle |
| フォントアトラスのメタデータの型を知りたい | FontAtlas |
| フォントに書き込む常用漢字・UI 記号の一覧が欲しい | JoyoKanji |
| 親の枠の中で子をどこに置くか名前で選びたい（中央・右下など） | Anchor |
| 文字列の改行・折り返し・中央寄せの座標計算をしたい（下請け） | TextLayout（ゲームの文章を幅で折るのは engine_world の RichText.wrapLinesBy） |
| 凹みのある多角形を三角形に分割したい | Triangulate |
| GL の uniform に渡す前の数値変換・丸めをしたい | RenderUtil |
| 0〜1 に収める・小数部だけ残す（core 側の基礎計算） | Num |
| 3D の位置・向きのベクトルを計算したい（左手系・X 東・Y 上・Z 北） | Vec3 |
| 3D の 4×4 行列（移動・回転・拡大・視点・透視）を組みたい | Mat4 |
| 3D の物の置き場所（位置・回転・拡大）を 1 つの値で持ちたい | Transform3d |
| 3D の回転を四元数で持つ・2 つの向きの間をなめらかにつなぐ | Quat |
| 3D の形（頂点・法線・色・三角形）を作る・箱や板を組む・uv を付ける（withUvs・withBoxUvs） | Mesh3d |
| 3D の材質に貼る絵を場面に持たせる（PNG / JPEG を読む・中身のハッシュの名前） | Texture3d（Scene3d.texturedMaterial と組む） |
| 絵の縮小の段（mip）を作る・3D の絵を読む段を選ぶ（GPU と CPU で同じ式） | Mip（build / lodOf） |
| 3D の視点（位置・向き・画角）を持ちたい | Camera3d |
| 3D のカメラに写る範囲（視錐台）で光や物を間引く・数える | Frustum（Camera3d.frustum で作る。置いた物とビルボードは描き手が Scene3d.isOutsideFrustum で間引く・docs/scene3d.md の「描く量」） |
| 3D の部屋や物を 1 つの描き物（Render.Item.Scene3d）にまとめる・灯り・霧・影 | Scene3d（shadowMatrix の約束は Scene3d.flix の doc・3D の口の案内は docs/scene3d.md） |
| 懐中電灯のような縁のぼけたスポットライトを置く（内側の角） | Scene3d.spotLight(p, t, fov) に innerFovY = Some(..)（直し方は Scene3d.spotConeOf・docs/scene3d.md） |
| 3D の点光源が 8 本を超える（遠い灯りまで全部置きたい） | Scene3d の pointLights に全部入れる（描き手が Scene3d.pickLights で目に近い 8 本を選ぶ。ゲームで選び直さない） |
| 3D の光・かすみ・空の式を読む・直す（GL と CPU の描き手が同じ木から出す） | LightModel3d（式の木と lightingModel・fogModel・skyModel。コード生成は LightModel3d.Codegen。直したら make gen-light3d で engine_tools の SoftRaster3dLight を作り直す。ゲームは使わない） |
| 3D の形に骨を入れる（関節の並び・頂点ごとの重み） | Skin3d |
| 骨の動き（キーフレームの並び）を持つ・ある時刻の姿勢を取り出す | AnimationClip3d |
| 骨ごとの姿勢を混ぜる・Scene3d へ渡す | Pose3d（Scene3d.withPose） |
| Blender などで書き出した .glb を読む（形・骨・動き） | Gltf（load / fromGlb。X を反転して左手系へ） |
| .glb の絵と材質（baseColorTexture・normalTexture・emissive）も読んで primitive ごとに置く | Gltf.loadTextured（Model3d の parts と textures・材質の情報は part#gltfMaterial・止めるなら Scene3d.withoutEmission） |
| Blender で名前を付けたノード（扉・当たり判定の箱・印の点）を .glb から名前で引く | Model3d.findNode / nodesWithPrefix / nodesByName（node#world・node#localBounds・docs/scene3d.md） |
| 3D の当たり判定の形（向きのある箱・球・縦のカプセル）を作る・glb のノードから箱を作る・回す扉の箱 | CollisionShape3d（boxOfNode / boxesOfNodes・transformBox・debugMesh。2D は CollisionShape2D） |
| 動かない 3D の箱をたくさん持ち、足元の近くの箱だけを引く | CollisionWorld3d（build / boxesNear。歩くのは engine_world の CharacterBody3d） |
| 一人称で見ている物を調べる（クロスヘアの先の物の名前・壁で遮る）・画面の点から 3D のレイを伸ばす | Ray3d.pickNearest（Camera3d.forwardRay / screenPointToRay・的は Ray3d.boxTargetsOf・docs/scene3d.md の「見ている物を調べる」） |
| Blender でベイクした光（lightmap と 2 本目の uv）を 3D の部屋に貼る | Scene3d.withLightmap（Gltf の TEXCOORD_1 → Mesh3d.uvs2・docs/lightmap.md） |
| 3D の絵が場面の絵の上限（256 MB・64 枚）を超える・大きすぎる絵を縮める | Gltf.loadTexturedWith・Texture3d.limitSize・project.json の scene3dTextureBudgetMB / scene3dTextureBudgetCount（docs/lightmap.md の「場面の絵の予算」） |
| 8bit の絵の値の意味（sRGB の曲線か線形か）と変換の式 | Texture3d.ColorSpace・srgbToLinear・linearToSrgb |
| 起動画面（ロゴ+ゲージ）を組み立てたい | Splash |
| 起動画面の組み込みフォント・ロゴを使いたい | BootFont（素データは BootFontData。生成物なので手で触らない） |
| 円弧・リングを描きたい（Drawable 経路） | Arc |
| 単色の多角形を塗りたい（Drawable 経路） | Polygon |
| 単色矩形・枠線・角丸を描きたい（Drawable 経路） | Rect |
| スプライト 1 枚を表示したい（Drawable 経路） | Sprite |
| 名前つきのコマ送り素材集を持ちたい（Drawable 経路） | SpriteFrames |
| 文字を 1 文字ずつグリフに分けて描きたい（両経路が使う共有の下請け） | Text |
| タイルの格子を 1 層まとめて描きたい（Drawable 経路） | TileLayer |
| タイルセット画像からマスを切り出す設定を持ちたい（Drawable 経路） | Tileset |
| 位置・回転・スケール・せん断をまとめて持ちたい（Drawable 経路の値部品） | Transform |
| 色変調・可視性・重なり順をまとめて持ちたい（Drawable 経路の値部品） | Visual |
| 当たり判定の幾何形状（矩形・円・カプセル・坂）を計算したい | CollisionShape2D |
| 今フレーム押されているキー・マウスボタンの集合を取りたい | InputEvent |
| HUD を本体より確実に手前に出す | ゲームからは App.withHudView（中は ZStack の木）。CanvasLayer は ui.json の層の内側の仕組み |
| 放射グラデの組み込みテクスチャ（`__radial_light` / `__radial_dark`）の画素・名前・寸法を知りたい | RadialBuiltin（ゲーム側の入口は engine_world の `Render.lightAt` / `Render.darkAt`） |
| Drawable 経路のカメラ・投影を知りたい（`view = None` のゲーム以外では使わない） | Camera / Projection |
| Pass のターゲットを画面（窓・書き出し）の画素で描きたい（3D・後処理を design より細かく） | RenderTarget.windowDescriptor（Descriptor の basis = Window。寸法は RenderTarget.texelSizeOf） |
| 画面でなくレンダーターゲットに描いてテクスチャとして読み返したい（`eff Target`） | RenderTarget（GL 実装は render_gl の Target.flix / RenderTargetGl。ゲーム側の入口は engine_world の `Render.Pass` + `App.withPasses`、[逆引き](../module-index.md)を参照） |
| いま bind 中のフレームバッファ（FBO でも既定でも）を画像 / PNG に吸い出したい | GlReadback（render_gl の GlReadback.flix。`readBoundImage`（RGBA・左上原点）/ `readBoundImageRgb`（RGB に落とす皮）/ `readBoundPng`。splashShot・注釈スクショ・GL 突き合わせ（bench/gl_parity）が共有する読み出しの核） |

## 土台

- **GameEngine** — ゲームとエンジンの境界に置く共有の型（描画データ・キー・色など）と、副作用の入口（描画・入力・音・時間の取得）をまとめて定義する。各ゲームはここの型とエフェクトだけを見れば、内部実装を知らずに描画や入力を組める。
- **GamepadMap** — ゲームパッド（Xbox 配置）のボタンとキーの対応表（1 ボタン = 1 キー）と、GUID と名前からパッドの機種（一般・Steam・不明）を決める純関数。GLFW を読むのは render_gl の LwjglLayer。
- **EngineSentinel** — engine fpkg のロードを consumer 側で trigger するためのモジュール。
- **EngineSentinel.Marker** — EngineSentinel が使う印だけの小さな型。

## シェーダー

- **ShaderDoc** — 面（矩形）を GPU シェーダーで塗るための「宣言データ」。生の GLSL を書かず、少数の部品（値の場・色・出力）を組み合わせて水面のような連続した見た目を作る。部品の型（Spec）と、木の汎用走査 `ShaderDoc.foldField`・Tex が読むテクスチャ名の正典順列挙 `ShaderDoc.texNames`（GLSL の uniform 番号 = sampler unit 番号 = 描画依頼の texNames の並びの正）を持つ。全面でない面から pass を等倍・鏡像で読む Shift の dy 場は、ゲーム側の入口 engine_world の `Render.passStripDy` で組める。
- **ShaderGen** — Spec を GLSL の fragment シェーダー文字列へ変換する codegen。各部品が自分の GLSL 片（式）を返し、compile が 1 枚の main() に繋ぐ。出力は決定論なのでスナップショットで釘打ちできる。
- **ShaderEval** — Spec 木を CPU（Float64）で評価する純関数。GL の描画経路ではないが、SoftRaster（描き出し・動画・スナップショット）はシェーダー面の画素をこれで塗り、テストは式の構造が GLSL 側と揃っているかをこれで確かめる。tex 場つきの評価は `ShaderEval.evalPixelTex` / `ShaderEval.evalAlphaTex`。何万画素も評価する画素ループは `ShaderEval.compile` で面ごとに 1 回だけ組み直し、画素ごとに `ShaderEval.evalCompiled` を呼ぶ（色と α を 1 回の shared 先行評価で返す。SoftRaster はこれを全コアで並べて評価し、`FGE_SOFT_SERIAL=1` で 1 本に戻せる）。
- **ShaderJson** — シェーダー面の宣言（ShaderDoc.Spec）を JSON と相互変換する codec。engine を触らず `*.shader.json` の保存だけで調整できる（App.watchFile によるホットリロードの受け皿）。
- **PostProcess** — 画面の仕上げの面を ShaderDoc の Spec で組む部品（Unity URP / Unreal の Post Process と同じ並び）。`PostProcess.tonemapped` / `tonemappedWith`（AcesFitted・Reinhard。既定は `defaultExposure()` = 0.4 stop・`defaultWhitePoint()` = 4.0）・`PostProcess.fxaaSpec`（FXAA 3.11 の PC の簡単な版）・`PostProcess.luma709`。今の場と bindings だけで組むので GPU と CPU が同じ木を評価する。
- **FrameDiagnostics** — 1 コマぶんの描く側の診断（作ったシェーダーと理由・GPU にあるシェーダーの数・足した字・塗りと swap の時間・GPU の時間と描き先ごとの時間・3D の数）。2D と 3D で共通。`Platform.Diagnostics.consumeDiagnostics` が返し、App が 1 コマに 1 回引き取ってヒッチの記録とゲーム（`App.withDiagnostics` → `frame#diagnostics`）へ配る。`setDiagnosticsEnabled(true)` の間だけ数える。画面に出す字は `summaryLines`。
- **Platform** — 機種（ウィンドウ・入力・GPU・時計）に触る effect を役割ごとに分けた所。関数の型に触る effect だけが出て、op を足しても止まるのはその役割の handler だけ。`Draw2d.drawSurface` と `Draw3d.drawScene3d` は積むだけで `Draw2d.renderCommands` が出すので、`Draw2d`・`Draw3d`・`GpuResources` は同じ handler の組から張る。
- **ShaderEffect** — 描き手の handler がまだ受けている面と 3D の場面の op（`eff Shader`）。呼ぶ側は `Platform` の effect を使う（render_gl の `RenderLegacyBridge` がここへ回す）。

## レンダーターゲット（RenderTarget）

- **RenderTarget** — レンダーターゲット（描いた結果を読み返せる描き込み先）に描いてテクスチャとして読み返すための効果口（`eff Target`）。描き込み先の切り替えは描く op の外側の関心なので `Platform.Draw2d` に入れず、ターゲットを持たない描き出し・テストの偽物はこれを張らずに描ける。GL 側の実体は `render_gl` の **Target.flix**（`mod RenderTargetGl`。FBO 1 枚 + カラーテクスチャ 1 枚を作り・切り替え・破棄する）と `LwjglLayer` のハンドラが持つ。ゲーム側は engine 内部の `eff Target` を直接触らず、engine_world の `Render.Pass` + `App.withPasses` を使う（[逆引き](../module-index.md)を参照）。

## core（基礎の値と計算）

- **Anchor** — 親の枠の中で子をどこに置くか（左上・中央・全面など）を、決まった型で選ぶ。
- **AudioUtil** — 音声ファイル（WAV）の中身を読み解くための小さな計算。形式（モノラル/ステレオ・ビット数）の判別や波形データの在り処探し・ループ点（smpl チャンク）の読み出しを一箇所にまとめる。実際のファイル読み込みや再生はしない。
- **Color** — 3 チャンネル sRGB-linear カラー（Float64・0.0〜1.0）。`{ r = 1.0, g = 0.0, b = 1.0 }` と書ける。
- **DrawCmd** — 1 フレームぶんの描画命令の型。フロント（engine のシーングラフ）が組み立て、バックエンド（GL 描画・SoftRaster）が消費する共有の型。
- **Duration** — 時間の長さ（継続時間・経過時間・残り時間）を表す型。
- **FontAtlas** — フォントアトラス型定義。STBTruetype で書き込んだフォントビットマップのメタデータを保持する。
- **GpuHandle** — バックエンドが割り当てる描画リソースのハンドル（タイル VBO やテクスチャの実体を 1 枚の型で包む）。
- **JoyoKanji** — フォントアトラスに書き込む常用漢字 + UI 記号のコードポイント列。
- **Num** — 数の小さな道具（0〜1 に収める・小数部だけ残す・周期で折り返す）。書き方の揺れをなくすため 1 箇所にまとめる。
- **ProjectLoader** — project.json を読み込んで engine 起動用の設定 + scene ファイル列挙を提供する。engine とゲームが共通で読む唯一の真実。
- **Rect2** — 2D の矩形を「左上の座標」と「幅・高さ」で表し、当たり・包含・膨張などを計算する。
- **RenderUtil** — 描画に使う数値変換ヘルパー。GL の uniform やシェーダに渡す前の Float32 変換・丸め・三角関数をまとめる。
- **TextLayout** — 文字列の一文字ずつを、どこに置くか（改行・折り返し・中央寄せ）を計算する。
- **Triangulate** — 単純多角形（自己交差しない・凹あり可）を三角形の列に分割する耳切り法。GL の塗り（GL_TRIANGLES）と SoftRaster（スキャンライン）の絵を一致させるための芯。
- **Vec2** — 2D の位置や向きを表す (x, y) の組と、その足し引き・長さ・回転などの計算。
- **Vec2i** — 整数の (x, y) の組に対する足し引きなどの計算。マス目やピクセルの位置を丸め誤差なく扱える。
- **ZBand** — 重なり順（zIndex）を用途ごとの範囲に区切る取り決めの source of truth（HUD の範囲・デバッグの範囲・範囲の幅と clamp）。範囲の地図は docs/z-bands.md。

## render（描画物・Drawable 経路の部品）

- **Arc** — 円弧・リングを描く描画物。中心から半径・太さのリングを、開始角から終了角まで単色で塗る。
- **BootFont** — 起動画面が使う組み込みフォントとロゴを、埋め込みデータ（BootFontData）から組み立てる。ゲームのフォントは起動時にまだ生成できていないため、起動画面専用に持つ。
- **BootFontData** — 生成物。手で編集しない（`make boot-font` で生成し直す）。Splash が使う組み込みフォントとロゴの素データ。
- **Camera** — Drawable 経路（`view = None` で renderCommands を自前で組むゲーム）専用のカメラ部品。PlacedItem 経路は `App.withCamera` / `App.withZoom` + `CameraRig` を使うので、そちらでは使わない。
- **CanvasLayer** — HUD やオーバーレイを本体より手前に重ねるための描画レイヤー番号の基準。レイヤー番号 × layerStride を zIndex に加算する（UiRender が使う内側の仕組み。ゲームが重なりを決めるのは ZStack / SortingLayer / App.withHudView で、ここに数を足さない）。
- **CollisionShape2D** — 当たり判定に使う 2D の幾何形状（矩形・円・カプセル・坂）。形状同士の重なり・点の内外・押し出しベクトルの計算をまとめて持つ。
- **InputEvent** — 現在フレームで押されているキー・マウスボタンをまとめて取得する。押下エッジは呼び側が前フレームと差分して取る。
- **Polygon** — 局所座標の単純多角形を単色（color + alpha）で塗り潰す描画物。
- **Projection** — Drawable 経路専用の投影部品（ワールド座標→画面座標）。PlacedItem 経路は CameraRig が同じ役割を担う。
- **RadialBuiltin** — 放射グラデ（中心から縁へ滑らかに変わる円）の組み込みテクスチャ。画素を純関数で決め、GL（起動時に GPU へ上げる）と SoftRaster（生成）が同じ列から絵を作るので、実機と生成した絵がずれない。ゲーム側は engine_world の `Render.lightAt` / `Render.darkAt` から使う。
- **Rect** — テクスチャなしで単色の矩形を描く描画物。枠線・角丸・45° の斜線ハッチも指定でき、枠付きパネルもこれ 1 つで描ける。
- **Splash** — 起動画面 1 枚ぶんの絵を組み立てる。読み込みの間、何も描かれない時間が「固まった」ように見えるのを防ぐ。
- **Sprite** — テクスチャを 1 枚表示するだけの軽い描画物で、見た目（visual）と座標変換（transform）を持つ。
- **SpriteFrames** — 名前つきのパラパラ漫画（アニメーション素材）をまとめて持つリソース。AnimatedSprite2D が参照する素材置き場。
- **Text** — テキストを 1 文字ずつグリフに分けて描画する描画物。Drawable 経路・PlacedItem 経路の両方が使う共有の下請け（PlacedItem 側は engine_world の Render が内部で `Text.toDrawables` を呼ぶ）。
- **TileLayer** — 格子状に並べたタイルの層を 1 枚まとめて描く。大量のタイルを 1 回の描画でまとめて出せる。
- **Tileset** — タイルセットのアトラス元。1 枚のタイル画像と、そこからマスを切り出す設定（texWidth / texHeight / tileSize）を持つ。
- **Transform** — 2D の位置・回転・スケール・せん断をまとめた値部品。描画型はこれを埋め込んで座標変換を共有する。
- **Visual** — 描画の見た目（色変調・可視性・重なり順）をまとめた値部品。
