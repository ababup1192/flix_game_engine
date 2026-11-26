// App.Internal.AutoPreload — View が返した 3D の場面に載った staticGroup のうち、まだ作り終えていない名前を描き手への先に作る宣言へ足し、
// 済むまで場面から外す所（App.withAutoPreload3d。Cover なら design 全体を黒で覆う）。宣言（withPreload3d）の groups の名前も、一度済むまでは同じに外す。
// 1 コマは prepare（宣言を組む）→ 描き手の preload3d → settle（外す名前と黒を決める）の順。
// ゲームからは呼ばない（App の中身）。
pub mod App.Internal.AutoPreload {
    import java.lang.{Object => JObject}
    import java.lang.ref.WeakReference

    /// 自動の表の名前 1 つ。Building = 作っている（宣言に足す値と、その値の通し番号）・Ready = 作り終えた（最後に View に出たコマ）。
    enum Entry {
        case Building(Scene3d.StaticGroup, Int32)
        case Ready(Int64)
    }

    /// コマをまたいで持ち回す状態（欄の意味は StateRec）。
    enum StateOf(StateRec)

    pub type alias State = StateOf

    /// frame = 数えたコマ・entries = 自動の表（宣言に無い名前）・serial = 次に振る値の通し番号・
    /// autoScenes = 自動で足す場面（版の字 → groups を空にした場面）・
    /// declKey・declNames・declVariants = 最後に読んだ宣言の key と、その groups の名前と scenes の版・declReady = 一度済んだ宣言の名前・
    /// waiting = 前のコマで集まりを外したか・changes = 名前か値が替わったコマ（新しい順・300 コマの内）・off = 止めたか・lastGen = 前のコマの Doc の世代。
    type alias StateRec = {
        frame = Int64, entries = Map[String, Entry], serial = Int32, autoScenes = Map[String, Scene3d.Scene3dCmd],
        declKey = Option[String], declNames = Set[String], declVariants = Set[String], declReady = Set[String],
        waiting = Bool, changes = List[Int64], off = Bool, lastGen = Int32
    }

    /// 何も見ていない起動時の状態。
    pub def fresh(): State = StateOf.StateOf({
        frame = 0i64, entries = Map.empty(), serial = 0, autoScenes = Map.empty(),
        declKey = None, declNames = Set.empty(), declVariants = Set.empty(), declReady = Set.empty(),
        waiting = false, changes = Nil, off = false, lastGen = 0
    })

    def recOf(s: State): StateRec = { let StateOf.StateOf(r) = s; r }

    /// 作り終えた名前を忘れるまでの、View に出なかったコマの数。
    // WhyNot: 描き手が控えを手放す 128 コマ（idleFrames）より長くしない — 手放された後にまた出ると、前の控えが無いので ensure がそのコマで全部作って止まる。
    def forgetAfter(): Int64 = 120i64

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
                  state = StateOf.StateOf({ off = true, entries = Map.empty(), autoScenes = Map.empty(), changes = Nil | s2 }) }
            else {
                let s3 = { changes = changes, autoScenes = autoScenesOf(scenes, s2) | s2 };
                { cmd = withBuilding(declared, s3), seen = seen, stopped = false, state = StateOf.StateOf(s3) }
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

    /// View に出た集まり seen で自動の表を進めた状態と、名前か値が替わったか（作り終えて出なくなった名前は忘れる）。
    def updateEntries(seen: Map[String, Scene3d.StaticGroup], s: StateRec): (StateRec, Bool) =
        let frame = s#frame;
        let (entries, serial, changed) = Map.foldLeftWithKey((acc, name, g) -> {
            let (es, n, ch) = acc;
            if (Set.memberOf(name, s#declNames)) acc
            else match Map.get(name, es) {
                case Some(Entry.Ready(_))                                  => (Map.insert(name, Entry.Ready(frame), es), n, ch)
                case Some(Entry.Building(old, _)) if isSameGroup(old, g)   => acc
                case _                                                     => (Map.insert(name, Entry.Building(g, n), es), n + 1, true)
            }
        }, (s#entries, s#serial, false), seen);
        let kept = entries |> Map.filter(e -> match e {
            case Entry.Ready(last) => frame - last < forgetAfter()
            case Entry.Building(_, _) => true
        });
        ({ entries = kept, serial = serial | s }, changed)

    /// 作っている名前を描く場面の版のうち、宣言の scenes にも自動の場面にもまだ無い版を足した自動の場面（作っている名前が無ければ空）。
    // WhyNot: 宣言の場面に同じ版がある時に足さない — 描き手は groups × scenes の全部の組を作るので、宣言の集まり × 自動の場面の描かない行まで作って控えに残る。
    def autoScenesOf(scenes: List[Scene3d.Scene3dCmd], s: StateRec): Map[String, Scene3d.Scene3dCmd] =
        let building = buildingOf(s);
        if (Map.isEmpty(building)) Map.empty()
        else scenes |> List.foldLeft((acc, scene) -> {
            let key = variantKeyOf(scene);
            let wanted = scene#groups |> List.exists(g -> Map.memberOf(nameOf(g), building));
            if (not wanted or Set.memberOf(key, s#declVariants) or Map.memberOf(key, acc)) acc
            else Map.insert(key, { groups = Nil | scene }, acc)
        }, s#autoScenes)

    def buildingOf(s: StateRec): Map[String, (Scene3d.StaticGroup, Int32)] =
        s#entries |> Map.filterMap(e -> match e {
            case Entry.Building(g, n) => Some((g, n))
            case Entry.Ready(_)       => None
        })

    /// 宣言 declared に作っている名前の集まりと自動の場面を足した宣言（key に名前と値の通し番号と版を足す）。作っている名前が無ければ declared のまま。
    def withBuilding(declared: Option[Scene3d.PreloadCmd], s: StateRec): Option[Scene3d.PreloadCmd] =
        let building = buildingOf(s);
        if (Map.isEmpty(building)) declared
        else {
            let base = declared |> Option.getWithDefault(Scene3d.preloadCmd("", () -> Nil));
            let names = building |> Map.toList |> List.map(kv -> { let (name, (_, n)) = kv; "${name}#${n}" }) |> String.intercalate(",");
            let variants = Map.keysOf(s#autoScenes) |> Set.toList |> String.intercalate(",");
            let groups = Map.valuesOf(building) |> List.map(fst);
            let scenes = Map.valuesOf(s#autoScenes);
            Some({ key = base#key + "|auto:" + names + "|" + variants,
                   groups = () -> List.append((base#groups)(), groups),
                   scenes = () -> List.append((base#scenes)(), scenes) | base })
        }

    /// 描き手が返した進み具合 progress で、このコマに外す名前と黒を決める。cover = Cover の時に黒を出すか（PopIn は外すだけ）。
    /// 済んでいなければ、作っている名前と、まだ一度も済んでいない宣言の名前のうち View に出た物を外す。前のコマで外していてこのコマで済んだら、
    /// 集まりは載せて黒だけ残す（明けた後の初めてのコマの draw の仕事を黒の下で済ませる）。
    pub def settle(cover: Bool, progress: Scene3d.PreloadProgress, prepared: Prepared): Outcome =
        let s = recOf(prepared#state);
        let done = Scene3d.isPreloaded(progress);
        let building = Map.keysOf(buildingOf(s));
        let pendingDeclared = Set.difference(Set.intersection(prepared#seen, s#declNames), s#declReady);
        let pending = Set.union(building, pendingDeclared);
        let waiting = not done and not Set.isEmpty(pending);
        let held = done and s#waiting and not prepared#stopped;
        let next = if (not done) { waiting = waiting | s }
                   else { waiting = false, autoScenes = Map.empty(),
                          entries = s#entries |> Map.map(e -> match e {
                              case Entry.Building(_, _) => Entry.Ready(s#frame)
                              case ready                => ready
                          }),
                          declReady = if (Option.isEmpty(s#declKey)) s#declReady else Set.union(s#declReady, s#declNames) | s };
        { strip = if (waiting) pending else Set.empty(), cover = cover and (waiting or held), state = StateOf.StateOf(next) }

    /// 自動を止めた時の知らせ。
    pub def stoppedText(): String =
        "[scene3d] staticGroup の名前か値が 300 コマに 20 回替わった — 名前に時刻を混ぜていないか・毎コマ作り直していないか（集まりは読み込みで 1 回作って Resources に持つ）。" +
        "自動で先に作るのをやめ、描いたコマで作る（withPreload3d の宣言は有効なまま）"
}
