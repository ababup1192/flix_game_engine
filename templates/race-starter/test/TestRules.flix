// ルール・進行・収支だけをテストする（方針どおり）。演出（タイヤ痕・煙・傾き・粒）は
// スナップショットと目視の仕事なのでテストしない。ただし当たり（路面・障害物・スリップの範囲）はルールなので残す。
// 期待値はリテラルでなく Doc（RulesDoc.defaults / RivalsDoc.defaults / CourseDoc.defaults）から導く —
// バランス調整でテストが壊れないように。
//
// step の中の順番（World.tickRacing の pipe）に依る所は各テストのコメントに書く。
// 特に coolTimers は発動と同じフレームで dt ぶん削るので、タイマーの期待値は「設定値 - dt」。
mod TestRules {

    // ══════════════════════════════════════════════════════
    // 場面を組む土台
    // ══════════════════════════════════════════════════════

    /// 既定の Doc の束（World.initial と描き出しが読むのと同じ形）。
    def docs(): World.Docs =
        { rules = RulesDoc.defaults(), rivalsCfg = RivalsDoc.defaults(), theme = ThemeDoc.defaults(),
          course = CourseDoc.defaults(), props = PropsDoc.defaults(), palette = PaletteDoc.defaults(), sprites = PxSpriteDoc.empty(),
          fx = { smoke = FxDoc.empty(), spark = FxDoc.empty(), flame = FxDoc.empty(),
                 shock = FxDoc.empty(), crash = FxDoc.empty() },
          sfxtune = SfxTuneDoc.defaults() }

    /// Racing にした World（進行・当たり・収支のテスト用）。
    def racing(): World.World =
        { phase = World.Phase.Racing | World.initial(docs()) }

    /// 何も押していない 1 フレームの入力。必要な所だけレコード更新で変える。
    def idle(): World.Inputs =
        { dir = 0.0, brake = false, driftHeld = false, nitroTap = false }

    /// ライバル 1 台。性格はテストの邪魔をしない値（corner = 1.0 = コーナー減速なし・レーン中央好み）。
    def rivalAt(progress: Float64, off: Float64, baseSpeed: Float64): World.Rival =
        { progress = progress, off = off, baseSpeed = baseSpeed, corner = 1.0, laneBias = 0.0, passed = false }

    // ══════════════════════════════════════════════════════
    // コースから行を探す土台（行番号・横位置をテストへ直書きしない）
    // ══════════════════════════════════════════════════════

    /// 置き場の表を先頭の行から見て、その種類の物が最初に置かれている通し行と、その横ずれ。
    /// 見つからない（= 置き場の作りが変わって前提が崩れた）ときは
    /// 来てはいけない分岐として落ちる。
    def firstPropAt(w: World.World, kind: PropsDoc.Kind): { row = Int32, off = Float64 } =
        match List.range(0, CourseDoc.rowCount(w#course))
                |> List.filterMap(n ->
                    World.propCellsAt(n, w) |> List.filter(c -> c#kind == kind) |> List.head
                        |> Option.map(c ->
                            { row = n, off = PropsDoc.laneOff(c#lane, World.halfWidthAt(n, w#course)) }))
                |> List.head {
            case Some(found) => found
            case None        => bug!("props table has no such prop")
        }

    /// 全面が路面の平らな 2 行コース（置き場も空）。当たりや坂を混ぜたくないテストの土台。
    def flatCourse(): CourseDoc.Doc =
        CourseDoc.Doc.Doc({ version = 1,
          sections = { len = 2, curve = 0.0, hill = 0.0, width = 300.0, rail = "none",
                       note = "" } :: Nil })

    /// 右へ曲がり続ける全面路面の 2 行コース（置き場は空）。
    /// 「外側 = 左（負）」へ押される・流れる向きを見るテストの土台。
    def rightCurveCourse(): CourseDoc.Doc =
        CourseDoc.Doc.Doc({ version = 1,
          sections = { len = 2, curve = 6.0, hill = 0.0, width = 300.0, rail = "none",
                       note = "" } :: Nil })

    /// 通し行 n をまたぐ直前の distance（1 フレームで必ず n をまたいで入る位置）。
    /// playerRowOf(d) = floor((d + playerAheadPx) / rowPitch) の境界のすぐ手前に置く。
    def justBeforeRow(n: Int32): Float64 =
        Int32.toFloat64(n) * World.rowPitch() - World.playerAheadPx() - 1.0

    // ══════════════════════════════════════════════════════
    // 柱 1: カーブの導出（区間の curve = 急さ。行ごとの表を別に持たない）
    // ══════════════════════════════════════════════════════

    @Test
    def testCurveComesFromTheSectionTable(): Unit \ Assert =
        // 既定コースはスタート直線から始まり、そのあと最初の曲がる区間が来る。
        // 行 0 は直線なので 0、最初に曲がる行の値はその区間の curve と一致する —
        // 行番号も期待値も CourseDoc.defaults() から導く（コースを書き換えても壊れない）。
        let c = CourseDoc.defaults();
        let n = match List.range(0, CourseDoc.rowCount(c))
                |> List.filter(row -> World.curveAt(row, c) != 0.0) |> List.head {
            case Some(row) => row
            case None      => bug!("course has no curve")
        };
        Assert.assertEq(
            expected = (0.0, (CourseDoc.sectionAt(n, c))#sec#curve),
            (World.curveAt(0, c), World.curveAt(n, c)))

    // ══════════════════════════════════════════════════════
    // 柱 1: ハンドルとグリップ
    // ══════════════════════════════════════════════════════

    @Test
    def testSteerOnStraightMovesExactly(): Unit \ Assert =
        // 直線（distance = 0 で自機はスタート直線の行に乗る）では、→ 入力どおり
        // steerSpeed * dt だけ右へ動く（カーブの横押しゼロ）。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let w = racing();
        let dt = 0.1;
        let after = World.step({ dir = 1.0 | idle() }, dt, w);
        Assert.assertEq(expected = w#playerOff + d#steerSpeed * dt, after#playerOff)

    @Test
    def testGripSpeedFollowsCurve(): Unit \ Assert =
        // gripSpeed 以下ならカーブでも道に付いていく = 道の中心からの横ずれは増えない。
        // distance = 70 で自機は最初の曲がる区間（通し行 3）に乗る。速度を gripSpeed に
        // 置いて 1 フレーム → 超過ゼロなので横ずれは 0 のまま（曲がりは道の側が引き受ける）。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let c = CourseDoc.defaults();
        let dt = 0.1;
        let w = { distance = 70.0, speed = d#gripSpeed | racing() };
        let after = World.step(idle(), dt, w);
        Assert.assertEq(
            expected = (true, w#playerOff),
            (World.curveAt(World.playerRowOf(w#distance), c) != 0.0, after#playerOff))

    @Test
    def testCurveExcessPushesOutward(): Unit \ Assert =
        // gripSpeed を超えて右カーブへ入ると、カーブの外側（左 = 負）へ押し出され、
        // 超過を 2 倍にすると押しも強くなる。超過は横押し率が 1.0 で頭打ちになる手前
        // （forwardSpeed / curvePush 未満）に収めて、飽和で差が消えないようにする。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let dt = 0.05;
        let w = { course = rightCurveCourse(), rivals = Nil | racing() };
        let sped = ex -> World.step(idle(), dt, { speed = d#gripSpeed + ex | w });
        let small = sped(d#forwardSpeed / d#curvePush * 0.3);
        let big = sped(d#forwardSpeed / d#curvePush * 0.6);
        Assert.assertEq(
            expected = (true, true),
            (small#playerOff < 0.0, big#playerOff < small#playerOff))

    // ══════════════════════════════════════════════════════
    // 柱 1: ドリフトの成立とゲージ
    // ══════════════════════════════════════════════════════

    @Test
    def testDriftNeedsHoldAndSteerAndNoSpin(): Unit \ Assert =
        // ドリフトの成立は「X を押しながらハンドルを切る」ときだけ。
        // dir = 0 では成立しない。スピン中も成立しない。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let drift = { dir = 1.0, driftHeld = true | idle() };
        let held = World.step(drift, 0.05, racing());
        let noDir = World.step({ driftHeld = true | idle() }, 0.05, racing());
        let spinning = World.step(drift, 0.05, { spinLeft = d#spinDuration | racing() });
        Assert.assertEq(
            expected = (true, false, false),
            (held#drifting, noDir#drifting, spinning#drifting))

    @Test
    def testDriftChargesNitroPerSecond(): Unit \ Assert =
        // ドリフト 1 秒でゲージが nitroChargeDrift ぶん貯まる（dt 積分は単純加算）。
        // 全面が路面のコースで右 0.5 秒 → 左 0.5 秒と切り返して道の真ん中へ戻す —
        // 片側へ 1 秒切り続けると草へ流れ落ちてスピン（ドリフト失敗）が混ざる。
        // スリップ加算も混ぜない（rivals = Nil）。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let w = { course = flatCourse(), rivals = Nil | racing() };
        let half = World.step({ dir = 1.0, driftHeld = true | idle() }, 0.5, w);
        let after = World.step({ dir = 0.0 - 1.0, driftHeld = true | idle() }, 0.5, half);
        Assert.assertEq(expected = d#nitroChargeDrift, after#nitro)

    @Test
    def testDriftSlideFlowsTowardOutside(): Unit \ Assert =
        // 右カーブでのドリフトは、舵の移動（steerSpeed × driftTurnBoost）に加えて
        // 外側（左 = 負）へ driftSlide * dt だけ流れ続ける（速度の超過とは無関係の一定量）。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let dt = 0.05;
        let w = { course = rightCurveCourse(), rivals = Nil | racing() };
        let after = World.step({ dir = 1.0, driftHeld = true | idle() }, dt, w);
        Assert.assertEq(
            expected = d#steerSpeed * d#driftTurnBoost * dt - d#driftSlide * dt,
            after#playerOff)

    @Test
    def testDriftFallOntoGrassStartsSpin(): Unit \ Assert =
        // ドリフトのまま草（道の外）にいると、そのフレームでスピンが始まりドリフトは解ける
        // （coolTimers が同フレームで dt を削るので spinLeft = spinDuration - dt）。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let dt = 0.05;
        let half = World.halfWidthAt(0, flatCourse());
        let w = { course = flatCourse(), playerOff = half + 20.0, rivals = Nil | racing() };
        let after = World.step({ dir = 1.0, driftHeld = true | idle() }, dt, w);
        Assert.assertEq(
            expected = (d#spinDuration - dt, false),
            (after#spinLeft, after#drifting))

    // ══════════════════════════════════════════════════════
    // 柱 3: スリップストリーム（前走車の真後ろの範囲）
    // ══════════════════════════════════════════════════════

    @Test
    def testSlipActiveOnlyBehindWithinRange(): Unit \ Assert =
        // 前走車の真後ろ（slipRange 内・横ずれ slipWidth/2 以内）で true、
        // 同じ距離でも横へ slipWidth ぶん外すと false。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let w = racing();
        let me = World.playerDistOf(w);
        let inRange = { rivals = rivalAt(me + d#slipRange * 0.5, w#playerOff, 0.0) :: Nil | w };
        let offSide = { rivals = rivalAt(me + d#slipRange * 0.5, w#playerOff + d#slipWidth, 0.0) :: Nil | w };
        Assert.assertEq(
            expected = (true, false),
            (World.slipActive(inRange), World.slipActive(offSide)))

    // ══════════════════════════════════════════════════════
    // 柱 3: ニトロの発動と速度
    // ══════════════════════════════════════════════════════

    @Test
    def testNitroFiresOnlyWhenFull(): Unit \ Assert =
        // 満タン（1.0）で Z → nitroLeft = nitroDuration が入りゲージは 0 へ。
        // 未満タン（0.5）では発動せず、ゲージもそのまま。
        // coolTimers が同じフレームで dt を削るので nitroLeft の期待値は nitroDuration - dt。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let dt = 0.1;
        let tap = { nitroTap = true | idle() };
        let full = World.step(tap, dt, { nitro = 1.0, rivals = Nil | racing() });
        let low = World.step(tap, dt, { nitro = 0.5, rivals = Nil | racing() });
        Assert.assertEq(
            expected = (d#nitroDuration - dt, 0.0, 0.0, 0.5),
            (full#nitroLeft, full#nitro, low#nitroLeft, low#nitro))

    @Test
    def testNitroMultipliesForwardSpeed(): Unit \ Assert =
        // ニトロ発動中の前進速度 = forwardSpeed * nitroBoost（直線・路上・他の倍率なし）。
        // speedOf は非公開なので step 後の w#speed で観測する。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let w = { nitroLeft = d#nitroDuration, rivals = Nil | racing() };
        let after = World.step(idle(), 0.1, w);
        Assert.assertEq(expected = d#forwardSpeed * d#nitroBoost, after#speed)

    // ══════════════════════════════════════════════════════
    // 柱 4: スピン（操作不能 + 時間で回復）
    // ══════════════════════════════════════════════════════

    @Test
    def testSpinLocksSteeringAndCoolsDown(): Unit \ Assert =
        // スピン中は舵が効かない（横ずれがまったく動かない）。残り時間は dt ずつ減り、
        // spinDuration ぶん経てば 0 に戻る（操作が返ってくる）。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let w = { spinLeft = d#spinDuration | racing() };
        let dt = 0.1;
        let mid = World.step({ dir = 1.0 | idle() }, dt, w);
        let done = World.step({ dir = 1.0 | idle() }, d#spinDuration, w);
        Assert.assertEq(
            expected = (w#playerOff, d#spinDuration - dt, 0.0),
            (mid#playerOff, mid#spinLeft, done#spinLeft))

    // ══════════════════════════════════════════════════════
    // 柱 4: 押し合い（車どうしの接触は横へ弾く・スピンさせない）
    // ══════════════════════════════════════════════════════

    /// 真横 5px にライバルが並んで触れている 1 フレーム前（自機は直線・舵は中立）。
    /// baseSpeed = 0 にしてライバルの前進を止め、1 フレームのあいだ当たり判定の区間から出ないようにする。
    def sideBySide(): World.World =
        let w = racing();
        { rivals = rivalAt(World.playerDistOf(w), w#playerOff - 5.0, 0.0) :: Nil | w }

    @Test
    def testRivalContactPushesPlayerSideways(): Unit \ Assert =
        // 左から接触したライバルに押されて、自機は右へ bumpPush * dt だけずれる。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let dt = 0.01;
        let w = sideBySide();
        let after = World.step(idle(), dt, w);
        Assert.assertEq(expected = w#playerOff + d#bumpPush * dt, after#playerOff)

    @Test
    def testRivalContactDoesNotSpin(): Unit \ Assert =
        // 接触してもスピンは始まらない（スピンは障害物の直撃とドリフト中の草落ちだけ）。
        let after = World.step(idle(), 0.01, sideBySide());
        Assert.assertEq(expected = 0.0, after#spinLeft)

    // ══════════════════════════════════════════════════════
    // 柱 4: 障害物（直撃 = スピン / すれすれ = ゲージ加算）
    // ══════════════════════════════════════════════════════

    @Test
    def testObstacleHitStartsSpin(): Unit \ Assert =
        // 既定コースで最初に X（障害物）がある行とその列を CourseDoc から探し、
        // その行をまたぐ直前の distance に立つ（justBeforeRow で 1 フレーム必ずまたぐ位置へ）。
        // X の列中心に自機を合わせて直撃 → スピン開始（coolTimers 後 = spinDuration - dt）。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let dt = 0.1;
        let cone = firstPropAt(racing(), PropsDoc.Kind.Cone);
        let w = { distance = justBeforeRow(cone#row), playerOff = cone#off, rivals = Nil | racing() };
        let after = World.step(idle(), dt, w);
        Assert.assertEq(expected = d#spinDuration - dt, after#spinLeft)

    @Test
    def testObstacleNearMissChargesNitro(): Unit \ Assert =
        // 同じく最初の X から「車の当たり半径 + nearMissDist の半分」だけ横へ外すと、
        // 当たらず（spinLeft = 0 のまま）にすれすれ扱いでゲージが nitroChargeNearMiss 増える。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let cone = firstPropAt(racing(), PropsDoc.Kind.Cone);
        let nearOff = cone#off + World.coneHitR() + d#nearMissDist * 0.5;
        let w = { distance = justBeforeRow(cone#row), playerOff = nearOff, rivals = Nil | racing() };
        let after = World.step(idle(), 0.1, w);
        Assert.assertEq(
            expected = (0.0, d#nitroChargeNearMiss),
            (after#spinLeft, after#nitro))

    @Test
    def testSpinDrainsGaugeAndStopsNitro(): Unit \ Assert =
        // 直撃スピンの瞬間、ゲージは spinNitroLoss の割合を失い、発動中のニトロも打ち切られる。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let cone = firstPropAt(racing(), PropsDoc.Kind.Cone);
        let w = { distance = justBeforeRow(cone#row), playerOff = cone#off,
                  nitro = 0.8, nitroLeft = d#nitroDuration, rivals = Nil | racing() };
        let after = World.step(idle(), 0.1, w);
        Assert.assertEq(
            expected = (0.8 * (1.0 - d#spinNitroLoss), 0.0),
            (after#nitro, after#nitroLeft))

    // ══════════════════════════════════════════════════════
    // 柱 4: 土管ゲート（隙間だけが通れる・両側すれすれで 2 回貯まる）
    // ══════════════════════════════════════════════════════

    @Test
    def testGateGapIsTheOnlyWayThrough(): Unit \ Assert =
        // 隙間の真ん中を通れば無傷、そこから 2 レーンずらすと土管に刺さってスピン。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let dt = 0.1;
        let w0 = racing();
        let gate = firstPropAt(w0, PropsDoc.Kind.Gate);
        let laneW = 2.0 * World.halfWidthAt(gate#row, w0#course)
            / Int32.toFloat64(PropsDoc.lanes());
        let atOff = off -> World.step(idle(), dt,
            { distance = justBeforeRow(gate#row), playerOff = off, rivals = Nil | w0 });
        Assert.assertEq(
            expected = (0.0, d#spinDuration - dt),
            ((atOff(gate#off))#spinLeft, (atOff(gate#off + laneW * 2.0))#spinLeft))

    @Test
    def testGateGapChargesFromBothPipes(): Unit \ Assert =
        // 隙間を抜けると左右 2 本の土管それぞれにすれすれが立ち、ゲージが 2 回ぶん貯まる。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let w0 = racing();
        let gate = firstPropAt(w0, PropsDoc.Kind.Gate);
        let after = World.step(idle(), 0.1,
            { distance = justBeforeRow(gate#row), playerOff = gate#off, rivals = Nil | w0 });
        Assert.assertEq(expected = d#nitroChargeNearMiss * 2.0, after#nitro)

    // ══════════════════════════════════════════════════════
    // 柱 4: 振り子バー（閉じた式・乱数も状態も無い）
    // ══════════════════════════════════════════════════════

    @Test
    def testBarSwingsOnAClosedFormLoop(): Unit \ Assert =
        // バーの位置は時刻と行番号だけで決まる。1 往復ぶん時計を進めると同じ場所へ戻り、
        // 半分だけ進めると逆側にいる（毎周同じリズム = 覚えて攻略できる）。
        let w = racing();
        let at = tt -> World.barOffAt(3, { t = tt | w });
        let a = at(0.3);
        Assert.assertEq(
            expected = (true, true),
            (Float64.abs(at(0.3 + PropsDoc.rec(w#props)#barPeriod) - a) < 0.0001,
             Float64.abs(at(0.3 + PropsDoc.rec(w#props)#barPeriod / 2.0) + a) < 0.0001))

    // ══════════════════════════════════════════════════════
    // 柱 4: ガードレール（擦っても壊れない・道の端で止まる）
    // ══════════════════════════════════════════════════════

    /// ガードレールが立っていて、立ち物の無い最初の通し行。
    def firstRailRow(w: World.World): { row = Int32, side = Float64 } =
        match List.range(0, CourseDoc.rowCount(w#course))
                |> List.filter(n -> World.railSideAt(n, w) != 0.0
                    and List.isEmpty(World.blockersAt(n, w)))
                |> List.head {
            case Some(n) => { row = n, side = World.railSideAt(n, w) }
            case None    => bug!("course has no guardrail")
        }

    @Test
    def testGuardrailHoldsTheCarWithoutSpinning(): Unit \ Assert =
        // 壁のある側へ切り続けても、道の端で止まってスピンはしない（= 擦っている状態）。
        let w0 = racing();
        let r = firstRailRow(w0);
        let half = World.halfWidthAt(r#row, w0#course);
        let w = { distance = Int32.toFloat64(r#row) * World.rowPitch()
                      - World.playerAheadPx() + 4.0,
                  playerOff = r#side * (half - 1.0), rivals = Nil | w0 };
        let after = World.step({ dir = r#side | idle() }, 0.1, w);
        Assert.assertEq(
            expected = (r#side * half, 0.0, true),
            (after#playerOff, after#spinLeft, World.scraping(after)))

    @Test
    def testGuardrailScrapeChargesNitro(): Unit \ Assert =
        // 擦っている間はゲージが nitroChargeRail ぶん/秒 貯まる（遅い代わりに見返りはある）。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let w0 = racing();
        let r = firstRailRow(w0);
        let half = World.halfWidthAt(r#row, w0#course);
        let dt = 0.2;
        let w = { distance = Int32.toFloat64(r#row) * World.rowPitch()
                      - World.playerAheadPx() + 4.0,
                  playerOff = r#side * half, rivals = Nil | w0 };
        let after = World.step(idle(), dt, w);
        Assert.assertEq(expected = d#nitroChargeRail * dt, after#nitro)

    // ══════════════════════════════════════════════════════
    // 坂（登りで遅く・下りで速く）
    // ══════════════════════════════════════════════════════

    /// 勾配 grade の平らでない直線が延々続くコース（当たりも曲がりも混ぜない）。
    def hillCourse(grade: Float64): CourseDoc.Doc =
        CourseDoc.Doc.Doc({ version = 1,
          sections = { len = 2, curve = 0.0, hill = grade, width = 300.0, rail = "none",
                       note = "" } :: Nil })

    @Test
    def testHillChangesForwardSpeed(): Unit \ Assert =
        // 同じ直線でも、勾配 1.0 の登りでは hillSpeedGain ぶん遅く、下りでは同じだけ速い。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let speedOn = c -> (World.step(idle(), 0.1, { course = c, rivals = Nil | racing() }))#speed;
        Assert.assertEq(
            expected = (d#forwardSpeed * (1.0 - d#hillSpeedGain),
                        d#forwardSpeed * (1.0 + d#hillSpeedGain)),
            (speedOn(hillCourse(1.0)), speedOn(hillCourse(0.0 - 1.0))))

    // ══════════════════════════════════════════════════════
    // 柱 5: アイテム（取った瞬間の順位で効果が決まる・二重取得なし）
    // ══════════════════════════════════════════════════════

    /// 既定コースで最初にアイテムが置かれている行と横ずれ。beforeItem と
    /// testItemNotTakenTwiceOnSameRow の両方が同じ行を指すよう、ここで 1 か所に決める。
    def firstItem(): { row = Int32, off = Float64 } =
        firstPropAt(racing(), PropsDoc.Kind.Item)

    /// 最初のアイテムの手前（1 フレームで必ずまたいで拾う位置）に立つ。順位は rank を直に置いて作る。
    def beforeItem(rank: Int32): World.World =
        { distance = justBeforeRow(firstItem()#row), playerOff = firstItem()#off,
          rank = rank, rivals = Nil | racing() }

    @Test
    def testItemEffectDependsOnRank(): Unit \ Assert =
        // 1 位 = スコアだけ / 2 位 = ゲージ / 最下位（4 位）= 即ブースト。
        // boostLeft は coolTimers が同フレームで dt を削るので itemBoostDuration - dt。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let dt = 0.1;
        let first = World.step(idle(), dt, beforeItem(1));
        let second = World.step(idle(), dt, beforeItem(2));
        let last = World.step(idle(), dt, beforeItem(4));
        Assert.assertEq(
            expected = (d#itemScoreBonus, d#itemNitroCharge, d#itemBoostDuration - dt),
            (first#score, second#nitro, last#boostLeft))

    @Test
    def testItemNotTakenTwiceOnSameRow(): Unit \ Assert =
        // 同じ通し行はもう一度またいでも二重取得しない（taken の掛け金）。
        // 一度拾ったあと distance を行の手前へ戻してもう 1 フレーム → スコアは 1 回ぶんのまま。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let once = World.step(idle(), 0.1, beforeItem(1));
        let again = World.step(idle(), 0.1, { distance = justBeforeRow(firstItem()#row) | once });
        Assert.assertEq(expected = d#itemScoreBonus, again#score)

    // ══════════════════════════════════════════════════════
    // 柱 2: ラバーバンド（離されると速く・千切ると遅く）
    // ══════════════════════════════════════════════════════

    @Test
    def testRubberBandAdjustsRivalSpeed(): Unit \ Assert =
        // 自機から rubberRange ぶん後ろのライバルは 1 フレームの伸びが baseSpeed * dt より大きく、
        // 同じだけ前のライバルは小さい（corner = 1.0 でコーナー減速は混ぜない）。
        let cfg = RivalsDoc.rec(RivalsDoc.defaults());
        let dt = 0.1;
        let baseSpeed = 100.0;
        let w = racing();
        let me = World.playerDistOf(w);
        let behindStart = me - cfg#rubberRange;
        let aheadStart = me + cfg#rubberRange;
        let afterB = World.step(idle(), dt, { rivals = rivalAt(behindStart, 200.0, baseSpeed) :: Nil | w });
        let afterA = World.step(idle(), dt, { rivals = rivalAt(aheadStart, 200.0, baseSpeed) :: Nil | w });
        let gainB = afterB#rivals |> List.head |> Option.map(r -> r#progress - behindStart)
            |> Option.getWithDefault(0.0);
        let gainA = afterA#rivals |> List.head |> Option.map(r -> r#progress - aheadStart)
            |> Option.getWithDefault(0.0);
        Assert.assertEq(
            expected = (true, true),
            (gainB > baseSpeed * dt, gainA < baseSpeed * dt))

    // ══════════════════════════════════════════════════════
    // 追い抜き（加点・順位・二重加点なし）
    // ══════════════════════════════════════════════════════

    @Test
    def testPassingRivalScoresAndRanksUp(): Unit \ Assert =
        // まだ抜いていないライバルを追い越すと scorePerPass が入り、順位が 1 位になり、
        // passed の掛け金が立つ。横は離して接触スピンを混ぜない（当たり幅の外）。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let w = { distance = 100.0, rivals = rivalAt(150.0, 200.0, 0.0) :: Nil | racing() };
        let after = World.step(idle(), 0.01, w);
        let allPassed = after#rivals |> List.forAll(r -> r#passed);
        Assert.assertEq(
            expected = (d#scorePerPass, 1, true),
            (after#score, after#rank, allPassed))

    @Test
    def testPassedRivalDoesNotScoreTwice(): Unit \ Assert =
        // 既に抜いた（passed = true）ライバルは、また加点しない。
        let w = { distance = 100.0,
                  rivals = { passed = true | rivalAt(50.0, 200.0, 0.0) } :: Nil | racing() };
        let after = World.step(idle(), 0.01, w);
        Assert.assertEq(expected = 0, after#score)

    // ══════════════════════════════════════════════════════
    // 周回とゴール（totalLaps 完走 → 順位で Win / Lose・1 位だけ finishBonus）
    // ══════════════════════════════════════════════════════

    @Test
    def testFinishOutcomeDependsOnRank(): Unit \ Assert =
        // totalLaps ぶん走り切ったフレームに: 1 位 = Win + finishBonus / 2 位 = Win（ボーナスなし）/
        // 最下位（既定 3 台 + 自機 = 4 位）= Lose。ライバルは接触もスリップも起きない距離に置く。
        let d = RulesDoc.rec(RulesDoc.defaults());
        let dist = World.lapLength(CourseDoc.defaults()) * Int32.toFloat64(d#totalLaps) + 10.0;
        let me = dist + World.playerAheadPx();
        let first = World.step(idle(), 0.001, { distance = dist, rivals = Nil | racing() });
        let second = World.step(idle(), 0.001,
            { distance = dist, rivals = rivalAt(me + 100.0, 200.0, 0.0) :: Nil | racing() });
        let last = World.step(idle(), 0.001,
            { distance = dist,
              rivals = rivalAt(me + 100.0, 200.0, 0.0)
                    :: rivalAt(me + 110.0, 200.0, 0.0)
                    :: rivalAt(me + 120.0, 200.0, 0.0) :: Nil | racing() });
        Assert.assertEq(
            expected = (World.Phase.Win, d#finishBonus, World.Phase.Win, 0, World.Phase.Lose),
            (first#phase, first#score, second#phase, second#score, last#phase))

    // ══════════════════════════════════════════════════════
    // 場面の切り替え（confirm の意味は場面で変わる）
    // ══════════════════════════════════════════════════════

    @Test
    def testConfirmTransitions(): Unit \ Assert =
        // Title → Racing / Racing → そのまま / Win → Title / Lose → Title。
        let title = World.initial(docs());
        let win = { phase = World.Phase.Win | racing() };
        let lose = { phase = World.Phase.Lose | racing() };
        Assert.assertEq(
            expected = (World.Phase.Racing, World.Phase.Racing, World.Phase.Title, World.Phase.Title),
            (World.confirm(title)#phase, World.confirm(racing())#phase,
             World.confirm(win)#phase, World.confirm(lose)#phase))

    // ══════════════════════════════════════════════════════
    // 路面判定（草に出たかどうか）
    // ══════════════════════════════════════════════════════

    @Test
    def testOnRoadByColumn(): Unit \ Assert =
        // 道の中心（初期位置 = 横ずれ 0）は路面、道幅の半分より外へ出れば草。
        let w = racing();
        let half = World.halfWidthAt(World.playerRowOf(w#distance), w#course);
        Assert.assertEq(
            expected = (true, false),
            (World.onRoad(w), World.onRoad({ playerOff = 0.0 - half - 1.0 | w })))
}
