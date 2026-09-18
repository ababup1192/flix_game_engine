// Enemies — 敵 3 種(歩く a / 飛ぶ b / 撃つ z)と弾。すべて純粋。
// 倒し方は踏みつけだけ(このゲームに武器は無い)。
//   歩く: 巡回。壁に当たるか、次の一歩の足元が崖なら向きを変える。
//   飛ぶ: 湧き場所を中心に上下へ揺れる(時刻の純関数 — 状態を持たない)。
//   撃つ: 主役が同じ高さ帯で射程内に入ると、向きを合わせて一定間隔で弾を出す。
mod Enemies {

    /// 敵の振る舞いと、その振る舞いだけが持つ値。
    /// 種類ごとの値を Enemy に平らに並べない — 歩く敵が「撃つまでの残り秒」を持てる形にすると、
    /// 種類が増えるたびに全個体のフィールドが増え、どれが誰の物か型から読めなくなる。
    /// 中身は Float64 1 つに揃える(レコードを payload に置くと Eq を derive できない)。
    pub enum Behavior with Eq, ToString {
        case Walking(Float64)   // 落下速度 px/s
        case Flying(Float64)    // 揺れの中心の高さ px
        case Shooting(Float64)  // 次に撃てるまでの残り秒
    }

    pub type alias Enemy = {
        behavior = Behavior,
        pos = Vec2.Vec2,
        dir = Float64         // 向き(+1 右 / -1 左)。絵の反転も見るので全種が持つ
    }

    pub type alias Shot = { pos = Vec2.Vec2, vel = Vec2.Vec2, ttl = Float64 }

    /// 当たり箱の大きさ(px)。種類ごとに固定(絵と揃える)。
    pub def sizeOf(behavior: Behavior): Vec2.Vec2 =
        match behavior {
            case Behavior.Walking(_)  => { x = 14.0, y = 11.0 }
            case Behavior.Flying(_)   => { x = 13.0, y = 10.0 }
            case Behavior.Shooting(_) => { x = 13.0, y = 15.0 }
        }

    /// 湧かせる。cellCenter = 湧くマスの中心。飛ぶ敵はそこを揺れの中心にし、
    /// 他はマスの下端へ足を着ける。
    /// 揺れの中心は呼び側に渡させない — 湧いた位置と 2 か所で持つと食い違い、
    /// 直接呼んだ敵だけが初回の tick で別の高さへ飛ぶ。
    pub def make(behavior: Behavior, cellCenter: Vec2.Vec2): Enemy =
        let size = sizeOf(behavior);
        let pos = match behavior {
            case Behavior.Flying(_) => cellCenter
            case _                  => { x = cellCenter#x,
                                         y = cellCenter#y + Physics.tileSize() * 0.5 - size#y * 0.5 }
        };
        let seeded = match behavior {
            case Behavior.Flying(_) => Behavior.Flying(pos#y)
            case other              => other
        };
        { behavior = seeded, pos = pos, dir = -1.0 }

    /// 1 tick。player は撃つ敵の索敵にだけ使う。返りは (敵, 新しく出た弾)。
    pub def step(t: Physics.Terrain, doc: EnemyDoc.Doc, dt: Float64, time: Float64,
                 player: Vec2.Vec2, e: Enemy): (Enemy, List[Shot]) =
        let d = EnemyDoc.rec(doc);
        match e#behavior {
            case Behavior.Walking(fallSpeed) => (walk(t, d, dt, fallSpeed, e), Nil)
            case Behavior.Flying(centerY)    => (fly(d, time, centerY, e), Nil)
            case Behavior.Shooting(cooldown) => shoot(d, dt, cooldown, player, e)
        }

    def walk(t: Physics.Terrain, doc: EnemyDoc.Rec, dt: Float64, fallSpeed: Float64,
             e: Enemy): Enemy =
        let size = sizeOf(e#behavior);
        let vy = Float64.min(fallSpeed + 900.0 * dt, 480.0);
        let slid = Physics.slideBox(t, size, dt, false, 0.0,
                                    e#pos, { x = e#dir * doc#walkSpeed, y = vy });
        let turned = slid#hitX or (slid#onGround and cliffAhead(t, size, e#dir, slid#pos));
        { pos = slid#pos, behavior = Behavior.Walking(slid#vel#y),
          dir = if (turned) -e#dir else e#dir | e }

    /// 次の一歩の足元(進行方向の縁の 1 つ先・半タイル下)が空なら崖。
    def cliffAhead(t: Physics.Terrain, size: Vec2.Vec2, dir: Float64, pos: Vec2.Vec2): Bool =
        let probeX = pos#x + dir * (size#x * 0.5 + 2.0);
        let probeY = pos#y + size#y * 0.5 + 2.0;
        let cx = Physics.tileOf(probeX);
        let cy = Physics.tileOf(probeY);
        not (t#solid(cx, cy) or t#oneWay(cx, cy))

    /// 上下の揺れは時刻の純関数(巻き戻し・描き出しと相性が良い)。横には動かない。
    def fly(doc: EnemyDoc.Rec, time: Float64, centerY: Float64, e: Enemy): Enemy =
        let amp = doc#flyAmpTiles * Physics.tileSize();
        let phase = 2.0 * 3.14159265 * time / doc#flyPeriod;
        { pos = { x = e#pos#x, y = centerY + amp * Vec2.sin(phase) } | e }

    def shoot(doc: EnemyDoc.Rec, dt: Float64, cooldown: Float64, player: Vec2.Vec2, e: Enemy):
             (Enemy, List[Shot]) =
        let dx = player#x - e#pos#x;
        let dy = player#y - e#pos#y;
        let inRange = Float64.abs(dx) <= doc#shotRangeTiles * Physics.tileSize()
                      and Float64.abs(dy) <= Physics.tileSize() * 2.5;
        let dir = if (dx < 0.0) -1.0 else 1.0;
        let left = Float64.max(0.0, cooldown - dt);
        if (inRange and left <= 0.0)
            ({ dir = dir, behavior = Behavior.Shooting(doc#shotCooldown) | e },
             { pos = { x = e#pos#x + dir * 10.0, y = e#pos#y - 2.0 },
               vel = { x = dir * doc#shotSpeed, y = 0.0 }, ttl = 3.0 } :: Nil)
        else ({ dir = if (inRange) dir else e#dir, behavior = Behavior.Shooting(left) | e }, Nil)

    /// 弾を進める。壁に刺さるか寿命で消える(None)。
    pub def stepShot(t: Physics.Terrain, dt: Float64, s: Shot): Option[Shot] =
        let np = Vec2.add(s#pos, Vec2.mul(s#vel, dt));
        let cx = Physics.tileOf(np#x);
        let cy = Physics.tileOf(np#y);
        let ttl = s#ttl - dt;
        if (ttl <= 0.0 or t#solid(cx, cy)) None
        else Some({ pos = np, ttl = ttl | s })

    pub def rectOf(e: Enemy): Rect2.Rect2 =
        let half = Vec2.mul(sizeOf(e#behavior), 0.5);
        { position = Vec2.sub(e#pos, half), size = sizeOf(e#behavior) }

    pub def shotRect(s: Shot): Rect2.Rect2 =
        { position = Vec2.sub(s#pos, { x = 3.0, y = 3.0 }), size = { x = 6.0, y = 6.0 } }
}
