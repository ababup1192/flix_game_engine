// Render3d.ProgramKey — 3D の描き手の GL と WebGPU が共有する、プログラムの版の約束（材質の版・場面の変種・鍵）。
// 変種のフラグは表（flagRows）の 1 行ずつ。フラグを足す時に render_gl の中で直すのは表の 1 行と、Render3dShaders.featureOfFlag の case 1 つ。
// engine の Scene3d.PreloadVariant（ゲームへ出している record）は変えず、ここで 1 回だけ Set[VariantFlag] へ変える。
pub mod Render3d.ProgramKey {

    /// 場面ごとのシェーダーの変種（Unity の shader variant に当たる）。pointShadows = 点光源の影を引く（鍵の +ps）・physicalUnits = Physical の光（鍵の +pu）・
    /// psx = PS1 風の描き方（Scene3d.Psx.isOn。鍵の +psx。色の丸めとディザ・頂点の揺れ・アフィンの uv を uniform で渡す）・
    /// skyIrradiance = ambient に景色の拡散の光を混ぜる（Scene3d.withSkyContribution。鍵の +sh）・
    /// ambientOcclusion = 画面の上の SSAO の mask を読む（Scene3dCmd#screenInputs に ambientOcclusion がある・鍵の +ao）。
    /// どれも偽なら既定のプログラム（変種を足す前と同じ字）。先に組む宣言の Scene3d.PreloadVariant と同じ形。
    pub type alias ShaderVariant = Scene3d.PreloadVariant

    /// 変種のフラグ（ShaderVariant の欄 1 つ）。
    pub enum VariantFlag with Eq, Order {
        case PointShadows, PhysicalUnits, Psx, SkyIrradiance, AmbientOcclusion
    }

    /// WebGPU の場面の group 0 に変種が足す binding（Render3dWgsl.variantDeclarations と WebGpuRenderer.Group0.sceneLayoutDesc が並べる順）。
    /// LightBuffer = R3dLight の buffer・PointShadowAtlas = 点光源の影の atlas・AoMask = SSAO の mask の絵と R3dAo の buffer。
    pub enum Group0Binding with Eq, Order, ToString {
        case LightBuffer, PointShadowAtlas, AoMask
    }

    /// 変種のフラグの表の 1 行。key = 鍵の字（Scene3d.preloadVariantKey と同じ）・kindCodeBit = 材質の版を 1 つの数にする時の bit・
    /// billboard = ビルボードのプログラムも受けるか・group0 = WebGPU の group 0 に足す binding（2 つのフラグが同じ binding を足しても 1 つ）。
    /// シェーダーの名前のある点ごとの差し込みは Render3dShaders.featureOfFlag。
    // WhyNot: 差し込み（Render3dShaders.ShaderFeature）を行の欄に持たない — 鍵の字を引くだけのブラウザの描き手まで、シェーダーの木を組む関数を wasm に持つ。
    pub type alias FlagRow = { flag = VariantFlag, key = String, kindCodeBit = Int32, billboard = Bool, group0 = List[Group0Binding] }

    /// 変種のフラグの表（鍵の並びの順）。
    // WhyNot: ビルボードに点光源の影を受けさせない — 板は薄く、点光源の影の地図の 6 面を引くと 1 枚の板のために全部の面を読む。
    pub def flagRows(): List[FlagRow] =
        { flag = VariantFlag.PointShadows,  key = "+ps",  kindCodeBit = 256,  billboard = false, group0 = Group0Binding.LightBuffer :: Group0Binding.PointShadowAtlas :: Nil } ::
        { flag = VariantFlag.PhysicalUnits, key = "+pu",  kindCodeBit = 512,  billboard = true,  group0 = Group0Binding.LightBuffer :: Nil } ::
        { flag = VariantFlag.Psx,           key = "+psx", kindCodeBit = 1024, billboard = true,  group0 = Group0Binding.LightBuffer :: Nil } ::
        { flag = VariantFlag.SkyIrradiance, key = "+sh",  kindCodeBit = 2048, billboard = true,  group0 = Group0Binding.LightBuffer :: Nil } ::
        { flag = VariantFlag.AmbientOcclusion, key = "+ao", kindCodeBit = 4096, billboard = true, group0 = Group0Binding.AoMask :: Nil } :: Nil

    /// 変種 v のフラグの集まり（render_gl へ入る所で 1 回だけ変える）。
    pub def flagsOf(v: ShaderVariant): Set[VariantFlag] =
        let on = (b: Bool, flag: VariantFlag) -> if (b) flag :: Nil else Nil;
        List.toSet(on(v#pointShadows, VariantFlag.PointShadows) ::: on(v#physicalUnits, VariantFlag.PhysicalUnits) ::: on(v#psx, VariantFlag.Psx)
                   ::: on(v#skyIrradiance, VariantFlag.SkyIrradiance) ::: on(v#ambientOcclusion, VariantFlag.AmbientOcclusion))

    /// フラグの集まり flags の変種。
    pub def variantOf(flags: Set[VariantFlag]): ShaderVariant =
        { pointShadows = Set.memberOf(VariantFlag.PointShadows, flags), physicalUnits = Set.memberOf(VariantFlag.PhysicalUnits, flags),
          psx = Set.memberOf(VariantFlag.Psx, flags), skyIrradiance = Set.memberOf(VariantFlag.SkyIrradiance, flags),
          ambientOcclusion = Set.memberOf(VariantFlag.AmbientOcclusion, flags) }

    /// 変種 v が WebGPU の場面の group 0 に足す binding。
    pub def group0Of(v: ShaderVariant): Set[Group0Binding] =
        rowsOf(v) |> List.flatMap(row -> row#group0) |> List.toSet

    /// 変種 v の、表で row が真になるフラグの行。
    // WhyNot: flagsOf の Set を作らない — 材質の問い合わせが置いた物 1 つごとに通り（kindCodeBitsOf）、
    // 毎コマ数千の Set と表の行を作って捨てる。フラグが 1 つも無い変種（たいていの場面）は表も作らない。
    pub def rowsOf(v: ShaderVariant): List[FlagRow] =
        if (not (v#pointShadows or v#physicalUnits or v#psx or v#skyIrradiance or v#ambientOcclusion)) Nil
        else flagRows() |> List.filter(row -> isFlagOn(v, row#flag))

    def isFlagOn(v: ShaderVariant, flag: VariantFlag): Bool = match flag {
        case VariantFlag.PointShadows     => v#pointShadows
        case VariantFlag.PhysicalUnits    => v#physicalUnits
        case VariantFlag.Psx              => v#psx
        case VariantFlag.SkyIrradiance    => v#skyIrradiance
        case VariantFlag.AmbientOcclusion => v#ambientOcclusion
    }

    /// 点光源の影なし・Legacy の光・PS1 風なし・景色の拡散の光なしの変種。
    pub def defaultShaderVariant(): ShaderVariant = variantOf(Set.empty())

    /// 場面 scene の変種（pointShadows が Some なら +ps — このコマで影を落とす灯りが 0 本でも +ps のまま・Physical なら +pu）。
    // WhyNot: このコマで影を落とす灯りの数で +ps を決めない — 灯りが画面に出入りするたびにシェーダーを組み直す。
    pub def shaderVariantOf(scene: Scene3d.Scene3dCmd): ShaderVariant = Scene3d.preloadVariantOf(scene)

    /// 場面 scene の pass のプログラムの変種（色の場面は shaderVariantOf・奥行きの書き出しは既定。Render3d.ScenePlan の groupScene と同じ決め方）。
    pub def passVariantOf(scene: Scene3d.Scene3dCmd): ShaderVariant = match scene#output {
        case Scene3d.Output.Color    => shaderVariantOf(scene)
        case Scene3d.Output.Depth(_) => defaultShaderVariant()
    }

    /// ビルボードのプログラムの変種（表で billboard が偽のフラグを落とす）。
    pub def billboardVariantOf(v: ShaderVariant): ShaderVariant =
        rowsOf(v) |> List.filter(row -> row#billboard) |> List.map(row -> row#flag) |> List.toSet |> variantOf

    /// 変種 v の光の式の木の変種（点光源の影・光の量の読み方・景色の拡散の光）。
    pub def lightVariantOf(v: ShaderVariant): LightModel3d.LightVariant =
        { pointShadows = v#pointShadows, lightUnits = Some(if (v#physicalUnits) Scene3d.LightUnits.Physical else Scene3d.LightUnits.Legacy),
          skyIrradiance = v#skyIrradiance, ambientOcclusion = v#ambientOcclusion }

    /// 変種 v の鍵の字（表の key を並べた物。既定は空）。
    pub def variantKeyOf(v: ShaderVariant): String = rowsOf(v) |> List.map(row -> row#key) |> String.flatten

    /// 変種 v の、材質の版を 1 つの数にする時の bit の和。
    pub def kindCodeBitsOf(v: ShaderVariant): Int32 = rowsOf(v) |> List.foldLeft((acc, row) -> acc + row#kindCodeBit, 0)

    /// 材質のプログラムを分ける形。skinned = 骨つき・uv = uv とタンジェントを持つ・normalMap = 法線マップを当てる（uv つきの時だけ真）・
    /// lightmap = ベイクした光を 2 本目の uv で読む（Scene3d.lightmapOfFields が Some の時だけ真。骨つきには付かない）・
    /// blend = 半透明（出す α を材質の α に）・doubleSided = 裏の面の光の法線を裏返す・
    /// coverage = cutout を discard でなく alpha to coverage で抜く（isCoverageCutout が真の時だけ）・
    /// metallicRoughness = metallic と roughness を持つ材質（鏡面ハイライトと空の映り込みを足す式のプログラム。持たない材質の GLSL は変わらない）・
    /// screenAoOnBlend = 半透明でも画面の上の SSAO の mask を読む（screenAoOnBlendOf が真の時だけ）・
    /// variant = 場面のシェーダーの変種。
    // WhyNot: blend・doubleSided・coverage・metallicRoughness と変種を uniform で切り替えない — 使わない材質の GLSL の字が変わり、
    //   どの GPU でも同じ絵になる保証が崩れる。どれも偽の版は、それらを足す前と 1 字も同じ GLSL を組む。
    pub type alias ProgramKind = { skinned = Bool, uv = Bool, normalMap = Bool, lightmap = Bool, blend = Bool, doubleSided = Bool, coverage = Bool,
                                   metallicRoughness = Bool, screenAoOnBlend = Bool, variant = ShaderVariant }

    /// 材質 m を変種 v で描く時に、半透明でも SSAO の mask を読むか（Scene3d.MaterialFields#screenAoOnBlend）。
    // WhyNot: 材質の欄をそのまま版に入れない — +ao の無い場面で同じ字のプログラムを 2 回組み、記録の行も増える。
    pub def screenAoOnBlendOf(v: ShaderVariant, m: Scene3d.MaterialFields): Bool =
        v#ambientOcclusion and m#blend and m#screenAoOnBlend

    /// 材質のプログラムの鍵（2D の Shader 面の鍵 = spec の名前 と重ならない）。骨つき・uv つき・法線マップつき・lightmap つきの版は GLSL が違うので別の鍵。
    /// 材質の側は spec と emission の中身の鍵（MaterialFields#shaderHash）なので、同じ名前で木の違う材質が並んでも組み直さず、ゲームは名前を分けなくてよい。
    /// cutout・params・wrap は uniform と sampler で渡すので鍵に入れない（blend・doubleSided・法線マップ・coverage は kind の側）。
    pub def materialKey(m: Scene3d.MaterialFields, kind: ProgramKind): String =
        "3d" + (if (kind#skinned) "+skin" else "") + (if (kind#uv) "+uv" else "") + (if (kind#normalMap) "+nm" else "") + (if (kind#lightmap) "+lm" else "")
            + (if (kind#blend) "+bl" else "") + (if (kind#doubleSided) "+ds" else "") + (if (kind#coverage) "+cov" else "")
            + (if (kind#metallicRoughness) "+mr" else "") + (if (kind#screenAoOnBlend) "+ab" else "") + variantKeyOf(kind#variant)
            + ":" + Int64.toString(force m#shaderHash)
}
