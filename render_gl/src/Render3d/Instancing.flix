// Render3d.Instancing — 3D の描き手（Render3d）の、1 回の prepare の全部の batch の 1 体ごとの値を 1 枚の RGBA32F のテクスチャへ詰めて上げる所。
// 1 体 = 横に 8 texel: 0〜3 = world の列・4〜6 = 法線の行列の列の xyz・7 = tint の rgb（線形）。4 の w = emissionIntensity・5 の w = joint texture の行（float で 2^24 まで正確）。
// 番号は prepare の中の通し番号で、頂点シェーダーは uInstanceBase + gl_InstanceID で引く（Render3dGlsl.instanceDeclarations）。テクスチャの回し方は Render3d.DataTexture。約束は Render3d.flix の頭。
// WhyNot: 頂点の属性に置かない — batch にならない draw ごとに 8 本の属性を指し直すことになり、WebGL2 では submit が 3 倍を超える。location の 16 個も使い切る。
mod Render3d.Instancing {
    import fge.gl.GlConst
    import fge.gl.GlContext
    import java.nio.FloatBuffer
    use Render3d.{MeshDraw, State, instanceTextureUnit, warnSceneOnce}
    use Render3d.Batch.{MaterialBatch, MeshBatch, PlannedBatch}
    use Render3d.DataTexture.{bufferFor, heightFor, rowLimit, takeTexture, textureWidth}
    use Render3dGlsl.{instancesPerRow, texelsPerInstance}
    use Render3d.ScenePlan.{ScenePlan}

    /// count 体を入れる行の数。
    pub def rowsFor(count: Int32): Int32 =
        (count + instancesPerRow() - 1) / instancesPerRow()

    /// 値をどこまで詰めるか。Lit = 全部・ShadowDepth = world と姿勢の行だけ（影の地図は法線と色を使わない）。
    pub enum PackMode {
        case Lit
        case ShadowDepth
    }

    /// plan の全部の batch へ f を当てる（色・深度の場面の batch の後にその場面の影の batch）。
    def mapBatches(f: PackMode -> PlannedBatch -> MeshBatch \ ef, plan: ScenePlan[PlannedBatch]): ScenePlan[MeshBatch] \ ef =
        let lit = f(PackMode.Lit);
        let shadowDepth = f(PackMode.ShadowDepth);
        let material = d -> { entry = d#entry, material = d#material, batch = lit(d#batch) };
        let draws = plan#draws;
        { cmd = plan#cmd,
          draws = { plain = List.map(lit, draws#plain), skinned = List.map(lit, draws#skinned),
                    opaque = List.map(material, draws#opaque), blended = List.map(material, draws#blended) },
          shadowPlan = plan#shadowPlan |> Option.map(s -> { caster = s#caster, plain = List.map(shadowDepth, s#plain), skinned = List.map(shadowDepth, s#skinned) }) }

    /// plan の batch の描く物の数の合計。
    def countOf(plan: ScenePlan[PlannedBatch]): Int32 =
        let draws = plan#draws;
        let meshes = (bs: List[PlannedBatch]) -> List.sumWith(b -> b#count, bs);
        let materials = (ds: List[MaterialBatch[PlannedBatch]]) -> List.sumWith(d -> d#batch#count, ds);
        meshes(draws#plain) + meshes(draws#skinned) + materials(draws#opaque) + materials(draws#blended)
            + (plan#shadowPlan |> Option.map(s -> meshes(s#plain) + meshes(s#skinned)) |> Option.getWithDefault(0))

    /// 今の prepare の全部の batch に番号を振り、1 体ごとの値をテクスチャへ 1 回で上げて、振り終えた plans とテクスチャの番号を返す。描く物が無ければテクスチャを作らず None。
    /// テクスチャに入り切らない batch の物は描かない（1 回知らせる）。
    pub def upload(gl: GlContext, state: State, gen: Int64, plans: List[ScenePlan[PlannedBatch]]): (List[ScenePlan[MeshBatch]], Option[Int32]) \ IO =
        let total = List.sumWith(countOf, plans);
        if (total == 0) (plans |> List.map(mapBatches(_ -> b -> { head = b#head, count = 0, first = 0 })), None)
        else {
            let limit = rowLimit(gl, state#instances);
            let capacity = limit * instancesPerRow();
            if (total > capacity)
                warnSceneOnce(state, "@instance-rows", Log.fellBackLine("scene3d", "1 回の prepare の描く物", "入り切らない物を描かない", "${capacity} 体を超えた（${total} 体）"))
            else ();
            let kept = Int32.min(total, capacity);
            let rows = rowsFor(kept);
            let width = if (rows == 1) kept * texelsPerInstance() else textureWidth();
            let out = bufferFor(gl, state#instances, rows * textureWidth() * 4);
            discard out.clear();
            let scratch = Array.repeat(Static, texelsPerInstance() * 4, 0.0f32);
            let next = Array#{0} @ Static;
            let numbered = plans |> List.map(mapBatches(numberBatch(out, scratch, capacity, next)));
            discard out.position(0);
            discard out.limit(rows * width * 4);
            gl.activeTexture(GlConst.TEXTURE0 + instanceTextureUnit());
            let texture = takeTexture(gl, state#instances, gen, heightFor(limit, rows));
            gl.texSubImageRgba32f(0, 0, width, rows, out);
            gl.activeTexture(GlConst.TEXTURE0);
            (numbered, Some(texture#texId))
        }

    /// next の番号から b の物の値を out へ詰め、番号を振った b を返す。capacity を超える物は詰めない。
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
