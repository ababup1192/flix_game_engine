// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 見下ろしのレース。コースは下へ流れ（前進）、自機は画面の下寄りにいる。
//
// ── 遊びの骨格（5 本柱） ──
//   1. 急カーブとドリフト … カーブの急さは区間の curve が持つ。速いまま入ると
//      「道が横へ動くのに舵が追いつかない」+ 超過ぶんの横押しでアウトへ膨らむ。
//      X を押しながら曲がるとドリフト: 舵が深くなり減速もしないが、外へ流れ続ける。
//   2. スリップストリーム + ラバーバンド AI … 前走車の真後ろの範囲で加速。ライバルは
//      距離差で速度が補正され（離されると速く・千切ると遅く）、常に接戦へ戻る。
//   3. ニトロ … 危険な走り（ドリフト・張り付き・すれすれ）だけがゲージを貯め、
//      満タンで Z 発動。爆発的に速いが、操舵が半分になる。
//   4. クラッシュと押し合い … 障害物の直撃とドリフト中のはみ出しはスピン（操作不能 +
//      大減速 + ゲージ半減）。車どうしの接触はスピンさせず、互いに横へ弾き合って
//      少しのあいだ減速する（並走そのものは罰しない）。障害物は 4 種 — 点のコーン、
//      隙間を通す土管ゲート、閉じた式で往復する振り子バー、擦っても壊れないガードレール。
//   5. アイテム … 取った瞬間の順位で効果が決まる（乱数ゼロの逆転補正）。
//   おまけの軸: 坂 … 登りで遅く・下りで速い。頂上の向こうは道が隠れて先が読めない。
//
// ── 場面の移り変わり（Phase） ──
//   Title ──Space──▶ Racing ──totalLaps 周──▶ Win（最下位以外）/ Lose（最下位）──Space──▶ Title
//
// 数値は RulesDoc / RivalsDoc、色は ThemeDoc / PaletteDoc、コースは CourseDoc、
// 粒の演出は assets/fx/*.fx.json — World は「規則」だけに集中する。
// Doc が壊れていても止まらない（fail-open）: 読めない → 既定値で起動。
mod World {

    /// いま画面が何をしているか。
    pub enum Phase with Eq, ToString {
        case Title      // 開始待ち
        case Racing     // 走っている
        case Win        // 完走（最下位以外）
        case Lose       // 完走したが最下位
    }

    /// ライバル 1 台。
    ///   progress … 走った距離（px。自機の distance と同じ物差し）。
    ///   off      … 道の中心からの横ずれ（px。右が正。レーン変更で滑らかに動く）。
    ///   baseSpeed / corner / laneBias … 性格（RivalsDoc の 1 行から写す）。
    ///   passed   … 自機がこのライバルを既に抜いたか（二重加点を防ぐ掛け金）。
    pub type alias Rival = {
        progress = Float64, off = Float64,
        baseSpeed = Float64, corner = Float64, laneBias = Float64,
        passed = Bool
    }

    /// ドリフト中に路面へ残るタイヤ痕の 1 点（dist = 前進距離 px, off = 道の中心からの横ずれ px）。
    pub type alias Skid = { dist = Float64, off = Float64, turn = Float64 }

    /// 1 フレームぶんの操作（Controls が組んで渡す）。
    ///   dir = ハンドル（-1/0/+1）、brake = ↓、driftHeld = X、nitroTap = Z を押した瞬間。
    pub type alias Inputs = { dir = Float64, brake = Bool, driftHeld = Bool, nitroTap = Bool }

    /// fx.json から読んだ粒の効果一式（発生は World、絵は View が描く）。
    pub type alias FxSpecs = {
        smoke = FxDoc.Spec,   // ドリフトの白煙
        spark = FxDoc.Spec,   // すれすれの火花
        flame = FxDoc.Spec,   // ニトロの炎（loop）
        shock = FxDoc.Spec,   // ニトロ発動の瞬間だけ広がる衝撃の輪
        crash = FxDoc.Spec    // クラッシュの閃光と破片
    }

    /// 起動時と描き出しが同じ形で読む Doc の束。
    pub type alias Docs = {
        rules = RulesDoc.Doc, rivalsCfg = RivalsDoc.Doc, theme = ThemeDoc.Doc,
        course = CourseDoc.Doc, props = PropsDoc.Doc, palette = PaletteDoc.Doc,
        sprites = PxSpriteDoc.Doc, fx = FxSpecs, sfxtune = SfxTuneDoc.Doc
    }

    /// ゲームの状態。
    ///   playerOff / distance / speed … 自機の道の中心からの横ずれと、いまの前進速度。
    ///   nitro     … ゲージ（0..1。1.0 で発動できる）。
    ///   nitroLeft / boostLeft / spinLeft … 発動中のニトロ / アイテムブースト / スピンの残り秒。
    ///   bumpLeft  … 車どうしがぶつかって速度が落ちている残り秒。
    ///   drifting / steerDir … いまドリフト中か・ハンドルの向き（絵の傾きと煙の向きに使う）。
    ///   taken     … 取ったアイテムの通し行（同じアイテムは 1 周で 1 回だけ）。
    ///   skids     … タイヤ痕（コース相対の点のまま持ち、View が毎フレーム投影する）。
    ///   bursts    … 進行中の粒の効果（煙・火花・クラッシュ。at はコース相対）。
    ///   fxSeq     … 効果の通し番号（同じ煙が毎回そっくり同じ姿になるのを避ける種）。
    ///   smokeClock … ドリフト煙を一定間隔で焚くための貯め時計。
    pub type alias World = {
        rules = RulesDoc.Doc,
        rivalsCfg = RivalsDoc.Doc,
        theme = ThemeDoc.Doc,
        course = CourseDoc.Doc,
        props = PropsDoc.Doc,
        palette = PaletteDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        atlas = PxSpriteAtlas.Baked,
        atlasGen = Int32,
        fx = FxSpecs,
        sfxtune = SfxTuneDoc.Doc,
        phase = Phase,
        t = Float64,
        playerOff = Float64,
        distance = Float64,
        speed = Float64,
        lap = Int32,
        rank = Int32,
        score = Int32,
        nitro = Float64,
        nitroLeft = Float64,
        boostLeft = Float64,
        spinLeft = Float64,
        bumpLeft = Float64,
        drifting = Bool,
        steerDir = Float64,
        rivals = List[Rival],
        taken = Set[Int32],
        skids = List[Skid],
        bursts = List[Fx.Burst],
        fxSeq = Int32,
        smokeClock = Float64,
        railClock = Float64,
        activeDocsWritten = String
    }

    // ── 画面の寸法とレイアウト（project.json の design 240×360 と対。View も同じ値を使う） ──

    pub def designW(): Float64 = 240.0
    pub def designH(): Float64 = 360.0

    /// コース 1 行が距離いくつ分か（px）。距離 → 通し行の割り算の分母。
    pub def rowPitch(): Float64 = 40.0

    /// 1 周の距離（px）= コースの行数 × 1 行の距離。Doc に別の数値としては持たない —
    /// 持つと、コースの行数を編集したとき周長だけ古いままずれる。
    pub def lapLength(course: CourseDoc.Doc): Float64 =
        Int32.toFloat64(CourseDoc.rowCount(course)) * rowPitch()

    /// 自機は画面の少し先（1.35 行ぶん前）に見える。判定も同じ行を見る —
    /// 絵と当たりの物差しを 1 つにする（マジックナンバーを 2 か所に置かない）。
    pub def playerAheadPx(): Float64 = rowPitch() * 1.35

    /// 当たり判定の車の大きさ（px）。ドット絵 17×27 より一回り小さくして理不尽な接触を減らす。
    pub def carHitW(): Float64 = 14.0
    pub def carHitLen(): Float64 = 24.0

    /// 自機が出られる横ずれの範囲（px）。道幅の半分 + 草へ踏み出せる余地。
    /// 画面の縁で止めないのは、道そのものが画面の外まで曲がっていくため —
    /// 縁で止めると急カーブで車だけが道に置いて行かれる。
    /// ガードレールのある側だけは道の端で止まる（壁は通り抜けられない）。
    def offRangeOf(w: World): { lo = Float64, hi = Float64 } =
        let n = playerRowOf(w#distance);
        let half = halfWidthAt(n, w#course);
        let side = railSideAt(n, w);
        { lo = if (side < 0.0) 0.0 - half else 0.0 - half - grassReach(),
          hi = if (side > 0.0) half else half + grassReach() }

    /// 道の外（草）へ踏み出せる幅（px）。ここを越える前に大減速で引き戻される。
    def grassReach(): Float64 = 52.0

    // ── コースの読み取り（行・曲がり・道幅） ──

    /// 距離 d にいる自機が「乗っている」通し行（0 始まり・周回しても増え続ける）。
    pub def playerRowOf(d: Float64): Int32 =
        Num.floorInt((d + playerAheadPx()) / rowPitch())

    /// 通し行 n で道が曲がっていく強さ（+ が右）。急さの物差しはこれ 1 本。
    pub def curveAt(n: Int32, course: CourseDoc.Doc): Float64 =
        CourseDoc.curveAt(n, course)

    /// 通し行 n の道の半幅（px）。
    pub def halfWidthAt(n: Int32, course: CourseDoc.Doc): Float64 =
        CourseDoc.halfWidthAt(n, course)

    /// 通し行 n の路面の左右端（道の中心からの横ずれ px）。
    /// セグメントどうしで辺を共有させるため、絵の側はこの 1 か所からしか道の幅を引かない
    /// （行ごとに別々に幅を出すと、セグメントの境目で道が横へ飛ぶ）。
    pub def roadEdgeAt(n: Int32, course: CourseDoc.Doc): { xl = Float64, xr = Float64 } =
        let half = halfWidthAt(n, course);
        { xl = 0.0 - half, xr = half }

    /// 距離 d まで走ってきて、道がどれだけ向きを変えたか（+ = 右へ回った）。
    /// 空・太陽・雲はこの値で横へ流す — セグメントの折れだけだと、急カーブと「強く傾いた直線」が
    /// 見分けられない（景色が動いて初めて「回った」と読める）。
    /// 周回ぶんは足さない。区間表の curve の合計は 1 周で 0 に戻す決まりなので、
    /// 足すと同じ場所なのに周ごとに空の位置がずれる。
    pub def headingAt(d: Float64, course: CourseDoc.Doc): Float64 =
        let rowF = d / rowPitch();
        let n = Num.floorInt(rowF);
        let count = Int32.max(1, CourseDoc.rowCount(course));
        let m = Int32.modulo(Int32.modulo(n, count) + count, count);
        let whole = List.range(0, m) |> List.foldLeft((acc, i) -> acc + curveAt(i, course), 0.0);
        (whole + (rowF - Int32.toFloat64(n)) * curveAt(n, course)) / rowPitch()

    /// 「急カーブ」と呼べる曲がりの強さ。敵のコーナー減速をここで 0..1 に正規化する。
    def sharpCurve(): Float64 = 22.0

    /// アイテムを拾える横の当たり幅（px）。
    def itemReach(): Float64 = 16.0

    /// コーン 1 本の半分の太さ（px）。
    def coneHalfW(): Float64 = 4.0

    /// コーンの直撃と判定する横の距離（px）。この外側 nearMissDist までが「すれすれ」。
    pub def coneHitR(): Float64 = carHitW() / 2.0 + coneHalfW()

    /// 自機の足元が路面か。草なら false（= 減速。ドリフト中ならスピン）。
    pub def onRoad(w: World): Bool =
        Float64.abs(w#playerOff) <= halfWidthAt(playerRowOf(w#distance), w#course)

    // ── 立ち物（置き場 Doc）と、障害物の当たりの範囲 ──

    /// 通し行 n に置かれている物。周回の巻き戻しはコースの行数で行う
    /// （置き場の表はコース 1 周ぶんしか持たない）。
    pub def propCellsAt(n: Int32, w: World): List[PropsDoc.Cell] =
        PropsDoc.cellsAt(CourseDoc.wrapRow(n, w#course), w#props)

    /// 通し行 n のアイテムの横ずれ（px）。
    pub def itemOffsAt(n: Int32, w: World): List[Float64] =
        let half = halfWidthAt(n, w#course);
        propCellsAt(n, w) |> List.filterMap(c ->
            if (c#kind == PropsDoc.Kind.Item) Some(PropsDoc.laneOff(c#lane, half)) else None)

    /// 障害物 1 つの当たり（道の中心からの横ずれ px の範囲）と、その正体。
    /// 点でなく範囲で持つのは、土管ゲートのように「隙間以外ぜんぶ塞がっている」物を
    /// 同じ 1 つの規則で扱うため。絵（ViewRoad）もこの範囲から引く。
    pub type alias Blocker = { lo = Float64, hi = Float64, kind = PropsDoc.Kind }

    /// 通し行 n の障害物の範囲ぜんぶ。土管ゲートは左右 2 つぶんの範囲になる。
    pub def blockersAt(n: Int32, w: World): List[Blocker] =
        let half = halfWidthAt(n, w#course);
        propCellsAt(n, w) |> List.flatMap(c ->
            match c#kind {
                case PropsDoc.Kind.Item => Nil
                case PropsDoc.Kind.Cone =>
                    let x = PropsDoc.laneOff(c#lane, half);
                    ({ lo = x - coneHalfW(), hi = x + coneHalfW(), kind = c#kind }: Blocker) :: Nil
                case PropsDoc.Kind.Gate => gateBlockers(c#lane, half, w)
                case PropsDoc.Kind.Bar =>
                    let x = barOffAt(n, w);
                    let hw = PropsDoc.rec(w#props)#barHalfWidth;
                    ({ lo = x - hw, hi = x + hw, kind = c#kind }: Blocker) :: Nil
            })

    /// 土管ゲート = 隙間の左右に伸びる 2 つの範囲。土管の外側の端を道の外まで伸ばすのは、
    /// 草へ迂回して隙間を通らずに済ませられないようにするため。
    def gateBlockers(lane: Int32, half: Float64, w: World): List[Blocker] =
        let gap = Int32.max(1, PropsDoc.rec(w#props)#gateGapLanes);
        let leftLane = lane - (gap - 1) / 2;
        let far = half + grassReach() + 40.0;
        let gapL = PropsDoc.laneEdge(leftLane, half);
        let gapR = PropsDoc.laneEdge(leftLane + gap, half);
        let span = (lo, hi) -> if (hi <= lo) Nil
            else ({ lo = lo, hi = hi, kind = PropsDoc.Kind.Gate }: Blocker) :: Nil;
        span(0.0 - far, gapL) ::: span(gapR, far)

    /// 振り子バーが通し行 n・時刻 t にいる横ずれ（px）。閉じた式 1 本で決まる —
    /// 乱数も、覚えておく状態も無い。行番号が位相を決めるので、同じ行のバーは
    /// 何周目でもそっくり同じリズムで往復し、覚えて攻略できる。
    pub def barOffAt(n: Int32, w: World): Float64 =
        let phase = w#t / PropsDoc.rec(w#props)#barPeriod + Int32.toFloat64(n) * PropsDoc.rec(w#props)#barPhaseStep;
        let half = halfWidthAt(n, w#course);
        Vec2.sin(2.0 * Vec2.pi() * phase) * Float64.max(0.0, half - PropsDoc.rec(w#props)#barHalfWidth)

    // ── ガードレール ──

    /// 通し行 n でガードレールが立っている側（-1 = 左・+1 = 右・0 = 立っていない）。
    pub def railSideAt(n: Int32, w: World): Float64 =
        CourseDoc.railSideAt(n, w#course)

    /// 自機が壁を擦っているか。擦っている間は減速し、火花が散り、ゲージが貯まる。
    /// 壁はスピンさせない — 擦り付けて曲がる「遅いが確実な線」を下手な人に残す。
    pub def scraping(w: World): Bool =
        let n = playerRowOf(w#distance);
        let side = railSideAt(n, w);
        side != 0.0 and w#playerOff * side >= halfWidthAt(n, w#course) - RulesDoc.rec(w#rules)#railTouch

    // ── 初期状態と場面の切り替え ──

    /// ゲーム開始時の状態。Title 画面から始まる（まだ走っていない）。
    pub def initial(docs: Docs): World =
        { rules = docs#rules, rivalsCfg = docs#rivalsCfg, theme = docs#theme,
          course = docs#course, props = docs#props, palette = docs#palette,
          sprites = docs#sprites,
          atlas = PxSpriteAtlas.bake(docs#sprites,
                      PaletteDoc.carInk(docs#palette, ThemeDoc.rec(docs#theme)#player)),
          atlasGen = 0,
          fx = docs#fx, sfxtune = docs#sfxtune,
          phase = Phase.Title, t = 0.0,
          playerOff = 0.0, distance = 0.0, speed = 0.0,
          lap = 0, rank = startRank(docs#rivalsCfg), score = 0,
          nitro = 0.0, nitroLeft = 0.0, boostLeft = 0.0, spinLeft = 0.0, bumpLeft = 0.0,
          drifting = false, steerDir = 0.0,
          rivals = initialRivals(docs), taken = Set.empty(),
          skids = Nil, bursts = Nil, fxSeq = 0, smokeClock = 0.0, railClock = 0.0,
          activeDocsWritten = "" }

    /// ライバルの初期配置。性格は RivalsDoc の 1 行ずつ。少し前方に階段状に置き、
    /// 好みのレーン（laneBias）に応じて左右へ振る。
    def initialRivals(docs: Docs): List[Rival] =
        let half = roadHalfPx(docs#course);
        RivalsDoc.rec(docs#rivalsCfg)#rows |> List.zipWithIndex |> List.map(entry -> {
            let (i, row) = entry;
            // 1 台目でも slipRange の外へ置く — スタートした瞬間からスリップが効くと、
            // 「敵の後ろに付きに行く」という操作がないまま加速だけ手に入ってしまう。
            { progress = playerAheadPx() + RulesDoc.rec(docs#rules)#slipRange + 30.0 + Int32.toFloat64(i) * 80.0,
              off = row#lane * half * 0.6,
              baseSpeed = row#speed, corner = row#corner, laneBias = row#lane,
              passed = false }
        })

    /// 道の半幅（px）の見積もり（スタート行の道幅から。レーンの振り幅に使う）。
    def roadHalfPx(course: CourseDoc.Doc): Float64 =
        halfWidthAt(0, course)

    /// 開始時の順位。自機は最後尾から出る（ライバルは全員前にいる）。
    def startRank(rivalsCfg: RivalsDoc.Doc): Int32 =
        List.length(RivalsDoc.rec(rivalsCfg)#rows) + 1

    /// 遊び始め（Title → Racing）。initial から作り直し、時計・効果の通し番号・
    /// 表示中 Doc の名乗りだけ引き継ぐ（絵の流れと Studio への名乗りを巻き戻さない）。
    /// [遷移: Title→Racing]
    pub def startGame(w: World): World =
        { phase = Phase.Racing, speed = RulesDoc.rec(w#rules)#forwardSpeed,
          t = w#t, fxSeq = w#fxSeq, activeDocsWritten = w#activeDocsWritten,
          atlas = w#atlas, atlasGen = w#atlasGen
        | initial(docsOf(w)) }

    /// 最初（Title）へ戻る。時計と効果の通し番号は引き継ぐ（絵の流れを巻き戻さない）。[遷移: Win/Lose→Title]
    /// アトラスと世代も引き継ぐ — initial は世代 0 から数え直すので、読み直し済みの
    /// 世界で仕切り直すと「新しい画素なのに古い鍵」になり、App が上げ直さない。
    pub def toTitle(w: World): World =
        { t = w#t, fxSeq = w#fxSeq, atlas = w#atlas, atlasGen = w#atlasGen
        | initial(docsOf(w)) }

    /// Space/Enter の意味は場面で変わる: Title では開始、Win/Lose では仕切り直し、走行中は無し。
    pub def confirm(w: World): World =
        match w#phase {
            case Phase.Title  => startGame(w)
            case Phase.Racing => w
            case _            => toTitle(w)
        }

    pub def isRacing(w: World): Bool = w#phase == Phase.Racing

    /// いまの World が持つ Doc の束（仕切り直しで読み直さずに使う）。
    pub def docsOf(w: World): Docs =
        { rules = w#rules, rivalsCfg = w#rivalsCfg, theme = w#theme, course = w#course,
          props = w#props, palette = w#palette, sprites = w#sprites, fx = w#fx,
          sfxtune = w#sfxtune }

    // ══════════════════════════════════════════════════════
    // 毎フレームの更新
    // ══════════════════════════════════════════════════════

    /// 毎フレームの更新。時計と粒の寿命は場面を問わず進める — 待っている画面でも
    /// 海が光り、煙は流れて消える。走りの規則は Racing のときだけ。
    pub def step(inputs: Inputs, dt: Float64, w: World): World =
        let ticked = { t = w#t + dt, bursts = Fx.expire(w#t + dt, w#bursts) | w };
        match w#phase {
            case Phase.Racing => tickRacing(inputs, dt, ticked)
            case _            => ticked
        }

    /// Racing の 1 フレーム。「進める部品」を順に pipe でつなぐ（読み下すと 1 フレームの物語になる）。
    def tickRacing(inputs: Inputs, dt: Float64, w: World): World =
        w
            |> resolveDrift(inputs)
            |> fireNitro(inputs)
            |> steer(inputs, dt)
            |> advance(inputs, dt)
            |> scrapeRail(dt)
            |> chargeNitro(dt)
            |> moveRivals(dt)
            |> rivalContact(dt)
            |> resolvePasses
            |> resolveDriftFall
            |> emitDriftTrail(dt)
            |> coolTimers(dt)
            |> checkLaps

    // ── 柱 1: ハンドル・カーブ・ドリフト ──

    /// ドリフトの成立: X を押しながらハンドルを切っている間だけ（スピン中は不成立）。
    def resolveDrift(inputs: Inputs, w: World): World =
        { drifting = inputs#driftHeld and inputs#dir != 0.0 and w#spinLeft <= 0.0,
          steerDir = inputs#dir | w }

    /// ハンドル。ドリフト中は舵が深く（driftTurnBoost）、ニトロ中は重い（nitroSteerPenalty）。
    /// スピン中は効かない。止めるのは画面の縁ではなく「道 + 草」の範囲（offRangeOf）—
    /// 道そのものが画面の外まで曲がっていくので、縁で止めると車だけが道に置いて行かれる。
    def steer(inputs: Inputs, dt: Float64, w: World): World =
        if (w#spinLeft > 0.0) w
        else {
            let boost = if (w#drifting) RulesDoc.rec(w#rules)#driftTurnBoost else 1.0;
            let penalty = if (w#nitroLeft > 0.0) RulesDoc.rec(w#rules)#nitroSteerPenalty else 1.0;
            let steered = w#playerOff + inputs#dir * RulesDoc.rec(w#rules)#steerSpeed * boost * penalty * dt;
            let rng = offRangeOf(w);
            { playerOff = Num.clamp(rng#lo, rng#hi, steered + curveDrift(dt, w)) | w }
        }

    /// カーブが車を道の外側へ押し出す量（このフレームぶん・道の中心から見た横ずれの変化）。
    /// 位置を道の中心からの横ずれで持つので、「道に付いていく」ぶんは式に出てこない
    /// （曲がりきれずに置いていかれる分だけが残る）。
    ///   - グリップの範囲（gripSpeed まで）なら横ずれは増えない。
    ///   - 超過した速さの分は曲がりきれず、アウト側へ置いていかれる（curvePush）。
    ///   - ドリフト中は超過に関わらず、外へ一定の速さで流れ続ける（driftSlide）。
    def curveDrift(dt: Float64, w: World): Float64 =
        let curve = curveAt(playerRowOf(w#distance), w#course);
        if (w#drifting)
            0.0 - sideOf(curve) * RulesDoc.rec(w#rules)#driftSlide * dt
        else {
            let excess = Float64.max(0.0, w#speed - RulesDoc.rec(w#rules)#gripSpeed);
            let missRate = Num.clamp01(excess * RulesDoc.rec(w#rules)#curvePush / RulesDoc.rec(w#rules)#forwardSpeed);
            0.0 - curve * missRate * w#speed / rowPitch() * dt
        }

    /// カーブの向き（右 = +1 / 左 = -1 / 直線 = 0）。ドリフトで外へ流れる向きに使う。
    def sideOf(curve: Float64): Float64 =
        if (curve > 0.0) 1.0 else if (curve < 0.0) -1.0 else 0.0

    // ── 前進（速度の合成）と行またぎの出来事 ──

    /// 前進。速度は「基本 × 状況の倍率の積」で毎フレーム決め直す（状態にため込まない）。
    /// 行をまたいだ瞬間に、その行の出来事（アイテム・障害物・すれすれ）を 1 回だけ解決する。
    def advance(inputs: Inputs, dt: Float64, w: World): World =
        let sp = speedOf(inputs, w);
        let rowBefore = playerRowOf(w#distance);
        let moved = { distance = w#distance + sp * dt, speed = sp | w };
        let rowAfter = playerRowOf(moved#distance);
        if (rowAfter > rowBefore) crossRow(rowAfter, moved) else moved

    /// いまの前進速度。危険な走りほど速い、が積の形で読める。
    def speedOf(inputs: Inputs, w: World): Float64 =
        RulesDoc.rec(w#rules)#forwardSpeed
            * hillMult(w)
            * (if (onRoad(w)) 1.0 else RulesDoc.rec(w#rules)#offRoadSlow)
            * (if (scraping(w)) RulesDoc.rec(w#rules)#railScrapeSlow else 1.0)
            * (if (inputs#brake and not w#drifting) RulesDoc.rec(w#rules)#brakeSlow else 1.0)
            * (if (slipActive(w)) RulesDoc.rec(w#rules)#slipBoost else 1.0)
            * (if (w#nitroLeft > 0.0) RulesDoc.rec(w#rules)#nitroBoost else 1.0)
            * (if (w#boostLeft > 0.0) RulesDoc.rec(w#rules)#itemBoostLow else 1.0)
            * (if (w#spinLeft > 0.0) RulesDoc.rec(w#rules)#spinSlow else 1.0)
            * (if (w#bumpLeft > 0.0) RulesDoc.rec(w#rules)#bumpSlow else 1.0)

    /// 坂の速度倍率。登りで遅く、下りで速い。1 行ぶんの勾配にしか掛けないので、
    /// 長い坂ほど効き続ける。0.6〜1.4 で頭打ちにするのは、極端な勾配を書かれても
    /// 止まったり倍速になったりしないため（コースの書き手を信用しすぎない）。
    def hillMult(w: World): Float64 =
        let grade = CourseDoc.hillAt(playerRowOf(w#distance), w#course);
        Num.clamp(0.6, 1.4, 1.0 - RulesDoc.rec(w#rules)#hillSpeedGain * grade)

    /// 通し行 n に入った瞬間の出来事: アイテムを拾う / 障害物に当たる / すれすれをかすめる。
    /// 行ごとに 1 回だけ通るので、同じマスで二重に起きない。
    /// 入った行だけを見て、飛び越した行は見ない — project.json の maxDeltaTime が
    /// 1 フレームの進みを 1 行（40px）より小さく抑えるので、間の行は落ちない。
    def crossRow(n: Int32, w: World): World =
        w |> pickItems(n) |> hitObstacles(n)

    /// アイテムマス: 車の幅 + 少しの範囲で拾える。効果は「取った瞬間の順位」で決める
    /// （1 位 = スコアだけ / 2 位 = ゲージ / 3 位以下 = 即ブースト。乱数ゼロの逆転補正）。
    def pickItems(n: Int32, w: World): World =
        let reached = itemOffsAt(n, w)
            |> List.exists(off -> Float64.abs(off - w#playerOff) <= itemReach());
        if (not reached or Set.memberOf(n, w#taken)) w
        else applyItem({ taken = Set.insert(n, w#taken) | w })

    /// 順位に応じたアイテムの効果。
    def applyItem(w: World): World =
        if (w#rank == 1)      { score = w#score + RulesDoc.rec(w#rules)#itemScoreBonus | w }
        else if (w#rank == 2) { nitro = Num.clamp01(w#nitro + RulesDoc.rec(w#rules)#itemNitroCharge) | w }
        else                  { boostLeft = RulesDoc.rec(w#rules)#itemBoostDuration | w }

    /// 障害物マス: 車体が範囲に触れていればスピン、触れていなくても範囲の端から
    /// nearMissDist 以内なら「すれすれ」（ゲージが貯まり火花が散る）。
    /// 範囲 1 つにつき 1 回数えるので、土管ゲートの狭い隙間を両側すれすれで抜けると 2 回貯まる —
    /// 危険に寄るほど強くなる仕組みの、一番おいしい所。
    def hitObstacles(n: Int32, w: World): World =
        let blockers = blockersAt(n, w);
        let carHalf = carHitW() / 2.0;
        let gapOf = b ->
            Float64.max(b#lo - (w#playerOff + carHalf), (w#playerOff - carHalf) - b#hi);
        if (blockers |> List.exists(b -> gapOf(b) <= 0.0)) startSpin(w)
        else {
            let grazes = blockers |> List.count(b -> gapOf(b) <= RulesDoc.rec(w#rules)#nearMissDist);
            if (grazes <= 0) w
            else
                { nitro = Num.clamp01(
                      w#nitro + RulesDoc.rec(w#rules)#nitroChargeNearMiss * Int32.toFloat64(grazes))
                | burstAt(w#fx#spark, { x = w#playerOff, y = playerDistOf(w) }, w) }
        }

    /// 壁擦りの火花を散らす間隔（秒）。
    def sparkPeriod(): Float64 = 0.07

    /// ガードレールを擦っている間: 減速（speedOf 側）と引き換えにゲージが貯まり、
    /// sparkPeriod 秒おきに火花が散る。壁の面から火花を出すので、擦っている所が目で判る。
    def scrapeRail(dt: Float64, w: World): World =
        if (not scraping(w)) { railClock = 0.0 | w }
        else {
            let charged = { nitro = Num.clamp01(w#nitro + RulesDoc.rec(w#rules)#nitroChargeRail * dt) | w };
            let clock = w#railClock + dt;
            if (clock < sparkPeriod()) { railClock = clock | charged }
            else {
                let n = playerRowOf(w#distance);
                let face = railSideAt(n, w) * halfWidthAt(n, w#course);
                { railClock = clock - sparkPeriod()
                | burstAt(w#fx#spark, { x = face, y = playerDistOf(w) }, charged) }
            }
        }

    /// 自機の世界座標での前進位置（絵と当たりが共有する物差し）。
    pub def playerDistOf(w: World): Float64 =
        w#distance + playerAheadPx()

    // ── 柱 3: ニトロ（貯める・撃つ） ──

    /// スリップストリームの範囲の中か（前走車の真後ろ・幅 slipWidth）。
    /// 横のずれは道の中心から測る — カーブの途中では画面上の左右で測ると、
    /// 同じ車線に並んでいるのに範囲から外れてしまう。
    pub def slipActive(w: World): Bool =
        let me = playerDistOf(w);
        w#rivals |> List.exists(r ->
            r#progress > me and r#progress - me <= RulesDoc.rec(w#rules)#slipRange
                and Float64.abs(r#off - w#playerOff) <= RulesDoc.rec(w#rules)#slipWidth / 2.0)

    /// 危険な走りがゲージを貯める: ドリフト（最速）とスリップ維持（毎秒）。
    /// すれすれの加算は hitObstacles 側（出来事なので行またぎで 1 回）。
    def chargeNitro(dt: Float64, w: World): World =
        let rate = (if (w#drifting) RulesDoc.rec(w#rules)#nitroChargeDrift else 0.0)
                 + (if (slipActive(w)) RulesDoc.rec(w#rules)#nitroChargeSlip else 0.0);
        { nitro = Num.clamp01(w#nitro + rate * dt) | w }

    /// Z で発動（満タンのときだけ）。ゲージを使い切り、nitroDuration 秒だけ爆発的に速くなる。
    def fireNitro(inputs: Inputs, w: World): World =
        if (inputs#nitroTap and w#nitro >= 1.0 and w#spinLeft <= 0.0)
            { nitroLeft = RulesDoc.rec(w#rules)#nitroDuration, nitro = 0.0 | w }
        else w

    // ── 柱 2: ライバル（ラバーバンド + コーナー減速 + レーン変更） ──

    /// ライバルを進める。速度 = 地力 × コーナーの腕 × ラバーバンド補正。
    /// 横は「2 行先の道の中心 + 好みの寄り」へ滑らかに寄り、前が詰まったら横へずれる。
    def moveRivals(dt: Float64, w: World): World =
        let moved = w#rivals |> List.map(r -> moveRival(dt, w, r));
        { rivals = moved | w }

    def moveRival(dt: Float64, w: World, r: Rival): Rival =
        let cfg = RivalsDoc.rec(w#rivalsCfg);
        let theirRow = Num.floorInt(r#progress / rowPitch());
        // コーナー減速: 急さ（1 マス幅 = ゆるい、2 マス幅 = 急）を 0..1 に写し、下手なほど落とす。
        let sharpness = Num.clamp01(Float64.abs(curveAt(theirRow, w#course)) / sharpCurve());
        let cornerMult = 1.0 - (1.0 - cfg#cornerSlow) * sharpness * (1.0 - r#corner);
        // ラバーバンド: 自機より後ろ（正）なら速く、前（負）なら遅く。
        let gap = Num.clamp(-1.0, 1.0, (playerDistOf(w) - r#progress) / cfg#rubberRange);
        let rubber = 1.0 + (if (gap > 0.0) cfg#rubberCatchUp * gap else cfg#rubberSlowDown * gap);
        let sp = r#baseSpeed * cornerMult * rubber;
        // レーン: 好みの寄りへ。前が詰まっていたら反対側へ避ける。
        let target = laneTargetOf(w, r);
        let dx = Num.clamp(-cfg#laneChangeSpeed * dt, cfg#laneChangeSpeed * dt, target - r#off);
        { progress = r#progress + sp * dt, off = r#off + dx | r }

    /// ライバルが寄っていきたい横ずれ。基本は「好みの寄り」、
    /// 前方に他の車（自機含む）がいたらその反対側へ 1 台ぶんずれる。
    /// 道を追いかける項が要らないのは、横ずれが道の中心から測られているため。
    def laneTargetOf(w: World, r: Rival): Float64 =
        let base = r#laneBias * roadHalfPx(w#course) * 0.6;
        match blockerAheadOf(w, r) {
            case None      => base
            case Some(off) => if (off <= r#off) base + carHitW() else base - carHitW()
        }

    /// ライバル r の前方（40px 以内・横も車 1 台ぶん以内）にいる車の横ずれ。自機も他のライバルも見る。
    def blockerAheadOf(w: World, r: Rival): Option[Float64] =
        let ahead = (pos, off) -> pos > r#progress and pos - r#progress < 40.0
            and Float64.abs(off - r#off) < carHitW() * 1.2;
        let rivalOff = w#rivals
            |> List.filter(o -> ahead(o#progress, o#off) and o#progress != r#progress)
            |> List.head |> Option.map(o -> o#off);
        if (ahead(playerDistOf(w), w#playerOff)) Some(w#playerOff) else rivalOff

    // ── 柱 4: 押し合いとスピン ──

    /// 車どうしの接触は押し合い: 触れている間は互いに反対側へ弾かれ、
    /// 離れたあとも bumpDuration 秒だけ速度が落ちる。ゲージは減らさない —
    /// 追いついて並ぶこと自体を罰すると、上位の駆け引きが成り立たない。
    def rivalContact(dt: Float64, w: World): World =
        let me = playerDistOf(w);
        let touching = r -> Float64.abs(r#progress - me) < carHitLen() * 0.7
            and Float64.abs(r#off - w#playerOff) < carHitW() * 0.75;
        let dirs = w#rivals |> List.filter(touching) |> List.map(r -> pushDirOf(w#playerOff, r#off));
        if (List.isEmpty(dirs)) w
        else {
            let dir = Num.clamp(-1.0, 1.0, List.foldLeft(Add.add, 0.0, dirs));
            let shove = RulesDoc.rec(w#rules)#bumpPush * dt;
            let rng = offRangeOf(w);
            let pushed = w#rivals |> List.map(r ->
                if (touching(r)) { off = r#off - pushDirOf(w#playerOff, r#off) * shove | r } else r);
            let moved =
                { playerOff = Num.clamp(rng#lo, rng#hi, w#playerOff + dir * shove),
                  rivals = pushed, bumpLeft = RulesDoc.rec(w#rules)#bumpDuration | w };
            if (w#bumpLeft > 0.0) moved
            else burstAt(w#fx#spark, { x = w#playerOff, y = me }, moved)
        }

    /// 自機が相手から離れる向き（右 = +1 / 左 = -1）。真横に重なったときは右へ逃がす。
    def pushDirOf(playerOff: Float64, rivalOff: Float64): Float64 =
        if (playerOff < rivalOff) -1.0 else 1.0

    /// スピン開始: 操作不能 + 大減速 + ゲージ半減 + クラッシュの粒。
    /// ドリフト中に草へ流れ落ちたときもここへ来る（resolveDriftFall が判定）。
    def startSpin(w: World): World =
        if (w#spinLeft > 0.0) w
        else
            { spinLeft = RulesDoc.rec(w#rules)#spinDuration,
              nitro = w#nitro * (1.0 - RulesDoc.rec(w#rules)#spinNitroLoss),
              nitroLeft = 0.0, drifting = false
            | burstAt(w#fx#crash, { x = w#playerOff, y = playerDistOf(w) }, w) }

    // ── 追い抜きと順位 ──

    /// 追い抜きを解く: まだ抜いていないライバルを追い越したら加点し、順位を取り直す。
    /// passed の掛け金で「1 台につき 1 回だけ加点」を守る（抜き返されても没収はしない）。
    def resolvePasses(w: World): World =
        let me = playerDistOf(w);
        let justPassed = r -> not r#passed and me >= r#progress;
        let updated = w#rivals |> List.map(r -> if (justPassed(r)) { passed = true | r } else r);
        let passes = w#rivals |> List.count(justPassed);
        { rivals = updated, score = w#score + passes * RulesDoc.rec(w#rules)#scorePerPass,
          rank = rankOf({ rivals = updated | w }) | w }

    /// いまの順位（1 = 先頭）。自機より前にいるライバルの数 + 1。
    pub def rankOf(w: World): Int32 =
        1 + (w#rivals |> List.count(r -> r#progress > playerDistOf(w)))

    /// ドリフトのまま草へ流れ落ちたら、そこでスピン（ドリフトの失敗には痛みがある）。
    def resolveDriftFall(w: World): World =
        if (w#drifting and not onRoad(w)) startSpin(w) else w

    // ── 演出の発生（タイヤ痕・煙。規則には絡まない） ──

    /// ドリフト煙を焚く間隔（秒）。
    def smokePeriod(): Float64 = 0.09

    /// ドリフト中の置き土産: タイヤ痕を刻み、smokePeriod 秒おきに白煙を焚く。
    def emitDriftTrail(dt: Float64, w: World): World =
        if (not w#drifting) { smokeClock = 0.0 | w }
        else {
            let clock = w#smokeClock + dt;
            let marked = { skids = pruneSkids(w#distance,
                { dist = playerDistOf(w), off = w#playerOff, turn = driftTurnOf(w) } :: w#skids) | w };
            if (clock >= smokePeriod())
                { smokeClock = clock - smokePeriod()
                | burstAt(w#fx#smoke,
                    { x = w#playerOff - w#steerDir * 5.0, y = playerDistOf(w) - carHitLen() * 0.5 }, marked) }
            else { smokeClock = clock | marked }
        }

    /// 車体の傾き（1 周 = 1.0 の turn）。ドリフトは深く、普段の操舵はわずかに、スピンは 2 回転。
    pub def driftTurnOf(w: World): Float64 =
        if (w#spinLeft > 0.0)
            (RulesDoc.rec(w#rules)#spinDuration - w#spinLeft) / RulesDoc.rec(w#rules)#spinDuration * 2.0
        else if (w#drifting) w#steerDir * 0.06
        else w#steerDir * 0.015

    /// 画面より後ろへ流れたタイヤ痕を捨てる（伸び続けるリストにしない）。
    def pruneSkids(distance: Float64, skids: List[Skid]): List[Skid] =
        skids |> List.filter(s -> s#dist > distance - 60.0) |> List.take(140)

    /// 粒の効果を 1 発焚く（at は x = 道の中心からの横ずれ px, y = 前進距離 px。View が毎フレーム投影する）。
    def burstAt(spec: FxDoc.Spec, at: Vec2.Vec2, w: World): World =
        { bursts = Fx.burst(spec, w#fxSeq, at, w#t) :: w#bursts, fxSeq = w#fxSeq + 1 | w }

    /// 残り時間のある効果（ニトロ・ブースト・スピン・押し合い）を冷ます。
    def coolTimers(dt: Float64, w: World): World =
        { nitroLeft = Float64.max(0.0, w#nitroLeft - dt),
          boostLeft = Float64.max(0.0, w#boostLeft - dt),
          spinLeft = Float64.max(0.0, w#spinLeft - dt),
          bumpLeft = Float64.max(0.0, w#bumpLeft - dt) | w }

    // ── 周回とゴール ──

    /// 走った距離から周回数を更新し、totalLaps 周に達したらゴール。
    /// 最下位なら Lose、それ以外は Win（1 位だけ finishBonus）。[遷移: Racing→Win/Lose]
    def checkLaps(w: World): World =
        let lapsDone = Num.floorInt(w#distance / lapLength(w#course));
        if (lapsDone < RulesDoc.rec(w#rules)#totalLaps) { lap = lapsDone | w }
        else if (w#rank >= startRank(w#rivalsCfg))
            { phase = Phase.Lose, lap = RulesDoc.rec(w#rules)#totalLaps | w }
        else
            { phase = Phase.Win, lap = RulesDoc.rec(w#rules)#totalLaps,
              score = w#score + (if (w#rank == 1) RulesDoc.rec(w#rules)#finishBonus else 0) | w }

    // ══════════════════════════════════════════════════════
    // Doc の差し替え（保存即反映）と 表示中の名乗り
    // ══════════════════════════════════════════════════════

    pub def withRules(rules: RulesDoc.Doc, w: World): World = { rules = rules | w }
    pub def withRivalsCfg(rivalsCfg: RivalsDoc.Doc, w: World): World = { rivalsCfg = rivalsCfg | w }
    pub def withTheme(theme: ThemeDoc.Doc, w: World): World = rebakeAtlas({ theme = theme | w })
    pub def withCourse(course: CourseDoc.Doc, w: World): World = { course = course | w }
    pub def withProps(props: PropsDoc.Doc, w: World): World = { props = props | w }
    pub def withPalette(palette: PaletteDoc.Doc, w: World): World = rebakeAtlas({ palette = palette | w })
    pub def withSprites(sprites: PxSpriteDoc.Doc, w: World): World = rebakeAtlas({ sprites = sprites | w })
    pub def withFx(fx: FxSpecs, w: World): World = { fx = fx | w }

    /// テーマ・色票・ドット絵のどれかが変わったらアトラスを生成し直して世代を進める。
    /// 世代の鍵（atlasKey）が変わらないと、App は古い画素のテクスチャを使い続ける。
    def rebakeAtlas(w: World): World =
        { atlas = PxSpriteAtlas.bake(w#sprites, PaletteDoc.carInk(w#palette, ThemeDoc.rec(w#theme)#player)),
          atlasGen = w#atlasGen + 1 | w }

    /// ドット絵アトラスの論理名（GL の TextureRegistry と描き出しの texturePath が同じ鍵で引く）。
    pub def atlasName(): String = "px"

    /// アトラスの世代鍵。App はこの鍵の変化で GPU へ上げ直す。
    pub def atlasKey(w: World): String = "gen${w#atlasGen}"

    /// 効果音のつまみ。走らせたまま効くのは鳴らす間隔だけで、音量・高さ・長さは
    /// 生成した WAV に入っている（make render-all で生成し直して起動し直すと届く）。
    pub def withSfxTune(sfxtune: SfxTuneDoc.Doc, w: World): World = { sfxtune = sfxtune | w }

    pub def spritePath(): String = "assets/race.sprite.json"
}
