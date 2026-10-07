// PxSpriteAtlas — PxSpriteDoc(文字格子)×resolver(テーマ)を 1 枚のアトラス画素に生成する純関数層。
// 1 セル = 1px(ARGB)。描画時に整数 scale で拡大する(NEAREST 前提)ので、アトラスは常に等倍で生成する。
// 出力は「画素(Vector[Int32]・ARGB 行優先)+コマ→矩形の目次(regions)」だけ — GL への
// アップロード(render_gl/RenderTexture.loadTextureFromPixels)も PNG 書き出し
// (SoftRaster.writeRadialPng に pixelAt を渡す)も、同じ Baked を読む。こうして GL と
// headless(SoftRaster)が同一ソースの絵になる。
// テーマ切替は低頻度 → テーマごとに bake し直す(watchFile 変更時はフレーム先頭で
// 差し替え — fontAtlas と同じライフサイクル)。
// 棚詰め(shelfPack)は RenderFont のシェルフパッキングと同じ規則を関数に切り出したもの
// (左→右に詰め、行に収まらなければ行の最大高+1px で折り返す。コマ間は 1px の隙間)。
pub mod PxSpriteAtlas {

    /// アトラス内の 1 コマの矩形(px・セル数と同じ)。
    pub type alias Slot = { x = Int32, y = Int32, w = Int32, h = Int32 }

    /// 生成した結果。pixels は side×side の ARGB(行優先)。regions のキーは (スプライト名, コマ名)。
    pub type alias Baked = {
        side = Int32,
        regions = Map[(String, String), Slot],
        pixels = Vector[Int32]
    }

    /// 何も持たない空のアトラス(「まだ生成していない」の置き場)。
    pub def empty(): Baked =
        { side = 0, regions = Map.empty(), pixels = Vector.empty() }

    /// アトラス辺長の候補。ドット絵の格子は小さいので 16px から。2048 で収まらない Doc は
    /// regions から溢れたコマが欠ける(fail-open: 描かれないだけで落ちない)。
    def sideCandidates(): List[Int32] = 16 :: 32 :: 64 :: 128 :: 256 :: 512 :: 1024 :: 2048 :: Nil

    /// Doc の全スプライト×全コマを 1 枚に生成する。コマの順は Map 順(名前順)で決定的。
    /// legend に無い文字は透明(ARGB 0)。resolver が意味色キー → 実色を解決する
    /// (テーマ替え・体色差はここで生成し分ける — 格子は共有)。
    /// パッキングが全部失敗しても呼び側の型を変えないため、空のアトラスを返して
    /// 標準エラーへ 1 行知らせる(fail-open)。失敗を捌きたい呼び側は bakeChecked を使う。
    pub def bake(doc: PxSpriteDoc.Doc, resolver: String -> Color): Baked =
        match bakeChecked(doc, resolver) {
            case Ok(baked) => warnDroppedFrames(doc, baked)
            case Err(msg)  => warnPackFailed(msg, bakeAtSide(largestSide(), doc, resolver))
        }

    /// bake の Result 版。どの辺長でも全コマを詰められないときは Err で、既定値を使うかどうかを
    /// 呼び側に決めさせる。
    pub def bakeChecked(doc: PxSpriteDoc.Doc, resolver: String -> Color): Result[String, Baked] =
        let sizes = sizesOf(doc);
        match sideCandidates() |> List.find(s -> Option.nonEmpty(shelfPack(s, sizes))) {
            case Some(side) => Ok(bakeAtSide(side, doc, resolver))
            case None       =>
                Err("shelf packing failed: ${List.length(sizes)} frames do not fit in ${largestSide()}px")
        }

    /// 辺長を決め打ちして 1 枚に生成する。
    def bakeAtSide(side: Int32, doc: PxSpriteDoc.Doc, resolver: String -> Color): Baked = region rc {
        let frames = framesOf(doc);
        let sizes = sizesOf(doc);
        let placed = shelfPack(side, sizes) |> Option.getWithDefault(Map.empty());
        let regions = sizes |> List.filterMap(entry -> {
            let (key, wh) = entry;
            let (w, h) = wh;
            Map.get(key, placed) |> Option.map(xy -> {
                let (x, y) = xy;
                (key, ({ x = x, y = y, w = w, h = h }: Slot))
            })
        }) |> List.toMap;
        let buf: Array[Int32, rc] = Array.empty(rc, side * side);
        frames |> List.forEach(f -> {
            let (key, rows) = f;
            match Map.get(key, regions) {
                case None    => ()
                case Some(r) => blitFrame(buf, side, r, doc#legend, resolver, rows)
            }
        });
        { side = side, regions = regions, pixels = Array.toVector(buf) }
    }

    /// パッキングが全部失敗した事実を 1 行知らせてから baked を返す。
    def warnPackFailed(msg: String, baked: Baked): Baked =
        let _ = Log.fellBack("pxsprite", "アトラス", "空のアトラス", msg);
        baked

    /// 目次に載らなかったコマがあれば 1 行知らせてから baked を返す。
    /// 載らないコマは描かれない(何も知らせないと「絵が出ない」の原因が追えない)。
    def warnDroppedFrames(doc: PxSpriteDoc.Doc, baked: Baked): Baked =
        let dropped = List.length(framesOf(doc)) - Map.size(baked#regions);
        if (dropped <= 0)
            baked
        else
            let _ = Log.warn("pxsprite fail-open: ${dropped} 個のコマがアトラスに入らないため描かれません");
            baked

    /// (スプライト名, コマ名) → アトラス内矩形(Rect2・px)。regionRect(Item.Sprite)にそのまま渡せる。
    pub def regionOf(baked: Baked, sprite: String, frame: String): Option[Rect2.Rect2] =
        Map.get((sprite, frame), baked#regions) |> Option.map(r ->
            { position = { x = Int32.toFloat64(r#x), y = Int32.toFloat64(r#y) },
              size = { x = Int32.toFloat64(r#w), y = Int32.toFloat64(r#h) } })

    /// 画素 1 個(ARGB)。範囲外・未 bake は透明 0。PNG 書き出し(SoftRaster.writeRadialPng)の
    /// pixelOf にそのまま部分適用できる。
    pub def pixelAt(baked: Baked, x: Int32, y: Int32): Int32 =
        if (x < 0 or y < 0 or x >= baked#side or y >= baked#side) 0
        else Vector.get(y * baked#side + x, baked#pixels)

    /// 生成した絵の一覧を「正方形の絵の一覧」へ写す（HeadlessRender.imagePngs / imageTextureInfo 用）。
    /// 生成の道具は engine_world の型を知らないので、素の形に直してから渡す。
    pub def asImages(uploads: List[{ texture = String, baked = Baked | r }]):
            List[{ name = String, side = Int32, pixelAt = (Int32, Int32) -> Int32 }] =
        uploads |> List.map(u ->
            { name = u#texture, side = u#baked#side,
              pixelAt = (x, y) -> pixelAt(u#baked, x, y) })

    /// シェルフパッキング(棚詰め): items を与えられた順に左→右へ詰め、行に収まらなければ
    /// 「その行の最大高 + 1px」下の新しい行へ折り返す。コマ間は縦横とも 1px の隙間。
    /// 全部収まれば キー → 左上(x, y) の Map、1 つでも溢れれば None(呼び手が辺長を広げる)。
    pub def shelfPack(side: Int32, items: List[(k, (Int32, Int32))]): Option[Map[k, (Int32, Int32)]] with Order[k] =
        let step = (acc: Option[(Map[k, (Int32, Int32)], Int32, Int32, Int32)],
                    item: (k, (Int32, Int32))) -> {
            match acc {
                case None => None
                case Some((placed, cx, cy, rowH)) => {
                    let (key, wh) = item;
                    let (w, h) = wh;
                    if (w <= 0 or h <= 0)
                        // 空のコマは置かない(regions からも落ちる — 描かれないだけ)。
                        Some((placed, cx, cy, rowH))
                    else {
                        let (nx, ny, nrh) =
                            if (cx + w > side) (0, cy + rowH + 1, 0)
                            else (cx, cy, rowH);
                        if (nx + w > side or ny + h > side) None
                        else Some((Map.insert(key, (nx, ny), placed),
                                   nx + w + 1, ny, Int32.max(nrh, h)))
                    }
                }
            }
        };
        List.foldLeft(step, Some((Map.empty(), 0, 0, 0)), items)
            |> Option.map(st -> { let (placed, _, _, _) = st; placed })

    /// Color(0..1) → 不透明 ARGB。丸めは SoftRaster.byteOf と同一
    /// (round・クランプ)— box 列(polygon 塗り)とアトラス画素の色をバイト一致させるため。
    pub def argbOf(c: Color): Int32 =
        let ch = v -> {
            let i = Float64.tryToInt32(Float32.toFloat64(RenderUtil.f32(v)) * 255.0 + 0.5)
                |> Option.getWithDefault(0);
            Int32.max(0, Int32.min(255, i))
        };
        Int32.leftShift(255, 24)
            |> Int32.bitwiseOr(Int32.leftShift(ch(c#r), 16))
            |> Int32.bitwiseOr(Int32.leftShift(ch(c#g), 8))
            |> Int32.bitwiseOr(ch(c#b))

    // ── 内部 ──

    /// Doc → ((スプライト名, コマ名), rows) の列。Map 順(名前順)なので決定的。
    def framesOf(doc: PxSpriteDoc.Doc): List[((String, String), List[String])] =
        doc#sprites |> Map.toList |> List.flatMap(sp -> {
            let (name, sprite) = sp;
            sprite#frames |> Map.toList |> List.map(fr -> {
                let (frame, rows) = fr;
                ((name, frame), rows)
            })
        })

    /// パッキングに渡す ((スプライト名, コマ名), (w, h)) の列。
    def sizesOf(doc: PxSpriteDoc.Doc): List[((String, String), (Int32, Int32))] =
        framesOf(doc) |> List.map(f -> { let (key, rows) = f; (key, gridSize(rows)) })

    /// 辺長の候補の最大。パッキングが全部失敗したときの辺長でもある。
    def largestSide(): Int32 =
        sideCandidates() |> List.foldLeft(Int32.max, 0)

    /// 格子の寸法(w = 最長行の文字数, h = 行数)。
    def gridSize(rows: List[String]): (Int32, Int32) =
        (rows |> List.foldLeft((acc, row) -> Int32.max(acc, String.length(row)), 0),
         List.length(rows))

    /// 1 コマを buf の region 位置に書き込む。legend に無い文字は透明のまま(書かない)。
    def blitFrame(buf: Array[Int32, rc], side: Int32, r: Slot,
                  legend: Map[Char, String], resolver: String -> Color,
                  rows: List[String]): Unit \ rc =
        rows |> List.zipWithIndex |> List.forEach(entry -> {
            let (ry, row) = entry;
            String.toList(row) |> List.zipWithIndex |> List.forEach(cell -> {
                let (rx, ch) = cell;
                match Map.get(ch, legend) {
                    case None      => ()
                    case Some(key) =>
                        Array.put(argbOf(resolver(key)), (r#y + ry) * side + (r#x + rx), buf)
                }
            })
        })
}
