// BuildVideo — 歩く先の町が出来ていく動画のコマを、窓を開かずに CPU（SoftRaster）で書く（debug/build_frames/f0001.png …）。
// FRAME_FROM・FRAME_TO で範囲を選び、もう書いたコマは飛ばす。出来た物を staticGroup にまとめ直した回数と時間を最後に出す。
mod BuildVideo {
    use fge::{Color, HeadlessFont, HeadlessRender, Num, PostStack, Render, Scene3d, Texture3d, Vec2}
    use Buildup.{Plan, Show}
    use Route.{Dir}
    use TownMap.{TownMap}
    use TownScene.{Res}

    import java.io.File
    import java.lang.System

    pub def fps(): Int32 = 30

    def design(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    def envInt(name: String, fallback: Int32): Int32 \ IO =
        let v = System.getenv(name);
        if (Object.isNull(v)) fallback else Int32.fromString(v) |> Option.getWithDefault(fallback)

    /// 毎コマの決まり（台本から 1 回だけ作る）。leaderX・leaderY = 先頭の位置・cameraX・cameraY = ならしたカメラの追う点・
    /// clock = 歩いている間だけ進む時計（歩きのコマを替える）・feetDepth = 足元が画面の高さ feetV に来る水平の奥行き。
    pub type alias Track = { route = Route.Route, cameraX = Vector[Float64], cameraY = Vector[Float64], cameraHeight = Vector[Float64],
                         clock = Vector[Float64], frames = Int32, feetDepth = Float64, eye = TownCamera.Eye, lens = TownCamera.Lens, groundZ = Float64 }

    pub def trackOf(m: TownMap, look: TownScene.Look, plan: Plan): Track =
        let lens = TownCamera.lensOf(look#topDeg, look#bottomDeg);
        let eye = TownCamera.frameEye(m, lens);
        let first = List.head(plan#path) |> Option.getWithDefault({ col = 13, row = 20, wait = 0.0 });
        let groundZ = TownMap.topAt(m, first#col, first#row);
        let speed = plan#groundFlowH / TownCamera.screenPerMeterAt(lens, eye, groundZ, 0.5);
        let route = Route.make(m#height, plan#path, speed, plan#idleSec);
        // WhyNot: 待機の長さは台本の holdSec だけにしない — 止まる時に待機の動きが見えるよう、hold は Doc の値をそのまま使う
        let total = route#endAt + plan#stopSec / 2.0 + plan#holdSec;
        let n = Float64.round(total * Int32.toFloat64(fps())) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let dt = 1.0 / Int32.toFloat64(fps());
        let leader = Vector.range(0, n) |> Vector.map(f -> fst(Route.pointAt(route, Route.distanceAt(route, Int32.toFloat64(f) * dt))));
        let half = Float64.round(plan#stopSec / 2.0 / dt) |> Float64.tryToInt32 |> Option.getWithDefault(10);
        let moving = Vector.range(0, n) |> Vector.map(f -> if (Route.isMoving(route, Int32.toFloat64(f) * dt)) dt else 0.0);
        let clock = Vector.scanLeft((a, x) -> a + x, 0.0, moving);
        let snap = (v: Float64) -> if (look#snapToTexels) TownCamera.snapToTexel(v) else v;
        { route = route, cameraX = Route.hannSmooth(half, Vector.map(fst, leader)), cameraY = Route.hannSmooth(half, Vector.map(snd, leader)),
          cameraHeight = Route.lagged(plan#camZLagK, dt, Vector.map(_ -> groundZ, leader)),
          clock = clock, frames = n, feetDepth = snap(TownCamera.depthAt(lens, eye, groundZ, plan#feetV)), eye = eye, lens = lens, groundZ = groundZ }

    /// 向き → 帯の中の段（0 背中・1 右・2 正面）と左右反転（左は右の反転）。
    def dirCell(d: Dir): (Int32, Bool) = match d {
        case Dir.North => (0, false)
        case Dir.East  => (1, false)
        case Dir.South => (2, false)
        case Dir.West  => (1, true)
    }

    /// 出来た物の集まりの作り置きと、作り直しにかかった時間（ns）。
    type alias GroupCache = { grouping = Grouping, totalNs = Int64, maxNs = Int64, listed = Int32 }

    def cachedGroup(cache: Ref[GroupCache, r], f: Int32, settled: List[(String, Scene3d.Instance3d)]): (Scene3d.StaticGroup, List[Scene3d.Instance3d]) \ {r, IO} =
        let c = Ref.get(cache);
        let t0 = System.nanoTime();
        let (next, loose) = regroup(f, settled, c#grouping);
        let rebuilt = next#regroups != c#grouping#regroups;
        // WhyNot: 集まりの値を作るだけで測り終えない — 描き手が描く時に読む物の列まで出してから時計を止める
        let listed = if (rebuilt) List.length(Scene3d.groupInstancesOf(next#group)) else c#listed;
        let ns = System.nanoTime() - t0;
        Ref.put({ grouping = next, totalNs = if (rebuilt) c#totalNs + ns else c#totalNs, maxNs = if (rebuilt) Int64.max(c#maxNs, ns) else c#maxNs, listed = listed }, cache);
        (next#group, loose)

    /// 止まっている間の 1 人の絵（帯・コマ・縦の倍率）。3 人の位相は 1 人ごとに少しずらす。
    /// 息遣い = 1.8 秒周期で縦に ±1.5%（足元はそのまま）・足踏み = 歩きのコマを 0.5 秒ごとにその場で替える。
    /// 息遣いのコマの帯（向きごとに 吸った・吐いた の 2 コマ）があれば、それを idleFrameSec ごとに・1 人ごとに idlePhaseSec ずらして替える。
    def idlePose(plan: Plan, w: Buildup.Walker, i: Int32, t: Float64): { strip = String, frame = Int32, perDir = Int32, stretch = Float64 } =
        let phase = Int32.toFloat64(i) * 0.37;
        let cycleFrame = (sec: Float64) -> Int32.modulo(Float64.floor(t / sec + phase * 4.0) |> Float64.tryToInt32 |> Option.getWithDefault(0), 4);
        match (w#idleStrip, plan#idle) {
            case (Some(strip), _) =>
                let k = Float64.floor((t + Int32.toFloat64(i) * plan#idlePhaseSec) / plan#idleFrameSec) |> Float64.tryToInt32 |> Option.getWithDefault(0);
                { strip = strip, frame = Int32.modulo(k, 2), perDir = 2, stretch = 1.0 }
            case (None, Buildup.Idle.Step) => { strip = w#strip, frame = cycleFrame(0.5), perDir = 4, stretch = 1.0 }
            case (None, Buildup.Idle.Breath) =>
                { strip = w#strip, frame = 1, perDir = 4, stretch = 1.0 + 0.015 * Num.sin(2.0 * Num.pi() * (t / 1.8 + phase)) }
        }

    /// 読み込んだ物（地図・台本・町・土ぼこりの絵・演出の部品・毎コマの決まり）。
    pub type alias Setup = { map = TownMap, plan = Plan, res = Res, dust = Texture3d.Texture3d, show = Show, track = Track }

    /// 地図・台本・町を読み、演出の部品と毎コマの決まりを作る。look = 見た目のつまみ。
    pub def setup(look: TownScene.Look): Result[String, Setup] \ IO =
        (run { TownMap.load("step", "assets/town_avenue.map.json") |> Result.flatMap(m -> Buildup.loadPlan("assets/buildup.json") |> Result.map(p -> (m, p))) } with Fs.FileRead.runWithIO)
            |> Result.flatMap(mp -> {
                let (m, p) = mp;
                TownScene.load(m, look, Some(m#walk#col), p#party |> List.filterMap(w -> w#idleStrip)) |> Result.map(res -> (m, p, res))
            })
            |> Result.flatMap(mpr -> { let (m, p, res) = mpr; Buildup.dustTexture() |> Result.map(d -> (m, p, res, d)) })
            |> Result.flatMap(all -> {
                let (m, p, res, d) = all;
                let tr = trackOf(m, look, p);
                let dt = 1.0 / Int32.toFloat64(fps());
                let leaderRows = Vector.range(0, tr#frames) |> Vector.map(f -> {
                    let t = Int32.toFloat64(f) * dt;
                    (t, Int32.toFloat64(m#height) - 0.5 - snd(fst(Route.pointAt(tr#route, Route.distanceAt(tr#route, t)))))
                });
                let rowTime = (r: Int32) -> Buildup.rowTimeOf(p#timing, leaderRows, r);
                Buildup.make(p#timing, rowTime, m, res#town#quads, res#town#boards, name -> Map.get(name, res#materials), TownScene.boardBillboard(res), d)
                    |> Result.map(show -> { map = m, plan = p, res = res, dust = d, show = show, track = tr })
            })

    /// コマ f の出来た物（staticGroup へまとめる鍵と物）。
    pub def settledAt(st: Setup, f: Int32): List[(String, Scene3d.Instance3d)] =
        Buildup.frameAt(st#show, Int32.toFloat64(f) / Int32.toFloat64(fps()))#settled

    /// 出来た物の集まりの持ち越し。keys = 集まりに入れた物の鍵・group = 集まり・builtAt = 作ったコマ・regroups = 作り直した回数。
    pub type alias Grouping = { keys = Set[String], group = Scene3d.StaticGroup, builtAt = Int32, regroups = Int32 }

    /// 作り直す間のコマ数（出来た物は毎コマ増えるので、まとめ直しは 0.5 秒ごとにまとめて行い、その間に出来た物は置いた物として描く）。
    // WhyNot: 出来た物が増えたコマごとに集まりを作り直さない — 描き手が持ち越しを毎コマ作り直し、engine が「30 コマ続けて作り直した」と知らせる。
    pub def regroupEvery(): Int32 = 15

    pub def startGrouping(st: Setup): Grouping = { keys = Set.empty(), group = st#show#fixed, builtAt = -1000, regroups = 0 }

    /// コマ f の出来た物から、集まり（作り直すのは regroupEvery コマごと）と、集まりにまだ入っていない物を出す。
    pub def regroup(f: Int32, settled: List[(String, Scene3d.Instance3d)], g: Grouping): (Grouping, List[Scene3d.Instance3d]) =
        if (f - g#builtAt >= regroupEvery() and List.length(settled) != Set.size(g#keys)) {
            let next = { keys = settled |> List.map(fst) |> List.toSet, group = Scene3d.staticGroup("settled", settled), builtAt = f, regroups = g#regroups + 1 };
            (next, Nil)
        } else (g, settled |> List.filter(kv -> not Set.memberOf(fst(kv), g#keys)) |> List.map(snd))

    /// コマ f の場面とピントの距離。groupOf = 出来た物の列 → (集まり, 集まりにまだ入っていない物)・size = 描き物の大きさ。
    pub def shotAt(st: Setup, groupOf: List[(String, Scene3d.Instance3d)] -> (Scene3d.StaticGroup, List[Scene3d.Instance3d]) \ ef, size: Vec2.Vec2, f: Int32): (Scene3d.Scene3dCmd, Float64) \ ef =
        let res = st#res;
        let plan = st#plan;
        let show = st#show;
        let tr = st#track;
        let look = res#look;
        let snap = (v: Float64) -> if (look#snapToTexels) TownCamera.snapToTexel(v) else v;
        let dt = 1.0 / Int32.toFloat64(fps());
        let t = Int32.toFloat64(f) * dt;
        let route = tr#route;
        let s = Route.distanceAt(route, t);
        let walking = Route.isMoving(route, t);
        let clock = Vector.nth(f, tr#clock) |> Option.getWithDefault(0.0);
        let walkFrame = Int32.modulo(Float64.floor(clock / plan#frameSec) |> Float64.tryToInt32 |> Option.getWithDefault(0), 4);
        let members = plan#party |> List.mapWithIndex((i, w) -> {
            let ((x, y), d0) = Route.pointAt(route, s - Int32.toFloat64(i));
            let d = if (not walking and t >= route#endAt) plan#endFace else d0;
            let (row, flip) = dirCell(d);
            let pose = if (walking) { strip = w#strip, frame = walkFrame, perDir = 4, stretch = 1.0 } else idlePose(plan, w, i, t);
            TownScene.walkerBoardFrames(res, pose#strip, w#tint, row, pose#perDir, pose#frame, flip, pose#stretch, snap(x), snap(y), tr#groundZ)
        }) |> List.filterMap(identity);
        let shake = Buildup.shakeAt(show, t);
        let at = (v: Vector[Float64], fallback: Float64) -> Vector.nth(f, v) |> Option.getWithDefault(fallback);
        let eye = { x = snap(at(tr#cameraX, tr#eye#x)), z = snap(at(tr#cameraY, 0.0) - tr#feetDepth),
                    height = tr#eye#height + (at(tr#cameraHeight, tr#groundZ) - tr#groundZ) + shake };
        let camera = TownCamera.cameraAt(tr#lens, look#far, eye);
        let leaderY = snap(snd(fst(Route.pointAt(route, s))));
        let focus = Num.sqrt((leaderY - eye#z) * (leaderY - eye#z) + (eye#height - tr#groundZ) * (eye#height - tr#groundZ));
        let textures = st#dust :: res#textures;
        let partyBoards = List.map(fst, members);
        let partyShadows = List.flatMap(snd, members);
        if (t >= show#done)
            ({ time = t | TownScene.sceneWith(res, camera, size, res#group :: Nil, List.append(res#boards, partyBoards), partyShadows, textures) }, focus)
        else {
            let fr = Buildup.frameAt(show, t);
            let contacts = fr#contacts |> List.map(c -> {
                let (p, w, k) = c;
                TownScene.contactInstance(res#contactMesh, res#contactMaterial, p#x, p#z, p#y, w * k)
            });
            let (settledGroup, loose) = groupOf(fr#settled);
            ({ time = t | TownScene.sceneWith(res, camera, size, show#fixed :: settledGroup :: Nil, List.append(fr#billboards, partyBoards),
                                 List.flatten(fr#moving :: loose :: contacts :: partyShadows :: Nil), textures) }, focus)
        }

    def fullSceneOf(look: TownScene.Look, focus: Float64, scene: Scene3d.Scene3dCmd): HeadlessRender.Scene =
        let built = PostStack.build({ size = design(), clear = Color.rgb(0.0, 0.0, 0.0), world = TownScene.items(scene) }, TownScene.postAt(look, focus, scene#time));
        let specs = Render.passSpecsOf(_ -> None, built#plan)#specs
            |> List.map(sp -> { name = sp#name, clear = sp#clear, drawables = sp#drawables, polygons = sp#polygons, surfaces = sp#surfaces, scenes = sp#scenes, target = sp#target });
        let soft = Render.softSceneOf(_ -> None, built#present :: Nil);
        { passes = specs, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces,
          scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }

    def pad4(i: Int32): String = String.padLeft(4, '0', Int32.toString(i))

    /// 町が出来ていく動画のコマを書く。
    pub def frames(): Unit \ IO =
        let look = run { TownLook.loadOr("assets/town.json") } with Fs.FileRead.runWithIO;
        match setup(look) {
            case Err(why) => bug!("[hd2d_town] 町を組めない: ${why}")
            case Ok(st)   =>
                let tr = st#track;
                let scale = envInt("SCALE", 4);
                let first = envInt("FRAME_FROM", 1);
                let last = Int32.min(tr#frames, envInt("FRAME_TO", tr#frames));
                let atlas = HeadlessFont.buildUiAtlas("assets/Xolonium-Regular.ttf", "assets/Xolonium-Regular.ttf");
                let cfg = { design = design(), scale = scale, outDir = "debug/build_frames", fontTtf = "assets/Xolonium-Regular.ttf", fontAtlas = atlas,
                            frameW = 320 * scale, frameH = 180 * scale | HeadlessRender.defaults() };
                println("[hd2d_town] 町が出来ていく動画: コマ ${Int32.toString(tr#frames)}（${Float64.toString(Int32.toFloat64(tr#frames) / 30.0)} 秒）・" +
                        "部品 ${Int32.toString(Vector.length(st#show#pieces))}・全部出来る ${Float64.toString(st#show#done)} 秒・先頭が止まる ${Float64.toString(tr#route#endAt)} 秒");
                region rc {
                    let cache = Ref.fresh(rc, { grouping = startGrouping(st), totalNs = 0i64, maxNs = 0i64, listed = 0 });
                    List.range(first, last + 1) |> List.forEach(f -> {
                        let name = "f${pad4(f)}";
                        if (new File("debug/build_frames/${name}.png").exists()) ()
                        else {
                            let (scene, focus) = shotAt(st, cachedGroup(cache, f - 1), design(), f - 1);
                            HeadlessRender.renderPngFull(cfg, fullSceneOf(look, focus, scene), name);
                            println("[hd2d_town] debug/build_frames/${name}.png")
                        }
                    });
                    let c = Ref.get(cache);
                    println("[hd2d_town] staticGroup のまとめ直し ${Int32.toString(c#grouping#regroups)} 回・合計 ${Float64.toString(Int64.toFloat64(c#totalNs) / 1000000.0)} ms・" +
                            "最大 ${Float64.toString(Int64.toFloat64(c#maxNs) / 1000000.0)} ms・最後の集まりの物 ${Int32.toString(c#listed)} 個")
                }
        }
}
