// World — ゲームの全状態と 1 tick の進行。すべて純粋(IO なし)。
//
// ── 毎フレームの 1 周(Main の App.game から見た地図)──
//   入力: Controls.inputOf が Frame を Input へ写す
//   更新: World.step — hitstop → 動く床 → 主役(Player) → バネ/コイン/旗 → 敵と弾 → 収支 → カメラ
//   描画: View.frame(全動的・描き出し)/ View.frameLive(GPU レイヤー + 動的補完)
//
// 場面(phase)は 3 つだけ: play → clear(旗) → 次の面 / play → over(残機 0) → 最初から。
// 加点と場面替えの「規則」はここに書き、その規則が読む数値は rules Doc に置く。
// 進行の持ち物(取ったコイン・点いたチェックポイント)は集合で覚える — rows は書き換えない。
mod World {

    pub type alias World = {
        motion = MotionDoc.Doc,
        keys = KeysDoc.Doc,
        rules = RulesDoc.Doc,
        enemyDoc = EnemyDoc.Doc,
        stageDoc = StageDoc.Doc,
        theme = Theme.Doc,
        uiText = UiText.Doc,
        pxDoc = PxSpriteDoc.Doc,
        atlas = PxSpriteAtlas.Baked,
        atlasGen = Int32,
        stageIx = Int32,
        stage = Stage.Stage,
        light = Map[(Int32, Int32), (Float64, Float64, Float64)],
        player = Player.State,
        enemies = List[Enemies.Enemy],
        shots = List[Enemies.Shot],
        got = Set[(Int32, Int32)],       // 取ったコインのマス
        cpOn = Set[(Int32, Int32)],      // 点いたチェックポイントのマス
        springT = Map[(Int32, Int32), Float64], // バネの伸び演出の残り秒
        fx = List[Fx],
        checkpoint = Vec2.Vec2,          // 戻り先(足の着く位置)
        score = Int32,
        stomps = Int32,                  // 踏んだ敵の総数(進行の記録 — 得点から逆算させない)
        hearts = Int32,
        invuln = Float64,                // 被弾後の無敵の残り秒
        freeze = Float64,                // hitstop の残り秒(世界の時間ごと止まる)
        phase = String,                  // play / clear / over
        phaseT = Float64,
        t = Float64,
        cam = Vec2.Vec2
    }

    /// このフレームの入力。Controls が Frame から写す — 中身は主役の入力そのもの。
    pub type alias Input = Player.Input

    /// ぱっと出て消える演出の種(land = 砂煙 / stomp = 星 / coin = 光 / spring = 風)。
    pub type alias Fx = { kind = String, pos = Vec2.Vec2, t0 = Float64 }

    /// 演出の寿命(秒)。回収(World)と薄まり(View)が同じ長さを見るための 1 本。
    pub def fxLifeSec(): Float64 = 0.5

    // ── 生成 ──

    pub def initial(motion: MotionDoc.Doc, keys: KeysDoc.Doc, rules: RulesDoc.Doc,
                    enemyDoc: EnemyDoc.Doc, stageDoc: StageDoc.Doc, theme: Theme.Doc,
                    uiText: UiText.Doc, pxDoc: PxSpriteDoc.Doc): World =
        let stage = stageOf(stageDoc, 0);
        let at0 = standingAt(stage, Stage.rec(stage)#start);
        { motion = motion, keys = keys, rules = rules, enemyDoc = enemyDoc, stageDoc = stageDoc, theme = theme,
          uiText = uiText, pxDoc = pxDoc,
          atlas = PxSpriteAtlas.bake(pxDoc, key -> Theme.resolve(theme, key)),
          atlasGen = 0,
          stageIx = 0, stage = stage, light = LightGrid.compute(stage),
          player = Player.initial(at0),
          enemies = enemiesOf(stage), shots = Nil,
          got = Set.empty(), cpOn = Set.empty(), springT = Map.empty(), fx = Nil,
          checkpoint = at0,
          score = 0, stomps = 0, hearts = RulesDoc.rec(rules)#maxHearts, invuln = 0.0, freeze = 0.0,
          phase = "play", phaseT = 0.0, t = 0.0,
          cam = at0 }

    def stageOf(doc: StageDoc.Doc, ix: Int32): Stage.Stage =
        let stages = StageDoc.rec(doc)#stages;
        let n = List.length(stages);
        let i = if (n <= 0) 0 else Int32.modulo(ix, n);
        stages |> List.drop(i) |> List.head
            |> Option.getWithDefault(List.head(StageDoc.rec(StageDoc.defaults())#stages)
                |> Option.getWithDefault({ name = "?", kind = "outdoor", rows = "####" :: Nil }))
            |> Stage.make

    def enemiesOf(stage: Stage.Stage): List[Enemies.Enemy] =
        Stage.rec(stage)#enemies |> List.map(entry -> {
            let (cell, behavior) = entry;
            Enemies.make(behavior, Stage.centerOf(cell))
        })

    /// マス cell の上に足を着けて立つ位置(体の中心)。
    def standingAt(_stage: Stage.Stage, cell: Stage.Cell): Vec2.Vec2 =
        let ts = Physics.tileSize();
        { x = (Int32.toFloat64(cell#x) + 0.5) * ts,
          y = Int32.toFloat64(cell#y + 1) * ts - Physics.playerSize()#y * 0.5 }

    /// 面を差し替えて出発点に立たせる(clear → 次の面 / over → 最初から)。
    pub def loadStage(ix: Int32, w: World): World =
        let stage = stageOf(w#stageDoc, ix);
        let at0 = standingAt(stage, Stage.rec(stage)#start);
        { stageIx = ix, stage = stage, light = LightGrid.compute(stage),
          player = Player.initial(at0),
          enemies = enemiesOf(stage), shots = Nil,
          got = Set.empty(), cpOn = Set.empty(), springT = Map.empty(), fx = Nil,
          checkpoint = at0, invuln = 0.0, freeze = 0.0,
          phase = "play", phaseT = 0.0, cam = at0 | w }

    // ── 地形の照会(Physics へ渡す口)──

    /// 消える床の点滅: blinkPeriod 秒のうち前半 blinkOnSec 秒だけ硬い(Doc のノブ)。
    /// 位相はマス座標で散らす — 全部の床が同時に消えると詰む。
    pub def blinkOn(md: MotionDoc.Doc, t: Float64, x: Int32, y: Int32): Bool =
        let m = MotionDoc.rec(md);
        let phase = Int32.toFloat64(Int32.modulo(x * 3 + y * 7, 4)) * 0.3;
        fmod(t + phase, m#blinkPeriod) < m#blinkOnSec

    /// 正の剰余(Float64 — 周期の位相取り)。
    pub def fmod(v: Float64, period: Float64): Float64 =
        v - Float64.floor(v / period) * period

    pub def terrainOf(w: World): Physics.Terrain =
        let st = w#stage;
        let time = w#t;
        let m = w#motion;
        { solid = (x, y) -> Stage.solidAt(st, x, y)
              or (Stage.blinkAt(st, x, y) and blinkOn(m, time, x, y)),
          oneWay = (x, y) -> Stage.oneWayAt(st, x, y) }

    // ── 動く床(横往復・時刻の純関数)──

    /// 床の左上 px(時刻 t)。振れ幅と周期は Doc のノブ。位相はマスで散らす。
    pub def platformPosAt(md: MotionDoc.Doc, p: Stage.Platform, time: Float64): Vec2.Vec2 =
        let m = MotionDoc.rec(md);
        let ts = Physics.tileSize();
        let amp = m#platformAmpTiles * ts;
        let phase = Int32.toFloat64(Int32.modulo(p#cell#x + p#cell#y * 5, 6)) * 1.0;
        { x = Int32.toFloat64(p#cell#x) * ts
              + amp * Vec2.sin(2.0 * 3.14159265 * time / m#platformPeriodSec + phase),
          y = Int32.toFloat64(p#cell#y) * ts }

    // ── 1 tick ──

    pub def step(input: Input, dt: Float64, w: World): World =
        if (w#freeze > 0.0)
            { freeze = Float64.max(0.0, w#freeze - dt) | w }   // hitstop: 世界ごと止まる
        else if (w#phase != "play")
            stepPhase(dt, w)
        else {
            let w1 = { t = w#t + dt, invuln = Float64.max(0.0, w#invuln - dt),
                       springT = Map.map(v -> v - dt, w#springT)
                           |> Map.filter(v -> v > 0.0),
                       fx = List.filter(f -> w#t + dt - f#t0 < fxLifeSec(), w#fx) | w };
            let w2 = stepPlayer(input, dt, w1);
            let w3 = ridePlatforms(dt, w2);
            let w4 = touchThings(w3);
            let w5 = stepEnemies(dt, w4);
            let w6 = combat(input, w5);
            let w7 = fallOut(w6);
            stepCamera(dt, w7)
        }

    /// clear / over の間(みじかい間を置いて次へ)。
    def stepPhase(dt: Float64, w: World): World =
        let pt = w#phaseT + dt;
        let rules = RulesDoc.rec(w#rules);
        if (w#phase == "clear" and pt >= rules#clearWaitSec)
            loadStage(w#stageIx + 1, w)
        else if (w#phase == "over" and pt >= rules#overWaitSec)
            loadStage(0, { score = 0, stomps = 0, hearts = rules#maxHearts | w })
        else { phaseT = pt, t = w#t + dt | w }

    def stepPlayer(input: Input, dt: Float64, w: World): World =
        let wasAir = not w#player#body#onGround;
        let fallVy = w#player#body#vel#y;
        let p = Player.step(terrainOf(w), w#motion, dt, input, w#player);
        // 着地の砂煙(強い落下からの接地だけ)。
        let fx = if (wasAir and p#body#onGround and fallVy > 260.0)
            ({ kind = "land", pos = feetOf(p), t0 = w#t }: Fx) :: w#fx else w#fx;
        { player = p, fx = fx | w }

    def feetOf(p: Player.State): Vec2.Vec2 =
        { x = p#body#pos#x, y = p#body#pos#y + Physics.playerSize()#y * 0.5 }

    /// 動く床に乗る: 上から踏んだら上面へ吸着し、床の移動量で運ばれる(carry)。
    def ridePlatforms(dt: Float64, w: World): World =
        let p = w#player;
        let half = Vec2.mul(Physics.playerSize(), 0.5);
        let bottom = p#body#pos#y + half#y;
        let ts = Physics.tileSize();
        // 乗っている床の「この tick の移動量」と「上面 y」を 1 回の走査で取る。
        let ride = Stage.rec(w#stage)#platforms |> List.filterMap(pf -> {
            let prev = platformPosAt(w#motion, pf, w#t - dt);
            let now = platformPosAt(w#motion, pf, w#t);
            let width = Int32.toFloat64(pf#wTiles) * ts;
            let overlap = p#body#pos#x + half#x > now#x
                      and p#body#pos#x - half#x < now#x + width;
            let landing = p#body#vel#y >= 0.0
                      and bottom >= now#y and bottom - now#y <= 10.0;
            if (overlap and landing) Some((now#x - prev#x, now#y)) else None
        }) |> List.head;
        match ride {
            case None => w
            case Some((dx, topY)) =>
                // 上面へ吸着 → 床の移動量で横に運ぶ(壁に挟まれば slideBox が止める)。
                let snapped = { pos = { y = topY - half#y | p#body#pos },
                                vel = { y = 0.0 | p#body#vel },
                                onGround = true | p#body };
                let slid = Physics.slideBox(terrainOf(w), Physics.playerSize(), 1.0,
                                            false, 0.0, snapped#pos, { x = dx, y = 0.0 });
                { player = { body = { pos = slid#pos, vel = snapped#vel, onGround = true },
                             coyote = MotionDoc.rec(w#motion)#coyoteTime | p } | w }
        }

    /// 触れる物: バネ・コイン・チェックポイント・ゴール旗。
    def touchThings(w: World): World =
        let p = w#player;
        // バネ: 足元のマスがバネなら大ジャンプ(下降・接地の時だけ)。
        // 足の 1px 上のマスで見る — 接地中は足裏がマス境界ちょうどに居るため、
        // 下側で見ると地面の行に入ってバネを踏めない。
        let feet = feetOf(p);
        let fc = (Physics.tileOf(feet#x), Physics.tileOf(feet#y - 1.0));
        let onSpring = Stage.rec(w#stage)#springs
            |> List.exists(c -> (c#x, c#y) == fc and p#body#vel#y >= 0.0);
        let w1 = if (onSpring) {
            let vy = Physics.launchVelocity(w#motion, MotionDoc.rec(w#motion)#springTiles);
            { player = Player.launch(vy, p),
              springT = Map.insert(fc, 0.3, w#springT),
              fx = ({ kind = "spring", pos = feet, t0 = w#t }: Fx) :: w#fx | w }
        } else w;
        // コイン(1 マス矩形と重なったら取得)。
        let ts = Physics.tileSize();
        let hitCell = c -> touches(p, Stage.centerOf(c), { x = ts, y = ts });
        let newCoins = Stage.rec(w1#stage)#coins
            |> List.filter(c -> not Set.memberOf((c#x, c#y), w1#got) and hitCell(c));
        let w2 = if (List.isEmpty(newCoins)) w1 else {
            let got = List.foldLeft((acc, c) -> Set.insert((c#x, c#y), acc), w1#got, newCoins);
            let fx = List.map(c -> ({ kind = "coin", pos = Stage.centerOf(c), t0 = w1#t }: Fx),
                              newCoins) ::: w1#fx;
            { got = got, score = w1#score + RulesDoc.rec(w1#rules)#coinScore * List.length(newCoins),
              fx = fx | w1 }
        };
        // チェックポイント: 戻り先を差し替え、ハートを 1 つ返す。
        // 回復が無いと、長い面は「残機が尽きて最初から」に必ず着地する —
        // 中間ポイントは「ここまで来た」の褒美なので、ひと息つける形にする。
        let newCp = Stage.rec(w2#stage)#checkpoints
            |> List.filter(c -> not Set.memberOf((c#x, c#y), w2#cpOn) and hitCell(c));
        let w3 = match List.head(newCp) {
            case None    => w2
            case Some(c) => { cpOn = Set.insert((c#x, c#y), w2#cpOn),
                              checkpoint = standingAt(w2#stage, c),
                              hearts = Int32.min(RulesDoc.rec(w2#rules)#maxHearts, w2#hearts + 1) | w2 }
        };
        // ゴール旗(旗は 2 マスぶんの背)。
        let g = Stage.rec(w3#stage)#goal;
        let goalC = { x = (Int32.toFloat64(g#x) + 0.5) * ts,
                      y = Int32.toFloat64(g#y) * ts };
        if (touches(p, goalC, { x = ts, y = ts * 2.0 }))
            { phase = "clear", phaseT = 0.0, score = w3#score + RulesDoc.rec(w3#rules)#goalScore | w3 }
        else w3

    /// 主役の当たり箱と「中心 c・大きさ size の箱」が重なるか。
    def touches(p: Player.State, c: Vec2.Vec2, size: Vec2.Vec2): Bool =
        Hit.boxBox(p#body#pos, Physics.playerSize()#x, Physics.playerSize()#y,
                   c, size#x, size#y)

    def stepEnemies(dt: Float64, w: World): World =
        let t = terrainOf(w);
        let stepped = w#enemies
            |> List.map(e -> Enemies.step(t, w#enemyDoc, dt, w#t, w#player#body#pos, e));
        let enemies = List.map(fst, stepped);
        let born = List.flatMap(snd, stepped);
        let shots = (born ::: w#shots) |> List.filterMap(s -> Enemies.stepShot(t, dt, s));
        { enemies = enemies, shots = shots | w }

    /// 踏みつけ(上から)か被弾か。弾は常に被弾。
    /// 踏んだ敵と生き残りは 1 回の partition の裏表で取る — 消す敵を値の等値で探し直すと、
    /// 踏む条件が位置以外(無敵の残り・体力)も見るようになった瞬間に別の敵を巻き添えにする。
    def combat(input: Input, w: World): World =
        let p = w#player;
        let bottom = p#body#pos#y + Physics.playerSize()#y * 0.5;
        let touching = e -> touches(p, e#pos, Enemies.sizeOf(e#behavior));
        let stompable = e -> {
            let etop = e#pos#y - Enemies.sizeOf(e#behavior)#y * 0.5;
            p#body#vel#y > 40.0 and bottom - etop < 10.0
        };
        let (stomped, alive) = w#enemies |> List.partition(e -> touching(e) and stompable(e));
        let hurting = alive |> List.filter(touching);
        let w1 = if (List.isEmpty(stomped)) w else {
            // 踏みつけ: バウンド(押しっぱなしなら高く)+ hitstop + 星。
            let m = MotionDoc.rec(w#motion);
            let hTiles = if (input#jumpHeld) m#jumpHeightTiles
                         else m#stompBounceTiles;
            let vy = Physics.launchVelocity(w#motion, hTiles);
            { player = Player.launch(vy, p),
              enemies = alive,
              score = w#score + RulesDoc.rec(w#rules)#stompScore * List.length(stomped),
              stomps = w#stomps + List.length(stomped),
              freeze = m#hitstopSec,
              fx = List.map(e -> ({ kind = "stomp", pos = e#pos, t0 = w#t }: Fx), stomped)
                  ::: w#fx | w }
        };
        let shotHit = w1#shots
            |> List.exists(s -> touches(p, s#pos, { x = 6.0, y = 6.0 }));
        if ((not List.isEmpty(hurting) or shotHit) and w1#invuln <= 0.0 and List.isEmpty(stomped))
            hurt(w1)
        else w1

    /// 被弾: ハートを 1 減らし、少し弾き飛ばして無敵時間。残機 0 で over。
    def hurt(w: World): World =
        let hearts = w#hearts - 1;
        let p = w#player;
        let knocked = { body = { vel = { x = -p#facing * 120.0, y = -180.0 | p#body#vel }
                               | p#body } | p };
        if (hearts <= 0)
            { hearts = 0, phase = "over", phaseT = 0.0, player = knocked | w }
        else { hearts = hearts, invuln = MotionDoc.rec(w#motion)#invulnSec, player = knocked | w }

    /// 画面の下へ落ちたらチェックポイントへ(ハートも 1 減る)。
    def fallOut(w: World): World =
        let limit = Int32.toFloat64(Stage.rec(w#stage)#height) * Physics.tileSize() + 48.0;
        if (w#player#body#pos#y <= limit) w
        else {
            let back = { body = { pos = w#checkpoint, vel = Vec2.zero(), onGround = false }
                       | Player.initial(w#checkpoint) };
            let hearts = w#hearts - 1;
            if (hearts <= 0) { hearts = 0, phase = "over", phaseT = 0.0 | w }
            else { player = back, hearts = hearts, invuln = MotionDoc.rec(w#motion)#invulnSec | w }
        }

    /// カメラ: 進行方向へ先読みし、不感帯つきで追う(CameraRig)。
    /// 縦の不感帯を広く取るのがプラットフォーマーの作法 — ジャンプのたびに
    /// 画面が上下すると酔う。振り向きは横の緩和で滑らかに反転する。
    /// 先読み量も不感帯も motion Doc のノブ — 歩速を上げたら一緒に伸ばす物なので。
    def stepCamera(dt: Float64, w: World): World =
        let m = MotionDoc.rec(w#motion);
        let target = { x = w#player#body#pos#x + w#player#facing * m#camLeadPx,
                       y = w#player#body#pos#y - m#camLiftPx };
        let side: CameraRig.Follow = { deadzone = m#camDeadzoneX, k = m#camFollowKX };
        let vert: CameraRig.Follow = { deadzone = m#camDeadzoneY, k = m#camFollowKY };
        { cam = { x = w#cam#x + CameraRig.followDelta(side, dt, target#x, w#cam#x),
                  y = w#cam#y + CameraRig.followDelta(vert, dt, target#y, w#cam#y) } | w }

    // ── View / Main が読む口 ──

    pub def cameraFocus(w: World): Vec2.Vec2 = w#cam

    pub def worldRect(w: World): Rect2.Rect2 = Stage.worldRect(w#stage)

    pub def atlasName(): String = "px"

    pub def atlasKey(w: World): String = "gen${w#atlasGen}"

    /// コインがまだそのマスに在るか。
    pub def coinAlive(w: World, c: Stage.Cell): Bool =
        not Set.memberOf((c#x, c#y), w#got)

    // ── Doc の読み直し(watchFile / F1)──

    pub def reloadMotion(w: World): World \ Fs.FileRead =
        { motion = MotionDoc.load(MotionDoc.path()) | w }

    pub def reloadKeys(w: World): World \ Fs.FileRead =
        { keys = KeysDoc.load(KeysDoc.path()) | w }

    pub def reloadRules(w: World): World \ Fs.FileRead =
        { rules = RulesDoc.load(RulesDoc.path()) | w }

    pub def reloadEnemies(w: World): World \ Fs.FileRead =
        { enemyDoc = EnemyDoc.load(EnemyDoc.path()) | w }

    /// 面データの読み直しは、いまの面を作り直して出発点から(形が変わるので安全側)。
    pub def reloadStages(w: World): World \ Fs.FileRead =
        let doc = StageDoc.load(StageDoc.path());
        loadStage(w#stageIx, { stageDoc = doc | w })

    pub def reloadUiText(w: World): World \ Fs.FileRead =
        { uiText = UiText.load(UiText.path()) | w }

    pub def reloadTheme(w: World): World \ Fs.FileRead =
        let theme = Theme.load(Theme.path());
        { theme = theme,
          atlas = PxSpriteAtlas.bake(w#pxDoc, key -> Theme.resolve(theme, key)),
          atlasGen = w#atlasGen + 1 | w }

    pub def reloadSprites(w: World): World \ Fs.FileRead =
        let doc = PxSpriteDoc.load(spritePath());
        { pxDoc = doc,
          atlas = PxSpriteAtlas.bake(doc, key -> Theme.resolve(w#theme, key)),
          atlasGen = w#atlasGen + 1 | w }

    pub def spritePath(): String = "assets/px.sprite.json"
}
