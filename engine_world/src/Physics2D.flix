// Physics2D — 物理を「積分・検出・反射・分離」の 4 つの純関数に切り出し、好きな順に合成できる形。
// 位置・速度・形・反発係数は entity ごとに別の Map（component）で持つ。velocities に登録が
// 無い entity は静止扱い（積分も反射も受けない・分類の enum は無い）。
//
// 注意: 検出は 1 回きりの離散判定なので、1 フレームの移動量が相手の厚みを大きく超える速さでは
// すり抜けうる。静的地形同士（矩形・坂・多角形の組）は分離ベクトルを返さない。narrowphase は
// 円・矩形・カプセル・坂・多角形を解決する。

pub mod Physics2D {

    // ── 接触（データの橋）──
    // 重なった 2 体 a・b（id は a < b）と、a を b から離す単位法線・接触点・めり込み量。
    // どちらが動くかは持たず、bounce / separate が velocities の在・不在から判断する。
    pub type alias Contact = {
        a = EntityId,           // ペアの一方（id が小さい側）
        b = EntityId,           // もう一方
        normal = Vec2.Vec2,     // b から a へ向かう単位ベクトル（a を b から押し出す向き）
        point = Vec2.Vec2,      // おおよその接触点（a の表面上・情報用）
        penetration = Float64   // めり込んでいた深さ（正の値）
    }

    /// これ未満のめり込みは「触れていない」とみなす下限（0 除算とちらつきを避ける）。
    def epsilon(): Float64 = 0.0000001

    // ── 接触の読み取り補助 ──
    // 政策側の定型「この物体は何かに当たったか / 相手は誰か」を 1 語にする。

    /// id が絡む接触だけを残す。「このフレームでボールに起きたこと」を一度で取り出せる。
    pub def contactsOf(id: EntityId, contacts: List[Contact]): List[Contact] =
        List.filter(contact -> contact#a == id or contact#b == id, contacts)

    /// id が 1 つでも接触に絡んでいるか。「パドルに当たったら」の条件をそのまま書ける。
    pub def touches(id: EntityId, contacts: List[Contact]): Bool =
        List.exists(contact -> contact#a == id or contact#b == id, contacts)

    /// 接触の相手側の id。id がその接触に絡んでいなければ None。
    pub def other(id: EntityId, contact: Contact): Option[EntityId] =
        if (contact#a == id) Some(contact#b)
        else if (contact#b == id) Some(contact#a)
        else None

    /// contact の法線を「id を押し出す向き」に揃える（a 側ならそのまま・b 側なら反転）。
    pub def normalToward(id: EntityId, contact: Contact): Vec2.Vec2 =
        if (contact#a == id) contact#normal else Vec2.neg(contact#normal)

    /// 面に近づく速度の法線成分だけを消す（跳ねずに滑る）。検出順に適用する。bounce の対。
    /// 離れる向きの接触（かすめた直後など）は触らない。
    pub def slide(id: EntityId, contacts: List[Contact], vel: Vec2.Vec2): Vec2.Vec2 =
        List.foldLeft((v, contact) -> {
            let normal = normalToward(id, contact);
            let approach = Vec2.dot(v, normal);
            if (approach < 0.0) Vec2.sub(v, Vec2.mul(normal, approach)) else v
        }, vel, contacts)

    /// normalToward が dir と minDot より強く揃う接触だけ残す
    /// （dir=(0,-1),0.6 で接地・(0,1),0.7 で頭上）。しきい値ちょうどは含まない（>）。
    pub def contactsAlong(id: EntityId, dir: Vec2.Vec2, minDot: Float64, contacts: List[Contact]): List[Contact] =
        List.filter(contact -> Vec2.dot(normalToward(id, contact), dir) > minDot, contacts)

    // ── integrate: 速度を持つものだけ位置を進める ──

    /// velocities に登録された entity だけ、その速度で位置を進める。登録の無い entity は
    /// 動かない（静止は「速度の店に居ない」というデータの不在で表す）。位置だけを返す純関数。
    pub def integrate(dt: Float64, velocities: Map[EntityId, Vec2.Vec2],
                      positions: Map[EntityId, Vec2.Vec2]): Map[EntityId, Vec2.Vec2] =
        Query.updateWith2(positions, velocities, (pos, vel) -> Vec2.add(pos, Vec2.mul(vel, dt)))

    // ── detect: 重なりを接触として集める（検出だけ）──

    /// 位置と形から、重なっている組を接触として返す。broadphase は共有の Collision（一様格子）に
    /// 任せ、重なった各ペアの分離ベクトルから法線・めり込み・接触点を求める。速度も反発も見ない。
    pub def detect(positions: Map[EntityId, Vec2.Vec2],
                   shapes: Map[EntityId, CollisionShape2D]): List[Contact] =
        let colliders: Map[EntityId, Collision.Collider] =
            Map.map(shape -> { shape = shape, layer = 1i32, mask = 1i32 }, shapes);
        Collision.detectCollisions(positions, colliders)
            |> List.filterMap(pair -> contactOf(pair, positions, shapes))

    /// 1 ペアの接触。位置・形が揃い、分離ベクトルが取れて、めり込みが下限を超えるときだけ Some。
    def contactOf(pair: (EntityId, EntityId), positions: Map[EntityId, Vec2.Vec2],
                  shapes: Map[EntityId, CollisionShape2D]): Option[Contact] =
        let (a, b) = pair;
        forM (
            posA   <- Map.get(a, positions);
            shapeA <- Map.get(a, shapes);
            posB   <- Map.get(b, positions);
            shapeB <- Map.get(b, shapes);
            mtv    <- CollisionShape2D.resolveOverlap(posA, shapeA, posB, shapeB);
            contact <- makeContact(a, b, posA, shapeA, mtv)
        ) yield contact

    /// 分離ベクトル mtv（a を b から離す）から接触を組む。長さが下限未満なら None。
    def makeContact(a: EntityId, b: EntityId, posA: Vec2.Vec2,
                    shapeA: CollisionShape2D, mtv: Vec2.Vec2): Option[Contact] =
        let penetration = Vec2.length(mtv);
        if (penetration < epsilon()) None
        else {
            let normal = Vec2.div(mtv, penetration);
            Some({ a = a, b = b, normal = normal,
                   point = Vec2.sub(posA, Vec2.mul(normal, boundExtentAlong(shapeA, normal))),
                   penetration = penetration })
        }

    // ── bounce: 速度を持つ側だけ反射する ──

    /// 各接触について、速度を持つ側の速度を反発係数ぶん反射する。相手の速度を基準に取るので、
    /// 相手が velocities に居なければ壁として振る舞う（vOther = 0）のが自然に出る。速度だけを返す。
    /// restitutions に登録の無い entity は反発 0（跳ねずにその場で止まる）として扱う。
    pub def bounce(contacts: List[Contact], restitutions: Map[EntityId, Float64],
                   velocities: Map[EntityId, Vec2.Vec2]): Map[EntityId, Vec2.Vec2] =
        List.foldLeft((vels, contact) ->
            vels
                |> reflectSide(contact#a, contact#b, contact#normal, restitutions)
                |> reflectSide(contact#b, contact#a, Vec2.neg(contact#normal), restitutions),
            velocities, contacts)

    /// self が velocities に居れば、other の速度を基準に normal 方向へ反射する。居なければ素通し
    /// （＝静止として振る舞い、相手にとっては壁になる）。近づいている接触だけ反射する（貼り付き防止）。
    def reflectSide(self: EntityId, other: EntityId, normal: Vec2.Vec2,
                    restitutions: Map[EntityId, Float64],
                    velocities: Map[EntityId, Vec2.Vec2]): Map[EntityId, Vec2.Vec2] =
        match Map.get(self, velocities) {
            case None => velocities
            case Some(vSelf) =>
                let vOther = Map.get(other, velocities) |> Option.getWithDefault(Vec2.zero());
                let restitution = Map.get(self, restitutions) |> Option.getWithDefault(0.0);
                let vRel = Vec2.sub(vSelf, vOther);
                let approach = Vec2.dot(vRel, normal);
                if (approach < 0.0)
                    Map.insert(self, Vec2.add(vOther, Vec2.sub(vRel, Vec2.mul(normal, (1.0 + restitution) * approach))), velocities)
                else velocities
        }

    // ── separate: めり込みを押し出す（位置だけ）──

    /// 各接触のめり込みを解消するよう位置を押し出す。動かせる側（velocities に居る側）だけを動かし、
    /// 両方動かせるなら半分ずつ、片方だけなら全量を動かす。静止側は動かさない。位置だけを返す純関数。
    pub def separate(contacts: List[Contact], velocities: Map[EntityId, Vec2.Vec2],
                     positions: Map[EntityId, Vec2.Vec2]): Map[EntityId, Vec2.Vec2] =
        List.foldLeft((pos, contact) -> separateOne(contact, velocities, pos), positions, contacts)

    def separateOne(contact: Contact, velocities: Map[EntityId, Vec2.Vec2],
                    positions: Map[EntityId, Vec2.Vec2]): Map[EntityId, Vec2.Vec2] =
        let mtv = Vec2.mul(contact#normal, contact#penetration);   // a を b から離すベクトル
        match (Map.memberOf(contact#a, velocities), Map.memberOf(contact#b, velocities)) {
            case (true, false)  => shift(contact#a, mtv, positions)
            case (false, true)  => shift(contact#b, Vec2.neg(mtv), positions)
            case (true, true)   => positions
                                     |> shift(contact#a, Vec2.mul(mtv, 0.5))
                                     |> shift(contact#b, Vec2.mul(mtv, -0.5))
            case (false, false) => positions
        }

    def shift(id: EntityId, delta: Vec2.Vec2, positions: Map[EntityId, Vec2.Vec2]): Map[EntityId, Vec2.Vec2] =
        match Map.get(id, positions) {
            case Some(p) => Map.insert(id, Vec2.add(p, delta), positions)
            case None    => positions
        }

    // ── 補助 ──

    /// 中心から法線方向の表面までのおおよその距離（接触点の推定に使う）。
    def boundExtentAlong(shape: CollisionShape2D, normal: Vec2.Vec2): Float64 =
        match shape {
            case CollisionShape2D.CircleShape2D(circle)   => circle#radius
            case CollisionShape2D.RectShape2D(rect)       =>
                Float64.abs(normal#x) * rect#width / 2.0 + Float64.abs(normal#y) * rect#height / 2.0
            case CollisionShape2D.CapsuleShape2D(capsule) => capsule#radius
            case CollisionShape2D.SlopeShape2D(slope)     =>
                // 外接箱で見積もる（矩形と同じ保守的な近似）
                Float64.abs(normal#x) * slope#width / 2.0 + Float64.abs(normal#y) * slope#height / 2.0
            case CollisionShape2D.PolygonShape2D(poly)    =>
                // 支持関数: -normal 方向へ最も張り出した頂点までの距離（近似でなく厳密に取れる）
                List.foldLeft((acc, p) -> Float64.max(acc, Vec2.dot(p, Vec2.neg(normal))), 0.0, poly#points)
        }
}
