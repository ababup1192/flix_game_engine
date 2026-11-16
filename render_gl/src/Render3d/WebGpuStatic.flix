// Render3d.WebGpuStatic — 動かない物の集まりの持ち越した行（Render3d.StaticRows）を GPU に置いて毎コマ描く所（WebGPU の backend）。
// 集まりごとに 1 体ごとの値の buffer と材質の値の buffer を 1 回だけ作って書き、毎コマは形と絵を使った物にして、時刻が変わった値の区画だけ書き直す。
// 描くのは場面の色の pass の空の後・場面の行の前（場面の行の頭は不透明の行なので、半透明の行は持ち越した物より後に重なる）と、場面の影の地図の pass。
// 行は描き先の形式・標本・pass ごとの render bundle に 1 回だけ積み、毎コマはその bundle を流す（runBundle）。group 0 か材質の絵が替わったら積み直す。
// WhyNot: 持ち越した buffer を作り直す時にその場で destroy しない — 同じ encoder の前の場面がまだ submit していない pass でその buffer を読んでいる。submit の後に手放す。
mod Render3d.WebGpuStatic {
    import fge.webgpu.BindGroup
    import fge.webgpu.Buffer
    import fge.webgpu.BufferUsage
    import fge.webgpu.RenderBundle
    import fge.webgpu.RenderCommands
    import fge.webgpu.RenderPass
    import fge.webgpu.TextureFormat
    import fge.webgpu.WebGpu
    import java.lang.Object
    import java.util.Objects
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
    /// values = 材質の値の buffer（rows#list#values を頭から）・textureRows = 毎コマ材質の絵を使った物にする行（値を分け合わない材質の行）・
    /// bundles = 積んだ bundle（鍵 = 描き先の形式・標本・pass の字）・litTally と shadowTally = 色の pass の行と影の地図の行の診断の数（作った時に 1 回数える）。
    pub type alias Carried = {
        rows = CarriedRows, programs = Vector[Option[WebGpuMaterials.Program]], instances = Buffer, values = Buffer, textureRows = Vector[Int32],
        bundles = Ref[Map[String, Bundle], Static], litTally = Tally, shadowTally = Tally
    }

    /// 行の診断の数。counts = Render3d.Counts の入れ物と同じ並びの足す数・drawn = 描く物の数。
    // WhyNot: 毎コマ行を数え直さない — 持ち越した行は物の数だけあり、数え直しが持ち越しで省いた仕事と同じ重さになる。
    pub type alias Tally = { counts = Array[Int32, Static], drawn = Int32 }

    def tallyOf(list: SceneList): Tally \ IO =
        let holder = { countsHolder = Array.repeat(Static, Render3d.Counts.counterSlots(), 0) };
        let drawn = Render3d.WebGpuRows.countRowsOf(holder, list);
        { counts = holder#countsHolder, drawn = drawn }

    /// t の数を state の入れ物へ足す。
    pub def addTally(state: { countsHolder = Array[Int32, Static] | r }, t: Tally): Unit \ IO =
        Array.forEachWithIndex((i, n) -> if (n == 0) () else Array.put(Array.get(i, state#countsHolder) + n, i, state#countsHolder), t#counts)

    /// 積んだ bundle 1 つ。group = 積んだ時の group 0（参照で比べる）・epoch = 積んだ時の材質の絵の世代（WebGpuMaterials.textureEpochOf）・
    /// groups = 積んだ行の group 1（bundle と一緒に手放す）。
    pub type alias Bundle = { bundle = RenderBundle, group = BindGroup, epoch = Int64, groups = List[BindGroup] }

    /// 状態。cache = 集まりの持ち越しの控え・retired = submit の後に手放す物。
    pub type alias Statics = { cache = StaticRows.Cache[Carried], retired = Ref[List[Unit -> Unit \ IO], Static] }

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
          textureRows = ownBindingRows(rows#list), bundles = Ref.fresh(Static, Map.empty()), litTally = tallyOf(rows#list), shadowTally = tallyOf(rows#shadowList) }

    /// 値を前の行と分け合わない材質の行（材質の絵を作り、使った物にする行）。
    def ownBindingRows(list: SceneList): Vector[Int32] \ IO =
        Vector.range(0, rowCountOf(list)) |> Vector.filter(row ->
            rowAt(list, row, 0) == kindMaterial() and valuesAt(list, row) >= 0 and not hasFlag(list, row, flagSameBinding()))

    def retire(st: Statics): Carried -> Unit \ IO = c -> {
        Map.forEach((_, b) -> retireBundle(st, b), Ref.get(c#bundles));
        Ref.put((() -> { c#instances.destroy(); c#values.destroy() }) :: Ref.get(st#retired), st#retired)
    }

    def retireBundle(st: Statics, b: Bundle): Unit \ IO =
        Ref.put((() -> { b#bundle.release(); List.forEach(g -> g.release(), b#groups) }) :: Ref.get(st#retired), st#retired)

    /// bundle を積む描き先。color = 色の形式（色を持たない影の地図は None）・depth = 深度の形式・samples = 標本の数。
    pub type alias BundleTarget = { color = Option[TextureFormat], depth = TextureFormat, samples = Int32 }

    /// 持ち越した物 c の鍵 key の bundle を pass に流す（無いか、積んだ時と group 0 か材質の絵の世代 epoch が違えば積み直す）。
    /// record(積み先, group 1 の置き場) = 行を積む関数（group 0 は ここで付ける）。流した後の pass は pipeline・bind group・頂点の buffer を付け直す。
    // WhyNot: group 0 が替わった時に bundle を捨てずに使い続けない — bundle は積んだ時の group を読み続け、前のコマの影の地図や描き先の値を描く。
    pub def runBundle(st: Statics, gpu: WebGpu, c: Carried, key: String, group: BindGroup, epoch: Int64, target: BundleTarget,
                      record: (RenderCommands, Ref[List[BindGroup], Static]) -> Unit \ IO, pass: RenderPass): Unit \ IO =
        let held = Map.get(key, Ref.get(c#bundles));
        let bundle = if (isCurrent(held, group, epoch)) held |> Option.map(b -> b#bundle) |> Option.getWithDefault(unchecked_cast(null as RenderBundle)) else {
                held |> Option.forEach(retireBundle(st));
                let encoder = gpu.createRenderBundleEncoder("fge scene3d static", colorOrNull(target#color), target#depth, target#samples);
                encoder.setBindGroup(0, group);
                let groups = Ref.fresh(Static, Nil);
                record(checked_cast(encoder), groups);
                let made = encoder.finish();
                Ref.put(Map.insert(key, { bundle = made, group = group, epoch = epoch, groups = Ref.get(groups) }, Ref.get(c#bundles)), c#bundles);
                made
        };
        pass.executeBundle(bundle)

    /// held が group 0 group（参照で比べる）と材質の絵の世代 epoch で積んだ bundle か。
    def isCurrent(held: Option[Bundle], group: BindGroup, epoch: Int64): Bool \ IO = match held {
        case Some(b) =>
            let was: Object = checked_cast(b#group);
            let now: Object = checked_cast(group);
            b#epoch == epoch and Objects.equals(was, now)
        case None    => false
    }

    /// 場面を描く前に持ち越した物 c を今のコマで使った物にする: 形と材質の絵を今の世代にし（絵は無ければ作る）、場面の時刻 time が変わっていれば値の区画の uTime を書き直す。
    // WhyNot: 同じ集まりを時刻の違う 2 つの場面で描く時に場面ごとに値を分けない — 書いた値は submit の前に効くので、後の場面の時刻で両方を描く。材質の時刻が絵に効く集まりは場面ごとに別の集まりにする。
    pub def stage(gpu: WebGpu, materials: WebGpuMaterials.Materials, source: TextureSource, registered: WebGpuMaterials.Registered, gen: Int64, time: Float64, c: Carried): Unit \ IO =
        MeshTable.touchSlots(c#rows#meshSlots, gen);
        WebGpuMaterials.uploadTexturesAt(materials, source, registered, gen, c#rows#list, c#textureRows);
        if (StaticRows.retime(c#rows, time)) {
            let one = ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN);
            discard one.putFloat(0, RenderUtil.f32(time));
            c#rows#timeAt |> Vector.forEach(at -> gpu.writeBuffer(c#values, Int32.toInt64(4 * at), one, 0, 4))
        } else ()

    /// 色の形式（色を持たない描き先は Java の null。WebGpu.createRenderBundleEncoder の決まり）。
    def colorOrNull(color: Option[TextureFormat]): TextureFormat = match color {
        case Some(f) => f
        case None    => unchecked_cast(null as TextureFormat)
    }

    /// 2D の描き手が encoder を submit した後に呼ぶ（作り直した集まりの古い buffer と bundle を手放す）。
    pub def afterSubmit(st: Statics): Unit \ IO =
        Ref.get(st#retired) |> List.forEach(f -> f());
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

    /// 持ち越した物 c の影の地図の行を、地図の鍵 key ごとの bundle で流す関数（Render3d.WebGpuShadows.ShadowDraw の carried）。
    /// 渡される drawWith(積み先, 行, 1 体ごとの値の buffer) が行を積む。
    pub def shadowRunnerOf(st: Statics, gpu: WebGpu, c: Carried, depth: TextureFormat):
            (RenderPass, String, BindGroup, (RenderCommands, SceneList, Buffer) -> Unit \ IO) -> Unit \ IO =
        (pass, key, group, drawWith) ->
            runBundle(st, gpu, c, "shadow:" + key, group, 0i64, { color = None, depth = depth, samples = 1 },
                      (encoder, _) -> drawWith(encoder, c#rows#shadowList, c#instances), pass)
}
