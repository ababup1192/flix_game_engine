// Render3dWgsl — 3D の描き手の WebGPU のシェーダーの字の入口と、group 0〜2 の binding の宣言・buffer の大きさ。
// frag・ビルボード・空と、光・かすみ・影・色の空間の関数は Render3dGlsl と同じ Render3dShaders の木から ShaderAst.Wgsl で出す。
// 入口が辿る定義と varying の struct は ShaderAst が木から集める。置いた物の頂点シェーダーだけは Render3dWgsl.MeshVertex の手書きの字。
//
// bind group: 0 = 場面（`var<uniform> r3d: R3dScene`・影の地図・太陽の影の地図・環境マップ・目と射影の行列とカメラの向き）・1 = 材質（ShaderGen.Wgsl.compile3d の `sg` と絵・
// `var<uniform> r3dDraw: R3dDraw`・法線マップ・lightmap。ビルボードは 2D の描き手の絵と sampler）・2 = storage（姿勢）。varying の location は Render3dShaders の varying の表。
// 射影の行列は GL の物のまま使い、頂点シェーダーが ShaderGen.Wgsl.clipFromGlSource の sg_clipFromGl で clip の z を 0..w へ移す前提
// （奥行きの値が GL のウィンドウの奥行きと同じになり、影の比べ ndc.z × 0.5 + 0.5 をそのまま使える）。
pub mod Render3dWgsl {
    /// 場面の値の struct と、場面の絵の宣言（group 0）。struct の欄と並びは Render3d.UniformLayout.sceneFields（詰める側も同じ表から位置を引く）。
    /// f32 と vec2 の光の配列は、uniform の配列の 16 バイト刻みに合わせて vec4 の配列にした（x・y を読む。LightModel3d.Codegen の WGSL の欄と同じ）。
    pub def sceneDeclarations(): String =
        Render3d.UniformLayout.structSource("R3dScene", Render3d.UniformLayout.sceneFields()) +
        "@group(0) @binding(0) var<uniform> r3d: R3dScene;\n" +
        "@group(0) @binding(1) var uShadowMap: texture_depth_2d;\n" +
        "@group(0) @binding(2) var uSunMap: texture_depth_2d;\n" +
        "@group(0) @binding(3) var uEnvMap: texture_2d<f32>;\n" +
        "@group(0) @binding(4) var uEnvSampler: sampler;\n"

    /// 変種 v の pipeline だけが group 0 に足す binding の宣言（Render3d.ProgramKey.group0Of の順。どれも無ければ空の字）。
    /// R3dLight の欄の名前は Render3dGlsl の uniform と同じで、並びは Render3d.UniformLayout.lightFields。
    // WhyNot: 既定の R3dScene の struct に欄を足さない — 既定の pipeline の WGSL の字と group 0 の layout が変わり、変種を使わない場面まで値の並びが動く。
    pub def variantDeclarations(v: Render3d.ProgramKey.ShaderVariant): String =
        Render3d.ProgramKey.group0Of(v) |> Set.toList |> List.map(group0Declaration) |> String.flatten

    def group0Declaration(b: Render3d.ProgramKey.Group0Binding): String = match b {
        case Render3d.ProgramKey.Group0Binding.LightBuffer      =>
            Render3d.UniformLayout.structSource("R3dLight", Render3d.UniformLayout.lightFields()) +
            "@group(0) @binding(${lightBinding()}) var<uniform> r3dLight: R3dLight;\n"
        case Render3d.ProgramKey.Group0Binding.PointShadowAtlas =>
            "@group(0) @binding(${pointShadowMapBinding()}) var uPointShadowMap: texture_depth_2d;\n"
        case Render3d.ProgramKey.Group0Binding.AoMask =>
            "@group(0) @binding(${aoMaskBinding()}) var uAoMask: texture_2d<f32>;\n" +
            "struct R3dAo { uValues: vec4f };\n@group(0) @binding(${aoMaskBinding() + 1}) var<uniform> r3dAo: R3dAo;\n"
    }

    /// 変種 +ao の group 0 の SSAO の mask の binding（R3dAo の buffer はその次）。
    pub def aoMaskBinding(): Int32 = 8

    /// R3dAo のバイト数（uValues = (場面の描き先の幅, 高さ, lightAffect, 0)）。
    pub def aoValueBytes(): Int32 = 16

    /// 変種の group 0 の R3dLight の binding。
    pub def lightBinding(): Int32 = 6

    /// 変種 +ps の group 0 の点光源の影の atlas の binding。
    pub def pointShadowMapBinding(): Int32 = 7

    /// R3dLight のバイト数（並びは Render3d.UniformLayout.lightFields）。
    pub def lightValueBytes(): Int32 = Render3d.UniformLayout.bytesOf(Render3d.UniformLayout.lightFields())

    /// 物ごとの値（group 1 の drawBinding() から）。uCutout = cutout の材質か（1.0）・法線マップの強さと mip のレベルの数・lightmap の mip のレベルの数と
    /// 色空間（sRGB なら 1.0）と強さ（LightModel3d.Codegen の WGSL が r3dDraw.uLightmapSrgb・uLightmapIntensity で読む）と atlas の矩形（uLightmapUvRect）。
    /// 法線マップは drawBinding() + 1・+ 2、lightmap は + 3・+ 4（使う版だけ宣言する）。並びは Render3d.MaterialValues の物ごとの値の区画と同じ。
    // WhyNot: 法線マップの読みの v を上下に返す値（GLSL の uNormalFlip）を持たない — WebGPU の描き先の texture は上の行が先で、ほかの絵と同じ向き。
    // WhyNot: uCutout を i32 にしない — 値は計画の Float32 の values から読み、整数の bit で書く道を持たない。
    def drawDeclarations(normalMapped: Bool, lightmap: Bool): String =
        let b = drawBinding();
        "struct R3dDraw { uCutout: f32, uNormalStrength: f32, uNormalLevels: f32, uLightmapLevels: f32, uLightmapSrgb: f32, uLightmapIntensity: f32, uLightmapUvRect: vec4f };\n" +
        "@group(1) @binding(${b}) var<uniform> r3dDraw: R3dDraw;\n" +
        (if (normalMapped) "@group(1) @binding(${b + 1}) var uNormalMap: texture_2d<f32>;\n@group(1) @binding(${b + 2}) var uNormalMapSampler: sampler;\n" else "") +
        (if (lightmap) "@group(1) @binding(${b + 3}) var uLightmap: texture_2d<f32>;\n@group(1) @binding(${b + 4}) var uLightmapSampler: sampler;\n" else "")

    /// group 1 の物ごとの値の binding（材質の絵は ShaderGen.Wgsl の 1〜2 × Scene3d.maxMaterialTextures() を使う）。
    pub def drawBinding(): Int32 = 16

    /// 色の空間の変換（Render3dGlsl.colorSpaceSource と同じ）。
    pub def colorSpaceSource(): String = ShaderAst.Wgsl.print(Render3dShaders.colorSpace())

    /// 光の式（lightAt）・かすみ（fogged）・影と、色を作る最後の組み立て（Render3dGlsl.lightSource と同じ）。
    pub def lightSource(): String = lightSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の lightSource（Render3dGlsl.lightSourceFor と同じ定義）。
    pub def lightSourceFor(v: Render3d.ProgramKey.ShaderVariant): String = ShaderAst.Wgsl.print(Render3dShaders.lightDefinitions(v, Render3dShaders.featureOf(v)))

    /// Render3dGlsl.surfaceOutSource と同じ式。
    pub def surfaceOutSource(): String = ShaderAst.Wgsl.print(Render3dShaders.surfaceOut() :: Nil)

    /// 影の地図の PCF（Scene3d.shadowMatrix の doc の約束 1〜5）と、スポットと太陽の影の割合。
    /// 地図の画素の数え方は GL と同じ（行 0 が NDC の y = −1）で、読む時だけ行を上下に返す: WebGPU で描いた地図は行 0 が NDC の y = +1。
    // WhyNot: 周りの画素を返した後の行で端にそろえない — 端にそろえる（clamp）のを GL の行で済ませてから返せば、CPU の描き手と同じ画素の組を読む。
    pub def shadowSource(): String = ShaderAst.Wgsl.print(Render3dShaders.spotShadow() :: Render3dShaders.sunLit() :: Render3dShaders.sunLitAt() :: Nil)

    /// metallic と roughness を持つ材質の色 pbrAt と、環境マップの読み・かすみ → emission の組み立て（Render3dGlsl.metallicRoughnessSource と同じ）。
    pub def metallicRoughnessSource(): String = metallicRoughnessSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の metallicRoughnessSource。
    pub def metallicRoughnessSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        ShaderAst.Wgsl.print(Render3dShaders.metallicRoughnessDefinitions(v, Render3dShaders.featureOf(v)))

    /// Render3dGlsl.applyNormalMapSource と同じ式。
    // WhyNot: 長さ 0 の p の normalize を if で避けない — select は両側を計算するが、NaN の側は捨てられる。
    pub def applyNormalMapSource(): String = ShaderAst.Wgsl.print(Render3dShaders.applyNormalMap() :: Nil)

    /// group 0 の場面と変種 v の binding の宣言（frag の入口の declarations）。
    def sceneBindings(v: Render3d.ProgramKey.ShaderVariant, more: String): List[ShaderAst.Definition] =
        Render3dShaders.wgslDeclarations("r3d_bindings", sceneDeclarations() + variantDeclarations(v) + more) :: Nil

    /// 材質の frag（本文は Render3dShaders.materialFragmentBody）。入口は fs_main・varying の struct は R3dIn。
    /// 材質の部品は group 1 で作った物（ShaderGen.Wgsl.compile3d(…, materialOcclusion, 1)）を渡す。materialEval と cutoutAlpha は vUv・vWorld・vNormal・vColor を名前で読む（本文が局所の値に置く）。
    pub def materialFragmentSource(m: ShaderGen.Wgsl.MaterialWgsl, surface: Render3d.ProgramKey.ProgramKind): String =
        let bindings = sceneBindings(surface#variant, drawDeclarations(Render3dShaders.isNormalMapped(surface), surface#lightmap));
        ShaderAst.Wgsl.fragment(Render3dShaders.materialFragment(surface, Render3dShaders.wgslMaterialPart(m), bindings))

    /// materialFragmentSource の、材質の部品の所が空いた字（Render3d.ShaderLibrary.withMaterialPart で WGSL の材質の部品を入れる）。
    /// readsTextures = 入れる部品が絵を読むか。
    pub def materialFragmentTemplate(surface: Render3d.ProgramKey.ProgramKind, readsTextures: Bool): String =
        let bindings = sceneBindings(surface#variant, drawDeclarations(Render3dShaders.isNormalMapped(surface), surface#lightmap));
        ShaderAst.Wgsl.fragment(Render3dShaders.materialFragment(surface, Render3dShaders.templateMaterialPart(ShaderAst.Lang.Wgsl, surface, readsTextures), bindings))

    /// 奥行きの書き出し（Output.Depth）の形だけの frag（Render3dGlsl.depthFragmentSource と同じ本文）。頂点シェーダーは litVertexSource。入口は fs_main。
    pub def depthFragmentSource(): String =
        ShaderAst.Wgsl.fragment(Render3dShaders.depthFragment(Render3dShaders.wgslDeclarations("r3d_bindings", sceneDeclarations()) :: Nil))

    /// 頂点の色のプログラムの frag（Render3dGlsl.litFragmentSource と同じ本文。vColor は頂点シェーダーが線形へ戻し済み）。入口は fs_main。
    pub def litFragmentSource(): String = litFragmentSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の litFragmentSource。
    pub def litFragmentSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        ShaderAst.Wgsl.fragment(Render3dShaders.litFragment(v, sceneBindings(v, "")))

    /// 1 体ごとの値の 1 体のバイト数（Render3d.InstanceValues の 1 体 = 32 float）。
    pub def instanceBytes(): Int32 = 4 * Render3d.InstanceValues.floatsPerInstance()

    /// 目と射影の行列とカメラの向き（group 0 の binding 5）。詰める側は uView・uProj の順に列優先で 128 バイトの後に、
    /// カメラの right・up・カメラへ向く向き（−forward）を xyz に 16 バイトずつ（ビルボードが四角を立て、法線にする。GLSL の uRight・uUp・uFacing）。
    pub def cameraDeclarations(): String = cameraStructFor(false)

    /// R3dCamera の struct と binding の宣言（psx なら uSnap つき）。
    def cameraStructFor(psx: Bool): String =
        (if (psx) "struct R3dCamera { uView: mat4x4f, uProj: mat4x4f, uRight: vec4f, uUp: vec4f, uFacing: vec4f, uSnap: vec4f };\n"
         else "struct R3dCamera { uView: mat4x4f, uProj: mat4x4f, uRight: vec4f, uUp: vec4f, uFacing: vec4f };\n") +
        "@group(0) @binding(5) var<uniform> r3dCamera: R3dCamera;\n"

    /// ビルボードの vertex の入口の binding の宣言（psx なら uSnap つきのカメラの値）。
    def billboardCameraBindings(psx: Bool): List[ShaderAst.Definition] = Render3dShaders.wgslDeclarations("r3d_camera", cameraStructFor(psx)) :: Nil

    /// 貼る絵の宣言（group 1。2D の描き手の絵の group: binding 0 = 絵・1 = sampler）。
    def imageDeclarations(): String =
        "@group(1) @binding(0) var uImage: texture_2d<f32>;\n" +
        "@group(1) @binding(1) var uImageSampler: sampler;\n"

    /// R3dCamera の buffer のバイト数（PS1 風の変種の uSnap まで。既定の struct は前の 176 バイトだけを読む）。
    pub def cameraBytes(): Int32 = 192

    /// R3dCamera の uSnap のバイトの位置。
    pub def cameraSnapAt(): Int32 = 176

    /// ビルボードの頂点シェーダー（本文は Render3dShaders.billboardVertex）。入口は vs_main。
    /// 四角の角は vertex_index の 6 点（GL の Render3d.buildQuad と同じ並び・y は下向き）。ビルボードの値は buffer 0（instance ごと・stride は値 1 つ）の location 0〜3
    /// （並びは Render3d.SceneList.billboardValueFloats: 点と光の当て方・anchor と size・貼る範囲の uv・tint と影を受ける点を板から離す長さ）。影の地図へ描く時も同じ（group 0 が光の目と板の向き）。
    pub def billboardVertexSource(): String = billboardVertexSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の billboardVertexSource（v#psx なら四角の角を丸める）。
    pub def billboardVertexSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        ShaderAst.Wgsl.vertex(Render3dShaders.billboardVertex(v, Render3dShaders.BillboardRight.Camera, billboardCameraBindings(v#psx)))

    /// 板の横の向きを行の値の tint の rgb から読む billboardVertexSource（点光源の影の面へ描く時。Render3d.SceneList.putBillboardValues）。
    pub def billboardRowRightVertexSource(): String =
        ShaderAst.Wgsl.vertex(Render3dShaders.billboardVertex(Render3d.ProgramKey.defaultShaderVariant(), Render3dShaders.BillboardRight.PerBillboard, billboardCameraBindings(false)))

    /// ビルボードの frag（本文は Render3dShaders.billboardFragment）。貼る絵は group 1。入口は fs_main。
    pub def billboardFragmentSource(): String = billboardFragmentSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の billboardFragmentSource（点光源の影を受けないので billboardVariantOf(v) の字）。
    pub def billboardFragmentSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        ShaderAst.Wgsl.fragment(Render3dShaders.billboardFragment(v, sceneBindings(Render3d.ProgramKey.billboardVariantOf(v), imageDeclarations())))

    /// ビルボードを影の地図へ描く frag（本文は Render3dShaders.billboardShadowFragment。色を出さない）。
    /// 頂点シェーダーは billboardVertexSource（group 0 は影の地図の光の目・R3dCamera の uRight と uUp に板の向き）。貼る絵は group 1。入口は fs_main。
    pub def billboardShadowFragmentSource(): String =
        ShaderAst.Wgsl.fragment(Render3dShaders.billboardShadowFragment(Render3dShaders.wgslDeclarations("r3d_bindings", imageDeclarations()) :: Nil))

    /// 姿勢の group（group 2）の binding 0 の頭のバイト数（R3dPoses の matrices の位置）。
    pub def poseHeaderBytes(): Int32 = 16

    /// 頂点の色のプログラムの頂点シェーダー（Render3dGlsl.litVertexSource と同じ式）。入口は vs_main。
    /// 形の頂点は buffer 0（位置・法線・色の 9 float から）を location 0〜2 で、1 体ごとの値は buffer 1（Render3d.InstanceValues の 1 体の並び・instanceBytes()）を
    /// location 3〜10 で読む。行の頭の物は draw の firstInstance で引く。skinned なら骨つきの版（location 14・15 と group 2 の姿勢）。varying は litFragmentSource の R3dLitIn と同じ並び。
    // WhyNot: 1 体ごとの値を storage buffer から instance_index で引かない — 頂点の属性で読む形と 1 コマの時間の差が揺れの内（plans/engine-webgpu.md の 12.29）で、属性の数は一番多い版（uv つきの骨つきの材質）でも 15 個で上限 16 の内。
    //   storage から引く形は、頂点の段で storage を読めない機種（WebGPU の互換の版）で骨の無い物まで描けなくなる（姿勢の storage は骨つきの物だけが読む）。
    pub def litVertexSource(skinned: Bool): String = litVertexSourceFor(skinned, false)

    /// psx（PS1 風の変種）なら頂点を丸める版の litVertexSource。
    pub def litVertexSourceFor(skinned: Bool, psx: Bool): String = Render3dWgsl.MeshVertex.litSource(skinned, psx)

    /// 材質のプログラムの頂点シェーダー（Render3dGlsl.materialVertexSource と同じ式）。入口は vs_main。
    /// 形の頂点は buffer 0 の location 0〜2（位置・法線・色）と、uv つきの版は 11（uv）・12（タンジェント）、2 本目の uv つきは 13、骨つきの版は 14・15（Render3d.WebGpuRows の並び）。
    /// 1 体ごとの値は litVertexSource と同じ buffer 1 の location 3〜10。varying は materialFragmentSource の R3dIn の並び（frag が読まない物も出す）。
    /// 頂点の色は線形へ戻さない（材質の式が VertexColor を sRGB のまま読む・GLSL と同じ）。骨つきの版は lightmap を読まない（Scene3d.lightmapOf が None）。
    pub def materialVertexSource(uv: Bool, lightmap: Bool, skinned: Bool): String = materialVertexSourceFor(uv, lightmap, skinned, false)

    /// psx（PS1 風の変種）なら頂点を丸め、uv つきの版は画面の上でまっすぐつなぐ uv（location 8 の vUvAffine）も出す版の materialVertexSource。
    pub def materialVertexSourceFor(uv: Bool, lightmap: Bool, skinned: Bool, psx: Bool): String =
        Render3dWgsl.MeshVertex.materialSource(uv, lightmap, skinned, psx)

    /// 空の色の式 skyAt(向き)（Render3dGlsl.skyLightSource と同じ木）。
    pub def skyLightSource(): String = ShaderAst.Wgsl.print(Render3dShaders.skyAt() :: Nil)

    /// R3dScene の uSkyForward のバイトの位置（光の配列の後ろ・uSkyRight と uSkyUp が 16 バイトずつ続く）。
    pub def skyValuesAt(): Int32 = Render3d.UniformLayout.offsetOf(Render3d.UniformLayout.sceneOffsets(), Render3d.UniformLayout.SceneField.SkyForward)

    /// 空の頂点シェーダー（本文は Render3dShaders.skyVertex）: 頂点の buffer を読まず、vertex_index の 3 点で描き先いっぱいを覆う三角形を出す。入口は vs_main。
    pub def skyVertexSource(): String = ShaderAst.Wgsl.vertex(Render3dShaders.skyVertex())

    /// 空の frag（本文は Render3dShaders.skyFragment）。空の 3 色と曲がりは場面の値（group 0 の uZenith・uHorizon・uGround・uCurve。
    /// 空のある場面では LightModel3d.reflectionSkyOf が空の色を線形へ戻した物）、画素の向きの材料と描き先の大きさは同じ R3dScene の末尾の uSky*。
    /// uSkyUp.w が 1（景色を背景に描く場面）なら、空の代わりに環境マップの絵を mip のレベル 0 で読み、uEnvIntensity を掛ける。入口は fs_main。
    pub def skyFragmentSource(): String =
        ShaderAst.Wgsl.fragment(Render3dShaders.skyFragment(Render3dShaders.wgslDeclarations("r3d_bindings", sceneDeclarations()) :: Nil))
}
