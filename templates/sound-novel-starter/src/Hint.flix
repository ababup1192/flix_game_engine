// Hint — 入力の案内（純粋・描くだけ）と、tap の当たる物の画面の矩形。選択肢ごとに払う向きへ矢印が流れ、その下に選択肢の本文を置く（#mute なら字なし）。
// #icon:名前 は novel.prompts.json の icons の色で矢印と輪を塗り、絵があれば矢印の横で向きへ行き来させる。tap は当たる物の矩形のまわりに脈打つ輪
// （矩形が無ければ案内の場所に）。選択肢が複数なら横に並べる（横の払いは指を置き始める側の枠へ）。押せる所は持たない（選ぶのは払いだけ）。
mod Hint {
    use fge::{Bezier, Color, DrawCmd, FontAtlas, Num, RawDraw, Rect2, Render, ShaderDoc, Sort, TextDraw, Vec2}
    use fge::ShaderDoc.{Field, Out, Shade, TexChan}

    /// 置き場所と時刻。width / height = 画面の大きさ、y = 矢印の真ん中の高さ、right = 案内を収める右の端、t = 実時間の秒（矢印の流れと輪の脈打ち）、
    /// z = 一番奥の z（案内はここから z + 4 まで使う）、doc = novel.prompts.json、ink / ground = 案内の字と字の地の色。
    pub type alias Look = { width = Float64, height = Float64, y = Float64, right = Float64, t = Float64, z = Int32, doc = PromptsDoc.Doc, ink = Color, ground = Color }

    // ── tap の当たる物 ──

    /// tap の当たる物 name の画面の矩形（載る先が今の背景の写真か出ている絵の時だけ。無ければ None）。
    /// photo = 背景を塗る矩形（揺れの分はみ出す）、actorRect = 出ている絵の名前 → 置き場の矩形。
    pub def targetRect(doc: PromptsDoc.Doc, photo: Option[(String, Rect2.Rect2)], actorRect: String -> Option[Rect2.Rect2], name: String): Option[Rect2.Rect2] =
        PromptsDoc.targetOf(name, doc) |> Option.flatMap(target -> {
            let base = match target#anchor {
                case PromptsDoc.Anchor.Photo(p) => photo |> Option.filter(match (shown, _) -> shown == p) |> Option.map(snd)
                case PromptsDoc.Anchor.Actor(a) => actorRect(a)
            };
            base |> Option.map(r -> { position = { x = r#position#x + r#size#x * target#rect#x, y = r#position#y + r#size#y * target#rect#y },
                                      size = { x = r#size#x * target#rect#w, y = r#size#y * target#rect#h } })
        })

    /// 今のゲートの tap で選ぶ物のうち、点 at に当たる物の名前（どれにも当たらなければ ""）。
    pub def tapTargetAt(targets: String -> Option[Rect2.Rect2], gate: Gate.Gate, at: { x = Float64, y = Float64 }): String =
        gate#choices |> List.filterMap(choice -> namedTap(choice#act))
            |> List.find(name -> targets(name) |> Option.exists(r -> Layout.contains(r, at)))
            |> Option.getWithDefault("")

    def namedTap(act: Gate.Act): Option[String] = match act {
        case Gate.Act.Tap(name) if not String.isEmpty(name) => Some(name)
        case _                                              => None
    }

    // ── 案内 ──

    /// ゲートの案内の全部。当たる物の輪に付く選択肢は輪のそばに出し、残りの選択肢は輪から遠い枠から順に使う（並びの左右は選択肢の順のまま）。
    /// 字の大きさは全部の選択肢でそろえる（一番狭い所に入る大きさ）。
    pub def items(atlas: FontAtlas, look: Look, targets: String -> Option[Rect2.Rect2], gate: Gate.Gate): List[Render.PlacedItem] =
        let count = List.length(gate#choices);
        let slot = (look#right - margin()) / Int32.toFloat64(Int32.max(1, count));
        let size = gate#choices |> List.filterMap(choice -> choice#caption)
            |> List.map(text -> fitOf(atlas, slot, text)#size) |> List.minimum |> Option.getWithDefault(captionSize());
        let slotX = i -> margin() + slot * (Int32.toFloat64(i) + 0.5);
        let ringX = (choice: Gate.Choice) -> namedTap(choice#act) |> Option.flatMap(targets) |> Option.map(r -> r#position#x + r#size#x / 2.0);
        let rings = gate#choices |> List.filterMap(ringX);
        let farFromRings = i -> rings |> List.map(x -> Float64.abs(slotX(i) - x)) |> List.minimum |> Option.getWithDefault(0.0);
        let free = gate#choices |> List.zipWithIndex |> List.filter(match (_, choice) -> Option.isEmpty(ringX(choice)))
            |> Sort.sortStableBy(match (_, choice) -> startSide(choice)) |> List.map(fst);
        let freeSlots = List.range(0, count) |> List.map(i -> (0.0 - farFromRings(i), i)) |> Sort.sortStableBy(fst) |> List.map(snd)
            |> List.take(List.length(free)) |> Sort.sortStable;
        let placed = List.zip(free, freeSlots) |> List.toMap;
        gate#choices |> List.zipWithIndex |> List.flatMap(match (i, choice) -> {
            let at = Map.get(i, placed) |> Option.getWithDefault(i);
            let center = { x = slotX(at), y = look#y };
            choiceItems(atlas, look, targets, { center = center, room = slot, size = size, alone = count == 1 }, choice)
        })

    /// 選択肢を並べる時の左右の順（小さい方が左）。横の払いは指を置き始める側へ: 右払いは左の枠、左払いは右の枠、他は間。
    // WhyNot: 左払いを左の枠に置かない — 左へ払うのは右にある物を手前へ引き寄せる操作で、指は画面の右から置き始める。
    def startSide(choice: Gate.Choice): Int32 = match choice#act {
        case Gate.Act.Swipe(Gesture.Direction.Right) => 0
        case Gate.Act.Swipe(Gesture.Direction.Left)  => 2
        case _                                       => 1
    }

    /// 左右の余白（design px）。
    pub def margin(): Float64 = 24.0

    /// 案内の字の大きさ（入り切らなければここから縮める）。
    def captionSize(): Float64 = 20.0

    /// 選択肢の矢印と輪の色（#icon の色・無ければ矢印の色）。
    def inkOf(look: Look, choice: Gate.Choice): Color =
        choice#icon |> Option.flatMap(n -> PromptsDoc.iconOf(n, look#doc)) |> Option.map(i -> i#color)
            |> Option.getWithDefault(PromptsDoc.rec(look#doc)#arrow#color)

    /// 選択肢 1 つの案内。place = 矢印の真ん中・横に使える幅・字の大きさ・選択肢が 1 つだけか。
    /// tap の当たる物があれば輪はその物のまわりに、字も輪のそばに置く（1 つだけなら輪の上、並べる隣があれば輪の横）。
    // WhyNot: 並べる時に字を割り当ての枠に置かない — 輪は当たる物の所に出るので、字だけが離れてどこを押す案内か読めなくなる。
    def choiceItems(atlas: FontAtlas, look: Look, targets: String -> Option[Rect2.Rect2],
                    place: { center = Vec2.Vec2, room = Float64, size = Float64, alone = Bool }, choice: Gate.Choice): List[Render.PlacedItem] =
        let center = place#center;
        let ink = inkOf(look, choice);
        let below = { top = center#y + 41.0, x = center#x };
        let ringOf = (name: String) -> if (String.isEmpty(name)) None else targets(name);
        let (mark, atCenter, spot) = match choice#act {
            case Gate.Act.Swipe(dir) => (List.append(flowArrows(look, center, dir, ink), iconItems(look, center, dir, choice)), true, below)
            case Gate.Act.Tap(name) => tapMark(atlas, look, place, ink, ringOf(name), choice)
        };
        let words = choice#caption |> Option.map(text -> caption(atlas, look, { top = spot#top, x = spot#x, room = place#room, size = place#size }, text)) |> Option.getWithDefault(Nil);
        let ground = if (atCenter) halo(look, center) else Nil;
        List.flatten(ground :: mark :: words :: Nil)

    /// tap の案内: 当たる物があればそのまわりの輪と字の置き場、無ければ案内の場所の輪。
    def tapMark(atlas: FontAtlas, look: Look, place: { center = Vec2.Vec2, room = Float64, size = Float64, alone = Bool }, ink: Color,
                rect: Option[Rect2.Rect2], choice: Gate.Choice): (List[Render.PlacedItem], Bool, { top = Float64, x = Float64 }) = match rect {
        case Some(r) =>
            let (ringCenter, radius) = rectCenterRadius(r);
            let over = if (place#alone) { top = ringTop(look, r) - place#size - 30.0, x = ringCenter#x }
                       else besideRing(atlas, look, (ringCenter, radius), place#size, choice#caption);
            (pulse(look, (ringCenter, radius), ink), false, over)
        case None => (pulse(look, (place#center, 34.0), ink), true, { top = place#center#y + 41.0, x = place#center#x })
    }

    /// 輪の横（左右の空きの広い方）に置く字の、地の上端と真ん中の x。どちらにも入らなければ内の輪のすぐ上。
    def besideRing(atlas: FontAtlas, look: Look, ring: (Vec2.Vec2, Float64), size: Float64, text: Option[String]): { top = Float64, x = Float64 } =
        let (center, radius) = ring;
        let words = text |> Option.getWithDefault("");
        let pillW = TextDraw.width(words, atlas, size) + pillPad();
        let pillH = size + 22.0;
        let gap = 10.0;
        let leftRoom = center#x - radius - gap - margin();
        let rightRoom = look#width - margin() - (center#x + radius + gap);
        if (Float64.max(leftRoom, rightRoom) >= pillW) {
            let x = if (leftRoom >= rightRoom) center#x - radius - gap - pillW / 2.0 else center#x + radius + gap + pillW / 2.0;
            { top = center#y - pillH / 2.0, x = x }
        } else { top = center#y - radius - gap - pillH, x = center#x }

    /// 矢印の後ろに置く暗いぼかし（明るい背景の上でも線が立つ）。
    def halo(look: Look, center: Vec2.Vec2): List[Render.PlacedItem] =
        Render.glowAt(center, 84.0, Color.darken(look#ground, 0.6), { alpha = 0.7, blend = DrawCmd.BlendMode.Normal }, look#z)

    /// 向きの単位ベクトル（画面は y が下向き）。
    def unitOf(dir: Gesture.Direction): Vec2.Vec2 = match dir {
        case Gesture.Direction.Up    => { x = 0.0, y = -1.0 }
        case Gesture.Direction.Down  => { x = 0.0, y = 1.0 }
        case Gesture.Direction.Left  => { x = -1.0, y = 0.0 }
        case Gesture.Direction.Right => { x = 1.0, y = 0.0 }
    }

    def along(origin: Vec2.Vec2, unit: Vec2.Vec2, d: Float64): Vec2.Vec2 = { x = origin#x + unit#x * d, y = origin#y + unit#y * d }

    /// 向きへ流れる 3 つの山形（後ろから現れ、前で消える）。一番前を一番濃く・太く。
    def flowArrows(look: Look, center: Vec2.Vec2, dir: Gesture.Direction, ink: Color): List[Render.PlacedItem] =
        let unit = unitOf(dir);
        let side = { x = 0.0 - unit#y, y = unit#x };
        let speed = PromptsDoc.rec(look#doc)#arrow#speed;
        List.range(0, 3) |> List.flatMap(i -> {
            let phase = Num.fract(look#t * speed + Int32.toFloat64(i) / 3.0);
            let tip = along(center, unit, -34.0 + phase * 68.0);
            let back = along(tip, unit, -20.0);
            let wing = 24.0;
            let points = { x = back#x + side#x * wing, y = back#y + side#y * wing } :: tip :: { x = back#x - side#x * wing, y = back#y - side#y * wing } :: Nil;
            let alpha = Num.sin(phase * Num.pi());
            Bezier.polyline(points, { width = 3.5 + 2.5 * phase }, ink, look#z + 2) |> List.map(fadeTo(alpha))
        })

    /// #icon の絵（矢印の横で向きへ行き来する。絵の無い icon は色だけ）。
    def iconItems(look: Look, center: Vec2.Vec2, dir: Gesture.Direction, choice: Gate.Choice): List[Render.PlacedItem] =
        let unit = unitOf(dir);
        let side = { x = 0.0 - unit#y, y = unit#x };
        let swing = Num.sin(look#t * 3.0) * 6.0;
        let at = along({ x = center#x + side#x * 50.0, y = center#y + side#y * 50.0 }, unit, swing);
        let size = 56.0;
        choice#icon |> Option.flatMap(n -> PromptsDoc.iconOf(n, look#doc)) |> Option.filter(i -> not String.isEmpty(i#texture))
            |> Option.map(i -> Render.shaderFill(iconSpec(i#texture), { position = { x = at#x - size / 2.0, y = at#y - size / 2.0 }, size = { x = size, y = size } }, 0.0, look#z + 3) :: Nil)
            |> Option.getWithDefault(Nil)

    /// 案内の絵（透過画像を正方形に貼る。2 つの画素の間をなめらかにつないで読む）。
    // WhyNot: Render.sprite で貼らない — 絵の画素の大きさが Doc に無く、正方形に収める倍率が決められない。
    def iconSpec(texture: String): ShaderDoc.Spec =
        let read = chan -> Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = Field.Tex({ name = texture, chan = chan }) });
        { name = "prompt_icon_${texture}", cycleRate = 0.0, bindings = Nil,
          out = Out.Fill({ shade = Shade.Rgb({ r = read(TexChan.R), g = read(TexChan.G), b = read(TexChan.B) }), alpha = read(TexChan.A) }) }

    def rectCenterRadius(r: Rect2.Rect2): (Vec2.Vec2, Float64) =
        ({ x = r#position#x + r#size#x / 2.0, y = r#position#y + r#size#y / 2.0 }, Float64.max(r#size#x, r#size#y) / 2.0 + 10.0)

    /// 脈打つ輪: 内の輪は少し膨らんで戻り、外の輪は広がりながら消える（novel.prompts.json の pulse）。
    def pulse(look: Look, at: (Vec2.Vec2, Float64), ink: Color): List[Render.PlacedItem] =
        let (center, radius) = at;
        let p = PromptsDoc.rec(look#doc)#pulse;
        let beat = Num.fract(look#t * p#rate);
        let inner = radius * (1.0 + 0.06 * Num.sin(look#t * 5.6));
        let ring = (r, width, alpha, z) ->
            Bezier.polyline(Bezier.ellipse(center, r, r, 32) |> (pts -> List.append(pts, List.take(1, pts))), { width = width }, ink, z)
                |> List.map(fadeTo(alpha));
        List.append(ring(inner, 2.5, 0.85, look#z + 2), ring(radius * (1.0 + beat * p#spread), 2.0, 0.7 * (1.0 - beat), look#z + 1))

    /// tap の当たる物 rect のまわりの輪が届く一番上の y。
    def ringTop(look: Look, rect: Rect2.Rect2): Float64 =
        let (center, radius) = rectCenterRadius(rect);
        center#y - radius * (1.0 + PromptsDoc.rec(look#doc)#pulse#spread)

    /// 案内の字を幅 room に入れる割り方と大きさ。1 行で入らなければ真ん中の近くの「、」か「で」の後で 2 行に割り、それでも入らなければ縮める（0.6 倍まで）。
    def fitOf(atlas: FontAtlas, room: Float64, text: String): { rows = List[String], size = Float64 } =
        let widest = rows -> rows |> List.map(row -> TextDraw.width(row, atlas, captionSize())) |> List.maximum |> Option.getWithDefault(0.0);
        let fits = rows -> widest(rows) + pillPad() <= room;
        let rows = if (fits(text :: Nil)) text :: Nil else splitOf(text);
        let size = if (fits(rows)) captionSize() else captionSize() * Float64.max(0.6, (room - pillPad()) / Float64.max(1.0, widest(rows)));
        { rows = rows, size = size }

    /// 2 行に割る所（「、」か「で」の後。無ければ割らない）。
    def splitOf(text: String): List[String] =
        let at = String.indexOf(substr = "、", text) |> Option.withDefault(default = String.indexOf(substr = "で", text));
        match at {
            case Some(i) if i + 1 < String.length(text) => String.take(i + 1, text) :: String.drop(i + 1, text) :: Nil
            case _                                      => text :: Nil
        }

    /// 字の左右に取る地の幅の合計。
    def pillPad(): Float64 = 36.0

    /// 案内の字（暗い角丸の地の上に置く）。place = 地の上端・真ん中の x・横に使える幅・字の大きさ（全部の選択肢でそろえた物）。
    def caption(atlas: FontAtlas, look: Look, place: { top = Float64, x = Float64, room = Float64, size = Float64 }, text: String): List[Render.PlacedItem] =
        let rows = fitOf(atlas, place#room, text)#rows;
        let size = place#size;
        let lineH = size * 1.3;
        let tw = rows |> List.map(row -> TextDraw.width(row, atlas, size)) |> List.maximum |> Option.getWithDefault(0.0);
        let pill = { x = tw + pillPad(), y = Int32.toFloat64(List.length(rows) - 1) * lineH + size + 22.0 };
        let ground = RawDraw.box(pill, look#ground, look#z + 1) |> Render.fade(0.78)
            |> Render.outlineA({ color = PromptsDoc.rec(look#doc)#arrow#color, alpha = 0.4, width = 1.0 }) |> Render.rounded(Float64.min(pill#y, size + 22.0) / 2.0);
        let words = rows |> List.zipWithIndex |> List.map(match (i, row) -> {
            let rw = TextDraw.width(row, atlas, size);
            { at = { x = place#x - rw / 2.0, y = place#top + 9.0 + Int32.toFloat64(i) * lineH },
              item = Render.textTinted(row, atlas, size, look#ink, look#z + 2) }
        });
        { at = { x = place#x - pill#x / 2.0, y = place#top }, item = ground } :: words

    def fadeTo(alpha: Float64): Render.PlacedItem -> Render.PlacedItem = placed -> Render.overItem(item -> Render.fade(alpha, item), placed)
}
