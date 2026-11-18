// FinalCut — 町・炎・氷の場面を 1 本の通しのコマ番号で並べる台本（assets/final.json）と、場面の境目の白飛び（白い 2D の四角を α で重ねる）。
//   frames … 通しのコマを CPU で描く（debug/final_frames/f0001.png …）。FRAME_FROM・FRAME_TO・FRAME_STEP で範囲・書いたコマは飛ばす・要る場面だけ読む
mod FinalCut {
    use fge::{Color, DocJson, HeadlessFont, HeadlessRender, JsonCodec, RawDraw, Render, Vec2}
    use Util.Json.Json
    use BuildVideo.{Grouping, Setup, Source}

    import java.io.File
    import java.lang.System

    /// 場面 1 つ。source = 読む元・look = 見た目のつまみの Doc・start = 場面のどのコマから使うか（場面のコマ番号・0 から）・frames = 使うコマ数。
    pub type alias Shot = { name = String, source = Source, look = String, start = Int32, frames = Int32 }

    /// 台本。fadeIn = 白くなるコマ数（境目の前の場面の終わりに重ねる）・fadeOut = 白が消えるコマ数（後の場面の頭に重ねる）・
    /// fadeOutPower = 消え方の指数（α = (1 − u)^power）。
    pub type alias Cut = { shots = Vector[Shot], fadeIn = Int32, fadeOut = Int32, fadeOutPower = Float64 }

    def fps(): Int32 = BuildVideo.fps()

    def framesOfSec(sec: Float64): Int32 =
        Float64.round(sec * Int32.toFloat64(fps())) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    /// path の台本を読む。
    pub def load(path: String): Result[String, Cut] \ Fs.FileRead =
        DocJson.readJson(path) |> Result.mapErr(e -> "${path}: ${DocJson.describe(e)}")
            |> Result.flatMap(json -> JsonCodec.expectObject(json) |> Option.toOk("${path} がオブジェクトでない"))
            |> Result.flatMap(cutOf(path))

    /// 台本の Doc の中身から台本を作る（scenes の 1 件でも読めなければ Err）。
    pub def cutOf(path: String, o: Map[String, Json]): Result[String, Cut] =
        let shots = Map.get("scenes", o) |> Option.flatMap(JsonCodec.decodeList(shotOf)) |> Option.toOk("${path}: scenes が読めない");
        shots |> Result.map(xs -> { shots = List.toVector(xs), fadeIn = framesOfSec(JsonCodec.floatOr("fadeInSec", 0.8, o)),
                                    fadeOut = framesOfSec(JsonCodec.floatOr("fadeOutSec", 1.2, o)), fadeOutPower = JsonCodec.floatOr("fadeOutPower", 2.5, o) })

    /// scenes の 1 件（buildup か walkMap のどちらかが要る）。
    def shotOf(j: Json): Option[Shot] =
        JsonCodec.expectObject(j) |> Option.flatMap(o -> {
            let buildup = JsonCodec.stringOr("buildup", "", o);
            let walkMap = JsonCodec.stringOr("walkMap", "", o);
            let source = if (walkMap != "") Some(Source.MapWalk(walkMap)) else if (buildup != "") Some(Source.Plan(buildup)) else None;
            source |> Option.map(src -> { name = JsonCodec.stringOr("name", "", o), source = src, look = JsonCodec.stringOr("look", "assets/town.json", o),
                                          start = JsonCodec.intOr("start", 0, o), frames = JsonCodec.intOr("frames", 0, o) })
        })

    /// 通しのコマ数。
    pub def totalFrames(cut: Cut): Int32 = Vector.foldLeft((acc, s) -> acc + s#frames, 0, cut#shots)

    /// 場面 i の頭の通しのコマ番号。
    pub def startOf(cut: Cut, i: Int32): Int32 =
        Vector.take(i, cut#shots) |> Vector.foldLeft((acc, s) -> acc + s#frames, 0)

    /// 通しのコマ g → (場面の番号, 場面のコマ番号)。範囲の外は None。
    pub def locate(cut: Cut, g: Int32): Option[(Int32, Int32)] =
        if (g < 0) None else locateFrom(cut#shots, 0, g)

    def locateFrom(shots: Vector[Shot], i: Int32, g: Int32): Option[(Int32, Int32)] =
        Vector.nth(i, shots) |> Option.flatMap(s -> if (g < s#frames) Some((i, s#start + g)) else locateFrom(shots, i + 1, g - s#frames))

    /// 通しのコマ first から n コマに要る場面の番号（重なりなし・小さい順）。
    pub def shotsIn(cut: Cut, first: Int32, n: Int32): List[Int32] =
        List.range(first, first + n) |> List.filterMap(g -> locate(cut, g) |> Option.map(fst)) |> List.toSet |> Set.toList

    /// 通しのコマ g の白い四角の α（境目 b の前 fadeIn コマで 0 → 1・b から fadeOut コマで 1 → 0）。
    // WhyNot: 露出を足して白くしない — 場面の露出（霧 −2.0 段・炎は Standard）で白への届き方が変わり、同じ長さで白に届かない。
    pub def whiteAlpha(cut: Cut, g: Int32): Float64 =
        List.range(1, Vector.length(cut#shots)) |> List.map(i -> alphaNear(cut, startOf(cut, i), g)) |> List.foldLeft(Float64.max, 0.0)

    def alphaNear(cut: Cut, b: Int32, g: Int32): Float64 =
        let fin = Int32.max(1, cut#fadeIn);
        let fout = Int32.max(1, cut#fadeOut);
        if (g >= b - fin and g < b) Int32.toFloat64(g - (b - fin) + 1) / Int32.toFloat64(fin)
        else if (g >= b and g < b + fout) Float64.pow(base = 1.0 - Int32.toFloat64(g - b) / Int32.toFloat64(fout), cut#fadeOutPower)
        else 0.0

    /// 画面全体の白い四角（size = 描き物の大きさ・α 0 なら何も出さない）。
    pub def whiteCover(size: Vec2.Vec2, alpha: Float64): List[Render.PlacedItem] =
        if (alpha <= 0.0) Nil
        else Render.fadeAll(Float64.min(1.0, alpha), RawDraw.boxAt({ x = size#x / 2.0, y = size#y / 2.0 }, size, Color.rgb(1.0, 1.0, 1.0), 99999999) :: Nil)

    /// 場面 i を読む（look の Doc を読んで tweak を掛ける）。
    pub def loadShot(cut: Cut, tweak: TownScene.Look -> TownScene.Look, i: Int32): Result[String, Setup] \ IO =
        Vector.nth(i, cut#shots) |> Option.toOk("場面 ${Int32.toString(i)} が無い") |> Result.flatMap(s -> {
            let look = tweak(run { TownLook.loadOr(s#look) } with Fs.FileRead.runWithIO);
            BuildVideo.setupOf(look, tweak, s#source) |> Result.mapErr(why -> "${s#name}: ${why}")
        })

    /// indices の場面を読む（番号 → 読んだ物）。
    pub def loadShots(cut: Cut, tweak: TownScene.Look -> TownScene.Look, indices: List[Int32]): Result[String, Map[Int32, Setup]] \ IO =
        forM (xs <- indices |> List.map(i -> loadShot(cut, tweak, i) |> Result.map(st -> (i, st))) |> Result.sequence) yield List.toMap(xs)

    /// 通しのコマ g の (場面の番号, 場面のコマ番号, 読んだ物)。読んでいない場面なら None。
    pub def placeOf(cut: Cut, setups: Map[Int32, Setup], g: Int32): Option[(Int32, Int32, Setup)] =
        locate(cut, g) |> Option.flatMap(p -> { let (i, f) = p; Map.get(i, setups) |> Option.map(st -> (i, f, st)) })

    /// 台本の Doc（環境変数 FINAL・既定 assets/final.json）。
    pub def cutPath(): String \ IO =
        let v = System.getenv("FINAL");
        if (Object.isNull(v) or v == "") "assets/final.json" else v

    /// 場面ごとの通しのコマの区間を 1 行ずつ出す（"shot <名前> <頭のコマ 1 から> <終わりのコマ> <秒の頭> <秒の終わり>"）。
    pub def describe(cut: Cut): List[String] =
        List.range(0, Vector.length(cut#shots)) |> List.filterMap(i -> Vector.nth(i, cut#shots) |> Option.map(s -> {
            let a = startOf(cut, i);
            let b = a + s#frames;
            "shot ${s#name} ${Int32.toString(a + 1)} ${Int32.toString(b)} ${Float64.toString(Int32.toFloat64(a) / 30.0)} ${Float64.toString(Int32.toFloat64(b) / 30.0)}"
        }))

    /// 区間を出すだけ（絵は描かない）。
    pub def plan(): Unit \ IO =
        match (run { load(cutPath()) } with Fs.FileRead.runWithIO) {
            case Err(why) => bug!("[hd2d_town] 台本が読めない: ${why}")
            case Ok(cut)  =>
                describe(cut) |> List.forEach(println);
                println("total ${Int32.toString(totalFrames(cut))} ${Float64.toString(Int32.toFloat64(totalFrames(cut)) / 30.0)}")
        }

    /// 1 コマ描く時の持ち越し（直前の場面の番号と出来た物の集まり）。
    type alias Carry = { shot = Int32, grouping = Option[Grouping] }

    /// 通しのコマを CPU で描く（FRAMES_DIR = 書く所・既定 debug/final_frames）。
    pub def frames(): Unit \ IO =
        match (run { load(cutPath()) } with Fs.FileRead.runWithIO) {
            case Err(why) => bug!("[hd2d_town] 台本が読めない: ${why}")
            case Ok(cut)  => framesOf(cut)
        }

    def framesOf(cut: Cut): Unit \ IO =
        let outDir = { let v = System.getenv("FRAMES_DIR"); if (Object.isNull(v) or v == "") "debug/final_frames" else v };
        let total = totalFrames(cut);
        let scale = BuildVideo.envInt("SCALE", 4);
        let first = BuildVideo.envInt("FRAME_FROM", 1);
        let last = Int32.min(total, BuildVideo.envInt("FRAME_TO", total));
        let step = Int32.max(1, BuildVideo.envInt("FRAME_STEP", 1));
        let wanted = List.range(first, last + 1) |> List.filter(f -> Int32.modulo(f - first, step) == 0)
            |> List.filter(f -> not new File("${outDir}/f${BuildVideo.pad4(f)}.png").exists());
        let indices = wanted |> List.filterMap(f -> locate(cut, f - 1) |> Option.map(fst)) |> List.toSet |> Set.toList;
        describe(cut) |> List.forEach(line -> println("[hd2d_town] ${line}"));
        match loadShots(cut, identity, indices) {
            case Err(why)   => bug!("[hd2d_town] 場面を組めない: ${why}")
            case Ok(setups) =>
                let atlas = HeadlessFont.buildUiAtlas("assets/Xolonium-Regular.ttf", "assets/Xolonium-Regular.ttf");
                let cfg = { design = BuildVideo.design(), scale = scale, outDir = outDir, fontTtf = "assets/Xolonium-Regular.ttf", fontAtlas = atlas,
                            frameW = 320 * scale, frameH = 180 * scale | HeadlessRender.defaults() };
                region rc {
                    let carry = Ref.fresh(rc, { shot = -1, grouping = None });
                    wanted |> List.forEach(f -> placeOf(cut, setups, f - 1) |> Option.forEach(p -> drawOne(cfg, cut, carry, f, p)))
                }
        }

    def drawOne(cfg: HeadlessRender.RenderConfig, cut: Cut, carry: Ref[Carry, r], f: Int32, p: (Int32, Int32, Setup)): Unit \ {r, IO} =
        let (i, local, st) = p;
        let c = Ref.get(carry);
        let g0 = if (c#shot == i) c#grouping |> Option.getWithDefault(BuildVideo.startGrouping(st)) else BuildVideo.startGrouping(st);
        let (g1, loose) = BuildVideo.regroup(local, BuildVideo.settledAt(st, local), g0);
        Ref.put({ shot = i, grouping = Some(g1) }, carry);
        let (scene, focus) = BuildVideo.shotAt(st, _ -> (g1#group, loose), BuildVideo.design(), local);
        let white = whiteAlpha(cut, f - 1);
        let flash = Buildup.flashAt(st#show, Int32.toFloat64(local) / Int32.toFloat64(fps()));
        let name = "f${BuildVideo.pad4(f)}";
        HeadlessRender.renderPngFull(cfg, BuildVideo.fullSceneOf(BuildVideo.lookAt(st, local), focus, flash, whiteCover(BuildVideo.design(), white), scene), name);
        println("[hd2d_town] ${cfg#outDir}/${name}.png（場面 ${Int32.toString(i)} のコマ ${Int32.toString(local)}・白 ${Float64.toString(white)}）")
}
