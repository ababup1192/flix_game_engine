// World — 遊びの状態そのものと、次の状態を作る規則（すべて純粋）。
// 夜の校舎を一人称で歩く。体（足元と足の着き方）は engine の CharacterBody3d が壁で止め・坂を上らせ・落とす。
// 向き（yaw・pitch）と歩いた長さ（頭の揺れの周期）はこのゲームが持つ。Doc と組んだ校舎は Res が持ち、World は持たない。
//
// ── 場面 ──
// 画面は Screen の enum で分け、その画面だけが持つ値は payload に入れる。歩いている Walk と、紙のマップを開いている Map
// （開いている間は歩かない。見ている階を持つ）・話している Talk・物を拾って目の前で見ている Pickup・アイテム画面の Items。
// 拾った物と開けた戸と行った部屋は、どの画面でも持ち歩く Session の progress に入れる。
mod World {

    use fge::{CharacterBody3d, Clock, Num, Scene3d, Scene3dCheck, UiTypewriter, Vec2, Vec3, Yarn, YarnRunner}

    /// このフレームの入力。forward・strafe・turn = -1 / 0 / +1 の軸・pitch = 見下ろす向きが +1 の軸（キー）・
    /// look = マウスの動き（px。視点を取り込んでいない時は 0。下へ動かすと見下ろす）・dash = 走るキーを押している・
    /// active = このコマに何かを操作した（キー・マウス・指・パッドのどれか。操作方法の表示を消す）。
    pub type alias Input = { forward = Float64, strafe = Float64, turn = Float64, pitch = Float64, look = Vec2.Vec2, dash = Bool, active = Bool }

    /// 終了の確認。Esc か窓の閉じるボタンで Asking（確認の窓を出し、体は止まる）、
    /// はいで Confirmed（Main の App.quitWhen がこれを見て閉じる）、いいえで Playing へ戻る。
    pub enum Quit with Eq, ToString {
        case Playing
        case Asking
        case Confirmed
    }

    /// マウスで押せる物（View が描く木に ZStack.hit で積み、Controls が SortingLayer.pickFrom で引く）。
    pub enum Press with Eq, ToString {
        case QuitYes   // 終了の確認の窓の中（Enter と同じ）
        case QuitNo    // 窓の外（Esc と同じ）
    }

    /// どの画面か。
    pub enum Screen {
        /// 校舎の中を歩いている。
        case Walk(Session)
        /// 紙のマップを開いている（歩いていた中身と、見ている階の番号）。
        case Map(Session, Int32)
        /// 人物と話している（歩いていた中身と、会話の中身）。歩けず、向きとピッチはそのまま。
        case Talk(Session, TalkRec)
        /// 物を拾って、目の前へ飛んできた物を見ている（拾う演出の間）。歩けず、見回せない。終わったら Walk へ戻る。
        case Pickup(Session, PickupRec)
        /// アイテム画面（持ち物の一覧と、選んだ物が目の前で回る）。歩けず、見回せない。
        case Items(Session, ItemsRec)
    }

    /// 拾う演出の中身。pickup = 拾った置き場所の id・started = 拾った時刻（World の t）。
    pub type alias PickupRec = { pickup = String, started = Float64 }

    /// アイテム画面の中身。cursor = 選んでいる持ち物の番号（0 から・持ち物の並びの順）・started = 開いた時刻（回り始め）。
    pub type alias ItemsRec = { cursor = Int32, started = Float64 }

    /// 開けた戸の記録。at = 開けた時刻（World の t）・door = 開けた時に向いていた戸口の真ん中（その戸だけが滑って開く。None ならどれも開き切った絵）。
    pub type alias Unlock = { at = Float64, door = Option[Vec3.Vec3] }

    /// どの画面でも持ち歩く進み具合。visited = 入ったことのある部屋の鍵（PaperMap.roomKey。マップに丸と名前が付く）・
    /// taken = 拾った置き場所の id（拾った順。持ち物はここから導く: Items.inventoryOf）・unlocked = 開けた部屋の id → 開けた記録。
    pub type alias Progress = { visited = Set[String], taken = List[String], unlocked = Map[String, Unlock] }

    /// 画面の下に少しの間だけ出す一言（「鍵がかかっている。」など）。started = 出した時刻（World の t）。
    pub type alias Notice = { text = String, started = Float64 }

    /// 会話の中身。who = 話している人物の id・runner = 台詞の実行器・line = 窓に出している行・reveal = その行の文字送り。
    pub type alias TalkRec = { who = String, runner = YarnRunner.Runner[Clock.Real], line = Option[Yarn.Line], reveal = UiTypewriter.Reveal }

    /// 歩いている間の中身。body = 足元と足の着き方・yaw = 左右の向き（ラジアン・0 で +Z・増えると +X へ）・
    /// pitch = 上下の向き（ラジアン・正で下）・walked = 歩いた水平の長さの合計（m。懐中電灯の揺れの周期）・
    /// steps = 踏んだ歩数（小数。歩いた長さをその時の 1 歩の長さで割って足した物。足音と頭の揺れの周期）・
    /// dashing = このコマ走っている・progress = 行った部屋・拾った物・開けた戸・notice = 出している一言。
    pub type alias SessionRec = { body = CharacterBody3d.Body, yaw = Float64, pitch = Float64, walked = Float64, steps = Float64, dashing = Bool,
                                  progress = Progress, notice = Option[Notice] }

    /// 作るのは World の中（initial・placeAt・step）だけ。
    enum SessionOf(SessionRec)

    pub type alias Session = SessionOf

    /// 遊びの状態。t は積み上げた秒（灯りのゆらぎ）。mouseCaptured = マウスを視点に取り込んでいる（クリックで取り込み・Esc で放す）。
    /// doorAt = 最後に初めて入った部屋の戸口（入った時の足元。戸の音はそこで鳴った音として、離れるほど小さく聞こえる）。
    /// idle = 何も操作していない秒・hint = 操作方法の表示の出具合（0 で消えている・1 で出切っている）。
    /// attention = 最後に話しかけた人物の記録（体と首の向き・身振り。話し終えた後も、人物が元の向きへ戻るのに使う）。
    pub type alias World = {
        t = Float64,
        screen = Screen,
        quit = Quit,
        mouseCaptured = Bool,
        perf = Option[Perf],
        caption = RoomCaption.State,
        doorAt = Option[Vec3.Vec3],
        idle = Float64,
        hint = Float64,
        attention = Option[Cast.Attention]
    }

    /// 重さの表示（F3）。1 秒ごとに締めた fps と、その 1 秒の一番長いコマの fps（low）。acc・frames・maxDt = 締める前の 1 秒の途中の値。
    /// CPU と GPU の ms・draw call は描く時に ctx#diagnostics から読む（View）。
    // WhyNot: Frame#diagnostics を World へ写さない — 遊んだ記録に残らず、再生と食い違う（engine の docs/migrations/0.84.1.md）。dt は記録に残る。
    pub type alias Perf = { acc = Float64, frames = Int32, maxDt = Float64, fps = Float64, low = Float64 }

    /// 重さの表示を出す・消す。
    pub def togglePerf(w: World): World =
        { perf = if (Option.isEmpty(w#perf)) Some({ acc = 0.0, frames = 0, maxDt = 0.0, fps = 0.0, low = 0.0 }) else None | w }

    /// 重さの表示に 1 コマを足す（出していなければ何もしない）。
    pub def notePerf(dt: Float64, w: World): World = match w#perf {
        case None    => w
        case Some(p) =>
            let acc = p#acc + dt;
            let frames = p#frames + 1;
            let maxDt = Float64.max(p#maxDt, dt);
            let next = if (acc >= 1.0) { acc = 0.0, frames = 0, maxDt = 0.0, fps = Int32.toFloat64(frames) / acc, low = 1.0 / Float64.max(0.0001, maxDt) }
                       else { acc = acc, frames = frames, maxDt = maxDt | p };
            { perf = Some(next) | w }
    }

    /// 目から見た今の様子（View と問いが読む）。eye = 目の位置（頭の揺れを足した後）・feet = 足元。
    pub type alias Pov = { eye = Vec3.Vec3, feet = Vec3.Vec3, yaw = Float64, pitch = Float64, walked = Float64 }

    // ── 画面の寸法（design 320×240。project.json と同じ値） ──

    pub def width(): Float64 = 320.0
    pub def height(): Float64 = 240.0

    /// 体の動き方（半径と高さは Doc・段と坂と吸い付きは engine の既定）。
    def bodySettings(res: Res.Res): CharacterBody3d.Settings =
        let wk = Res.walkOf(res);
        CharacterBody3d.settings(wk#radius, wk#height)

    /// 校舎の見た目（階ごとの集まりから、通り抜けられる小物を除いた物）と当たり判定の箱の食い違い（Scene3dCheck.check。テストが Nil を求める）。
    pub def collisionProblems(res: Res.Res): List[Scene3dCheck.Problem] =
        let visible = res#school#groups |> Map.valuesOf |> List.flatMap(Scene3d.groupInstancesOf) |> List.filter(i -> not isWalkThrough(Scene3d.nameOf(i)));
        Scene3dCheck.check(visible, res#school#collision, bodySettings(res), res#layout#start#pos)

    /// 当たりの箱を置かず、体が通り抜けられる小物か（glb のノードの名前の頭で見る）。
    // WhyNot: 小物の全部を見た目から外さない — 戸棚や教卓の当たりの箱が、見た目の無い見えない壁に見える。
    def isWalkThrough(name: String): Bool =
        walkThroughProps() |> List.exists(kind -> String.startsWith(prefix = "prop_${kind}", name))

    /// 当たりの箱を置かない小物の種類（机と椅子・カーテン・机の上の物・譜面台など）。机や椅子に当たりを置く校舎へ直したら、ここから外す。
    def walkThroughProps(): List[String] =
        "desk" :: "chair" :: "stool" :: "officechair" :: "teacherchair" :: "curtain" :: "textbook" :: "pencil_case" :: "musicstand" :: "easel" ::
        "plant" :: "map_roll" :: "light_fixture" :: "globe" :: "screen" :: "scale" :: "notice_board" :: "bucket" :: "door" :: Nil

    /// ゲーム開始時の状態。表の spawn（1 階の昇降口）に立つ。
    pub def initial(res: Res.Res): World =
        let s = res#layout#start;
        { t = 0.0, screen = Screen.Walk(SessionOf.SessionOf(standing(res, s#pos, s#yaw, { visited = Set.empty(), taken = Nil, unlocked = Map.empty() }))), quit = Quit.Playing, mouseCaptured = false, perf = None, caption = RoomCaption.empty(), doorAt = None, idle = 0.0, hint = 0.0, attention = None }

    def standing(res: Res.Res, feet: Vec3.Vec3, yaw: Float64, progress: Progress): SessionRec =
        let body = CharacterBody3d.snapToFloor(res#school#collision, Nil, bodySettings(res), CharacterBody3d.bodyAt(feet));
        { body = body, yaw = yaw, pitch = 0.0, walked = 0.0, steps = 0.0, dashing = false,
          progress = { visited = visit(res, body#feet, progress#visited) | progress }, notice = None }

    /// 上下の向き（ラジアン・正で見下ろす）。
    pub def pitchOf(w: World): Float64 = sessionOf(w)#pitch

    /// 足元が部屋の中なら、その部屋を行った部屋に足す。
    def visit(res: Res.Res, feet: Vec3.Vec3, visited: Set[String]): Set[String] =
        PaperMap.roomAt(res#layout, feet) |> Option.map(k -> Set.insert(k, visited)) |> Option.getWithDefault(visited)

    /// 足元 feet・向き yaw に立たせ直し、上下の向きは今のまま残す（描き出しの場面が見下ろした所を作る）。
    pub def turnTo(res: Res.Res, feet: Vec3.Vec3, yaw: Float64, w: World): World =
        let pitch = sessionOf(w)#pitch;
        { screen = Screen.Walk(SessionOf.SessionOf({ pitch = pitch | standing(res, feet, yaw, sessionOf(w)#progress) })) | w }

    /// 足元 feet・向き yaw に立たせ直す（下の床に合わせる。行った部屋は覚えたまま・歩く画面へ戻る）。
    pub def placeAt(res: Res.Res, feet: Vec3.Vec3, yaw: Float64, w: World): World =
        { screen = Screen.Walk(SessionOf.SessionOf(standing(res, feet, yaw, sessionOf(w)#progress))) | w }

    def sessionRec(session: Session): SessionRec = match session {
        case SessionOf.SessionOf(rec) => rec
    }

    def sessionOf(w: World): SessionRec = sessionRec(screenSession(w#screen))

    def screenSession(screen: Screen): Session = match screen {
        case Screen.Walk(session)      => session
        case Screen.Map(session, _)    => session
        case Screen.Talk(session, _)   => session
        case Screen.Pickup(session, _) => session
        case Screen.Items(session, _)  => session
    }

    /// 今の画面のまま、持ち歩く中身だけを f で替える。
    def mapSession(f: SessionRec -> SessionRec, w: World): World =
        let next = SessionOf.SessionOf(f(sessionOf(w)));
        let screen = match w#screen {
            case Screen.Walk(_)      => Screen.Walk(next)
            case Screen.Map(_, n)    => Screen.Map(next, n)
            case Screen.Talk(_, t)   => Screen.Talk(next, t)
            case Screen.Pickup(_, p) => Screen.Pickup(next, p)
            case Screen.Items(_, i)  => Screen.Items(next, i)
        };
        { screen = screen | w }

    def mapProgress(f: Progress -> Progress, w: World): World = mapSession(s -> { progress = f(s#progress) | s }, w)

    /// 歩いている間だけ中身を f で替える（マップを開いている間はそのまま）。
    def mapWalking(f: SessionRec -> SessionRec, w: World): World = match w#screen {
        case Screen.Walk(session) => { screen = Screen.Walk(SessionOf.SessionOf(f(sessionRec(session)))) | w }
        case _                    => w
    }

    /// 踏んだ歩数（小数。足音の数を出す）。
    pub def stepsOf(w: World): Float64 = sessionOf(w)#steps

    /// 走っているか（走るキーを押して前へ進んでいる。足音を大きくする）。
    pub def isDashing(w: World): Bool = match w#screen {
        case Screen.Walk(session) => sessionRec(session)#dashing
        case _                    => false
    }

    /// 行った部屋の鍵。
    pub def visitedOf(w: World): Set[String] = sessionOf(w)#progress#visited

    /// 行った部屋を足す（描き出しの場面が使う）。
    pub def withVisited(keys: Set[String], w: World): World = mapProgress(p -> { visited = Set.union(keys, p#visited) | p }, w)

    // ── 持ち物と鍵の戸 ──

    /// 拾った置き場所の id（拾った順）。
    pub def takenOf(w: World): List[String] = sessionOf(w)#progress#taken

    /// 持ち物（拾った順・同じ物は 1 つ）。
    pub def inventoryOf(res: Res.Res, w: World): List[ItemsDoc.Item] = Items.inventoryOf(res#items, takenOf(w))

    /// 持ち物の id（拾った順・同じ物は 1 つ）。
    pub def inventoryIdsOf(res: Res.Res, w: World): List[String] = inventoryOf(res, w) |> List.map(i -> i#id)

    /// 開けた部屋 id → 開けた記録。
    pub def unlockedOf(w: World): Map[String, Unlock] = sessionOf(w)#progress#unlocked

    pub def isUnlocked(room: String, w: World): Bool = Map.memberOf(room, unlockedOf(w))

    /// 出している一言（無ければ None。消えたかは描く側が noticeSec で決める）。
    pub def noticeOf(w: World): Option[Notice] = sessionOf(w)#notice

    /// 部屋 rooms の戸を、ずっと前に開けたことにする（始まりの口と描き出しの場面。最初のコマから開き切った絵）。
    pub def withUnlocked(rooms: List[String], w: World): World =
        mapProgress(p -> { unlocked = rooms |> List.foldLeft((acc, room) -> Map.insert(room, { at = w#t - 100.0, door = None }, acc), p#unlocked) | p }, w)

    /// 持ち物 ids を持っていることにする（Doc で最初にその物を置いた所を拾った事にする・床からも消える）。置き場所の無い物は知らない物として返す。
    pub def withItems(res: Res.Res, ids: List[String], w: World): Result[String, World] =
        ids |> List.foldLeft((acc, id) -> acc |> Result.flatMap(cur ->
            Items.firstPickupOf(res#items, id) |> Option.toOk("持ち物 '${id}' は items.kind.json の置き場所に無い")
                |> Result.map(pickup -> mapProgress(p -> { taken = if (List.memberOf(pickup, p#taken)) p#taken else List.append(p#taken, pickup :: Nil) | p }, cur))), Ok(w))

    /// 前の扇形（人物に話しかける時と同じ）。
    def coneOf(res: Res.Res, s: SessionRec): Cast.Cone = Cast.coneOf(res#cast, s#body#feet, s#yaw)

    /// 形の読めた持ち物か（ブラウザ版で glb が届く前の物は描かないので、拾えない）。
    def isLoaded(res: Res.Res, item: ItemsDoc.Item): Bool = Map.memberOf(Res.itemModelKey(item), res#assets#props)

    /// 目の前の拾える物（歩いている間だけ・目の前に人物がいれば None — 話しかけが先）。
    pub def pickupTargetOf(res: Res.Res, w: World): Option[ItemsDoc.Pickup] = match w#screen {
        case Screen.Walk(session) if Option.isEmpty(talkTargetOf(res, w)) =>
            let s = sessionRec(session);
            Items.facedPickup(res#layout, res#items, coneOf(res, s), s#progress#taken, isLoaded(res))
        case _ => None
    }

    /// 目の前の鍵の戸（歩いている間だけ・人物と拾える物が先）。
    pub def doorTargetOf(res: Res.Res, w: World): Option[Items.Door] = match w#screen {
        case Screen.Walk(session) if Option.isEmpty(talkTargetOf(res, w)) and Option.isEmpty(pickupTargetOf(res, w)) =>
            let s = sessionRec(session);
            Items.facedDoor(res#layout, res#doors, coneOf(res, s), room -> Map.memberOf(room, s#progress#unlocked))
        case _ => None
    }

    /// 目の前の物を拾う: 床から消して（拾った物に足す）、拾う演出を始める。拾える物が無ければそのまま。
    pub def startPickup(res: Res.Res, w: World): World = match (w#screen, pickupTargetOf(res, w)) {
        case (Screen.Walk(session), Some(p)) =>
            let s = sessionRec(session);
            let next = { progress = { taken = List.append(s#progress#taken, p#id :: Nil) | s#progress }, notice = None | s };
            { screen = Screen.Pickup(SessionOf.SessionOf(next), { pickup = p#id, started = w#t }) | w }
        case _ => w
    }

    /// 拾う演出の中身（演出の間でなければ None）。
    pub def pickupOf(w: World): Option[PickupRec] = match w#screen {
        case Screen.Pickup(_, p) => Some(p)
        case _                   => None
    }

    pub def isPickingUp(w: World): Bool = Option.nonEmpty(pickupOf(w))

    /// 拾う演出を終えて歩く画面へ戻る（決定で早めに閉じる・時間が来たら step が閉じる）。目の前へ飛んでくる間は閉じない。
    pub def endPickup(res: Res.Res, w: World): World = match w#screen {
        case Screen.Pickup(session, p) if w#t - p#started >= ItemsDoc.rec(res#items)#pickup#flySec => { screen = Screen.Walk(session) | w }
        case _ => w
    }

    /// 演出の秒（飛ぶ秒と見せる秒）が過ぎたら歩く画面へ戻る。
    def finishPickup(res: Res.Res, w: World): World = match w#screen {
        case Screen.Pickup(session, p) =>
            let d = ItemsDoc.rec(res#items)#pickup;
            if (w#t - p#started >= d#flySec + d#showSec) { screen = Screen.Walk(session) | w } else w
        case _ => w
    }

    /// 目の前の鍵の戸を調べる: 鍵を持っていれば開け（その戸だけ滑って開く・当たりも抜ける）「〇〇で開けた。」、無ければ「鍵がかかっている。」。
    /// 戸の音はその戸口で鳴った音にする（doorAt）。
    pub def tryDoor(res: Res.Res, w: World): World = match doorTargetOf(res, w) {
        case Some(door) =>
            let texts = ItemsDoc.rec(res#items)#texts;
            let key = Items.keyOf(res#items, door#room) |> Option.filter(k -> Items.holds(res#items, takenOf(w), k#id));
            let opened = match key {
                case Some(k) => mapSession(s -> { progress = { unlocked = Map.insert(door#room, { at = w#t, door = Some(door#center) }, s#progress#unlocked) | s#progress },
                                                  notice = Some({ text = ItemsDoc.fill(texts#opened, k#name), started = w#t }) | s }, w)
                case None    => mapSession(s -> { notice = Some({ text = texts#locked, started = w#t }) | s }, w)
            };
            { doorAt = Some(door#center) | opened }
        case None => w
    }

    // ── アイテム画面 ──

    /// アイテム画面の中身（開いていなければ None）。
    pub def itemsScreenOf(w: World): Option[ItemsRec] = match w#screen {
        case Screen.Items(_, i) => Some(i)
        case _                  => None
    }

    pub def isItemsOpen(w: World): Bool = Option.nonEmpty(itemsScreenOf(w))

    /// アイテム画面を開く（歩いている間だけ・最初の持ち物を選ぶ）。
    pub def openItems(w: World): World = match w#screen {
        case Screen.Walk(session) => { screen = Screen.Items(session, { cursor = 0, started = w#t }) | w }
        case _                    => w
    }

    pub def closeItems(w: World): World = match w#screen {
        case Screen.Items(session, _) => { screen = Screen.Walk(session) | w }
        case _                        => w
    }

    /// 選んでいる持ち物を d 個ずらす（端で止まる）。選び直したら回り始めからにする。
    pub def moveItemCursor(res: Res.Res, d: Int32, w: World): World = match w#screen {
        case Screen.Items(session, i) =>
            let last = Int32.max(0, List.length(inventoryOf(res, w)) - 1);
            let cursor = Int32.min(last, Int32.max(0, i#cursor + d));
            if (cursor == i#cursor) w else { screen = Screen.Items(session, { cursor = cursor, started = w#t }) | w }
        case _ => w
    }

    // ── 紙のマップ ──

    /// マップで見ている階（開いていなければ None）。
    pub def mapFloorOf(w: World): Option[Int32] = match w#screen {
        case Screen.Map(_, n) => Some(n)
        case _                => None
    }

    pub def isMapOpen(w: World): Bool = Option.nonEmpty(mapFloorOf(w))

    /// マップを開く（今いる階を見る）。
    pub def openMap(res: Res.Res, w: World): World = match w#screen {
        case Screen.Walk(session) => { screen = Screen.Map(session, Layout.floorIndexAt(sessionRec(session)#body#feet#y, res#layout)) | w }
        case _                    => w
    }

    pub def closeMap(w: World): World = match w#screen {
        case Screen.Map(session, _) => { screen = Screen.Walk(session) | w }
        case _                      => w
    }

    // ── 会話 ──

    /// 話している会話の中身（話していなければ None）。
    pub def talkOf(w: World): Option[TalkRec] = match w#screen {
        case Screen.Talk(_, t) => Some(t)
        case _                 => None
    }

    pub def isTalking(w: World): Bool = Option.nonEmpty(talkOf(w))

    /// 話しかけられる相手（歩いている間だけ・形の読めた人物だけ。ブラウザ版で glb が届く前の人物は見えないので、話しかけられない）。
    // WhyNot: 届く前の人物に話しかけて engine の待ち（App.withLoadGate）に任せない — 押した時の待ちは、押す前 1.5 秒の内に向きを変えた
    //   キーの押しっぱなしを渡し直さないので、待ちの明けた所で相手の方を向いておらず、話しかけが空振りする。
    pub def talkTargetOf(res: Res.Res, w: World): Option[CastDoc.Member] = match w#screen {
        case Screen.Walk(session) => Cast.facedMember(res#cast, sessionRec(session)#body#feet, sessionRec(session)#yaw)
            |> Option.filter(m -> Map.memberOf(m#model, res#people))
        case _                    => None
    }

    /// 見ている相手に話しかける（相手がいなければそのまま）。相手の .yarn のノードを始め、最初の行を窓に出す。now = 実時間（frame#realNow）。
    // WhyNot: 会話の実行器に遊びの時計を作らない — 台詞に <<wait>> を使わないので、実行器の時刻は実時間で足りる（時計を数から作ると遊びの時計の抜け道になる）。
    pub def startTalk(res: Res.Res, now: Clock.Time[Clock.Real], w: World): World = match (w#screen, talkTargetOf(res, w)) {
        case (Screen.Walk(session), Some(m)) =>
            let (runner, events) = YarnRunner.start(res#dialogue, m#node, now);
            let talk = showEvents(events, { who = m#id, runner = runner, line = None, reveal = UiTypewriter.done("") });
            let attention = Cast.attend(res#cast, m, sessionRec(session)#body#feet, w#t, w#attention);
            if (YarnRunner.isOpen(runner)) { screen = Screen.Talk(session, talk), attention = Some(attention) | w } else w
        case _ => w
    }

    /// 実行器の出来事のうち最後の行を窓に出す（選択肢・コマンドは今の台詞では出ない）。
    def showEvents(events: List[YarnRunner.Event], talk: TalkRec): TalkRec =
        events |> List.foldLeft((t, e) -> match e {
            case YarnRunner.Event.Line(line) => { line = Some(line), reveal = UiTypewriter.start(line#text) | t }
            case _                           => t
        }, talk)

    /// 文字送り・決定（クリック・Space・Enter）: 行の途中なら全文を出し、出し切っていれば次の行へ。台詞が終われば歩く画面へ戻る。
    pub def advanceTalk(now: Clock.Time[Clock.Real], w: World): World = match w#screen {
        case Screen.Talk(session, talk) =>
            if (not UiTypewriter.isDone(talk#reveal)) { screen = Screen.Talk(session, { reveal = UiTypewriter.skip(talk#reveal) | talk }) | w }
            else {
                let (runner, events) = YarnRunner.step(YarnRunner.Action.Advance, now, talk#runner);
                if (YarnRunner.isOpen(runner)) { screen = Screen.Talk(session, showEvents(events, { runner = runner | talk })), attention = Option.map(Cast.nextLine(w#t), w#attention) | w }
                else finishTalk(session, w)
            }
        case _ => w
    }

    /// 会話を途中でやめる（Esc）。
    pub def endTalk(w: World): World = match w#screen {
        case Screen.Talk(session, _) => finishTalk(session, w)
        case _                       => w
    }

    /// 歩く画面へ戻り、話していた人物に話し終えた時刻とプレイヤーの足元を渡す（人物が少し向いたままでいてから戻る）。
    def finishTalk(session: Session, w: World): World =
        { screen = Screen.Walk(session), attention = Option.map(Cast.finish(w#t, sessionRec(session)#body#feet), w#attention) | w }

    /// 会話の文字送りを dt 秒進める。
    def revealTalk(cps: Float64, dt: Float64, w: World): World = match w#screen {
        case Screen.Talk(session, talk) => { screen = Screen.Talk(session, { reveal = UiTypewriter.step(cps = cps, dt, talk#reveal) | talk }) | w }
        case _                          => w
    }

    /// マップで階 index を見る（表に無い階なら今のまま）。
    pub def showFloor(res: Res.Res, index: Int32, w: World): World = match w#screen {
        case Screen.Map(session, _) if Option.nonEmpty(Layout.floorAt(index, res#layout)) => { screen = Screen.Map(session, index) | w }
        case _ => w
    }

    /// マップで見ている階を d 階ずらす（一番上と一番下で止まる）。
    pub def shiftFloor(res: Res.Res, d: Int32, w: World): World =
        mapFloorOf(w) |> Option.map(n -> showFloor(res, n + d, w)) |> Option.getWithDefault(w)

    /// 足元（問いとテストが読む）。
    pub def feetOf(w: World): Vec3.Vec3 = sessionOf(w)#body#feet

    /// 左右の向き（ラジアン）。
    pub def yawOf(w: World): Float64 = sessionOf(w)#yaw

    /// 床に立っているか（落ちている間は偽）。
    pub def isOnFloor(w: World): Bool = CharacterBody3d.isOnFloor(sessionOf(w)#body)

    /// 目から見た今の様子。頭は 1 歩ごとに 1 回沈む（踏んだ歩数の位相。足音と同じ周期）。
    pub def povOf(res: Res.Res, w: World): Pov =
        let s = sessionOf(w);
        let wk = Res.walkOf(res);
        let phase = s#steps * Num.pi();
        let bob = 0.0 - wk#bob * Float64.abs(Num.sin(phase));
        let feet = s#body#feet;
        { eye = Vec3.v3(feet#x, feet#y + wk#eyeHeight + bob, feet#z), feet = feet, yaw = s#yaw, pitch = s#pitch, walked = s#walked }

    /// 入力と経過時間から次の状態を作る。終了の確認の窓が出ている間は動かない（時刻だけ進む）。
    pub def step(res: Res.Res, input: Input, dt: Float64, w: World): World =
        let advanced = { t = w#t + dt | w };
        let walked = if (w#quit != Quit.Playing) advanced else finishPickup(res, revealTalk(CastDoc.rec(res#cast)#cps, dt, mapWalking(walk(res, input, dt), advanced)));
        let entered = Set.size(visitedOf(walked)) > Set.size(visitedOf(w));
        let moved = if (entered) { doorAt = Some(feetOf(walked)) | walked } else walked;
        let wk = Res.walkOf(res);
        let target = RoomCaption.targetOf(res#layout, { reach = wk#signReach, angleDeg = wk#captionAngleDeg }, feetOf(moved), yawOf(moved));
        let captioned = { caption = RoomCaption.step(target, wk#captionDelay, wk#captionFade, dt, moved#caption) | moved };
        stepHint(wk#hint, input#active, dt, captioned)

    /// 操作方法の表示: 歩く画面で何も操作しない秒が Doc の wait に届いたら出し始め、操作したら消し始める（どちらも fade 秒で）。
    /// 会話・マップ・終了の確認の間は消す。
    def stepHint(h: WalkDoc.Hint, active: Bool, dt: Float64, w: World): World =
        let idle = if (active) 0.0 else w#idle + dt;
        let walking = match w#screen {
            case Screen.Walk(_) => w#quit == Quit.Playing
            case _              => false
        };
        let target = if (walking and idle >= h#wait) 1.0 else 0.0;
        let rate = dt / Float64.max(0.01, h#fade);
        let hint = if (target > w#hint) Float64.min(target, w#hint + rate) else Float64.max(target, w#hint - rate);
        { idle = idle, hint = hint | w }

    /// 操作方法の表示の出具合（0〜1。View が濃さに掛ける）。
    pub def controlsHintOf(w: World): Float64 = w#hint

    /// 向きを変えてから、向いた方へ歩く。壁と家具で止まり、斜めに当たれば沿って滑り、坂では高さが変わる。
    def walk(res: Res.Res, input: Input, dt: Float64, s: SessionRec): SessionRec =
        let wk = Res.walkOf(res);
        let rad = Num.pi() / 180.0;
        let yaw = s#yaw + input#turn * wk#turnDegPerSec * rad * dt + input#look#x * wk#mouseDegPerPx * rad;
        // 上下の向きは見る向きだけを替える。歩く向きは yaw だけで決める（見下ろして歩いても遅くならない）。
        let pitchMax = wk#pitchLimitDeg * rad;
        let pitch = Num.clamp(0.0 - pitchMax, pitchMax, s#pitch + input#pitch * wk#pitchDegPerSec * rad * dt + input#look#y * wk#mouseDegPerPx * rad);
        // WhyNot: 横歩きと後ろは走らせない — 振り向かずに速く逃げられると、背後を見ないまま歩ける。
        let dashing = input#dash and input#forward > 0.0;
        let forwardSpeed = if (dashing) wk#dashSpeed else wk#speed;
        let ahead = if (input#forward >= 0.0) input#forward * forwardSpeed else input#forward * wk#backSpeed;
        let side = input#strafe * wk#speed * 0.8;
        let raw = Vec3.v3(ahead * Num.sin(yaw) + side * Num.cos(yaw), 0.0, ahead * Num.cos(yaw) - side * Num.sin(yaw));
        let limit = Float64.max(forwardSpeed, wk#backSpeed);
        let len = Vec3.length(raw);
        let motion = if (len > limit) Vec3.mul(raw, limit / len) else raw;
        let moving = List.append(Cast.boxesOf(res#cast), Items.closedBoxes(res#doors, room -> Map.memberOf(room, s#progress#unlocked)));
        let body = CharacterBody3d.moveAndSlide(res#school#collision, moving, bodySettings(res), motion, dt, s#body);
        let dx = body#feet#x - s#body#feet#x;
        let dz = body#feet#z - s#body#feet#z;
        let moved = Num.sqrt(dx * dx + dz * dz);
        let stride = Float64.max(0.1, if (dashing) wk#dashStride else wk#stride);
        { body = body, yaw = yaw, pitch = pitch, walked = s#walked + moved, steps = s#steps + moved / stride, dashing = dashing,
          progress = { visited = visit(res, body#feet, s#progress#visited) | s#progress } | s }

    // ── マウスの視点 ──

    /// マウスを視点に取り込みたいか（App.withMouseCapture。確認の窓が出ている間は放す）。
    // WhyNot: 拾う演出とアイテム画面の間は放さない — 閉じるたびにクリックで取り込み直すことになる（見回しは step が止める）。
    pub def wantsMouseCapture(w: World): Bool = w#mouseCaptured and w#quit == Quit.Playing and not isMapOpen(w) and not isTalking(w)

    pub def isMouseCaptured(w: World): Bool = w#mouseCaptured

    pub def captureMouse(w: World): World = { mouseCaptured = true | w }

    pub def releaseMouse(w: World): World = { mouseCaptured = false | w }

    // ── 終了の確認 ──

    /// Esc・閉じるボタン: 遊んでいる間なら確認の窓を出す。
    pub def askQuit(w: World): World =
        if (w#quit == Quit.Playing) { quit = Quit.Asking | w } else w

    /// 確認の窓への答え（yes なら終わる・no なら遊びへ戻る）。窓が出ていないときは何もしない。
    pub def answerQuit(yes: Bool, w: World): World =
        if (w#quit != Quit.Asking) w
        else if (yes) { quit = Quit.Confirmed | w }
        else { quit = Quit.Playing | w }

    pub def isAskingQuit(w: World): Bool = w#quit == Quit.Asking

    pub def isQuitting(w: World): Bool = w#quit == Quit.Confirmed
}
