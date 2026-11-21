// Cast — 校舎にいる人物の決まり（純粋）: 話しかけられる相手を選ぶ・人物の体の当たり・話す相手へ体と首をどれだけ回すか・どの身振りをするか。
// 置き場所と決まりの値は CastDoc（characters.kind.json）。描くのは SchoolView（骨つきの glb を毎コマ instances に置く）。
mod Cast {
    use fge::{CollisionShape3d, Num, Vec3}
    use CastDoc.Member

    /// 2 つの向きの差（−π..π）。
    def angleBetween(a: Float64, b: Float64): Float64 =
        let d = a - b;
        Num.atan2(Num.sin(d), Num.cos(d))

    /// 前の扇形（話しかけ・拾う・戸を調べるで同じ物）。feet = 足元・yaw = 向き・reach = 届く水平の距離（m）・angleDeg = 視線の正面から何度以内か。
    pub type alias Cone = { feet = Vec3.Vec3, yaw = Float64, reach = Float64, angleDeg = Float64 }

    /// 人物に話しかける時の扇形（Doc の talkReach と talkAngleDeg）。
    pub def coneOf(doc: CastDoc.Doc, feet: Vec3.Vec3, yaw: Float64): Cone =
        let d = CastDoc.rec(doc);
        { feet = feet, yaw = yaw, reach = d#talkReach, angleDeg = d#talkAngleDeg }

    /// 点 at が扇形の中なら、視線の正面からの角の大きさ（ラジアン・0 以上）。外なら None。高さは見ない。
    def offAngle(cone: Cone, at: Vec3.Vec3): Option[Float64] =
        let dx = at#x - cone#feet#x;
        let dz = at#z - cone#feet#z;
        let off = Float64.abs(angleBetween(Num.atan2(dx, dz), cone#yaw));
        if (Num.sqrt(dx * dx + dz * dz) <= cone#reach and off <= cone#angleDeg * Num.pi() / 180.0) Some(off) else None

    /// 扇形の中の物のうち、角の小さい方。
    pub def nearestInCone(cone: Cone, at: a -> Vec3.Vec3, xs: List[a]): Option[a] =
        xs |> List.filterMap(x -> offAngle(cone, at(x)) |> Option.map(off -> (off, x)))
            |> List.minimumBy((a, b) -> fst(a) <=> fst(b))
            |> Option.map(snd)

    /// 話しかけられる相手: 同じ階（高さの差 1 m 以内）・talkReach m 以内・視線の正面から talkAngleDeg 度以内のうち、角の小さい方。
    pub def facedMember(doc: CastDoc.Doc, feet: Vec3.Vec3, yaw: Float64): Option[Member] =
        CastDoc.rec(doc)#members
            |> List.filter(m -> Float64.abs(m#feet#y - feet#y) < 1.0)
            |> nearestInCone(coneOf(doc, feet, yaw), m -> m#feet)

    /// 番号 id の人物。
    pub def memberOf(doc: CastDoc.Doc, id: String): Option[Member] = CastDoc.rec(doc)#members |> List.find(m -> m#id == id)

    /// 人物の体の当たり（足元から 1.6 m・半径 0.25 m の四角い柱）。プレイヤーは人物を通り抜けない。
    pub def boxesOf(doc: CastDoc.Doc): List[CollisionShape3d.Box3d] =
        CastDoc.rec(doc)#members |> List.map(m ->
            CollisionShape3d.box3d(Vec3.v3(m#feet#x, m#feet#y + 0.8, m#feet#z), Vec3.v3(0.25, 0.8, 0.25)))

    /// 人物がプレイヤーに気を向けている間の記録（体と首の向き・身振りを決める）。who = 人物の id・started = 話しかけた時刻・
    /// fromBody = 話しかけた時に体がもう回っていた角（ラジアン。前の会話から戻る途中なら 0 でない）・line = 窓に出している行の番号（0 から）・
    /// lineAt = その行を出した時刻・ended = 話し終えた時刻と、その時のプレイヤーの足元（話している間は None）。
    pub type alias Attention = { who = String, started = Float64, fromBody = Float64, line = Int32, lineAt = Float64, ended = Option[(Float64, Vec3.Vec3)] }

    /// 体と首を、置いた向き（Member#yaw）からどれだけ回すか（ラジアン・engine の yaw と同じ回り）。
    pub type alias Facing = { body = Float64, head = Float64 }

    /// 今の身振り: clip = glb のアニメの名前・t = 身振りの始まりからの秒・weight = 混ぜる重みの上限（話し終えた後に薄めていく）。
    pub type alias Gesture = { clip = String, t = Float64, weight = Float64 }

    /// 話しかけ始める記録。前の記録が同じ人物なら、まだ戻り切っていない体の角から向き直る。
    pub def attend(doc: CastDoc.Doc, m: Member, player: Vec3.Vec3, now: Float64, prev: Option[Attention]): Attention =
        let turned = prev |> Option.filter(a -> a#who == m#id) |> Option.map(a -> facingOf(doc, m, player, now, a)#body) |> Option.getWithDefault(0.0);
        { who = m#id, started = now, fromBody = turned, line = 0, lineAt = now, ended = None }

    /// 次の行を出した。
    pub def nextLine(now: Float64, a: Attention): Attention = { line = a#line + 1, lineAt = now | a }

    /// 話し終えた（台詞の終わり・途中でやめた）。
    pub def finish(now: Float64, player: Vec3.Vec3, a: Attention): Attention = { ended = Some((now, player)) | a }

    /// 0..1 の進み具合を、出だしと終わりをゆっくりにした 0..1 にする。
    def ease(x: Float64): Float64 =
        let p = Num.clamp01(x);
        p * p * (3.0 - 2.0 * p)

    /// 置いた向きから見た、プレイヤーの足元の向き（ラジアン）。
    def towards(m: Member, player: Vec3.Vec3): Float64 =
        angleBetween(Num.atan2(player#x - m#feet#x, player#z - m#feet#z), m#yaw)

    /// 話している間の体の角: fromBody からプレイヤーの向きへ bodyTurnSec かけて回る。
    def bodyWhileTalking(d: CastDoc.Rec, m: Member, player: Vec3.Vec3, now: Float64, a: Attention): Float64 =
        a#fromBody + angleBetween(towards(m, player), a#fromBody) * ease((now - a#started) / Float64.max(0.01, d#bodyTurnSec))

    /// 体を body まで回した時に、首が残りをどれだけ回すか（headMaxDeg で止める）。
    def headRest(d: CastDoc.Rec, m: Member, player: Vec3.Vec3, body: Float64): Float64 =
        let limit = d#headMaxDeg * Num.pi() / 180.0;
        Num.clamp(0.0 - limit, limit, angleBetween(towards(m, player), body))

    /// 体と首の角。話している間は首が先にプレイヤーへ向き、体が後から追い付いて首の分が減る。
    /// 話し終えたら lingerSec の間はそのまま（首だけ離れていくプレイヤーを追う）、それから returnSec かけて置いた向きへ戻る。
    pub def facingOf(doc: CastDoc.Doc, m: Member, player: Vec3.Vec3, now: Float64, a: Attention): Facing =
        let d = CastDoc.rec(doc);
        let headIn = at -> ease((at - a#started) / Float64.max(0.01, d#headTurnSec));
        match a#ended {
            case None =>
                let body = bodyWhileTalking(d, m, player, now, a);
                { body = body, head = headRest(d, m, player, body) * headIn(now) }
            case Some((endedAt, playerAtEnd)) =>
                let stay = 1.0 - ease((now - endedAt - d#lingerSec) / Float64.max(0.01, d#returnSec));
                let body = bodyWhileTalking(d, m, playerAtEnd, endedAt, a) * stay;
                { body = body, head = headRest(d, m, player, body) * headIn(endedAt) * stay }
        }

    /// 今の行の身振り（人物の gestures を行の順に回して選ぶ）。行を出してから gestureDelaySec 後に始め、最初の行は体が向き直ってから。
    /// 話し終えたら gestureFadeSec かけて薄める。gestures が空か、まだ始まっていなければ None。
    pub def gestureOf(doc: CastDoc.Doc, m: Member, now: Float64, a: Attention): Option[Gesture] =
        let d = CastDoc.rec(doc);
        let n = List.length(m#gestures);
        let start = a#lineAt + d#gestureDelaySec + (if (a#line == 0) d#bodyTurnSec else 0.0);
        let weight = a#ended |> Option.map(e -> 1.0 - Num.clamp01((now - fst(e)) / Float64.max(0.01, d#gestureFadeSec))) |> Option.getWithDefault(1.0);
        if (n == 0 or now < start or weight <= 0.0) None
        else List.nth(Int32.remainder(a#line, n), m#gestures) |> Option.map(clip -> { clip = clip, t = now - start, weight = weight })
}
