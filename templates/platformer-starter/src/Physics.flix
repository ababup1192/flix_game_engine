// Physics — 動く物とタイルの当たり(軸分離: x を動かして解決 → y を動かして解決)。
// すべて純粋。地形は Terrain(solid = 硬い / oneWay = 一方通行の床)の 2 つの
// 関数でだけ受け取るので、ステージの持ち方にも Doc にも触れない。terra_like からの移植。
//
// ジャンプの式は「頂点の高さ h と頂点までの秒 t」から導く:
//   初速 = -2h/t(負 = 上向き), 重力 = 2h/t²。
// 可変ジャンプは離した瞬間に上昇速度を cutFactor 倍に削る — タップの頂点が
// ちょうど jumpTapTiles になるよう cutFactor = sqrt(タップ高 / 長押し高) で導く
// (高さは速度の 2 乗に比例するため)。
//
// このゲームで足した「ゆるし」:
//   一方通行 — oneWay の床は「下端が上から境界をまたぐ時」だけ硬い(↓ 押下ですり抜け)。
//   角の許し — 上昇中の頭の角が cornerNudgePx 以下のかすりなら、横へ滑らせて通す。
mod Physics {

    /// 動く物 1 体の状態。pos は当たり箱の中心(ワールド px・y は下向き)。
    pub type alias Body = { pos = Vec2.Vec2, vel = Vec2.Vec2, onGround = Bool }

    /// 地形の照会口。solid = 全方向に硬い / oneWay = 上からだけ硬い(一方通行の床)。
    pub type alias Terrain = { solid = (Int32, Int32) -> Bool, oneWay = (Int32, Int32) -> Bool }

    /// 1 タイルの一辺 px。
    pub def tileSize(): Float64 = 16.0

    /// プレイヤーの当たり箱(px)。幅 12 × 高さ 26 = 1×2 タイル弱。
    pub def playerSize(): Vec2.Vec2 = { x = 12.0, y = 26.0 }

    // ── Doc から導く運動の定数 ──

    /// ジャンプの初速(負 = 上向き): -2h/t。
    pub def jumpVelocity(md: MotionDoc.Doc): Float64 =
        let m = MotionDoc.rec(md);
        -2.0 * m#jumpHeightTiles * tileSize() / m#timeToApex

    /// 高さ h タイルの頂点に届く初速(バネ・バウンドが使う)。
    pub def launchVelocity(m: MotionDoc.Doc, hTiles: Float64): Float64 =
        -Vec2.sqrt(Float64.max(0.0, 2.0 * gravity(m) * hTiles * tileSize()))

    /// 上昇中の重力加速度: 2h/t²。
    pub def gravity(md: MotionDoc.Doc): Float64 =
        let m = MotionDoc.rec(md);
        2.0 * m#jumpHeightTiles * tileSize() / (m#timeToApex * m#timeToApex)

    /// 今の速度に効く重力。下降中は fallGravityMult 倍 — 山の右側が詰まり
    /// 「ふわっと上がってストンと落ちる」になる。
    pub def gravityFor(md: MotionDoc.Doc, vy: Float64): Float64 =
        if (vy > 0.0) gravity(md) * MotionDoc.rec(md)#fallGravityMult else gravity(md)

    /// B ダッシュ中の最高速。歩きの dashMult 倍(MotionDoc のノブ)。
    pub def topSpeed(md: MotionDoc.Doc, dash: Bool): Float64 =
        let m = MotionDoc.rec(md);
        if (dash) m#walkSpeed * m#dashMult else m#walkSpeed

    /// ボタンを離した瞬間に上昇速度へ掛ける倍率。
    pub def cutFactor(md: MotionDoc.Doc): Float64 =
        let m = MotionDoc.rec(md);
        if (m#jumpHeightTiles <= 0.0) 1.0
        else Vec2.sqrt(Float64.max(0.0, m#jumpTapTiles / m#jumpHeightTiles))

    // ── 1 tick の運動 ──

    /// 任意サイズの箱を今の速度で 1 tick 動かし、地形に当てて止めた結果。
    /// hitX = 壁 / hitHead = 天井(角の許しで逃げた場合は false)。
    pub type alias Slide = { pos = Vec2.Vec2, vel = Vec2.Vec2, hitX = Bool,
                             hitHead = Bool, onGround = Bool }

    /// 幅 size の箱を速度 vel で dt 秒動かし、地形に当てて止める(プレイヤーと敵が共用)。
    /// 重力・入力は呼び手が vel に織り込み済み — ここは「動かして当てる」だけ。
    /// drop = ↓ 押下(一方通行をすり抜ける)。nudgePx = 角の許し幅(0 で無効)。
    pub def slideBox(t: Terrain, size: Vec2.Vec2, dt: Float64, drop: Bool, nudgePx: Float64,
                     pos: Vec2.Vec2, vel: Vec2.Vec2): Slide =
        let afterX = moveX(t, size, vel#x * dt, pos);
        let afterY = moveY(t, size, vel#y * dt, drop, nudgePx, afterX#pos);
        { pos = afterY#pos,
          vel = { x = if (afterX#hit) 0.0 else vel#x,
                  y = if (afterY#hit) 0.0 else vel#y },
          hitX = afterX#hit,
          hitHead = afterY#hit and vel#y < 0.0,
          onGround = afterY#hit and vel#y >= 0.0 }

    /// 1 tick 進めた結果。wall = 押していた向きの壁に当たったか(-1 左 / 0 なし / +1 右)。
    /// 壁ジャンプはこの向きの逆へ蹴るので、Body と別に返す(Body は「いまの姿」だけ)。
    pub type alias Step = { body = Body, wall = Float64 }

    /// 横入力 dir(-1/0/+1)と重力で速度を進め、地形に当てて止める。
    /// onGround は下向きの衝突があった tick だけ true。
    pub def stepBody(t: Terrain, md: MotionDoc.Doc, dt: Float64, dir: Float64, drop: Bool,
                     dash: Bool, body: Body): Step =
        let m = MotionDoc.rec(md);
        let top = topSpeed(md, dash);
        let vx =
            // ダッシュを離した直後は最高速を超えている — そこは decel でゆるく
            // 落とす(accel で急に戻すと勢いが消えて操作が固く感じる)。
            if (dir == 0.0) approach(0.0, m#decel * dt, body#vel#x)
            else if (dir * body#vel#x > 0.0 and Float64.abs(body#vel#x) > top)
                approach(dir * top, m#decel * dt, body#vel#x)
            else approach(dir * top, m#accel * dt, body#vel#x);
        let vy = Float64.min(body#vel#y + gravityFor(md, body#vel#y) * dt, m#maxFallSpeed);
        let slid = slideBox(t, playerSize(), dt, drop, m#cornerNudgePx,
                            body#pos, { x = vx, y = vy });
        { body = { pos = slid#pos, vel = slid#vel, onGround = slid#onGround },
          wall = if (slid#hitX and dir != 0.0) dir else 0.0 }

    /// current を target へ最大 step だけ近づける(行き過ぎない)。
    pub def approach(target: Float64, step: Float64, current: Float64): Float64 =
        if (current < target) Float64.min(current + step, target)
        else Float64.max(current - step, target)

    // ── 軸分離の衝突解決 ──
    // 進む側の縁が通り過ぎるタイル行(列)を近い順に調べ、最初に硬い所で縁を
    // タイルの境界へぴったり戻す。1 フレームで 2 タイル近く落ちても、行を順に
    // 見るので間のタイルを飛び越えない。

    /// 横移動の解決。hit = 壁に当たって止まったか。横は solid だけが硬い。
    def moveX(t: Terrain, size: Vec2.Vec2, dx: Float64, pos: Vec2.Vec2):
             { pos = Vec2.Vec2, hit = Bool } =
        let f = t#solid;
        let half = Vec2.mul(size, 0.5);
        let nx = pos#x + dx;
        let rows = spanOf(pos#y - half#y, pos#y + half#y);
        if (dx > 0.0) {
            let c0 = tileOf(pos#x + half#x);
            let c1 = tileOf(nx + half#x - epsilon());
            match firstSolid(f, c0, c1, rows, false) {
                case Some(c) => { pos = { x = Int32.toFloat64(c) * tileSize() - half#x | pos }, hit = true }
                case None    => { pos = { x = nx | pos }, hit = false }
            }
        } else if (dx < 0.0) {
            let c0 = tileOf(pos#x - half#x - epsilon());
            let c1 = tileOf(nx - half#x);
            match firstSolid(f, c0, c1, rows, false) {
                case Some(c) => { pos = { x = Int32.toFloat64(c + 1) * tileSize() + half#x | pos }, hit = true }
                case None    => { pos = { x = nx | pos }, hit = false }
            }
        } else { pos = pos, hit = false }

    /// 縦移動の解決。下向きは solid に加え「上からまたぐ oneWay」も硬い。
    /// 上向きで天井に当たったら、角のかすりなら横へ逃がしてから通す(角の許し)。
    def moveY(t: Terrain, size: Vec2.Vec2, dy: Float64, drop: Bool, nudgePx: Float64,
              pos: Vec2.Vec2): { pos = Vec2.Vec2, hit = Bool } =
        let half = Vec2.mul(size, 0.5);
        let ny = pos#y + dy;
        let cols = spanOf(pos#x - half#x, pos#x + half#x);
        if (dy > 0.0) {
            let bottom = pos#y + half#y;
            let r0 = tileOf(bottom);
            let r1 = tileOf(ny + half#y - epsilon());
            // 一方通行はこの tick で下端が上から境界をまたいだ行だけ硬い。
            let floorAt = (c, r) -> t#solid(c, r) or
                (t#oneWay(c, r) and not drop
                    and bottom <= Int32.toFloat64(r) * tileSize() + epsilon());
            match firstSolid(floorAt, r0, r1, cols, true) {
                case Some(r) => { pos = { y = Int32.toFloat64(r) * tileSize() - half#y | pos }, hit = true }
                case None    => { pos = { y = ny | pos }, hit = false }
            }
        } else if (dy < 0.0) {
            let r0 = tileOf(pos#y - half#y - epsilon());
            let r1 = tileOf(ny - half#y);
            match firstSolid(t#solid, r0, r1, cols, true) {
                case Some(r) =>
                    match cornerNudge(t, size, nudgePx, pos, r) {
                        case Some(nx) => moveY(t, size, dy, drop, 0.0, { x = nx | pos })
                        case None     => { pos = { y = Int32.toFloat64(r + 1) * tileSize() + half#y | pos }, hit = true }
                    }
                case None => { pos = { y = ny | pos }, hit = false }
            }
        } else { pos = pos, hit = false }

    /// 角の許し: 頭がぶつかった行 r の硬いマスが箱の左右どちらかの端に
    /// nudgePx 以下しか食い込んでいないなら、逃げた後の x を返す。
    def cornerNudge(t: Terrain, size: Vec2.Vec2, nudgePx: Float64,
                    pos: Vec2.Vec2, r: Int32): Option[Float64] =
        if (nudgePx <= 0.0) None
        else {
            let half = Vec2.mul(size, 0.5);
            let left = pos#x - half#x;
            let right = pos#x + half#x;
            let (c0, c1) = spanOf(left, right);
            let hard = List.range(c0, c1 + 1) |> List.filter(c -> t#solid(c, r));
            match (List.head(hard), List.last(hard)) {
                case (Some(cL), Some(cR)) =>
                    let inLeft = Int32.toFloat64(cL + 1) * tileSize() - left;   // 左端への食い込み
                    let inRight = right - Int32.toFloat64(cR) * tileSize();     // 右端への食い込み
                    if (cL == cR and inLeft <= nudgePx and clearAt(t, size, pos#x + inLeft, r))
                        Some(pos#x + inLeft + epsilon())
                    else if (cL == cR and inRight <= nudgePx and clearAt(t, size, pos#x - inRight, r))
                        Some(pos#x - inRight - epsilon())
                    else None
                case _ => None
            }
        }

    /// x へ動かした箱の頭上の行 r に硬いマスが無いか。
    def clearAt(t: Terrain, size: Vec2.Vec2, x: Float64, r: Int32): Bool =
        let half = Vec2.mul(size, 0.5);
        let (c0, c1) = spanOf(x - half#x, x + half#x);
        List.range(c0, c1 + 1) |> List.forAll(c -> not t#solid(c, r))

    /// 進行方向の縁が通る範囲(i0 → i1 を近い順)を調べ、最初に硬いタイルを含む
    /// 行(rowAxis = true)か列(false)の番号を返す。span は動かない側の軸の占有範囲。
    def firstSolid(hard: (Int32, Int32) -> Bool, i0: Int32, i1: Int32,
                   span: (Int32, Int32), rowAxis: Bool): Option[Int32] =
        let order = if (i1 >= i0) List.range(i0, i1 + 1)
                    else List.range(i1, i0 + 1) |> List.reverse;
        let (s0, s1) = span;
        order |> List.findLeft(i ->
            List.range(s0, s1 + 1) |> List.exists(s ->
                if (rowAxis) hard(s, i) else hard(i, s)))

    /// px の閉区間 [a, b) が占めるタイル番号の範囲。b 側は半開扱い。
    def spanOf(a: Float64, b: Float64): (Int32, Int32) =
        (tileOf(a), tileOf(b - epsilon()))

    /// px 座標が入っているタイル番号。
    pub def tileOf(v: Float64): Int32 =
        Float64.floor(v / tileSize()) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    /// 縁の判定に使う微小量。「ちょうど境界に接している」を隣のタイル占有と数えないため。
    def epsilon(): Float64 = 0.0001
}
