// Controls — キーを規則の関数へ写す（純粋）・出来事から鳴らす音を選ぶ・Doc の読み直しの表。
// どのキーがどの操作かは KeysDoc（rpg.keys.json）。どの層が入力を受けるかは InputLayer の 1 か所で決め、ここは match するだけ。
// Esc は OS の決まりに合わせた固定のキー（終了の確認。割り当ての Doc には載せない）。
mod Controls {
    use fge::{App, AudioMixer, Clock, Dir4, DocTable, Emit, PxSpriteDoc, Resources, UiTypewriter}
    use fge::GameEngine.Key
    use InputLayer.Layer

    /// 毎フレームのシステム: 実時間を写し、時間で進む物（暗転・歩き・文字送り）を進めてから、入力を 1 つ当てる。
    /// このフレームにウィンドウが閉じたら、押している方向を離すまで歩かない方向にする（閉じる道が入力でも時間でも、ここ 1 か所）。
    /// 会話の音（開いた・文字送り）は、このフレームの前後の World を見比べて出す（talkSoundsOf）。
    pub def step(frame: App.Frame, res: Res.Res, w: World.World): World.World =
        let w1 = { realNow = frame#realNow | w };
        let (next, events) = Emit.collectInto(() -> {
            let after = interpret(res, frame, tick(res, frame, w1));
            talkSoundsOf(res, w1, after) |> List.forEach(Emit.emit);
            rideSoundsOf(w1, after) |> List.forEach(Emit.emit);
            transitionSoundsOf(res, w1, after) |> List.forEach(Emit.emit);
            goldSoundsOf(w1, after) |> List.forEach(Emit.emit);
            after
        }, w1#events);
        let closed = World.isWindowOpen(w1) and not World.isWindowOpen(next);
        let held = if (closed) World.holdUntilReleased(heldDirs(keysOf(res), frame), next) else next;
        { events = events | held }

    def tick(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        fieldTick(res, frame, w)
            |> WorldTalk.tick(res, Clock.dtOf(w#play))
            |> WorldMenu.tickNotice(res, Clock.dtOf(w#play))
            |> WorldBattle.tick(res)

    /// 暗転の間は暗転だけを、ほかは歩きを進める（同じフレームに両方は進めない）。
    def fieldTick(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        match World.fieldRecOf(w) |> Option.flatMap(r -> r#transition) {
            case Some(transition) => WorldTransition.tick(res, transition, w)
            case None             => WorldField.tick(res, heldDir(keysOf(res), frame), w)
        }

    def keysOf(res: Res.Res): KeysDoc.Rec = KeysDoc.rec(res#keys)

    def tapped(keys: List[Key], frame: App.Frame): Bool = List.exists(key -> App.justPressed(key, frame), keys)

    def held(keys: List[Key], frame: App.Frame): Bool = List.exists(key -> App.isDown(key, frame), keys)

    def dirsOf(k: KeysDoc.Rec): List[(List[Key], Dir4.Dir4)] =
        (k#up, Dir4.Dir4.Up) :: (k#down, Dir4.Dir4.Down) :: (k#left, Dir4.Dir4.Left) :: (k#right, Dir4.Dir4.Right) :: Nil

    /// このフレームに押した方向（無ければ None）。
    def pressedDir(k: KeysDoc.Rec, frame: App.Frame): Option[Dir4.Dir4] =
        dirsOf(k) |> List.find(e -> tapped(fst(e), frame)) |> Option.map(snd)

    /// 押している方向の全部。
    def heldDirs(k: KeysDoc.Rec, frame: App.Frame): List[Dir4.Dir4] =
        dirsOf(k) |> List.filter(e -> held(fst(e), frame)) |> List.map(snd)

    /// 歩く方向: このフレームに押した方向を先に、無ければ押したままの方向。
    def heldDir(k: KeysDoc.Rec, frame: App.Frame): Option[Dir4.Dir4] =
        pressedDir(k, frame) |> Option.withDefault(default = dirsOf(k) |> List.find(e -> held(fst(e), frame)) |> Option.map(snd))

    def interpret(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        match InputLayer.layerOf(w) {
            case Layer.Asking(ask)  => askInput(keysOf(res), frame, ask, w)
            case _ if App.justPressed(Key.Escape, frame) => World.askQuit(w)
            case Layer.Busy         => w
            case Layer.Title(item)  => titleInput(res, frame, item, w)
            case Layer.Talk(_)      => talkInput(res, frame, w)
            case Layer.Menu(_)      => menuInput(res, frame, w)
            case Layer.Shop(_)      => shopInput(res, frame, w)
            case Layer.Notice       => noticeInput(res, frame, w)
            case Layer.Walking      => walkInput(res, frame, w)
            case Layer.BattleChoose(_, _) => battleChooseInput(res, frame, w)
            case Layer.BattleMessage => battleMessageInput(res, frame, w)
            case Layer.Ending       => if (tapped(keysOf(res)#confirm, frame)) WorldTitle.confirmEnding(res, w) else w
        }

    // ── 戦い ──

    /// コマンドを選ぶ: 決定で進む・取消で 1 つ前・上下でカーソル。
    def battleChooseInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        if (tapped(k#confirm, frame)) WorldBattle.confirm(res, w)
        else if (tapped(k#cancel, frame)) WorldBattle.cancel(res, w)
        else if (tapped(k#up, frame)) WorldBattle.move(res, -1, w)
        else if (tapped(k#down, frame)) WorldBattle.move(res, 1, w)
        else w

    /// 伝言: 決定か取消で出し切る・次へ。
    def battleMessageInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        if (tapped(k#confirm, frame) or tapped(k#cancel, frame)) WorldBattle.confirmMessage(res, w) else w

    // ── 終了の確認 ──

    /// はい / いいえ: 上下左右でカーソル、決定で答える、取消と Esc は「いいえ」。
    /// はいで決めたフレームは World を変えない（終わるかは isQuit が同じフレームの入力で決める）。
    def askInput(k: KeysDoc.Rec, frame: App.Frame, ask: World.Ask, w: World.World): World.World \ Emit[World.Event] =
        let answer = World.answerOf(ask);
        if (tapped(k#cancel, frame) or App.justPressed(Key.Escape, frame)) World.closeAsk(w)
        else if (tapped(k#confirm, frame) and answer == World.Answer.No) World.closeAsk(w)
        else if (tapped(k#up, frame) or tapped(k#left, frame)) World.moveAsk(World.Answer.Yes, w)
        else if (tapped(k#down, frame) or tapped(k#right, frame)) World.moveAsk(World.Answer.No, w)
        else w

    /// 終了の判定（Game の App.quitWhen）。確認で「はい」にカーソルがあって決定を押したフレーム。
    pub def isQuit(frame: App.Frame, res: Res.Res, w: World.World): Bool =
        w#ask == Some(World.Ask.Quit(World.Answer.Yes)) and tapped(keysOf(res)#confirm, frame)

    // ── タイトル ──

    /// 上下でカーソル（選べる項目だけ）、決定で選ぶ。
    def titleInput(res: Res.Res, frame: App.Frame, item: World.TitleItem, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        if (tapped(k#confirm, frame)) WorldTitle.confirm(res, item, w)
        else if (tapped(k#up, frame)) WorldTitle.move(-1, w)
        else if (tapped(k#down, frame)) WorldTitle.move(1, w)
        else w

    // ── フィールドのウィンドウ（InputLayer の case ごとに 1 つの関数） ──

    def talkInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        if (tapped(k#confirm, frame)) WorldTalk.confirm(res, w)
        else if (tapped(k#cancel, frame)) WorldTalk.cancel(res, w)
        else if (tapped(k#up, frame)) WorldTalk.moveCursor(-1, w)
        else if (tapped(k#down, frame)) WorldTalk.moveCursor(1, w)
        else w

    /// メニュー: 決定で進む・取消で 1 つ前のページ・方向キーでカーソル。
    def menuInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        if (tapped(k#confirm, frame)) WorldMenu.confirm(res, w)
        else if (tapped(k#cancel, frame)) WorldMenu.cancel(res, w)
        else pressedDir(k, frame) |> Option.map(dir -> WorldMenu.move(res, dir, w)) |> Option.getWithDefault(w)

    /// 店: 決定で進む・取消で 1 つ前のページ・上下でカーソル（個数のページは個数）。
    def shopInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        if (tapped(k#confirm, frame)) WorldShop.confirm(res, w)
        else if (tapped(k#cancel, frame)) WorldShop.cancel(res, w)
        else if (tapped(k#up, frame)) WorldShop.move(res, -1, w)
        else if (tapped(k#down, frame)) WorldShop.move(res, 1, w)
        else w

    /// 知らせ: 決定か取消で送る。
    def noticeInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        if (tapped(k#confirm, frame) or tapped(k#cancel, frame)) WorldMenu.confirmNotice(w) else w

    // ── 歩く ──

    /// ウィンドウを閉じたフレームに押していた方向のうち、離した物の待ちを先に解く（どのウィンドウを閉じた後もここ 1 か所）。
    /// 取消のキーでメニューを開く。
    def walkInput(res: Res.Res, frame: App.Frame, w0: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let w = World.releaseAwait(heldDirs(k, frame), w0);
        if (tapped(k#confirm, frame)) WorldField.interact(res, w)
        else if (tapped(k#cancel, frame)) WorldMenu.open(w)
        else heldDir(k, frame)
            |> Option.map(dir -> WorldField.walk(res, dir, pressedDir(k, frame) == Some(dir), w))
            |> Option.getWithDefault(w)

    // ── 音（project.json の sounds の論理名。素材は art/sfx.snd.star → assets/sfx） ──

    /// 出来事の音の名前。
    pub def soundOf(event: World.Event): String = match event {
        case World.Event.Cursor   => "cursor"
        case World.Event.Confirm  => "confirm"
        case World.Event.Cancel   => "cancel"
        case World.Event.Bump     => "bump"
        case World.Event.Door     => "door"
        case World.Event.Denied   => "bump"
        case World.Event.TalkOpen => "talk_open"
        case World.Event.TalkNext => "talk_next"
        case World.Event.TalkBlip(TextDoc.Voice.Low)  => "talk_low"
        case World.Event.TalkBlip(TextDoc.Voice.Mid)  => "talk_mid"
        case World.Event.TalkBlip(TextDoc.Voice.High) => "talk_high"
        case World.Event.Lever    => "lever"
        case World.Event.Switch   => "plate"
        case World.Event.RockPush => "rock"
        case World.Event.CartRide => "cart"
        case World.Event.CrystalLit   => "chime"
        case World.Event.CrystalReset => "fizzle"
        case World.Event.Stairs   => "stairs"
        case World.Event.Chest    => "chest"
        case World.Event.Unlock   => "door"
        case World.Event.Gold     => "gold"
        case World.Event.Inn      => "inn"
        case World.Event.Encounter  => "encounter"
        case World.Event.BossAppear => "boss"
        case World.Event.Attack   => "attack"
        case World.Event.Critical => "critical"
        case World.Event.Hurt     => "hurt"
        case World.Event.Spell(fx) => spellSoundOf(fx)
        case World.Event.Heal     => "heal"
        case World.Event.Sleep    => "sleep"
        case World.Event.Flee     => "flee"
        case World.Event.FoeDown  => "foe_down"
        case World.Event.Victory  => "fanfare"
        case World.Event.LevelUp  => "level_up"
        case World.Event.Wiped    => "wiped"
    }

    /// 呪文の演出の絵（rpg.spells.json の fx）→ 音。
    /// WhyNot: 知らない絵を無音にしない — 呪文を Doc に足しただけで唱えた手応えが消える。素材を作るまでは炎の音を借りる。
    def spellSoundOf(fx: String): String = match fx {
        case "ice"  => "spell_ice"
        case "heal" => "heal"
        case _      => "spell_fire"
    }

    /// 暗転の始まりの音: 戦いの点滅（逃げられない敵がいればボスの登場）・宿に泊まる。
    /// WhyNot: 点滅を始める所（WorldField の出会い・会話の <<fight>>・<<inn>>）で出さない — 始める道が 3 つあり、
    /// 逃げられない敵かを見るには敵の Doc が要る。前後の見比べ 1 か所にそろえる。
    def transitionSoundsOf(res: Res.Res, before: World.World, after: World.World): List[World.Event] =
        let thenOf = w -> World.fieldRecOf(w) |> Option.flatMap(r -> r#transition) |> Option.map(t -> t#then);
        let started = if (Option.isEmpty(thenOf(before))) thenOf(after) else None;
        started |> Option.flatMap(t -> match t {
            case World.TransitionThen.StartBattle(foes, _) => Some(if (isNoFleeGroup(res, foes)) World.Event.BossAppear else World.Event.Encounter)
            case World.TransitionThen.InnRest              => Some(World.Event.Inn)
            case World.TransitionThen.Warp(_, _, _)        => None
            case World.TransitionThen.FadeIn               => None
            case World.TransitionThen.Ending               => None
        }) |> Option.toList

    /// 敵の並びに逃げられない敵がいるか（ボスの登場の音とボス戦の曲）。
    def isNoFleeGroup(res: Res.Res, foes: List[FoesDoc.FoeId]): Bool =
        foes |> List.exists(id -> FoesDoc.foeOrBlank(res#foes, id)#noFlee)

    /// お金の音: フィールドにいる前後のフレームでお金が変わった（宝箱・会話の <<gold>>・店・お礼）。
    /// WhyNot: 戦いから戻ったフレームでは鳴らさない — 勝ったお金はファンファーレと伝言が先に知らせている。
    def goldSoundsOf(before: World.World, after: World.World): List[World.Event] =
        let onField = w -> Option.nonEmpty(World.fieldRecOf(w));
        if (onField(before) and onField(after) and Bag.goldOf(before#bag) != Bag.goldOf(after#bag)) World.Event.Gold :: Nil else Nil

    // ── 曲（App.withSustained。素材は art/bgm.snd.star → assets/bgm） ──

    /// このフレームに鳴らし続ける曲（0 か 1 本）。
    pub def musicOf(res: Res.Res, w: World.World): List[App.Sustain] =
        trackOf(res, w) |> Option.map(t -> { name = Bgm.soundOf(t), volume = 1.0, pitch = 1.0 }) |> Option.toList

    /// 場面の曲: タイトル → タイトル / フィールド → マップの bgm（戦いの点滅に入ったら戦いの曲）/ 戦い → 戦いかボス戦の曲
    /// （勝ちと全滅の伝言の間は鳴らさない = ファンファーレと全滅の音）/ エンディング → 村の曲。
    pub def trackOf(res: Res.Res, w: World.World): Option[Bgm.Track] = match World.sceneKindOf(w) {
        case World.SceneKind.Title  => Some(Bgm.Track.Title)
        case World.SceneKind.Field  => World.fieldRecOf(w) |> Option.flatMap(fieldTrackOf(res))
        case World.SceneKind.Battle => World.battleRecOf(w) |> Option.flatMap(battleTrackOf(res))
        case World.SceneKind.Ending => Some(Bgm.Track.Village)
    }

    def fieldTrackOf(res: Res.Res, r: World.FieldRec): Option[Bgm.Track] =
        let fighting = r#transition |> Option.flatMap(t -> match t#then {
            case World.TransitionThen.StartBattle(foes, _) => Some(foes)
            case World.TransitionThen.Warp(_, _, _)        => None
            case World.TransitionThen.FadeIn               => None
            case World.TransitionThen.InnRest              => None
            case World.TransitionThen.Ending               => None
        });
        match fighting {
            case Some(foes) => Some(fightTrackOf(isNoFleeGroup(res, foes)))
            case None       => MapDoc.docOf(res#maps, r#map) |> Option.flatMap(m -> MapDoc.rec(m)#bgm)
        }

    def battleTrackOf(res: Res.Res, r: World.BattleRec): Option[Bgm.Track] = match r#phase {
        case World.Phase.Show(_, _, _, World.AfterShow.Leave(Battle.Outcome.Won))  => None
        case World.Phase.Show(_, _, _, World.AfterShow.Leave(Battle.Outcome.Lost)) => None
        case _ => Some(fightTrackOf(Battle.isNoFlee(res, r#battle)))
    }

    def fightTrackOf(noFlee: Bool): Bgm.Track = if (noFlee) Bgm.Track.Boss else Bgm.Track.Battle

    /// 音の通り道（rpg.mixer.json）。終了の確認を開いている間は snapshot「ask」（曲を籠もらせる）。
    pub def mixerOf(res: Res.Res, w: World.World): AudioMixer.Mixer =
        if (Option.nonEmpty(w#ask)) AudioMixer.withSnapshot("ask", res#mixer) else res#mixer

    /// トロッコの音: 前のフレームに走っていなかったのが、このフレームに走り出した（CartRide）。
    /// WhyNot: 走り出す所（WorldField.board）で出さない — 走れなかった時の知らせと同じ枝に音を混ぜず、出来事は前後の見比べ 1 か所にそろえる。
    def rideSoundsOf(before: World.World, after: World.World): List[World.Event] =
        let riding = w -> World.fieldRecOf(w) |> Option.flatMap(World.rideOf) |> Option.nonEmpty;
        if (not riding(before) and riding(after)) World.Event.CartRide :: Nil else Nil

    /// 会話の音: 閉じていたウィンドウに会話か知らせが開いた（TalkOpen）・文字送りが奇数字目に届いた（TalkBlip。話し手の声）。
    /// 同じ字の文字送りの続きなら前のフレームの字数から数え、新しい台詞なら 0 から数える（出し切りの早送りでも 1 回だけ鳴る）。
    /// WhyNot: 文字送りの関数（WorldTalk.tick）の中で出さない — 会話と知らせの 2 つの文字送りに同じ数え方を 2 回書くことになり、
    /// 開いた音も「閉じていた」前のフレームを知らない所では出せない。
    def talkSoundsOf(res: Res.Res, before: World.World, after: World.World): List[World.Event] =
        let opened = if (not World.isWindowOpen(before) and Option.nonEmpty(World.typingOf(after))) World.Event.TalkOpen :: Nil else Nil;
        let blip = World.typingOf(after) |> Option.flatMap(match (speaker, reveal) -> {
            let shown = UiTypewriter.visibleCount(reveal);
            let was = World.typingOf(before) |> Option.filter(pair -> snd(pair)#text == reveal#text)
                |> Option.map(pair -> UiTypewriter.visibleCount(snd(pair))) |> Option.getWithDefault(0);
            if ((shown + 1) / 2 > (was + 1) / 2) Some(World.Event.TalkBlip(TextDoc.voiceOf(speaker, res#text))) else None
        });
        List.append(opened, Option.toList(blip))

    /// 1 フレームの音: このフレームに溜まった出来事（Emit.since）を音へ写す（同じ音は 1 つ）。
    pub def sounds(ws: { before = World.World, after = World.World }): List[String] =
        Emit.since(ws#before#events, ws#after#events) |> List.map(soundOf) |> List.toSet |> Set.toList

    // ── Doc の読み直し（watchFile / F1） ──

    /// Doc の一覧表。docId は project.json の editor.resources[] の id。
    /// マップは読み直した後にいる所を収め（WorldField.settle）、会話は開いている会話（と店）を閉じる。
    /// 仲間の Doc は HP と MP を新しい最大へ、道具の Doc は消えた道具をふくろと装備から捨てる。
    pub def docTable(): List[DocTable.Entry[Resources.With[Res.Res, World.World]]] =
        let unchanged = (_, w) -> w;
        Resources.reloadRow("rules", RulesDoc.path(), res -> Res.withRules(RulesDoc.load(RulesDoc.path()), res), unchanged)
            :: Resources.reloadRow("text", TextDoc.path(), res -> Res.withText(TextDoc.load(TextDoc.path()), res), unchanged)
            :: Resources.reloadRow("keys", KeysDoc.path(), res -> Res.withKeys(KeysDoc.load(KeysDoc.path()), res), unchanged)
            :: Resources.reloadRow("party", PartyDoc.path(), res -> Res.withParty(PartyDoc.load(PartyDoc.path()), res), settleParty)
            :: Resources.reloadRow("items", ItemsDoc.path(), res -> Res.withItems(ItemsDoc.load(ItemsDoc.path()), res), settleItems)
            :: Resources.reloadRow("shops", ShopsDoc.path(), res -> Res.withShops(ShopsDoc.load(ShopsDoc.path()), res), unchanged)
            :: Resources.reloadRow("foes", FoesDoc.path(), res -> Res.withFoes(FoesDoc.load(FoesDoc.path()), res), WorldBattle.settle)
            :: Resources.reloadRow("foe_moves", FoeMovesDoc.path(), res -> Res.withFoeMoves(FoeMovesDoc.load(FoeMovesDoc.path()), res), unchanged)
            :: Resources.reloadRow("spells", SpellsDoc.path(), res -> Res.withSpells(SpellsDoc.load(SpellsDoc.path()), res), unchanged)
            :: Resources.reloadRow("recolors", RecolorsDoc.path(), res -> Res.withRecolors(RecolorsDoc.load(RecolorsDoc.path()), res), unchanged)
            :: Resources.reloadRow("mixer", Res.mixerPath(), res -> Res.withMixer(Res.loadMixer(), res), unchanged)
            :: Resources.reloadUnnamedRow(Talk.dialoguePath(), res -> Res.withDialogue(Talk.load(), res), (_, w) -> WorldTalk.close(w))
            :: Resources.reloadUnnamedRow(Palette.path(), reloadSprites, unchanged)
            :: List.append(
                MapDoc.names() |> List.map(name -> Resources.reloadRow("map", MapDoc.pathOf(name), res -> Res.withMaps(MapDoc.loadTable(res#items), res), WorldField.settle)),
                Sheet.all() |> List.map(id -> Resources.reloadRow("sprite", Sheet.pathOf(id), reloadSprites, unchanged)))

    def settleParty(res: Res.Res, w: World.World): World.World =
        WorldBattle.settle(res, { party = Party.settle(res#party, res#items, w#party) | w })

    def settleItems(res: Res.Res, w: World.World): World.World =
        { party = Party.settle(res#party, res#items, w#party), bag = Bag.settle(res#items, w#bag) | w }

    def reloadSprites(res: Res.Res): Res.Res \ Fs.FileRead =
        Res.withSprites(Palette.load(), Sheet.all() |> List.map(id -> (id, PxSpriteDoc.load(Sheet.pathOf(id)))) |> List.toMap, res)
}
