// Render3d.UniformLayout — WGSL の uniform の struct（R3dScene・R3dLight）の欄の表 1 つから、struct の字と、詰める側のバイト位置の両方を作る。
// 欄の並びと型は表にだけ書き、Render3dWgsl の struct の字と WebGPU の backend の詰める所（WebGpuRenderer・WebGpuShadows・WebGpuSky）は表から引く。
// 位置は WGSL の並びの決まり（欄ごとのそろえ: f32・i32 は 4・vec2f は 8・vec3f・vec4f・mat4x4f・配列は 16。大きさ: vec3f は 12・mat4x4f は 64・
// array<vec4f, N> は 16N。struct の大きさは 16 の倍数へ切り上げ）で前から積む。
// 字は 1 行 16 バイトの区切り: 4 字下げで欄を ", " でつなぎ、欄の終わり（位置 + 大きさ）が 16 の倍数になった所で ",\n"。
pub mod Render3d.UniformLayout {

    /// 欄の WGSL の型。Vec4Array(n) = array<vec4f, n>（f32 と vec2f の光の配列も、uniform の配列の 16 バイト刻みに合わせてこの形にする）。
    pub enum FieldType with Eq {
        case F32
        case I32
        case Vec2f
        case Vec3f
        case Vec4f
        case Mat4
        case Vec4Array(Int32)
    }

    /// 表の 1 行: (欄の鍵, WGSL の欄の名前, 型)。並びが struct の並び。
    pub type alias Field[f] = (f, String, FieldType)

    def alignOf(t: FieldType): Int32 = match t {
        case FieldType.F32          => 4
        case FieldType.I32          => 4
        case FieldType.Vec2f        => 8
        case FieldType.Vec3f        => 16
        case FieldType.Vec4f        => 16
        case FieldType.Mat4         => 16
        case FieldType.Vec4Array(_) => 16
    }

    def sizeOf(t: FieldType): Int32 = match t {
        case FieldType.F32          => 4
        case FieldType.I32          => 4
        case FieldType.Vec2f        => 8
        case FieldType.Vec3f        => 12
        case FieldType.Vec4f        => 16
        case FieldType.Mat4         => 64
        case FieldType.Vec4Array(n) => 16 * n
    }

    def wgslTypeOf(t: FieldType): String = match t {
        case FieldType.F32          => "f32"
        case FieldType.I32          => "i32"
        case FieldType.Vec2f        => "vec2f"
        case FieldType.Vec3f        => "vec3f"
        case FieldType.Vec4f        => "vec4f"
        case FieldType.Mat4         => "mat4x4f"
        case FieldType.Vec4Array(n) => "array<vec4f, ${n}>"
    }

    def roundUp(x: Int32, a: Int32): Int32 = (x + a - 1) / a * a

    /// 欄ごとの (位置, 大きさ)（表の並び）。
    def placed(fields: List[Field[f]]): List[(f, String, FieldType, Int32)] =
        fields |> List.foldLeft((acc, field) -> {
            let (rev, at) = acc;
            let (key, name, t) = field;
            let start = roundUp(at, alignOf(t));
            ((key, name, t, start) :: rev, start + sizeOf(t))
        }, (Nil, 0)) |> fst |> List.reverse

    /// 欄の鍵 → バイト位置。
    pub def offsetsOf(fields: List[Field[f]]): Map[f, Int32] with Order[f] =
        placed(fields) |> List.map(p -> { let (key, _, _, at) = p; (key, at) }) |> List.toMap

    /// struct のバイト数（16 の倍数へ切り上げ）。
    pub def bytesOf(fields: List[Field[f]]): Int32 =
        let ends = placed(fields) |> List.map(p -> { let (_, _, t, at) = p; at + sizeOf(t) });
        roundUp(List.foldLeft(Int32.max, 0, ends), 16)

    /// struct の WGSL の字（"struct <name> {\n" … "};\n"）。
    pub def structSource(name: String, fields: List[Field[f]]): String =
        let lines = placed(fields) |> List.foldLeft((acc, p) -> {
            let (done, line) = acc;
            let (_, field, t, at) = p;
            let piece = "${field}: ${wgslTypeOf(t)}";
            let current = piece :: line;
            if (Int32.remainder(at + sizeOf(t), 16) == 0) (("    " + String.intercalate(", ", List.reverse(current)) + ",\n") :: done, Nil)
            else (done, current)
        }, (Nil, Nil));
        let (done, rest) = lines;
        let tail = if (List.isEmpty(rest)) Nil else ("    " + String.intercalate(", ", List.reverse(rest)) + ",\n") :: Nil;
        "struct ${name} {\n" + String.intercalate("", List.append(List.reverse(done), tail)) + "};\n"

    /// 位置の表 offsets から鍵 key の位置（表に無い鍵はプログラムの誤り）。
    pub def offsetOf(offsets: Map[f, Int32], key: f): Int32 with Order[f], ToString[f] = match Map.get(key, offsets) {
        case Some(at) => at
        case None     => bug!("Render3d.UniformLayout: 欄 ${key} が表に無い")
    }

    // ── R3dScene（group 0 の binding 0） ──

    /// R3dScene の欄。名前は Render3dGlsl の uniform と同じ（u を頭に付けた物）。
    pub enum SceneField with Eq, Order, ToString {
        case Ambient, Hemisphere, Eye, ToonSteps, FogColor, FogOn, FogRange, PointCount, SpotCount, SunDir, SunShadowOn, SunColor, SunNormalShift,
             SunForward, SunBias, SunFade, SunPcf, SunStrength, Zenith, Curve, Horizon, EnvOn, Ground, EnvBoxOn, EnvBoxMin, EnvLevels, EnvBoxMax,
             EnvIntensity, EnvBoxCenter, ShadowOn, DepthRange, ShadowSpot, ShadowPcf, ShadowBias, ShadowStrength, DepthOut, EnvSrgb, Pad1, Pad2, Pad3, Pad4,
             ShadowMatrix, SunMatrix, PointPos, PointColor, PointRange, SpotPos, SpotDir, SpotColor, SpotRange, SpotCone, SkyForward, SkyRight, SkyUp
    }

    /// R3dScene の表。vec3f の後ろの 4 バイトには f32 か i32 を 1 つ置く。末尾の uSky* は空の画素の向きの材料（Render3d.WebGpuSky.packValues）。
    // uEnvSrgb は空いていた pad の枠に置いた（環境マップの絵を sRGB から戻すなら 1。既定の場面の欄の位置と buffer の大きさは変わらない）。
    // WhyNot: pad0〜pad4 を表から抜かない — 抜くと uShadowMatrix が 272 から 256 へ動き、struct の字（TestPointShadowVariants の既定の WGSL の sha）と
    //   各欄の位置が変わる。位置は表から求めるので詰める側とはずれないが、0 差を確かめる前提が崩れる。
    pub def sceneFields(): List[Field[SceneField]] =
        let p = Scene3d.maxPointLights();
        let s = Scene3d.maxSpotLights();
        (SceneField.Ambient, "uAmbient", FieldType.Vec3f) :: (SceneField.Hemisphere, "uHemisphere", FieldType.F32) ::
        (SceneField.Eye, "uEye", FieldType.Vec3f) :: (SceneField.ToonSteps, "uToonSteps", FieldType.I32) ::
        (SceneField.FogColor, "uFogColor", FieldType.Vec3f) :: (SceneField.FogOn, "uFogOn", FieldType.I32) ::
        (SceneField.FogRange, "uFogRange", FieldType.Vec2f) :: (SceneField.PointCount, "uPointCount", FieldType.I32) :: (SceneField.SpotCount, "uSpotCount", FieldType.I32) ::
        (SceneField.SunDir, "uSunDir", FieldType.Vec3f) :: (SceneField.SunShadowOn, "uSunShadowOn", FieldType.I32) ::
        (SceneField.SunColor, "uSunColor", FieldType.Vec3f) :: (SceneField.SunNormalShift, "uSunNormalShift", FieldType.F32) ::
        (SceneField.SunForward, "uSunForward", FieldType.Vec3f) :: (SceneField.SunBias, "uSunBias", FieldType.F32) ::
        (SceneField.SunFade, "uSunFade", FieldType.Vec2f) :: (SceneField.SunPcf, "uSunPcf", FieldType.I32) :: (SceneField.SunStrength, "uSunStrength", FieldType.F32) ::
        (SceneField.Zenith, "uZenith", FieldType.Vec3f) :: (SceneField.Curve, "uCurve", FieldType.F32) ::
        (SceneField.Horizon, "uHorizon", FieldType.Vec3f) :: (SceneField.EnvOn, "uEnvOn", FieldType.I32) ::
        (SceneField.Ground, "uGround", FieldType.Vec3f) :: (SceneField.EnvBoxOn, "uEnvBoxOn", FieldType.I32) ::
        (SceneField.EnvBoxMin, "uEnvBoxMin", FieldType.Vec3f) :: (SceneField.EnvLevels, "uEnvLevels", FieldType.F32) ::
        (SceneField.EnvBoxMax, "uEnvBoxMax", FieldType.Vec3f) :: (SceneField.EnvIntensity, "uEnvIntensity", FieldType.F32) ::
        (SceneField.EnvBoxCenter, "uEnvBoxCenter", FieldType.Vec3f) :: (SceneField.ShadowOn, "uShadowOn", FieldType.I32) ::
        (SceneField.DepthRange, "uDepthRange", FieldType.Vec2f) :: (SceneField.ShadowSpot, "uShadowSpot", FieldType.I32) :: (SceneField.ShadowPcf, "uShadowPcf", FieldType.I32) ::
        (SceneField.ShadowBias, "uShadowBias", FieldType.F32) :: (SceneField.ShadowStrength, "uShadowStrength", FieldType.F32) ::
        (SceneField.DepthOut, "uDepthOut", FieldType.I32) :: (SceneField.EnvSrgb, "uEnvSrgb", FieldType.I32) ::
        (SceneField.Pad1, "pad1", FieldType.F32) :: (SceneField.Pad2, "pad2", FieldType.F32) :: (SceneField.Pad3, "pad3", FieldType.F32) :: (SceneField.Pad4, "pad4", FieldType.F32) ::
        (SceneField.ShadowMatrix, "uShadowMatrix", FieldType.Mat4) :: (SceneField.SunMatrix, "uSunMatrix", FieldType.Mat4) ::
        (SceneField.PointPos, "uPointPos", FieldType.Vec4Array(p)) :: (SceneField.PointColor, "uPointColor", FieldType.Vec4Array(p)) ::
        (SceneField.PointRange, "uPointRange", FieldType.Vec4Array(p)) ::
        (SceneField.SpotPos, "uSpotPos", FieldType.Vec4Array(s)) :: (SceneField.SpotDir, "uSpotDir", FieldType.Vec4Array(s)) ::
        (SceneField.SpotColor, "uSpotColor", FieldType.Vec4Array(s)) :: (SceneField.SpotRange, "uSpotRange", FieldType.Vec4Array(s)) ::
        (SceneField.SpotCone, "uSpotCone", FieldType.Vec4Array(s)) ::
        (SceneField.SkyForward, "uSkyForward", FieldType.Vec4f) :: (SceneField.SkyRight, "uSkyRight", FieldType.Vec4f) :: (SceneField.SkyUp, "uSkyUp", FieldType.Vec4f) :: Nil

    /// R3dScene の欄の位置。
    pub def sceneOffsets(): Map[SceneField, Int32] = offsetsOf(sceneFields())

    // ── R3dLight（変種の group 0 の binding 6） ──

    /// R3dLight の欄（点光源の影の値と 1 / unitsPerMeter² と PS1 風の値と景色の拡散の光）。
    pub enum LightField with Eq, Order, ToString {
        case PointShadow, PointShadowAtlas, PointShadowBias, InverseUnitsPerMeterSquared, Pad0, Psx, Sh, SkyContribution
    }

    /// R3dLight の表。uPointShadow = 点光源ごとの (slot, A, B, strength)・uPointShadowAtlas = (大きさ, 列, 縮み, pcf)・uPointShadowBias = (bias, normalBias)・
    /// uPsx = PS1 風の (段の数, ディザの表の番号, 強さ, アフィンの割合)（GLSL の uPsx と同じ値）・uSh = 景色の拡散の光の係数 9 個（xyz・GLSL の uSh と同じ値）・
    /// uSkyContribution = 混ぜる割合。
    // WhyNot: +sh の時だけ別の struct と binding を足さない — group 0 の layout を変種の組ごとに分けることになる（今は 0・1・2 の 3 つ）。R3dLight は既定の場面が読まないので、欄を足しても既定の WGSL は変わらない。
    pub def lightFields(): List[Field[LightField]] =
        (LightField.PointShadow, "uPointShadow", FieldType.Vec4Array(Scene3d.maxPointLights())) ::
        (LightField.PointShadowAtlas, "uPointShadowAtlas", FieldType.Vec4f) ::
        (LightField.PointShadowBias, "uPointShadowBias", FieldType.Vec2f) ::
        (LightField.InverseUnitsPerMeterSquared, "uInverseUnitsPerMeterSquared", FieldType.F32) ::
        (LightField.Pad0, "pad0", FieldType.F32) ::
        (LightField.Psx, "uPsx", FieldType.Vec4f) ::
        (LightField.Sh, "uSh", FieldType.Vec4Array(9)) ::
        (LightField.SkyContribution, "uSkyContribution", FieldType.F32) :: Nil

    /// R3dLight の欄の位置。
    pub def lightOffsets(): Map[LightField, Int32] = offsetsOf(lightFields())
}
