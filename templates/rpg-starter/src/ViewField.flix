// ViewField — World からフィールドの絵の In（FieldScreen.In）を組む（純粋）。隊列の画素の位置・画面の下の文のウィンドウ・暗転の進み具合。
// メニューと店のウィンドウの In は ViewMenu。World を受けるのは fieldIn だけ。
mod ViewField {
    use fge::{Clock, Grid, Num, Transition, UiTypewriter, Vec2}
    use World.{FieldWindow, ShopMode, ShopPage, TransitionThen, FieldRec, Stride}
    use TextDoc.MenuText

    /// World から FieldScreen の In を組む（エンディングの間は下敷きのフィールド。マップが読み直しで消えていれば None）。
    pub def fieldIn(res: Res.Res, w: World.World): Option[FieldScreen.In] =
        forM (
            r <- World.shownFieldOf(w);
            map <- MapDoc.docOf(res#maps, r#map);
            art <- Map.get(MapDoc.nameOf(r#map), res#arts)
        ) yield {
            let quest = Progress.rec(w#progress)#quest;
            { map = map, art = art, party = walkersOf(res, World.now(w), Party.membersOf(w#party), r), facing = r#facing,
              npcs = MapDoc.standingOf(Party.joinedIds(w#party), quest, map),
              props = MapDoc.propsIn(quest, map),
              things = WorldObject.objectsNow(map, r, w#progress)
                  |> List.map(p -> { kind = p#object#kind, sprite = p#object#sprite, x = p#cell#x, y = p#cell#y, state = p#state }),
              talkingTo = openTalkOf(r#window) |> Option.flatMap(t -> t#npc),
              menu = ViewMenu.menuIn(res, w#party, w#bag, r#window),
              shop = ViewMenu.shopIn(res, w#bag, r#window),
              talk = talkBoxOf(res, w#bag, r#window),
              transition = r#transition |> Option.map(transitionProgress(res, World.now(w))),
              light = lightOf(res, map, heroPx(res, World.now(w), r), r),
              riding = World.rideOf(r) |> Option.map(_ -> heroPx(res, World.now(w), r)) }
        }

    // ── 画面の下の文のウィンドウ ──

    /// 開いている会話（店に渡している会話も。話している人を主人公の方へ向かせる）。
    def openTalkOf(window: FieldWindow): Option[World.TalkRec] = match window {
        case FieldWindow.Talk(t)    => Some(World.talkRecOf(t))
        case FieldWindow.Shop(_, _, t) => Some(World.talkRecOf(t))
        case _                         => None
    }

    /// 画面の下の文のウィンドウ: 会話の台詞・店の人の台詞（確かめの間は「〜G で かいますか？」と はい / いいえ）・知らせ。
    def talkBoxOf(res: Res.Res, bag: Bag.Bag, window: FieldWindow): Option[FieldScreen.TalkBox] = match window {
        case FieldWindow.Talk(t)    => lineBoxOf(res, World.talkRecOf(t), true)
        case FieldWindow.Shop(shop, ShopPage.Confirm(mode, item, n, answer), _) => Some(askBoxOf(res, bag, shop, mode, item, n, answer))
        case FieldWindow.Shop(_, _, t) => lineBoxOf(res, World.talkRecOf(t), false)
        case FieldWindow.Notice(n)  => Some(FieldScreen.buildTalk("", n#reveal, Nil, 0))
        case FieldWindow.Menu(_)    => None
        case FieldWindow.Closed     => None
    }

    /// 会話の台詞（withChoices = 選択肢も出す。店の間は台詞だけ）。
    def lineBoxOf(res: Res.Res, t: World.TalkRec, withChoices: Bool): Option[FieldScreen.TalkBox] =
        let choices = if (withChoices) t#choices |> List.map(o -> (o#line#text, o#available)) else Nil;
        t#line |> Option.map(line -> FieldScreen.buildTalk(TextDoc.speakerName(line#speaker, res#text), t#reveal, choices, t#cursor))

    def askBoxOf(res: Res.Res, bag: Bag.Bag, shop: String, mode: ShopMode, item: ItemsDoc.ItemId, n: Int32, answer: World.Answer): FieldScreen.TalkBox =
        let price = WorldShop.goodsOf(res, shop, mode, bag) |> List.find(g -> g#item == item) |> Option.map(g -> g#price) |> Option.getWithDefault(0);
        let ask = match mode {
            case ShopMode.Buy  => TextDoc.NoticeText.BuyAsk
            case ShopMode.Sell => TextDoc.NoticeText.SellAsk
        };
        let line = TextDoc.noticeText(ask, (TextDoc.Placeholder.Item, ItemsDoc.nameOf(res#items, item)) :: (TextDoc.Placeholder.N, "${n}") :: (TextDoc.Placeholder.Gold, "${price * n}") :: Nil, res#text);
        FieldScreen.buildTalk("", UiTypewriter.skip(UiTypewriter.start(line)),
                              (TextDoc.menuText(MenuText.Yes, res#text), true) :: (TextDoc.menuText(MenuText.No, res#text), true) :: Nil,
                              if (answer == World.Answer.Yes) 0 else 1)

    // ── 隊列と暗転 ──

    /// 先頭のマスの左上（px）。歩きの途中は前のマスから今のマスへ、歩いた割合だけ動かす（画素にそろえて切り捨てる）。
    /// トロッコで走っている間は、道の今の 2 マスの間（1 マスは rules の secondsPerRail 秒）。
    pub def heroPx(res: Res.Res, now: Clock.Time[World.Play], r: FieldRec): Vec2.Vec2 = match r#stride {
        case Stride.Still => FieldView.cellPx(r#hero)
        case Stride.Walking(prev, startedAt) => betweenPx(strideRatio(res, now, startedAt), prev, r#hero)
        case Stride.Boarding => FieldView.cellPx(r#hero)
        case Stride.Riding(ride) => ridePx(res, now, ride)
    }

    def ridePx(res: Res.Res, now: Clock.Time[World.Play], ride: World.Ride): Vec2.Vec2 =
        let cells = List.toVector(ride#path);
        let last = Int32.max(0, Vector.length(cells) - 1);
        let t = Float64.max(0.0, Clock.since(ride#startedAt, now) / RulesDoc.rec(res#rules)#secondsPerRail);
        let i = Float64.floor(t) |> Float64.tryToInt32 |> Option.getWithDefault(0) |> Int32.min(last);
        let cellAt = k -> Vector.nth(Int32.min(k, last), cells) |> Option.getWithDefault({ x = 0, y = 0 });
        if (i >= last) FieldView.cellPx(cellAt(last))
        else betweenPx(t - Int32.toFloat64(i), cellAt(i), cellAt(i + 1))

    /// 暗いマップの明かり（明るいマップは None）。たいまつの残りがあれば rules の torchRadius、無ければ darkRadius。
    def lightOf(res: Res.Res, map: MapDoc.Doc, leaderAt: Vec2.Vec2, r: FieldRec): Option[FieldScreen.Light] =
        let rules = RulesDoc.rec(res#rules);
        let half = FieldView.tile() / 2.0;
        if (not MapDoc.rec(map)#dark) None
        else Some({ center = { x = leaderAt#x + half, y = leaderAt#y + half },
                    radius = if (r#light > 0) rules#torchRadius else rules#darkRadius })

    def strideRatio(res: Res.Res, now: Clock.Time[World.Play], startedAt: Clock.Time[World.Play]): Float64 =
        Num.clamp01(Clock.since(startedAt, now) / RulesDoc.rec(res#rules)#secondsPerTile)

    def betweenPx(ratio: Float64, before: Grid.Cell, after: Grid.Cell): Vec2.Vec2 =
        Vec2.floor(Vec2.lerp(FieldView.cellPx(before), FieldView.cellPx(after), ratio))

    /// 隊列の全員（先頭から）。2 人目からは trail の前の人のマスに立ち、先頭と同じ進み具合で 1 つ古いマスから動く。
    /// trail が足りない人（出入口を通った直後）は先頭と同じマスに重なる。
    /// トロッコで走っている間は先頭だけ（2 人目・3 人目は乗っている事にして描かない。降りると trail が空なので先頭に重なる）。
    def walkersOf(res: Res.Res, now: Clock.Time[World.Play], members: List[Member.Member], r: FieldRec): List[FieldScreen.Walker] =
        let leaderAt = heroPx(res, now, r);
        let riding = Option.nonEmpty(World.rideOf(r));
        members |> List.take(if (riding) 1 else List.length(members)) |> List.zipWithIndex |> List.map(match (i, member) -> {
            let looks = PartyDoc.memberOf(member, res#party);
            let base = { who = looks#sprite, placeholder = looks#placeholder };
            let spot = if (i == 0) None else List.nth(i - 1, r#trail);
            match spot {
                case None => { +at = leaderAt, +facing = r#facing | base }
                case Some((cell, facing)) =>
                    let before = List.nth(i, r#trail) |> Option.map(fst) |> Option.getWithDefault(cell);
                    { +at = followerPx(res, now, r#stride, before, cell), +facing = facing | base }
            }
        })

    /// 後ろの人のマスの左上（px）。先頭が歩いている間は before から cell へ、先頭と同じ割合だけ動かす。
    def followerPx(res: Res.Res, now: Clock.Time[World.Play], stride: Stride, before: Grid.Cell, cell: Grid.Cell): Vec2.Vec2 =
        match stride {
            case Stride.Still               => FieldView.cellPx(cell)
            case Stride.Walking(_, started) => betweenPx(strideRatio(res, now, started), before, cell)
            case Stride.Boarding            => FieldView.cellPx(cell)
            case Stride.Riding(_)           => FieldView.cellPx(cell)
        }


    /// 覆う物と進み具合（0..1）。覆う途中は FadeOut、晴らす途中は FadeIn、出会いは点滅。
    def transitionProgress(res: Res.Res, now: Clock.Time[World.Play], transition: World.Transition): FieldScreen.Cover =
        let length = WorldTransition.secondsOf(res, transition#then);
        let t = if (length <= 0.0) 1.0 else Clock.since(transition#startedAt, now) / length;
        match transition#then {
            case TransitionThen.Warp(_, _, _)       => FieldScreen.Cover.Fade(Transition.Kind.FadeOut, t)
            case TransitionThen.InnRest             => FieldScreen.Cover.Fade(Transition.Kind.FadeOut, t)
            case TransitionThen.Ending              => FieldScreen.Cover.Fade(Transition.Kind.FadeOut, t)
            case TransitionThen.FadeIn              => FieldScreen.Cover.Fade(Transition.Kind.FadeIn, t)
            case TransitionThen.StartBattle(_, _)   => FieldScreen.Cover.Flash(t)
        }
}
