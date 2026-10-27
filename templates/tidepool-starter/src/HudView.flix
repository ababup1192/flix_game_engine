// HudView — 右の板（題字と面・潮見表・手数と最少手数と貝殻・キーの絵）。
// 板は乾いた砂の色の紙で、盤の絵より手前の層（Layer.Hud）に置く。
// 潮見表の「次の手」は盤の上の先読みの水際と同じ色の破線で描き、表と盤をつなげて読ませる。
mod HudView {

    use fge::{Color, DrawCmd, FontAtlas, Num, RawDraw, Render, Sway, TextDraw, Vec2}

    /// cycle は面の満ち引きの表、moves は手数（= 面の初めからの t）、shells は今クリアしたら取れる貝殻の数。
    pub type alias In = {
        t = Float64,
        cycle = Vector[Int32],
        moves = Int32,
        parMoves = Int32,
        shells = Int32,
        level = Int32,
        name = String,
        theme = ThemeDoc.Doc
    }

    /// クリアと流されたの重ね（play の上）に要る値。age は今の状態になってからの秒、last は最後の面か。
    pub type alias Overlay = {
        t = Float64,
        age = Float64,
        phase = World.Phase,
        moves = Int32,
        parMoves = Int32,
        shells = Int32,
        last = Bool,
        theme = ThemeDoc.Doc
    }

    /// 板の左上と大きさ。
    def panelAt(): Vec2.Vec2 = { x = 470.0, y = 12.0 }

    def panelSize(): Vec2.Vec2 = { x = 158.0, y = 336.0 }

    def centerX(): Float64 = panelAt()#x + panelSize()#x / 2.0

    def left(): Float64 = panelAt()#x + 13.0

    def right(): Float64 = panelAt()#x + panelSize()#x - 13.0

    /// 潮見表の枠（左上・大きさ）。
    def chartAt(): Vec2.Vec2 = { x = left() + 2.0, y = 110.0 }

    def chartSize(): Vec2.Vec2 = { x = right() - left() - 4.0, y = 58.0 }

    /// 奥から手前へ積む部品の列。
    pub def hud(atlas: FontAtlas, w: In): List[List[Render.PlacedItem]] =
        panel(w) :: chart(w) :: shellRow(w#theme, { x = left() + 9.0, y = 270.0 }, w#shells) :: texts(atlas, w) :: keys(atlas, w) :: Nil

    def ink(w: In): Color = ThemeDoc.rec(w#theme)#ink

    /// 盤の先読みと同じ色を、明るい紙の上で読める濃さにした色。
    def forecastInk(w: In): Color = Color.mix(Layout.forecastColor(w#theme), ink(w), 0.35)

    def text(atlas: FontAtlas, w: In, s: String, size: Float64, at: Vec2.Vec2, alpha: Float64): Render.PlacedItem =
        { at = at, item = Render.textTinted(s, atlas, size, ink(w), 0) |> Render.fade(alpha) }

    def textRight(atlas: FontAtlas, w: In, s: String, size: Float64, rightX: Float64, y: Float64): Render.PlacedItem =
        text(atlas, w, s, size, { x = rightX - TextDraw.width(s, atlas, size), y = y }, 1.0)

    def textCentered(atlas: FontAtlas, w: In, s: String, size: Float64, y: Float64, alpha: Float64): Render.PlacedItem =
        text(atlas, w, s, size, { x = TextDraw.centerLeft(s, atlas, size, centerX()), y = y }, alpha)

    def line(a: Vec2.Vec2, b: Vec2.Vec2, width: Float64, color: Color, alpha: Float64): Render.PlacedItem =
        RawDraw.lineSeg(a, b, width, color, 0) |> Render.overItem(Render.fade(alpha))

    /// a→b を破線で引く（dash の長さで刻み、shift で刻みの頭をずらして流す）。
    pub def dashed(a: Vec2.Vec2, b: Vec2.Vec2, look: { width = Float64, dash = Float64, shift = Float64, color = Color }): List[Render.PlacedItem] =
        let len = Vec2.distanceTo(a, b);
        let dir = Vec2.normalized(Vec2.sub(b, a));
        let period = look#dash * 2.0;
        let count = Float64.ceil(len / period) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        List.range(-1, count + 1) |> List.filterMap(k -> {
            let s0 = Int32.toFloat64(k) * period + Num.wrapTo(period, look#shift);
            let head = Float64.max(0.0, s0);
            let tail = Float64.min(len, s0 + look#dash);
            if (tail <= head) None
            else Some(RawDraw.lineSeg(Vec2.add(a, Vec2.mul(dir, head)), Vec2.add(a, Vec2.mul(dir, tail)), look#width, look#color, 0))
        })

    def rule(w: In, y: Float64): Render.PlacedItem =
        line({ x = left(), y = y }, { x = right(), y = y }, 1.0, ink(w), 0.22)

    /// 板: 落ち影 → 紙 → 上から下へわずかに暗くなる階調 → 細い縁。
    def panel(w: In): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let at = panelAt();
        let size = panelSize();
        let inset = 6.0;
        { at = Vec2.add(at, { x = 4.0, y = 5.0 }),
          item = RawDraw.box(size, theme#shadow, 0) |> Render.rounded(9.0) |> Render.fade(0.45)
                    |> Render.blended(DrawCmd.BlendMode.Multiply) }
            :: { at = at, item = RawDraw.box(size, theme#panel, 0) |> Render.rounded(9.0)
                    |> Render.outlineA({ color = theme#ink, alpha = 0.25, width = 1.0 }) }
            :: { at = Vec2.add(at, { x = inset, y = inset }),
                 item = Render.vgrad({ x = size#x - inset * 2.0, y = size#y - inset * 2.0 },
                     { top = Color.mix(theme#panel, theme#light, 0.4), bottom = Color.mix(theme#panel, theme#shadow, 0.12) }, 0)
                     |> Render.fade(0.6) }
            :: rule(w, 80.0) :: rule(w, 222.0) :: rule(w, 290.0) :: Nil

    def cycleLength(w: In): Int32 = Int32.max(1, Vector.length(w#cycle))

    def topTide(w: In): Int32 = Int32.max(1, Vector.foldLeft(Int32.max, 0, w#cycle))

    def tideAt(w: In, step: Int32): Int32 = Vector.get(Int32.modulo(step, cycleLength(w)), w#cycle)

    /// 満ち引きの表の i 番目の点（潮見表の枠の中。i が表の長さなら右端 = 0 番目の潮位）。
    def pointOf(w: In, i: Int32): Vec2.Vec2 =
        let (at, size) = (chartAt(), chartSize());
        { x = at#x + Int32.toFloat64(i) / Int32.toFloat64(cycleLength(w)) * size#x,
          y = at#y + size#y - 6.0 - Int32.toFloat64(tideAt(w, i)) / Int32.toFloat64(topTide(w)) * (size#y - 14.0) }

    /// 潮見表: 6 手の周期の波形・水の面・今の針・針の残像（取り消すと潮も戻る）・次の手の破線。
    def chart(w: In): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let at = chartAt();
        let size = chartSize();
        let bottom = at#y + size#y;
        let n = cycleLength(w);
        // 1 周した所は左端でなく右端に置く（1 手前の点がいつも左隣にある）。
        let phase = if (w#moves > 0 and Int32.modulo(w#moves, n) == 0) n else Int32.modulo(w#moves, n);
        let pointOf = i -> pointOf(w, i);
        let back = { at = at, item = RawDraw.box(size, Color.mix(theme#panel, theme#sea, 0.12), 0) |> Render.rounded(4.0) };
        let levels = List.range(0, topTide(w) + 1) |> List.map(k -> {
            let y = at#y + size#y - 6.0 - Int32.toFloat64(k) / Int32.toFloat64(topTide(w)) * (size#y - 14.0);
            line({ x = at#x + 2.0, y = y }, { x = at#x + size#x - 2.0, y = y }, 0.8, theme#ink, 0.12)
        });
        let fill = List.range(0, n) |> List.map(i -> {
            let a = pointOf(i);
            let b = pointOf(i + 1);
            let vertex = (p, alpha) -> { pos = p, color = theme#sea, alpha = alpha };
            { at = Vec2.zero(), item = Render.gradPolygon(
                vertex(a, 0.5) :: vertex(b, 0.5) :: vertex({ x = b#x, y = bottom - 1.0 }, 0.1)
                    :: vertex({ x = a#x, y = bottom - 1.0 }, 0.1) :: Nil, 0) }
        });
        let curveColor = Color.mix(theme#sea, theme#ink, 0.5);
        let curve = List.range(0, n) |> List.filter(i -> i != Int32.modulo(phase, n)) |> List.map(i ->
            RawDraw.lineSeg(pointOf(i), pointOf(i + 1), 1.6, curveColor, 0));
        let dots = List.range(0, n + 1) |> List.map(i -> RawDraw.circleAt(pointOf(i), 1.5, curveColor, 0));
        let now = pointOf(phase);
        let next = pointOf(Int32.modulo(phase, n) + 1);
        let forecast = List.append(dashed(pointOf(Int32.modulo(phase, n)), next, { width = 2.6, dash = 3.5, shift = w#t * 6.0, color = forecastInk(w) }),
            (RawDraw.circleAt(next, 3.2, forecastInk(w), 0) |> Render.overItem(Render.fade(0.85)))
                :: RawDraw.circleAt(next, 1.6, theme#panel, 0) :: Nil);
        let ghosts = List.range(1, 3) |> List.filter(k -> w#moves - k >= 0 and phase - k >= 0) |> List.flatMap(k -> {
            let p = pointOf(phase - k);
            let fade = 0.42 / Int32.toFloat64(k);
            line({ x = p#x, y = at#y + 4.0 }, { x = p#x, y = bottom - 4.0 }, 1.0, theme#ink, fade * 0.6)
                :: (RawDraw.circleAt(p, 4.0, theme#ink, 0) |> Render.overItem(Render.fade(fade)))
                :: RawDraw.circleAt(p, 2.6, Color.mix(theme#panel, theme#sea, 0.12), 0) :: Nil
        });
        let pulse = 0.5 + 0.5 * Sway.wave(w#t, 0.0, 1.2);
        let needle =
            line({ x = now#x, y = at#y + 3.0 }, { x = now#x, y = bottom - 3.0 }, 1.2, theme#ink, 0.5)
            :: RawDraw.circleAt(now, 5.0 + pulse * 0.6, theme#ink, 0)
            :: RawDraw.circleAt(now, 2.4, theme#panel, 0)
            :: Nil;
        back :: levels ::: fill ::: curve ::: dots ::: forecast ::: ghosts ::: needle
            ::: (if (phase > 0) undoArc(w, now, pointOf(phase - 1)) else Nil)

    /// 取り消しの印: 今の針から 1 手前の残像へ戻る弧の矢印（潮も逆に戻る）。
    def undoArc(w: In, start: Vec2.Vec2, goal: Vec2.Vec2): List[Render.PlacedItem] =
        let lift = 13.0;
        let n = 8;
        let at = k -> {
            let u = Int32.toFloat64(k) / Int32.toFloat64(n);
            { x = start#x + (goal#x - start#x) * u,
              y = start#y + (goal#y - start#y) * u - Vec2.sin(u * Vec2.pi()) * lift }
        };
        let arc = List.range(0, n) |> List.map(k -> line(at(k), at(k + 1), 1.1, ink(w), 0.5));
        let tip = at(n);
        let head = { at = Vec2.zero(), item = RawDraw.polygon(
            tip :: Vec2.add(tip, { x = 4.5, y = -4.0 }) :: Vec2.add(tip, { x = 5.0, y = 1.5 }) :: Nil, ink(w), 0) |> Render.fade(0.6) };
        head :: arc

    /// 貝殻の印 3 つ（左端の中心 at から右へ並べる）。earned 個だけ満ち、残りは空。
    /// クリアの重ね（card）も同じ印を使う。
    def shellRow(themeDoc: ThemeDoc.Doc, at: Vec2.Vec2, earned: Int32): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(themeDoc);
        List.range(0, 3) |> List.flatMap(k -> {
            let c = { x = at#x + Int32.toFloat64(k) * 21.0, y = at#y };
            let full = k < earned;
            let body = if (full) theme#shell else Color.mix(theme#panel, theme#ink, 0.12);
            let band = Color.mix(body, theme#wood, if (full) 0.6 else 0.2);
            RawDraw.ellipseAt(Vec2.add(c, { x = 1.0, y = 1.5 }), { x = 8.0, y = 6.5 }, theme#shadow, 0)
                |> Render.overItem(item -> item |> Render.fade(0.25) |> Render.blended(DrawCmd.BlendMode.Multiply))
            :: RawDraw.ellipseAt(c, { x = 8.0, y = 6.5 }, band, 0)
            :: RawDraw.ellipseAt(Vec2.add(c, { x = -1.4, y = -1.1 }), { x = 5.6, y = 4.5 }, body, 0)
            :: RawDraw.ellipseAt(Vec2.add(c, { x = -3.0, y = -2.4 }), { x = 2.8, y = 2.2 }, band, 0)
            :: RawDraw.ellipseAt(Vec2.add(c, { x = 4.0, y = 3.0 }), { x = 2.6, y = 1.8 }, Color.mix(theme#anemone, theme#shadow, if (full) 0.3 else 0.0), 0)
            :: Nil
        })

    /// 上向き・下向きの小さな三角（次の手で満ちるか引くか）。
    def arrow(w: In, center: Vec2.Vec2, up: Bool): Render.PlacedItem =
        let s = if (up) -1.0 else 1.0;
        { at = Vec2.zero(), item = RawDraw.polygon(
            { x = center#x, y = center#y + s * 5.0 } :: { x = center#x + 5.0, y = center#y - s * 3.5 }
                :: { x = center#x - 5.0, y = center#y - s * 3.5 } :: Nil, forecastInk(w), 0) }

    def texts(atlas: FontAtlas, w: In): List[Render.PlacedItem] =
        let (now, next) = (tideAt(w, w#moves), tideAt(w, w#moves + 1));
        let nextWord = if (next > now) "満ちる" else if (next < now) "引く" else "そのまま";
        let legendY = 202.0;
        textCentered(atlas, w, "潮だまり", 30.0, 22.0, 1.0)
            :: textCentered(atlas, w, "面 ${w#level + 1}  ${w#name}", 10.0, 59.0, 0.75)
            :: text(atlas, w, "潮見表", 13.0, { x = left(), y = 88.0 }, 1.0)
            :: textRight(atlas, w, "潮位 ${now} / ${topTide(w)}", 12.0, right(), 89.0)
            :: text(atlas, w, "次の手で", 12.0, { x = left(), y = 179.0 }, 0.75)
            :: text(atlas, w, nextWord, 15.0, { x = left() + 56.0, y = 176.0 }, 1.0)
            :: (if (next == now) Nil else arrow(w, { x = right() - 8.0, y = 187.0 }, next > now) :: Nil)
            ::: text(atlas, w, "次の水際", 10.0, { x = left() + 26.0, y = legendY - 1.0 }, 0.75)
            :: text(atlas, w, "Z 潮も戻る", 10.0, { x = right() - 48.0, y = legendY - 1.0 }, 0.75)
            :: text(atlas, w, "手数", 13.0, { x = left(), y = 238.0 }, 1.0)
            :: textRight(atlas, w, "${w#moves}", 30.0, right(), 226.0)
            :: textRight(atlas, w, "最少 ${w#parMoves} 手", 11.0, right(), 264.0)
            :: List.append(
                dashed({ x = left(), y = legendY + 6.0 }, { x = left() + 20.0, y = legendY + 6.0 },
                       { width = 2.4, dash = 3.5, shift = w#t * 6.0, color = forecastInk(w) }),
                undoArc(w, { x = right() - 52.0, y = legendY + 10.0 }, { x = right() - 63.0, y = legendY + 10.0 }))

    /// キーの絵: 刻印を押したキーの頭（落ち影・面・縁）と、その横の言葉。3 行に並べる。
    def keys(atlas: FontAtlas, w: In): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let cap = (x: Float64, y: Float64, label: String) -> {
            let size = { x = Float64.max(14.0, TextDraw.width(label, atlas, 9.0) + 7.0), y = 14.0 };
            let at = { x = x, y = y };
            ({ at = Vec2.add(at, { x = 0.0, y = 1.6 }), item = RawDraw.box(size, theme#shadow, 0) |> Render.rounded(3.0) |> Render.fade(0.45) }
                :: { at = at, item = Render.vgrad(size, { top = Color.mix(theme#panel, theme#light, 0.6), bottom = theme#panel }, 0)
                        |> Render.rounded(3.0) |> Render.outlineA({ color = theme#ink, alpha = 0.35, width = 0.8 }) }
                :: TextDraw.centeredAt({ text = label, atlas = atlas, size = 9.0, color = theme#ink, z = 1,
                                         center = Vec2.add(at, Vec2.mul(size, 0.5)) }) :: Nil, x + size#x + 2.0)
        };
        let row = (start: Float64, y: Float64, labels: List[String], word: String) -> {
            let (items, x) = labels |> List.foldLeft((acc, label) -> {
                let (out, x) = acc;
                let (drawn, next) = cap(x, y, label);
                (out ::: drawn, next)
            }, (Nil, start));
            text(atlas, w, word, 10.0, { x = x + 3.0, y = y + 1.0 }, 0.8) :: items
        };
        row(left(), 298.0, "←" :: "↑" :: "↓" :: "→" :: Nil, "動く・押す")
            ::: row(left(), 315.0, "Space" :: Nil, "待つ")
            ::: row(left() + 70.0, 315.0, "Z" :: Nil, "1 手戻す")
            ::: row(left(), 332.0, "R" :: Nil, "面の初めから")

    // ── クリア・流されたの重ね ──

    /// 盤の上に重ねる札: 上下の端で溶ける影の色の帯・大きな見出し・一言・（クリアなら貝殻）・次の操作。
    /// ヤドカリの演出（巻き貝へ入る・流される）が見えてから、delay 秒後に帯ごと浮かび上がる。
    pub def overlay(atlas: FontAtlas, o: Overlay): List[List[Render.PlacedItem]] =
        match o#phase {
            case World.Phase.Playing => Nil
            case World.Phase.Cleared => card(atlas, o, 0.9, ("お引っ越し完了", "${o#moves} 手 ・ 最少 ${o#parMoves} 手"),
                if (o#last) "Enter で おしまいへ" else "Enter で 次の面へ")
            case World.Phase.Washed  => card(atlas, o, 0.6, ("流された", "潮に足元をさらわれた"), "Z で 1 手戻る ・ R で 面の初めから")
        }

    def card(atlas: FontAtlas, o: Overlay, delay: Float64, words: (String, String), next: String): List[List[Render.PlacedItem]] =
        let theme = ThemeDoc.rec(o#theme);
        let k = Num.clamp01((o#age - delay) / 0.45);
        let cx = 234.0;
        let paper = Color.mix(theme#panel, theme#light, 0.3);
        let band = (top: Float64, bottom: Float64, a0: Float64, a1: Float64) ->
            { at = Vec2.zero(), item = Render.gradPolygon(
                { pos = { x = 0.0, y = top }, color = theme#shadow, alpha = a0 * k } :: { pos = { x = 470.0, y = top }, color = theme#shadow, alpha = a0 * k }
                    :: { pos = { x = 470.0, y = bottom }, color = theme#shadow, alpha = a1 * k } :: { pos = { x = 0.0, y = bottom }, color = theme#shadow, alpha = a1 * k } :: Nil, 0) };
        let line = (s: String, size: Float64, y: Float64, alpha: Float64) ->
            TextDraw.centeredAt({ text = s, atlas = atlas, size = size, color = paper, z = 0, center = { x = cx, y = y + 6.0 * (1.0 - k) } })
                |> Render.overItem(Render.fade(alpha * k));
        let shells = if (o#phase == World.Phase.Cleared) shellRow(o#theme, { x = cx - 21.0, y = 200.0 }, o#shells) |> List.map(Render.overItem(Render.fade(k))) else Nil;
        let breathe = 0.6 + 0.4 * Float64.abs(Sway.wave(o#t, 0.0, 0.8));
        (band(96.0, 170.0, 0.0, 0.62) :: band(170.0, 262.0, 0.62, 0.0) :: Nil)
            :: (line(fst(words), 30.0, 146.0, 1.0) :: line(snd(words), 12.0, 178.0, 0.85) :: line(next, 12.0, 228.0, breathe) :: Nil)
            :: shells :: Nil
}
