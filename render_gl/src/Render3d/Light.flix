// Render3d.Light — 3D の描き手（Render3d）の光の uniform（場面の光を並びへ詰める・プログラムへ渡す）。式の約束は Render3d.flix の頭。
mod Render3d.Light {
    import fge.gl.GlContext
    use Render3d.{LightData}
    use Render3d.Uniforms.{R3dUniform, UniformLocations, has, put1f, put1fv, put1i, put2fv, put3fv, put4f}

    /// 場面の PS1 風の値の uniform（色の段の数 2^bits − 1・ディザの表の番号・ディザの強さ・アフィンの割合）。GL の uPsx と WGSL の R3dLight の psx。
    pub def psxValuesOf(scene: Scene3d.Scene3dCmd): Array[Float32, Static] \ IO =
        let psx = scene#psx;
        Array#{ RenderUtil.f32(Int32.toFloat64(Int32.leftShift(1, Scene3d.Psx.colorDepthOf(psx)) - 1)), RenderUtil.f32(Int32.toFloat64(Scene3d.Psx.patternCode(psx#dither))),
                RenderUtil.f32(Scene3d.Psx.ditherStrengthOf(psx)), RenderUtil.f32(Scene3d.Psx.affineOf(psx)) } @ Static

    /// 光を uniform の並びへ詰める（点光源・スポットは選んだ後の物）。PS1 風の値（psx・vertexSnap）も詰める。psxTarget（描き先の矩形）は 0 のままで、描き手が描き先を決めた所で入れる。光の color・ambient・かすみの色は線形の量へ戻してから詰める
    /// （hemisphere・intensity・range は線形の量のまま）。
    /// environmentLevels = 場面の環境マップの絵の段の数（環境マップが無い場面は 0。Render3d.Material.bindEnvironmentMap の答え）。
    pub def lightDataOf(scene: Scene3d.Scene3dCmd, environmentLevels: Int32): LightData \ IO =
        let toLinear = Texture3d.srgbToLinearColor;
        let env = { ambient = toLinear(scene#environment#ambient),
                    fog = scene#environment#fog |> Option.map(f -> { color = toLinear(f#color) | f }) | scene#environment };
        let eye = scene#camera#eye;
        let points = scene#pointLights |> List.map(l -> { color = toLinear(l#color) | l });
        let spots = scene#spotLights |> List.map(l -> { color = toLinear(l#color) | l });
        let pointPos = Array.repeat(Static, 3 * Scene3d.maxPointLights(), 0.0f32);
        let pointColor = Array.repeat(Static, 3 * Scene3d.maxPointLights(), 0.0f32);
        let pointRange = Array.repeat(Static, Scene3d.maxPointLights(), 1.0f32);
        points |> List.forEachWithIndex((i, l) -> {
            fillVec3(pointPos, i, l#position);
            fillVec3(pointColor, i, Vec3.mul(colorVec(l#color), l#intensity));
            Array.put(RenderUtil.f32(Float64.max(0.000001, l#range)), i, pointRange)
        });
        let spot = spotArrays(spots);
        let fogColor = Array.repeat(Static, 3, 0.0f32);
        let fogRange = Array.repeat(Static, 2, 0.0f32);
        env#fog |> Option.forEach(f -> {
            fillVec3(fogColor, 0, colorVec(f#color));
            Array.put(RenderUtil.f32(f#near), 0, fogRange);
            Array.put(RenderUtil.f32(f#far), 1, fogRange)
        });
        let ambient = Array.repeat(Static, 3, 0.0f32);
        fillVec3(ambient, 0, colorVec(env#ambient));
        let eyeArray = Array.repeat(Static, 3, 0.0f32);
        fillVec3(eyeArray, 0, eye);
        let reflection = LightModel3d.reflectionSkyOf(scene);
        let reflectArray = (c: Color) -> { let a = Array.repeat(Static, 3, 0.0f32); fillVec3(a, 0, colorVec(c)); a };
        let environment = environmentUniforms(scene, environmentLevels);
        let sun = sunUniforms(scene);
        let (skyContribution, sh) = Scene3d.Internal.SkyIrradiance.valuesOf(scene);
        { psx = psxValuesOf(scene), sh = Vector.toArray(Static, Vector.map(RenderUtil.f32, sh)), skyContribution = RenderUtil.f32(skyContribution),
          psxTarget = Array.repeat(Static, 4, 0.0f32), vertexSnap = RenderUtil.f32(Scene3d.Psx.vertexSnapOf(scene#psx)),
          sunDir = sun#direction, sunColor = sun#color, inverseUnitsPerMeterSquared = RenderUtil.f32(inverseUnitsPerMeterSquaredOf(scene)), ambient = ambient, hemisphere = RenderUtil.f32(env#hemisphere), toonSteps = env#toonSteps,
          pointCount = List.length(points), pointPos = pointPos, pointColor = pointColor, pointRange = pointRange,
          spotCount = List.length(spots), spotPos = spot#position, spotDir = spot#direction, spotColor = spot#color,
          spotRange = spot#range, spotCone = spot#cone,
          fogOn = if (Option.isEmpty(env#fog)) 0 else 1, fogColor = fogColor, fogRange = fogRange, eye = eyeArray,
          reflectZenith = reflectArray(reflection#zenith), reflectHorizon = reflectArray(reflection#horizon), reflectGround = reflectArray(reflection#ground),
          reflectCurve = RenderUtil.f32(reflection#curve),
          envOn = environment#on, envBoxOn = environment#boxOn, envBoxMin = environment#boxMin, envBoxMax = environment#boxMax,
          envBoxCenter = environment#boxCenter, envLevels = environment#levels, envIntensity = environment#intensity,
          envSrgb = environmentSrgbOf(scene#environmentMap) }

    /// 環境マップの絵を sRGB から線形へ戻して読むなら 1（8bit の絵）・そのまま読むなら 0（half の絵）。環境マップが無ければ 1（読まれない）。
    pub def environmentSrgbOf(e: Option[Scene3d.EnvironmentMap]): Int32 =
        if (e |> Option.exists(m -> Scene3d.environmentMapFieldsOf(m)#colorSpace == Texture3d.ColorSpace.Linear)) 0 else 1

    /// Physical の光の逆二乗を m で測る 1 / unitsPerMeter²（unitsPerMeter² が 1e−12 より小さければ 1e−12 で割る）。
    pub def inverseUnitsPerMeterSquaredOf(scene: Scene3d.Scene3dCmd): Float64 =
        1.0 / Float64.max(scene#unitsPerMeter * scene#unitsPerMeter, 1.0e-12)

    /// 太陽の uniform（点から太陽への向きと color × intensity。式は Scene3d.sunTermsOf）。太陽が無い場面は両方 0（拡散も鏡面も 0 になる）。
    def sunUniforms(scene: Scene3d.Scene3dCmd): { direction = Array[Float32, Static], color = Array[Float32, Static] } \ IO =
        let direction = Array.repeat(Static, 3, 0.0f32);
        let color = Array.repeat(Static, 3, 0.0f32);
        Scene3d.directionalLightOf(scene) |> Option.forEach(l -> {
            let t = Scene3d.sunTermsOf(l);
            fillVec3(direction, 0, t#toward);
            fillVec3(color, 0, t#color)
        });
        { direction = direction, color = color }

    /// 環境マップの uniform（強さ・箱・段の数）。環境マップが無い場面は on = 0（箱の値は使われない）。
    def environmentUniforms(scene: Scene3d.Scene3dCmd, levels: Int32): { on = Int32, boxOn = Int32, boxMin = Array[Float32, Static], boxMax = Array[Float32, Static],
                                                                      boxCenter = Array[Float32, Static], levels = Float32, intensity = Float32 } \ IO =
        let boxMin = Array.repeat(Static, 3, 0.0f32);
        let boxMax = Array.repeat(Static, 3, 0.0f32);
        let boxCenter = Array.repeat(Static, 3, 0.0f32);
        let box = scene#environmentMap |> Option.flatMap(e -> Scene3d.environmentMapFieldsOf(e)#box) |> Option.map(Scene3d.environmentBoxOf);
        box |> Option.forEach(b -> { fillVec3(boxMin, 0, b#min); fillVec3(boxMax, 0, b#max); fillVec3(boxCenter, 0, b#center) });
        let intensity = scene#environmentMap |> Option.map(Scene3d.environmentIntensityOf) |> Option.getWithDefault(0.0);
        { on = if (Option.isEmpty(scene#environmentMap)) 0 else 1, boxOn = if (Option.isEmpty(box)) 0 else 1,
          boxMin = boxMin, boxMax = boxMax, boxCenter = boxCenter,
          levels = RenderUtil.f32(Int32.toFloat64(Int32.max(1, levels))), intensity = RenderUtil.f32(intensity) }

    def spotArrays(spots: List[Scene3d.SpotLight]): { position = Array[Float32, Static], direction = Array[Float32, Static],
                                                       color = Array[Float32, Static], range = Array[Float32, Static],
                                                       cone = Array[Float32, Static] } \ IO =
        let n = Scene3d.maxSpotLights();
        let position = Array.repeat(Static, 3 * n, 0.0f32);
        let direction = Array.repeat(Static, 3 * n, 0.0f32);
        let color = Array.repeat(Static, 3 * n, 0.0f32);
        let range = Array.repeat(Static, n, 1.0f32);
        let cone = Array.repeat(Static, 2 * n, 0.0f32);
        spots |> List.forEachWithIndex((i, l) -> {
            fillVec3(position, i, l#position);
            fillVec3(direction, i, Vec3.normalized(Vec3.sub(l#target, l#position)));
            fillVec3(color, i, Vec3.mul(colorVec(l#color), l#intensity));
            Array.put(RenderUtil.f32(Float64.max(0.000001, l#range)), i, range);
            let edge = Scene3d.spotConeOf(l);
            Array.put(RenderUtil.f32(edge#outerCos), 2 * i, cone);
            Array.put(RenderUtil.f32(edge#innerCos), 2 * i + 1, cone)
        });
        { position = position, direction = direction, color = color, range = range, cone = cone }

    def colorVec(c: Color): Vec3.Vec3 = Vec3.v3(c#r, c#g, c#b)

    def fillVec3(out: Array[Float32, Static], i: Int32, v: Vec3.Vec3): Unit \ IO =
        Array.put(RenderUtil.f32(v#x), 3 * i, out);
        Array.put(RenderUtil.f32(v#y), 3 * i + 1, out);
        Array.put(RenderUtil.f32(v#z), 3 * i + 2, out)

    pub def putLights(gl: GlContext, locs: UniformLocations, d: LightData): Unit \ IO =
        put3fv(gl, locs, R3dUniform.Ambient, d#ambient);
        put1f(gl, locs, R3dUniform.Hemisphere, d#hemisphere);
        put1i(gl, locs, R3dUniform.ToonSteps, d#toonSteps);
        put1i(gl, locs, R3dUniform.PointCount, d#pointCount);
        put3fv(gl, locs, R3dUniform.PointPos, d#pointPos);
        put3fv(gl, locs, R3dUniform.PointColor, d#pointColor);
        put1fv(gl, locs, R3dUniform.PointRange, d#pointRange);
        put1i(gl, locs, R3dUniform.SpotCount, d#spotCount);
        put3fv(gl, locs, R3dUniform.SpotPos, d#spotPos);
        put3fv(gl, locs, R3dUniform.SpotDir, d#spotDir);
        put3fv(gl, locs, R3dUniform.SpotColor, d#spotColor);
        put1fv(gl, locs, R3dUniform.SpotRange, d#spotRange);
        put2fv(gl, locs, R3dUniform.SpotCone, d#spotCone);
        put1i(gl, locs, R3dUniform.FogOn, d#fogOn);
        put3fv(gl, locs, R3dUniform.FogColor, d#fogColor);
        put2fv(gl, locs, R3dUniform.FogRange, d#fogRange);
        put3fv(gl, locs, R3dUniform.Eye, d#eye);
        put3fv(gl, locs, R3dUniform.SunDir, d#sunDir);
        put3fv(gl, locs, R3dUniform.SunColor, d#sunColor);
        put1f(gl, locs, R3dUniform.InverseUnitsPerMeterSquared, d#inverseUnitsPerMeterSquared);
        putVec4(gl, locs, R3dUniform.Psx, d#psx);
        putVec4(gl, locs, R3dUniform.PsxTarget, d#psxTarget);
        put1f(gl, locs, R3dUniform.VertexSnap, d#vertexSnap);
        put3fv(gl, locs, R3dUniform.Sh, d#sh);
        put1f(gl, locs, R3dUniform.SkyContribution, d#skyContribution);
        putReflection(gl, locs, d)

    def putVec4(gl: GlContext, locs: UniformLocations, u: R3dUniform, v: Array[Float32, Static]): Unit \ IO =
        put4f(gl, locs, u, Array.get(0, v), Array.get(1, v), Array.get(2, v), Array.get(3, v))

    /// 映り込みに使う空の 3 色と curve を渡す（metallic と roughness を持つ材質のプログラムだけが宣言している。無いプログラムは何も呼ばない）。
    // WhyNot: uZenith を宣言しないプログラムで残りの 11 個の handle を 1 つずつ引かない — 持たないプログラムが大半で、毎回 11 回の無駄な表引きになる。
    def putReflection(gl: GlContext, locs: UniformLocations, d: LightData): Unit \ IO =
        if (not has(R3dUniform.Zenith, locs)) ()
        else {
            put3fv(gl, locs, R3dUniform.Zenith, d#reflectZenith);
            put3fv(gl, locs, R3dUniform.Horizon, d#reflectHorizon);
            put3fv(gl, locs, R3dUniform.Ground, d#reflectGround);
            put1f(gl, locs, R3dUniform.Curve, d#reflectCurve);
            put1i(gl, locs, R3dUniform.EnvOn, d#envOn);
            if (d#envOn == 0) ()
            else {
                put1i(gl, locs, R3dUniform.EnvBoxOn, d#envBoxOn);
                put3fv(gl, locs, R3dUniform.EnvBoxMin, d#envBoxMin);
                put3fv(gl, locs, R3dUniform.EnvBoxMax, d#envBoxMax);
                put3fv(gl, locs, R3dUniform.EnvBoxCenter, d#envBoxCenter);
                put1f(gl, locs, R3dUniform.EnvLevels, d#envLevels);
                put1f(gl, locs, R3dUniform.EnvIntensity, d#envIntensity);
                put1i(gl, locs, R3dUniform.EnvSrgb, d#envSrgb)
            }
        }
}
