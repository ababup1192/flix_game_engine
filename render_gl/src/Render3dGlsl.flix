// Render3dGlsl — 3D の描き手（Render3d）の GL のシェーダーの字の入口。座標と式の約束は Render3d.flix の頭。
//
// frag・ビルボード・空・blit と、光・かすみ・影・色の空間の関数は Render3dShaders の木から ShaderAst.Glsl で出す（WGSL は同じ木から Render3dWgsl）。
// 入口が辿る定義と uniform・varying の宣言は ShaderAst が木から集める。置いた物の頂点シェーダーだけは Render3dGlsl.MeshVertex の手書きの字。
// 式が CPU の描き手（SoftRaster3d）と同じ値になることは gl-parity の式の行が確かめる。
// 光の uniform を光ごとに引く式（点光源・スポットの配列の [i]）は、LightModel3d.Codegen の外に書かない（bin/lint-rules/forbid.json が止める）。
// 3D の色（Scene3d の頭の「3D の色」）: 光の color・ambient・かすみ・空・tint は描き手が線形の量へ戻して uniform に入れ、
// 頂点の色は lit の頂点シェーダーで、材質の albedo.rgb・emission とビルボードの絵は frag で線形へ戻し、色を作った直後に 1 回だけ画面の値へ戻す。
// WhyNot: 描き先を GL_SRGB8_ALPHA8 にして GL_FRAMEBUFFER_SRGB で戻さない — 2D の Pass が描き先を sRGB の絵として線形へ戻して読み、2D の絵が変わる。
// WhyNot: 3D を別の float の描き先へ描いて貼る時に戻さない — 背景の無い場面の縁は 2D の上で結局画面の値で混ざり、場面ごとに描き先と貼り直しが増える。
//   半透明の混ぜと MSAA の平均は戻した後の画面の値どうし。
pub mod Render3dGlsl {

    /// 置いた物の頂点シェーダー（深度だけのプログラム・uv の無い材質のプログラムで共有。頂点の色は値のまま渡す）。
    pub def meshVertexSource(): String = Render3dGlsl.MeshVertex.meshSource(false)

    /// 頂点の色のプログラム（lit）の頂点シェーダー。頂点の色を線形の量へ戻してから渡す（三角形の中は線形の量でつなぐ）。
    /// skinned なら骨つきの版。
    // WhyNot: meshVertexSource と共有しない — uv の無い材質の Spec の VertexColor まで線形の値になり、出口でもう一度戻して暗くなる。
    pub def litVertexSource(skinned: Bool): String = litVertexSourceFor(skinned, Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の litVertexSource（v#psx なら頂点を丸める）。
    pub def litVertexSourceFor(skinned: Bool, v: Render3d.ProgramKey.ShaderVariant): String = Render3dGlsl.MeshVertex.litSource(skinned, v#psx)

    /// 骨つきの版: 位置と法線を joint 行列の重みつきの和（Pose3d.jointMatrices の並び）で曲げてから model を掛ける。
    // WhyNot: 法線を skin の逆行列の転置で曲げない — 左上 3×3 のままだと倍率が軸ごとに違うジョイントで少し傾くが、
    //   CPU の描き手も同じ式なので GL と CPU の絵は一致する。その差は許す。
    pub def skinnedMeshVertexSource(): String = Render3dGlsl.MeshVertex.skinnedSource(false)

    /// 材質のプログラムの頂点シェーダー。uv の無い形は頂点の色のプログラムと同じ物・uv つきは vUv と vTangent も出す・
    /// lightmap つき（骨の無い版だけ）は 2 本目の uv の vUv2 も出す。骨つきの版は lightmap を読まない（Scene3d.lightmapOf が None）。
    pub def materialVertexSource(kind: { skinned = Bool, uv = Bool, lightmap = Bool }): String = materialVertexSourceFor(kind, false)

    /// psx（PS1 風の変種 +psx）なら頂点を丸め、uv つきの版は遠近で補正する uv（vUvPerspective）と画面の上でまっすぐつなぐ uv（vUvAffine）の 2 本を出す版の
    /// materialVertexSource（materialFragmentSource が uPsx.w で混ぜる）。
    pub def materialVertexSourceFor(kind: { skinned = Bool, uv = Bool, lightmap = Bool }, psx: Bool): String =
        Render3dGlsl.MeshVertex.materialSource(kind, psx)

    /// 頂点シェーダーへ数を渡すテクスチャの幅（texel）。
    pub def dataTextureWidth(): Int32 = Skin3d.maxJoints() * 4

    /// 1 体ごとの値の 1 体の幅（texel）。
    pub def texelsPerInstance(): Int32 = Render3d.InstanceValues.texelsPerInstance()

    /// 1 体ごとの値のテクスチャの 1 行の体の数（dataTextureWidth は texelsPerInstance で割り切れる）。
    pub def instancesPerRow(): Int32 = dataTextureWidth() / texelsPerInstance()

    /// 光の uniform と、光の式（lightAt）・かすみ（fogged）・影・色を作る最後の組み立て。式は LightModel3d の木から作る（CPU の描き手と同じ木）。
    pub def lightSource(): String = lightSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の lightSource（v の feature が足す定義を含める）。
    pub def lightSourceFor(v: Render3d.ProgramKey.ShaderVariant): String = ShaderAst.Glsl.print(Render3dShaders.lightDefinitions(v, Render3dShaders.featureOf(v)))

    /// 3D の色を作る最後の組み立て r3d_surfaceOut(albedoLinear, tint, light, emission, intensity, p, fogOn)（CPU の描き手は SoftRaster3d.materialColor と shadePixel）:
    /// 色 = albedoLinear × tint × light（fogOn ならかすみ）+ 線形へ戻した emission × intensity を、画面の値へ戻した物。
    /// albedoLinear は線形へ戻し済みの色（材質は r3d_srgbToLinear3(albedo.rgb)・ビルボードは絵・lit は頂点で戻した vColor）。
    // WhyNot: albedo をここで戻さない — lit の頂点の色は頂点シェーダーで戻してあり、ここで戻すと 2 回かかる。
    // WhyNot: emission にかすみを掛けない — 自分で光る物（溶岩・目）は遠くでもかすみに沈まずに見えてほしい。
    // WhyNot: 光の式の木（LightModel3d）に入れない — かすみの有無・ビルボードの lit・Depth の枝まで木の入力にすることになる。
    pub def surfaceOutSource(): String = ShaderAst.Glsl.print(Render3dShaders.surfaceOut() :: Nil)

    /// 色の空間の変換: Texture3d の式のスカラーの r3d_srgbToLinear / r3d_linearToSrgb と、
    /// その vec3 の版 r3d_srgbToLinear3 / r3d_linearToSrgb3。lit の頂点シェーダーが含める（frag は使う所から辿る）。
    pub def colorSpaceSource(): String = ShaderAst.Glsl.print(Render3dShaders.colorSpace())

    /// 頂点の色のプログラムの frag（vColor は litVertexSource が線形へ戻し済み）。
    pub def litFragmentSource(): String = litFragmentSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の litFragmentSource。
    pub def litFragmentSourceFor(v: Render3d.ProgramKey.ShaderVariant): String = ShaderAst.Glsl.fragment(Render3dShaders.litFragment(v, Nil))

    /// 材質の frag（本文は Render3dShaders.materialFragmentBody）。surface#uv = uv つきの形か（偽なら vUv は (0, 0) の const）・
    /// surface#normalMap = 法線マップを当てるか（uv つきの時だけ。光の計算の法線を、法線マップで傾けた n' にする）。
    /// 材質の部品（glsl#functions の materialEval）は大域の vUv・vWorld・vNormal・vColor を読む。psx の uv つきの vUv は main の頭で代入する大域の変数。
    // WhyNot: 欄を 1 つずつ並べた引数にしない — ProgramKind に欄が増えるたびに、呼び手とテストの字が全部書き換わる。skinned は頂点の側だけが読む。
    pub def materialFragmentSource(glsl: ShaderGen.MaterialGlsl, surface: Render3d.ProgramKey.ProgramKind): String =
        ShaderAst.Glsl.fragment(Render3dShaders.materialFragment(surface, Render3dShaders.glslMaterialPart(glsl, surface), Nil))

    /// materialFragmentSource の、材質の部品の所が空いた字（Render3d.ShaderLibrary.withMaterialPart で GLSL の材質の部品を入れる）。
    /// readsTextures = 入れる部品が絵を読むか。
    pub def materialFragmentTemplate(surface: Render3d.ProgramKey.ProgramKind, readsTextures: Bool): String =
        ShaderAst.Glsl.fragment(Render3dShaders.materialFragment(surface, Render3dShaders.templateMaterialPart(ShaderAst.Lang.Glsl, surface, readsTextures), Nil))

    /// metallic と roughness を持つ材質の色 pbrAt(p, n, albedo × tint, 拡散の光, vec3(metallic, roughness, 0), 映り込み)（LightModel3d.pbrModel の木から作る）と、
    /// それが読む環境マップの読みと、かすみ → emission の組み立て r3d_surfaceOutLit(pbrAt の色, emission, intensity, p)。
    /// 色 = albedo × (1 − metallic) × light + 鏡面 + 映り込みをかすみに通してから、線形へ戻した emission × intensity を足して画面の値へ戻した物
    /// （CPU の描き手は SoftRaster3d.materialPixel と materialColor）。
    // WhyNot: r3d_surfaceOut を使い回さない — あちらは albedo × tint × light を中で掛けるので、鏡面を足すには掛け算の前後を別に書く必要があり、
    //   持たない材質の GLSL の字を変えることになる。
    pub def metallicRoughnessSource(): String = metallicRoughnessSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の metallicRoughnessSource。
    pub def metallicRoughnessSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        ShaderAst.Glsl.print(Render3dShaders.metallicRoughnessDefinitions(v, Render3dShaders.featureOf(v)))

    /// lightmap のある面の光の式 lightmapLightAt(p, n, lightmap の色)（LightModel3d の木から作る）と、それが読む uniform と関数。
    pub def lightmapLightSource(): String = lightmapLightSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の lightmapLightSource。
    pub def lightmapLightSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        ShaderAst.Glsl.print(Render3dShaders.lightmapLightAt(v, Render3dShaders.featureOf(v)#spotShadow(Render3dShaders.spotShadow())) :: Nil)

    /// 外向きの法線 n をタンジェント（xyz と w）と法線マップの rgb c で傾けた applyNormalMap(n, tangent, strength, c)（式は Render3d.flix の頭。
    /// CPU の描き手は SoftRaster3d.applyNormalMap）。
    // WhyNot: タンジェントを頂点の値のまま使わない — 補間で N との直交が崩れ、傾ける向きが法線の側へ漏れる。
    // WhyNot: 長さ 0 のタンジェントで傾けない — normalize が NaN を出し、画素が黒く抜ける。その画素は n のまま。
    pub def applyNormalMapSource(): String = ShaderAst.Glsl.print(Render3dShaders.applyNormalMap() :: Nil)

    /// 奥行きの書き出し（Output.Depth）の形だけの frag（本文は Render3dShaders.depthFragment）。
    pub def depthFragmentSource(): String = ShaderAst.Glsl.fragment(Render3dShaders.depthFragment(Nil))

    /// ビルボードの頂点シェーダー（本文は Render3dShaders.billboardVertex）: カメラの right / up で四角を立てる（aCorner は 0〜1・y は下向き）。板ごとの値は instance の attribute（location 1〜4・
    /// 並びは Render3d.SceneList.billboardValueFloats: 点と光の当て方・anchor と size・貼る範囲の uv・tint と影を受ける点を離す長さ）。
    /// uRightPerBillboard = 1 なら板の横の向きを tint の欄から読む（影の地図の点光源の面）。
    pub def billboardVertexSource(): String = billboardVertexSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の billboardVertexSource（v#psx なら四角の角を丸める）。
    pub def billboardVertexSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        ShaderAst.Glsl.vertex(Render3dShaders.billboardVertex(v, Render3dShaders.BillboardRight.ByUniform, Nil))

    /// ビルボードの frag（本文は Render3dShaders.billboardFragment）。影の地図に描く時（Render3d.Shadow）は uDepthOut = 1 で、α で捨てた後に返る。
    pub def billboardFragmentSource(): String = billboardFragmentSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の billboardFragmentSource。ビルボードは点光源の影を受けないので v#pointShadows は読まない（Physical の光だけを変える）。
    pub def billboardFragmentSourceFor(v: Render3d.ProgramKey.ShaderVariant): String = ShaderAst.Glsl.fragment(Render3dShaders.billboardFragment(v, Nil))

    /// 空の頂点シェーダー（頂点の buffer を読まず、gl_VertexID の 3 点で描き先いっぱいを覆う三角形）。
    pub def skyVertexSource(): String = ShaderAst.Glsl.vertex(Render3dShaders.skyVertex())

    /// 空の frag（本文は Render3dShaders.skyFragment。NDC は画素の真ん中と uViewport から）。
    pub def skyFragmentSource(): String = ShaderAst.Glsl.fragment(Render3dShaders.skyFragment(Nil))

    /// 空の色の式 skyAt(向き)（LightModel3d の木から作る）と、それが読む uniform。
    pub def skyLightSource(): String = ShaderAst.Glsl.print(Render3dShaders.skyAt() :: Nil)

    /// Design の FBO を viewport 全面へ貼る（本文は Render3dShaders.blitVertex）。
    pub def blitVertexSource(): String = ShaderAst.Glsl.vertex(Render3dShaders.blitVertex())

    pub def blitFragmentSource(): String = ShaderAst.Glsl.fragment(Render3dShaders.blitFragment())
}
