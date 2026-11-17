// Render3d.StaticRows — 動かない物の集まり（Scene3d.staticGroup）の計画と描く行を、コマをまたいで持ち越す所（前半の側。GPU を呼ばない）。
// 集まりごとに 1 回だけ候補に分け、1 体ごとの値を詰め、色の pass の行（頂点の色と不透明の材質）と影の地図の行を作る（build）。backend は答えを GPU に置いて毎コマ描く。
// 同じ集まりかは、名前・staticGroup で作った items の値そのもの（参照）・外した鍵・tint で見る（中身は比べない・Cache）。
// 半透明（目から遠い順に毎コマ並べ直す）と骨つき（姿勢が毎コマ変わる）は持ち越さず、場面の計画へ通す（perFrameOf）。奥行きの書き出しの場面は全部を計画へ通す。
// WhyNot: 持ち越す物を視錐台で間引かない — 持ち越した行は目の位置に依らず、間引くと目が動くたびに作り直しになる（遠くを描かないのは、集まりを区画に分けてゲームが載せ外しする）。
// WhyNot: GL の backend から使わない — GL は集まりの物を instances の後ろに並べて今の道で描く（GL の絵を 1 bit も変えない）。
mod Render3d.StaticRows {
    import java.lang.Object
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.util.IdentityHashMap
    use Render3d.InstanceValues.{PackMode, floatsPerInstance, numberSpan}
    use Render3d.MaterialValues
    use Render3d.MeshTable
    use Render3d.ScenePlan.{MaterialRequest, Planner, groupCarried, materialsInOrder, splitGroups, warnOnce}
    use Render3d.SceneList.{SceneList, Tables, buildSceneList, buildShadowList, contextOf, flagSameBinding, hasFlag, headAt, rowCountOf, setValuesAt, valuesAt}

    // ── 持ち越す物と毎コマの物 ──

    /// 集まりの物 i を持ち越すか（半透明でも骨つきでもない物）。
    pub def isCarriedItem(i: Scene3d.Instance3d): Bool =
        not Scene3d.isBlendedFields(Scene3d.instanceFieldsOf(i)) and Option.isEmpty(Scene3d.skinningOf(i))

    /// 場面の計画へ通す物: 色の場面は instances と、持ち越した集まりの持ち越さない物（carried の perFrame）・奥行きの書き出しの場面は全部（Scene3d.instancesOf）。
    pub def perFrameOf(scene: Scene3d.Scene3dCmd, carried: List[CarriedRows]): List[Scene3d.Instance3d] = match scene#output {
        case Scene3d.Output.Depth(_) => Scene3d.instancesOf(scene)
        case Scene3d.Output.Color    => List.foldRight((c, acc) -> List.append(c#perFrame, acc), Nil, carried) |> List.append(scene#instances)
    }

    /// 場面に描く物が 1 つでもあるか（集まりは外していない鍵が 1 つでもあるか。先頭で止まり、描く物の列を作らない）。
    pub def hasDrawnItem(scene: Scene3d.Scene3dCmd): Bool =
        not List.isEmpty(scene#instances) or List.exists(g -> {
            let r = Scene3d.staticGroupFieldsOf(g);
            List.exists(kv -> not Set.memberOf(fst(kv), r#removed), r#items)
        }, scene#groups)

    /// 場面の置いた物の数（診断）。carried = 持ち越した集まり（色の場面）。奥行きの書き出しの場面は集まりの物も数える。
    pub def placedCountOf(scene: Scene3d.Scene3dCmd, carried: List[CarriedRows]): Int32 = match scene#output {
        case Scene3d.Output.Color    => List.length(scene#instances) + List.sumWith(c -> c#placed + List.length(c#perFrame), carried)
        case Scene3d.Output.Depth(_) => List.length(Scene3d.instancesOf(scene))
    }

    /// 場面の持ち越す集まり（色の場面だけ）。
    pub def carriedGroupsOf(scene: Scene3d.Scene3dCmd): List[Scene3d.StaticGroup] = match scene#output {
        case Scene3d.Output.Color    => scene#groups
        case Scene3d.Output.Depth(_) => Nil
    }

    // ── 行を作る ──

    /// 集まり 1 つの持ち越す行。list = 色の pass の行（頂点の色 → 不透明の材質。ビルボードと半透明の行は無い）・shadowList = 影の地図の行（形だけ）・
    /// instances = 1 体ごとの値（list と shadowList の行の欄 3 が頭からの番号で指す）・instanceCount = その体の数・requests = 行の欄 1 が引く材質の問い合わせ・
    /// timeAt = list の values の中の uTime の位置（値の区画ごとに 1 つ）・time = values に書いた時刻（要素 1 つ）・placed = 持ち越す物の数・
    /// meshSlots = 行の形の控え（毎コマ使った物にする）・perFrame = 集まりの持ち越さない物（半透明と骨つき。毎コマ場面の計画へ通す）。
    pub type alias CarriedRows = {
        list = SceneList, shadowList = SceneList, instances = ByteBuffer, instanceCount = Int32, requests = Vector[MaterialRequest],
        timeAt = Vector[Int32], time = Array[Float64, Static], placed = Int32, meshSlots = Vector[MeshTable.Slot], perFrame = List[Scene3d.Instance3d]
    }

    /// 集まり g の持ち越す物の行を作る。resolve = 材質の問い合わせに順の番号で答える（backend。0 なら頂点の色で描く）・scene = 絵の名前と時刻を引く場面。
    /// 形と絵の番号は tables で振る（GPU には作らない）。
    pub def build(planner: Planner, tables: Tables, resolve: Vector[MaterialRequest] -> Vector[Int32] \ ef, scene: Scene3d.Scene3dCmd,
                  g: Scene3d.StaticGroup): CarriedRows \ ef + IO =
        let (items, perFrame) = Scene3d.groupInstancesOf(g) |> List.partition(isCarriedItem);
        let (lit, shadow, requests, members) = groupCarried(planner, Render3d.shaderVariantOf(scene), items);
        let (plain, materials) = splitGroups(lit, resolve(requests));
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
          time = Array#{scene#time} @ Static, placed = List.length(items), meshSlots = slotsOf(tables, list, shadowList), perFrame = perFrame }

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

    // ── 持ち越しの控え ──

    /// 集まり 1 つの控え。items = staticGroup で作った items の値だけを鍵に持つ表（参照で比べる）・removed と tint = 作った時の外した鍵と色・
    /// payload = backend が置いた物・lastUsed = 最後に描いたコマの世代（要素 1 つ）。
    // WhyNot: items を Eq で比べない — 中身の比べは物の数だけ形と材質を辿り、持ち越しで省きたい仕事と同じ重さになる。
    type alias Entry[a] = { items = IdentityHashMap[Object, Object], removed = Set[String], tint = Color, payload = a, lastUsed = Array[Int64, Static] }

    /// 持ち越しの控え（a = backend が GPU に置いた物）。entries = 集まりの名前 → 控えの列（同じ名前でも中身の違う集まりを 1 コマに何場面かで描くと 2 つ以上）・
    /// rebuilds = 名前 → (最後に作り直した世代, 続けて作り直したコマの数)。
    pub type alias Cache[a] = { entries = Ref[Map[String, List[Entry[a]]], Static], rebuilds = Ref[Map[String, (Int64, Int32)], Static] }

    pub def freshCache(): Cache[a] \ IO =
        { entries = Ref.fresh(Static, Map.empty()), rebuilds = Ref.fresh(Static, Map.empty()) }

    /// この数のコマ続けて同じ名前の集まりを作り直したら、1 回知らせる。
    def rebuildStreakLimit(): Int32 = 30

    /// 集まり g の持ち越した物。名前・items の値・外した鍵・tint が同じ控えがあればその物、無ければ build で作る（重い）。gen = 今のコマの世代。
    /// 作る時は、同じ名前の控えのうち今のコマで使っていない物を retire へ渡す（今のコマで使った物は、ほかの場面が描くので残す）。
    pub def ensure(planner: Planner, cache: Cache[a], gen: Int64, g: Scene3d.StaticGroup, make: Unit -> a \ ef1, retire: a -> Unit \ ef2): a \ ef1 + ef2 + IO =
        let f = Scene3d.staticGroupFieldsOf(g);
        let items = unchecked_cast(f#items as Object);
        let held = Map.getWithDefault(f#name, Nil, Ref.get(cache#entries));
        match List.find(e -> isSameGroup(f, e) and e#items.containsKey(items), held) {
            case Some(e) =>
                Array.put(gen, 0, e#lastUsed);
                e#payload
            case None =>
                let (usedNow, idle) = List.partition(e -> Array.get(0, e#lastUsed) == gen, held);
                List.forEach(e -> retire(e#payload), idle);
                noteRebuild(planner, cache, gen, f#name);
                let key: IdentityHashMap[Object, Object] = new IdentityHashMap();
                discard key.put(items, items);
                let made = { items = key, removed = f#removed, tint = f#tint, payload = make(), lastUsed = Array#{gen} @ Static };
                Ref.put(Map.insert(f#name, made :: usedNow, Ref.get(cache#entries)), cache#entries);
                made#payload
        }

    /// 控え e の外した鍵と色が f と同じか（items の参照は呼ぶ側が比べる）。
    def isSameGroup(f: Scene3d.StaticGroupFields, e: Entry[a]): Bool =
        f#removed == e#removed and f#tint#r == e#tint#r and f#tint#g == e#tint#g and f#tint#b == e#tint#b

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

    /// idle のコマより長く描かなかった集まりの物を retire へ渡して控えから外す。
    pub def sweep(cache: Cache[a], gen: Int64, idle: Int64, retire: a -> Unit \ ef): Unit \ ef + IO =
        let isStale = (e: Entry[a]) -> Array.get(0, e#lastUsed) + idle < gen;
        let all = Ref.get(cache#entries);
        Map.forEach((_, es) -> List.forEach(e -> if (isStale(e)) retire(e#payload) else (), es), all);
        Ref.put(all |> Map.map(List.filter(e -> not isStale(e))) |> Map.filter(es -> not List.isEmpty(es)), cache#entries)

    /// 控えの物を全部 retire へ渡して外す（持ち越した行の形か絵の番号を置き場が捨てた時・描き手を手放す時）。
    pub def clear(cache: Cache[a], retire: a -> Unit \ ef): Unit \ ef + IO =
        Map.forEach((_, es) -> List.forEach(e -> retire(e#payload), es), Ref.get(cache#entries));
        Ref.put(Map.empty(), cache#entries)

    /// 控えにある集まりの物の数。
    pub def sizeOf(cache: Cache[a]): Int32 \ IO = Map.foldLeft((n, es) -> n + List.length(es), 0, Ref.get(cache#entries))

    /// 控えにある物を全部 f に渡す（コマの終わりに backend が中の物を締める）。
    pub def forEachHeld(f: a -> Unit \ ef, cache: Cache[a]): Unit \ ef + IO =
        Map.forEach((_, es) -> List.forEach(e -> f(e#payload), es), Ref.get(cache#entries))
}
