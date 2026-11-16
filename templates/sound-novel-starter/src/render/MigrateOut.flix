// MigrateOut — 移行の突き合わせ（bin/fge migrate diff）の記録: tape.json に足す欄（events・buses・frames・ranLines・screen）と
// restore.json を、flow を流した結果から作る（純粋）。欄の名前・型・書き手への約束は engine の docs/migrate-diff.md。
// コマの PNG は塗らず、どのフレームを・どの層で撮るかの予定だけを返す（塗るのは MIGRATE_OUT を渡した FlowVideo）。
//
// ranLines は実行器が流した文の所（World.Event.RanLines）を、流した時に集める（コマのシナリオの位置からは作らない）。
mod MigrateOut {
    use fge::{AudioMixer, Clock, Emit, Flow, Num, Resources, Vec2, Yarn, YarnRunner}
    use Util.Json.Json

    type alias AppState = Resources.With[Res.Res, World.World]

    /// コマの層。WorldLayer = 舞台だけ（View.worldLayer。文字の枠・HUD・UI を描かない）、AllLayers = 全部の層。
    pub enum Layer with Eq, ToString {
        case WorldLayer
        case AllLayers
    }

    /// 時間を取る命令の途中のコマ。cmd = 命令の名前、step = その台詞の後で何番目の時間を取る命令か（0 から）、
    /// at = 命令の秒に対する割合、seconds = 命令が取った秒。
    pub type alias Mid = { cmd = String, step = Int32, at = Float64, seconds = Float64 }

    /// 書き出すコマ 1 枚。frame = flow のフレームの番号、seq = 直前に出し終えた台詞の番号（まだなら -1）、mid = 途中のコマなら Some。
    pub type alias Shot = { frame = Int32, node = String, seq = Int32, mid = Option[Mid], layer = Layer }

    /// events の欄と、書き出すコマの予定。
    pub type alias Record = { events = List[Json], shots = List[Shot] }

    /// 載せる問い: 名前と、AppState からその値の JSON を読む物。
    pub type alias ProbeRow = (String, AppState -> Json)

    /// 途中のコマを撮る、命令の秒に対する割合。
    pub def midPoints(): List[Float64] = 0.25 :: 0.5 :: 0.75 :: Nil

    /// 層の名前（tape.json の layer・コマのフォルダの名前）。
    pub def layerName(layer: Layer): String = match layer {
        case Layer.WorldLayer => "world"
        case Layer.AllLayers  => "all"
    }

    /// コマの PNG の tape.json からの相対パス（FlowVideo が VideoOut で塗る名前と同じ）。
    pub def fileOf(shot: Shot): String = "frames/${layerName(shot#layer)}/f${String.padLeft(4, '0', Int32.toString(shot#frame))}.png"

    // ── 問い ──

    /// 載せる問い: fixed（E2e.table の probes の名前。知らない名前は Err）と、シナリオに宣言した変数の全部（`$名前`）。
    // WhyNot: 変数を名指しで並べない — ゲームのシナリオの変数がゲームごとに替わり、名指しの表から漏れた変数は門を通らない。
    pub def probeRowsOf(fixed: List[String], program: Yarn.Program): Result[String, List[ProbeRow]] =
        let reads = E2e.table()#probes |> List.map(row -> (row#name, row#read)) |> List.toMap;
        let named = fixed |> List.map(name -> match Map.get(name, reads) {
            case Some(read) => Ok((name, h -> TapeJson.valueJson(TapeJson.probeValue(read)(h))))
            case None       => Err("知らない問い '${name}'（E2e.table の probes の名前を書く）")
        }) |> Result.sequence;
        let variables = Yarn.variablesOf(program) |> List.map(match (name, initial) -> (name, (h: AppState) -> variableJson(name, initial, h#world)));
        named |> Result.map(rows -> List.append(rows, variables))

    /// 変数の今の値（読んでいない間は宣言の初めの値）。
    def variableJson(name: String, initial: Yarn.Value, w: World.World): Json =
        World.readOf(w) |> Option.flatMap(r -> YarnRunner.valueOf(name, r#talk)) |> Option.getWithDefault(initial) |> Yarn.valueToJson

    def probesJson(rows: List[ProbeRow], h: AppState): Map[String, Json] =
        rows |> List.map(match (name, read) -> (name, read(h))) |> List.toMap

    // ── 出来事の並びとコマの予定 ──

    /// フレームごとの World の出来事（フレームの番号つき・出た順）。
    def eventsOf(frames: List[Flow.Played[AppState]]): List[(Int32, World.Event)] =
        frames |> List.zipWithIndex |> List.flatMap(match (i, played) ->
            Emit.since(played#step#before#world#events, played#step#after#world#events) |> List.map(e -> (i, e)))

    /// 人が読み進めた間に反映した実行器の出来事（フレームの番号つき・出た順）。
    pub def executedOf(frames: List[Flow.Played[AppState]]): List[(Int32, World.Executed)] =
        eventsOf(frames) |> List.filterMap(match (i, e) -> executedIn(e) |> Option.map(x -> (i, x)))

    def executedIn(e: World.Event): Option[World.Executed] = match e {
        case World.Event.Executed(x) => Some(x)
        case _                       => None
    }

    /// ranLines の欄: 人が読み進めた間に実行器が流した文の所 (ファイル, 行)（重ねずに並べる）。
    pub def ranLinesOf(frames: List[Flow.Played[AppState]]): List[(String, Int32)] =
        eventsOf(frames) |> List.flatMap(match (_, e) -> ranIn(e)) |> List.toSet |> Set.toList

    def ranIn(e: World.Event): List[(String, Int32)] = match e {
        case World.Event.RanLines(sources) => sources
        case _                             => Nil
    }

    /// ranLines の欄の JSON（[{file, line}]）。
    pub def ranLinesJson(sources: List[(String, Int32)]): Json =
        Json.JArray(sources |> List.map(match (file, line) -> Json.JObject(Map#{ "file" => Json.JString(file), "line" => TapeJson.intJson(line) })) |> List.toVector)

    /// 出来事ごとに、それより後ろで最初に出来事が出たフレーム（無ければ None）。台詞を出し終えたコマはその 1 つ前のフレーム。
    def nextFramesOf(executed: List[(Int32, World.Executed)]): List[(Int32, World.Executed, Option[Int32])] =
        let (out, _) = List.foldRight((one, acc) -> {
            let (rows, right) = acc;
            let (f, x) = one;
            let later = match right {
                case Some((rf, rLater)) => if (rf > f) Some(rf) else rLater
                case None               => None
            };
            ((f, x, later) :: rows, Some((f, later)))
        }, (Nil, None), executed);
        out

    /// 持ち回す物: 出来事の JSON（新しい順）・コマの予定（新しい順）・ノードの訪問ごとの台詞の数と時間を取る命令の数・残りの選んだ所。
    type alias Walk = { events = List[Json], shots = List[Shot], lines = Map[(String, Int32), Int32], steps = Map[(String, Int32), Int32],
                        picks = List[TapeOut.Choice] }

    /// events の欄と、書き出すコマの予定。probes = 台詞ごとに載せる問い（probeRowsOf）。
    pub def recordOf(fps: Float64, probes: List[ProbeRow], frames: List[Flow.Played[AppState]]): Record =
        let worlds = frames |> List.map(played -> played#step#after) |> List.toVector;
        let start = { events = Nil, shots = Nil, lines = Map.empty(), steps = Map.empty(), picks = TapeOut.choicesOf(frames) };
        let walked = nextFramesOf(executedOf(frames)) |> List.foldLeft((walk, row) -> stepOf(fps, probes, worlds, row, walk), start);
        { events = List.reverse(walked#events), shots = List.reverse(walked#shots) }

    def stepOf(fps: Float64, probes: List[ProbeRow], worlds: Vector[AppState], row: (Int32, World.Executed, Option[Int32]), walk: Walk): Walk =
        let (f, x, later) = row;
        let t = TapeJson.secondsAt(fps, f);
        match x {
            case World.Executed.Said((node, visit, _), who, text) =>
                let key = (node, visit);
                let seq = Map.getWithDefault(key, 0, walk#lines);
                let done = Int32.min(Vector.length(worlds) - 1, Option.getWithDefault(Vector.length(worlds), later) - 1);
                let settled = Vector.nth(done, worlds) |> Option.filter(h -> Page.isDone(World.pageOf(h#world)));
                let shown = Vector.nth(done, worlds) |> Option.map(h -> probesJson(probes, h)) |> Option.getWithDefault(Map.empty());
                let event = Json.JObject(Map#{ "t" => TapeJson.numJson(t), "node" => Json.JString(node), "kind" => Json.JString("line"),
                                              "seq" => TapeJson.intJson(seq), "who" => Json.JString(who), "text" => Json.JString(text),
                                              "probes" => Json.JObject(shown) });
                let shots = settled |> Option.map(_ ->
                    { frame = done, node = node, seq = seq, mid = None, layer = Layer.WorldLayer } ::
                    { frame = done, node = node, seq = seq, mid = None, layer = Layer.AllLayers } :: Nil) |> Option.getWithDefault(Nil);
                { events = event :: walk#events, shots = List.append(List.reverse(shots), walk#shots),
                  lines = Map.insert(key, seq + 1, walk#lines), steps = Map.insert(key, 0, walk#steps) | walk }
            case World.Executed.Offered((node, visit, _), options) =>
                let seq = Map.getWithDefault((node, visit), 0, walk#lines);
                let (picked, rest) = pickOf(node, options, walk#picks);
                let base = Map#{ "t" => TapeJson.numJson(t), "node" => Json.JString(node), "kind" => Json.JString("choice"), "seq" => TapeJson.intJson(seq),
                                 "options" => Json.JArray(options |> List.map(Json.JString) |> List.toVector) };
                let fields = picked |> Option.map(i -> Map.insert("picked", TapeJson.intJson(i), base)) |> Option.getWithDefault(base);
                { events = Json.JObject(fields) :: walk#events, picks = rest | walk }
            case World.Executed.Commanded((node, visit, _), name, args, timed, seconds) =>
                let key = (node, visit);
                let seq = Map.getWithDefault(key, 0, walk#lines);
                let waited = if (name == "wait") List.head(args) |> Option.flatMap(Float64.fromString) else None;
                let events = waited |> Option.map(s -> Json.JObject(Map#{ "t" => TapeJson.numJson(t), "node" => Json.JString(node), "kind" => Json.JString("wait"),
                                                                          "seq" => TapeJson.intJson(seq), "seconds" => TapeJson.numJson(s) }) :: walk#events)
                    |> Option.getWithDefault(walk#events);
                if (timed) midsOf(worlds, f, key, name, seq, seconds, { events = events | walk }) else { events = events | walk }
        }

    /// 時間を取る命令 1 つ: その台詞の後の時間を取る命令の数を 1 つ進め、秒が分かれば途中のコマ（midPoints の所・world の層だけ）を予定に足す。
    // WhyNot: 秒の分からない命令を数から外さない — 移行で片方の版だけ秒が分かる形になると、後ろの命令の step が全部ずれて鍵が組めなくなる。
    def midsOf(worlds: Vector[AppState], f: Int32, key: (String, Int32), name: String, seq: Int32, seconds: Option[Float64], walk: Walk): Walk =
        let step = Map.getWithDefault(key, 0, walk#steps);
        let mids = seconds |> Option.map(s -> midPoints() |> List.filterMap(share -> frameAfter(worlds, f, share * s) |> Option.map(j ->
            { frame = j, node = fst(key), seq = seq - 1, mid = Some({ cmd = name, step = step, at = share, seconds = s }), layer = Layer.WorldLayer })))
            |> Option.getWithDefault(Nil);
        { shots = List.append(List.reverse(mids), walk#shots), steps = Map.insert(key, step + 1, walk#steps) | walk }

    /// 選択肢 2 つ以上を選んだ所を、出た順に 1 つずつ当てる（同じノードの物だけ）。選ばずに終わった選択肢は None。
    def pickOf(node: String, options: List[String], picks: List[TapeOut.Choice]): (Option[Int32], List[TapeOut.Choice]) =
        match picks {
            case c :: rest if List.length(options) >= 2 and c#node == node and c#options == options => (Some(c#picked), rest)
            case _ => (None, picks)
        }

    /// フレーム first の物語の時刻から seconds 経った最初のフレーム（流し終えるまでに来なければ None）。
    def frameAfter(worlds: Vector[AppState], first: Int32, seconds: Float64): Option[Int32] =
        Vector.nth(first, worlds) |> Option.flatMap(h0 -> {
            let t0 = World.now(h0#world);
            Vector.range(first, Vector.length(worlds)) |> Vector.find(j ->
                Vector.nth(j, worlds) |> Option.exists(h -> Clock.since(t0, World.now(h#world)) >= seconds))
        })

    /// frames の欄（書き出したコマ）。
    pub def framesJson(fps: Float64, shots: List[Shot]): Json =
        Json.JArray(shots |> List.map(shot -> frameJson(TapeJson.secondsAt(fps, shot#frame), shot)) |> List.toVector)

    def frameJson(t: Float64, shot: Shot): Json =
        let base = Map#{ "file" => Json.JString(fileOf(shot)), "t" => TapeJson.numJson(t), "node" => Json.JString(shot#node),
                         "seq" => TapeJson.intJson(shot#seq), "layer" => Json.JString(layerName(shot#layer)) };
        let fields = match shot#mid {
            case Some(m) => base |> Map.insert("kind", Json.JString("mid")) |> Map.insert("cmd", Json.JString(m#cmd))
                                 |> Map.insert("step", TapeJson.intJson(m#step)) |> Map.insert("at", TapeJson.numJson(m#at))
                                 |> Map.insert("seconds", TapeJson.numJson(m#seconds))
            case None    => Map.insert("kind", Json.JString("lineDone"), base)
        };
        Json.JObject(fields)

    /// screen の欄（design の px）。
    pub def screenJson(design: Vec2.Vec2): Json = Json.JObject(Map#{ "w" => TapeJson.numJson(design#x), "h" => TapeJson.numJson(design#y) })

    // ── バスの音量 ──

    /// buses の欄: ミキサー（Controls.mixerOf が World と Res から作る）を実機と同じ AudioMixer.step で 1 フレームずつ進め、
    /// バスの音量の倍率（バスの今の音量 × ダッキング）を dB にして、変わったフレームだけ [秒, dB] に（無音は null）。
    /// lengthOf = 音の長さ（秒。ダッキングが鳴っている間を知るのに使う）。ミキサーにバスが 1 本も無ければ None（欄ごと出さない）。
    pub def busesJson(fps: Float64, lengthOf: String -> Float64, frames: List[Flow.Played[AppState]]): Option[Json] =
        let dt = 1.0 / fps;
        let (_, _, rows) = frames |> List.zipWithIndex |> List.foldLeft((acc, pair) -> {
            let (state, last, out) = acc;
            let (i, played) = pair;
            let mixer = Resources.read(Controls.mixerOf, played#step#after);
            let living = played#step#sustained |> List.map(s -> s#name) |> List.distinct;
            let (_, next) = AudioMixer.step(mixer, lengthOf, dt, played#step#sounds, living, state);
            let changed = mixer#buses |> List.map(bus -> (bus#name, decibelsOf(AudioMixer.busGainOf(mixer, next, bus#name))))
                |> List.filter(match (name, db) -> Map.get(name, last) != Some(db));
            let t = TapeJson.secondsAt(fps, i);
            (next, List.foldLeft((m, p) -> Map.insert(fst(p), snd(p), m), last, changed),
             List.foldLeft((m, p) -> Map.insertWith((a, b) -> a ::: b, fst(p), (t, snd(p)) :: Nil, m), out, changed))
        }, (AudioMixer.initial(), Map.empty(), Map.empty()));
        if (Map.isEmpty(rows)) None
        else Some(Json.JObject(rows |> Map.map(points -> Json.JArray(List.reverse(points) |> List.map(match (t, db) ->
            Json.JArray(Vector#{ TapeJson.numJson(t), db |> Option.map(TapeJson.numJson) |> Option.getWithDefault(Json.JNull) })) |> List.toVector))))

    /// 倍率を dB（小数 2 桁）に。無音は None。
    def decibelsOf(gain: Float64): Option[Float64] =
        if (gain <= 0.0) None
        else Some(Float64.round(20.0 * Num.log(gain) / Num.log(10.0) * 100.0) / 100.0)

    // ── 古いセーブの読み戻し ──

    /// 読み戻した直後の台詞の番号: 今のノードに入ってから送った数（ブックマークの Advance の数。入り直すと 0 から。events の seq と同じ数え方）。
    pub def restoredSeqOf(w: World.World): Int32 =
        World.readOf(w) |> Option.flatMap(r -> YarnRunner.bookmarkOf(r#talk))
            |> Option.map(b -> b#steps |> List.count(step -> step == YarnRunner.Action.Advance)) |> Option.getWithDefault(-1)

    /// restore.json の文字。save = セーブの名前、node・seq = 戻った所、h = 読み戻した直後、shots = 書き出したコマ、objects = 出ている物。
    pub def restoreJson(save: String, probes: List[ProbeRow], design: Vec2.Vec2, node: String, seq: Int32, h: AppState,
                        shots: List[Shot], objects: List[TapeOut.Span]): String =
        Util.Json.toPrettyString(2, Json.JObject(Map#{
            "save" => Json.JString(save),
            "refused" => Json.JBool(false),
            "node" => Json.JString(node),
            "seq" => TapeJson.intJson(seq),
            "probes" => Json.JObject(probesJson(probes, h)),
            "objects" => Json.JArray(objects |> List.map(TapeOut.spanJson) |> List.toVector),
            "frames" => framesJson(30.0, shots),
            "screen" => screenJson(design)
        })) + "\n"
}
