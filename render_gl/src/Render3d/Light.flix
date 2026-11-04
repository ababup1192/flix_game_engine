// Render3d.Light — 3D の描き手（Render3d）の光の uniform（場面の光を並びへ詰める・プログラムへ渡す）。式の約束は Render3d.flix の頭。
mod Render3d.Light {
    import org.lwjgl.opengl.GL20
    use Render3d.{LightData, LightLocs}

    /// 光を uniform の並びへ詰める（点光源・スポットは選んだ後の物）。光の color・ambient・かすみの色は線形の量へ戻してから詰める
    /// （hemisphere・intensity・range は線形の量のまま）。
    pub def lightDataOf(scene: Scene3d.Scene3dCmd): LightData \ IO =
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
        { ambient = ambient, hemisphere = RenderUtil.f32(env#hemisphere), toonSteps = env#toonSteps,
          pointCount = List.length(points), pointPos = pointPos, pointColor = pointColor, pointRange = pointRange,
          spotCount = List.length(spots), spotPos = spot#position, spotDir = spot#direction, spotColor = spot#color,
          spotRange = spot#range, spotCone = spot#cone,
          fogOn = if (Option.isEmpty(env#fog)) 0 else 1, fogColor = fogColor, fogRange = fogRange, eye = eyeArray }

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

    pub def putLights(locs: LightLocs, d: LightData): Unit \ IO =
        GL20.glUniform3fv(locs#ambient, d#ambient);
        GL20.glUniform1f(locs#hemisphere, d#hemisphere);
        GL20.glUniform1i(locs#toonSteps, d#toonSteps);
        GL20.glUniform1i(locs#pointCount, d#pointCount);
        GL20.glUniform3fv(locs#pointPos, d#pointPos);
        GL20.glUniform3fv(locs#pointColor, d#pointColor);
        GL20.glUniform1fv(locs#pointRange, d#pointRange);
        GL20.glUniform1i(locs#spotCount, d#spotCount);
        GL20.glUniform3fv(locs#spotPos, d#spotPos);
        GL20.glUniform3fv(locs#spotDir, d#spotDir);
        GL20.glUniform3fv(locs#spotColor, d#spotColor);
        GL20.glUniform1fv(locs#spotRange, d#spotRange);
        GL20.glUniform2fv(locs#spotCone, d#spotCone);
        GL20.glUniform1i(locs#fogOn, d#fogOn);
        GL20.glUniform3fv(locs#fogColor, d#fogColor);
        GL20.glUniform2fv(locs#fogRange, d#fogRange);
        GL20.glUniform3fv(locs#eye, d#eye)
}
