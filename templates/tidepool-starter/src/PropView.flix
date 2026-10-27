// PropView — 盤に乗る物の形（小石・海藻・イソギンチャク・巻き貝・流木・魚・ヤドカリ）。
// 光は左上から来るので、落ち影はどれも右下へ落とし、受光は左上に置く。
// 沈んでいる物は描く順で水の下に入る（View がこの部品を高さごとに呼ぶ）ので、ここでは水の色を塗らない。
// 座標は盤の座標（Layout.centerOf）。海藻・イソギンチャク・魚・カサガイは遊びに効かない飾りで、置き場所はマスのハッシュで決める。
mod PropView {

    use fge::{Color, DrawCmd, DualGrid, RawDraw, Render, Sway, Vec2}

    /// 動く物 1 つ: 規則の上のマスと、今描く置き場所（1 手の動きの間は 2 マスの間）。
    pub type alias Piece = { cell = Board.Cell, at = Vec2.Vec2 }

    pub type alias In = {
        t = Float64,
        board = Board.Board,
        // 今、水に沈んでいるマス。
        wet = Set[Board.Cell],
        pebbles = List[Piece],
        driftwood = List[Piece],
        // ヤドカリの置き場所・大きさ（巻き貝へ入ると 0 へ縮む）・傾き（流されると回る）。
        crab = { at = Vec2.Vec2, scale = Float64, turn = Float64 },
        theme = ThemeDoc.Doc
    }

    def isWet(w: In, c: Board.Cell): Bool = Set.memberOf(c, w#wet)

    def hashOf(c: Board.Cell, channel: Int32): Float64 =
        let (x, y) = c;
        DualGrid.hash(x, y, channel)

    /// マスの中で少しずらした置き場所（どの物もマスの真ん中にそろうと作り物に見える）。
    def spotOf(c: Board.Cell, spread: Float64): Vec2.Vec2 =
        Vec2.add(Layout.centerOf(c), { x = (hashOf(c, 1) - 0.5) * spread, y = (hashOf(c, 2) - 0.5) * spread })

    def ellipse(center: Vec2.Vec2, radii: Vec2.Vec2, color: Color, alpha: Float64): Render.PlacedItem =
        RawDraw.ellipseAt(center, radii, color, 0) |> Render.overItem(Render.fade(alpha))

    def shadowOf(w: In, center: Vec2.Vec2, radii: Vec2.Vec2, alpha: Float64): Render.PlacedItem =
        RawDraw.ellipseAt(center, radii, ThemeDoc.rec(w#theme)#shadow, 0)
            |> Render.overItem(item -> item |> Render.fade(alpha) |> Render.blended(DrawCmd.BlendMode.Multiply))

    def line(a: Vec2.Vec2, b: Vec2.Vec2, width: Float64, color: Color, alpha: Float64): Render.PlacedItem =
        RawDraw.lineSeg(a, b, width, color, 0) |> Render.overItem(Render.fade(alpha))

    /// 楕円の輪（細い線を周に並べる）。
    def ring(center: Vec2.Vec2, radii: Vec2.Vec2, width: Float64, color: Color, alpha: Float64): List[Render.PlacedItem] =
        let n = 32;
        let at = k -> { let a = Int32.toFloat64(k) / Int32.toFloat64(n) * Vec2.tau();
                        { x = center#x + Vec2.cos(a) * radii#x, y = center#y + Vec2.sin(a) * radii#y } };
        List.range(0, n) |> List.map(k -> line(at(k), at(k + 1), width, color, alpha))

    // ── 高さごとに乗っている物 ──

    /// 飾りを置くマス（channel ごとに 3 割ほど。ヤドカリと巻き貝のマスは避ける）。
    def decorCells(w: In, channel: Int32, maxHeight: Int32): List[Board.Cell] =
        Board.cells(w#board) |> List.filter(c -> hashOf(c, channel) < 0.3 and Board.heightAt(c, w#board) <= maxHeight
            and c != w#board#goal and c != w#board#crab)

    /// 高さ level のマスに乗った物。浮いていない流木もここ。
    pub def restingOn(w: In, level: Int32): List[Render.PlacedItem] =
        let here = c -> Board.heightAt(c, w#board) == level;
        let pebbles = w#pebbles |> List.filter(p -> here(p#cell)) |> List.flatMap(p -> pebble(w, p));
        let weeds = decorCells(w, 200, 1) |> List.filter(here) |> List.flatMap(c -> seaweed(w, c));
        let anemones = decorCells(w, 210, 2) |> List.filter(c -> here(c) and hashOf(c, 200) >= 0.3) |> List.flatMap(c -> anemone(w, c));
        let wood = w#driftwood |> List.filter(p -> here(p#cell) and not isWet(w, p#cell)) |> List.flatMap(p -> driftwood(w, p, false));
        let goal = if (here(w#board#goal)) bigShell(w, w#board#goal) else Nil;
        limpets(w, level) ::: weeds ::: pebbles ::: anemones ::: wood ::: goal

    /// 潮の満ち引きで濡れる高さの岩に付くカサガイ（磯の岩を「物」として読ませる細かい手がかり）。
    /// 置き場所は座標のハッシュで決め、どこにも保存しない。
    def limpets(w: In, level: Int32): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        if (level < 1 or level > 2) Nil
        else Board.cells(w#board) |> List.filter(c -> Board.heightAt(c, w#board) == level) |> List.flatMap(c ->
            List.range(0, 3) |> List.filter(k -> hashOf(c, 90 + k) < 0.3) |> List.flatMap(k -> {
                let at = Vec2.add(Layout.centerOf(c), { x = (hashOf(c, 100 + k) - 0.5) * 36.0, y = (hashOf(c, 110 + k) - 0.5) * 36.0 });
                let r = 2.8 + hashOf(c, 120 + k) * 1.6;
                let shellTone = Color.mix(theme#shell, theme#light, 0.15);
                shadowOf(w, Vec2.add(at, { x = 1.2, y = 1.5 }), { x = r, y = r * 0.85 }, 0.45)
                    :: ellipse(at, { x = r, y = r * 0.85 }, Color.mix(shellTone, theme#shadow, 0.3), 1.0)
                    :: ellipse(Vec2.add(at, { x = -0.4, y = -0.4 }), { x = r * 0.6, y = r * 0.5 }, shellTone, 1.0)
                    :: ellipse(Vec2.add(at, { x = -0.7, y = -0.7 }), { x = r * 0.22, y = r * 0.2 }, Color.mix(shellTone, theme#light, 0.5), 1.0)
                    :: Nil
            }))

    /// 小石: 落ち影 → 影の側の地 → 受光の側 → つや。
    def pebble(w: In, p: Piece): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let c = p#cell;
        let at = p#at;
        let radii = { x = 11.0 + hashOf(c, 3) * 3.0, y = 8.5 + hashOf(c, 4) * 2.0 };
        let stone = Color.mix(theme#cliff, theme#light, 0.42);
        shadowOf(w, Vec2.add(at, { x = 4.0, y = 5.0 }), radii, 0.5)
            :: ellipse(at, radii, Color.mix(stone, theme#shadow, 0.45), 1.0)
            :: ellipse(Vec2.add(at, { x = -1.6, y = -1.8 }), Vec2.mul(radii, 0.86), stone, 1.0)
            :: ellipse(Vec2.add(at, { x = -3.5, y = -3.2 }), Vec2.mul(radii, 0.42), Color.mix(stone, theme#light, 0.45), 0.75)
            :: Nil

    /// 海藻: 根元から先へ節をつなぐ。水の中では揺れて伸び、水が引くと寝てしおれる。
    def seaweed(w: In, c: Board.Cell): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let wet = isWet(w, c);
        let root = spotOf(c, 16.0);
        List.range(0, 4) |> List.flatMap(k -> {
            let seed = hashOf(c, 10 + k);
            let heading0 = seed * Vec2.tau();
            let segs = 6;
            let segLen = (if (wet) 4.2 else 2.6) + hashOf(c, 20 + k) * 1.6;
            let base = Color.mix(theme#weed, theme#shadow, if (wet) 0.1 else 0.4);
            let (_, _, items) = List.range(0, segs) |> List.foldLeft((acc, s) -> {
                let (p, heading, out) = acc;
                let bend = if (wet) Sway.wave(w#t, seed + Int32.toFloat64(s) * 0.12, 0.7) * 0.32 else 0.04;
                let h = heading + bend;
                let q = { x = p#x + Vec2.cos(h) * segLen, y = p#y + Vec2.sin(h) * segLen };
                let u = Int32.toFloat64(s) / Int32.toFloat64(segs);
                let color = Color.mix(base, theme#light, u * 0.28);
                (q, h, line(p, q, 3.4 - u * 2.2, color, 0.95) :: out)
            }, (root, heading0, Nil));
            List.reverse(items)
        })

    /// イソギンチャク: 水の中では触手を開き、水が引くと閉じて濡れた丸い塊になる。
    def anemone(w: In, c: Board.Cell): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let at = spotOf(c, 12.0);
        let body = theme#anemone;
        if (isWet(w, c)) {
            let n = 14;
            let tentacles = List.range(0, n) |> List.flatMap(k -> {
                let a = Int32.toFloat64(k) / Int32.toFloat64(n) * Vec2.tau() + Sway.wave(w#t, hashOf(c, k), 0.8) * 0.12;
                let len = 8.0 + Sway.wave(w#t, hashOf(c, 30 + k), 0.5) * 1.6;
                let a1 = { x = at#x + Vec2.cos(a) * 3.5, y = at#y + Vec2.sin(a) * 3.5 };
                let tip = { x = at#x + Vec2.cos(a) * len, y = at#y + Vec2.sin(a) * len };
                line(a1, tip, 2.0, Color.mix(body, theme#light, 0.25), 0.95)
                    :: RawDraw.circleAt(tip, 1.1, Color.mix(body, theme#light, 0.5), 0) :: Nil
            });
            shadowOf(w, Vec2.add(at, { x = 3.0, y = 4.0 }), { x = 8.0, y = 6.0 }, 0.35)
                :: List.append(tentacles,
                    ellipse(at, { x = 4.6, y = 4.2 }, Color.mix(body, theme#shadow, 0.25), 1.0)
                    :: ellipse(at, { x = 1.6, y = 1.4 }, Color.mix(body, theme#shadow, 0.6), 1.0) :: Nil)
        } else
            shadowOf(w, Vec2.add(at, { x = 3.0, y = 4.0 }), { x = 7.0, y = 5.5 }, 0.45)
                :: ellipse(at, { x = 6.0, y = 5.0 }, Color.mix(body, theme#shadow, 0.35), 1.0)
                :: ellipse(Vec2.add(at, { x = -1.0, y = -1.0 }), { x = 4.6, y = 3.8 }, body, 1.0)
                :: ellipse(Vec2.add(at, { x = -2.2, y = -2.0 }), { x = 1.4, y = 1.0 }, Color.mix(body, theme#light, 0.6), 0.8)
                :: Nil

    /// 巻き貝を真上から見た形: 大きい巻きから殻頂へ小さい巻きを重ね、右下に口を開ける。
    /// size は外側の巻きの半径。
    def whelk(w: In, at: Vec2.Vec2, size: Float64, tone: Color): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let band = Color.mix(tone, theme#wood, 0.55);
        let whorls = List.range(0, 5) |> List.flatMap(k -> {
            let s = Float64.pow(base = 0.7, Int32.toFloat64(k));
            let c = Vec2.add(at, { x = -size * 0.42 * (1.0 - s), y = -size * 0.36 * (1.0 - s) });
            let r = { x = size * s, y = size * 0.82 * s };
            ellipse(c, r, Color.mix(band, theme#shadow, 0.2), 1.0)
                :: ellipse(Vec2.add(c, { x = -size * 0.06 * s, y = -size * 0.06 * s }), Vec2.mul(r, 0.86),
                           Color.mix(tone, theme#light, 0.12 * Int32.toFloat64(k)), 1.0) :: Nil
        });
        let mouth = Vec2.add(at, { x = size * 0.45, y = size * 0.38 });
        List.append(whorls,
            ellipse(mouth, { x = size * 0.42, y = size * 0.3 }, Color.mix(tone, theme#anemone, 0.35), 1.0)
            :: ellipse(Vec2.add(mouth, { x = 1.0, y = 0.8 }), { x = size * 0.25, y = size * 0.16 }, Color.mix(theme#anemone, theme#shadow, 0.55), 1.0)
            :: ellipse(Vec2.add(at, { x = -size * 0.45, y = -size * 0.45 }), { x = size * 0.18, y = size * 0.1 }, theme#light, 0.55)
            :: Nil)

    /// ゴールの大きな巻き貝と、ゆっくり広がる目印の輪。
    def bigShell(w: In, c: Board.Cell): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let at = Layout.centerOf(c);
        let pulse = Float64.abs(Sway.wave(w#t, 0.0, 0.6));
        List.append(
            List.append(ring(at, { x = 22.0 + pulse * 3.0, y = 18.0 + pulse * 2.5 }, 1.4, theme#foam, 0.45 - pulse * 0.2),
                        shadowOf(w, Vec2.add(at, { x = 6.0, y = 7.0 }), { x = 17.0, y = 13.0 }, 0.55) :: Nil),
            whelk(w, at, 16.0, theme#shell))

    // ── 流木 ──

    /// 流木の輪郭（芯に沿って両側の点を並べた多角形・画面座標）。
    def driftwoodShape(center: Vec2.Vec2, angle: Float64, c: Board.Cell): List[Vec2.Vec2] =
        let n = 9;
        let half = 31.0;
        let axis = { x = Vec2.cos(angle), y = Vec2.sin(angle) };
        let side = { x = -axis#y, y = axis#x };
        let pointAt = (k, sign) -> {
            let s = Int32.toFloat64(k) / Int32.toFloat64(n - 1) * 2.0 - 1.0;
            let width = (5.2 - 1.6 * s * s) + (hashOf(c, 40 + k) - 0.5) * 1.6;
            Vec2.add(Vec2.add(center, Vec2.mul(axis, s * half)), Vec2.mul(side, sign * width))
        };
        List.append(List.range(0, n) |> List.map(k -> pointAt(k, 1.0)),
                    List.range(0, n) |> List.reverse |> List.map(k -> pointAt(k, -1.0)))

    /// 流木 1 本。浮いているときは揺れて濡れた色になり、水底に落ちる影が遠くへ離れる。
    def driftwood(w: In, p: Piece, afloat: Bool): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let c = p#cell;
        let bob = if (afloat) Sway.drift(w#t, hashOf(c, 5), { x = 1.6, y = 1.1 }) else Vec2.zero();
        let center = Vec2.add(p#at, bob);
        let angle = -0.38 + (if (afloat) Sway.wave(w#t, 0.3, 0.35) * 0.05 else 0.0);
        let shape = driftwoodShape(center, angle, c);
        let wood = if (afloat) Color.mix(theme#wood, theme#shadow, 0.3) else theme#wood;
        let shadowShift = if (afloat) { x = 11.0, y = 13.0 } else { x = 3.5, y = 4.5 };
        let shadow = { at = Vec2.zero(), item = RawDraw.polygon(shape |> List.map(v -> Vec2.add(v, shadowShift)), theme#shadow, 0)
            |> Render.fade(if (afloat) 0.28 else 0.5) |> Render.blended(DrawCmd.BlendMode.Multiply) };
        let axis = { x = Vec2.cos(angle), y = Vec2.sin(angle) };
        let side = { x = -axis#y, y = axis#x };
        let along = (s, off) -> Vec2.add(Vec2.add(center, Vec2.mul(axis, s * 31.0)), Vec2.mul(side, off));
        let lit = { at = Vec2.zero(), item = RawDraw.polygon(
            driftwoodShape(Vec2.add(center, Vec2.mul(side, -1.6)), angle, c) |> List.map(v ->
                Vec2.add(center, Vec2.mul(Vec2.sub(v, center), 0.78))), Color.mix(wood, theme#light, 0.3), 0) |> Render.fade(0.85) };
        let grain = List.range(0, 3) |> List.map(k -> {
            let off = (Int32.toFloat64(k) - 1.0) * 2.4;
            line(along(-0.8, off), along(0.75, off + 0.6), 0.8, Color.mix(wood, theme#shadow, 0.5), 0.7)
        });
        let knot = ellipse(along(0.25, 1.0), { x = 2.2, y = 1.6 }, Color.mix(wood, theme#shadow, 0.55), 0.9);
        let ripples = if (afloat)
            List.append(ring(center, { x = 36.0 + Sway.wave(w#t, 0.1, 0.8) * 1.5, y = 15.0 }, 1.0, theme#foam, 0.3),
                        ring(center, { x = 42.0 + Sway.wave(w#t, 0.6, 0.8) * 2.0, y = 19.0 }, 0.8, theme#foam, 0.16))
            else Nil;
        ripples ::: (shadow :: { at = Vec2.zero(), item = RawDraw.polygon(shape, wood, 0) } :: lit :: knot :: grain)

    /// 沈んだマスに浮いた流木（水の段の上に描く）。
    pub def floating(w: In): List[Render.PlacedItem] =
        w#driftwood |> List.filter(p -> isWet(w, p#cell)) |> List.flatMap(p -> driftwood(w, p, true))

    // ── 魚 ──

    /// 小さな魚の影。住みかのマスが沈んでいる間だけ、まわりをゆっくり回る。
    pub def fish(w: In): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        decorCells(w, 220, 2) |> List.filter(c -> isWet(w, c)) |> List.flatMap(c ->
            List.range(0, 2) |> List.flatMap(k -> {
                let phase = hashOf(c, 60 + k) * Vec2.tau();
                let speed = 0.5 + hashOf(c, 70 + k) * 0.3;
                let a = w#t * speed + phase;
                let home = Layout.centerOf(c);
                let at = { x = home#x + Vec2.cos(a) * 15.0, y = home#y + Vec2.sin(a) * 10.0 };
                let heading = { x = -Vec2.sin(a) * 15.0, y = Vec2.cos(a) * 10.0 } |> Vec2.normalized;
                let side = { x = -heading#y, y = heading#x };
                let wag = Sway.wave(w#t, hashOf(c, 80 + k), 3.0) * 1.4;
                let p = (fwd, sd) -> Vec2.add(Vec2.add(at, Vec2.mul(heading, fwd)), Vec2.mul(side, sd));
                let body = p(6.0, 0.0) :: p(3.0, 2.2) :: p(-2.0, 2.0) :: p(-5.0, 0.8 + wag * 0.3)
                    :: p(-5.0, -0.8 + wag * 0.3) :: p(-2.0, -2.0) :: p(3.0, -2.2) :: Nil;
                let tail = p(-4.5, wag * 0.4) :: p(-9.0, 2.6 + wag) :: p(-9.0, -2.6 + wag) :: Nil;
                let ink = Color.mix(theme#shadow, theme#weed, 0.2);
                let drawn = shape -> { at = Vec2.zero(), item = RawDraw.polygon(shape, ink, 0) |> Render.fade(0.6) };
                let shade = shape -> { at = Vec2.zero(), item = RawDraw.polygon(shape |> List.map(v -> Vec2.add(v, { x = 6.0, y = 8.0 })), theme#shadow, 0)
                    |> Render.fade(0.2) |> Render.blended(DrawCmd.BlendMode.Multiply) };
                shade(body) :: shade(tail) :: drawn(tail) :: drawn(body) :: Nil
            }))

    // ── ヤドカリ ──

    /// 主役のヤドカリ（朱）。背中に小さな巻き貝を背負い、右を向く。
    /// 立ち止まっていても目と脚がわずかに動く。
    pub def crab(w: In): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let center = w#crab#at;
        let at = Vec2.add(center, { x = -2.0, y = Sway.wave(w#t, 0.2, 1.3) * 0.6 });
        let red = theme#accent;
        let deep = Color.mix(red, theme#shadow, 0.45);
        let lit = Color.mix(red, theme#light, 0.35);
        let scale = 1.3;
        let p = (x, y) -> Vec2.add(at, { x = x * scale, y = y * scale });
        let step = Sway.wave(w#t, 0.0, 2.2) * 0.8;
        let legs = List.range(0, 3) |> List.flatMap(k -> {
            let fk = Int32.toFloat64(k);
            List.range(0, 2) |> List.flatMap(s -> {
                let sign = if (s == 0) 1.0 else -1.0;
                let hip = p(2.5 + fk * 2.6, sign * 3.0);
                let knee = p(1.5 + fk * 4.2 + step * sign, sign * (10.0 + fk * 0.6));
                let foot = p(4.0 + fk * 5.0 + step * sign, sign * (14.5 + fk * 0.4));
                line(hip, knee, 3.4, deep, 1.0) :: line(knee, foot, 2.7, deep, 1.0)
                    :: line(hip, knee, 1.8, red, 1.0) :: line(knee, foot, 1.3, red, 1.0) :: Nil
            })
        });
        let shadow = shadowOf(w, p(4.0, 6.0), { x = 18.0 * scale, y = 12.0 * scale }, 0.5);
        let shell = whelk(w, p(-6.0, 0.0), 10.5 * scale, Color.mix(theme#shell, theme#cliff, 0.25));
        let body =
            ellipse(p(7.5, 0.0), Vec2.mul({ x = 6.5, y = 5.6 }, scale), deep, 1.0)
            :: ellipse(p(7.0, -0.8), Vec2.mul({ x = 5.4, y = 4.4 }, scale), red, 1.0)
            :: ellipse(p(13.5, 4.8), Vec2.mul({ x = 5.4, y = 3.9 }, scale), deep, 1.0)
            :: ellipse(p(13.2, 4.2), Vec2.mul({ x = 4.6, y = 3.1 }, scale), red, 1.0)
            :: ellipse(p(12.2, 3.2), Vec2.mul({ x = 1.8, y = 1.0 }, scale), lit, 0.9)
            :: ellipse(p(12.5, -4.4), Vec2.mul({ x = 3.6, y = 2.7 }, scale), deep, 1.0)
            :: ellipse(p(12.3, -4.8), Vec2.mul({ x = 2.9, y = 2.1 }, scale), red, 1.0)
            :: ellipse(p(5.8, -2.6), Vec2.mul({ x = 2.2, y = 1.2 }, scale), lit, 0.8)
            :: Nil;
        let twitch = Sway.wave(w#t, 0.7, 0.9) * 0.5;
        let eyes = List.range(0, 2) |> List.flatMap(s -> {
            let sign = if (s == 0) 1.0 else -1.0;
            let tip = p(15.5, sign * (2.6 + twitch));
            line(p(10.5, sign * 1.2), tip, 1.3, red, 1.0)
                :: RawDraw.circleAt(tip, 1.9, theme#ink, 0)
                :: RawDraw.circleAt(Vec2.add(tip, { x = -0.4, y = -0.5 }), 0.5, theme#light, 0) :: Nil
        });
        (shadow :: List.append(legs, List.append(shell, List.append(body, eyes))))
            |> Render.scaledAllAround(w#crab#scale, center) |> Render.turnedAll(w#crab#turn, center)
}
