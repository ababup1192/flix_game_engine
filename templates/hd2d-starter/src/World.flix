// World — 遊びの状態そのものと、次の状態を作る規則（すべて純粋）。
// 先頭をキーかスティックで動かし、通れないマスの四角とぶつけて壁に沿って滑らせる（CollisionGrid）。仲間は先頭の通った道（FollowTrail）をなぞる。
// カメラは横と奥を先頭へ合わせ（歩く向きへ先を見せる量は explore.json の aheadMeters）、高さは足元の高さを遅れて追う。
// Doc と組んだ町は Res が持ち、World は持たない（読む口は res を受ける）。
//
// ── 場面 ──
// 画面は Screen の enum で分け、その画面だけが持つ値は payload に入れる。今は Walk の 1 つだけ。
// 表紙・会話などを足すときは Screen に case を足し、step と View を match で分ける（手本は engine の templates/tidepool-starter）。
mod World {
    use fge::{Num}

    /// 終了の確認。Esc か窓の閉じるボタンで Asking（確認の窓を出し、隊列は止まる）、
    /// はいで Confirmed（Main の App.quitWhen がこれを見て閉じる）、いいえで Walking へ戻る。
    pub enum Quit with Eq, ToString {
        case Walking
        case Asking
        case Confirmed
    }

    /// マウスで押せる物（View が描く木に ZStack.hit で積み、Controls が SortingLayer.pickFrom で引く）。
    pub enum Press with Eq, ToString {
        case QuitYes   // 終了の確認の窓の中（Enter と同じ）
        case QuitNo    // 窓の外（Esc と同じ）
    }

    /// どの画面か。その画面だけが持つ値を payload に持つ。
    pub enum Screen {
        /// 町を歩き回っている。
        case Walk(Party)
    }

    /// カメラの遅れて追う物。ahead = 先頭から先へ見せる量（m・地図の座標）・height = 遅れて追う床の高さ（m）。
    pub type alias CameraLag = { ahead = (Float64, Float64), height = Float64 }

    /// 歩き回っている間の中身。leader = 先頭の足元（地図の座標）・facing = 先頭の向き・trail = 先頭の通った道・
    /// walkClock = 歩いている間だけ進む時計（歩きのコマ）・moving = このコマで先頭が動いたか・camera = カメラの遅れて追う物。
    pub type alias PartyRec = { leader = (Float64, Float64), facing = Facing.Dir, trail = FollowTrail.Trail, walkClock = Float64,
                                moving = Bool, camera = CameraLag }

    /// 歩き回っている間の中身。作るのは World の中（partyAt・mapPartyRec）だけ。読む口は partyOf・書く口は mapParty。
    enum PartyOf(PartyRec)

    pub type alias Party = PartyOf

    /// 遊びの状態。time = 積み上げた秒（小物のコマ・待機モーション）。time と quit はどの画面でも使うので、Screen の外に置く。
    pub type alias World = { time = Float64, screen = Screen, quit = Quit }

    /// ゲーム開始時の状態。先頭は explore.json の startCol・startRow のマスに startFace を向いて立つ。
    pub def initial(res: Res.Res): World =
        let e = Res.exploreOf(res);
        { time = 0.0, screen = Screen.Walk(partyAt(res, e#startCol, e#startRow, e#startFace)), quit = Quit.Walking }

    /// マス (c, r) の真ん中に face を向いて立ち、仲間がその後ろに並ぶ隊列。
    def partyAt(res: Res.Res, c: Int32, r: Int32, face: Facing.Dir): Party =
        let e = Res.exploreOf(res);
        let m = Res.mapOf(res);
        let at = TownMap.centerOf(m, c, r);
        let (fx, fy) = Facing.unitOf(face);
        PartyOf.PartyOf({ leader = at, facing = face,
                          trail = FollowTrail.lineBehind(at, (0.0 - fx, 0.0 - fy), e#spacing, List.length(e#party)),
                          walkClock = 0.0, moving = false, camera = { ahead = (0.0, 0.0), height = TownMap.topAt(m, c, r) } })

    def partyRec(p: Party): PartyRec = match p {
        case PartyOf.PartyOf(rec) => rec
    }

    /// 歩き回っている間の中身（Walk の外は None）。
    pub def partyOf(w: World): Option[PartyRec] = match w#screen {
        case Screen.Walk(p) => Some(partyRec(p))
    }

    /// 歩き回っている間の中身を f で替える（Walk の外はそのまま）。
    def mapParty(f: PartyRec -> PartyRec, w: World): World = match w#screen {
        case Screen.Walk(p) => { screen = Screen.Walk(PartyOf.PartyOf(f(partyRec(p)))) | w }
    }

    /// 先頭をマス (c, r) に face を向けて立たせ直す（始まりとギャラリーの場面）。
    pub def placeLeader(res: Res.Res, c: Int32, r: Int32, face: Facing.Dir, w: World): World =
        { screen = Screen.Walk(partyAt(res, c, r, face)) | w }

    /// 先頭の立つマス（Walk の外は None）。
    pub def leaderCell(res: Res.Res, w: World): Option[(Int32, Int32)] =
        partyOf(w) |> Option.map(p -> CollisionGrid.cellAt(res#grid, fst(p#leader), snd(p#leader)))

    /// 入力 input（長さ 0〜1・右が +x・上（北）が +y）と経過時間 dt から次の状態を作る。
    /// 終了の確認の窓が出ている間は動かない（時刻だけ進むので小物は動き続ける）。
    pub def step(res: Res.Res, input: (Float64, Float64), dt: Float64, w: World): World =
        let advanced = { time = w#time + dt | w };
        if (w#quit != Quit.Walking) mapParty(p -> stand(res, dt, p), advanced)
        else mapParty(p -> walk(res, input, dt, p), advanced)

    def stand(res: Res.Res, dt: Float64, p: PartyRec): PartyRec = walk(res, (0.0, 0.0), dt, p)

    /// 先頭を動かして壁で滑らせ、道を延ばし、カメラを近づける。
    def walk(res: Res.Res, input: (Float64, Float64), dt: Float64, p: PartyRec): PartyRec =
        let e = Res.exploreOf(res);
        let (ix, iy) = input;
        let (x0, y0) = p#leader;
        let (x1, y1) = CollisionGrid.moveAndSlide(res#grid, e#radius, p#leader, (ix * e#speed * dt, iy * e#speed * dt));
        let dx = x1 - x0;
        let dy = y1 - y0;
        let moved = dx * dx + dy * dy > 0.0000000001;
        let pushing = ix * ix + iy * iy > 0.04;
        let keep = e#spacing * Int32.toFloat64(Int32.max(1, List.length(e#party) - 1)) + 0.5;
        let feet = TownMap.groundZAt(Res.mapOf(res), x1, y1);
        { leader = (x1, y1),
          facing = if (moved) Facing.nearestOf((dx, dy)) else if (pushing) Facing.nearestOf(input) else p#facing,
          trail = if (moved) FollowTrail.push((x1, y1), keep, p#trail) else p#trail,
          walkClock = if (moved) p#walkClock + dt else p#walkClock, moving = moved,
          camera = { ahead = TownCamera.lookAhead(e#aheadMeters, e#aheadRate, e#speed, (dx, dy), dt, p#camera#ahead),
                     height = p#camera#height + (feet - p#camera#height) * TownCamera.followRate(e#heightLagK, dt) } }

    /// i 番目（0 = 先頭）の足元と向き。仲間は道を間 × i だけ戻った所で、そこで動いていた向き（止まった時も最後の向き）。
    pub def memberAt(res: Res.Res, p: PartyRec, i: Int32): ((Float64, Float64), Facing.Dir) =
        if (i == 0) (p#leader, p#facing)
        else {
            let (at, v) = FollowTrail.pointBack(p#trail, Res.exploreOf(res)#spacing * Int32.toFloat64(i));
            (at, if (fst(v) == 0.0 and snd(v) == 0.0) p#facing else Facing.nearestOf(v))
        }

    /// Doc を読み直して格子が替わった後に、先頭を通れるマスへ収める（今のマスが塞がれたら近い通れるマスへ・無ければ立ち始めへ）。
    pub def settle(res: Res.Res, w: World): World =
        match leaderCell(res, w) {
            case None         => w
            case Some(origin) =>
                if (not CollisionGrid.isBlockedFrom(res#grid, origin, origin)) w
                else {
                    let e = Res.exploreOf(res);
                    let face = partyOf(w) |> Option.map(p -> p#facing) |> Option.getWithDefault(e#startFace);
                    let (c, r) = nearestOpen(res, origin) |> Option.getWithDefault((e#startCol, e#startRow));
                    placeLeader(res, c, r, face, w)
                }
        }

    /// origin に近い通れるマス（一辺 2k + 1 の四角の縁を k = 1..8 で広げて探す）。
    def nearestOpen(res: Res.Res, origin: (Int32, Int32)): Option[(Int32, Int32)] =
        let (c0, r0) = origin;
        let ring = (k: Int32) -> List.range(r0 - k, r0 + k + 1) |> List.flatMap(r -> List.range(c0 - k, c0 + k + 1) |> List.map(c -> (c, r)))
            |> List.filter(cr -> Int32.max(Int32.abs(fst(cr) - c0), Int32.abs(snd(cr) - r0)) == k);
        List.range(1, 9) |> List.findMap(k -> ring(k) |> List.find(cr -> not CollisionGrid.isBlockedFrom(res#grid, cr, cr)))

    /// 目の位置（先頭 + 先へ見せる量を、足元が画面の feetV に来る所から引いて見る）。
    pub def eyeOf(res: Res.Res, p: PartyRec): TownCamera.Eye =
        let pull = Res.exploreOf(res)#walkZoom;
        let (lx, ly) = p#leader;
        let (ax, ay) = p#camera#ahead;
        let snap = (v: Float64) -> if (Res.lookOf(res)#snapToTexels) TownCamera.snapToTexel(v) else v;
        { x = snap(lx + ax), z = snap(ly + ay - res#feetDepth * pull),
          height = res#groundZ + res#eyeRise * pull + (p#camera#height - res#groundZ) }

    /// ピントの合う奥行き（目から先頭の足元まで）。
    pub def focusOf(res: Res.Res, p: PartyRec): Float64 =
        let eye = eyeOf(res, p);
        let (lx, ly) = p#leader;
        let z = TownMap.groundZAt(Res.mapOf(res), lx, ly);
        Num.sqrt((ly - eye#z) * (ly - eye#z) + (eye#height - z) * (eye#height - z))

    // ── 終了の確認 ──

    /// Esc・閉じるボタン: 歩いている間なら確認の窓を出す。
    pub def askQuit(w: World): World =
        if (w#quit == Quit.Walking) { quit = Quit.Asking | w } else w

    /// 確認の窓への答え（yes なら終わる・no なら歩きへ戻る）。窓が出ていないときは何もしない。
    pub def answerQuit(yes: Bool, w: World): World =
        if (w#quit != Quit.Asking) w
        else if (yes) { quit = Quit.Confirmed | w }
        else { quit = Quit.Walking | w }

    pub def isAskingQuit(w: World): Bool = w#quit == Quit.Asking

    pub def isQuitting(w: World): Bool = w#quit == Quit.Confirmed
}
