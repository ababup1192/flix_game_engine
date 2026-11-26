// App.Internal.AutoPreload — View が返した 3D の場面に載った staticGroup を描き手への先に作る宣言へ足す所（App.withAutoPreload3d）。
// 初めて出た名前は済むまで場面から外し、Cover なら design 全体を黒で覆う。宣言（withPreload3d）の groups の名前も、一度済むまでは同じに外して黒で覆う。
// 一度済んだ名前は、View から消えても keepFrames の間は宣言に載せ続け、描き手に控えを手放させない（戻った時に外しも黒も無い）。
// 値が替わった名前は新しい値を宣言に載せ、場面にも新しい値を渡す（描き手が作り終えるまで前の控えを描く・Render3d.StaticRows.ensure）。
// 載せ続けるのをやめた名前がまた出た時は、黒にせず済むまで外すだけ。
// 1 コマは prepare（宣言を組む）→ 描き手の preload3d → settle（外す名前と黒を決める）の順。
// ゲームからは呼ばない（App の中身）。
pub mod App.Internal.AutoPreload {
    import java.lang.{Object => JObject}
    import java.lang.ref.WeakReference

    /// 自動の表の名前 1 つ。Building = 作っている（宣言に足す値・その値の通し番号・まだ一度も済んでいない名前か）・
    /// Ready = 作り終えた（宣言に載せ続ける値・その値の通し番号・最後に View に出たコマ）。
    enum Entry {
        case Building(Scene3d.StaticGroup, Int32, Bool)
        case Ready(Scene3d.StaticGroup, Int32, Int64)
    }

    /// コマをまたいで持ち回す状態（欄の意味は StateRec）。
    enum StateOf(StateRec)

    pub type alias State = StateOf

    /// frame = 数えたコマ・entries = 自動の表（宣言に無い名前）・serial = 次に振る値の通し番号・known = 一度でも済んだ自動の名前・
    /// scenes = 自動の名前を描いた場面の版（版の字 → (最後に描いたコマ, groups を空にした場面)）・
    /// declKey・declNames・declVariants = 最後に読んだ宣言の key と、その groups の名前と scenes の版・declReady = 一度済んだ宣言の名前・
    /// covering = 前のコマで黒を出したか・changes = 名前か値が替わったコマ（新しい順・300 コマの内）・off = 止めたか・lastGen = 前のコマの Doc の世代。
    // WhyNot: known を忘れない — 名前の字だけで軽い。忘れると、載せ続けるのをやめた名前がまた出た時に初めての名前と見分けられず黒になる。
    type alias StateRec = {
        frame = Int64, entries = Map[String, Entry], serial = Int32, known = Set[String], scenes = Map[String, (Int64, Scene3d.Scene3dCmd)],
        declKey = Option[String], declNames = Set[String], declVariants = Set[String], declReady = Set[String],
        covering = Bool, changes = List[Int64], off = Bool, lastGen = Int32
    }

    /// 何も見ていない起動時の状態。
    pub def fresh(): State = StateOf.StateOf({
        frame = 0i64, entries = Map.empty(), serial = 0, known = Set.empty(), scenes = Map.empty(),
        declKey = None, declNames = Set.empty(), declVariants = Set.empty(), declReady = Set.empty(),
        covering = false, changes = Nil, off = false, lastGen = 0
    })

    def recOf(s: State): StateRec = { let StateOf.StateOf(r) = s; r }

    /// 作り終えた名前を、View に出なくなってから宣言に載せ続けるコマの数（60 コマで 30 秒）。
    // WhyNot: 実時間で数えない — prepare は時計を持たない純粋な関数で、描き手が控えを手放すのもコマの数（idleFrames）で数える。
    // WhyNot: 描き手の idleFrames（128 コマ）に近づけない — 階段や戸口から覗く階は数秒おきに出入りし、手放された後に戻ると作り終えるまでその階が欠ける。
    def keepFrames(): Int64 = 1800i64

    /// 載せ続ける作り終えた名前の数の上限（超えたら、View に出ていない物のうち出なくなって長い物から忘れる）。
    // WhyNot: 上限を置かない、にしない — 区画を順に載せる場面では、通った区画の控えが keepFrames の間ずっと GPU に残る。
    // WhyNot: もっと小さくしない — 階・部屋・区画の単位の名前（数個〜十数個）を持つ場面で、戻るたびに外れる名前が出ないように。
    def keepLimit(): Int32 = 64

    /// 名前か値が替わったコマを数える幅と、止める回数。
    // WhyNot: 30 回にしない — 描き手の @preload-key（300 コマに 30 回）が先に鳴り、「withPreload3d の key」を直せという誤った文が出る。
    def changeWindow(): Int64 = 300i64

    def changeLimit(): Int32 = 20

    /// prepare の答え。cmd = 描き手へ渡す宣言（宣言に自動の物を足した物）・seen = このコマの View に出た集まりの名前・
    /// stopped = このコマで自動を止めた（知らせを出す）。
    pub type alias Prepared = { cmd = Option[Scene3d.PreloadCmd], seen = Set[String], stopped = Bool, state = State }

    /// settle の答え。strip = 場面から外す集まりの名前・cover = design 全体を黒で覆うか。
    pub type alias Outcome = { strip = Set[String], cover = Bool, state = State }

    /// 場面 scene の版の字（色の場面は Scene3d.preloadVariantOf の字・奥行きの書き出しは既定の版）。
    /// WhyNot: 描き手の carriedKeyOf を使わない — render_gl にあって engine_world から呼べず、alpha to coverage の版は描き手が作る。
    pub def variantKeyOf(scene: Scene3d.Scene3dCmd): String = match scene#output {
        case Scene3d.Output.Color    => "color" + Scene3d.preloadVariantKey(Scene3d.preloadVariantOf(scene))
        case Scene3d.Output.Depth(_) => "depth"
    }

    /// items の中の 3D の場面（Clipped の中も）。
    pub def scenesOf(items: List[Render.PlacedItem]): List[Scene3d.Scene3dCmd] = items |> List.flatMap(pi -> scenesOfItem(pi#item))

    def scenesOfItem(item: Render.Item): List[Scene3d.Scene3dCmd] = match item {
        case Render.Item.Scene3d(cmd) => cmd :: Nil
        case Render.Item.Clipped(c)   => scenesOfItem(c#inner)
        case _                        => Nil
    }

    /// items の 3D の場面から、名前が names の集まりを外した物。
    pub def withoutGroups(names: Set[String], items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        items |> List.map(pi -> { item = stripItem(names, pi#item) | pi })

    def stripItem(names: Set[String], item: Render.Item): Render.Item = match item {
        case Render.Item.Scene3d(cmd) => Render.Item.Scene3d({ groups = cmd#groups |> List.filter(g -> not Set.memberOf(nameOf(g), names)) | cmd })
        case Render.Item.Clipped(c)   => Render.Item.Clipped({ inner = stripItem(names, c#inner) | c })
        case other                    => other
    }

    def nameOf(g: Scene3d.StaticGroup): String = Scene3d.staticGroupFieldsOf(g)#name

    /// a と b が同じ集まりか（items の参照・外した鍵・tint。描き手の StaticRows と同じ見方）。
    // WhyNot: items の中身を比べない — 中身の比べは先に作って省きたい仕事と同じ重さになる。
    def isSameGroup(a: Scene3d.StaticGroup, b: Scene3d.StaticGroup): Bool =
        let fa = Scene3d.staticGroupFieldsOf(a);
        let fb = Scene3d.staticGroupFieldsOf(b);
        isSameRef(fa#items, fb#items) and fa#removed == fb#removed and fa#tint#r == fb#tint#r and fa#tint#g == fb#tint#g and fa#tint#b == fb#tint#b

    // WhyNot: Objects.equals で比べない — Flix の値が equals を中身の比べにした時に、木を辿る比べへ黙って戻る。
    def isSameRef(a: x, b: x): Bool =
        unsafe IO {
            let held = new WeakReference(unchecked_cast(a as JObject));
            held.refersTo(unchecked_cast(b as JObject))
        }

    /// このコマの宣言を組む。declared = withPreload3d の宣言（key に Doc の世代を足した物）・docGen = Doc の世代・
    /// scenes = このコマの View が返した 3D の場面（本編と Pass）。宣言の groups と scenes は key が替わったコマだけ読む。
    pub def prepare(declared: Option[Scene3d.PreloadCmd], docGen: Int32, scenes: List[Scene3d.Scene3dCmd], state: State): Prepared =
        let s0 = recOf(state);
        let frame = s0#frame + 1i64;
        let s1 = { frame = frame, lastGen = docGen | withDeclared(declared, s0) };
        let seenGroups = scenes |> List.foldLeft((acc, scene) ->
            scene#groups |> List.foldLeft((m, g) -> if (Map.memberOf(nameOf(g), m)) m else Map.insert(nameOf(g), g, m), acc),
            (Map.empty(): Map[String, Scene3d.StaticGroup]));
        let seen = Map.keysOf(seenGroups);
        if (s1#off) { cmd = declared, seen = seen, stopped = false, state = StateOf.StateOf(s1) }
        else {
            let (s2, changed) = updateEntries(seenGroups, s1);
            let counted = if (changed and docGen == s0#lastGen) frame :: s2#changes else s2#changes;
            let changes = counted |> List.filter(f -> frame - f < changeWindow());
            if (List.length(changes) >= changeLimit())
                { cmd = declared, seen = seen, stopped = true,
                  state = StateOf.StateOf({ off = true, entries = Map.empty(), scenes = Map.empty(), changes = Nil | s2 }) }
            else {
                let s3 = { changes = changes, scenes = keptScenesOf(scenes, s2) | s2 };
                { cmd = withAuto(declared, s3), seen = seen, stopped = false, state = StateOf.StateOf(s3) }
            }
        }

    /// 宣言の key が替わっていれば、groups の名前と scenes の版を読み直した状態（自動の表から宣言の名前を外す）。
    def withDeclared(declared: Option[Scene3d.PreloadCmd], s: StateRec): StateRec = match declared {
        case None                                   => { declKey = None, declNames = Set.empty(), declVariants = Set.empty() | s }
        case Some(cmd) if Some(cmd#key) == s#declKey => s
        case Some(cmd)                              =>
            let names = (cmd#groups)() |> List.map(nameOf) |> List.toSet;
            { declKey = Some(cmd#key), declNames = names, declVariants = (cmd#scenes)() |> List.map(variantKeyOf) |> List.toSet,
              entries = s#entries |> Map.filterWithKey((name, _) -> not Set.memberOf(name, names)) | s }
    }

    /// View に出た集まり seen で自動の表を進めた状態と、名前か値が替わったか（載せ続ける間を過ぎた名前と、上限を超えた分は忘れる）。
    def updateEntries(seen: Map[String, Scene3d.StaticGroup], s: StateRec): (StateRec, Bool) =
        let frame = s#frame;
        let (entries, serial, changed) = Map.foldLeftWithKey((acc, name, g) -> {
            let (es, n, ch) = acc;
            if (Set.memberOf(name, s#declNames)) acc
            else match Map.get(name, es) {
                case Some(Entry.Ready(old, m, _)) if isSameGroup(old, g)    => (Map.insert(name, Entry.Ready(old, m, frame), es), n, ch)
                case Some(Entry.Ready(_, _, _))                             => (Map.insert(name, Entry.Ready(g, n, frame), es), n + 1, true)
                case Some(Entry.Building(old, _, _)) if isSameGroup(old, g) => acc
                case Some(Entry.Building(_, _, first))                      => (Map.insert(name, Entry.Building(g, n, first), es), n + 1, true)
                case None                                                   => (Map.insert(name, Entry.Building(g, n, not Set.memberOf(name, s#known)), es), n + 1, true)
            }
        }, (s#entries, s#serial, false), seen);
        ({ entries = keptEntriesOf(frame, entries), serial = serial | s }, changed)

    /// entries から、View に出なくなって keepFrames を過ぎた作り終えた名前と、作り終えた名前の数が keepLimit を超えた分
    /// （このコマに出ていない物のうち、出なくなって長い物から）を外した物。
    def keptEntriesOf(frame: Int64, entries: Map[String, Entry]): Map[String, Entry] =
        let alive = entries |> Map.filter(e -> match e {
            case Entry.Ready(_, _, last) => frame - last < keepFrames()
            case Entry.Building(_, _, _) => true
        });
        let readyCount = alive |> Map.count((_, e) -> isReady(e));
        let over = readyCount - keepLimit();
        if (over <= 0) alive
        else alive |> Map.toList |> List.filterMap(awayOf(frame)) |> Sort.sortStableBy(fst) |> List.take(over)
                   |> List.foldLeft((m, p) -> Map.remove(snd(p), m), alive)

    def isReady(e: Entry): Bool = match e {
        case Entry.Ready(_, _, _)    => true
        case Entry.Building(_, _, _) => false
    }

    /// 作り終えた名前のうち、このコマ（frame）の View に出ていない物の (最後に出たコマ, 名前)。
    def awayOf(frame: Int64, kv: (String, Entry)): Option[(Int64, String)] = match kv {
        case (name, Entry.Ready(_, _, last)) if last < frame => Some((last, name))
        case _                                              => None
    }

    /// 自動の名前を描いた場面の版を、このコマの scenes で進めた物（keepFrames の間に描かなかった版は外す）。
    // WhyNot: 作っている間だけ版を持つ、にしない — 載せ続ける名前を描く版が宣言から消えると、描き手がその版の控えを手放す。
    def keptScenesOf(scenes: List[Scene3d.Scene3dCmd], s: StateRec): Map[String, (Int64, Scene3d.Scene3dCmd)] =
        let frame = s#frame;
        let drawn = scenes |> List.foldLeft((acc, scene) ->
            if (scene#groups |> List.exists(g -> Map.memberOf(nameOf(g), s#entries))) Map.insert(variantKeyOf(scene), (frame, { groups = Nil | scene }), acc)
            else acc, s#scenes);
        drawn |> Map.filter(p -> frame - fst(p) < keepFrames())

    def groupOf(e: Entry): Scene3d.StaticGroup = match e {
        case Entry.Building(g, _, _) => g
        case Entry.Ready(g, _, _)    => g
    }

    def serialOf(e: Entry): Int32 = match e {
        case Entry.Building(_, n, _) => n
        case Entry.Ready(_, n, _)    => n
    }

    /// 宣言 declared に自動の表の集まり全部と、それを描いた場面の版のうち宣言の scenes に無い版を足した宣言（key に名前と値の通し番号と版を足す）。
    /// 自動の表が空なら declared のまま。
    // WhyNot: 宣言の場面に同じ版がある時に足さない — 描き手は groups × scenes の全部の組を作るので、宣言の集まり × 自動の場面の描かない行まで作って控えに残る。
    // WhyNot: View に出ている名前を宣言から外さない — 階段の際を行き来するだけで key が替わり、描き手が宣言を読み直し続ける。
    def withAuto(declared: Option[Scene3d.PreloadCmd], s: StateRec): Option[Scene3d.PreloadCmd] =
        if (Map.isEmpty(s#entries)) declared
        else {
            let base = declared |> Option.getWithDefault(Scene3d.preloadCmd("", () -> Nil));
            let wanted = s#scenes |> Map.filterWithKey((key, _) -> not Set.memberOf(key, s#declVariants));
            let names = s#entries |> Map.toList |> List.map(kv -> { let (name, e) = kv; "${name}#${serialOf(e)}" }) |> String.intercalate(",");
            let variants = Map.keysOf(wanted) |> Set.toList |> String.intercalate(",");
            let groups = Map.valuesOf(s#entries) |> List.map(groupOf);
            let scenes = Map.valuesOf(wanted) |> List.map(snd);
            Some({ key = base#key + "|auto:" + names + "|" + variants,
                   groups = () -> List.append((base#groups)(), groups),
                   scenes = () -> List.append((base#scenes)(), scenes) | base })
        }

    /// 作っている名前を、まだ一度も済んでいない物と、前に済んだ物に分けた物。
    def buildingNamesOf(s: StateRec): (Set[String], Set[String]) =
        s#entries |> Map.foldLeftWithKey((acc, name, e) -> match e {
            case Entry.Building(_, _, true)  => (Set.insert(name, fst(acc)), snd(acc))
            case Entry.Building(_, _, false) => (fst(acc), Set.insert(name, snd(acc)))
            case Entry.Ready(_, _, _)        => acc
        }, (Set.empty(), Set.empty()))

    def readyAt(frame: Int64, e: Entry): Entry = match e {
        case Entry.Building(g, n, _) => Entry.Ready(g, n, frame)
        case ready                   => ready
    }

    /// 描き手が返した進み具合 progress で、このコマに外す名前と黒を決める。cover = Cover の時に黒を出すか（PopIn は外すだけ）。
    /// 済んでいなければ、作っている名前と、まだ一度も済んでいない宣言の名前のうち View に出た物を外す。黒を出すのは、外す名前に
    /// まだ一度も済んでいない物がある時だけ。前のコマで黒を出していてこのコマで済んだら、集まりは載せて黒だけ残す（明けた後の初めてのコマの draw の仕事を黒の下で済ませる）。
    pub def settle(cover: Bool, progress: Scene3d.PreloadProgress, prepared: Prepared): Outcome =
        let s = recOf(prepared#state);
        let done = Scene3d.isPreloaded(progress);
        let (first, again) = buildingNamesOf(s);
        let pendingDeclared = Set.difference(Set.intersection(prepared#seen, s#declNames), s#declReady);
        let unseen = Set.union(first, pendingDeclared);
        let coverNow = cover and not done and not Set.isEmpty(unseen);
        let held = done and s#covering and not prepared#stopped;
        let next = if (not done) { covering = coverNow | s }
                   else { covering = false,
                          entries = s#entries |> Map.map(readyAt(s#frame)),
                          known = Set.union(s#known, Set.union(first, again)),
                          declReady = if (Option.isEmpty(s#declKey)) s#declReady else Set.union(s#declReady, s#declNames) | s };
        { strip = if (done) Set.empty() else Set.union(unseen, again), cover = coverNow or held, state = StateOf.StateOf(next) }

    /// 自動を止めた時の知らせ。
    pub def stoppedText(): String =
        "[scene3d] staticGroup の名前か値が 300 コマに 20 回替わった — 名前に時刻を混ぜていないか・毎コマ作り直していないか（集まりは読み込みで 1 回作って Resources に持つ）。" +
        "自動で先に作るのをやめ、描いたコマで作る（withPreload3d の宣言は有効なまま）"
}
