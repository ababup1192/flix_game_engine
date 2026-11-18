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

    pub def design(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    pub def envInt(name: String, fallback: Int32): Int32 \ IO =
        let v = System.getenv(name);
        if (Object.isNull(v)) fallback else Int32.fromString(v) |> Option.getWithDefault(fallback)

    /// 毎コマの決まり（台本から 1 回だけ作る）。leaderX・leaderY = 先頭の位置・cameraX・cameraY = ならしたカメラの追う点・
    /// clock = 歩いている間だけ進む時計（歩きのコマを替える）・feetDepth = 足元が画面の高さ feetV に来る水平の奥行き・
    /// zoom = コマごとのカメラの引き（足元の点からの距離の倍率）・stand = 立ったままの台本の立つ点（地図の座標）・
    /// walkFrom = 立ったままの台本で歩き出す演出の時刻（横並びから隊列へ組み直す始まり）・feetZ = 地図の座標の点の足の高さ。
    pub type alias Track = { route = Route.Route, cameraX = Vector[Float64], cameraY = Vector[Float64], cameraHeight = Vector[Float64],
                         clock = Vector[Float64], frames = Int32, feetDepth = Float64, eye = TownCamera.Eye, lens = TownCamera.Lens, groundZ = Float64,
                         zoom = Vector[Float64], stand = Option[(Float64, Float64)], walkFrom = Float64, feetZ = Float64 -> Float64 -> Float64 }

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
          clock = clock, frames = n, feetDepth = snap(TownCamera.depthAt(lens, eye, groundZ, plan#feetV)), eye = eye, lens = lens, groundZ = groundZ,
          zoom = Vector.map(_ -> 1.0, leader), stand = None, walkFrom = 0.0, feetZ = (_, _) -> groundZ }

    /// 地図の walk の台本（段のある道）の毎コマの決まり。足は段の上の高さ・カメラの高さは先頭の足の高さを camZLagK で遅れて追う・
    /// 目の位置は地図の frame の目を、道の頭の床が frame の groundZ より高い分だけ上げた物・zoom = 追従カメラの引き（足元からの距離の倍率）。
    // WhyNot: 地図の frame の目の高さをそのまま使わない — frame は床 groundZ の上で決めた画角で、高い所から歩き出すと目が床に近づき、キャラが町より大きく写る。
    pub def pathTrackOf(m: TownMap, look: TownScene.Look, plan: Plan, zoom: Float64): Track =
        let lens = TownCamera.lensOf(look#topDeg, look#bottomDeg);
        let first = List.head(plan#path) |> Option.getWithDefault({ col = 0, row = 0, wait = 0.0 });
        let z0 = TownMap.groundZAt(m, Int32.toFloat64(first#col) + 0.5, Int32.toFloat64(m#height - 1 - first#row) + 0.5);
        let framed = TownCamera.frameEye(m, lens);
        let eye = { height = framed#height + z0 - m#frame#groundZ | framed };
        let speed = plan#groundFlowH / TownCamera.screenPerMeterAt(lens, eye, z0, 0.5);
        let route = Route.make(m#height, plan#path, speed, plan#idleSec);
        let total = route#endAt + plan#stopSec / 2.0 + plan#holdSec;
        let n = Float64.round(total * Int32.toFloat64(fps())) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let dt = 1.0 / Int32.toFloat64(fps());
        let leader = Vector.range(0, n) |> Vector.map(f -> fst(Route.pointAt(route, Route.distanceAt(route, Int32.toFloat64(f) * dt))));
        let half = Float64.round(plan#stopSec / 2.0 / dt) |> Float64.tryToInt32 |> Option.getWithDefault(10);
        let moving = Vector.range(0, n) |> Vector.map(f -> if (Route.isMoving(route, Int32.toFloat64(f) * dt)) dt else 0.0);
        let snap = (v: Float64) -> if (look#snapToTexels) TownCamera.snapToTexel(v) else v;
        { route = route, cameraX = Route.hannSmooth(half, Vector.map(fst, leader)), cameraY = Route.hannSmooth(half, Vector.map(snd, leader)),
          cameraHeight = Route.lagged(plan#camZLagK, dt, Vector.map(p -> TownMap.groundZAt(m, fst(p), snd(p)), leader)),
          clock = Vector.scanLeft((a, x) -> a + x, 0.0, moving), frames = n, feetDepth = snap(TownCamera.depthAt(lens, eye, z0, plan#feetV)),
          eye = eye, lens = lens, groundZ = z0, zoom = Vector.map(_ -> zoom, leader), stand = None, walkFrom = 0.0,
          feetZ = TownMap.groundZAt(m) }

    /// 立ったままの台本の毎コマの決まり。町が出来て目印の揺れが収まった walkPause 秒後に、path の 2 点目から先を歩き出す。
    /// カメラは引いた位置から、歩き出して r#followSec 秒かけて歩く追従カメラ（横と奥は先頭を追い、止まる所だけ丸める）へ移る。
    def standTrackOf(m: TownMap, look: TownScene.Look, plan: Plan, r: Buildup.Radial, show: Buildup.Show): Track =
        let lens = TownCamera.lensOf(look#topDeg, look#bottomDeg);
        let eye = TownCamera.frameEye(m, lens);
        let at = List.head(plan#path) |> Option.getWithDefault({ col = 13, row = 15, wait = 0.0 });
        let groundZ = TownMap.topAt(m, at#col, at#row);
        let x = Int32.toFloat64(at#col) + 0.5;
        let y = Int32.toFloat64(m#height - 1 - at#row) + 0.5;
        let dt = 1.0 / Int32.toFloat64(fps());
        let settle = Buildup.impactOf(show) |> Option.map(ip -> fst(ip) + plan#timing#shake) |> Option.getWithDefault(show#done);
        let walkFrom = Float64.max(show#done, settle) + r#walkPause;
        let speed = plan#groundFlowH / TownCamera.screenPerMeterAt(lens, eye, groundZ, 0.5);
        let route = Route.make(m#height, plan#path, speed, walkFrom);
        let total = route#endAt + plan#stopSec / 2.0 + plan#holdSec + plan#timing#hitstopSec;
        let n = Float64.round(total * Int32.toFloat64(fps())) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let story = Vector.range(0, n) |> Vector.map(f -> Buildup.storyTime(show, Int32.toFloat64(f) * dt));
        let leader = story |> Vector.map(t -> fst(Route.pointAt(route, Route.distanceAt(route, t))));
        let half = Float64.round(plan#stopSec / 2.0 / dt) |> Float64.tryToInt32 |> Option.getWithDefault(10);
        let followX = Route.hannSmooth(half, Vector.map(fst, leader));
        let followY = Route.hannSmooth(half, Vector.map(snd, leader));
        let moving = story |> Vector.map(t -> if (Route.isMoving(route, t)) dt else 0.0);
        // WhyNot: 引きを時刻でなく輪の届いた割合で決める — 輪が加速して画面の外へ出る前にカメラが追いつくように
        let reach = (t: Float64) -> Float64.pow(base = Num.clamp(0.0, 1.0, (t - plan#timing#startDelay) / r#buildSec), 1.0 / r#curve);
        let smooth = (u: Float64) -> { let v = Num.clamp(0.0, 1.0, u); v * v * (3.0 - 2.0 * v) };
        let pulled = story |> Vector.map(t -> r#zoomFrom + (r#zoomTo - r#zoomFrom) * smooth(reach(t) / r#zoomLead));
        let follow = story |> Vector.map(t -> smooth((t - walkFrom) / r#followSec));
        let zoom = Vector.zip(pulled, follow) |> Vector.map(kw -> { let (k, w) = kw; k + (r#walkZoom - k) * w });
        let aimOf = (k: Float64) -> y + r#aimNorth * (k - r#zoomFrom) / Float64.max(0.001, r#zoomTo - r#zoomFrom);
        let blend = (a: Float64, b: Float64, w: Float64) -> a + (b - a) * w;
        let camX = Vector.range(0, n) |> Vector.map(f -> blend(x, Vector.get(f, followX), Vector.get(f, follow)));
        let camY = Vector.range(0, n) |> Vector.map(f -> blend(aimOf(Vector.get(f, pulled)), Vector.get(f, followY), Vector.get(f, follow)));
        { route = route, cameraX = camX, cameraY = camY,
          cameraHeight = Vector.map(_ -> groundZ, zoom), clock = Vector.scanLeft((acc, v) -> acc + v, 0.0, moving), frames = n,
          feetDepth = TownCamera.depthAt(lens, eye, groundZ, plan#feetV), eye = eye, lens = lens, groundZ = groundZ, zoom = zoom,
          stand = Some((x, y)), walkFrom = walkFrom, feetZ = (_, _) -> groundZ }

    /// 立ったままの台本の i 人目の位置と向き。歩き出す前は横並びで正面、歩き出したら 0.9 秒かけて横並びの位置から道の 1 マスずつ後ろへ寄せる（先頭はそのまま道を行く）。
    def formationAt(c: (Float64, Float64), spread: Float64, route: Route.Route, walkFrom: Float64, t: Float64, s: Float64, i: Int32): ((Float64, Float64), Dir) =
        let ((rx, ry), d) = Route.pointAt(route, s - Int32.toFloat64(i));
        let (sx, sy) = standAt(c, spread, i);
        let u = Num.clamp(0.0, 1.0, (t - walkFrom) / 0.9);
        let w = if (i == 0) 1.0 else u * u * (3.0 - 2.0 * u);
        if (t < walkFrom) ((sx, sy), Dir.South) else ((sx + (rx - sx) * w, sy + (ry - sy) * w), d)

    /// 立ったままの隊列の i 人目の位置（先頭が真ん中・2 人目が左・3 人目が右で、後ろの 2 人は少し奥）。
    def standAt(c: (Float64, Float64), spread: Float64, i: Int32): (Float64, Float64) =
        let side = if (i == 0) 0.0 else if (Int32.modulo(i, 2) == 1) 0.0 - spread * Int32.toFloat64((i + 1) / 2) else spread * Int32.toFloat64((i + 1) / 2);
        (fst(c) + side, snd(c) + (if (i == 0) 0.0 else 0.3))

    /// 向き → 帯の中の段（dirs の字の順・"nes" なら 0 背中・1 右・2 正面）と左右反転（dirs に w が無ければ左は右の反転）。
    def dirCell(dirs: String, d: Dir): (Int32, Bool) =
        let letter = match d {
            case Dir.North => "n"
            case Dir.East  => "e"
            case Dir.South => "s"
            case Dir.West  => "w"
        };
        let flip = d == Dir.West and not String.contains(substr = "w", dirs);
        (String.indexOf(substr = if (flip) "e" else letter, dirs) |> Option.getWithDefault(0), flip)

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

    /// 読み込んだ物（地図・台本・町・土ぼこりの絵・演出の部品・毎コマの決まり・歩きながら替える Look）。
    pub type alias Setup = { map = TownMap, plan = Plan, res = Res, dust = Texture3d.Texture3d, show = Show, track = Track,
                             schedule = Option[TownLook.Schedule] }

    /// 地図・台本・町を読み、演出の部品と毎コマの決まりを作る。look = 見た目のつまみ（台本に timeOfDay があれば歩き出す前の昼にも使う）・
    /// tweak = 台本の timeOfDay の Look に掛ける差し替え（look に掛けた物と同じ）。台本は BUILDUP（既定 assets/buildup.json）・地図は台本の map。
    /// WALK_MAP（地図の Doc）があれば、その地図の walk の台本で、はじめから全部出来ている場面を歩く（look の Look のまま）。
    pub def setup(look: TownScene.Look, tweak: TownScene.Look -> TownScene.Look): Result[String, Setup] \ IO =
        setupOf(look, tweak, sourceFromEnv())

    /// 場面の元。Plan = 町が出来ていく台本の Doc（buildup の形）・MapWalk = 地図の Doc の walk.path で歩くだけ。
    pub enum Source with Eq, ToString {
        case Plan(String)
        case MapWalk(String)
    }

    /// 環境変数の場面の元（WALK_MAP があれば MapWalk・無ければ BUILDUP の台本・既定 assets/buildup.json）。
    pub def sourceFromEnv(): Source \ IO =
        let walkMap = System.getenv("WALK_MAP");
        let planPath = System.getenv("BUILDUP");
        if (not (Object.isNull(walkMap) or walkMap == "")) Source.MapWalk(walkMap)
        else if (Object.isNull(planPath) or planPath == "") Source.Plan("assets/buildup.json")
        else Source.Plan(planPath)

    /// setup の、場面の元を渡す形。
    pub def setupOf(look: TownScene.Look, tweak: TownScene.Look -> TownScene.Look, src: Source): Result[String, Setup] \ IO =
        match src {
            case Source.Plan(planPath)   => setupPlan(look, tweak, planPath)
            case Source.MapWalk(mapPath) => setupMapWalk(look, mapPath)
        }

    /// 地図 mapPath の walk.path で歩くだけの場面（出来ていく演出なし）。
    def setupMapWalk(look: TownScene.Look, mapPath: String): Result[String, Setup] \ IO =
        (run { TownMap.load("step", mapPath) |> Result.flatMap(m -> StageFx.load(mapPath) |> Result.map(fx -> (m, fx))) } with Fs.FileRead.runWithIO)
            |> Result.flatMap(mf -> { let (m, fx) = mf; m#walkPath |> Option.toOk("${mapPath}: walk.path が無い") |> Result.map(pw -> (m, fx, pw)) })
            |> Result.flatMap(mfp -> {
                let (m, fx, pw) = mfp;
                let p = Buildup.planOfMap(m, mapPath, pw);
                forM (
                    res <- TownScene.loadWithFx(m, fx, look, None, p#party |> List.filterMap(w -> w#idleStrip));
                    d <- Buildup.dustTexture()
                ) yield { map = m, plan = p, res = res, dust = d, show = Buildup.alreadyBuilt(p#timing, d),
                          track = pathTrackOf(m, look, p, pw#followZoom), schedule = None }
            })

    def setupPlan(look: TownScene.Look, tweak: TownScene.Look -> TownScene.Look, planPath: String): Result[String, Setup] \ IO =
        (run { Buildup.loadPlan(planPath) |> Result.flatMap(p -> TownMap.load("step", p#map) |> Result.map(m -> (m, p))) } with Fs.FileRead.runWithIO)
            |> Result.flatMap(mp -> {
                let (m, p) = mp;
                TownScene.load(m, look, Some(m#walk#col), p#party |> List.flatMap(w -> w#strip :: Option.toList(w#idleStrip))) |> Result.map(res -> (m, p, res))
            })
            |> Result.flatMap(mpr -> { let (m, p, res) = mpr; Buildup.dustTexture() |> Result.map(d -> (m, p, res, d)) })
            |> Result.flatMap(all -> {
                let (m, p, res, d) = all;
                let make = (front: Buildup.Front) -> Buildup.make(p#timing, front, m, res#town#quads, res#town#boards, name -> Map.get(name, res#materials), TownScene.boardBillboard(res), d);
                match p#radial {
                    case Some(r) =>
                        let at = List.head(p#path) |> Option.getWithDefault({ col = 13, row = 15, wait = 0.0 });
                        make(Buildup.radialFront(p#timing, at#col, at#row, m#width, m#height, r))
                            |> Result.map(show -> {
                                let tr = standTrackOf(m, look, p, r, show);
                                { map = m, plan = p, res = res, dust = d, show = show, track = tr, schedule = scheduleOf(p, tweak, tr) }
                            })
                    case None =>
                        let tr = trackOf(m, look, p);
                        make(walkFront(m, p, tr)) |> Result.map(show -> { map = m, plan = p, res = res, dust = d, show = show, track = tr, schedule = scheduleOf(p, tweak, tr) })
                }
            })

    def scheduleOf(p: Plan, tweak: TownScene.Look -> TownScene.Look, tr: Track): Option[TownLook.Schedule] \ IO =
        p#timeOfDay |> Option.map(t -> (run { TownLook.loadSchedule(t, tweak) } with Fs.FileRead.runWithIO) |> TownLook.withWalkSpeed(walkSpeedOf(tr#route)))

    /// 道を歩く速さ（マス/秒・待ちの間を除く）。
    pub def walkSpeedOf(route: Route.Route): Float64 =
        let pairs = List.zip(route#knots, List.drop(1, route#knots));
        let (dist, secs) = pairs |> List.foldLeft((acc, ab) -> {
            let ((t0, s0), (t1, s1)) = ab;
            if (s1 > s0) (fst(acc) + s1 - s0, snd(acc) + t1 - t0) else acc
        }, (0.0, 0.0));
        if (secs > 0.0) dist / secs else 0.0

    /// コマ f の Look（台本に timeOfDay があれば先頭の行で替える・無ければ読み込んだ Look のまま）。
    pub def lookAt(st: Setup, f: Int32): TownScene.Look =
        match st#schedule {
            case None    => st#res#look
            case Some(s) => TownLook.atRow(s, leaderRowAt(st, f))
        }

    /// コマ f の先頭の地図の行（マスの真ん中で整数・その間はなめらかに）。
    // WhyNot: 行を floor で整数に丸めない — 1 マス歩くごとに Look が段で跳ねる。
    def leaderRowAt(st: Setup, f: Int32): Float64 =
        let t = Buildup.storyTime(st#show, Int32.toFloat64(f) / Int32.toFloat64(fps()));
        let y = snd(fst(Route.pointAt(st#track#route, Route.distanceAt(st#track#route, t))));
        Int32.toFloat64(st#map#height) - 0.5 - y

    /// 歩く台本の前線（先頭の lead 行先の行が出来る）。
    def walkFront(m: TownMap, p: Plan, tr: Track): Buildup.Front =
        let dt = 1.0 / Int32.toFloat64(fps());
        let leaderRows = Vector.range(0, tr#frames) |> Vector.map(f -> {
            let t = Int32.toFloat64(f) * dt;
            (t, Int32.toFloat64(m#height) - 0.5 - snd(fst(Route.pointAt(tr#route, Route.distanceAt(tr#route, t)))))
        });
        { cellTime = (_c: Int32, r: Int32) -> Buildup.rowTimeOf(p#timing, leaderRows, r), monumentAt = None, pace = _ -> 1.0 }

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
        let look = lookAt(st, f);
        let res = TownScene.withCamera(TownScene.withLook(st#res, look), TownCamera.cameraAt(st#track#lens, look#far, eyeAt(st, look, f)), size);
        let plan = st#plan;
        let show = st#show;
        let tr = st#track;
        let snap = (v: Float64) -> if (look#snapToTexels) TownCamera.snapToTexel(v) else v;
        let dt = 1.0 / Int32.toFloat64(fps());
        let t = Buildup.storyTime(show, Int32.toFloat64(f) * dt);
        let route = tr#route;
        let s = Route.distanceAt(route, t);
        let walking = Route.isMoving(route, t);
        let spread = plan#radial |> Option.map(r -> r#spread) |> Option.getWithDefault(0.95);
        let clock = Vector.nth(f, tr#clock) |> Option.getWithDefault(0.0);
        let walkFrame = Int32.modulo(Float64.floor(clock / plan#frameSec) |> Float64.tryToInt32 |> Option.getWithDefault(0), 4);
        let members = plan#party |> List.mapWithIndex((i, w) -> {
            let ((x, y), d0) = tr#stand |> Option.map(c -> formationAt(c, spread, route, tr#walkFrom, t, s, i))
                |> Option.getWithDefault(Route.pointAt(route, s - Int32.toFloat64(i)));
            let d = if (not walking and t >= route#endAt) plan#endFace else d0;
            let (row, flip) = dirCell(w#dirs, d);
            let pose = if (walking) { strip = w#strip, frame = walkFrame, perDir = 4, stretch = 1.0 } else idlePose(plan, w, i, t);
            TownScene.walkerBoardFrames(res, pose#strip, w#tint, row, pose#perDir, pose#frame, flip, pose#stretch, snap(x), snap(y), tr#feetZ(x, y))
        }) |> List.filterMap(identity);
        // WhyNot: 広場のにぎやかしを建物と一緒に出さない — 記念碑の揺れと跳ねに重なって読めない。揺れが収まってから 1 つずつ落とす
        let decorFrom = Buildup.impactOf(show) |> Option.map(ip -> fst(ip) + show#timing#shake) |> Option.getWithDefault(show#done);
        let decor = TownScene.decorBoards(res, t, i -> Buildup.boardDropAt(show, t, decorFrom + 0.1 * Int32.toFloat64(i)));
        let decorShadows = decor |> List.filterMap(snd);
        let eye = eyeAt(st, look, f);
        let camera = TownCamera.cameraAt(tr#lens, look#far, eye);
        let (leaderX, leaderY0) = fst(Route.pointAt(route, s));
        let leaderY = snap(leaderY0);
        let leaderZ = tr#feetZ(leaderX, leaderY0);
        let focus = Num.sqrt((leaderY - eye#z) * (leaderY - eye#z) + (eye#height - leaderZ) * (eye#height - leaderZ));
        let textures = st#dust :: res#textures;
        let partyBoards = List.map(fst, members);
        let partyShadows = List.flatMap(snd, members);
        let at = (v: Vector[Float64], fallback: Float64) -> Vector.nth(f, v) |> Option.getWithDefault(fallback);
        let center = (at(tr#cameraX, leaderX), at(tr#cameraY, leaderY0), at(tr#cameraHeight, tr#groundZ));
        if (t >= show#done)
            ({ time = t | TownScene.sceneWith(res, camera, size, res#group :: Nil, List.flatten(TownScene.staticBoards(res) :: partyBoards :: List.map(fst, decor) :: Nil),
                                              List.append(partyShadows, decorShadows), textures) } |> TownScene.withStageFx(res, t, center), focus)
        else {
            let fr = Buildup.frameAt(show, t);
            let contacts = fr#contacts |> List.map(c -> {
                let (p, w, k) = c;
                TownScene.contactInstance(res#contactMesh, res#contactMaterial, p#x, p#z, p#y, w * k)
            });
            let (settledGroup, loose) = groupOf(fr#settled);
            ({ time = t | TownScene.sceneWith(res, camera, size, show#fixed :: settledGroup :: Nil, List.flatten(fr#billboards :: partyBoards :: List.map(fst, decor) :: Nil),
                                 List.flatten(fr#moving :: loose :: contacts :: partyShadows :: decorShadows :: Nil), textures) }, focus)
        }

    /// コマ f の目の位置（ならした追う点・引き・遅れて追う高さ・揺れ）。
    def eyeAt(st: Setup, look: TownScene.Look, f: Int32): TownCamera.Eye =
        let tr = st#track;
        let snap = (v: Float64) -> if (look#snapToTexels) TownCamera.snapToTexel(v) else v;
        let t = Buildup.storyTime(st#show, Int32.toFloat64(f) / Int32.toFloat64(fps()));
        let at = (v: Vector[Float64], fallback: Float64) -> Vector.nth(f, v) |> Option.getWithDefault(fallback);
        let pull = at(tr#zoom, 1.0);
        { x = snap(at(tr#cameraX, tr#eye#x)), z = snap(at(tr#cameraY, 0.0) - tr#feetDepth * pull),
          height = tr#groundZ + (tr#eye#height - tr#groundZ) * pull + (at(tr#cameraHeight, tr#groundZ) - tr#groundZ) + Buildup.shakeAt(st#show, t) }

    /// 場面に後がけを掛けた、CPU で描く 1 枚の中身。overlay = 後がけの後に重ねる 2D の絵（白飛びの白い四角）。
    pub def fullSceneOf(look: TownScene.Look, focus: Float64, flash: Float64, overlay: List[Render.PlacedItem], scene: Scene3d.Scene3dCmd): HeadlessRender.Scene =
        let built = PostStack.build({ size = design(), clear = Color.rgb(0.0, 0.0, 0.0), world = TownScene.items(scene) }, TownScene.postFlashAt(look, focus, scene#time, flash, design()#x));
        let specs = Render.passSpecsOf(_ -> None, built#plan)#specs
            |> List.map(sp -> { name = sp#name, clear = sp#clear, drawables = sp#drawables, polygons = sp#polygons, surfaces = sp#surfaces, scenes = sp#scenes, target = sp#target });
        let soft = Render.softSceneOf(_ -> None, built#present :: overlay);
        { passes = specs, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces,
          scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }

    pub def pad4(i: Int32): String = String.padLeft(4, '0', Int32.toString(i))

    /// 台本の毎コマの先頭の行を 1 行ずつ出す（"row <コマ 1 から> <行>"・絵は描かない。動画に時刻のラベルを入れる時に読む）。
    pub def leaderRows(): Unit \ IO =
        let look = run { TownLook.loadOr(Video.lookPath()) } with Fs.FileRead.runWithIO;
        match setup(look, identity) {
            case Err(why) => bug!("[hd2d_town] 町を組めない: ${why}")
            case Ok(st)   => List.range(0, st#track#frames) |> List.forEach(f -> println("row ${Int32.toString(f + 1)} ${Float64.toString(leaderRowAt(st, f))}"))
        }

    /// 町が出来ていく動画のコマを書く（LOOK = 見た目のつまみ・既定 assets/town.json・FRAMES_DIR = 書く所・既定 debug/build_frames・FRAME_STEP = FRAME_FROM から何コマおきに描くか）。
    pub def frames(): Unit \ IO =
        let look = run { TownLook.loadOr(Video.lookPath()) } with Fs.FileRead.runWithIO;
        let outDir = { let v = System.getenv("FRAMES_DIR"); if (Object.isNull(v) or v == "") "debug/build_frames" else v };
        match setup(look, identity) {
            case Err(why) => bug!("[hd2d_town] 町を組めない: ${why}")
            case Ok(st)   =>
                let tr = st#track;
                let scale = envInt("SCALE", 4);
                let first = envInt("FRAME_FROM", 1);
                let last = Int32.min(tr#frames, envInt("FRAME_TO", tr#frames));
                let step = Int32.max(1, envInt("FRAME_STEP", 1));
                let atlas = HeadlessFont.buildUiAtlas("assets/Xolonium-Regular.ttf", "assets/Xolonium-Regular.ttf");
                let cfg = { design = design(), scale = scale, outDir = outDir, fontTtf = "assets/Xolonium-Regular.ttf", fontAtlas = atlas,
                            frameW = 320 * scale, frameH = 180 * scale | HeadlessRender.defaults() };
                println("[hd2d_town] 町が出来ていく動画: コマ ${Int32.toString(tr#frames)}（${Float64.toString(Int32.toFloat64(tr#frames) / 30.0)} 秒）・" +
                        "部品 ${Int32.toString(Vector.length(st#show#pieces))}・全部出来る ${Float64.toString(st#show#done)} 秒・先頭が止まる ${Float64.toString(tr#route#endAt)} 秒");
                region rc {
                    let cache = Ref.fresh(rc, { grouping = startGrouping(st), totalNs = 0i64, maxNs = 0i64, listed = 0 });
                    List.range(first, last + 1) |> List.filter(f -> Int32.modulo(f - first, step) == 0) |> List.forEach(f -> {
                        let name = "f${pad4(f)}";
                        if (new File("${outDir}/${name}.png").exists()) ()
                        else {
                            let (scene, focus) = shotAt(st, cachedGroup(cache, f - 1), design(), f - 1);
                            HeadlessRender.renderPngFull(cfg, fullSceneOf(lookAt(st, f - 1), focus, Buildup.flashAt(st#show, Int32.toFloat64(f - 1) / Int32.toFloat64(fps())), Nil, scene), name);
                            println("[hd2d_town] ${outDir}/${name}.png（先頭の行 ${Float64.toString(leaderRowAt(st, f - 1))}）")
                        }
                    });
                    let c = Ref.get(cache);
                    println("[hd2d_town] staticGroup のまとめ直し ${Int32.toString(c#grouping#regroups)} 回・合計 ${Float64.toString(Int64.toFloat64(c#totalNs) / 1000000.0)} ms・" +
                            "最大 ${Float64.toString(Int64.toFloat64(c#maxNs) / 1000000.0)} ms・最後の集まりの物 ${Int32.toString(c#listed)} 個")
                }
        }
}
