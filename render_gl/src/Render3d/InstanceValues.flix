// Render3d.InstanceValues — 1 回の prepare の batch に 1 体ごとの値の番号を振り、値を Float の並びへ詰める所（計画の側。GPU を呼ばない）。
// 1 体 = 32 float（RGBA の 8 組）: 0〜3 組 = world の列・4〜6 組 = 法線の行列の列の xyz・7 組 = tint の rgb（線形）。4 組の w = emissionIntensity・5 組の w = 姿勢の行（float で 2^24 まで正確）。
// 番号は prepare（WebGPU は場面）の中の通し番号で、上げるのは backend: GL は RGBA32F の絵（Render3d.GlRows.Instancing・頂点シェーダーが uInstanceBase + gl_InstanceID で引く）・
// WebGPU は instance の頂点の buffer（Render3d.WebGpuRenderer・行の頭の物は draw の firstInstance）。
// WhyNot: pub を外さない — 1 体の長さを GLSL と WGSL の字を作る所（Render3dGlsl・Render3dWgsl。Render3d の外）が読む（親の Render3d が pub でないので、ゲームからは見えない）。
pub mod Render3d.InstanceValues {
    import java.nio.FloatBuffer
    use Render3d.{MeshDraw}
    use Render3d.Batch.{MaterialBatch, MeshBatch, PlannedBatch, SpanBatch}
    use Render3d.ScenePlan.{ScenePlan}

    /// 1 体の RGBA の組の数（GL の絵の texel の数・WGSL の頂点の属性の数）。
    pub def texelsPerInstance(): Int32 = 8

    /// 1 体の float の数。
    pub def floatsPerInstance(): Int32 = 4 * texelsPerInstance()

    /// 値をどこまで詰めるか。Lit = 全部・ShadowDepth = world と姿勢の行だけ（影の地図は法線と色を使わない）。
    pub enum PackMode {
        case Lit
        case ShadowDepth
    }

    /// plan の全部の batch へ f を当てる（色・深度の場面の batch の後にその場面の影の batch）。
    pub def mapBatches(f: PackMode -> SpanBatch -> MeshBatch \ ef, plan: ScenePlan[SpanBatch]): ScenePlan[MeshBatch] \ ef =
        let lit = f(PackMode.Lit);
        let shadowDepth = f(PackMode.ShadowDepth);
        let material = d -> { handle = d#handle, order = d#order, kind = d#kind, material = d#material, batch = lit(d#batch) };
        let draws = plan#draws;
        { cmd = plan#cmd, mainPass = plan#mainPass,
          draws = { plain = List.map(lit, draws#plain), skinned = List.map(lit, draws#skinned),
                    opaque = List.map(material, draws#opaque), blended = List.map(material, draws#blended), billboards = draws#billboards },
          shadowPlans = plan#shadowPlans |> List.map(s -> { plain = List.map(shadowDepth, s#plain), skinned = List.map(shadowDepth, s#skinned) | s }) }

    /// plan の batch の描く物の数の合計。
    pub def countOf(plan: ScenePlan[SpanBatch]): Int32 =
        let draws = plan#draws;
        let meshes = (bs: List[SpanBatch]) -> List.sumWith(b -> b#count, bs);
        let materials = (ds: List[MaterialBatch[SpanBatch]]) -> List.sumWith(d -> d#batch#count, ds);
        meshes(draws#plain) + meshes(draws#skinned) + materials(draws#opaque) + materials(draws#blended)
            + List.sumWith(s -> meshes(s#plain) + meshes(s#skinned), plan#shadowPlans)

    /// numberBatch の、描く物を members の [b#start, b#start + b#count) で受ける形。
    pub def numberSpan(out: FloatBuffer, scratch: Array[Float32, Static], capacity: Int32, next: Array[Int32, Static], members: MutList[MeshDraw, Static],
                   mode: PackMode, b: SpanBatch): MeshBatch \ IO =
        let first = Array.get(0, next);
        let count = Int32.max(0, Int32.min(b#count, capacity - first));
        packFrom(out, scratch, mode, members, b#start, b#start + count);
        Array.put(first + count, 0, next);
        { head = b#head, count = count, first = first }

    def packFrom(out: FloatBuffer, scratch: Array[Float32, Static], mode: PackMode, members: MutList[MeshDraw, Static], i: Int32, end: Int32): Unit \ IO =
        if (i >= end) ()
        else {
            packDraw(out, scratch, mode, MutList.get(i, members));
            packFrom(out, scratch, mode, members, i + 1, end)
        }

    /// next の番号から b の物の値を out へ詰め、番号を振った b を返す。capacity を超える物は詰めない。
    // WhyNot: 本番（numberSpan）から呼ばない・消さない — 描く物を列で持つ素直な形を、上限で止まる決まりの答え合わせの相手（TestRender3dBatch）として残す。
    pub def numberBatch(out: FloatBuffer, scratch: Array[Float32, Static], capacity: Int32, next: Array[Int32, Static], mode: PackMode, b: PlannedBatch): MeshBatch \ IO =
        let first = Array.get(0, next);
        let count = Int32.max(0, Int32.min(b#count, capacity - first));
        (if (count == b#count) b#draws else List.take(count, b#draws)) |> List.forEach(packDraw(out, scratch, mode));
        Array.put(first + count, 0, next);
        { head = b#head, count = count, first = first }

    /// d の 1 体ごとの値を scratch（1 体の長さ）へ組み、out の今の位置へ 1 回で詰める。ShadowDepth は法線と tint の所へ前の物の値を残す。
    pub def packDraw(out: FloatBuffer, scratch: Array[Float32, Static], mode: PackMode, d: MeshDraw): Unit \ IO =
        let fields = d#fields;
        let m = Mat4.asRows(fields#world);
        putColumns(m, scratch, 0);
        match mode {
            case PackMode.Lit =>
                putNormalColumns(m, scratch);
                Array.put(RenderUtil.f32(emissionIntensityOf(d)), 19, scratch);
                putTint(fields#tint, scratch)
            case PackMode.ShadowDepth => ()
        };
        Array.put(Int32.toFloat32(d#poseRow), 23, scratch);
        discard out.put(scratch)

    // 行優先の m を列優先で scratch[0..15] へ（Mat4.toColumns と同じ並び）。
    // WhyNot: Mat4.toColumns を通さない — 1 体ごとに 16 個の Vector を作り、物が万を超える場面で確保と GC が 1 コマの何割にもなる。
    def putColumns(m: Vector[Float64], scratch: Array[Float32, Static], base: Int32): Unit \ IO =
        let put = (k: Int32, i: Int32) -> Array.put(Float64.truncateToFloat32(Vector.get(i, m)), base + k, scratch);
        put(0, 0); put(1, 4); put(2, 8); put(3, 12);
        put(4, 1); put(5, 5); put(6, 9); put(7, 13);
        put(8, 2); put(9, 6); put(10, 10); put(11, 14);
        put(12, 3); put(13, 7); put(14, 11); put(15, 15)

    // Mat4.normalMatrix の列優先の 12 個（w の所は 0）を scratch[16..27] へ。式と足す順は Mat4.normalMatrix と同じ（丸めを変えない）。
    def putNormalColumns(m: Vector[Float64], scratch: Array[Float32, Static]): Unit \ IO =
        let at = (i: Int32) -> Vector.get(i, m);
        let a = at(0); let b = at(1); let c = at(2);
        let d = at(4); let e = at(5); let f = at(6);
        let g = at(8); let h = at(9); let i = at(10);
        let c00 = e * i - f * h;
        let c01 = f * g - d * i;
        let c02 = d * h - e * g;
        let c10 = c * h - b * i;
        let c11 = a * i - c * g;
        let c12 = b * g - a * h;
        let c20 = b * f - c * e;
        let c21 = c * d - a * f;
        let c22 = a * e - b * d;
        let det = a * c00 + b * c01 + c * c02;
        let s = if (Float64.abs(det) < 1.0e-12) 1.0 else 1.0 / det;
        let put = (k: Int32, v: Float64) -> Array.put(RenderUtil.f32(v), k, scratch);
        put(16, c00 * s); put(17, c10 * s); put(18, c20 * s); put(19, 0.0);
        put(20, c01 * s); put(21, c11 * s); put(22, c21 * s); put(23, 0.0);
        put(24, c02 * s); put(25, c12 * s); put(26, c22 * s); put(27, 0.0)

    // WhyNot: 白の tint で pow を回さない — 物の多くは白のままで、srgbToLinear(1) は 1 ちょうど。
    def putTint(c: Color, scratch: Array[Float32, Static]): Unit \ IO =
        if (c#r == 1.0 and c#g == 1.0 and c#b == 1.0) {
            Array.put(1.0f32, 28, scratch);
            Array.put(1.0f32, 29, scratch);
            Array.put(1.0f32, 30, scratch)
        } else {
            let tint = Texture3d.srgbToLinearColor(c);
            Array.put(RenderUtil.f32(tint#r), 28, scratch);
            Array.put(RenderUtil.f32(tint#g), 29, scratch);
            Array.put(RenderUtil.f32(tint#b), 30, scratch)
        }

    def emissionIntensityOf(d: MeshDraw): Float64 =
        d#fields#material |> Option.map(m -> Scene3d.materialFieldsOf(m)#emissionIntensity) |> Option.getWithDefault(1.0)
}
