// ViewProjection — world 座標を画面（design px）へ写す 4 通りの写し方と、その逆算。
//
// なぜ要るか: 配置 Doc に画面 px を書くと、「この岩を左へ 16px」を Doc の数字に
// 戻せない。Doc が world 座標だけを持ち、画面のどこに出るかはここが決める、という
// 形にしておくと、直しが機械的になる（画面 px → world は toWorld / toWorldDelta）。
// この規約そのものは docs/doc-conventions.md「配置 Doc は world 座標だけを持つ」にある。
//
// 写し方ごとに world の意味が違う。意味を決めるのは呼ぶ側で、ここは式だけを持つ:
//
//   Side        (x, y)     world 単位（1 world = zoom px。y は下向き）
//   TopDown     (x, y)     床の world 単位（高さの軸は無い）
//   Quarter     (x, y, h)  タイル座標（マス何個ぶんか）+ 高さ
//   FirstPerson (x, y)     格子の連続座標（マス (col,row) は [col,col+1]×[row,row+1] を占める）
//
// 既存の部品との分担:
//   - Side / TopDown の world ⇄ screen は CameraRig（映す中心 + zoom）へそのまま渡す。
//     2D の見下ろし・横視点のカメラはあちらが持ち物ごと持っているので、式を 2 つ置かない
//   - 透視除算・近クリップ・台形は Persp。ここは Persp を呼ぶだけで自前の割り算を持たない
//   - 見下ろしの「足元が下ほど手前」は Depth、カメラ距離の描画順は Painter
//   - FirstPerson で「どのマスの壁が見えるか」は WallFaces / GridRay（ここは持たない）
//
// **「その写し方にその操作が有るかどうか」は Option で返さない。** 有無は型を作った
// 時点で決まっているので、持ち物を取り出す口（quarterOf / firstPersonOf / inverseOf）で
// 1 回だけ捌く。取り出した後の coveringCells・wallQuad・toWorld・yawOf は Option を返さない。
// Option が残るのは toScreen だけ — あれは「カメラの後ろに来た」という実行時の部分性。
//
// タイル 1 マスの画面上の大きさ・カメラの置き場所・焦点距離は**ゲーム側の意見**なので、
// ここには既定値を置かない（Persp が焦点距離と霧の係数を持たないのと同じ線引き）。
// 組み立ては side / topDown / quarter / firstPerson の 4 本。
pub mod ViewProjection {

    /// world → screen の写し方。写し方ごとに要る数が違うので case ごとに持ち物を変える
    /// （持ち物の中身は下の FlatSpec / QuarterSpec / FirstPersonSpec）。
    pub enum ViewProjection {
        case SideOf(FlatSpec)
        case TopDownOf(FlatSpec)
        case QuarterOf(QuarterSpec)
        case FirstPersonOf(FirstPersonSpec)
    }

    /// 4 つの写し方の名前。目録の "view" と、world 配列の長さを決める。
    pub enum Mode with Eq, ToString {
        case Side
        case TopDown
        case Quarter
        case FirstPerson
    }

    /// world の 1 点。h（高さ）を使うのは Quarter と FirstPerson だけで、
    /// Side / TopDown では 0 のまま（usesHeight が同じことを Bool で言う）。
    pub type alias WorldPos = { x = Float64, y = Float64, h = Float64 }

    /// 高さを持たない world の点。
    pub def worldPos(x: Float64, y: Float64): WorldPos = { x = x, y = y, h = 0.0 }

    /// 高さつきの world の点。
    pub def worldPosAt(x: Float64, y: Float64, h: Float64): WorldPos = { x = x, y = y, h = h }

    /// Side / TopDown の持ち物。CameraRig と同じ形（映す中心 + zoom）で持つので、
    /// **world は画面への割合ではなく world 単位**（1 world = zoom px）。
    /// design を広げると同じ world の点は同じ場所に居たまま、見える範囲だけが広がる。
    pub type alias FlatSpec = { design = Vec2.Vec2, center = Vec2.Vec2, zoom = Float64 }

    /// Quarter の持ち物。tile = タイル 1 マスの画面上の幅と高さ、
    /// rise = 高さ 1 あたり画面で何 px 持ち上がるか、origin = world (0,0,0) の画面位置。
    pub type alias QuarterSpec =
        { design = Vec2.Vec2, tile = Vec2.Vec2, rise = Float64, origin = Vec2.Vec2 }

    /// FirstPerson の持ち物。camera / persp / near はすべて呼ぶ側の意見。
    pub type alias FirstPersonSpec =
        { design = Vec2.Vec2, camera = Persp.Camera, persp = Persp.Projection, near = Float64 }

    /// screen → world の戻し方を持つ写し方だけを抜き出した形（inverseOf で取り出す）。
    /// FirstPerson は透視除算が 2 つの数を 1 つに潰すので、ここには入らない。
    pub enum Inverse {
        case FlatInverse(FlatSpec)
        case QuarterInverse(QuarterSpec)
    }

    pub def all(): List[Mode] =
        Mode.Side :: Mode.TopDown :: Mode.Quarter :: Mode.FirstPerson :: Nil

    /// 目録や Makefile に出す名前。**視点名の文字列はここだけ**。
    pub def key(m: Mode): String = match m {
        case Mode.Side        => "side"
        case Mode.TopDown     => "topdown"
        case Mode.Quarter     => "quarter"
        case Mode.FirstPerson => "firstPerson"
    }

    /// world の h（高さ）が絵に効くか。Quarter は画面の上へ持ち上がり、
    /// FirstPerson は目線から見た上下になる。Side / TopDown には高さの軸が無い。
    pub def usesHeight(m: Mode): Bool = match m {
        case Mode.Quarter     => true
        case Mode.FirstPerson => true
        case Mode.Side        => false
        case Mode.TopDown     => false
    }

    // ════════════════════════════════════════════════════════
    // 写し方を組み立てる（数はゲーム側の意見。既定値はここに置かない）
    // ════════════════════════════════════════════════════════

    /// 横から見た画面。center を画面の中央に zoom 倍（1 world = zoom px）で映す。
    /// 等倍で world = 画面 px にしたいなら `{ center = design/2, zoom = 1.0 }`。
    pub def side(spec: FlatSpec): ViewProjection = ViewProjection.SideOf(spec)

    /// 真上から見た画面。持ち物も式も side と同じで、違うのは y の意味だけ
    /// （横視点は上下・見下ろしは奥行き）。
    pub def topDown(spec: FlatSpec): ViewProjection = ViewProjection.TopDownOf(spec)

    /// 斜め見下ろし（クォータービュー）。
    /// tile = タイル 1 マスの画面上の幅と高さ（2:1 のひし形なら y = x / 2）、
    /// rise = 高さ 1 あたり画面で何 px 持ち上がるか（ふつうは tile#y と同じ）、
    /// origin = world (0, 0, 0) が画面のどこに来るか。
    pub def quarter(spec: QuarterSpec): ViewProjection = ViewProjection.QuarterOf(spec)

    /// 一人称。**カメラは呼ぶ側が渡す**（既存の Persp.Camera をそのまま受ける）。
    /// 一人称の絵は物の位置と同じくらいカメラの位置と向きで決まるので、片方だけ動かせる
    /// 形にしない — 「棚をもう 1 マス奥へ」と「カメラを 1 マス下がる」は同じ重さの調整。
    /// マス目の上を四方位で歩くゲームは makeCamera(eye, facing) で Camera を作れる。
    ///
    /// persp（消失点と焦点距離）と near も呼ぶ側の意見。**例**として、design 320×200 の
    /// 画面をマス (0.5, 0.5) の中心から見るなら
    /// `{ camera = makeCamera({ x = 0.5, y = 0.5 }, Dir4.Dir4.Down),
    ///    persp = { center = { x = 160.0, y = 100.0 }, fx = 192.0, fy = 192.0 }, near = 0.05 }`
    /// のようになる（これは例であって正しい値ではない。画角も目線の高さも場面ごとに違う）。
    pub def firstPerson(spec: FirstPersonSpec): ViewProjection = ViewProjection.FirstPersonOf(spec)

    pub def modeOf(vp: ViewProjection): Mode = match vp {
        case ViewProjection.SideOf(_)        => Mode.Side
        case ViewProjection.TopDownOf(_)     => Mode.TopDown
        case ViewProjection.QuarterOf(_)     => Mode.Quarter
        case ViewProjection.FirstPersonOf(_) => Mode.FirstPerson
    }

    pub def designOf(vp: ViewProjection): Vec2.Vec2 = match vp {
        case ViewProjection.SideOf(s)        => s#design
        case ViewProjection.TopDownOf(s)     => s#design
        case ViewProjection.QuarterOf(q)     => q#design
        case ViewProjection.FirstPersonOf(f) => f#design
    }

    // ════════════════════════════════════════════════════════
    // 持ち物を取り出す（**捌くのはここで 1 回だけ**）
    // ════════════════════════════════════════════════════════

    /// Quarter の持ち物。取り出せたら coveringCells がそのまま呼べる。
    pub def quarterOf(vp: ViewProjection): Option[QuarterSpec] = match vp {
        case ViewProjection.QuarterOf(q) => Some(q)
        case _                           => None
    }

    /// FirstPerson の持ち物。取り出せたら yawOf / distanceOf / visibleFraction /
    /// wallQuad がそのまま呼べる。
    pub def firstPersonOf(vp: ViewProjection): Option[FirstPersonSpec] = match vp {
        case ViewProjection.FirstPersonOf(f) => Some(f)
        case _                               => None
    }

    /// screen → world の戻し方。FirstPerson だけ None — 画面の 1 点に当たる world の点が
    /// 奥行きぶん無数にあるので、一意に決められない（代わりに firstPersonOf を取り出して
    /// yawOf / distanceOf / visibleFraction を使う。床の高さを 1 つ決めてよいなら
    /// Persp.depthAtY が戻せる）。
    pub def inverseOf(vp: ViewProjection): Option[Inverse] = match vp {
        case ViewProjection.SideOf(s)        => Some(Inverse.FlatInverse(s))
        case ViewProjection.TopDownOf(s)     => Some(Inverse.FlatInverse(s))
        case ViewProjection.QuarterOf(q)     => Some(Inverse.QuarterInverse(q))
        case ViewProjection.FirstPersonOf(_) => None
    }

    // ════════════════════════════════════════════════════════
    // world → screen
    // ════════════════════════════════════════════════════════

    /// world の点を画面 px へ。FirstPerson でカメラの真横〜後方に来た点は None
    /// （画面に出しようがない）。残り 3 つは必ず Some。
    pub def toScreen(vp: ViewProjection, at: WorldPos): Option[Vec2.Vec2] = match vp {
        case ViewProjection.SideOf(s)    => Some(flatScreen(s, at))
        case ViewProjection.TopDownOf(s) => Some(flatScreen(s, at))
        case ViewProjection.QuarterOf(q) => Some(quarterScreen(q, at))
        case ViewProjection.FirstPersonOf(f) =>
            Persp.projectPoint(f#persp, f#camera,
                { near = f#near, h = at#h }, { x = at#x, y = at#y })
    }

    def flatScreen(s: FlatSpec, at: WorldPos): Vec2.Vec2 =
        CameraRig.toScreenPos(s#center, { zoom = s#zoom }, { design = s#design },
                              { world = { x = at#x, y = at#y } })

    def quarterScreen(q: QuarterSpec, at: WorldPos): Vec2.Vec2 =
        { x = q#origin#x + (at#x - at#y) * q#tile#x / 2.0,
          y = q#origin#y + (at#x + at#y) * q#tile#y / 2.0 - at#h * q#rise }

    // ════════════════════════════════════════════════════════
    // screen → world（配置 Doc を直すための逆算）
    // ════════════════════════════════════════════════════════

    /// 画面 px の点が、高さ h の面のどの world 座標に当たるか。
    /// 高さの軸を持たない Side / TopDown は h を見ない（返る h も 0）。
    pub def toWorld(inv: Inverse, h: Float64, screen: Vec2.Vec2): WorldPos = match inv {
        case Inverse.FlatInverse(s) =>
            let w = CameraRig.toWorldPos(s#center, { zoom = s#zoom }, { design = s#design },
                                         { screen = screen });
            worldPos(w#x, w#y)
        case Inverse.QuarterInverse(q) =>
            let d = quarterWorldDelta(q, { x = screen#x - q#origin#x,
                                           y = screen#y - q#origin#y + h * q#rise });
            worldPosAt(d#x, d#y, h)
    }

    /// 画面で delta px だけ動かしたいとき、world の座標をいくら動かせばよいか。
    /// 写し方の平行移動しない部分（傾きだけ）の逆なので、どの位置でも同じ値になる。
    /// Quarter では斜行しているので、画面の x だけ動かしても world は x と y の両方が動く
    /// （手で足し引きすると必ず間違える場所）。
    pub def toWorldDelta(inv: Inverse, delta: Vec2.Vec2): Vec2.Vec2 = match inv {
        case Inverse.FlatInverse(s)    => Vec2.div(delta, CameraRig.safeZoom(s#zoom))
        case Inverse.QuarterInverse(q) => quarterWorldDelta(q, delta)
    }

    def quarterWorldDelta(q: QuarterSpec, delta: Vec2.Vec2): Vec2.Vec2 =
        let u = delta#x * 2.0 / safe(q#tile#x);
        let v = delta#y * 2.0 / safe(q#tile#y);
        { x = (u + v) / 2.0, y = (v - u) / 2.0 }

    // ════════════════════════════════════════════════════════
    // 画面を覆うマスの列挙（Quarter）
    // ════════════════════════════════════════════════════════

    /// 画面に重なるマスを盤の内側から並べる（Grid.cellsIn の斜め見下ろし版で、
    /// 契約もあちらにそろえてある — cols / rows で盤の外を落とし、margin で余分を足す）。
    ///
    /// **逆変換があることと、画面を覆うマスを列挙できることは別物。** 画面の四隅を
    /// toWorld で戻して外接を取るだけでは足りない: (1) 1 マスは world の 1 点でなく
    /// ひし形なので、中心が画面の外にあっても半分だけ見えるマスがある。
    /// (2) 高さのあるマスは持ち上がって見えるので、画面の外にある足元も拾う必要がある。
    /// そこで、逆算する前に**画面の矩形のほうを広げる** — 横と上下にひし形の半分、
    /// さらに持ち上がり（maxHeight × rise）のぶん。広げた矩形の四隅を h = 0 で戻すと
    /// （写し方は平行四辺形なので四隅の外接が正確な外接になる）マスの矩形が出る。
    ///
    /// maxHeight = その場面でいちばん高いマスの高さ（world 単位）。**負でよい** —
    /// 穴・地下・水面下は画面の下へ沈むので、広げる辺が上下逆になる。平らな場面は 0.0。
    ///
    /// **保証するのは「1 マスの絵が 1 マスぶんの床 + maxHeight に収まっている限り
    /// 取りこぼさない」ところまで**。数マスにまたがる 1 枚絵（大きい建物・大道具）は
    /// この矩形からはみ出すので、はみ出す量を margin で足す（足さないと画面の縁で消える）。
    ///
    /// 返るのは**奥から手前**（x + y の小さい順・同じ深さでは x の小さい順）。そのまま
    /// 順に描けば重なりが正しくなる。Grid.cellsIn の「上の行から左へ」とここだけ違うのは、
    /// 斜め見下ろしで手前かどうかを決めるのが行でなく x + y だから。
    pub def coveringCells(q: QuarterSpec,
                          spec: { maxHeight = Float64, cols = Int32, rows = Int32,
                                  margin = { left = Int32, top = Int32,
                                             right = Int32, bottom = Int32 } }): List[Grid.Cell] =
        if (spec#cols <= 0 or spec#rows <= 0) Nil
        else {
            let halfW = Float64.abs(q#tile#x) / 2.0;
            let halfH = Float64.abs(q#tile#y) / 2.0;
            let lift = spec#maxHeight * q#rise;
            let up = Float64.max(0.0, lift);
            let down = Float64.max(0.0, -lift);
            let box = { minX = -halfW, minY = -halfH - down,
                        maxX = q#design#x + halfW, maxY = q#design#y + halfH + up };
            let corners = { x = box#minX, y = box#minY } :: { x = box#maxX, y = box#minY } ::
                          { x = box#minX, y = box#maxY } :: { x = box#maxX, y = box#maxY } :: Nil;
            let pts = corners |> List.map(c -> toWorld(Inverse.QuarterInverse(q), 0.0, c));
            let xs = pts |> List.map(p -> p#x);
            let ys = pts |> List.map(p -> p#y);
            let m = spec#margin;
            let x0 = Int32.max(0, floorInt(minOf(xs)) - m#left);
            let y0 = Int32.max(0, floorInt(minOf(ys)) - m#top);
            let x1 = Int32.min(spec#cols - 1, ceilInt(maxOf(xs)) + m#right);
            let y1 = Int32.min(spec#rows - 1, ceilInt(maxOf(ys)) + m#bottom);
            let cells = forM (y <- List.range(y0, y1 + 1); x <- List.range(x0, x1 + 1))
                yield ({ x = x, y = y }: Grid.Cell);
            cells |> List.sortBy(c -> (c#x + c#y, c#x))
        }

    def minOf(vs: List[Float64]): Float64 = List.minimum(vs) |> Option.getWithDefault(0.0)

    def maxOf(vs: List[Float64]): Float64 = List.maximum(vs) |> Option.getWithDefault(0.0)

    def floorInt(v: Float64): Int32 =
        Float64.floor(v) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    def ceilInt(v: Float64): Int32 =
        Float64.ceil(v) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    // ════════════════════════════════════════════════════════
    // FirstPerson だけの読み取り（逆変換の代わり）
    // ════════════════════════════════════════════════════════

    /// カメラの正面から見て何度ずれているか（- が左・+ が右）。
    /// 「この物を画面の中央へ寄せたい」の直し方は、この角度をカメラの向きか
    /// 物の world 座標で詰めること。
    pub def yawOf(f: FirstPersonSpec, at: WorldPos): Float64 =
        let c = Persp.toCam(f#camera, { x = at#x, y = at#y });
        toDegrees(Vec2.atan2(c#lat, c#fwd))

    /// カメラからの距離（マス何個ぶんか）。
    pub def distanceOf(f: FirstPersonSpec, at: WorldPos): Float64 =
        Persp.dist(Persp.toCam(f#camera, { x = at#x, y = at#y }))

    /// 幅 width（world 単位）の物が、画面の中にどれだけ入っているか 0..1。
    /// 1.0 = 全部見えている / 0.0 = 画面の外。カメラの後ろも 0.0。
    pub def visibleFraction(f: FirstPersonSpec, at: WorldPos, width: Float64): Float64 =
        let c = Persp.toCam(f#camera, { x = at#x, y = at#y });
        if (c#fwd < f#near) 0.0
        else {
            let half = width / 2.0;
            let x0 = Persp.screenX(f#persp, { fwd = c#fwd, lat = c#lat - half });
            let x1 = Persp.screenX(f#persp, { fwd = c#fwd, lat = c#lat + half });
            let full = x1 - x0;
            let shown = Float64.min(x1, f#design#x) - Float64.max(x0, 0.0);
            Num.clamp01(shown / safe(full))
        }

    /// 壁 1 枚（足元の線分 a→b を strip の高さの帯まで立ち上げた面）の画面上の四隅と、
    /// **一緒に描くのに要る 3 つ**: dist（Painter.zOrdered に渡す描画順）と
    /// t0 / t1（元の線分のどこが残ったか。模様を世界に固定して、歩いても滑らせないため）。
    /// 近クリップで全部切れたら None。
    ///
    /// strip の hTop / hBot は **目の高さを 0 とした world 単位で、- が上・+ が下**
    /// （Persp.screenY と同じ向き）。目線を壁の中程に置くなら床から天井までの壁は
    /// `{ hTop = -0.6, hBot = 0.4 }` のようになる — hBot を 0 に決め打ちすると
    /// 「目が床にある」壁しか作れず、床から天井までの面が描けない。
    pub def wallQuad(f: FirstPersonSpec, a: Vec2.Vec2, b: Vec2.Vec2,
                     strip: { hTop = Float64, hBot = Float64 }):
            Option[{ corners = Persp.Corners, dist = Float64, t0 = Float64, t1 = Float64 }] =
        Persp.clipSegment(f#near, Persp.toCam(f#camera, a), Persp.toCam(f#camera, b))
            |> Option.map(clipped ->
                { corners = Persp.stripCorners(f#persp, strip, clipped#camA, clipped#camB),
                  dist = clipped#dist, t0 = clipped#t0, t1 = clipped#t1 })

    /// マス目の上を四方位で歩くゲームのための Persp.Camera の作り方。
    /// 向き（Dir4）から Persp の yaw（ラジアン。0 = +x）を導く。
    /// 斜めを向く・なめらかに回すカメラは Persp.Camera を直接組む。
    pub def makeCamera(eye: Vec2.Vec2, facing: Dir4.Dir4): Persp.Camera =
        let (dx, dy) = Dir4.delta(facing);
        { pos = eye, yaw = Vec2.atan2(Int32.toFloat64(dy), Int32.toFloat64(dx)) }

    /// ラジアンを度へ。人が読む向き（yawOf・目録の "facing"）はこの単位でそろえる。
    pub def toDegrees(radians: Float64): Float64 = radians * 180.0 / Vec2.pi()

    /// 0 で割らないための下駄。design やタイルが 0 で来ても落ちない（fail-open）。
    def safe(v: Float64): Float64 =
        if (Float64.abs(v) < 0.000001) 0.000001 else v
}
