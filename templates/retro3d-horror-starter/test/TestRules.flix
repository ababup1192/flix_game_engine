// ルールだけをテストする（方針どおり）。座標の写経や描画はテストしない。
// 期待値はリテラルでなく Doc の既定値（WalkDoc.defaults）や表の値から導く。
// 校舎はテストの中に書いた小さな配置の表（床 2 枚・東の壁・西の階段）で組む（assets の表を描き替えても揺れない）。
mod TestRules {

    use fge::{Clock, Mesh3d, Model3d, Num, SortingLayer, Vec2, Vec3, Yarn}

    /// glTF の座標の表（engine では X が反転する）: 1 階の床・engine の x = 2..2.2 の壁・2 階の床・
    /// engine の x = −6..−4 を +Z へ上る坂と、x = −8.3..−6.3 を −Z へ上る坂。
    def layoutJson(): String =
        "{\"floors\":[" +
        "{\"index\":1,\"y\":0,\"rooms\":[{\"id\":\"r1\",\"name\":\"1年2組\",\"min\":[-1,0],\"max\":[1,3]}],\"colliders\":[{\"min\":[-10,-0.2,-10],\"max\":[10,0,10]},{\"min\":[-2.2,0,-10],\"max\":[-2,3,10]}]," +
        "\"stairs\":[{\"id\":\"s\",\"from\":1,\"to\":2,\"ramp\":[[[4,0,-4],[6,0,-4],[6,1.75,4],[4,1.75,4]],[[6.3,1.75,4],[8.3,1.75,4],[8.3,3.5,-4],[6.3,3.5,-4]]]}]}," +
        "{\"index\":2,\"y\":3.5,\"colliders\":[{\"min\":[-10,3.3,-10],\"max\":[10,3.5,10]}]}]," +
        "\"signs\":[{\"pos\":[0,2.15,-1],\"text\":\"1年2組\"}]," +
        "\"spawn\":{\"pos\":[0,0,5],\"yaw\":0}}"

    def layout(): Layout.Layout = Layout.fromJson(layoutJson()) |> Result.getWithDefault(Layout.empty())

    /// 人物 1 人（engine の (0, 0, 4)・−Z を向く・話すノードは girl）を置いた Doc。
    def cast(): CastDoc.Doc =
        CastDoc.fromJson("{\"characters\":[{\"id\":\"g\",\"model\":\"girl_student\",\"node\":\"girl\",\"pos\":[0,0,4],\"yaw\":180}]}")
            |> Option.getWithDefault(CastDoc.defaults())

    def dialogue(): Yarn.Program = Yarn.empty()

    def res(): Res.Res =
        Res.build({ walk = WalkDoc.defaults(), keys = KeysDoc.defaults(), look = LookDoc.defaults(), sound = SoundDoc.defaults(), layout = layout(),
                    assets = { floors = Map.empty(), props = Map.empty(), surfaces = Res.surfaces() }, items = ItemsDoc.defaults(),
                    cast = cast(), people = Map#{"girl_student" => person()}, dialogue = dialogue(), bundles = Nil, pending = Res.nothingPending() })

    /// 人物の形の代わり（形の無い模型）。話しかけられるのは形の読めた人物だけなので、cast の model の名前で置く。
    def person(): Model3d.Model3d =
        { mesh = Mesh3d.fromPolygons(Nil), skin = None, clips = Map.empty(), parts = Nil, textures = Nil, nodes = Nil }

    def speed(): Float64 = WalkDoc.rec(WalkDoc.defaults())#speed

    def radius(): Float64 = WalkDoc.rec(WalkDoc.defaults())#radius

    def forwardOnly(): World.Input = { forward = 1.0, strafe = 0.0, turn = 0.0, pitch = 0.0, look = Vec2.zero(), dash = false, active = true }

    /// 走るキーを押したまま前へ。
    def dashForward(): World.Input = { dash = true | forwardOnly() }

    def dashSpeed(): Float64 = WalkDoc.rec(WalkDoc.defaults())#dashSpeed

    /// マウスで degrees 度だけ右へ回す入力（Doc の 1 px あたりの角から px を出す）。
    def turnBy(degrees: Float64): World.Input =
        { forward = 0.0, strafe = 0.0, turn = 0.0, pitch = 0.0, look = { x = degrees / WalkDoc.rec(WalkDoc.defaults())#mouseDegPerPx, y = 0.0 }, dash = false, active = true }

    /// 入力を steps コマ（1 コマ 0.1 秒）ずつ順に流した World。
    def played(w0: World.World, script: List[(World.Input, Int32)]): World.World =
        let r = res();
        script |> List.foldLeft((w, e) -> List.range(0, snd(e)) |> List.foldLeft((acc, _) -> World.step(r, fst(e), 0.1, acc), w), w0)

    /// 足元 (x, 0, z) に yaw（ラジアン）を向いて立たせた World。
    def standingAt(x: Float64, z: Float64, yaw: Float64): World.World =
        let r = res();
        World.placeAt(r, Vec3.v3(x, 0.0, z), yaw, World.initial(r))

    /// 足元 (x, 0, z) から yaw を向いて steps コマ前へ歩いた World。
    def walked(x: Float64, z: Float64, yaw: Float64, steps: Int32): World.World =
        played(standingAt(x, z, yaw), (forwardOnly(), steps) :: Nil)

    def mm(v: Float64): Float64 = Float64.round(v * 1000.0)

    @Test
    def testWalkingForwardMovesBySpeedFromDoc(): Unit \ Assert =
        // 開けた床で yaw 0（+Z）へ 1 秒歩くと、Doc の速さの分だけ進む。
        Assert.assertEq(expected = mm(-5.0 + speed()), mm(World.feetOf(walked(0.0, -5.0, 0.0, 10))#z))

    @Test
    def testDashingCoversMoreGroundThanWalking(): Unit \ Assert =
        // 開けた床で 1 秒（10 コマ）前へ。歩くと Doc の speed・走るキーを押したままだと dashSpeed だけ進む。
        let dashed = played(standingAt(0.0, -5.0, 0.0), (dashForward(), 10) :: Nil);
        Assert.assertEq(expected = (mm(-5.0 + speed()), mm(-5.0 + dashSpeed())),
            (mm(World.feetOf(walked(0.0, -5.0, 0.0, 10))#z), mm(World.feetOf(dashed)#z)))

    @Test
    def testReleasingDashReturnsToWalkingSpeed(): Unit \ Assert =
        // 1 秒走ってから走るキーを離して 1 秒歩くと、後の 1 秒は Doc の speed だけ進む（−5 + dashSpeed + speed）。
        let w = played(standingAt(0.0, -5.0, 0.0), (dashForward(), 10) :: (forwardOnly(), 10) :: Nil);
        Assert.assertEq(expected = mm(-5.0 + dashSpeed() + speed()), mm(World.feetOf(w)#z))

    @Test
    def testPitchDoesNotChangeDashSpeed(): Unit \ Assert =
        // 見下ろしたまま 1 秒走っても、まっすぐ前を見て走った時と同じ dashSpeed だけ進む。
        let down = played(standingAt(0.0, -5.0, 0.0), ({ pitch = 1.0 | dashForward() }, 10) :: Nil);
        Assert.assertEq(expected = mm(-5.0 + dashSpeed()), mm(World.feetOf(down)#z))

    // ── 操作方法の表示（何も操作しない秒が Doc の hintWait に届くと出て、操作で消える） ──

    def hintDoc(): WalkDoc.Hint = WalkDoc.rec(WalkDoc.defaults())#hint

    /// 何も触っていないコマの入力。
    def idleInput(): World.Input = { forward = 0.0, strafe = 0.0, turn = 0.0, pitch = 0.0, look = Vec2.zero(), dash = false, active = false }

    @Test
    def testControlsHintStaysHiddenBeforeTheWait(): Unit \ Assert =
        // 何も操作しない時間が Doc の待つ秒より 0.5 秒短いうちは出ない。
        let r = res();
        Assert.assertEq(expected = 0.0, World.controlsHintOf(World.step(r, idleInput(), hintDoc()#wait - 0.5, standingAt(0.0, -5.0, 0.0))))

    @Test
    def testControlsHintShowsAfterTheWait(): Unit \ Assert =
        // 待つ秒と出る秒を過ぎると出切る（出具合 1）。
        let r = res();
        Assert.assertEq(expected = 1.0, World.controlsHintOf(World.step(r, idleInput(), hintDoc()#wait + hintDoc()#fade, standingAt(0.0, -5.0, 0.0))))

    @Test
    def testControlsHintFadesOutOnInput(): Unit \ Assert =
        // 出切った後に、動かない操作（キーを押しただけ）を Doc の消える秒だけ続けると消え切る。
        let r = res();
        let shown = World.step(r, idleInput(), hintDoc()#wait + hintDoc()#fade, standingAt(0.0, -5.0, 0.0));
        Assert.assertEq(expected = 0.0, World.controlsHintOf(World.step(r, { active = true | idleInput() }, hintDoc()#fade, shown)))

    @Test
    def testControlsHintStaysHiddenWhileTalkingOrOnTheMap(): Unit \ Assert + Fs.FileRead =
        // 話している間とマップを開いている間は、待つ秒と出る秒を過ぎても出ない。
        let r = Res.withDialogue(Yarn.loadOr(Yarn.empty(), Controls.dialoguePath()), res());
        let talking = World.startTalk(r, Clock.zero(), World.placeAt(r, Vec3.v3(0.0, 0.0, 3.0), 0.0, World.initial(r)));
        let onMap = World.openMap(r, standingAt(0.0, -5.0, 0.0));
        let waited = w -> World.controlsHintOf(World.step(r, idleInput(), hintDoc()#wait + hintDoc()#fade, w));
        Assert.assertEq(expected = (true, 0.0, 0.0), (World.isTalking(talking), waited(talking), waited(onMap)))

    @Test
    def testWallStopsTheBody(): Unit \ Assert =
        // +X の壁（x = 2）へ向かって歩き続けても、体の半径の手前で止まる。
        Assert.assertEq(expected = true, World.feetOf(walked(0.0, 0.0, Num.pi() / 2.0, 30))#x <= 2.0 - radius() + 0.001)

    @Test
    def testBodySlidesAlongTheWall(): Unit \ Assert =
        // 壁へ斜め（45°）に当たると、壁に沿って +Z へ進み続ける。
        let feet = World.feetOf(walked(1.0, 0.0, Num.pi() / 4.0, 30));
        Assert.assertEq(expected = (true, true), (feet#x <= 2.0 - radius() + 0.001, feet#z > 1.5))

    @Test
    def testRampRaisesTheFeetToTheLanding(): Unit \ Assert =
        // 1 本目の坂（z = −4 で床・z = 4 で 1.75 m）を上り切って踊り場に立つ。
        let w = walked(-5.0, -5.0, 0.0, 75);
        Assert.assertEq(expected = (mm(1.75), true), (mm(World.feetOf(w)#y), World.isOnFloor(w)))

    @Test
    def testBothRampsLeadToTheUpperFloor(): Unit \ Assert =
        // 1 本目の坂で踊り場へ・左を向いて 2 本目の坂の前へ・もう一度左を向いて上り切ると 2 階の床に立つ
        // （2 階の床の板の階段の所と踊り場の上が抜けていないと、頭が当たって上れない）。
        let w = played(standingAt(-5.0, -5.0, 0.0),
            (forwardOnly(), 75) :: (turnBy(-90.0), 1) :: (forwardOnly(), 18) :: (turnBy(-90.0), 1) :: (forwardOnly(), 80) :: Nil);
        Assert.assertEq(expected = (2, true), (Layout.floorIndexAt(World.feetOf(w)#y, layout()), World.isOnFloor(w)))

    @Test
    def testUpperFloorIsDrawnOnlyNearTheStairs(): Unit \ Assert =
        // 階段室から離れた所では今の階だけ、階段の下では上の階も描く。
        Assert.assertEq(expected = (1 :: Nil, 1 :: 2 :: Nil),
            (School.visibleFloors(layout(), Vec3.v3(9.0, 0.0, 0.0)), School.visibleFloors(layout(), Vec3.v3(-5.0, 0.0, -5.0))))

    @Test
    def testEnteringARoomMarksItVisited(): Unit \ Assert =
        // 廊下（z = −2）から部屋の四角（z = 0..3）へ歩いて入ると、その部屋が行った部屋になる。
        Assert.assertEq(expected = Set#{PaperMap.roomKey(1, "r1")}, World.visitedOf(walked(0.0, -2.0, 0.0, 30)))

    @Test
    def testEnteringARoomRemembersTheDoorway(): Unit \ Assert =
        // 部屋に入ったコマの足元が戸の音の鳴った所になり、部屋の四角（z = 0..3）の縁にある。
        let at = walked(0.0, -2.0, 0.0, 30)#doorAt |> Option.map(p -> p#z >= 0.0 and p#z < 0.1);
        Assert.assertEq(expected = Some(true), at)

    @Test
    def testMapFloorShiftsAndStopsAtTheTop(): Unit \ Assert =
        // 開くと今の階（1 階）・右へ 1 つで 2 階・表に 3 階は無いのでもう 1 つ右でも 2 階のまま。
        let r = res();
        let opened = World.openMap(r, standingAt(0.0, -2.0, 0.0));
        let up = World.shiftFloor(r, 1, opened);
        Assert.assertEq(expected = (Some(1), Some(2), Some(2)),
            (World.mapFloorOf(opened), World.mapFloorOf(up), World.mapFloorOf(World.shiftFloor(r, 1, up))))

    @Test
    def testMapNamesOnlyVisitedRooms(): Unit \ Assert =
        // 行った部屋だけに名前（「1年2組」は「1-2」に縮む）。行っていなければ名前は無い。
        let fr = PaperMap.frameOf(layout());
        Assert.assertEq(expected = ("1-2" :: Nil, Nil),
            (PaperMap.labelsOf(PaperMap.sheetOf(layout(), fr, 1, Set#{PaperMap.roomKey(1, "r1")})),
             PaperMap.labelsOf(PaperMap.sheetOf(layout(), fr, 1, Set.empty()))))

    @Test
    def testFloorNameIsWrittenInKanji(): Unit \ Assert =
        Assert.assertEq(expected = ("一階", "三階"), (PaperMap.floorName(1), PaperMap.floorName(3)))

    def talkDoc(): CastDoc.Rec = CastDoc.rec(CastDoc.defaults())

    @Test
    def testTalkNeedsReachAndFacing(): Unit \ Assert =
        // 人物（z = 4）へ向いて Doc の距離の内なら話しかけられ、距離の外・背を向けると話しかけられない。
        let near = 4.0 - talkDoc()#talkReach + 0.2;
        let far = 4.0 - talkDoc()#talkReach - 0.5;
        let id = (z: Float64, yaw: Float64) -> Cast.facedMember(cast(), Vec3.v3(0.0, 0.0, z), yaw) |> Option.map(m -> m#id);
        Assert.assertEq(expected = (Some("g"), None, None), (id(near, 0.0), id(far, 0.0), id(near, Num.pi())))

    @Test
    def testTalkAngleComesFromDoc(): Unit \ Assert =
        // 視線の正面から Doc の角より少し内なら話しかけられ、少し外なら話しかけられない。
        let rad = Num.pi() / 180.0;
        let id = (offDeg: Float64) -> Cast.facedMember(cast(), Vec3.v3(0.0, 0.0, 3.0), offDeg * rad) |> Option.map(m -> m#id);
        Assert.assertEq(expected = (Some("g"), None), (id(talkDoc()#talkAngleDeg - 2.0), id(talkDoc()#talkAngleDeg + 2.0)))

    @Test
    def testCannotWalkWhileTalking(): Unit \ Assert + Fs.FileRead =
        // 台詞（assets/talk の girl のノード）で話しかけると話す画面になり、前へ押し続けても足元が動かない。
        let r = Res.withDialogue(Yarn.loadOr(Yarn.empty(), Controls.dialoguePath()), res());
        let talking = World.startTalk(r, Clock.zero(), World.placeAt(r, Vec3.v3(0.0, 0.0, 3.0), 0.0, World.initial(r)));
        let after = played(talking, (forwardOnly(), 10) :: Nil);
        Assert.assertEq(expected = (true, World.feetOf(talking)#z), (World.isTalking(after), World.feetOf(after)#z))

    @Test
    def testCannotTalkBeforeTheFigureArrives(): Unit \ Assert =
        // 形がまだ無い人物（ブラウザ版で glb が届く前）は、話しかけられる所に立って向いていても相手にならない。
        let r = { people = Map.empty() | res() };
        let facing = World.placeAt(r, Vec3.v3(0.0, 0.0, 3.0), 0.0, World.initial(r));
        Assert.assertEq(expected = None, World.talkTargetOf(r, facing) |> Option.map(m -> m#id))

    /// 人物 m の真横（体の向きから +90 度）1 m に立つプレイヤーの足元。
    def besideOf(m: CastDoc.Member): Vec3.Vec3 =
        let side = m#yaw + Num.pi() / 2.0;
        Vec3.v3(m#feet#x + Num.sin(side), m#feet#y, m#feet#z + Num.cos(side))

    def roundedDeg(rad: Float64): Int32 = Num.roundInt(rad * 180.0 / Num.pi())

    @Test
    def testBodyTurnsToThePlayerWithinBodyTurnSec(): Unit \ Assert =
        // 真横のプレイヤーに話しかけると、Doc の bodyTurnSec の後には体が 90 度回り切り、首は回していない。
        let facing = Cast.memberOf(cast(), "g") |> Option.map(m -> {
            let a = Cast.attend(cast(), m, besideOf(m), 0.0, None);
            let f = Cast.facingOf(cast(), m, besideOf(m), talkDoc()#bodyTurnSec, a);
            (roundedDeg(f#body), roundedDeg(f#head))
        });
        Assert.assertEq(expected = Some((90, 0)), facing)

    @Test
    def testBodyStaysThenGoesBackAfterTheTalk(): Unit \ Assert =
        // 話し終えて lingerSec の内は向いたまま、lingerSec + returnSec の後には置いた向きへ戻っている。
        let bodies = Cast.memberOf(cast(), "g") |> Option.map(m -> {
            let ended = Cast.finish(5.0, besideOf(m), Cast.attend(cast(), m, besideOf(m), 0.0, None));
            let bodyAt = (t: Float64) -> roundedDeg(Cast.facingOf(cast(), m, besideOf(m), t, ended)#body);
            (bodyAt(5.0 + talkDoc()#lingerSec * 0.5), bodyAt(5.0 + talkDoc()#lingerSec + talkDoc()#returnSec))
        });
        Assert.assertEq(expected = Some((90, 0)), bodies)

    @Test
    def testGesturesCycleThroughTheLines(): Unit \ Assert =
        // 人物の gestures を台詞の行の順に回す（2 つなら 3 行目で最初に戻る）。
        let clipAt = (line: Int32) -> CastDoc.fromJson("{\"characters\":[{\"id\":\"g\",\"model\":\"girl_student\",\"pos\":[0,0,4],\"gestures\":[\"a\",\"b\"]}]}")
            |> Option.flatMap(doc -> Cast.memberOf(doc, "g") |> Option.flatMap(m -> {
                let a = { line = line, lineAt = 10.0 | Cast.attend(doc, m, besideOf(m), 0.0, None) };
                Cast.gestureOf(doc, m, 10.0 + talkDoc()#gestureDelaySec + 0.1, a) |> Option.map(g -> g#clip)
            }));
        Assert.assertEq(expected = (Some("b"), Some("a")), (clipAt(1), clipAt(2)))

    @Test
    def testSubtitleWrapsAfterPunctuationWithinTheLimit(): Unit \ Assert =
        // Doc の字数の上限を超える台詞は、両方の行が上限に収まる句読点の後で 2 行に分かれる。
        let max = Num.floorInt(LookDoc.rec(LookDoc.defaults())#subtitle#maxChars);
        Assert.assertEq(expected = "三階の空き教室には入るなよ。あそこは今、" :: "『月曜日の朝』がぎゅうぎゅうに詰まっている。" :: Nil,
            SubtitleWrap.linesOf(max, "三階の空き教室には入るなよ。あそこは今、『月曜日の朝』がぎゅうぎゅうに詰まっている。"))

    @Test
    def testLayoutMirrorsXIntoEngineCoordinates(): Unit \ Assert =
        // 表の壁（glTF の x = −2.2..−2）は engine の x = 2..2.2 になる。
        Assert.assertEq(expected = Some((2.0, 2.2)),
            Layout.floorAt(1, layout()) |> Option.flatMap(f -> List.drop(1, f#colliders) |> List.head) |> Option.map(b -> (b#min#x, b#max#x)))

    @Test
    def testSpawnYawZeroFacesMinusZ(): Unit \ Assert =
        // 表の yaw 0 は glTF の −Z を向く。engine のカメラの yaw は π（−Z）。
        Assert.assertEq(expected = mm(Num.pi()), mm(layout()#start#yaw))

    def captionRule(): RoomCaption.Rule =
        { reach = WalkDoc.rec(WalkDoc.defaults())#signReach, angleDeg = WalkDoc.rec(WalkDoc.defaults())#captionAngleDeg }

    @Test
    def testCaptionNamesTheRoomYouAreIn(): Unit \ Assert =
        // 部屋（表の r1・engine の z = 0..3）の中では、プレートに背を向けていてもその部屋の名前。
        Assert.assertEq(expected = Some("1年2組"), RoomCaption.targetOf(layout(), captionRule(), Vec3.v3(0.0, 0.0, 1.5), 0.0))

    @Test
    def testCaptionInTheCorridorNamesTheFacedDoorway(): Unit \ Assert =
        // 廊下（部屋の外の z = −2.5）でプレート（z = −1）の方を向くと出て、背を向けると出ない。
        Assert.assertEq(expected = (Some("1年2組"), None),
            (RoomCaption.targetOf(layout(), captionRule(), Vec3.v3(0.0, 0.0, -2.5), 0.0),
             RoomCaption.targetOf(layout(), captionRule(), Vec3.v3(0.0, 0.0, -2.5), Num.pi())))

    @Test
    def testCaptionSwitchesOnlyAfterTheDelay(): Unit \ Assert =
        // 選んだ部屋が Doc の間より短い時は出さず、間と出る秒が過ぎると出切る。
        let d = WalkDoc.rec(WalkDoc.defaults());
        let early = RoomCaption.step(Some("A"), d#captionDelay, d#captionFade, d#captionDelay / 2.0, RoomCaption.empty());
        let late = RoomCaption.step(Some("A"), d#captionDelay, d#captionFade, d#captionFade + 0.01,
                       RoomCaption.step(Some("A"), d#captionDelay, d#captionFade, d#captionDelay + 0.01, early));
        Assert.assertEq(expected = (None, Some("A"), 1.0), (early#shown, late#shown, late#alpha))

    @Test
    def testPitchStopsAtTheLimitAndDoesNotChangeTheWalk(): Unit \ Assert =
        // 見下ろすキーを押し続けると Doc の限りで止まり、歩く距離は見下ろしていない時と同じ。
        let d = WalkDoc.rec(WalkDoc.defaults());
        let down = { pitch = 1.0 | forwardOnly() };
        let w = played(standingAt(0.0, -5.0, 0.0), (down, 10) :: Nil);
        Assert.assertEq(expected = (mm(d#pitchLimitDeg * Num.pi() / 180.0), mm(World.feetOf(walked(0.0, -5.0, 0.0, 10))#z)),
            (mm(World.pitchOf(w)), mm(World.feetOf(w)#z)))

    @Test
    def testQuitAskedThenNoReturnsToPlay(): Unit \ Assert =
        // Esc・閉じるボタンで確認へ、いいえで遊びへ戻る（すぐには終わらない）。
        let asked = World.askQuit(World.initial(res()));
        Assert.assertEq(expected = (true, false, false),
            (World.isAskingQuit(asked), World.isQuitting(asked), World.isAskingQuit(World.answerQuit(false, asked))))

    @Test
    def testQuitConfirmedOnlyAfterYes(): Unit \ Assert =
        Assert.assertEq(expected = true, World.isQuitting(World.answerQuit(true, World.askQuit(World.initial(res())))))

    @Test
    def testBodyStaysWhileAskingQuit(): Unit \ Assert =
        // 確認の窓が出ている間は押しても動かない。
        let r = res();
        let asked = World.askQuit(World.initial(r));
        Assert.assertEq(expected = World.feetOf(asked)#z, World.feetOf(World.step(r, forwardOnly(), 0.5, asked))#z)

    @Test
    def testClickInsideQuitWindowQuits(): Unit \ Assert =
        // 確認の窓の真ん中を押すと Enter と同じ（はい）。
        let asked = World.askQuit(World.initial(res()));
        Assert.assertEq(expected = true,
            World.isQuitting(Controls.tapAt(res(), { x = World.width() / 2.0, y = World.height() / 2.0 }, asked)))

    @Test
    def testClickOutsideQuitWindowReturnsToPlay(): Unit \ Assert =
        // 窓の外を押すと Esc と同じ（いいえ）。
        let asked = World.askQuit(World.initial(res()));
        let after = Controls.tapAt(res(), { x = 1.0, y = 1.0 }, asked);
        Assert.assertEq(expected = (false, false), (World.isAskingQuit(after), World.isQuitting(after)))

    @Test
    def testLayersAreStackedBackToFront(): Unit \ Assert =
        // 層の表が奥から手前へ交ざらずに並ぶ（範囲を書き換えたときの取り違えを止める）。
        Assert.assertEq(expected = true, SortingLayer.isStacked(ZOrder.layers()))
}
