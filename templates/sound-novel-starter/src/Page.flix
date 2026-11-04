// Page — 画面に出している文章（NVL の頁・ADV の 1 行）と文字送りの状態（純粋）。
// 1 行はシナリオの台詞 1 つで、ルビ（Yarn.rubiesOf）と、どの .yarn の行か（既読の鍵）を持つ。
// 台詞（話し手のある行）は「」で包む — サウンドノベルは地の文と台詞を同じ頁に積むので、名前の表示だけでは
// 誰の言葉か頁の上で読めない。ルビの位置は包んだ「の 1 字ぶん後ろへずらす。
//
// NVL は行を頁に積み、入り切らなくなったら頁をめくる（数え方は rowsOf。描く時の折り方 RichText.placeRuby と
// 同じ決まりを、字幅の近似で数える — 描くまで atlas が無い所でも頁の割りが決まる）。ADV は今の 1 行だけ。
mod Page {
    use fge::{RichText, UiTypewriter, Yarn}

    /// 1 行。speaker = 話し手の呼び名（地の文は空）、text = 出す字（台詞は「」込み）、source = .yarn の「ファイル:行」。
    pub type alias Line = { speaker = String, text = String, rubies = List[RichText.Ruby], source = String }

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

    /// シナリオの台詞を 1 行に（name = 話し手の呼び名。地の文は空）。
    pub def lineOf(name: String, line: Yarn.Line): Line =
        let rubies = Yarn.rubiesOf(line);
        if (String.isEmpty(line#speaker))
            { speaker = "", text = line#text, rubies = rubies, source = Yarn.sourceText(line#source) }
        else
            { speaker = name, text = "「${line#text}」", rubies = rubies |> List.map(r -> { start = r#start + 1 | r }),
              source = Yarn.sourceText(line#source) }

    /// 選んだ選択肢をログに残す形（「→ 選んだ字」）。
    pub def choiceLine(text: String): Line = { speaker = "", text = "→ ${text}", rubies = Nil, source = "" }

    /// 次の行を出す。今の行を頁に積んでから出す。場面が変わった後（next が NewPage）は積まない。
    /// 入り切らない時、NVL は頁をめくり（積んだ行を捨てる）、ADV は古い行から落として積み続ける。
    /// fits = 頁に積んだ行と新しい行が入り切るか（World が rowsOf と novel.kind.json の nvlRows で決める）。
    // WhyNot: ADV の行を捨てずに積む — 縦の画面は ADV の台詞も頁に積んで読ませる。横の ADV のウィンドウは今の 1 行だけを描くので見た目は変わらない。
    pub def show(mode: Stage.Mode, fits: List[Line] -> Bool, line: Line, page: Page): Page =
        let kept = match (page#next, page#current) {
            case (NextLine.Append, Some(prev)) => List.append(page#lines, prev :: Nil)
            case _                        => Nil
        };
        let lines = match mode {
            case Stage.Mode.Nvl => if (fits(List.append(kept, line :: Nil))) kept else Nil
            case Stage.Mode.Adv => latestFitting(fits, line, kept)
        };
        { lines = lines, current = Some(line), reveal = UiTypewriter.start(line#text), next = NextLine.Append }

    /// 積んだ行 kept のうち、新しい行 line と一緒に入り切る新しい方の行（入り切るまで古い行から落とす）。
    def latestFitting(fits: List[Line] -> Bool, line: Line, kept: List[Line]): List[Line] =
        if (List.isEmpty(kept) or fits(List.append(kept, line :: Nil))) kept
        else latestFitting(fits, line, List.drop(1, kept))

    /// 場面が変わった（背景を替えた）: 次の行から新しい頁にする。今の行は出したまま（横の ADV のウィンドウは次の行まで今の行を見せる）。
    pub def turn(page: Page): Page = { lines = Nil, next = NextLine.NewPage | page }

    /// 頁をめくる（<<clear>>・ADV と NVL の切り替え）。今の行も消す。
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
}
