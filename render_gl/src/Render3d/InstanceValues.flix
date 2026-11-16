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
        let world = d#fields#world;
        Mat4.toColumns(world) |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), i, scratch));
        match mode {
            case PackMode.Lit =>
                Mat4.toColumns(Mat4.normalMatrix(world)) |> Vector.forEachWithIndex((i, v) -> if (i < 12) Array.put(RenderUtil.f32(v), 16 + i, scratch) else ());
                Array.put(RenderUtil.f32(emissionIntensityOf(d)), 19, scratch);
                let tint = Texture3d.srgbToLinearColor(d#fields#tint);
                Array.put(RenderUtil.f32(tint#r), 28, scratch);
                Array.put(RenderUtil.f32(tint#g), 29, scratch);
                Array.put(RenderUtil.f32(tint#b), 30, scratch)
            case PackMode.ShadowDepth => ()
        };
        Array.put(Int32.toFloat32(d#poseRow), 23, scratch);
        discard out.put(scratch)

    def emissionIntensityOf(d: MeshDraw): Float64 =
        d#fields#material |> Option.map(m -> Scene3d.materialFieldsOf(m)#emissionIntensity) |> Option.getWithDefault(1.0)
}
