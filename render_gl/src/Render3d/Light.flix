// Render3d.Light — 3D の描き手（Render3d）の光の uniform（場面の光を並びへ詰める・プログラムへ渡す）。式の約束は Render3d.flix の頭。
mod Render3d.Light {
    import fge.gl.GlContext
    use Render3d.{LightData, LightLocs}

    /// 光を uniform の並びへ詰める（点光源・スポットは選んだ後の物）。光の color・ambient・かすみの色は線形の量へ戻してから詰める
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
        { ambient = ambient, hemisphere = RenderUtil.f32(env#hemisphere), toonSteps = env#toonSteps,
          pointCount = List.length(points), pointPos = pointPos, pointColor = pointColor, pointRange = pointRange,
          spotCount = List.length(spots), spotPos = spot#position, spotDir = spot#direction, spotColor = spot#color,
          spotRange = spot#range, spotCone = spot#cone,
          fogOn = if (Option.isEmpty(env#fog)) 0 else 1, fogColor = fogColor, fogRange = fogRange, eye = eyeArray,
          reflectZenith = reflectArray(reflection#zenith), reflectHorizon = reflectArray(reflection#horizon), reflectGround = reflectArray(reflection#ground),
          reflectCurve = RenderUtil.f32(reflection#curve),
          envOn = environment#on, envBoxOn = environment#boxOn, envBoxMin = environment#boxMin, envBoxMax = environment#boxMax,
          envBoxCenter = environment#boxCenter, envLevels = environment#levels, envIntensity = environment#intensity }

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

    pub def putLights(gl: GlContext, locs: LightLocs, d: LightData): Unit \ IO =
        gl.uniform3fv(locs#ambient, d#ambient);
        gl.uniform1f(locs#hemisphere, d#hemisphere);
        gl.uniform1i(locs#toonSteps, d#toonSteps);
        gl.uniform1i(locs#pointCount, d#pointCount);
        gl.uniform3fv(locs#pointPos, d#pointPos);
        gl.uniform3fv(locs#pointColor, d#pointColor);
        gl.uniform1fv(locs#pointRange, d#pointRange);
        gl.uniform1i(locs#spotCount, d#spotCount);
        gl.uniform3fv(locs#spotPos, d#spotPos);
        gl.uniform3fv(locs#spotDir, d#spotDir);
        gl.uniform3fv(locs#spotColor, d#spotColor);
        gl.uniform1fv(locs#spotRange, d#spotRange);
        gl.uniform2fv(locs#spotCone, d#spotCone);
        gl.uniform1i(locs#fogOn, d#fogOn);
        gl.uniform3fv(locs#fogColor, d#fogColor);
        gl.uniform2fv(locs#fogRange, d#fogRange);
        gl.uniform3fv(locs#eye, d#eye);
        putReflection(gl, locs, d)

    /// 映り込みに使う空の 3 色と curve を渡す（metallic と roughness を持つ材質のプログラムだけが宣言している。無いプログラムは何も呼ばない）。
    // WhyNot: location が -1 のままで GL を呼ばない — 持たないプログラムが大半で、毎回 4 回の無駄な呼び出しになる。
    def putReflection(gl: GlContext, locs: LightLocs, d: LightData): Unit \ IO =
        if (locs#reflectZenith < 0) ()
        else {
            gl.uniform3fv(locs#reflectZenith, d#reflectZenith);
            gl.uniform3fv(locs#reflectHorizon, d#reflectHorizon);
            gl.uniform3fv(locs#reflectGround, d#reflectGround);
            gl.uniform1f(locs#reflectCurve, d#reflectCurve);
            gl.uniform1i(locs#envOn, d#envOn);
            if (d#envOn == 0) ()
            else {
                gl.uniform1i(locs#envBoxOn, d#envBoxOn);
                gl.uniform3fv(locs#envBoxMin, d#envBoxMin);
                gl.uniform3fv(locs#envBoxMax, d#envBoxMax);
                gl.uniform3fv(locs#envBoxCenter, d#envBoxCenter);
                gl.uniform1f(locs#envLevels, d#envLevels);
                gl.uniform1f(locs#envIntensity, d#envIntensity)
            }
        }
}
