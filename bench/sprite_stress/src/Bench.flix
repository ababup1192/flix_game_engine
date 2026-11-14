// Bench — 2D の描画提出コストを before/after で比べるための負荷世界。
// 位置は (i, t) の純関数にしてある: 乱数や可変状態を混ぜると計測のたびに
// 描画量が揺れて、エンジン改修の差分と見分けが付かなくなるため。

mod Bench {
    use fge::{App, Color, DrawCmd, FontAtlas, PxSpriteAtlas, RawDraw, Render, RenderUtil}

    /// 描く物の組み方。
    /// Mixed = 半分が単色の箱・半分が同じ絵のスプライト・SDF の字が約 300 字。
    /// Kinds = 全部スプライト。tex 種類の絵を順に使い、alternateBlend なら Normal と Multiply を 1 個ごとに替える。
    pub enum Scenario {
        case Mixed
        case Kinds({ tex = Int32, alternateBlend = Bool })
    }

    /// つまみ。counts = 区間ごとの物の数・plan = 区間の段取り・hud = HUD の層を足すか。
    pub type alias Config = { scenario = Scenario, counts = Vector[Int32], plan = BenchRun.Plan, hud = Bool }

    /// kindItems = Kinds の絵ごとのスプライト（Normal の列と Multiply の列）。毎コマ名前の字を組み立てないように先に作る。
    pub type alias World = {
        t = Float64,
        config = Config,
        atlases = List[App.AtlasUpload],
        kindItems = (Vector[Render.Item], Vector[Render.Item]),
        progress = BenchRun.Run
    }

    /// つまみの表（n = 物の数のカンマ区切り・tex = 絵の種類・blend = normal / alt・frames = 測るコマ数・hud = 1 で HUD あり）を読む。
    /// tex か blend があれば Kinds、どちらも無ければ Mixed。
    pub def configOf(knobs: Map[String, String]): Config =
        let alternateBlend = Map.get("blend", knobs) == Some("alt");
        let kinds = Map.memberOf("tex", knobs) or Map.memberOf("blend", knobs);
        let scenario = if (kinds) Scenario.Kinds({ tex = Int32.max(1, BenchRun.intKnob("tex", 1, knobs)), alternateBlend = alternateBlend })
                       else Scenario.Mixed;
        let fallback = if (kinds) 1000 :: 5000 :: 20000 :: Nil else 500 :: 2000 :: 5000 :: 10000 :: Nil;
        let counts = BenchRun.intsKnob("n", fallback, knobs) |> List.toVector;
        { scenario = scenario, counts = counts,
          plan = BenchRun.planOf({ warmup = warmup(), frames = 300, segments = Vector.length(counts) }, knobs),
          hud = Map.get("hud", knobs) == Some("1") }

    pub def initialWorld(config: Config): World =
        let tex = match config#scenario {
            case Scenario.Kinds(k) => k#tex
            case Scenario.Mixed    => 0
        };
        let names = Vector.range(0, tex) |> Vector.map(k -> "kind_${k}");
        let normal = names |> Vector.map(name -> Render.sprite(name, zSprite()));
        { t = 0.0, config = config,
          atlases = Vector.toList(names) |> List.mapWithIndex((k, name) -> { texture = name, key = name, baked = kindPixels(k) }),
          kindItems = (normal, normal |> Vector.map(Render.blended(DrawCmd.BlendMode.Multiply))),
          progress = BenchRun.start() }

    // ── 区間の台本 ──

    /// 起動直後は JIT とアセット準備で dt が荒れるため、各区間の頭を捨てる。
    def warmup(): Int32 = 60

    def countOf(w: World): Int32 =
        let last = Vector.length(w#config#counts) - 1;
        if (last < 0) 0 else Vector.get(Int32.min(last, w#progress#segment), w#config#counts)

    def knobsOf(config: Config, segment: Int32): List[(String, String)] =
        let n = ("n", Int32.toString(Vector.get(segment, config#counts)));
        let hud = ("hud", if (config#hud) "1" else "0");
        match config#scenario {
            case Scenario.Mixed    => ("bench", BenchRun.quoted("sprite_stress")) :: ("scenario", BenchRun.quoted("mixed")) :: n :: hud :: Nil
            case Scenario.Kinds(k) =>
                ("bench", BenchRun.quoted("sprite_stress")) :: ("scenario", BenchRun.quoted("kinds")) :: n ::
                ("tex", Int32.toString(k#tex)) :: ("blend", BenchRun.quoted(if (k#alternateBlend) "alt" else "normal")) :: hud :: Nil
        }

    pub def step(emit: String -> Unit \ IO, frame: App.Frame, w: World): World \ IO =
        if (w#progress#done) w
        else { t = w#t + frame#dt,
               progress = BenchRun.advance(w#config#plan, emit, knobsOf(w#config), BenchRun.sampleOf(frame, 0.0), w#progress) | w }

    // ── 絵の種類 ──

    /// 絵 1 種類の 1 辺（画素）。
    def kindSide(): Int32 = 16

    /// k 番目の絵（縁 1 画素が透明・中は k で決まる 1 色）。ARGB・行優先。
    // WhyNot: PNG を assets に置かない — 256 枚の生成物が git に入る。起動の時に作れば絵の種類を増やしても足す物が無い。
    def kindPixels(k: Int32): PxSpriteAtlas.Baked =
        let side = kindSide();
        let channel = rate -> 64 + Int32.modulo(k * rate, 192);
        let argb = Int32.bitwiseOr(Int32.leftShift(255, 24),
                   Int32.bitwiseOr(Int32.leftShift(channel(53), 16), Int32.bitwiseOr(Int32.leftShift(channel(97), 8), channel(151))));
        let isEdge = i -> {
            let (x, y) = (Int32.modulo(i, side), i / side);
            x == 0 or y == 0 or x == side - 1 or y == side - 1
        };
        { side = side, regions = Map.empty(), pixels = Vector.range(0, side * side) |> Vector.map(i -> if (isEdge(i)) 0 else argb) }

    pub def atlases(w: World): List[App.AtlasUpload] = w#atlases

    // ── World → 絵 ──

    def zBox(): Int32 = 5
    def zSprite(): Int32 = 10
    def zText(): Int32 = 100

    pub def view(ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
        match w#config#scenario {
            case Scenario.Mixed    => List.append(movers(countOf(w), w#t), texts(ctx#atlas, w))
            case Scenario.Kinds(k) => kindSprites(k#alternateBlend, w#kindItems, countOf(w), w#t)
        }

    def movers(n: Int32, t: Float64): List[Render.PlacedItem] =
        List.range(0, n) |> List.map(i -> placedOf(i, t))

    /// i 番目は i 番目の絵（種類の数で折り返す）。alternateBlend なら奇数番目が Multiply。
    def kindSprites(alternateBlend: Bool, items: (Vector[Render.Item], Vector[Render.Item]), n: Int32, t: Float64): List[Render.PlacedItem] =
        let (normal, multiply) = items;
        let kinds = Vector.length(normal);
        List.range(0, n) |> List.map(i -> {
            let k = Int32.modulo(i, kinds);
            let item = if (alternateBlend and Int32.modulo(i, 2) == 1) Vector.get(k, multiply) else Vector.get(k, normal);
            { at = centerOf(i, t), item = item }
        })

    def fract(x: Float64): Float64 = x - Float64.floor(x)

    /// 軌道の半径・速さ・位相は黄金比の端数で i ごとにばらす。規則的な格子だと
    /// 同じ場所に重なって描画の仕事量が偏り、負荷として当てにならないため。
    def centerOf(i: Int32, t: Float64): { x = Float64, y = Float64 } =
        let fi = Int32.toFloat64(i);
        let radius = 14.0 + 128.0 * fract(fi * 0.61803);
        let angle = fi * 2.39996 + t * (0.4 + 1.6 * fract(fi * 0.2716));
        { x = 160.0 + RenderUtil.cosF(angle) * radius, y = 120.0 + RenderUtil.sinF(angle) * radius * 0.72 }

    def placedOf(i: Int32, t: Float64): Render.PlacedItem =
        if (Int32.modulo(i, 2) == 0)
            RawDraw.boxAt(centerOf(i, t), { x = 4.0, y = 4.0 }, colorOf(i / 2), zBox())
        else
            { at = centerOf(i, t), item = Render.sprite("flag", zSprite()) }

    def colorOf(k: Int32): Color =
        match Int32.modulo(k, 4) {
            case 0 => { r = 0.86, g = 0.30, b = 0.29 }
            case 1 => { r = 0.42, g = 0.72, b = 0.34 }
            case 2 => { r = 0.35, g = 0.55, b = 0.87 }
            case _ => { r = 0.91, g = 0.75, b = 0.32 }
        }

    /// HUD あり構成（hud = 1）の絵。withHudView 経由なので z は HUD の範囲
    /// （ZBand.hudBase 以上）へ持ち上がり、mergedByZ が範囲別 2 段階ソートに入る —
    /// 範囲が混ざってもスロット方式（counting sort）に乗り続けるかを HUD 無しとの A/B で見る。
    pub def hud(ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
        RawDraw.boxAt({ x = 160.0, y = 228.0 }, { x = 300.0, y = 16.0 },
            { r = 0.10, g = 0.10, b = 0.14 }, 0)
        :: { at = { x = 14.0, y = 222.0 },
             item = Render.textTinted("HUD SEG=${w#progress#segment + 1} N=${countOf(w)}",
                 ctx#atlas, 9.0, { r = 0.95, g = 0.85, b = 0.40 }, 1) }
        :: { at = { x = 200.0, y = 222.0 },
             item = Render.textTinted("BAND CHECK", ctx#atlas, 9.0,
                 { r = 0.60, g = 0.90, b = 0.60 }, 1) }
        :: Nil

    /// Float64 をそのまま補間すると桁が長すぎて字の数が揺れるため、小数 2 桁で切る。
    def fmt2(x: Float64): String =
        let cents = RenderUtil.floatToInt32(x * 100.0);
        let frac = Int32.modulo(cents, 100);
        let fracText = if (frac < 10) "0${frac}" else "${frac}";
        "${cents / 100}.${fracText}"

    /// SDF テキストの負荷は文字数で決まるので、毎フレームほぼ一定（約 300 文字）に固定する。
    def texts(atlas: FontAtlas, w: World): List[Render.PlacedItem] =
        let lines =
            "N=${countOf(w)} SEG=${w#progress#segment + 1}/${Vector.length(w#config#counts)} F=${w#progress#frameInSegment}" ::
            "T=${fmt2(w#t)}S SAMPLES=${List.length(w#progress#samples)}" ::
            "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 01" ::
            "PACK MY BOX WITH FIVE DOZEN LIQUOR JUGS 23456" ::
            "SPHINX OF BLACK QUARTZ JUDGE MY VOW 7890 ABCD" ::
            "HOW VEXINGLY QUICK DAFT ZEBRAS JUMP 4321 EFGH" ::
            "WALTZ BAD NYMPH FOR QUICK JIGS VEX 5678 IJKLM" ::
            "JACKDAWS LOVE MY BIG SPHINX OF QUARTZ 90 NOPQ" :: Nil;
        lines |> List.mapWithIndex((k, line) ->
            { at = { x = 4.0, y = 12.0 + 11.0 * Int32.toFloat64(k) },
              item = Render.textTinted(line, atlas, 9.0,
                                       { r = 0.92, g = 0.92, b = 0.95 }, zText()) })

    /// デスクトップとブラウザの入口が同じ App を組む。
    pub def app(emit: String -> Unit \ IO, config: Config): App.App[World, IO] =
        let base = App.make(initialWorld(config))
            |> App.addSystem(step(emit))
            |> BenchRun.withDiagnostics(config#plan)
            |> App.withSpriteAtlases(atlases)
            |> App.withView((ctx, w) -> checked_ecast(view(ctx, w)));
        if (config#hud) base |> App.withHudView((ctx, w) -> checked_ecast(hud(ctx, w))) else base
}
