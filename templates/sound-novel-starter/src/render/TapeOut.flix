// TapeOut — flow を流した結果（Flow.Outcome）から、テープの頁が読む tape.json の文字を作る（純粋）。
// 書くのは FlowVideo（debug/video/<名前>/tape.json）。欄の名前・型・単位は plans/tape/mock.html の TAPE に合わせる。
// commit・video・strip・stripPerSec は束ねる側（bin/fge tape）が足すので、ここでは書かない。
mod TapeOut {
    use fge::{Color, Flow, JsonCodec, Rect2, Resources, Sort, Vec2, Yarn}
    use Util.Json.Json

    /// App の w（描く元と World の組）。
    type alias AppState = Resources.With[Res.Res, World.World]

    /// メッセージウィンドウの寸法（テープの頁が直した台詞を重ねる所）。x0 / x1 = 字の左右の端（画面の幅に対する割合）、
    /// cy = ウィンドウの縦の真ん中、lh = 行の高さ、padTop / padBot = 最初の行の字の下端までと最後の行の下の空き、
    /// font = 字の大きさ（ここまでは画面の高さに対する割合）、cps = 1 秒に出す字の数、
    /// when = 重ねてよいフレームの条件（問いの名前 → 値。全部そろう時だけ重ねる。空ならいつでも）。
    pub type alias Msg = { x0 = Float64, x1 = Float64, cy = Float64, lh = Float64, padTop = Float64, padBot = Float64, font = Float64, cps = Float64,
                           when = Map[String, String] }

    /// 画面に出ている物 1 つ。id = 物の名前（同じ物は同じ id。メッセージウィンドウは message）、name = 人に見せる名前、rect = design の px。
    pub type alias ScreenObject = { id = String, name = String, rect = Rect2.Rect2 }

    /// 同じ物が続いて出ていた間。startAt / endAt = 秒（tape.json の from / to。endAt のフレームにはもう出ていない）、rect = 画面に対する割合（左上が 0,0・小数 3 桁）。
    pub type alias Span = { id = String, name = String, startAt = Float64, endAt = Float64, rect = Fraction }

    /// 画面に対する割合の矩形。
    pub type alias Fraction = { x = Float64, y = Float64, w = Float64, h = Float64 }

    /// ゲームが渡す表。title = 題名、sceneNames = flow の mark の名前 → 人に見せる名前（無ければ mark の名前）、
    /// soundLabels = 音の素材の論理名 → 人に見せる名前（無ければ論理名）、hiddenSounds = 載せない音（UI の返事など）、
    /// msg = メッセージウィンドウの寸法、probes = 載せる flow の問いの名前、probeNames = 問いの表示名の上書き
    /// （無ければ問いの doc の頭）、playUrl = 遊べる所の URL（無ければ空）、objects = そのフレームの画面に出ている物。
    pub type alias Table = {
        title = String,
        sceneNames = Map[String, String],
        soundLabels = Map[String, String],
        hiddenSounds = Set[String],
        msg = Msg,
        probes = List[String],
        probeNames = Map[String, String],
        playUrl = String,
        objects = AppState -> List[ScreenObject]
    }

    /// 流した 1 回。game = ゲームのフォルダ名、flow = flow のパス、fps = flow の fps、design = 画面の大きさ（物の矩形を割る）、
    /// marks = flow に書いた mark の名前（書いた順。同じ名前は数えて止めるため Outcome の Map とは別に持つ）、outcome = 流した結果（途中で止まった時はそこまで）。
    pub type alias Run = { game = String, flow = String, fps = Float64, design = Vec2.Vec2, marks = List[String], outcome = Flow.Outcome[AppState] }

    /// tape.json の文字。同じ名前の mark・ノードをまたぐ flow・知らない問いは Err（理由の 1 行）。
    pub def toJson(table: Table, flowRun: Run): Result[String, String] =
        let frames = flowRun#outcome#frames;
        let worlds = frames |> List.map(played -> played#step#after);
        let res = flowRun#outcome#last#resources;
        let cursors = worlds |> List.map(h -> World.talkCursorOf(h#world));
        forM (
            _      <- uniqueMarks(flowRun#marks);
            node   <- singleNode(worlds);
            _      <- msgWhenKnown(table);
            probes <- probesOf(table, flowRun#fps, worlds)
        ) yield {
            let yarn = yarnOf(node, cursors, res);
            let timeOf = i -> secondsAt(flowRun#fps, i);
            Util.Json.toPrettyString(2, Json.JObject(Map#{
                "game" => Json.JString(flowRun#game),
                "title" => Json.JString(table#title),
                "flow" => Json.JString(flowRun#flow),
                "fps" => intJson(Float64.tryToInt32(Float64.round(flowRun#fps)) |> Option.getWithDefault(30)),
                "duration" => numJson(timeOf(List.length(frames))),
                "yarn" => Json.JString(yarn),
                "node" => Json.JString(node),
                "playUrl" => Json.JString(table#playUrl),
                "scenes" => Json.JArray(scenesOf(table, flowRun) |> List.toVector),
                "timeline" => Json.JArray(changesOf(cursors) |> List.map(match (i, cursor) -> pairJson(timeOf(i), lineJson(cursor))) |> List.toVector),
                "lines" => Json.JObject(linesOf(node, res)),
                "speaker" => Json.JObject(speakerRows(res) |> List.map(s -> (s#name, Json.JString(s#id))) |> List.toMap),
                "speakers" => Json.JArray(speakerRows(res) |> List.map(speakerJson) |> List.toVector),
                "sounds" => Json.JArray(soundsOf(table, flowRun#fps, frames) |> List.toVector),
                "objects" => Json.JArray(spansOf(flowRun#fps, flowRun#design, worlds |> List.map(table#objects)) |> List.map(spanJson) |> List.toVector),
                "branches" => Json.JArray(Vector.empty()),
                "probes" => Json.JObject(probes),
                "probeNames" => Json.JObject(probeNamesOf(table) |> List.map(match (name, shown) -> (name, Json.JString(shown))) |> List.toMap),
                "msg" => msgJson(table#msg)
            }))
        }

    // ── 止める所 ──

    /// 同じ名前の mark が無いか（テープのシーンは名前で引くので、2 つ目が 1 つ目を黙って上書きしないように止める）。
    def uniqueMarks(marks: List[String]): Result[String, Unit] =
        let counts = marks |> List.foldLeft((acc, name) -> Map.insertWith((a, b) -> a + b, name, 1, acc), Map.empty());
        let twice = counts |> Map.filter(n -> n > 1) |> Map.keysOf |> Set.toList;
        if (List.isEmpty(twice)) Ok(())
        else Err("同じ名前の mark がある: ${String.intercalate(", ", twice)}（テープのシーンは名前で引くので、mark の名前は 1 つずつにする）")

    /// 流した間に開いたノード（1 本のテープは 1 ノードだけ。開いていなければ空）。
    def singleNode(worlds: List[AppState]): Result[String, String] =
        let nodes = worlds |> List.map(h -> World.talkNodeOf(h#world)) |> List.filter(n -> not String.isEmpty(n)) |> changesOf |> List.map(snd);
        match List.distinct(nodes) {
            case Nil         => Ok("")
            case node :: Nil => Ok(node)
            case _           => Err("flow がノードをまたいでいる: ${String.intercalate(" → ", nodes)}（1 本のテープは 1 ノードだけ。ノードの中で止める flow にする）")
        }

    // ── 欄ごと ──

    /// i フレーム目の秒（小数 3 桁に丸める）。
    def secondsAt(fps: Float64, i: Int32): Float64 = Float64.round(Int32.toFloat64(i) / fps * 1000.0) / 1000.0

    /// 値が変わったフレームだけ（先頭のフレームは必ず載る）。
    def changesOf(values: List[a]): List[(Int32, a)] with Eq[a] =
        let (kept, _) = values |> List.zipWithIndex |> List.foldLeft((acc, pair) -> {
            let (out, prev) = acc;
            let (i, v) = pair;
            if (prev == Some(v)) (out, prev) else ((i, v) :: out, Some(v))
        }, (Nil, None));
        List.reverse(kept)

    /// 「ファイル:行」の行の番号（空・読めなければ None）。
    def lineNumberOf(cursor: String): Option[Int32] =
        String.splitOn({substr = ":"}, cursor) |> List.last |> Option.flatMap(Int32.fromString)

    def lineJson(cursor: String): Json = lineNumberOf(cursor) |> Option.map(intJson) |> Option.getWithDefault(Json.JNull)

    /// シナリオのファイル（実行位置のファイル。位置が出なかった時はノードの書いてあるファイル）。
    def yarnOf(node: String, cursors: List[String], res: Res.Res): String =
        let fromCursor = cursors |> List.find(c -> not String.isEmpty(c))
            |> Option.flatMap(c -> String.splitOn({substr = ":"}, c) |> List.head);
        let fromNode = Yarn.nodeOf(node, res#dialogue) |> Option.map(n -> n#source#file);
        (if (Option.isEmpty(fromCursor)) fromNode else fromCursor) |> Option.getWithDefault("")

    /// mark → シーン（書いた順）。
    def scenesOf(table: Table, flowRun: Run): List[Json] =
        flowRun#marks |> List.filterMap(name -> Map.get(name, flowRun#outcome#marks) |> Option.map(at ->
            Json.JObject(Map#{
                "id" => Json.JString(name),
                "name" => Json.JString(Map.getWithDefault(name, name, table#sceneNames)),
                "t" => numJson(secondsAt(flowRun#fps, at))
            })))

    /// 地の文と各話し手の色の行（地の文が先頭）。name が空の行は novel.story.json の呼び名。
    def speakerRows(res: Res.Res): List[ThemeDoc.Speaker] =
        ("" :: List.map(Talk.speakerId, Talk.speakers())) |> List.map(id -> {
            let row = ThemeDoc.speakerOf(id, res#theme);
            if (String.isEmpty(row#name)) { name = StoryDoc.nameOf(id, res#story) | row } else row
        })

    def speakerJson(s: ThemeDoc.Speaker): Json =
        Json.JObject(Map#{ "id" => Json.JString(s#id), "name" => Json.JString(s#name),
                           "color" => Json.JString(Color.toHex(s#color)), "ink" => Json.JString(Color.toHex(s#ink)) })

    /// ノードの文を行の番号 → {who, text} / {cmd} に（選択肢と <<if>> の中も）。字は ScriptEdits.rowsOf と同じ
    /// （「ここから遊ぶ」の前の文のハッシュをこの字で作る）。
    def linesOf(node: String, res: Res.Res): Map[String, Json] =
        let names = speakerRows(res) |> List.map(s -> (s#id, s#name)) |> List.toMap;
        Yarn.nodeOf(node, res#dialogue) |> Option.map(ScriptEdits.rowsOf) |> Option.getWithDefault(Nil)
            |> List.map(row -> (Int32.toString(row#line), rowJson(names, row))) |> List.toMap

    def rowJson(names: Map[String, String], row: ScriptEdits.Row): Json = match row#say {
        case Some(line) => Json.JObject(Map#{ "who" => Json.JString(Map.getWithDefault(line#speaker, line#speaker, names)),
                                              "text" => Json.JString(row#text) })
        case None       => Json.JObject(Map#{ "cmd" => Json.JString(row#text) })
    }

    /// 鳴った音: 一発の音（ambience 以外は se）と、鳴り続ける音の鳴り始め（前のフレームに無かった物 = ambience）。line = 同じフレームの実行位置。
    def soundsOf(table: Table, fps: Float64, frames: List[Flow.Played[AppState]]): List[Json] =
        let (rows, _) = frames |> List.zipWithIndex |> List.foldLeft((acc, pair) -> {
            let (out, before) = acc;
            let (i, played) = pair;
            let now = played#step#sustained |> List.map(s -> s#name) |> List.toSet;
            let line = lineJson(World.talkCursorOf(played#step#after#world));
            let started = Set.difference(now, before) |> Set.toList |> List.map(name -> (name, "ambience"));
            let shots = played#step#sounds |> List.map(name -> (name, "se"));
            let here = List.append(started, shots) |> List.filter(match (name, _) -> not Set.memberOf(name, table#hiddenSounds))
                |> List.map(match (name, kind) -> Json.JObject(Map#{
                    "t" => numJson(secondsAt(fps, i)), "name" => Json.JString(name), "kind" => Json.JString(kind),
                    "label" => Json.JString(Map.getWithDefault(name, name, table#soundLabels)), "line" => line }));
            (List.reverse(here) ::: out, now)
        }, (Nil, Set.empty()));
        List.reverse(rows)

    /// 出ている物を、同じ物（id・名前・割合の矩形が同じ）が続く間ごとに 1 行へまとめる（出た順）。画面の外だけにある物は載せない。
    pub def spansOf(fps: Float64, design: Vec2.Vec2, frames: List[List[ScreenObject]]): List[Span] =
        let keyed = frames |> List.map(objects -> objects |> List.filterMap(o ->
            fractionOf(design, o#rect) |> Option.map(r -> (o#id, o#name, (r#x, r#y, r#w, r#h)))) |> List.distinct);
        let (open, closed, _) = keyed |> List.zipWithIndex |> List.foldLeft((acc, pair) -> {
            let (opened, done, seq) = acc;
            let (i, now) = pair;
            let here = List.toSet(now);
            let ending = Map.filterWithKey((key, _) -> not Set.memberOf(key, here), opened);
            let starting = now |> List.filterMap(key -> if (Map.memberOf(key, opened)) None else Some(key)) |> List.zipWithIndex
                |> List.map(match (j, key) -> (key, (i, seq + j)));
            (Map.union(Map.filterWithKey((key, _) -> Set.memberOf(key, here), opened), List.toMap(starting)),
             List.append(Map.toList(ending) |> List.map(match (key, (since, order)) -> (key, since, i, order)), done),
             seq + List.length(starting))
        }, (Map.empty(), Nil, 0));
        let n = List.length(frames);
        List.append(Map.toList(open) |> List.map(match (key, (since, order)) -> (key, since, n, order)), closed)
            |> Sort.sortStableBy(match (_, _, _, order) -> order)
            |> List.map(match ((id, name, (x, y, w, h)), since, until, _) ->
                { id = id, name = name, startAt = secondsAt(fps, since), endAt = secondsAt(fps, until), rect = { x = x, y = y, w = w, h = h } })

    /// design の px の矩形を、画面に収めてから画面に対する割合（小数 3 桁）に。画面の外だけなら None。
    pub def fractionOf(design: Vec2.Vec2, r: Rect2.Rect2): Option[Fraction] =
        let clamp = v -> Float64.max(0.0, Float64.min(1.0, v));
        let round3 = v -> Float64.round(v * 1000.0) / 1000.0;
        let x0 = clamp(r#position#x / design#x);
        let y0 = clamp(r#position#y / design#y);
        let x1 = clamp((r#position#x + r#size#x) / design#x);
        let y1 = clamp((r#position#y + r#size#y) / design#y);
        let f = { x = round3(x0), y = round3(y0), w = round3(x1 - x0), h = round3(y1 - y0) };
        if (f#w <= 0.0 or f#h <= 0.0) None else Some(f)

    def spanJson(s: Span): Json =
        Json.JObject(Map#{ "id" => Json.JString(s#id), "name" => Json.JString(s#name), "from" => numJson(s#startAt), "to" => numJson(s#endAt),
                           "rect" => Json.JObject(Map#{ "x" => numJson(s#rect#x), "y" => numJson(s#rect#y),
                                                        "w" => numJson(s#rect#w), "h" => numJson(s#rect#h) }) })

    /// 選んだ問いをフレームごとに読み、変わった所だけ [秒, 値] に。
    def probesOf(table: Table, fps: Float64, worlds: List[AppState]): Result[String, Map[String, Json]] =
        let rows = E2e.table()#probes |> List.map(row -> (row#name, row#read)) |> List.toMap;
        table#probes |> List.map(name -> match Map.get(name, rows) {
            case Some(read) =>
                let values = worlds |> List.map(probeValue(read));
                Ok((name, Json.JArray(changesOf(values) |> List.map(match (i, v) -> pairJson(secondsAt(fps, i), valueJson(v))) |> List.toVector)))
            case None => Err("知らない問い '${name}'（E2e.table の probes の名前を書く）")
        }) |> Result.sequence |> Result.map(List.toMap)

    def probeValue(read: Flow.Probe[AppState]): AppState -> Flow.Value = h -> match read {
        case Flow.Probe.Num(f)  => Flow.Value.Num(f(h))
        case Flow.Probe.Text(f) => Flow.Value.Text(f(h))
        case Flow.Probe.Flag(f) => Flow.Value.Flag(f(h))
    }

    /// 数は整数なら整数で書く。
    def valueJson(v: Flow.Value): Json = match v {
        case Flow.Value.Num(x)  => numJson(x)
        case Flow.Value.Text(s) => Json.JString(s)
        case Flow.Value.Flag(b) => Json.JBool(b)
    }

    /// 問いの表示名: 上書きが無ければ doc の頭（「（」か「。」の前）。
    def probeNamesOf(table: Table): List[(String, String)] =
        let docs = E2e.table()#probes |> List.map(row -> (row#name, row#doc)) |> List.toMap;
        table#probes |> List.map(name -> (name, Map.get(name, table#probeNames)
            |> Option.getWithDefault(shortDoc(Map.getWithDefault(name, name, docs)))))

    def shortDoc(doc: String): String =
        let cut = (sep, text) -> String.splitOn({substr = sep}, text) |> List.head |> Option.getWithDefault(text);
        cut("。", cut("（", doc))

    def msgJson(m: Msg): Json =
        Json.JObject(Map#{ "x0" => numJson(m#x0), "x1" => numJson(m#x1), "cy" => numJson(m#cy), "lh" => numJson(m#lh),
                           "padTop" => numJson(m#padTop), "padBot" => numJson(m#padBot), "font" => numJson(m#font), "cps" => numJson(m#cps),
                           "when" => Json.JObject(Map.map(Json.JString, m#when)) })

    /// msg の when が見る問いは、載せる問い（probes）の中に無いと頁で読めない。
    def msgWhenKnown(table: Table): Result[String, Unit] =
        let probes = List.toSet(table#probes);
        Map.keysOf(table#msg#when) |> Set.toList |> List.find(name -> not Set.memberOf(name, probes))
            |> Option.map(name -> Err("msg の when の問い '${name}' が probes に無い"))
            |> Option.getWithDefault(Ok())

    def pairJson(t: Float64, v: Json): Json = Json.JArray(Vector#{ numJson(t), v })

    def intJson(n: Int32): Json = Json.JNumber(JsonCodec.intToBd(n))

    /// 整数の値は整数（3 → 3）、それ以外は小数 4 桁まで。
    def numJson(x: Float64): Json =
        if (Float64.floor(x) == x) Float64.tryToInt32(x) |> Option.map(intJson) |> Option.getWithDefault(Json.JNumber(JsonCodec.floatToBd(x)))
        else Json.JNumber(JsonCodec.floatToBd(Float64.round(x * 10000.0) / 10000.0))
}
