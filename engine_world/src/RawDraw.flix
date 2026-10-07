// RawDraw — 塗りつぶしの箱・円・多角形など、単色ベタの図形プリミティブの置き場。
// ここから絵を組み始めない(まず docs/drawing-floor.md と /visual-dict)。
// 家づくりでいう柱や板のような「材料」で、PxShade・Material・Scatter・Terrain・
// shader.json などの高レイヤー部品が、図形プリミティブを多数合成して見た目を作る土台。
// 正当な用途: HUD の下地・デバッグ描画・fail-open の仮板・高レイヤー部品の内部実装。
// 依存方向は RawDraw→Render のみ可。UI の入れ子レイアウトは UiLayout.box(別物)。
// lineQuad+rotated の時計の針イディオムはここに残る(線を引くこと自体は可)。

pub mod RawDraw {

    use Render.Item
    use Render.PlacedItem

    /// 単色塗りの矩形（左上原点・サイズ指定）。
    pub def box(size: Vec2.Vec2, color: Color, zIndex: Int32): Item =
        Item.Box({ size = size, color = color, alpha = 1.0, rotation = 0.0,
                         style = Some(solidStyle()), zIndex = zIndex,
                         blend = DrawCmd.BlendMode.Normal })

    /// 単色塗りの円（直径 radius×2 の全角丸 Box）。置き場所は外接正方形の左上。
    /// 中心で置きたいときは circleAt を使う。
    pub def circle(radius: Float64, color: Color, zIndex: Int32): Item =
        box({ x = radius * 2.0, y = radius * 2.0 }, color, zIndex) |> Render.rounded(radius)

    /// 中心 center に置いた単色の円（PlacedItem）。外接正方形の左上への換算はここが済ませる。
    pub def circleAt(center: Vec2.Vec2, radius: Float64, color: Color, zIndex: Int32): PlacedItem =
        { at = { x = center#x - radius, y = center#y - radius },
          item = circle(radius, color, zIndex) }

    /// 中心 center に置いた単色の矩形（PlacedItem）。左上で置きたいときは box を使う。
    pub def boxAt(center: Vec2.Vec2, size: Vec2.Vec2, color: Color, zIndex: Int32): PlacedItem =
        { at = { x = center#x - size#x / 2.0, y = center#y - size#y / 2.0 },
          item = box(size, color, zIndex) }

    /// items が空なら boxAt の仮色の板 1 枚にする fail-open。スプライトのコマ名違い・
    /// 読み込み失敗で画面に穴を開けない（板が出れば「絵が無い」と目で判る）ための関数 —
    /// 空でなければ items をそのまま返す。
    pub def orBoxAt(center: Vec2.Vec2, size: Vec2.Vec2, color: Color, zIndex: Int32,
                    items: List[PlacedItem]): List[PlacedItem] =
        if (List.isEmpty(items)) boxAt(center, size, color, zIndex) :: Nil
        else items

    /// 単色塗りの多角形。頂点は置き場所からの相対座標で渡す（絶対座標で組みたいときは
    /// 置き場所を Vec2.zero() にする）。左右反転した形が欲しいときは頂点を Render.flipH に
    /// 通してから渡す。
    pub def polygon(vertices: List[Vec2.Vec2], color: Color, zIndex: Int32): Item =
        Item.Poly({ vertices = vertices, color = color, alpha = 1.0, zIndex = zIndex,
                    blend = DrawCmd.BlendMode.Normal, grad = None })

    // ── 図形の語彙（polygon の上に組んだ形。凹も可 — 描画側の耳切りが三角形化する）──
    // 角度はぜんぶ「1 周 = 1.0 の回転量 t」で渡す（t = 0 が真上・時計回り = 画面の見た目どおり）。
    // 各図形は Item 版（頂点は原点中心。fade などの修飾をパイプで重ねてから置く）と、
    // 無修飾の近道の At 版（中心を渡すと PlacedItem になる）の 2 通り。

    /// 正 n 角形（外接半径 radius・頂点が真上・原点中心）。三角形・ひし形・六角形はこれ。
    pub def ngon(n: Int32, radius: Float64, color: Color, zIndex: Int32): Item =
        polygon(List.range(0, n) |> List.map(i ->
            onCircle(radius, radius, Int32.toFloat64(i) / Int32.toFloat64(n))), color, zIndex)

    /// ngon を中心 center に置く近道。
    pub def ngonAt(center: Vec2.Vec2, n: Int32, radius: Float64, color: Color, zIndex: Int32): PlacedItem =
        { at = center, item = ngon(n, radius, color, zIndex) }

    /// 楕円（radii は x/y の半径・原点中心。32 角形の近似）。
    /// 同型の Float64 2 つは取り違えやすいので Vec2 で渡す。
    pub def ellipse(radii: Vec2.Vec2, color: Color, zIndex: Int32): Item =
        ellipseSegs(radii, 32, color, zIndex)

    /// ellipse を中心 center に置く近道。
    pub def ellipseAt(center: Vec2.Vec2, radii: Vec2.Vec2, color: Color, zIndex: Int32): PlacedItem =
        { at = center, item = ellipse(radii, color, zIndex) }

    /// 縁の分割数を選べる楕円。小さく描く楕円（足元の影・遠くの茂み）では、既定の 32 分割は
    /// 頂点どうしの間隔が 1px を大きく切る — 絵は変わらないのに、頂点を組んで三角形へ
    /// ほどく手間だけが数を積む。何百個も撒く層では大きさに見合う分割数を渡す。
    pub def ellipseSegs(radii: Vec2.Vec2, segs: Int32, color: Color, zIndex: Int32): Item =
        let n = Int32.max(3, segs);
        polygon(List.range(0, n) |> List.map(i ->
            onCircle(radii#x, radii#y, Int32.toFloat64(i) / Int32.toFloat64(n))), color, zIndex)

    /// ellipseSegs を中心 center に置く近道。
    pub def ellipseSegsAt(center: Vec2.Vec2, radii: Vec2.Vec2, segs: Int32, color: Color,
                          zIndex: Int32): PlacedItem =
        { at = center, item = ellipseSegs(radii, segs, color, zIndex) }

    /// その大きさの楕円に見合う縁の分割数。頂点の間隔がおよそ 2px になる所で頭打ちにする
    /// （それ以上細かくしても画面では丸さが変わらない）。
    pub def ellipseSegsFor(radii: Vec2.Vec2): Int32 =
        let r = Float64.max(radii#x, radii#y);
        Int32.max(6, Int32.min(32, Num.floorInt(r) + 6))

    /// 扇形（パイ。要が原点）。中心角が半周を超える形（パックマン等）も正しく塗れる
    /// — 凹みは描画側の耳切りが三角形化する。
    pub def sector(radius: Float64, sweep: {fromT = Float64, toT = Float64},
                   color: Color, zIndex: Int32): Item =
        polygon(Vec2.zero() :: arcPoints(radius, sweep), color, zIndex)

    /// sector を中心 center に置く近道。
    pub def sectorAt(center: Vec2.Vec2, radius: Float64, sweep: {fromT = Float64, toT = Float64},
                     color: Color, zIndex: Int32): PlacedItem =
        { at = center, item = sector(radius, sweep, color, zIndex) }

    /// 円を弦で切った弓形（弧 + 弦。多角形は自動で閉じる・原点中心の円由来）。
    pub def circleSegment(radius: Float64, sweep: {fromT = Float64, toT = Float64},
                          color: Color, zIndex: Int32): Item =
        polygon(arcPoints(radius, sweep), color, zIndex)

    /// circleSegment を中心 center に置く近道。
    pub def circleSegmentAt(center: Vec2.Vec2, radius: Float64, sweep: {fromT = Float64, toT = Float64},
                            color: Color, zIndex: Int32): PlacedItem =
        { at = center, item = circleSegment(radius, sweep, color, zIndex) }

    /// 星（points 尖り・外径と内径の交互・原点中心）。凹んだ形の代表。
    pub def star(points: Int32, radii: {outer = Float64, inner = Float64},
                 color: Color, zIndex: Int32): Item =
        polygon(List.range(0, points * 2) |> List.map(i -> {
            let r = if (Int32.modulo(i, 2) == 0) radii#outer else radii#inner;
            onCircle(r, r, Int32.toFloat64(i) / Int32.toFloat64(points * 2))
        }), color, zIndex)

    /// star を中心 center に置く近道。
    pub def starAt(center: Vec2.Vec2, points: Int32, radii: {outer = Float64, inner = Float64},
                   color: Color, zIndex: Int32): PlacedItem =
        { at = center, item = star(points, radii, color, zIndex) }

    /// 線分 a→b の輪郭（太さ width の凸四角形の頂点列）。lineSeg の芯で、時計の針のように
    /// 「根元を原点に置いて rotated で回す」使い方のために頂点のまま取れるようにしてある。
    pub def lineQuad(a: Vec2.Vec2, b: Vec2.Vec2, width: Float64): List[Vec2.Vec2] =
        let d = Vec2.sub(b, a);
        let len = Vec2.length(d);
        let nrm = if (len < 0.0001) Vec2.zero()
                  else Vec2.mul({ x = 0.0 - d#y / len, y = d#x / len }, width / 2.0);
        Vec2.add(a, nrm) :: Vec2.add(b, nrm) :: Vec2.sub(b, nrm) :: Vec2.sub(a, nrm) :: Nil

    /// 線分 a→b を太さ width の四角形で描く（任意角度の線の代用）。
    /// a, b は絶対座標で渡す（置き場所は組み込み済み）。
    pub def lineSeg(a: Vec2.Vec2, b: Vec2.Vec2, width: Float64, color: Color, zIndex: Int32): PlacedItem =
        { at = Vec2.zero(), item = polygon(lineQuad(a, b, width), color, zIndex) }

    /// 円周（楕円周）上の点（Vec2.onEllipse の近道 — 半径 2 つを個別に受ける内部形）。
    def onCircle(rx: Float64, ry: Float64, t: Float64): Vec2.Vec2 =
        Vec2.onEllipse({ x = rx, y = ry }, t)

    /// fromT..toT の弧を 24 分割した点列（端点含む）。
    def arcPoints(radius: Float64, sweep: {fromT = Float64, toT = Float64}): List[Vec2.Vec2] =
        let segs = 24;
        List.range(0, segs + 1) |> List.map(i ->
            onCircle(radius, radius,
                sweep#fromT + (sweep#toT - sweep#fromT) * Int32.toFloat64(i) / Int32.toFloat64(segs)))

    def solidStyle(): GameEngine.BoxStyle =
        DrawCmd.defaultStyle({r = 1.0, g = 1.0, b = 1.0})
}
