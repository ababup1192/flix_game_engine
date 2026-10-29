// WorldTitle — タイトルのメニューの規則（カーソル・選ぶ）と、エンディングからタイトルへ戻る規則。
//   Field ──<<ending>>──▶ 暗転（TransitionThen.Ending）──▶ Ending（スタッフの字が rules の creditSeconds かけて流れる）
//     ──流れ切った後の決定──▶ Title（セーブはそのまま。「つづきから」は最後に泊まった宿から）
mod WorldTitle {
    use fge::{Clock, Emit}
    use World.TitleItem

    // ── エンディング ──

    /// スタッフの字の流れた割合（0..1。エンディングでなければ 0）。
    pub def creditProgressOf(res: Res.Res, w: World.World): Float64 =
        let length = RulesDoc.rec(res#rules)#creditSeconds;
        World.endingRecOf(w)
            |> Option.map(e -> if (length <= 0.0) 1.0 else Float64.min(1.0, Clock.since(e#startedAt, World.now(w)) / length))
            |> Option.getWithDefault(0.0)

    /// エンディングの決定: 字が流れ切っていればタイトルへ（流れている間は何もしない）。[遷移: Ending→Title]
    /// WhyNot: 流れている間の決定で飛ばさない — 報告の台詞を送る決定の連打が、そのままエンディングを飛ばしてしまう。
    pub def confirmEnding(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        if (creditProgressOf(res, w) >= 1.0) { Emit.emit(World.Event.Confirm); World.toTitle(w) } else w

    /// 上から並べた項目。
    pub def items(): List[TitleItem] = TitleItem.NewGame :: TitleItem.Continue :: Nil

    /// 選べる項目か。WhyNot: セーブが無い時に「つづきから」を選べる形で出さない — 選んでも何も起きない項目になる。
    /// saved = セーブがあるか。
    pub def isOpen(item: TitleItem, saved: Bool): Bool = match item {
        case TitleItem.NewGame  => true
        case TitleItem.Continue => saved
    }

    /// カーソルを delta だけ動かす（選べない項目は飛ばす。端で回る）。動かなければ音も出さない。
    pub def move(delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        let open = items() |> List.filter(item -> isOpen(item, Option.nonEmpty(w#save)));
        let count = List.length(open);
        let at = World.titleCursorOf(w) |> Option.flatMap(item -> List.indexOf(item, open)) |> Option.getWithDefault(0);
        let next = List.nth(Int32.modulo(at + delta, Int32.max(1, count)), open);
        match next {
            case Some(item) if Some(item) != World.titleCursorOf(w) => { Emit.emit(World.Event.Cursor); World.withTitleCursor(item, w) }
            case _ => w
        }

    /// 選ぶ。はじめから = 仲間はルカ 1 人・rules の始まりの場所と手持ちのお金で、暗転を晴らして入る。
    /// つづきから = セーブの中身で仲間・ふくろ・進み具合・乱数の回数を置き換え、宿の前（rules の home）に入る。[遷移: Title→Field]
    pub def confirm(res: Res.Res, item: TitleItem, w: World.World): World.World \ Emit[World.Event] =
        match (item, WorldField.startOf(res), WorldShop.homeOf(res), w#save) {
            case (TitleItem.NewGame, Some((map, cell, facing)), _, _) => {
                Emit.emit(World.Event.Confirm);
                World.enterField(map, cell, facing, { party = Party.starting(res#party, res#items),
                                                      bag = Bag.withGold(RulesDoc.rec(res#rules)#startGold) | w })
            }
            case (TitleItem.Continue, _, Some((map, cell, facing)), Some(save)) => {
                Emit.emit(World.Event.Confirm);
                let s = Saves.rec(save);
                World.enterField(map, cell, facing, { party = s#party, bag = s#bag, progress = s#progress, dice = s#dice | w })
            }
            case _ => w
        }
}
