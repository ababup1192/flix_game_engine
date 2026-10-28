// テストの共通部品: 実機と同じ App（Game.app）と Doc・シナリオで組んだ始まりの World と、系を直に呼ぶ 1 歩。
// シナリオは本物（assets/talk/dialogue.json）。期待値は台本と Doc から導き、行の文字を写さない。
mod TestKit {

    use fge::{App, Emit, Resources, YarnRunner}

    /// assets の Doc とシナリオをそのまま読んだ描く元。
    pub def res(): Res.Res \ Fs.FileRead = Controls.loadRes()

    /// タイトルの World（セーブデータは空・ファイルは書かない・時刻は 0）。
    pub def w0(res: Res.Res): World.World = World.initial(Saves.fresh(res#kind), 0i64)

    pub def app(res: Res.Res, w: World.World): App.App[Resources.With[Res.Res, World.World], {}] = Game.app(res, w#saves, w#clockBase)

    /// 物語の時計だけを dt 秒ぶん進める（実機と同じ App.addClock の進み方）。
    pub def tickClocks(res: Res.Res, dt: Float64, w: World.World): World.World =
        App.tickClocks(app(res, w), dt, Resources.of(res, w))#world

    /// 系を直に呼ぶ 1 歩: 実機と同じく、先に物語の時計を dt 秒ぶん進めてから World.step。
    pub def stepBy(res: Res.Res, dt: Float64, w: World.World): World.World =
        quiet(() -> WorldRead.step(res, tickClocks(res, dt, w)))

    /// 規則が出す返事の出来事（Emit）を捨てて World だけを見る。
    pub def quiet(f: Unit -> World.World \ Emit[World.Event]): World.World = fst(Emit.collect(f))

    pub def advance(res: Res.Res, w: World.World): World.World = quiet(() -> WorldRead.advance(res, w))

    pub def pick(res: Res.Res, i: Int32, w: World.World): World.World = quiet(() -> WorldRead.pick(res, i, w))

    /// はじめから読み、最初の行を出し終えた所（頭の <<wait>> も明けている）。
    pub def begun(res: Res.Res): World.World =
        settle(res, quiet(() -> WorldRead.newGame(res, w0(res))))

    /// 待ちと文字送りを使い切る（テストは速さを検査しない）。
    pub def settle(res: Res.Res, w: World.World): World.World = stepBy(res, 30.0, w)

    /// 選択肢では picks の頭を選び、それ以外は読み終えて送る。until が真になるか picks が尽きた選択肢で止まる（fuel で必ず止まる）。
    pub def readUntil(res: Res.Res, until: World.World -> Bool, picks: List[Int32], w: World.World): World.World =
        fst(readHearing(res, until, picks, w))

    /// readUntil と同じ読み方で、途中で規則が出した出来事（返事・<<se>>）も古い順に返す。
    pub def readHearing(res: Res.Res, until: World.World -> Bool, picks: List[Int32], w: World.World): (World.World, List[World.Event]) =
        let heard = (f: Unit -> World.World \ Emit[World.Event]) -> Emit.collect(f);
        let tick = (cur: World.World) -> heard(() -> WorldRead.step(res, tickClocks(res, 30.0, cur)));
        def go(fuel: Int32, rest: List[Int32], cur: World.World, acc: List[World.Event]): (World.World, List[World.Event]) =
            if (fuel <= 0 or until(cur) or not World.isReading(cur)) (cur, acc)
            else {
                let (moved, more, events) = if (World.isChoosing(cur)) match rest {
                    case i :: tail => { let (n, es) = heard(() -> WorldRead.pick(res, i, cur)); (Some(n), tail, es) }
                    case Nil       => (None, rest, Nil)
                } else { let (n, es) = heard(() -> WorldRead.advance(res, cur)); (Some(n), rest, es) };
                match moved {
                    case None    => (cur, acc)
                    case Some(n) =>
                        let (settled, ticked) = tick(n);
                        go(fuel - 1, more, settled, List.append(acc, List.append(events, ticked)))
                }
            };
        go(400, picks, w, Nil)

    /// node に入った所まで読む。
    pub def readTo(res: Res.Res, node: String, picks: List[Int32], w: World.World): World.World =
        readUntil(res, cur -> World.talkNodeOf(cur) == node, picks, w)

    /// 今出している選択肢の数（無ければ 0）。
    pub def choiceCount(w: World.World): Int32 = List.length(World.choicesOf(w))

    /// 今のシナリオの位置（ノードと行）。
    pub def placeOf(w: World.World): (String, String) = (World.talkNodeOf(w), World.talkLineOf(w))

    pub def isWaiting(w: World.World): Bool = match World.readOf(w) |> Option.map(r -> YarnRunner.shownOf(r#talk)) {
        case Some(YarnRunner.Shown.Waiting) => true
        case _                              => false
    }
}
