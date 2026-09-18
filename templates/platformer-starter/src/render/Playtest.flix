// Playtest — 面を bot に通しで遊ばせて「クリアできるか」「気持ちよく走れるか」を測る。
// 実行: make playtest
//
// 面白さは主観だが、**主観が壊れている面は数字にも出る**という前提で 5 つ測る:
//   clear      … そもそもゴールに着けるか(着けない = 罠かクリア不能)
//   dashRate   … 最高速の 8 割以上で走れていた時間の割合(低い = つっかえる面)
//   stuckMax   … 前進が止まっていた最長の秒(長い = ハマりか登れない壁)
//   jumps      … 跳んだ回数(少なすぎ = 平坦で単調・多すぎ = 忙しすぎ)
//   stomps     … 敵を踏んだ回数(このゲーム唯一の攻撃 — 0 なら「倒す快感」が無い面)
//   idleMax    … 見せ場(コイン・敵・ギミック)に触れずに走り続けた最長の秒
//
// bot の行動は 3 つだけ: ゴールの方へ走る / 前が壁・穴・敵なら跳ぶ /
// ゴールが上にあるなら手近な足場の真下へ回り込んで跳ぶ(登坂)。
// 人間より下手なので、bot が通れる面は人間なら必ず通れる(下限の保証)。
// 登坂があるので、塔のような縦の面(左右の足場を交互に登る)も測れる。
// 判定の閾値は goals() に 1 箇所だけ置く。
mod Playtest {

    /// 合格の目安。ここを触ると面の合否が変わる — 数字の意味は上の doc。
    def goals(): { dashRate = Float64, stuckMax = Float64, idleMax = Float64,
                   minJumps = Int32, minStomps = Int32, minSeconds = Float64 } =
        { dashRate = 0.55, stuckMax = 2.5, idleMax = 6.0,
          minJumps = 8, minStomps = 2, minSeconds = 14.0 }

    def dt(): Float64 = 1.0 / 60.0

    def maxSeconds(): Float64 = 150.0

    /// 1 面ぶんの計測結果。
    type alias Report = {
        name = String, outcome = String, seconds = Float64,
        dashRate = Float64, stuckMax = Float64, idleMax = Float64,
        jumps = Int32, stomps = Int32, coins = Int32, coinsTotal = Int32,
        hurts = Int32, stuckAt = Float64
    }

    /// bot の走行中の覚え書き(集計用)。
    type alias Tally = {
        ticks = Int32, dashTicks = Int32, jumps = Int32,
        stuck = Float64, stuckMax = Float64, stuckAt = Float64,
        idle = Float64, idleMax = Float64,
        lastDist = Float64, lastX = Float64, xStall = Float64, jumpHold = Float64,
        dir = Float64, turnCd = Float64, hurts = Int32, hearts = Int32
    }

    /// ゴールまでの直線距離(進んでいるかの物差し。縦の面でも効く)。
    def goalDist(w: World.World): Float64 =
        Vec2.length(Vec2.sub(Stage.centerOf(Stage.rec(w#stage)#goal), w#player#body#pos))

    pub def all(): Unit \ IO =
        let w0 = load();
        let n = List.length(StageDoc.rec(w0#stageDoc)#stages);
        let reports = List.range(0, n) |> List.map(i -> playStage(World.loadStage(i, w0)));
        reports |> List.forEach(r -> println(line(r)));
        let bad = reports |> List.filter(r -> not passed(r));
        if (List.isEmpty(bad)) println("playtest: OK (${n} stages)")
        else {
            bad |> List.forEach(r -> println("  NG ${r#name}: ${reasons(r)}"));
            println("playtest: NG (${List.length(bad)}/${n} stages)")
        }

    def load(): World.World \ IO =
        run {
            World.initial(MotionDoc.load(MotionDoc.path()), KeysDoc.load(KeysDoc.path()),
                RulesDoc.load(RulesDoc.path()),
                EnemyDoc.load(EnemyDoc.path()),
                StageDoc.load(StageDoc.path()), Theme.load(Theme.path()),
                UiText.load(UiText.path()), PxSpriteDoc.load(World.spritePath()))
        } with Fs.FileRead.runWithIO

    def passed(r: Report): Bool =
        let g = goals();
        r#outcome == "clear" and r#dashRate >= g#dashRate and r#stuckMax <= g#stuckMax
            and r#idleMax <= g#idleMax and r#jumps >= g#minJumps
            and r#stomps >= g#minStomps and r#seconds >= g#minSeconds

    def reasons(r: Report): String =
        let g = goals();
        (if (r#outcome == "dead") "難しすぎる(bot が ${round1(r#seconds)}s で残機切れ・被弾 ${r#hurts}) " else "")
            ++ (if (r#outcome == "stuck") "クリア不能(x=${round1(r#stuckAt)} で停止) " else "")
            ++ (if (r#dashRate < g#dashRate) "走れない(dash ${pct(r#dashRate)}) " else "")
            ++ (if (r#stuckMax > g#stuckMax) "詰まる(${round1(r#stuckMax)}s@x=${round1(r#stuckAt)}) " else "")
            ++ (if (r#idleMax > g#idleMax) "見せ場が空く(${round1(r#idleMax)}s) " else "")
            ++ (if (r#jumps < g#minJumps) "跳ぶ場面が少ない(${r#jumps}) " else "")
            ++ (if (r#stomps < g#minStomps) "踏める敵が少ない(${r#stomps}) " else "")
            ++ (if (r#outcome == "clear" and r#seconds < g#minSeconds)
                    "短すぎる(${round1(r#seconds)}s) " else "")

    def line(r: Report): String =
        let mark = if (passed(r)) "OK  " else "NG  ";
        "${mark}${r#name}: ${r#outcome} ${round1(r#seconds)}s"
            ++ " dash ${pct(r#dashRate)} stuckMax ${round1(r#stuckMax)}s"
            ++ " idleMax ${round1(r#idleMax)}s jumps ${r#jumps} stomps ${r#stomps}"
            ++ " coins ${r#coins}/${r#coinsTotal} hurts ${r#hurts}"

    // ── 1 面を通しで遊ぶ ──

    def playStage(w: World.World): Report =
        let t0: Tally = { ticks = 0, dashTicks = 0, jumps = 0,
                          stuck = 0.0, stuckMax = 0.0, stuckAt = 0.0,
                          idle = 0.0, idleMax = 0.0,
                          lastDist = goalDist(w), lastX = w#player#body#pos#x,
                          xStall = 0.0, jumpHold = 0.0, dir = 1.0, turnCd = 0.0,
                          hurts = 0, hearts = w#hearts };
        let (wEnd, tally) = loop(w, t0, 0);
        { name = Stage.rec(w#stage)#name,
          // clear = ゴール / dead = 残機切れ / stuck = 時間切れ(進めない)
          outcome = if (wEnd#phase == "clear") "clear"
                    else if (wEnd#phase == "over") "dead" else "stuck",
          seconds = Int32.toFloat64(tally#ticks) * dt(),
          dashRate = if (tally#ticks == 0) 0.0
                     else Int32.toFloat64(tally#dashTicks) / Int32.toFloat64(tally#ticks),
          stuckMax = tally#stuckMax, idleMax = tally#idleMax,
          jumps = tally#jumps,
          stomps = wEnd#stomps,
          coins = Set.size(wEnd#got), coinsTotal = List.length(Stage.rec(w#stage)#coins),
          hurts = tally#hurts, stuckAt = tally#stuckAt }

    def loop(w: World.World, tally: Tally, n: Int32): (World.World, Tally) =
        if (w#phase != "play" or Int32.toFloat64(n) * dt() > maxSeconds()) (w, tally)
        else {
            let (input, hold, turnCd) = decide(w, tally);
            let w1 = World.step(input, dt(), w);
            loop(w1, tick(w, w1, input, hold, turnCd, tally), n + 1)
        }

    /// bot の判断。跳んだら 0.22 秒は押しっぱなし(可変ジャンプの長押し側 —
    /// 人間の「大きく跳ぶ」に相当)。向きは登坂の目標があればそちら、無ければ
    /// 今の向きのまま。壁に当たって進めない時間が続いたら折り返す。
    def decide(w: World.World, tally: Tally): (World.Input, Float64, Float64) =
        let p = w#player;
        let x = p#body#pos#x;
        let grounded = p#body#onGround or p#coyote > 0.0;
        let climb = climbTarget(w);
        // 折り返し: 今の向きに進めていない(壁)ときだけ。頻繁に反転すると端まで届かない。
        let turned = tally#xStall > 0.5 and tally#turnCd <= 0.0;
        let dirBase = if (turned) -tally#dir else tally#dir;
        let dir = match climb {
            case Some(tx) => if (Float64.abs(tx - x) < 5.0) 0.0
                             else if (tx > x) 1.0 else -1.0
            case None     => dirBase
        };
        let underTarget = match climb {
            case Some(tx) => Float64.abs(tx - x) < 12.0
            case None     => false
        };
        let pressed = grounded
            and (underTarget or wantsJump(w, if (dir == 0.0) tally#dir else dir));
        let hold = if (pressed) 0.22 else Float64.max(0.0, tally#jumpHold - dt());
        let turnCd = if (turned) 1.0 else Float64.max(0.0, tally#turnCd - dt());
        ({ dir = dir, jumpHeld = hold > 0.0, jumpPressed = pressed, drop = false,
          dash = true },   // bot は常にダッシュ — 「ずっと走れるか」を測る前提
         hold, turnCd)

    /// 登坂の目標: ゴールが十分に上にあるとき、手が届く高さ(2〜5 タイル上)で
    /// 水平に 5 タイル以内の「立てるマス」のうち、一番低くて近い物の中心 x。
    /// 見つからなければ None(横に進む面ではこれが常に None になる)。
    def climbTarget(w: World.World): Option[Float64] =
        let p = w#player;
        let ts = Physics.tileSize();
        if (Stage.centerOf(Stage.rec(w#stage)#goal)#y > p#body#pos#y - ts * 2.0) None
        else {
            let cx = Physics.tileOf(p#body#pos#x);
            let cy = Physics.tileOf(p#body#pos#y);
            let st = w#stage;
            let standable = (x, y) ->
                not Stage.solidAt(st, x, y)
                    and (Stage.solidAt(st, x, y + 1) or Stage.oneWayAt(st, x, y + 1)
                         or Stage.blinkAt(st, x, y + 1))
                    and not Stage.solidAt(st, x, y - 1);
            let offsets = forM (dy <- List.range(2, 6); ox <- List.range(-5, 6))
                yield (dy, Int32.abs(ox), ox);
            offsets
                |> List.sort
                |> List.findLeft(o -> { let (dy, _, ox) = o; standable(cx + ox, cy - dy) })
                |> Option.map(o -> { let (_, _, ox) = o;
                                     (Int32.toFloat64(cx + ox) + 0.5) * ts })
        }

    /// 跳ぶべき状況か: 進む先が壁 / 足元の先が穴 / 前方に敵。
    /// 先読みの倍率 = いまの速さ ÷ 歩きの最高速。走っているほど遠くを見る。
    /// これを 1.0 固定にすると、B ダッシュ中は敵に気づいた時にはもう避けられない —
    /// 「面が難しい」ではなく「bot の目が遅い」で不合格が出る。
    def lead(w: World.World): Float64 =
        Float64.max(1.0, Float64.abs(w#player#body#vel#x) / MotionDoc.rec(w#motion)#walkSpeed)

    def wantsJump(w: World.World, dir: Float64): Bool =
        let p = w#player;
        let t = World.terrainOf(w);
        let half = Vec2.mul(Physics.playerSize(), 0.5);
        let k = lead(w);
        let x = p#body#pos#x;
        let y = p#body#pos#y;
        let aheadX = x + dir * (half#x + 6.0 * k);
        let cx = Physics.tileOf(aheadX);
        let head = Physics.tileOf(y - half#y + 2.0);
        let mid = Physics.tileOf(y);
        let foot = Physics.tileOf(y + half#y - 2.0);
        let wall = t#solid(cx, mid) or t#solid(cx, foot) or t#solid(cx, head);
        // 足場の先が 2 マス連続で空 = 穴。
        let below = Physics.tileOf(y + half#y + 2.0);
        // 穴の判定も速さに追随させる — 速いほど手前で踏み切らないと届かない。
        let span = Int32.max(1, Num.floorInt(k));
        let ahead2 = cx + (if (dir > 0.0) span else -span);
        let gap = not (t#solid(cx, below) or t#oneWay(cx, below))
              and not (t#solid(ahead2, below) or t#oneWay(ahead2, below));
        let enemyNear = w#enemies |> List.exists(e ->
            (e#pos#x - x) * dir > 0.0 and Float64.abs(e#pos#x - x) < 44.0 * k
                and Float64.abs(e#pos#y - y) < 28.0);
        let shotNear = w#shots |> List.exists(s ->
            Float64.abs(s#pos#x - x) < 56.0 * k and Float64.abs(s#pos#y - y) < 20.0);
        (wall or gap or enemyNear or shotNear) and p#body#vel#y >= -20.0

    /// 1 tick ぶんの集計。
    def tick(w: World.World, w1: World.World, input: World.Input, hold: Float64,
             turnCd: Float64, tally: Tally): Tally =
        let m = MotionDoc.rec(w#motion);
        let vx = Float64.abs(w1#player#body#vel#x);
        let dist = goalDist(w1);
        let movedX = Float64.abs(w1#player#body#pos#x - tally#lastX);
        // ゴールへ近づけていない時間(登れない壁・ハマりの検出)。横だけでなく
        // 縦の面でも効くよう、x の前進でなくゴールまでの距離で測る。
        let stuck = if (tally#lastDist - dist < 0.3) tally#stuck + dt() else 0.0;
        // 見せ場(コイン取得・踏みつけ・跳躍)に触れずに走った時間。
        let event = input#jumpPressed or w1#score != w#score or w1#hearts != w#hearts;
        let idle = if (event) 0.0 else tally#idle + dt();
        { ticks = tally#ticks + 1,
          dashTicks = tally#dashTicks + (if (vx >= m#walkSpeed * 0.8) 1 else 0),
          jumps = tally#jumps + (if (input#jumpPressed) 1 else 0),
          stuck = stuck,
          stuckMax = Float64.max(tally#stuckMax, stuck),
          stuckAt = if (stuck > tally#stuckMax) w1#player#body#pos#x else tally#stuckAt,
          idle = idle, idleMax = Float64.max(tally#idleMax, idle),
          lastDist = dist, lastX = w1#player#body#pos#x,
          // 進めていない時間は入力の有無に関わらず数える — dir = 0 のまま
          // 固まった時にこそ折り返してほしいので、ここで dir を条件にしない。
          xStall = if (movedX < 0.3) tally#xStall + dt() else 0.0,
          jumpHold = hold,
          // 向きは 0 を覚えない。0 を覚えると折り返しの -dir も 0 になり、
          // その場から永久に動けなくなる(実際にこれで 138 秒ハマった)。
          dir = if (input#dir == 0.0) tally#dir else input#dir, turnCd = turnCd,
          hurts = tally#hurts + (if (w1#hearts < tally#hearts) 1 else 0),
          hearts = w1#hearts }

    def round1(v: Float64): String =
        let r = Float64.round(v * 10.0) / 10.0;
        "${r}"

    def pct(v: Float64): String =
        let r = Float64.round(v * 100.0);
        "${Float64.tryToInt32(r) |> Option.getWithDefault(0)}%"
}
