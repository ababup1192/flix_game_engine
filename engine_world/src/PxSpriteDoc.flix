// PxSpriteDoc — *.sprite.json(文字格子のドット絵)の宣言ドキュメント層。
// 絵は「文字の格子」で書く: legend が文字→意味色キー(実色でなくテーマで解決する名前)を
// 与え、sprites が 名前 →{frames: 名前付きコマ(rows = 文字列の配列), anchor, loop} を並べる。
// legend はファイルに 1 個でコマ間共有。legend に無い文字は透明(fail-open)。
// 実色への解決は描く側(PxSprite.draw の resolver)が行う — Doc は色の名前しか知らない。
//
// 外形は Doc 規約どおり: version / note 歓迎 / 全フィールド fail-open
// (欠け・書き損じは既定へ落とす — 壊れたファイルでも empty() で必ず動く)。
pub mod PxSpriteDoc {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JString}

    /// コマの回し方。絵そのものには現れないので、Doc が言わないと誰にも分からない。
    /// Forward = 順送り(0→1→2→0)・PingPong = 往復(0→1→2→1→0)・Once = 最終コマで止まる。
    ///
    /// なぜ Doc に要るか: 往復のコマ列は「最終コマ → 0 コマ」が飛んで見えるが、それは
    /// 正しい絵で、順送りの本物の破綻と数値では見分けが付かない(bin/lint-anim.py)。
    /// 描く側にもここが要る — sin 波でコマを選ぶ絵は実体が往復なのに、Doc は順送りに見える。
    pub enum Loop with Eq, ToString {
        case Forward
        case PingPong
        case Once
    }

    /// 動き 1 つ。どのコマをどの順で、1 秒に何コマで、どう回すか。
    ///
    /// frames と分けてあるのは、frames が「名前の付いた姿勢の束」だから。
    /// 向き違いの立ち絵と歩き絵が 1 つの Map に同居していて、そこには順番も
    /// 時間も無い。どのコマが 1 つの動きを作るかは、絵からは分からない。
    pub type alias Clip = {
        frames = List[String],
        fps = Float64,
        loop = Loop
    }

    /// スプライト 1 体: anchor(格子内の基準セル — draw の置き場所がこのセルに来る)と、
    /// 名前付きコマ(rows 形式: 上の行から順の文字列の配列)と、動きの一覧。
    pub type alias Sprite = {
        anchor = Vec2.Vec2,
        frames = Map[String, List[String]],
        clips = Map[String, Clip]
    }

    /// sprite.json 全体。legend は 1 文字 → 意味色キー。
    pub type alias Doc = {
        version = Int32,
        note = Option[String],
        legend = Map[Char, String],
        sprites = Map[String, Sprite]
    }

    /// 何も描かない空の Doc。「まだ読めていない」の置き場 — draw は常に空を返す。
    pub def empty(): Doc =
        { version = 1, note = None, legend = Map.empty(), sprites = Map.empty() }

    /// コマも何も持たないスプライト。Sprite を組み立てる呼び側の土台
    /// （フィールドが増えてもここだけ直せばよい）。
    pub def emptySprite(): Sprite =
        { anchor = { x = 0.0, y = 0.0 }, frames = Map.empty(), clips = Map.empty() }

    /// コマを 1 枚も持たない動き。既定の速さは 8fps(人が歩く絵でだいたい合う)。
    pub def emptyClip(): Clip =
        { frames = Nil, fps = 8.0, loop = Loop.Forward }

    /// テキストから Doc へ(fail-open)。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.parse(String.trim(text))
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(fromRoot)

    /// パース済みの Json 値から Doc へ(エディタの doc/path 経路用 — fromJson と同じ fail-open)。
    /// オブジェクトでなければ None(呼び手が empty を使う)。
    pub def fromJsonValue(json: Json): Option[Doc] =
        JsonCodec.expectObject(json) |> Option.map(fromRoot)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = empty();
        { version = JsonCodec.intOr("version", d#version, root),
          note = Map.get("note", root) |> Option.flatMap(JsonCodec.expectString),
          legend = legendOf(root),
          sprites = spritesOf(root) }

    /// legend: {"h": "hair", ...}。キーが 1 文字でない・値が文字列でない項は黙って捨てる。
    def legendOf(root: Map[String, Json]): Map[Char, String] =
        Map.get("legend", root)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(m -> m
                |> Map.toList
                |> List.filterMap(entry -> {
                    let (k, v) = entry;
                    match (String.toList(k), JsonCodec.expectString(v)) {
                        case (ch :: Nil, Some(key)) => Some((ch, key))
                        case _                      => None
                    }
                })
                |> List.toMap)
            |> Option.getWithDefault(Map.empty())

    def spritesOf(root: Map[String, Json]): Map[String, Sprite] =
        Map.get("sprites", root)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(m -> m
                |> Map.toList
                |> List.filter(entry -> { let (name, _) = entry;
                    not String.startsWith(prefix = "//", name) })
                |> List.filterMap(entry -> {
                    let (name, json) = entry;
                    spriteOf(json) |> Option.map(sp -> (name, sp))
                })
                |> List.toMap)
            |> Option.getWithDefault(Map.empty())

    /// スプライト 1 体。anchor 省略時は {0,0}(格子の左上)。frames の中で
    /// 文字列でない行が混ざったコマは、そのコマだけ捨てる(fail-open)。
    def spriteOf(json: Json): Option[Sprite] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { anchor = Map.get("anchor", obj)
                  |> Option.flatMap(JsonCodec.decodeVec2)
                  |> Option.getWithDefault({ x = 0.0, y = 0.0 }),
              frames = framesOf(obj),
              clips = clipsOf(obj) })

    /// "clips": { "walk_down": { "frames": ["down","down_walk"], "fps": 6, "loop": "pingpong" } }。
    /// コマを 1 枚も挙げていない動きは捨てる(再生しても何も起きないため)。
    def clipsOf(obj: Map[String, Json]): Map[String, Clip] =
        Map.get("clips", obj)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(m -> m
                |> Map.toList
                |> List.filter(entry -> { let (name, _) = entry;
                    not String.startsWith(prefix = "//", name) })
                |> List.filterMap(entry -> {
                    let (name, json) = entry;
                    clipOf(json) |> Option.map(c -> (name, c))
                })
                |> List.toMap)
            |> Option.getWithDefault(Map.empty())

    def clipOf(json: Json): Option[Clip] =
        JsonCodec.expectObject(json) |> Option.flatMap(o -> {
            let names = Map.get("frames", o)
                |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString))
                |> Option.getWithDefault(Nil);
            if (List.isEmpty(names)) None
            else Some({ frames = names,
                        fps = JsonCodec.floatOr("fps", emptyClip()#fps, o),
                        loop = loopOf(o) })
        })

    /// 動きの t 秒後に出すコマの名前。動きが無い・fps が 0 以下なら None
    /// (呼ぶ側は今までどおり自分でコマの名前を選べばよい)。
    ///
    /// 名前を返すのは、描く口(PxSprite.draw / drawQuad)がコマの名前で引くため。
    /// ここが番号を返すと、呼ぶ側が並びを持ち直すことになる。
    pub def clipFrameAt(doc: Doc, sprite: String, clip: String, seconds: Float64): Option[String] =
        Map.get(sprite, doc#sprites)
            |> Option.flatMap(sp -> Map.get(clip, sp#clips))
            |> Option.flatMap(c ->
                if (c#fps <= 0.0) None
                else {
                    let count = List.length(c#frames);
                    let elapsed = Float64.max(0.0, seconds) * c#fps;
                    let step = Float64.tryToInt32(Float64.floor(elapsed)) |> Option.getWithDefault(0);
                    List.nth(frameIndexAt(c#loop, count, step), c#frames)
                })

    /// "loop": "forward" | "pingpong" | "once"。省略・知らない字は Forward。
    def loopOf(obj: Map[String, Json]): Loop =
        Map.get("loop", obj)
            |> Option.flatMap(JsonCodec.expectString)
            |> Option.map(s -> match String.toLowerCase(s) {
                   case "pingpong" => Loop.PingPong
                   case "once"     => Loop.Once
                   case _          => Loop.Forward
               })
            |> Option.getWithDefault(Loop.Forward)

    /// 通し番号 step(0,1,2,…)を、回し方に沿ったコマ番号へ写す。
    /// コマの名前の並びは呼び側が決める(Map の並び順・自前の列のどちらでもよい)。
    /// 描く側とコマ間の検査が同じ式を見るように、ここに 1 つだけ置く。
    pub def frameIndexAt(kind: Loop, count: Int32, step: Int32): Int32 =
        if (count <= 1) 0
        else {
            let s = Int32.max(0, step);
            match kind {
                case Loop.Forward  => Int32.modulo(s, count)
                case Loop.Once     => Int32.min(s, count - 1)
                // 往復は「行って戻る」1 周が 2*(count-1) コマ。折り返しのコマを 2 度出さない
                // ようにこの長さにする(出すと端で 1 コマぶん止まって見える)。
                case Loop.PingPong =>
                    let period = 2 * (count - 1);
                    let m = Int32.modulo(s, period);
                    if (m < count) m else period - m
            }
        }

    def framesOf(obj: Map[String, Json]): Map[String, List[String]] =
        Map.get("frames", obj)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(m -> m
                |> Map.toList
                |> List.filter(entry -> { let (name, _) = entry;
                    not String.startsWith(prefix = "//", name) })
                |> List.filterMap(entry -> {
                    let (name, json) = entry;
                    JsonCodec.decodeList(JsonCodec.expectString, json)
                        |> Option.map(rows -> (name, rows))
                })
                |> List.toMap)
            |> Option.getWithDefault(Map.empty())

    /// コマの格子の大きさ（列数・行数）。列数は一番長い行の文字数。
    /// そのスプライト・そのコマが無ければ None。
    /// 絵の大きさは「絵が決める」— 呼び側が数えると、絵を描き替えたとき静かに食い違う。
    pub def gridSizeOf(doc: Doc, sprite: String, frame: String): Option[{ cols = Int32, rows = Int32 }] =
        Map.get(sprite, doc#sprites)
            |> Option.flatMap(sp -> Map.get(frame, sp#frames))
            |> Option.map(Grid.dimsOfRows)

    /// path の Doc を読む。読めない・壊れているときは empty(fail-open)。
    /// empty へ落ちると絵が「消える」だけで落ちないぶん原因が見えにくいので、
    /// 読み込みを DocJson.loadOr に委譲し、落ちた事実は標準エラーへ 1 行出る。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, empty(), p)
}
