// Render3d.StaticRows — 動かない物の集まり（Scene3d.staticGroup）の計画と描く行を、コマをまたいで持ち越す所（前半の側。GPU を呼ばない）。
// 集まりごとに 1 回だけ候補に分け、1 体ごとの値を詰め、場面の pass の行（頂点の色と不透明の材質）と影の地図の行を作る（build）。backend は答えを GPU に置いて毎コマ描く。
// 同じ集まりかは、名前・staticGroup で作った items の値そのもの（参照）・外した鍵・tint・行の決め方の鍵（色の場面か奥行きの書き出しか・変種・alpha to coverage）で見る（中身は比べない・Cache）。
// 作る仕事は段（BuildPhase）に分けてあり、staticGroup を作り直した集まりは前の控えを描きながら 1 コマに決まった時間ずつ進める（ensure）。
// 半透明（目から遠い順に毎コマ並べ直す）と骨つき（姿勢が毎コマ変わる）は持ち越さず、場面の計画へ通す（perFrameOf）。
// WhyNot: 持ち越す物を視錐台で間引かない — 持ち越した行は目の位置に依らず、間引くと目が動くたびに作り直しになる（遠くを描かないのは、集まりを区画に分けてゲームが載せ外しする）。
// backend は WebGPU（Render3d.WebGpuStatic）と GL（Render3d.GlStatic）。どちらも持ち越した行を場面の行の前に描く。
mod Render3d.StaticRows {
    import java.lang.Object
    import java.lang.System
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.util.IdentityHashMap
    use Render3d.InstanceValues.{PackMode, floatsPerInstance, numberSpan}
    use Render3d.MaterialValues
    use Render3d.MeshTable
    use Render3d.ScenePlan.{CarriedGrouping, MaterialRequest, Planner, carriedResultOf, groupCarried, materialsInOrder, splitGroups, startCarried, stepCarried, warnOnce}
    use Render3d.SceneList.{SceneList, Tables, buildSceneList, buildShadowList, contextOf, flagSameBinding, hasFlag, headAt, rowCountOf, setValuesAt, valuesAt}

    // ── 持ち越す物と毎コマの物 ──

    /// 集まりの物 i を持ち越すか（半透明でも骨つきでもない物）。
    pub def isCarriedItem(i: Scene3d.Instance3d): Bool =
        not Scene3d.isBlendedFields(Scene3d.instanceFieldsOf(i)) and Option.isEmpty(Scene3d.skinningOf(i))

    /// 場面の計画へ通す物: instances と、持ち越した集まりの持ち越さない物（carried の perFrame）。
    pub def perFrameOf(scene: Scene3d.Scene3dCmd, carried: List[CarriedRows]): List[Scene3d.Instance3d] =
        List.foldRight((c, acc) -> List.append(c#perFrame, acc), Nil, carried) |> List.append(scene#instances)

    /// 場面に描く物が 1 つでもあるか（集まりは外していない鍵が 1 つでもあるか。先頭で止まり、描く物の列を作らない）。
    pub def hasDrawnItem(scene: Scene3d.Scene3dCmd): Bool =
        not List.isEmpty(scene#instances) or List.exists(g -> {
            let r = Scene3d.staticGroupFieldsOf(g);
            List.exists(kv -> not Set.memberOf(fst(kv), r#removed), r#items)
        }, scene#groups)

    /// 場面の置いた物の数（診断）。carried = 場面の持ち越した集まり。
    pub def placedCountOf(scene: Scene3d.Scene3dCmd, carried: List[CarriedRows]): Int32 =
        List.length(scene#instances) + List.sumWith(c -> c#placed + List.length(c#perFrame), carried)

    /// 場面 scene の持ち越した行の決め方の鍵（ensure の variant）。色の場面か奥行きの書き出しか・場面の pass の変種（Render3d.passVariantOf）・
    /// coverage = cutout を alpha to coverage の版にするか（Render3d.ScenePlan.coverageOf）。
    // WhyNot: 奥行きの書き出しの場面で色の場面の行を使わない — 奥行きの書き出しは cutout でも両面でもない材質を頂点の色の道で描き、変種も既定で、行が違う。
    // WhyNot: 奥行きの書き出しの near と range を鍵に入れない — 行には入らず、場面の値で渡す。
    pub def carriedKeyOf(coverage: Bool, scene: Scene3d.Scene3dCmd): String =
        let output = match scene#output {
            case Scene3d.Output.Color    => "color"
            case Scene3d.Output.Depth(_) => "depth"
        };
        output + Render3d.variantKeyOf(Render3d.passVariantOf(scene)) + (if (coverage) "+a2c" else "")

    // ── 行を作る ──

    /// 集まり 1 つの持ち越す行。list = 場面の pass の行（頂点の色 → 不透明の材質。ビルボードと半透明の行は無い）・shadowList = 影の地図の行（形だけ・奥行きの書き出しの場面は空）・
    /// instances = 1 体ごとの値（list と shadowList の行の欄 3 が頭からの番号で指す）・instanceCount = その体の数・requests = 行の欄 1 が引く材質の問い合わせ・
    /// timeAt = list の values の中の uTime の位置（値の区画ごとに 1 つ）・time = values に書いた時刻（要素 1 つ）・placed = 持ち越す物の数・
    /// combinedAway = つないで描く物の数に出ない物の数（つないだ物の数 − つないだ形の数。描いた物の数へ足す）・meshSlots = 行の形の控え（毎コマ使った物にする）・perFrame = 集まりの持ち越さない物（半透明と骨つき。毎コマ場面の計画へ通す）。
    pub type alias CarriedRows = {
        list = SceneList, shadowList = SceneList, instances = ByteBuffer, instanceCount = Int32, requests = Vector[MaterialRequest],
        timeAt = Vector[Int32], time = Array[Float64, Static], placed = Int32, combinedAway = Int32, meshSlots = Vector[MeshTable.Slot], perFrame = List[Scene3d.Instance3d]
    }

    /// 集まり g の持ち越す物の行を 1 回で作る。resolve = 材質の問い合わせに順の番号で答える（backend。0 なら頂点の色で描く）・
    /// coverage = cutout を alpha to coverage の版にするか（carriedKeyOf に渡す物と同じ）・scene = 行の決め方（Output・変種）と絵の名前と時刻を引く場面。
    /// 形と絵の番号は tables で振る（GPU には作らない）。
    /// 1 回しか使わない形は 1 つの形につなぐ（Scene3d.StaticBatch・DrawMode.OneByOne ではつながない）。
    pub def build(planner: Planner, tables: Tables, resolve: Vector[MaterialRequest] -> Vector[Int32] \ ef, coverage: Bool, scene: Scene3d.Scene3dCmd,
                  g: Scene3d.StaticGroup): CarriedRows \ ef + IO =
        let (items, perFrame) = Scene3d.groupInstancesOf(g) |> List.partition(isCarriedItem);
        let drawn = if (isCombining(planner)) Scene3d.StaticBatch.combineAll(items) else items;
        let (lit, shadow, requests, members) = groupCarried(planner, coverage, scene, drawn);
        rowsOf(planner, tables, resolve(requests), scene, { placed = List.length(items), drawn = List.length(drawn) }, perFrame, (lit, shadow, requests, members))

    /// 集まりの 1 回しか使わない形をつなぐか（DrawMode.OneByOne は batch の鍵と順の比べ相手なので、つながずに物ごとに描く）。
    def isCombining(planner: Planner): Bool = planner#drawMode == Render3d.DrawMode.Instanced

    /// 候補に分けた答え grouped（groupCarried の形）と材質の答え orders から行を作る。counts = 持ち越す物の数（placed）と、つないだ後の描く物の数（drawn）。
    def rowsOf(planner: Planner, tables: Tables, orders: Vector[Int32], scene: Scene3d.Scene3dCmd, counts: { placed = Int32, drawn = Int32 }, perFrame: List[Scene3d.Instance3d],
               grouped: (List[Render3d.ScenePlan.Group], List[Render3d.Batch.SpanBatch], Vector[MaterialRequest], MutList[Render3d.MeshDraw, Static])): CarriedRows \ IO =
        let (lit, shadow, requests, members) = grouped;
        let (plain, materials) = splitGroups(lit, orders);
        let opaque = materialsInOrder(planner, materials);
        let total = List.sumWith(b -> b#count, plain) + List.sumWith(d -> d#batch#count, opaque) + List.sumWith(b -> b#count, shadow);
        let raw = ByteBuffer.allocateDirect(Int32.max(4, 4 * floatsPerInstance() * total)).order(ByteOrder.LITTLE_ENDIAN);
        let out = raw.asFloatBuffer();
        let scratch = Array.repeat(Static, floatsPerInstance(), 0.0f32);
        let next = Array#{0} @ Static;
        let numberLit = numberSpan(out, scratch, Int32.maxValue(), next, members, PackMode.Lit);
        let numberedPlain = List.map(numberLit, plain);
        let numberedOpaque = opaque |> List.map(d -> { handle = d#handle, order = d#order, kind = d#kind, material = d#material, batch = numberLit(d#batch) });
        let numberedShadow = List.map(numberSpan(out, scratch, Int32.maxValue(), next, members, PackMode.ShadowDepth), shadow);
        let ctx = contextOf(tables, scene);
        let list = buildSceneList(ctx, { plain = numberedPlain, skinned = Nil, opaque = numberedOpaque, blended = Nil, billboards = Nil });
        let shadowList = buildShadowList(ctx, numberedShadow, Nil, Nil);
        { list = list, shadowList = shadowList, instances = raw, instanceCount = Array.get(0, next), requests = requests, timeAt = shareSameValues(list),
          time = Array#{scene#time} @ Static, placed = counts#placed, combinedAway = counts#placed - counts#drawn, meshSlots = slotsOf(tables, list, shadowList), perFrame = perFrame }

    /// 前の材質の行と同じ付け方（flagSameBinding）の行の値の位置を前の行の値へ向け、残った値の区画の uTime の位置を返す。
    // WhyNot: 同じ付け方の行の値を別々に残さない — 1 棟ずつの都市では行が物の数だけあり、毎コマ時刻を書き直す区画が物の数だけになる。値は前の行と同じ中身。
    def shareSameValues(list: SceneList): Vector[Int32] \ IO =
        let times = MutList.empty(Static);
        let previous = Array#{-1} @ Static;
        shareFrom(list, times, previous, 0, rowCountOf(list));
        MutList.toArray(Static, times) |> Array.toVector

    def shareFrom(list: SceneList, times: MutList[Int32, Static], previous: Array[Int32, Static], row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            shareOne(list, times, previous, row);
            shareFrom(list, times, previous, row + 1, n)
        }

    // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある集まりで shareFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    def shareOne(list: SceneList, times: MutList[Int32, Static], previous: Array[Int32, Static], row: Int32): Unit \ IO =
        let at = valuesAt(list, row);
        let before = Array.get(0, previous);
        if (at < 0) ()
        else if (before >= 0 and hasFlag(list, row, flagSameBinding())) setValuesAt(list, row, before)
        else {
            Array.put(at, 0, previous);
            MutList.push(at + MaterialValues.drawValueFloats(), times)
        };
        ()

    /// 行の頭の物の形の控え（list の後に shadowList）。
    def slotsOf(tables: Tables, list: SceneList, shadowList: SceneList): Vector[MeshTable.Slot] \ IO =
        let slotAt = (l: SceneList, row: Int32) -> MeshTable.slotOf(tables#meshes, tables#gen, headAt(l, row)#fields#mesh);
        let lit = Vector.range(0, rowCountOf(list)) |> Vector.map(row -> slotAt(list, row));
        let shadow = Vector.range(0, rowCountOf(shadowList)) |> Vector.map(row -> slotAt(shadowList, row));
        Vector.append(lit, shadow)

    /// 行の values の時刻を time にする（前と同じ時刻なら何もせず偽・書き直したら真）。
    pub def setTime(c: CarriedRows, time: Float64): Bool \ IO =
        if (Array.get(0, c#time) == time) false
        else {
            let t = RenderUtil.f32(time);
            Vector.forEach(at -> Array.put(t, at, c#list#values), c#timeAt);
            Array.put(time, 0, c#time);
            true
        }

    // ── 少しずつ作る ──

    /// 集まりを作る時に backend がする仕事（どれも今のコマの物を渡す）。tables = 前半の行の番号を振る表・resolve = 材質の問い合わせに順の番号で答える（build と同じ）・
    /// prepareMesh = 形 1 つを GPU に作る（中身の鍵もここで取る）・prepareMaterial = 材質 1 つの program を組む・place = 行を GPU に置く・
    /// uploadCount と uploadAt = 置いた物を描く前に GPU へ上げる物の数と、その k 番目を上げる仕事（材質の絵）・retire = 置いた物を手放す。
    pub type alias BuildSteps[a] = {
        tables = Tables, resolve = Vector[MaterialRequest] -> Vector[Int32] \ IO, prepareMesh = Mesh3d.Mesh3d -> Unit \ IO,
        prepareMaterial = MaterialRequest -> Unit \ IO, place = CarriedRows -> a \ IO, uploadCount = a -> Int32 \ IO, uploadAt = (a, Int32) -> Unit \ IO,
        retire = a -> Unit \ IO
    }

    /// 作る段。Keys = 持ち越す物の鍵（形の中身の鍵とつなぐ単位の鍵。Scene3d.StaticBatch.keysOf）を取る（1 つずつ。終えたらつなぐ計画を作る）・
    /// Combine = 計画の描く物を作る（1 つずつ。つなぐ物はここで 1 つの形にする）・
    /// Meshes = 形を GPU に作る（1 つずつ）・Group = 候補に分ける（groupChunk 体ずつ）・Materials = 材質の program を組む（1 つずつ）・
    /// Place = 行を作って置く（止めない最後の仕事）・Upload = 置いた物の絵を上げる（1 枚ずつ）・Done = 済んだ。
    pub enum BuildPhase with Eq {
        case Keys, Combine, Meshes, Group, Materials, Place, Upload, Done
    }

    /// 作りかけの集まり。source = 持ち越す物（つなぐ前）・keys = Keys の段で取った source の鍵（来た順）・plan = つなぐ計画（Keys の段を終えて作る）・
    /// combined = 計画の描く物（頭から順に足す）・coverage = build と同じ・
    /// items = 描く物（つないだ後。Combine の段を終えて決まる）・meshes = その形（同じ値は 1 つ）・perFrame = 持ち越さない物・grouping = 候補分けの作りかけ・
    /// requests = 分け終えた材質の問い合わせ・phase と next = 今の段とその段の次の番号・made = 置いた物（Place の後）。
    pub type alias Build[a] = {
        source = Vector[Scene3d.Instance3d], keys = MutList[Scene3d.StaticBatch.ItemKeys, Static], plan = Ref[Vector[Scene3d.StaticBatch.PlanEntry], Static],
        combined = MutList[Scene3d.Instance3d, Static], coverage = Bool,
        items = Ref[Vector[Scene3d.Instance3d], Static], meshes = Ref[Vector[Mesh3d.Mesh3d], Static], perFrame = List[Scene3d.Instance3d], scene = Scene3d.Scene3dCmd,
        grouping = Ref[CarriedGrouping, Static], requests = Ref[Vector[MaterialRequest], Static], phase = Ref[BuildPhase, Static], next = Array[Int32, Static],
        made = Ref[Option[a], Static]
    }

    /// 集まり g を作り始める（まだ何もしない）。coverage と scene は build と同じ。つながない描き方（isCombining が偽）は Meshes の段から始める
    /// （つなぐ描き方の描く物・形・候補分けは Combine の段を終えて入れる）。
    pub def startBuild(planner: Planner, coverage: Bool, scene: Scene3d.Scene3dCmd, g: Scene3d.StaticGroup): Build[a] \ IO =
        let (items, perFrame) = Scene3d.groupInstancesOf(g) |> List.partition(isCarriedItem);
        let combining = isCombining(planner);
        let drawn = if (combining) Nil else items;
        { source = List.toVector(items), keys = MutList.empty(Static), plan = Ref.fresh(Static, Vector.empty()), combined = MutList.empty(Static), coverage = coverage,
          items = Ref.fresh(Static, List.toVector(drawn)), meshes = Ref.fresh(Static, distinctMeshesOf(drawn)), perFrame = perFrame, scene = scene,
          grouping = Ref.fresh(Static, startCarried(planner, coverage, scene, drawn)), requests = Ref.fresh(Static, Vector.empty()),
          phase = Ref.fresh(Static, if (combining) BuildPhase.Keys else BuildPhase.Meshes), next = Array#{0} @ Static, made = Ref.fresh(Static, None) }

    /// items の形（同じ値は 1 つ・来た順）。
    // WhyNot: 中身の鍵で重なりを除かない — 鍵を取るのは Keys と Meshes の段の仕事（SHA-256 を 1 つずつ）で、ここで取ると 1 コマにまとめて払う。
    def distinctMeshesOf(items: List[Scene3d.Instance3d]): Vector[Mesh3d.Mesh3d] \ IO =
        let seen: IdentityHashMap[Object, Object] = new IdentityHashMap();
        let out = MutList.empty(Static);
        items |> List.forEach(i -> {
            let mesh = Scene3d.instanceFieldsOf(i)#mesh;
            let key = unchecked_cast(mesh as Object);
            if (seen.containsKey(key)) () else { discard seen.put(key, key); MutList.push(mesh, out) }
        });
        MutList.toArray(Static, out) |> Array.toVector

    /// b を、次の仕事に deadline までの時間が残っている間（hasRoomFor）進める（残っていなくても 1 つは進める）。
    /// 全部の段が済んだら置いた物。
    pub def stepBuild(planner: Planner, steps: BuildSteps[a], b: Build[a], deadline: Int64): Option[a] \ IO =
        stepOnce(planner, steps, b);
        if (Ref.get(b#phase) == BuildPhase.Done) Ref.get(b#made)
        else if (not hasRoomFor(b, deadline)) None
        else stepBuild(planner, steps, b, deadline)

    /// b の次の仕事を deadline までに始めてよいか。重い仕事（Place と、頂点の多い形を作る仕事）は heavyRoomNs 以上残っている時だけ。
    def hasRoomFor(b: Build[a], deadline: Int64): Bool \ IO =
        let left = deadline - System.nanoTime();
        if (isHeavyNext(b)) left >= heavyRoomNs() else left > 0i64

    /// b の次の仕事が重いか: Place（集まり 1 つの行を全部作る）か、heavyVertices 以上の頂点の形を作る仕事。
    def isHeavyNext(b: Build[a]): Bool \ IO =
        let i = Array.get(0, b#next);
        match Ref.get(b#phase) {
            case BuildPhase.Place  => true
            case BuildPhase.Meshes => i < Vector.length(b#meshes) and Mesh3d.vertexCount(Vector.get(i, b#meshes)) >= heavyVertices()
            case _                 => false
        }

    /// 重い仕事を始めるのに残っていてほしい時間（ns）。
    // WhyNot: 時計が少しでも残っていれば重い仕事を始める、としない — 形 1 つ・Place 1 回で数十 ms かかる物があり、予算の終わりの近くで始めると 1 コマが予算の何倍にもなる。
    // WhyNot: 仕事の重さを測って決めない — 重さは形の頂点の数と集まりの物の数で決まり、初めての仕事の前には測れない。
    def heavyRoomNs(): Int64 = frameBudgetNs() / 2i64

    /// 形を作る仕事を重いとみなす頂点の数。
    // WhyNot: もっと少なくしない — 小物の形まで重い扱いになり、予算の後半に形を 1 つも作らないコマが増えて作り終えるのが遅れる。
    // WhyNot: もっと多くしない — 頂点 4 千の形で PC の WebGPU の数 ms かかり、予算の終わりに始めると 1 コマが予算を大きく超える。
    def heavyVertices(): Int32 = 4000

    /// 候補分けで時計を見る間の物の数。
    def groupChunk(): Int32 = 32

    // WhyNot: 枝を呼び出しで終えない — 1 回しか回らない stepBuild のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def stepOnce(planner: Planner, steps: BuildSteps[a], b: Build[a]): Unit \ IO =
        let i = Array.get(0, b#next);
        match Ref.get(b#phase) {
            case BuildPhase.Keys =>
                if (i >= Vector.length(b#source)) enterCombine(b)
                else stepTo(b, i, () -> MutList.push(Scene3d.StaticBatch.keysOf(Vector.get(i, b#source)), b#keys))
            case BuildPhase.Combine =>
                let plan = Ref.get(b#plan);
                if (i >= Vector.length(plan)) finishCombine(planner, b)
                else stepTo(b, i, () -> MutList.push(Scene3d.StaticBatch.instanceOf(Vector.get(i, plan)), b#combined))
            case BuildPhase.Meshes =>
                let meshes = Ref.get(b#meshes);
                if (i >= Vector.length(meshes)) enter(b, BuildPhase.Group)
                else stepTo(b, i, () -> steps#prepareMesh(Vector.get(i, meshes)))
            case BuildPhase.Group =>
                if (stepCarried(Ref.get(b#grouping), groupChunk())) {
                    let (_, _, requests, _) = carriedResultOf(Ref.get(b#grouping));
                    Ref.put(requests, b#requests);
                    enter(b, BuildPhase.Materials)
                } else ()
            case BuildPhase.Materials =>
                if (i >= Vector.length(Ref.get(b#requests))) enter(b, BuildPhase.Place)
                else stepTo(b, i, () -> steps#prepareMaterial(Vector.get(i, Ref.get(b#requests))))
            case BuildPhase.Place  => discard placeOf(planner, steps, b)
            case BuildPhase.Upload => Ref.get(b#made) |> Option.forEach(uploadOne(steps, b, i))
            case BuildPhase.Done   => ()
        };
        ()

    /// 取り終えた鍵からつなぐ計画を作り、Combine の段へ。
    def enterCombine(b: Build[a]): Unit \ IO =
        Ref.put(Scene3d.StaticBatch.planFromKeys(MutList.toVector(b#keys), b#source), b#plan);
        enter(b, BuildPhase.Combine)

    /// 計画の描く物を作り終えた b の、描く物・形・候補分けを入れて Meshes の段へ。
    def finishCombine(planner: Planner, b: Build[a]): Unit \ IO =
        let drawn = MutList.toList(b#combined);
        Ref.put(List.toVector(drawn), b#items);
        Ref.put(distinctMeshesOf(drawn), b#meshes);
        Ref.put(startCarried(planner, b#coverage, b#scene, drawn), b#grouping);
        enter(b, BuildPhase.Meshes)


    /// 分け終えた b の行を作って置き、置いた物を返す（Upload の段へ進む）。
    def placeOf(planner: Planner, steps: BuildSteps[a], b: Build[a]): a \ IO =
        let grouped = carriedResultOf(Ref.get(b#grouping));
        let rows = rowsOf(planner, steps#tables, steps#resolve(Ref.get(b#requests)), b#scene, { placed = Vector.length(b#source), drawn = Vector.length(Ref.get(b#items)) }, b#perFrame, grouped);
        let made = steps#place(rows);
        Ref.put(Some(made), b#made);
        enter(b, BuildPhase.Upload);
        made

    /// b を時計を見ずに全部の段まで進めて、置いた物を返す。
    def buildAll(planner: Planner, steps: BuildSteps[a], b: Build[a]): a \ IO =
        let made = match Ref.get(b#made) {
            case Some(placed) => placed
            case None         =>
                stepUntil(planner, steps, b, BuildPhase.Place);
                placeOf(planner, steps, b)
        };
        stepUntil(planner, steps, b, BuildPhase.Done);
        made

    def stepUntil(planner: Planner, steps: BuildSteps[a], b: Build[a], phase: BuildPhase): Unit \ IO =
        if (Ref.get(b#phase) == phase) ()
        else {
            stepOnce(planner, steps, b);
            stepUntil(planner, steps, b, phase)
        }

    /// 置いた物 made の i 番目を上げる（残りが無ければ Done へ）。
    def uploadOne(steps: BuildSteps[a], b: Build[a], i: Int32, made: a): Unit \ IO =
        if (i >= steps#uploadCount(made)) enter(b, BuildPhase.Done)
        else stepTo(b, i, () -> steps#uploadAt(made, i))

    def stepTo(b: Build[a], i: Int32, work: Unit -> Unit \ IO): Unit \ IO =
        work();
        Array.put(i + 1, 0, b#next)

    def enter(b: Build[a], phase: BuildPhase): Unit \ IO =
        Ref.put(phase, b#phase);
        Array.put(0, 0, b#next)

    // ── 持ち越しの控え ──

    /// 集まり 1 つの控え。items = staticGroup で作った items の値だけを鍵に持つ表（参照で比べる）・removed と tint = 作った時の外した鍵と色・
    /// payload = backend が置いた物・lastUsed = 最後に描いたコマの世代（要素 1 つ）。
    // WhyNot: items を Eq で比べない — 中身の比べは物の数だけ形と材質を辿り、持ち越しで省きたい仕事と同じ重さになる。
    /// variant = 作った時の行の決め方の鍵（carriedKeyOf。材質のプログラムの版と、材質を組む物が場面で違う）。
    type alias Entry[a] = { items = IdentityHashMap[Object, Object], removed = Set[String], tint = Color, variant = String, payload = a, lastUsed = Array[Int64, Static] }

    /// 作りかけの集まり 1 つ（作り直しの間は前の控えを描く）。items・removed・tint・variant = 作っている集まり（Entry と同じ）・
    /// lastStep = 最後に進めたコマの世代（要素 1 つ）。
    type alias Work[a] = { items = IdentityHashMap[Object, Object], removed = Set[String], tint = Color, variant = String, build = Build[a],
                           lastStep = Array[Int64, Static] }

    /// 持ち越しの控え（a = backend が GPU に置いた物）。entries = 集まりの名前 → 控えの列（同じ名前でも中身の違う集まりを 1 コマに何場面かで描くと 2 つ以上）・
    /// rebuilds = 名前 → (最後に作り直した世代, 続けて作り直したコマの数)・works = 名前 → 作りかけの列（行の決め方の鍵ごとに 1 つ）・
    /// remakes = (名前, 行の決め方の鍵) → 作り終える前に別の値へ替わった回数（控えに当たるか作り終えたら 0 に戻す）・
    /// budget = (予算を決めたコマの世代, そのコマに少しずつ作るのを止める時刻（System.nanoTime）, 予算切れの後の最低の時間を渡したコマの世代)。
    pub type alias Cache[a] = { entries = Ref[Map[String, List[Entry[a]]], Static], rebuilds = Ref[Map[String, (Int64, Int32)], Static],
                                works = Ref[Map[String, List[Work[a]]], Static], remakes = Ref[Map[(String, String), Int32], Static], budget = Array[Int64, Static] }

    pub def freshCache(): Cache[a] \ IO =
        { entries = Ref.fresh(Static, Map.empty()), rebuilds = Ref.fresh(Static, Map.empty()), works = Ref.fresh(Static, Map.empty()),
          remakes = Ref.fresh(Static, Map.empty()), budget = Array#{-1i64, 0i64, -1i64} @ Static }

    /// この数のコマ続けて同じ名前の集まりを作り直したら、1 回知らせる。
    def rebuildStreakLimit(): Int32 = 30

    /// 1 コマに少しずつ作る仕事へ使う時間（ns）。コマの初めて集まりを引いた時から数える。
    // WhyNot: ゲームから渡さない — 渡す口は pub が増え、先に払う宣言（withPreload3d）の形と一緒に決める。
    // WhyNot: もっと長くしない — 止めない最後の仕事（Place）と、置いた物を初めて描くコマの bundle の積みがこの上に乗る。
    def frameBudgetNs(): Int64 = 8000000i64

    /// 予算を使い切った後のコマでも、そのコマで最初に来た作りかけ 1 つはこの時間（ns）進める。
    // WhyNot: 予算を使い切ったら 1 段だけにしない — 形を作る段は 1 段が形 1 つで、同じコマに初めて見えた集まりを作ると、形の多い作り直しが何千コマも止まる。
    // WhyNot: 作りかけごとに渡さない — 区画に分けた集まりを一度に作り直すと、区画の数だけ予算の上に乗る。
    def minimumStepNs(): Int64 = 1000000i64

    /// 作り終える前に別の値へ替わるのがこの回数を超えたら、前の控えを描かずに 1 コマで作る（控えに当たるまで続ける）。
    // WhyNot: 替わるたびに作り直しを始めるだけにしない — 毎コマ新しい値を渡すゲームでは作り終えず、前の絵がいつまでも残る。
    def restartLimit(): Int32 = 2

    /// gen のコマに少しずつ作るのを止める時刻（そのコマで初めて呼んだ時に決める）。
    def deadlineOf(cache: Cache[a], gen: Int64): Int64 \ IO =
        if (Array.get(0, cache#budget) == gen) ()
        else {
            Array.put(gen, 0, cache#budget);
            Array.put(System.nanoTime() + frameBudgetNs(), 1, cache#budget)
        };
        Array.get(1, cache#budget)

    /// 集まり g の持ち越した物。名前・items の値・外した鍵・tint・行の決め方の鍵 variant（carriedKeyOf）が同じ控えがあればその物。
    /// 無ければ steps で作る: 同じ名前・同じ variant の控えがあって items の値だけが違う時（staticGroup を作り直した）は、その控えを描きながら
    /// 1 コマに frameBudgetNs ずつ作り、作り終えたコマで替える。前の控えが無い時と、同じ items の値で外した鍵か tint だけが違う時は、このコマで全部作る。
    /// 作る時は、同じ名前の控えのうち今のコマで使っていない物を steps#retire へ渡す（今のコマで使った物は、ほかの場面が描くので残す）。gen = 今のコマの世代。
    // WhyNot: 外した鍵と tint だけ替わった時に前の控えを描かない — 拾って消した物が作り終えるまで残って見え、手に持った物と二重になる。
    // WhyNot: 前の控えが無い集まりを分けて作らない — 半分だけ見える集まりは壊れた絵で、何も無いのも物が消えて見える。先に払うのは起動と暗転の間（withPreload3d）。
    pub def ensure(planner: Planner, cache: Cache[a], gen: Int64, g: Scene3d.StaticGroup, variant: String, coverage: Bool, scene: Scene3d.Scene3dCmd,
                   steps: BuildSteps[a]): a \ IO =
        let deadline = deadlineOf(cache, gen);
        let f = Scene3d.staticGroupFieldsOf(g);
        let items = unchecked_cast(f#items as Object);
        let held = Map.getWithDefault(f#name, Nil, Ref.get(cache#entries));
        match List.find(e -> isSameGroup(f, e) and e#variant == variant and e#items.containsKey(items), held) {
            case Some(e) =>
                Array.put(gen, 0, e#lastUsed);
                settle(cache, f#name, variant, steps#retire);
                e#payload
            case None =>
                let shown = shownWhileBuilding(held, variant, items);
                let work = shown |> Option.flatMap(_ -> workFor(planner, cache, gen, g, variant, coverage, scene, steps#retire));
                match (shown, work) {
                    case (Some(e), Some(w)) => stepOrShow(planner, cache, gen, f, variant, steps, deadline, e, w)
                    case _ => finishNow(planner, cache, gen, g, variant, coverage, scene, steps)
                }
        }

    /// 作りかけ w を今のコマの予算まで進め、作り終えたら控えに入れてその物、まだなら前の控え shown の物。
    def stepOrShow(planner: Planner, cache: Cache[a], gen: Int64, f: Scene3d.StaticGroupFields, variant: String, steps: BuildSteps[a], deadline: Int64,
                   shown: Entry[a], w: Work[a]): a \ IO =
        Array.put(gen, 0, w#lastStep);
        match stepBuild(planner, steps, w#build, deadlineWithMinimum(cache, gen, deadline)) {
            case Some(made) =>
                removeWork(cache, f#name, variant);
                Ref.put(Map.remove((f#name, variant), Ref.get(cache#remakes)), cache#remakes);
                insertEntry(planner, cache, gen, f, variant, made, steps#retire)
            case None =>
                Array.put(gen, 0, shown#lastUsed);
                shown#payload
        }

    /// 予算を使い切っていて、このコマにまだ最低の時間を渡していなければ、今から minimumStepNs 後（渡したと控える）。ほかは deadline。
    def deadlineWithMinimum(cache: Cache[a], gen: Int64, deadline: Int64): Int64 \ IO =
        let now = System.nanoTime();
        if (now < deadline or Array.get(2, cache#budget) == gen) deadline
        else {
            Array.put(gen, 2, cache#budget);
            now + minimumStepNs()
        }

    /// g をこのコマで作り終えて控えに入れた物（先に上げる宣言の作りかけがあれば、その続きから）。
    def finishNow(planner: Planner, cache: Cache[a], gen: Int64, g: Scene3d.StaticGroup, variant: String, coverage: Bool, scene: Scene3d.Scene3dCmd,
                  steps: BuildSteps[a]): a \ IO =
        let f = Scene3d.staticGroupFieldsOf(g);
        match sameWorkOf(cache, f, variant) {
            case Some(w) =>
                removeWork(cache, f#name, variant);
                insertEntry(planner, cache, gen, f, variant, buildAll(planner, steps, w#build), steps#retire)
            case None =>
                dropWork(cache, f#name, variant, steps#retire);
                buildNow(planner, cache, gen, g, variant, coverage, scene, steps)
        }

    /// f と同じ集まり（items の値・外した鍵・tint）を variant で作っている作りかけ。
    def sameWorkOf(cache: Cache[a], f: Scene3d.StaticGroupFields, variant: String): Option[Work[a]] \ IO =
        let items = unchecked_cast(f#items as Object);
        Map.getWithDefault(f#name, Nil, Ref.get(cache#works))
            |> List.find(w -> w#variant == variant and w#items.containsKey(items) and f#removed == w#removed and isSameTint(f#tint, w#tint))

    /// 先に上げる宣言の集まり g を、描かずに variant の行で作る。作り終えていればその物（控えを今のコマで使った物にする）、
    /// まだならこのコマの予算まで作りかけを進めて None（作り終えたコマはその物）。次の仕事に予算が残っていないコマは進めない（hasRoomFor）。
    /// 返した物の形と絵を今のコマで使った物にするのは backend（宣言にある間は置き場の上限で捨てない）。
    // WhyNot: 予算を使い切った後に最低の時間（minimumStepNs）を渡さない — 宣言の作りかけは急がない。渡すと集まりの数だけ作りかけが同時に進み、1 コマが予算の何倍にもなる。
    //   進まないコマが続かないのは、描き手がコマの頭（場面を描く前）に呼び、そのコマの予算を最初に決めるのが宣言の側だから（GL の preloadScene3d・WebGPU の Scenes.preload）。
    pub def prepareAhead(planner: Planner, cache: Cache[a], gen: Int64, g: Scene3d.StaticGroup, variant: String, coverage: Bool, scene: Scene3d.Scene3dCmd,
                         steps: BuildSteps[a]): Option[a] \ IO =
        let deadline = deadlineOf(cache, gen);
        let f = Scene3d.staticGroupFieldsOf(g);
        let items = unchecked_cast(f#items as Object);
        let held = Map.getWithDefault(f#name, Nil, Ref.get(cache#entries));
        match List.find(e -> isSameGroup(f, e) and e#variant == variant and e#items.containsKey(items), held) {
            case Some(e) =>
                Array.put(gen, 0, e#lastUsed);
                Some(e#payload)
            case None => stepAhead(planner, cache, gen, g, variant, coverage, scene, steps, deadline)
        }

    /// prepareAhead の、控えに無い集まり g の作りかけ（無ければ始める）を deadline まで進める形。
    def stepAhead(planner: Planner, cache: Cache[a], gen: Int64, g: Scene3d.StaticGroup, variant: String, coverage: Bool, scene: Scene3d.Scene3dCmd,
                  steps: BuildSteps[a], deadline: Int64): Option[a] \ IO =
        let f = Scene3d.staticGroupFieldsOf(g);
        if (System.nanoTime() >= deadline) None
        else {
            let w = match sameWorkOf(cache, f, variant) {
                case Some(work) => work
                case None       => startWork(planner, cache, gen, g, variant, coverage, scene, steps#retire)
            };
            if (not hasRoomFor(w#build, deadline)) None
            else {
                Array.put(gen, 0, w#lastStep);
                match stepBuild(planner, steps, w#build, deadline) {
                    case Some(made) =>
                        removeWork(cache, f#name, variant);
                        Some(insertEntry(planner, cache, gen, f, variant, made, steps#retire))
                    case None => None
                }
            }
        }

    /// g の作りかけを始めて控える（同じ名前・variant の別の作りかけは捨てる）。
    def startWork(planner: Planner, cache: Cache[a], gen: Int64, g: Scene3d.StaticGroup, variant: String, coverage: Bool, scene: Scene3d.Scene3dCmd,
                  retire: a -> Unit \ IO): Work[a] \ IO =
        let f = Scene3d.staticGroupFieldsOf(g);
        let items = unchecked_cast(f#items as Object);
        dropWork(cache, f#name, variant, retire);
        let key: IdentityHashMap[Object, Object] = new IdentityHashMap();
        discard key.put(items, items);
        let w = { items = key, removed = f#removed, tint = f#tint, variant = variant, build = startBuild(planner, coverage, scene, g), lastStep = Array#{gen} @ Static };
        Ref.put(Map.insert(f#name, w :: Map.getWithDefault(f#name, Nil, Ref.get(cache#works)), Ref.get(cache#works)), cache#works);
        w

    /// g をこのコマで全部作って控えに入れた物。
    def buildNow(planner: Planner, cache: Cache[a], gen: Int64, g: Scene3d.StaticGroup, variant: String, coverage: Bool, scene: Scene3d.Scene3dCmd,
                 steps: BuildSteps[a]): a \ IO =
        let made = buildAll(planner, steps, startBuild(planner, coverage, scene, g));
        insertEntry(planner, cache, gen, Scene3d.staticGroupFieldsOf(g), variant, made, steps#retire)

    /// 作り直しの間に描く控え: held のうち variant が同じで items の値が違う物（一番最近描いた物）。items の値が同じ控えがあれば None（外した鍵か tint だけが違う）。
    def shownWhileBuilding(held: List[Entry[a]], variant: String, items: Object): Option[Entry[a]] \ IO =
        let same = List.filter(e -> e#variant == variant, held);
        if (List.exists(e -> e#items.containsKey(items), same)) None
        else List.foldLeft((acc, e) -> if (Option.exists(best -> Array.get(0, best#lastUsed) >= Array.get(0, e#lastUsed), acc)) acc else Some(e), None, same)

    /// g の作りかけ（同じ集まりの作りかけがあればそれ、無ければ始める）。作り終えていない別の値の作りかけは捨てて始め直し、
    /// 始め直しが上限を超えた (名前, variant) は None（1 コマで作る。控えに当たるまで続ける）。
    def workFor(planner: Planner, cache: Cache[a], gen: Int64, g: Scene3d.StaticGroup, variant: String, coverage: Bool, scene: Scene3d.Scene3dCmd,
                retire: a -> Unit \ IO): Option[Work[a]] \ IO =
        let f = Scene3d.staticGroupFieldsOf(g);
        let same = sameWorkOf(cache, f, variant);
        let building = Map.getWithDefault(f#name, Nil, Ref.get(cache#works)) |> List.exists(w -> w#variant == variant);
        let remakes = Map.getWithDefault((f#name, variant), 0, Ref.get(cache#remakes)) + (if (building) 1 else 0);
        if (Option.nonEmpty(same)) same
        else {
            Ref.put(Map.insert((f#name, variant), remakes, Ref.get(cache#remakes)), cache#remakes);
            if (remakes > restartLimit()) {
                dropWork(cache, f#name, variant, retire);
                None
            } else Some(startWork(planner, cache, gen, g, variant, coverage, scene, retire))
        }

    /// (name, variant) の集まりが控えに当たった: 作りかけを捨て（前の値へ戻った）、始め直しの数を 0 に戻す。
    def settle(cache: Cache[a], name: String, variant: String, retire: a -> Unit \ IO): Unit \ IO =
        if (Map.memberOf(name, Ref.get(cache#works))) dropWork(cache, name, variant, retire) else ();
        if (Map.memberOf((name, variant), Ref.get(cache#remakes))) Ref.put(Map.remove((name, variant), Ref.get(cache#remakes)), cache#remakes) else ()

    /// 名前 name・variant の作りかけを外す（置いた物があれば retire へ）。
    def dropWork(cache: Cache[a], name: String, variant: String, retire: a -> Unit \ IO): Unit \ IO =
        Map.getWithDefault(name, Nil, Ref.get(cache#works)) |> List.filter(w -> w#variant == variant) |> List.forEach(retireWork(retire));
        removeWork(cache, name, variant)

    /// 名前 name・variant の作りかけを外す（置いた物は控えへ移したので手放さない）。
    def removeWork(cache: Cache[a], name: String, variant: String): Unit \ IO =
        let rest = Map.getWithDefault(name, Nil, Ref.get(cache#works)) |> List.filter(w -> w#variant != variant);
        Ref.put(if (List.isEmpty(rest)) Map.remove(name, Ref.get(cache#works)) else Map.insert(name, rest, Ref.get(cache#works)), cache#works)

    def retireWork(retire: a -> Unit \ IO, w: Work[a]): Unit \ IO = Ref.get(w#build#made) |> Option.forEach(retire)

    /// 作った物 made を控えに入れて返す。同じ名前・同じ variant の控えのうち今のコマで使っていない物を retire へ渡す。
    // WhyNot: ほかの variant の控えを手放さない — 同じ集まりの別の場面（奥行きの書き出し）が、まだ作りかけの間に描いている前の控えかもしれない。使わなくなれば sweep が手放す。
    def insertEntry(planner: Planner, cache: Cache[a], gen: Int64, f: Scene3d.StaticGroupFields, variant: String, made: a, retire: a -> Unit \ IO): a \ IO =
        let items = unchecked_cast(f#items as Object);
        let held = Map.getWithDefault(f#name, Nil, Ref.get(cache#entries));
        let (usedNow, idle) = List.partition(e -> Array.get(0, e#lastUsed) == gen or e#variant != variant, held);
        List.forEach(e -> retire(e#payload), idle);
        noteRebuild(planner, cache, gen, f#name);
        let key: IdentityHashMap[Object, Object] = new IdentityHashMap();
        discard key.put(items, items);
        let entry = { items = key, removed = f#removed, tint = f#tint, variant = variant, payload = made, lastUsed = Array#{gen} @ Static };
        Ref.put(Map.insert(f#name, entry :: usedNow, Ref.get(cache#entries)), cache#entries);
        made

    /// 控え e の外した鍵と色が f と同じか（items の参照は呼ぶ側が比べる）。
    def isSameGroup(f: Scene3d.StaticGroupFields, e: Entry[a]): Bool =
        f#removed == e#removed and isSameTint(f#tint, e#tint)

    def isSameTint(a: Color, b: Color): Bool = a#r == b#r and a#g == b#g and a#b == b#b

    /// name の集まりを gen に作り直したと控え、続けて作り直したコマが上限に届いたら 1 回知らせる。
    def noteRebuild(planner: Planner, cache: Cache[a], gen: Int64, name: String): Unit \ IO =
        let streak = match Map.get(name, Ref.get(cache#rebuilds)) {
            case Some((last, n)) if last == gen - 1i64 => n + 1
            case Some((last, n)) if last == gen        => n
            case _                                     => 1
        };
        Ref.put(Map.insert(name, (gen, streak), Ref.get(cache#rebuilds)), cache#rebuilds);
        if (streak == rebuildStreakLimit())
            warnOnce(planner, "@staticGroup:" + name,
                "scene3d: 動かない物の集まり '${name}' を ${rebuildStreakLimit()} コマ続けて作り直した — 集まりは読み込みの時に 1 回作って毎コマ同じ値を渡す"
                + "（毎コマ staticGroup を呼ぶ・withoutItems や withGroupTint に毎コマ違う値を渡すと持ち越せない・名前が場面の中で重なっていないかも確かめる）")
        else ()

    /// idle のコマより長く描かなかった集まりの物と、長く進めなかった作りかけを retire へ渡して控えから外す。
    pub def sweep(cache: Cache[a], gen: Int64, idle: Int64, retire: a -> Unit \ ef): Unit \ ef + IO =
        let isStale = (e: Entry[a]) -> Array.get(0, e#lastUsed) + idle < gen;
        let all = Ref.get(cache#entries);
        Map.forEach((_, es) -> List.forEach(e -> if (isStale(e)) retire(e#payload) else (), es), all);
        Ref.put(all |> Map.map(List.filter(e -> not isStale(e))) |> Map.filter(es -> not List.isEmpty(es)), cache#entries);
        let isStaleWork = (w: Work[a]) -> Array.get(0, w#lastStep) + idle < gen;
        let works = Ref.get(cache#works);
        Map.forEach((_, ws) -> List.forEach(w -> if (isStaleWork(w)) Ref.get(w#build#made) |> Option.forEach(retire) else (), ws), works);
        Ref.put(works |> Map.map(List.filter(w -> not isStaleWork(w))) |> Map.filter(ws -> not List.isEmpty(ws)), cache#works);
        let live = (name: String) -> Map.memberOf(name, Ref.get(cache#entries)) or Map.memberOf(name, Ref.get(cache#works));
        Ref.put(Ref.get(cache#remakes) |> Map.filterWithKey((k, _) -> live(fst(k))), cache#remakes)

    /// 控えの物と作りかけを全部 retire へ渡して外す（材質の番号が替わった時・描き手を手放す時）。
    pub def clear(cache: Cache[a], retire: a -> Unit \ ef): Unit \ ef + IO =
        Map.forEach((_, es) -> List.forEach(e -> retire(e#payload), es), Ref.get(cache#entries));
        Ref.put(Map.empty(), cache#entries);
        Map.forEach((_, ws) -> List.forEach(w -> Ref.get(w#build#made) |> Option.forEach(retire), ws), Ref.get(cache#works));
        Ref.put(Map.empty(), cache#works);
        Ref.put(Map.empty(), cache#remakes)

    /// 控えの物と、置いた後の作りかけ（上げる段）のうち、置いた物の isBroken が真の物を retire へ渡して外す（置き場が形か絵を捨てた時。isBroken = 捨てた番号を行が持つ）。
    /// 置く前の作りかけは残す（行と番号は Place で振るので、捨てた番号を持たない）。
    // WhyNot: 置き場が何か捨てたら控えと作りかけを全部外す、としない — 上限を超えたゲームでは関わりの無い絵が数コマごとに捨てられ、そのたびに描いている集まりと宣言の集まりを全部作り直す。
    // WhyNot: 始め直しの数（remakes）を消さない — 数は値が替わり続ける集まりを 1 コマで作る道へ移すための物で、置き場の都合で外した作りかけは値が替わったのではない。
    pub def clearWhere(cache: Cache[a], isBroken: a -> Bool \ ef, retire: a -> Unit \ ef): Unit \ ef + IO =
        let split = Ref.get(cache#entries) |> Map.map(List.partition(e -> isBroken(e#payload)));
        Map.forEach((_, parts) -> List.forEach(e -> retire(e#payload), fst(parts)), split);
        Ref.put(split |> Map.map(snd) |> Map.filter(es -> not List.isEmpty(es)), cache#entries);
        let isBrokenWork = (w: Work[a]) -> Ref.get(w#build#made) |> Option.exists(isBroken);
        let works = Ref.get(cache#works) |> Map.map(List.partition(isBrokenWork));
        Map.forEach((_, parts) -> List.forEach(w -> Ref.get(w#build#made) |> Option.forEach(retire), fst(parts)), works);
        Ref.put(works |> Map.map(snd) |> Map.filter(ws -> not List.isEmpty(ws)), cache#works)

    /// 控えにある集まりの物の数。
    pub def sizeOf(cache: Cache[a]): Int32 \ IO = Map.foldLeft((n, es) -> n + List.length(es), 0, Ref.get(cache#entries))

    /// 作りかけの集まりの数。
    pub def buildingCountOf(cache: Cache[a]): Int32 \ IO = Map.foldLeft((n, ws) -> n + List.length(ws), 0, Ref.get(cache#works))

    /// 控えにある物を全部 f に渡す（コマの終わりに backend が中の物を締める）。
    pub def forEachHeld(f: a -> Unit \ ef, cache: Cache[a]): Unit \ ef + IO =
        Map.forEach((_, es) -> List.forEach(e -> f(e#payload), es), Ref.get(cache#entries))
}
