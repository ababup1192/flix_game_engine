// Explore — 昼の町を歩き回る場面（窓あり・ブラウザ版も同じ App）。先頭をキーかスティックで動かし、仲間 2 人は先頭の通った道をなぞる。
// 町は出来上がった姿から（降ってくる演出なし）。カメラは横と奥を先頭へ合わせ、歩く向きへ少し先を見せ（止まると戻る）、高さは遅れて追う。
// App の w は Resources.With[Res, World]: 地図・絵・格子・Doc は Res、遊びで変わる物（先頭・向き・道・カメラ・時刻）は World。

mod Explore {
    use fge::{App, ImageData, LoadProgress, LwjglLayer, Num, Render, Resources, Scene3d, Vec2}
    use fge::GameEngine.Key
    use Route.{Dir}

    /// 描き物の大きさ（project.json の design と同じ 1280×720）。
    pub def size(): Vec2.Vec2 = { x = 1280.0, y = 720.0 }

    /// 描く元。town = 組んだ町・boards = 動かない板（読み込みで 1 回作る）・grid = 通れるマスの格子・doc・keys・plan = Doc・
    /// lens・eye = カメラのレンズと、地図の frame に合わせた目の位置・groundZ = 立ち始めの床の高さ・feetDepth = 足元が画面の feetV に来る奥行き・
    /// quality = 描き方の重さ・hide = 建物の北に隠れるマスの決め方。
    pub type alias Res = { town = TownScene.Res, boards = List[Scene3d.Billboard3d], grid = CollisionGrid.Grid, doc = ExploreDoc.Rec,
                           keys = ExploreDoc.Keys, plan = Buildup.Plan, lens = TownCamera.Lens, eye = TownCamera.Eye, groundZ = Float64,
                           feetDepth = Float64, quality = ExploreDoc.Quality, hide = CollisionGrid.HideRule }

    /// カメラの遅れて追う物。ahead = 先頭から先へ見せる量（m・地図の座標）・height = 遅れて追う床の高さ（m）。
    pub type alias CameraState = { ahead = (Float64, Float64), height = Float64 }

    /// 遊びの状態。time = 時刻（秒）・leader = 先頭の足元（地図の座標）・facing = 先頭の向き・trail = 先頭の通った道・
    /// walkClock = 歩いている間だけ進む時計（歩きのコマ）・moving = このコマで先頭が動いたか・camera = カメラの遅れて追う物。
    pub type alias World = { time = Float64, leader = (Float64, Float64), facing = Dir, trail = FollowTrail.Trail, walkClock = Float64,
                             moving = Bool, camera = CameraState }

    /// Doc と絵を読んで描く元を組む。readImage = 絵を画素にする口（assets からの相対の道 → 画素）・knobs = 描き方の重さの差し替え。
    pub def load(readImage: String -> Result[String, ImageData.ImageData] \ ef, knobs: Map[String, String]): Result[String, Res] \ ef + Fs.FileRead =
        let doc = ExploreDoc.loadOr(ExploreDoc.path());
        let keys = ExploreDoc.loadKeys(ExploreDoc.keysPath());
        let quality = ExploreDoc.qualityWith(knobs, doc#quality);
        let look0 = TownLook.loadOr(doc#look);
        let look = { billboardTextures = TownScene.BillboardTextures.ProjectTextures, shadowMapSize = quality#shadowMapSize,
                     fStop = if (quality#depthOfField) look0#fStop else 0.0 | look0 };
        forM (
            plan <- Buildup.loadPlan(doc#plan);
            m <- TownMap.load("step", doc#map);
            town <- TownScene.loadWithFxUsing(readImage, m, StageFx.none(), look, Some(m#walk#col),
                                              plan#party |> List.flatMap(w -> w#strip :: Option.toList(w#idleStrip)))
        ) yield {
            let lens = TownCamera.lensOf(look#topDeg, look#bottomDeg);
            let eye = TownCamera.frameEye(m, lens);
            let (c, r) = doc#start;
            let groundZ = TownMap.topAt(m, c, r);
            let decorWidth = (d: TownMap.Decor) -> Map.get(d#sprite, town#strips)
                |> Option.map(l -> Int32.toFloat64(l#width / Int32.max(1, d#frames)) / 32.0) |> Option.getWithDefault(1.0);
            let feetDepth = TownCamera.snapToTexel(TownCamera.depthAt(lens, eye, groundZ, plan#feetV));
            let hide = { slope = TownCamera.tanAt(lens, plan#feetV), seenHeight = doc#seenHeight, reach = doc#hideReach,
                         halfWidth = halfWidthOf(town, plan), sideDrift = doc#aheadMeters / Float64.max(1.0, feetDepth * doc#walkZoom) };
            { town = town, boards = TownScene.staticBoards(town),
              grid = CollisionGrid.build(m, Some(m#walk#col), decorWidth, d -> Set.memberOf(d#sprite, doc#passDecor), Some(hide)),
              doc = doc, keys = keys, plan = plan, lens = lens, eye = eye, groundZ = groundZ,
              feetDepth = feetDepth, quality = quality, hide = hide }
        }

    /// 隊列の歩きの絵の 1 コマの横幅の半分（m・一番広い人）。
    def halfWidthOf(town: TownScene.Res, plan: Buildup.Plan): Float64 =
        plan#party |> List.filterMap(w -> Map.get(w#strip, town#strips)) |> List.map(l -> Int32.toFloat64(l#width / 12) / 32.0 / 2.0)
            |> List.foldLeft(Float64.max, 0.0)

    /// 立ち始めの World（先頭は doc の start のマスの真ん中・仲間はその後ろに並ぶ）。
    pub def initial(res: Res): World =
        let m = res#town#map;
        let (c, r) = res#doc#start;
        let at = (Int32.toFloat64(c) + 0.5, Int32.toFloat64(m#height - 1 - r) + 0.5);
        let (fx, fy) = unitOf(res#doc#startFace);
        { time = 0.0, leader = at, facing = res#doc#startFace,
          trail = FollowTrail.lineBehind(at, (0.0 - fx, 0.0 - fy), res#doc#spacing, List.length(res#plan#party)),
          walkClock = 0.0, moving = false, camera = { ahead = (0.0, 0.0), height = res#groundZ } }

    def unitOf(d: Dir): (Float64, Float64) = match d {
        case Dir.North => (0.0, 1.0)
        case Dir.East  => (1.0, 0.0)
        case Dir.South => (0.0, -1.0)
        case Dir.West  => (-1.0, 0.0)
    }

    /// 動く向き (x, y) に近い 4 方向（横と縦の大きい方）。
    pub def dirOf(v: (Float64, Float64)): Dir =
        let (x, y) = v;
        if (Float64.abs(x) > Float64.abs(y)) { if (x > 0.0) Dir.East else Dir.West }
        else if (y > 0.0) Dir.North else Dir.South

    /// 操作の向きと強さ（長さ 0〜1・右が +x・上（北）が +y）。スティック（パッド・画面のスティック）を倒していればその値、
    /// 無ければキー（2 つ押しで斜め・長さ 1）。
    pub def inputOf(keys: ExploreDoc.Keys, frame: App.Frame): (Float64, Float64) =
        let stick = frame#leftStick;
        let stickLength = Num.sqrt(stick#x * stick#x + stick#y * stick#y);
        if (stickLength > 0.01) { let k = Float64.min(1.0, stickLength) / stickLength; (stick#x * k, stick#y * k) }
        else {
            let held = (ks: List[Key]) -> if (List.exists(k -> Set.memberOf(k, frame#down), ks)) 1.0 else 0.0;
            let x = held(keys#right) - held(keys#left);
            let y = held(keys#up) - held(keys#down);
            let length = Num.sqrt(x * x + y * y);
            if (length < 0.5) (0.0, 0.0) else (x / length, y / length)
        }

    /// 1 コマ進める（先頭を動かして壁で滑らせ、道を延ばし、カメラを寄せる）。
    pub def step(frame: App.Frame, res: Res, w: World): World = stepWith(inputOf(res#keys, frame), Float64.min(frame#dt, 0.1), res, w)

    /// 操作 input（長さ 0〜1）で dt 秒進める。
    pub def stepWith(input: (Float64, Float64), dt: Float64, res: Res, w: World): World =
        let doc = res#doc;
        let (ix, iy) = input;
        let (x0, y0) = w#leader;
        let (x1, y1) = CollisionGrid.moveAndSlide(res#grid, doc#radius, w#leader, (ix * doc#speed * dt, iy * doc#speed * dt));
        let dx = x1 - x0;
        let dy = y1 - y0;
        let moved = dx * dx + dy * dy > 0.0000000001;
        let pushing = ix * ix + iy * iy > 0.04;
        let keep = doc#spacing * Int32.toFloat64(Int32.max(1, List.length(res#plan#party) - 1)) + 0.5;
        let feet = TownMap.groundZAt(res#town#map, x1, y1);
        { time = w#time + dt, leader = (x1, y1),
          facing = if (moved) dirOf((dx, dy)) else if (pushing) dirOf(input) else w#facing,
          trail = if (moved) FollowTrail.push((x1, y1), keep, w#trail) else w#trail,
          walkClock = if (moved) w#walkClock + dt else w#walkClock, moving = moved,
          camera = { ahead = TownCamera.lookAhead(doc#aheadMeters, doc#aheadRate, doc#speed, (dx, dy), dt, w#camera#ahead),
                     height = w#camera#height + (feet - w#camera#height) * TownCamera.followRate(doc#heightLagK, dt) } }

    def snap(res: Res, v: Float64): Float64 = if (res#town#look#snapToTexels) TownCamera.snapToTexel(v) else v

    /// 目の位置（先頭 + 先へ見せる量を、足元が画面の feetV に来る所から引いて見る）。
    pub def eyeOf(res: Res, w: World): TownCamera.Eye =
        let pull = res#doc#walkZoom;
        let (lx, ly) = w#leader;
        let (ax, ay) = w#camera#ahead;
        let base = res#groundZ;
        { x = snap(res, lx + ax), z = snap(res, ly + ay - res#feetDepth * pull),
          height = base + (res#eye#height - base) * pull + (w#camera#height - base) }

    /// ピントの合う奥行き（目から先頭の足元まで）。
    pub def focusOf(res: Res, w: World): Float64 =
        let eye = eyeOf(res, w);
        let (lx, ly) = w#leader;
        let z = TownMap.groundZAt(res#town#map, lx, ly);
        Num.sqrt((ly - eye#z) * (ly - eye#z) + (eye#height - z) * (eye#height - z))

    /// i 番目（0 = 先頭）の足元と向き。仲間は道を間 × i だけ戻った所で、そこで動いていた向き（止まった時も最後の向き）。
    def memberAt(res: Res, w: World, i: Int32): ((Float64, Float64), Dir) =
        if (i == 0) (w#leader, w#facing)
        else {
            let (p, v) = FollowTrail.pointBack(w#trail, res#doc#spacing * Int32.toFloat64(i));
            (p, if (fst(v) == 0.0 and snd(v) == 0.0) w#facing else dirOf(v))
        }

    /// 1 コマの場面。
    pub def sceneOf(res: Res, w: World): Scene3d.Scene3dCmd =
        let town0 = res#town;
        let plan = res#plan;
        let camera = TownCamera.cameraAt(res#lens, town0#look#far, eyeOf(res, w));
        let town = TownScene.withCamera(town0, camera, size());
        let walkFrame = Int32.modulo(Float64.floor(w#walkClock / plan#frameSec) |> Float64.tryToInt32 |> Option.getWithDefault(0), 4);
        let members = plan#party |> List.mapWithIndex((i, walker) -> {
            let ((x, y), d) = memberAt(res, w, i);
            let (row, flip) = BuildVideo.dirCell(walker#dirs, d);
            let pose = if (w#moving) { strip = walker#strip, frame = walkFrame, perDir = 4, stretch = 1.0 } else BuildVideo.idlePose(plan, walker, i, w#time);
            TownScene.walkerBoardFrames(town, pose#strip, walker#tint, row, pose#perDir, pose#frame, flip, pose#stretch,
                                        snap(res, x), snap(res, y), TownMap.groundZAt(town#map, x, y))
        }) |> List.filterMap(identity);
        let decor = TownScene.decorBoards(town, w#time, _ -> Some((0.0, 1.0, 1.0)));
        let billboards = List.append(List.map(fst, members), List.map(fst, decor));
        let shadows = List.append(List.flatMap(snd, members), List.filterMap(snd, decor));
        { time = w#time | TownScene.sceneOfBoards(town, res#boards, camera, size(), billboards, shadows) }

    /// 遊べる App（実機の窓とブラウザで同じ）。描き方の重さの post が偽なら後がけを掛けない。
    pub def appOf(res: Res): App.App[Resources.With[Res, World], {}] =
        let app = App.make(Resources.of(res, initial(res)))
            |> App.addSystem(Resources.system(step))
            |> App.withView(Resources.view((_ctx, r, w) -> Render.scene3d(Vec2.zero(), sceneOf(r, w)) :: Nil));
        if (res#quality#post) app |> App.withPostStack(Resources.read((r, w) -> TownScene.postAt(r#town#look, focusOf(r, w), w#time, size()#x)))
        else app

    /// 通れるマスの格子を字の地図にする（# = 地図の字と建物で塞いだマス・+ = 建物の北に隠れるので塞いだマス・d = 広場のにぎやかしで塞いだマス・. = 通れる）。
    pub def gridText(res: Res): String =
        let m = res#town#map;
        let plain = CollisionGrid.build(m, Some(m#walk#col), _ -> 0.0, _ -> true, None)#blocked;
        let hidden = CollisionGrid.build(m, Some(m#walk#col), _ -> 0.0, _ -> true, Some(res#hide))#blocked;
        let mark = (cr: (Int32, Int32)) ->
            if (not Set.memberOf(cr, res#grid#blocked)) "."
            else if (Set.memberOf(cr, plain)) "#"
            else if (Set.memberOf(cr, hidden)) "+"
            else "d";
        List.range(0, m#height) |> List.map(r -> {
            let row = List.range(0, m#width) |> List.map(c -> mark((c, r))) |> String.flatten;
            "${String.padLeft(2, ' ', Int32.toString(r))} ${row}"
        }) |> String.intercalate("\n")

    /// 格子を字で出す（窓を開かない・make explore-grid）。
    pub def printGrid(): Unit \ IO =
        match (run { load(Images.readImageIo, Map.empty()) } with Fs.FileRead.runWithIO) {
            case Ok(res)  => println("[hd2d_town] 板の半分の幅 ${res#hide#halfWidth} m・目への線の横のずれ ${res#hide#sideDrift} m/m・上がり ${res#hide#slope} m/m\n${gridText(res)}")
            case Err(why) => println("[hd2d_town] 町を組めない: ${why}")
        }

    /// 窓ありの入口（make explore）。つまみは環境変数 SHADOW_MAP・DOF・POST（ExploreDoc.qualityWith）。
    pub def main(): Unit \ IO =
        if (LwjglLayer.ensureMainThread()) ()
        else {
            let knobs = BenchEnv.knobs(("SHADOW_MAP", "shadow") :: ("DOF", "dof") :: ("POST", "post") :: Nil);
            run {
                App.loadAndLaunch(() -> {
                    let decoder = LoadProgress.imageDecoder();
                    match load(Images.readImageWith(decoder), knobs) {
                        case Ok(res)  => appOf(res)
                        case Err(why) => bug!("[hd2d_town] 町を組めない: ${why}")
                    }
                })
            } with LwjglLayer.withProject(".")
              with Fs.FileRead.runWithIO
              with Fs.FileWrite.runWithIO
        }
}
