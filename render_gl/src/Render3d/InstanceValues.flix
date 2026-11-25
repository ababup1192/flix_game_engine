// Render3d.InstanceValues — 1 回の prepare の batch に 1 体ごとの値の番号を振り、値を Float の並びへ詰める所（計画の側。GPU を呼ばない）。
// 1 体 = 32 float（RGBA の 8 組）: 0〜3 組 = world の列・4〜6 組 = 法線の行列の列の xyz・7 組 = tint の rgb（線形）。4 組の w = emissionIntensity・5 組の w = 姿勢の行（float で 2^24 まで正確）。
// 番号は prepare（WebGPU は場面）の中の通し番号で、上げるのは backend: GL は RGBA32F の絵（Render3d.GlRows.Instancing・頂点シェーダーが uInstanceBase + gl_InstanceID で引く）・
// WebGPU は instance の頂点の buffer（Render3d.WebGpuRenderer・行の頭の物は draw の firstInstance）。
// WhyNot: pub を外さない — 1 体の長さを GLSL と WGSL の字を作る所（Render3dGlsl・Render3dWgsl。Render3d の外）が読む（親の Render3d が pub でないので、ゲームからは見えない）。
pub mod Render3d.InstanceValues {
    import java.lang.Object
    import java.nio.FloatBuffer
    import java.util.IdentityHashMap
    import java.util.Objects
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
          shadowPlans = plan#shadowPlans |> List.map(s -> { plain = List.map(shadowDepth, s#plain), skinned = List.map(shadowDepth, s#skinned) | s }),
          multis = plan#multis }

    /// plan の batch の描く物の数の合計（multis の体は 1 回だけ数える。影の地図の pass は場面の pass と同じ番号を読む）。
    pub def countOf(plan: ScenePlan[SpanBatch]): Int32 =
        let draws = plan#draws;
        let meshes = (bs: List[SpanBatch]) -> List.sumWith(b -> b#count, bs);
        let materials = (ds: List[MaterialBatch[SpanBatch]]) -> List.sumWith(d -> d#batch#count, ds);
        meshes(draws#plain) + meshes(draws#skinned) + materials(draws#opaque) + materials(draws#blended)
            + List.sumWith(s -> meshes(s#plain) + meshes(s#skinned), plan#shadowPlans)
            + List.sumWith(mp -> MultiMesh3d.countOf(mp#mesh), plan#multis)

    /// mapBatches に、plan#multis を 1 つ 1 本の batch として足した物。場面の pass は材質があれば opaque・無ければ plain の後ろ、影の地図の pass は plain の後ろ。
    /// 群れ全体の境界がどの pass の視錐台にも掛からない物は詰めない。g = 1 つの MultiMesh の並びを詰めて番号を振る関数（numberMultiMesh）。
    // WhyNot: 影の地図の pass ごとに詰め直さない — 1 体の並びは場面の pass と同じ位置に world と姿勢の行を持ち、点光源の影は面 6 つ × 灯りの数だけ詰め直すことになる。
    pub def mapBatchesWithMultiMeshes(f: PackMode -> SpanBatch -> MeshBatch \ ef, g: MultiMesh3d.MultiMesh3d -> MeshBatch \ ef,
                                      plan: ScenePlan[SpanBatch]): ScenePlan[MeshBatch] \ ef =
        let mapped = mapBatches(f, plan);
        if (List.isEmpty(plan#multis)) mapped
        else {
            let sceneFrustum = Scene3d.frustumOf(plan#cmd#scene);
            let numbered = plan#multis |> List.map(mp -> {
                let lit = Render3d.MultiMeshPlan.isVisibleIn(sceneFrustum, mp#mesh);
                let shadows = mapped#shadowPlans |> List.map(sp -> Render3d.MultiMeshPlan.isVisibleIn(sp#caster#frustum, mp#mesh));
                let batch = if (lit or List.exists(identity, shadows)) Some(g(mp#mesh)) else None;
                (mp, lit, shadows, batch)
            });
            let litOf = (want: Bool) -> numbered |> List.filterMap(match (mp, lit, _, batch) ->
                if (lit and Option.nonEmpty(mp#material) == want) batch |> Option.map(b -> (mp, b)) else None);
            let plain = litOf(false) |> List.map(snd);
            let opaque = litOf(true) |> List.filterMap(match (mp, b) ->
                mp#material |> Option.map(match (handle, order, kind, m) -> { handle = handle, order = order, kind = kind, material = m, batch = b }));
            let draws = mapped#draws;
            let shadowPlans = mapped#shadowPlans |> List.mapWithIndex((k, sp) -> {
                let extra = numbered |> List.filterMap(match (_, _, shadows, batch) -> if (List.nth(k, shadows) == Some(true)) batch else None);
                { plain = List.append(sp#plain, extra) | sp }
            });
            { draws = { plain = List.append(draws#plain, plain), opaque = List.append(draws#opaque, opaque) | draws }, shadowPlans = shadowPlans | mapped }
        }

    /// MultiMesh mm の体を next の番号から out へ詰め、番号を振った batch を返す（頭は形を原点に置いた 1 体）。capacity を超える体は詰めない。
    /// carry と gen = 続けて描く値の詰めた並びの控えと、今のコマの世代（packOrCarry）。
    pub def numberMultiMesh(out: FloatBuffer, scratch: Array[Float32, Static], capacity: Int32, next: Array[Int32, Static], carry: MultiCarry, gen: Int64,
                            mm: MultiMesh3d.MultiMesh3d): MeshBatch \ IO =
        let r = MultiMesh3d.fieldsOf(mm);
        let first = Array.get(0, next);
        let count = Int32.max(0, Int32.min(MultiMesh3d.countOf(mm), capacity - first));
        let emission = r#material |> Option.map(m -> Scene3d.materialFieldsOf(m)#emissionIntensity) |> Option.getWithDefault(1.0);
        Array.put(1.0f32, 15, scratch);
        Array.put(RenderUtil.f32(emission), 19, scratch);
        Array.put(0.0f32, 23, scratch);
        Array.put(0.0f32, 27, scratch);
        packOrCarry(out, scratch, carry, gen, mm, count);
        Array.put(first + count, 0, next);
        let head = { fields = Scene3d.instanceFieldsOf(MultiMesh3d.headOf(mm)), pose = None, poseRow = 0, culled = false };
        { head = head, count = count, first = first }

    // ── 同じ MultiMesh の値を続けて描くコマで、詰めた並びを持ち越す ──

    /// 前のコマと今のコマに詰めた MultiMesh の値（参照）→ 詰めた並び（一度だけ見た物は長さ 0 の印）。frame = maps[0] のコマの世代・
    /// free = 使い終えた控えの並び（次の控えに使い回す）。
    pub type alias MultiCarry = { frame = Array[Int64, Static], maps = Array[IdentityHashMap[Object, Object], Static], free = Ref[List[Array[Float32, Static]], Static] }

    pub def freshMultiCarry(): MultiCarry \ IO =
        { frame = Array#{-1i64} @ Static, maps = Array#{new IdentityHashMap(), new IdentityHashMap()} @ Static, free = Ref.fresh(Static, Nil) }

    // 同じ値（参照）を 2 コマ続けて見たら、2 コマ目に out へ詰めた所を控えに写し、3 コマ目からは控えを写すだけにする。1 度しか見ない値（毎コマ作る群れ）は控えない。
    // WhyNot: 初めて見た値から並びを控えない — 毎コマ作り直す群れで、使わない写しを毎コマ作ることになる。
    // WhyNot: 2 コマ目に控えへ詰め直さない・控えを毎回作らない — 刻みより速い画面（120 Hz と刻み 60）では World の値がちょうど 2 コマずつ同じ参照で来るので、
    //   控えは一度も使われず、詰め直しと 1 万体で 1.28 MB の確保だけが毎回乗る。控えは out からの写しにし、並びは使い終えた控えから使い回す。
    // WhyNot: 中身で比べない — MultiMesh3d は作った後に変わらない値なので、参照が同じなら中身も同じ。中身の比べは詰めるのと同じ代金になる。
    def packOrCarry(out: FloatBuffer, scratch: Array[Float32, Static], carry: MultiCarry, gen: Int64, mm: MultiMesh3d.MultiMesh3d, count: Int32): Unit \ IO =
        if (Array.get(0, carry#frame) != gen) rotateCarry(carry, gen) else ();
        let key = unchecked_cast(mm as Object);
        let now = Array.get(0, carry#maps);
        let held = now.get(key);
        let found = if (Objects.isNull(held)) Array.get(1, carry#maps).get(key) else held;
        let r = MultiMesh3d.fieldsOf(mm);
        let floats = count * floatsPerInstance();
        if (Objects.isNull(found)) {
            packMultiFrom(out, scratch, r#transforms, r#colors, 0, count);
            discard now.put(key, unchecked_cast((Array.empty(Static, 0): Array[Float32, Static]) as Object))
        } else {
            let data: Array[Float32, Static] = unchecked_cast(found as Array[Float32, Static]);
            if (Array.length(data) >= floats) {
                discard out.put(data, 0, floats);
                discard now.put(key, found)
            } else {
                let start = out.position();
                packMultiFrom(out, scratch, r#transforms, r#colors, 0, count);
                let kept = takeFree(carry, floats);
                let view = out.duplicate();
                discard view.position(start);
                discard view.get(kept, 0, floats);
                discard now.put(key, unchecked_cast(kept as Object))
            }
        };
        ()

    // 前の前のコマの表を捨て、そこにしか無い控えの並びを free へ戻す。
    def rotateCarry(carry: MultiCarry, gen: Int64): Unit \ IO =
        let dropped = Array.get(1, carry#maps);
        let kept = Array.get(0, carry#maps);
        dropped.values().toArray() |> Array.forEach(v -> {
            let data: Array[Float32, Static] = unchecked_cast(v as Array[Float32, Static]);
            if (Array.length(data) > 0 and not kept.containsValue(v)) Ref.put(data :: Ref.get(carry#free), carry#free) else ()
        });
        Array.put(kept, 1, carry#maps);
        Array.put(new IdentityHashMap(), 0, carry#maps);
        Array.put(gen, 0, carry#frame)

    // floats 個以上の並びを free から取る（無ければ作る）。
    def takeFree(carry: MultiCarry, floats: Int32): Array[Float32, Static] \ IO =
        let (fits, rest) = List.partition(a -> Array.length(a) >= floats, Ref.get(carry#free));
        match fits {
            case a :: others =>
                Ref.put(others ::: rest, carry#free);
                a
            case Nil => Array.empty(Static, floats)
        }

    def packMultiFrom(out: FloatBuffer, scratch: Array[Float32, Static], t: Vector[Float64], colors: Option[Vector[Float64]], i: Int32, end: Int32): Unit \ IO =
        if (i >= end) ()
        else {
            packMultiOne(out, scratch, t, colors, i);
            packMultiFrom(out, scratch, t, colors, i + 1, end)
        }

    // 1 体の 3×4（行優先）を、packDraw と同じ 32 個の並び（world の列・法線の行列の列・tint）にする。15・19・23・27 は numberMultiMesh が先に置く。
    // WhyNot: 末尾を呼び出しで終えない — 物の数だけ回る packMultiFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def packMultiOne(out: FloatBuffer, scratch: Array[Float32, Static], t: Vector[Float64], colors: Option[Vector[Float64]], i: Int32): Unit \ IO =
        let o = i * 12;
        let put = (k: Int32, at: Int32) -> Array.put(Float64.truncateToFloat32(Vector.get(o + at, t)), k, scratch);
        put(0, 0); put(1, 4); put(2, 8); Array.put(0.0f32, 3, scratch);
        put(4, 1); put(5, 5); put(6, 9); Array.put(0.0f32, 7, scratch);
        put(8, 2); put(9, 6); put(10, 10); Array.put(0.0f32, 11, scratch);
        put(12, 3); put(13, 7); put(14, 11);
        putNormalFrom(t, o, scratch);
        putTint(MultiMesh3d.colorAt(colors, i), scratch);
        discard out.put(scratch);
        ()

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
                putNormalFrom(m, 0, scratch);
                Array.put(0.0f32, 19, scratch);
                Array.put(0.0f32, 23, scratch);
                Array.put(0.0f32, 27, scratch);
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

    // 行優先の m の o から 3 行（4 つおき）の左上 3×3 で、Mat4.normalMatrix の列優先の xyz を scratch[16..26] へ（w の所 19・23・27 は書かない）。
    // 式と足す順は Mat4.normalMatrix と同じ（丸めを変えない）。packDraw（Mat4 の 16 個）と packMultiOne（3×4 の 12 個）が同じ並びの位置で使う。
    def putNormalFrom(m: Vector[Float64], o: Int32, scratch: Array[Float32, Static]): Unit \ IO =
        let at = (i: Int32) -> Vector.get(o + i, m);
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
        put(16, c00 * s); put(17, c10 * s); put(18, c20 * s);
        put(20, c01 * s); put(21, c11 * s); put(22, c21 * s);
        put(24, c02 * s); put(25, c12 * s); put(26, c22 * s)

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
