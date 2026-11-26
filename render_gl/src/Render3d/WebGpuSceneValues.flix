// Render3d.WebGpuSceneValues — WebGPU の場面の値（R3dScene）を buffer へ詰める。欄の位置は Render3d.UniformLayout の表から引く（WGSL の struct の字も同じ表から作る）。
// GL の Render3d.Light.putLights・Render3d.Shadow.putShadow・putSunShadow・Render3d.putDepthRange が uniform へ渡す値と同じ値を、同じ名前の欄へ入れる。
mod Render3d.WebGpuSceneValues {
    import java.nio.ByteBuffer
    use Render3d.LightData
    use Render3d.ScenePlan.ScenePassSpec
    use Render3d.ShadowMaps.ShadowSampling
    use Render3d.UniformLayout.{SceneField, offsetOf}

    /// R3dScene のバイト数。
    pub def sceneValueBytes(): Int32 = Render3d.UniformLayout.bytesOf(Render3d.UniformLayout.sceneFields())

    /// 光と環境マップの値 d を R3dScene の並びで buf へ詰める。影の欄は切る値（影の地図を引く値は packShadowValues・奥行きの書き出しの欄は packPassValues）。
    // WhyNot: 書く欄の組を場面ごとに変えない — buf は場面をまたいで使い回すので、ある場面だけ書いた欄には次の場面で前の値が残る。
    //   ここで書く欄は毎回すべて書き、書かない欄は作った時の 0 のまま読ませる。
    /// o = R3dScene の欄の位置（Render3d.UniformLayout.sceneOffsets を renderer を作る時に 1 回求めた物。毎回求めると欄の表を場面ごとに組み直す）。
    pub def packSceneValues(buf: ByteBuffer, o: Map[SceneField, Int32], d: LightData): Unit \ IO =
        let at = f -> offsetOf(o, f);
        putVec3(buf, at(SceneField.Ambient), d#ambient, 0);
        discard buf.putFloat(at(SceneField.Hemisphere), d#hemisphere);
        putVec3(buf, at(SceneField.Eye), d#eye, 0);
        discard buf.putInt(at(SceneField.ToonSteps), d#toonSteps);
        putVec3(buf, at(SceneField.FogColor), d#fogColor, 0);
        discard buf.putInt(at(SceneField.FogOn), d#fogOn);
        putFloatAt(buf, at(SceneField.FogRange), 0, Array.get(0, d#fogRange));
        putFloatAt(buf, at(SceneField.FogRange), 1, Array.get(1, d#fogRange));
        discard buf.putInt(at(SceneField.PointCount), d#pointCount);
        discard buf.putInt(at(SceneField.SpotCount), d#spotCount);
        putVec3(buf, at(SceneField.SunDir), d#sunDir, 0);
        putVec3(buf, at(SceneField.SunColor), d#sunColor, 0);
        // WhyNot: 太陽の影の fade の幅を 0 のままにしない — 影を切っていて読まれないが、0 で割る式を残さない。
        putFloatAt(buf, at(SceneField.SunFade), 1, 1.0f32);
        putVec3(buf, at(SceneField.Zenith), d#reflectZenith, 0);
        discard buf.putFloat(at(SceneField.Curve), d#reflectCurve);
        putVec3(buf, at(SceneField.Horizon), d#reflectHorizon, 0);
        discard buf.putInt(at(SceneField.EnvOn), d#envOn);
        putVec3(buf, at(SceneField.Ground), d#reflectGround, 0);
        discard buf.putInt(at(SceneField.EnvBoxOn), d#envBoxOn);
        putVec3(buf, at(SceneField.EnvBoxMin), d#envBoxMin, 0);
        discard buf.putFloat(at(SceneField.EnvLevels), d#envLevels);
        putVec3(buf, at(SceneField.EnvBoxMax), d#envBoxMax, 0);
        discard buf.putFloat(at(SceneField.EnvIntensity), d#envIntensity);
        discard buf.putInt(at(SceneField.EnvSrgb), d#envSrgb);
        putVec3(buf, at(SceneField.EnvBoxCenter), d#envBoxCenter, 0);
        discard buf.putInt(at(SceneField.ShadowSpot), -1);
        let p = Scene3d.maxPointLights();
        let sp = Scene3d.maxSpotLights();
        putVec3Array(buf, at(SceneField.PointPos), d#pointPos, p);
        putVec3Array(buf, at(SceneField.PointColor), d#pointColor, p);
        putScalarArray(buf, at(SceneField.PointRange), d#pointRange, 1, p);
        putVec3Array(buf, at(SceneField.SpotPos), d#spotPos, sp);
        putVec3Array(buf, at(SceneField.SpotDir), d#spotDir, sp);
        putVec3Array(buf, at(SceneField.SpotColor), d#spotColor, sp);
        putScalarArray(buf, at(SceneField.SpotRange), d#spotRange, 1, sp);
        putScalarArray(buf, at(SceneField.SpotCone), d#spotCone, 2, sp)

    /// 影の地図を引く値 samplings（スポットと太陽が 1 つずつまで）を R3dScene の並びで buf へ詰める（GL の Render3d.Shadow.putShadow と putSunShadow が渡す欄と同じ値）。
    /// 地図の無い方は on の欄（uShadowOn・uSunShadowOn）を 0 にするだけで、ほかの欄は packSceneValues が書いた切る値か、前の場面の値のまま読まれない。packSceneValues の後に呼ぶ。
    pub def packShadowValues(buf: ByteBuffer, o: Map[SceneField, Int32], samplings: List[ShadowSampling]): Unit \ IO =
        let at = f -> offsetOf(o, f);
        discard buf.putInt(at(SceneField.ShadowOn), 0);
        discard buf.putInt(at(SceneField.SunShadowOn), 0);
        samplings |> List.forEach(sampling -> match sampling {
            case ShadowSampling.Spot(sp) =>
                discard buf.putInt(at(SceneField.ShadowOn), 1);
                discard buf.putInt(at(SceneField.ShadowSpot), sp#spotIndex);
                discard buf.putInt(at(SceneField.ShadowPcf), sp#pcfRadius);
                discard buf.putFloat(at(SceneField.ShadowBias), RenderUtil.f32(sp#bias));
                discard buf.putFloat(at(SceneField.ShadowStrength), RenderUtil.f32(sp#strength));
                putMatrix(buf, at(SceneField.ShadowMatrix), sp#matrix)
            case ShadowSampling.Sun(sun) =>
                discard buf.putInt(at(SceneField.SunShadowOn), 1);
                discard buf.putFloat(at(SceneField.SunNormalShift), RenderUtil.f32(sun#normalShift));
                putFloatAt(buf, at(SceneField.SunForward), 0, RenderUtil.f32(sun#forward#x));
                putFloatAt(buf, at(SceneField.SunForward), 1, RenderUtil.f32(sun#forward#y));
                putFloatAt(buf, at(SceneField.SunForward), 2, RenderUtil.f32(sun#forward#z));
                discard buf.putFloat(at(SceneField.SunBias), RenderUtil.f32(sun#bias));
                putFloatAt(buf, at(SceneField.SunFade), 0, RenderUtil.f32(sun#distance));
                putFloatAt(buf, at(SceneField.SunFade), 1, RenderUtil.f32(sun#fadeWidth));
                discard buf.putInt(at(SceneField.SunPcf), sun#pcfRadius);
                discard buf.putFloat(at(SceneField.SunStrength), RenderUtil.f32(sun#strength));
                putMatrix(buf, at(SceneField.SunMatrix), sun#matrix)
            case ShadowSampling.Point(_) => ()
        })

    /// pass spec の奥行きの書き出しの欄を R3dScene の並びで buf へ詰める: uDepthRange（GL の Render3d.putDepthRange と同じく幅は 0 にしない）と uDepthOut。
    /// 色の pass では uDepthOut が 0 で、uDepthRange は読まれない（0 で割る式を残さないよう幅は 1）。
    pub def packPassValues(buf: ByteBuffer, o: Map[SceneField, Int32], spec: ScenePassSpec): Unit \ IO =
        let (near, range, on) = match spec {
            case ScenePassSpec.Color        => (0.0, 1.0, 0)
            case ScenePassSpec.DepthOut(dr) => (dr#near, Float64.max(0.000001, dr#range), 1)
        };
        putFloatAt(buf, offsetOf(o, SceneField.DepthRange), 0, RenderUtil.f32(near));
        putFloatAt(buf, offsetOf(o, SceneField.DepthRange), 1, RenderUtil.f32(range));
        discard buf.putInt(offsetOf(o, SceneField.DepthOut), on)

    /// 欄の頭 at の component 番目の成分（4 バイト刻み）へ v。
    pub def putFloatAt(buf: ByteBuffer, at: Int32, component: Int32, v: Float32): Unit \ IO =
        discard buf.putFloat(at + 4 * component, v)

    /// 行列 m を列優先 16 個の float で buf の at へ。
    def putMatrix(buf: ByteBuffer, at: Int32, m: Mat4.Mat4): Unit \ IO =
        Mat4.toColumns(m) |> Vector.forEachWithIndex((i, v) -> discard buf.putFloat(at + 4 * i, RenderUtil.f32(v)))

    /// values の i 番目の vec3（3 個ずつ）を buf の at へ。
    pub def putVec3(buf: ByteBuffer, at: Int32, values: Array[Float32, Static], i: Int32): Unit \ IO =
        discard buf.putFloat(at, Array.get(3 * i, values));
        discard buf.putFloat(at + 4, Array.get(3 * i + 1, values));
        discard buf.putFloat(at + 8, Array.get(3 * i + 2, values))

    /// 3 個ずつの values の count 本を、16 バイト刻みの vec4 の配列として at から。
    def putVec3Array(buf: ByteBuffer, at: Int32, values: Array[Float32, Static], count: Int32): Unit \ IO = putVec3sFrom(buf, at, values, 0, count)

    def putVec3sFrom(buf: ByteBuffer, at: Int32, values: Array[Float32, Static], i: Int32, count: Int32): Unit \ IO =
        if (i >= count) ()
        else {
            putVec3(buf, at + 16 * i, values, i);
            putVec3sFrom(buf, at, values, i + 1, count)
        }

    /// width 個ずつの values の count 本を、16 バイト刻みの vec4 の頭の width 個として at から。
    def putScalarArray(buf: ByteBuffer, at: Int32, values: Array[Float32, Static], width: Int32, count: Int32): Unit \ IO =
        putScalarsFrom(buf, at, values, width, 0, count * width)

    def putScalarsFrom(buf: ByteBuffer, at: Int32, values: Array[Float32, Static], width: Int32, k: Int32, n: Int32): Unit \ IO =
        if (k >= n) ()
        else {
            discard buf.putFloat(at + 16 * (k / width) + 4 * Int32.remainder(k, width), Array.get(k, values));
            putScalarsFrom(buf, at, values, width, k + 1, n)
        }
}
