// Page — 画面に出している文章（NVL の頁・ADV の 1 行）と文字送りの状態（純粋）。
// 1 行はシナリオの台詞 1 つで、ルビ（Yarn.rubiesOf）と、どの .yarn の行か（既読の鍵）を持つ。
// 台詞（話し手のある行）はメッセージ枠の型の quotes が真なら「」で包む — サウンドノベルは地の文と台詞を同じ頁に積むので、名前の表示だけでは
// 誰の言葉か頁の上で読めない。ルビの位置は包んだ「の 1 字ぶん後ろへずらす。
//
// NVL は行を頁に積み、入り切らなくなったら頁をめくる（数え方は rowsOf。描く時の折り方 RichText.placeRuby と
// 同じ決まりを、字幅の近似で数える — 描くまで atlas が無い所でも頁の割りが決まる）。ADV は今の 1 行だけ。
mod Page {
    use fge::{JsonCodec, RichText, UiTypewriter, Yarn}
    use Util.Json.Json

    /// 1 行。speaker = 話し手の呼び名（地の文は空）、speakerId = 台本の話し手の id（地の文と、id を書く前のセーブの行は空）、
    /// text = 出す字（台詞は「」込み）、source = .yarn の「ファイル:行」。
    // WhyNot: 呼び名から id を逆引きしない — 呼び名には novel.story.json の replace が当たり、Doc の names と字が合わなくなる。
    pub type alias Line = { speaker = String, speakerId = String, text = String, rubies = List[RichText.Ruby], source = String }

    /// lines = 頁に積んだ読み終えた行（古い順）、current = 文字送り中か読み終えた今の行、reveal = 今の行の文字送り、
    /// next = 次の行を出す時に今の行を頁に積むか（場面が変わった後の最初の行は積まない）。
    /// ADV も行を積む（横の画面は今の 1 行だけを描き、縦の画面は NVL と同じ頁に積んで描く）。
    pub type alias Page = { lines = List[Line], current = Option[Line], reveal = UiTypewriter.Reveal, next = NextLine }

    /// 次の行を出す時に、今の行を頁に積むか。Append = 積む・NewPage = 積まずに新しい頁から始める（ADV で場面が変わった後）。
    pub enum NextLine with Eq, ToString {
        case Append
        case NewPage
    }

    pub def empty(): Page = { lines = Nil, current = None, reveal = UiTypewriter.done(""), next = NextLine.Append }

    /// シナリオの台詞を 1 行に（name = 話し手の呼び名。地の文は空・quotes = 台詞を「」で包むか）。
    pub def lineOf(name: String, quotes: Bool, line: Yarn.Line): Line =
        let rubies = Yarn.rubiesOf(line);
        if (String.isEmpty(line#speaker) or not quotes)
            { speaker = if (String.isEmpty(line#speaker)) "" else name, speakerId = line#speaker, text = line#text, rubies = rubies, source = Yarn.sourceText(line#source) }
        else
            { speaker = name, speakerId = line#speaker, text = "「${line#text}」", rubies = rubies |> List.map(r -> { start = r#start + 1 | r }),
              source = Yarn.sourceText(line#source) }

    /// 地の文の 1 行（話し手なし・ルビなし）。
    pub def plainLine(text: String, source: String): Line = { speaker = "", speakerId = "", text = text, rubies = Nil, source = source }

    /// 選んだ選択肢をログに残す形（「→ 選んだ字」）。
    pub def choiceLine(text: String): Line = plainLine("→ ${text}", "")

    /// 次の行を出す。今の行を頁に積んでから出す。場面が変わった後（next が NewPage）は積まない。
    /// 入り切らない時、NVL は頁をめくり（積んだ行を捨てる）、ADV は古い行から落として積み続ける。
    /// fits = 頁に積んだ行と新しい行が入り切るか（World が rowsOf と novel.kind.json の nvlRows で決める）。
    // WhyNot: ADV の行を捨てずに積む — 縦の画面は ADV の台詞も頁に積んで読ませる。横の ADV のウィンドウは今の 1 行だけを描くので見た目は変わらない。
    pub def show(mode: ThemeDoc.WindowKind, fits: List[Line] -> Bool, line: Line, page: Page): Page =
        let kept = keptOf(page);
        let lines = match mode {
            case ThemeDoc.WindowKind.Nvl => if (fits(List.append(kept, line :: Nil))) kept else Nil
            case ThemeDoc.WindowKind.Adv => latestFitting(fits, line, kept)
        };
        { lines = lines, current = Some(line), reveal = UiTypewriter.start(line#text), next = NextLine.Append }

    /// 次の行を出す時に頁に残る行（今の行を積んだ物。場面が変わった後は空）。
    def keptOf(page: Page): List[Line] = match (page#next, page#current) {
        case (NextLine.Append, Some(prev)) => List.append(page#lines, prev :: Nil)
        case _                             => Nil
    }

    /// line を出すと show が NVL の頁をめくるか（積んだ行があり、新しい行と一緒に入り切らない）。
    pub def isFullFor(mode: ThemeDoc.WindowKind, fits: List[Line] -> Bool, line: Line, page: Page): Bool =
        let kept = keptOf(page);
        mode == ThemeDoc.WindowKind.Nvl and not List.isEmpty(kept) and not fits(List.append(kept, line :: Nil))

    /// 積んだ行 kept のうち、新しい行 line と一緒に入り切る新しい方の行（入り切るまで古い行から落とす）。
    def latestFitting(fits: List[Line] -> Bool, line: Line, kept: List[Line]): List[Line] =
        if (List.isEmpty(kept) or fits(List.append(kept, line :: Nil))) kept
        else latestFitting(fits, line, List.drop(1, kept))

    /// 場面が変わった（背景を替えた）: 次の行から新しい頁にする。今の行は出したまま（横の ADV のウィンドウは次の行まで今の行を見せる）。
    pub def turn(page: Page): Page = { lines = Nil, next = NextLine.NewPage | page }

    /// 頁をめくる（<<window clear>>・ADV と NVL の切り替え）。今の行も消す。
    pub def clear(_page: Page): Page = empty()

    /// 文字送りを dt 秒ぶん進める。
    pub def step(cps: Float64, dt: Float64, page: Page): Page =
        { reveal = UiTypewriter.step(cps = cps, dt, page#reveal) | page }

    /// 今の行を全部出す。
    pub def revealAll(page: Page): Page = { reveal = UiTypewriter.skip(page#reveal) | page }

    /// 今の行を出し終えたか（行が無ければ出し終えている）。
    pub def isDone(page: Page): Bool = UiTypewriter.isDone(page#reveal)

    /// 今の行の見えている字の数。
    pub def visibleCount(page: Page): Int32 = UiTypewriter.visibleCount(page#reveal)

    /// 行が幅 maxWidth で何行に折れるか（字の大きさ size・ルビ rubySize。全角は size、半角は size の半分で数える）。
    pub def rowsOf(size: Float64, rubySize: Float64, maxWidth: Float64, line: Line): Int32 =
        let charWidth = ch -> if (Char.toBmpCodePoint(ch) < 128) size * 0.5 else size;
        let rubyWidth = text -> Int32.toFloat64(String.length(text)) * rubySize;
        RichText.rubyLineCountBy(charWidth, rubyWidth, rubySize, maxWidth, line#rubies, RichText.plain(line#text) :: Nil)

    // ── 残す形（セーブ） ──

    def lineToJson(line: Line): Json =
        let ruby = (r: RichText.Ruby) -> Json.JObject(Map#{ "start" => Json.JNumber(JsonCodec.intToBd(r#start)),
                                                            "length" => Json.JNumber(JsonCodec.intToBd(r#length)), "text" => Json.JString(r#text) });
        Json.JObject(Map#{ "speaker" => Json.JString(line#speaker), "speakerId" => Json.JString(line#speakerId), "text" => Json.JString(line#text),
                           "rubies" => JsonCodec.encodeList(ruby, line#rubies), "source" => Json.JString(line#source) })

    def lineFromJson(json: Json): Option[Line] =
        let rubyOf = j -> JsonCodec.expectObject(j) |> Option.map(obj ->
            { start = JsonCodec.intOr("start", 0, obj), length = JsonCodec.intOr("length", 0, obj), text = JsonCodec.stringOr("text", "", obj) });
        JsonCodec.expectObject(json) |> Option.flatMap(obj -> forM (
            text <- Map.get("text", obj) |> Option.flatMap(JsonCodec.expectString);
            rubies <- Map.get("rubies", obj) |> Option.getWithDefault(Json.JArray(Vector.empty())) |> JsonCodec.decodeList(rubyOf)
        ) yield { speaker = JsonCodec.stringOr("speaker", "", obj), speakerId = JsonCodec.stringOr("speakerId", "", obj), text = text, rubies = rubies, source = JsonCodec.stringOr("source", "", obj) })

    /// セーブの枠の "page" に書く値: { "lines": [行…], "current": 行か null, "next": "Append" か "NewPage" }。文字送りは出し終えた形で残す。
    pub def toJson(page: Page): Json =
        Json.JObject(Map#{ "lines" => JsonCodec.encodeList(lineToJson, page#lines),
                           "current" => page#current |> Option.map(lineToJson) |> Option.getWithDefault(Json.JNull),
                           "next" => Json.JString("${page#next}") })

    /// toJson の形から（今の行は出し終えた形）。行が 1 つでも読めなければ None（呼ぶ側は当て直しで作った頁を使う）。
    pub def fromJson(json: Json): Option[Page] =
        JsonCodec.expectObject(json) |> Option.flatMap(obj -> forM (
            lines <- Map.get("lines", obj) |> Option.flatMap(JsonCodec.decodeList(lineFromJson));
            current <- match Map.get("current", obj) {
                case None              => Some(None)
                case Some(Json.JNull)  => Some(None)
                case Some(j)           => lineFromJson(j) |> Option.map(Some)
            }
        ) yield {
            let next = if (JsonCodec.stringOr("next", "", obj) == "${NextLine.NewPage}") NextLine.NewPage else NextLine.Append;
            { lines = lines, current = current, next = next,
              reveal = UiTypewriter.done(current |> Option.map(line -> line#text) |> Option.getWithDefault("")) }
        })
}
