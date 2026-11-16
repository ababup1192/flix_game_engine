// Render3d.WebGpuStatic — 動かない物の集まりの持ち越した行（Render3d.StaticRows）を GPU に置いて毎コマ描く所（WebGPU の backend）。
// 集まりごとに 1 体ごとの値の buffer と材質の値の buffer を 1 回だけ作って書き、毎コマは形と絵を使った物にして、時刻が変わった値の区画だけ書き直す。
// 描くのは場面の色の pass の空の後・場面の行の前（場面の行の頭は不透明の行なので、半透明の行は持ち越した物より後に重なる）と、場面の影の地図の pass。
// WhyNot: 持ち越した buffer を作り直す時にその場で destroy しない — 同じ encoder の前の場面がまだ submit していない pass でその buffer を読んでいる。submit の後に手放す。
mod Render3d.WebGpuStatic {
    import fge.webgpu.Buffer
    import fge.webgpu.BufferUsage
    import fge.webgpu.RenderPass
    import fge.webgpu.Texture
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.{TextureSource}
    use Render3d.MeshTable
    use Render3d.ScenePlan.{Planner}
    use Render3d.SceneList.{SceneList, flagSameBinding, hasFlag, kindMaterial, rowAt, rowCountOf, valuesAt}
    use Render3d.StaticRows
    use Render3d.StaticRows.{CarriedRows}
    use Render3d.WebGpuMaterials
    use Render3d.WebGpuRows.{uploadRows}

    /// 持ち越した集まり 1 つを GPU に置いた物。rows = 前半の行・programs = 行の欄 1 が引く材質の program・instances = 1 体ごとの値の buffer（頭から）・
    /// values = 材質の値の buffer（rows#list#values を頭から）・textureRows = 毎コマ材質の絵を使った物にする行（値を分け合わない材質の行）。
    pub type alias Carried = {
        rows = CarriedRows, programs = Vector[Option[WebGpuMaterials.Program]], instances = Buffer, values = Buffer, textureRows = Vector[Int32]
    }

    /// 状態。cache = 集まりの持ち越しの控え・retired = submit の後に手放す buffer。
    pub type alias Statics = { cache = StaticRows.Cache[Carried], retired = Ref[List[Buffer], Static] }

    pub def fresh(): Statics \ IO = { cache = StaticRows.freshCache(), retired = Ref.fresh(Static, Nil) }

    /// 集まりの行を作る材料（どれも 3D の描き手の持ち物）。tables = 前半の行の番号を振る表・allocator = 形を作る関数の組・
    /// noteBuild = 材質の program を初めて組んだ知らせ・gen = 今のコマの世代。
    pub type alias Builder = {
        gpu = WebGpu, planner = Planner, materials = WebGpuMaterials.Materials, tables = Render3d.SceneList.Tables, allocator = MeshTable.MeshAllocator,
        noteBuild = String -> Unit \ IO
    }

    /// この数のコマ描かなかった集まりの持ち越しは手放す（描き先の Render3d.WebGpuRenderer の idleTargetFrames と同じ）。
    def idleFrames(): Int64 = 128i64

    /// 場面 scene の持ち越す集まりの物（色の場面だけ・同じ集まりが続くコマは作らずに前の物）。
    pub def carriedOf(st: Statics, b: Builder, scene: Scene3d.Scene3dCmd): List[Carried] \ IO =
        StaticRows.carriedGroupsOf(scene) |> List.map(g -> StaticRows.lookup(b#planner, st#cache, b#tables#gen, g, () -> build(b, scene, g), retire(st)))

    def build(b: Builder, scene: Scene3d.Scene3dCmd, g: Scene3d.StaticGroup): Carried \ IO =
        let programs = Ref.fresh(Static, Vector.empty());
        let resolve = (requests: Vector[Render3d.ScenePlan.MaterialRequest]) -> {
            let found = WebGpuMaterials.programsFor(b#materials, b#noteBuild, requests);
            Ref.put(found, programs);
            WebGpuMaterials.ordersOf(found)
        };
        let rows = StaticRows.build(b#planner, b#tables, resolve, scene, g);
        uploadRows(b#tables#meshes, b#allocator, b#tables#gen, rows#list);
        uploadRows(b#tables#meshes, b#allocator, b#tables#gen, rows#shadowList);
        let instanceBytes = rows#instanceCount * Render3dWgsl.instanceBytes();
        let instances = b#gpu.createBuffer("fge scene3d static instances", Int32.toInt64(Int32.max(Render3dWgsl.instanceBytes(), instanceBytes)),
                                           Int32.bitwiseOr(BufferUsage.VERTEX, BufferUsage.COPY_DST));
        if (instanceBytes > 0) b#gpu.writeBuffer(instances, 0i64, rows#instances, 0, instanceBytes) else ();
        { rows = rows, programs = Ref.get(programs), instances = instances, values = WebGpuMaterials.createValuesOf(b#materials, "fge scene3d static values", rows#list#values),
          textureRows = ownBindingRows(rows#list) }

    /// 値を前の行と分け合わない材質の行（材質の絵を作り、使った物にする行）。
    def ownBindingRows(list: SceneList): Vector[Int32] \ IO =
        Vector.range(0, rowCountOf(list)) |> Vector.filter(row ->
            rowAt(list, row, 0) == kindMaterial() and valuesAt(list, row) >= 0 and not hasFlag(list, row, flagSameBinding()))

    def retire(st: Statics): Carried -> Unit \ IO = c -> Ref.put(c#instances :: c#values :: Ref.get(st#retired), st#retired)

    /// 場面を描く前に持ち越した物 c を今のコマで使った物にする: 形と材質の絵を今の世代にし（絵は無ければ作る）、場面の時刻 time が変わっていれば値の区画の uTime を書き直す。
    // WhyNot: 同じ集まりを時刻の違う 2 つの場面で描く時に場面ごとに値を分けない — 書いた値は submit の前に効くので、後の場面の時刻で両方を描く。材質の時刻が絵に効く集まりは場面ごとに別の集まりにする。
    pub def stage(gpu: WebGpu, materials: WebGpuMaterials.Materials, source: TextureSource, textureById: Int32 -> Option[Texture] \ IO, gen: Int64, time: Float64, c: Carried): Unit \ IO =
        MeshTable.touchSlots(c#rows#meshSlots, gen);
        WebGpuMaterials.uploadTexturesAt(materials, source, textureById, gen, c#rows#list, c#textureRows);
        if (StaticRows.retime(c#rows, time)) {
            let one = ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN);
            discard one.putFloat(0, RenderUtil.f32(time));
            c#rows#timeAt |> Vector.forEach(at -> gpu.writeBuffer(c#values, Int32.toInt64(4 * at), one, 0, 4))
        } else ()

    /// 2D の描き手が encoder を submit した後に呼ぶ（作り直した集まりの古い buffer を手放す）。
    pub def afterSubmit(st: Statics): Unit \ IO =
        Ref.get(st#retired) |> List.forEach(b -> b.destroy());
        Ref.put(Nil, st#retired)

    /// 画面のコマの終わりに呼ぶ。evicted = 形か材質の絵の置き場がこのコマに何かを捨てた（持ち越した行の番号が別の物を指しうるので全部を作り直す）。
    /// そうでなければ、しばらく描かなかった集まりを手放す。
    pub def endFrame(st: Statics, gen: Int64, evicted: Bool): Unit \ IO =
        if (evicted) StaticRows.clear(st#cache, retire(st))
        else StaticRows.sweep(st#cache, gen, idleFrames(), retire(st))

    /// 全部を手放す（描き手を手放す時。encoder は submit 済み）。
    pub def release(st: Statics): Unit \ IO =
        StaticRows.clear(st#cache, retire(st));
        afterSubmit(st)

    /// 持ち越した物 c の色の pass の行を pass に描く。drawRowsWith(行, 1 体ごとの値の buffer, 材質の値の buffer, program) = 呼ぶ側の行の流し方（pipeline と group の付け方）。
    pub def draw(drawRowsWith: (SceneList, Buffer, Buffer, Vector[Option[WebGpuMaterials.Program]]) -> Unit \ IO, c: Carried): Unit \ IO =
        drawRowsWith(c#rows#list, c#instances, c#values, c#programs)

    /// 持ち越した物 c の影の地図の行と、その 1 体ごとの値の buffer。
    pub def shadowRowsOf(c: Carried): (SceneList, Buffer) = (c#rows#shadowList, c#instances)
}
