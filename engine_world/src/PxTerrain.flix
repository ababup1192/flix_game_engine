// PxTerrain — 側面・斜め視点の自然地形（丘・砂丘・崖・水際）を高さの関数から
// 1px 単位のドット絵として描く純粋なビルダー。上端 y(x)・下端 y(x)・明るさの場
// valueAt・色の列 rampAt を渡すと、その帯を埋める PlacedItem の束が返る。
//
// **init で 1 回組んで持ち回す。毎フレーム呼ばない** — 画面いっぱいの帯は
// 数万 PlacedItem になる（App.withStaticLayer か、組んだ List を World に持つ）。
//
// 矩形の階段とモザイクを出さないための 2 点（どちらも崩すと絵が壊れる）:
// - **上端・下端は 1px の列ごとに y(x) をサンプル**して塗る。cell の升目に丸めると、
//   砂丘のシルエットが上辺水平・角直角の矩形の階段（＝建物）に見える。
// - cell の升目は**色の段の組が切り替わる単位**として残し、**階調の升目は 1px** —
//   画素ごとの明るさを 4x4 Bayer に通して隣り合う 2 色を混ぜる。cell の升目で
//   階調まで作ると、物（1px の Bayer で打ったドット絵）と地で画素の解像度が
//   cell 倍違って、地だけがモザイクに見える。
//
// Terrain（rows の文字格子）との違い: あちらはタイルを敷く地形で、形は格子の文字が
// 決める。こちらは高さの関数が形を決める（タイルの升目に乗らない輪郭が要るとき用）。
//
// 複数の帯を貼り合わせるとき（クォーターの崖の面ごとの分割で実測）:
// - cell の格子は span#x0 起点。隣り合う帯は **x0 を cell の倍数に揃える**
//   （揃えないと升目が面の境でずれる）
// - z は 1 呼び出しに 1 つ。奥行きで z を刻む視点（クォーター等）は露出面ごとに
//   fill を分けて呼ぶ — painter の z 順で正しく隠れる
// - アニメする面（さざ波・草の揺れ）は fill の外で（fill は init で 1 回組む前提）
pub mod PxTerrain {

    /// 4x4 Bayer の敷居 0..1。同じ (x, y) からは同じ値が出る（何度描いても同じ絵）。
    pub def bayer4(x: Int32, y: Int32): Float64 =
        let row = match Int32.remainder(Int32.abs(y), 4) {
            case 0 => 0 :: 8 :: 2 :: 10 :: Nil
            case 1 => 12 :: 4 :: 14 :: 6 :: Nil
            case 2 => 3 :: 11 :: 1 :: 9 :: Nil
            case _ => 15 :: 7 :: 13 :: 5 :: Nil
        };
        let v = List.drop(Int32.remainder(Int32.abs(x), 4), row)
            |> List.head |> Option.getWithDefault(0);
        (Int32.toFloat64(v) + 0.5) / 16.0

    /// 上端と下端が場所ごとに動く帯を敷く。
    ///
    /// - `span` = 塗る x の範囲（x0 から x1 まで）
    /// - `topAt` / `bottomAt` = その x での帯の上端・下端の y
    /// - `rampAt` = その場所の色の列（**暗→明**の順。3 色でも 5 色でも可）
    /// - `valueAt` = その場所の明るさ 0..1（0 = 列の先頭・1 = 列の末尾）
    /// - `cell` = 色の段の組が切り替わる升目の大きさ（px）
    ///
    /// valueAt の 0..1 は列の隣り合う 2 色の区間に割られ、区間の中は Bayer で混ざる
    /// （3 色なら 0..0.5 が 1↔2 色目・0.5..1 が 2↔3 色目。n 色なら n-1 区間）。
    pub def fill(spec: { z = Int32, span = { x0 = Float64, x1 = Float64 },
                         topAt = Float64 -> Float64, bottomAt = Float64 -> Float64,
                         rampAt = Vec2.Vec2 -> Vector[Color],
                         valueAt = Vec2.Vec2 -> Float64, cell = Float64 })
        : List[Render.PlacedItem] =
        let cell = Float64.max(1.0, spec#cell);
        let cols = countOf((spec#span#x1 - spec#span#x0) / cell);
        let cells = List.range(0, cols) |> List.flatMap(i -> {
            let cx = spec#span#x0 + (Int32.toFloat64(i) + 0.5) * cell;
            let first = firstRowOf(spec#topAt, cell, cx);
            let rows = Int32.max(0, lastRowOf(spec#bottomAt, cell, cx) - first);
            List.range(0, rows) |> List.flatMap(j -> {
                let cy = (Int32.toFloat64(first + j) + 0.5) * cell;
                cellAt(spec#rampAt, spec#valueAt, spec#z, cell, { x = cx, y = cy })
            })
        });
        let base = Float64.floor(spec#span#x0);
        let strips = List.range(0, countOf(spec#span#x1 - base)) |> List.flatMap(k -> {
            let fx = base + Int32.toFloat64(k) + 0.5;
            let cx = spec#span#x0
                + (Float64.floor((fx - spec#span#x0) / cell) + 0.5) * cell;
            let first = firstRowOf(spec#topAt, cell, cx);
            let rows = Int32.max(0, lastRowOf(spec#bottomAt, cell, cx) - first);
            let firstY = Int32.toFloat64(first) * cell;
            let lastY = Int32.toFloat64(first + rows) * cell;
            let top = (spec#topAt)(fx);
            let bottom = (spec#bottomAt)(fx);
            // 上端の列: 輪郭 y(x) から、升目を敷き始める行まで（帯が薄ければ下端まで）。
            let topStart = Float64.floor(top);
            let topEdge = List.range(0, countOf(Float64.min(firstY, bottom) - topStart))
                |> List.flatMap(n -> pixelAt(spec#rampAt, spec#valueAt, spec#z,
                    { x = fx, y = topStart + Int32.toFloat64(n) + 0.5 }));
            // 下端の列: 升目を敷き終えた行から、輪郭 y(x) まで。
            let bottomEdge = List.range(0, countOf(bottom - lastY))
                |> List.flatMap(n -> pixelAt(spec#rampAt, spec#valueAt, spec#z,
                    { x = fx, y = lastY + Int32.toFloat64(n) + 0.5 }));
            List.append(topEdge, bottomEdge)
        });
        List.append(strips, cells)

    // ── 升目 1 枚と画素 1 つ ──

    /// 升目 1 枚。升目の中心の明るさで色の段の組（隣り合う 2 色）を選び、
    /// 中の画素は 1px の Bayer で 2 色を混ぜる。
    def cellAt(rampAt: Vec2.Vec2 -> Vector[Color], valueAt: Vec2.Vec2 -> Float64,
               z: Int32, cell: Float64, center: Vec2.Vec2): List[Render.PlacedItem] =
        let ramp = rampAt(center);
        let n = Vector.length(ramp);
        if (n == 0) Nil
        else if (n == 1)
            RawDraw.boxAt(center, { x = cell, y = cell }, Vector.get(0, ramp), z) :: Nil
        else {
            let segs = n - 1;
            let s = segOf(segs, Num.clamp01(valueAt(center)));
            let low = Vector.get(s, ramp);
            let high = Vector.get(s + 1, ramp);
            let left = center#x - cell / 2.0;
            let top = center#y - cell / 2.0;
            let m = countOf(cell);
            let dots = List.range(0, m) |> List.flatMap(i ->
                List.range(0, m) |> List.flatMap(j -> {
                    let p = { x = left + Int32.toFloat64(i) + 0.5,
                              y = top + Int32.toFloat64(j) + 0.5 };
                    let frac = fracOf(segs, s, Num.clamp01(valueAt(p)));
                    if (bayer4(intOf(p#x), intOf(p#y)) < frac)
                        RawDraw.boxAt(p, { x = 1.0, y = 1.0 }, high, z) :: Nil
                    else Nil
                }));
            RawDraw.boxAt(center, { x = cell, y = cell }, low, z) :: dots
        }

    /// 1 画素。段の組の選び方もこの画素の明るさで決める（上端・下端の 1px 列に使う）。
    def pixelAt(rampAt: Vec2.Vec2 -> Vector[Color], valueAt: Vec2.Vec2 -> Float64,
                z: Int32, p: Vec2.Vec2): List[Render.PlacedItem] =
        let ramp = rampAt(p);
        let n = Vector.length(ramp);
        if (n == 0) Nil
        else if (n == 1)
            RawDraw.boxAt(p, { x = 1.0, y = 1.0 }, Vector.get(0, ramp), z) :: Nil
        else {
            let segs = n - 1;
            let v = Num.clamp01(valueAt(p));
            let s = segOf(segs, v);
            let c = if (bayer4(intOf(p#x), intOf(p#y)) < fracOf(segs, s, v))
                Vector.get(s + 1, ramp) else Vector.get(s, ramp);
            RawDraw.boxAt(p, { x = 1.0, y = 1.0 }, c, z) :: Nil
        }

    /// 明るさ 0..1 が列のどの区間（隣り合う 2 色）に入るか。
    def segOf(segs: Int32, v: Float64): Int32 =
        Num.clampInt(0, segs - 1, intOf(v * Int32.toFloat64(segs)))

    /// その区間の中での混ざり具合 0..1（区間の外は 0 か 1 に張り付く）。
    def fracOf(segs: Int32, s: Int32, v: Float64): Float64 =
        Num.clamp01(v * Int32.toFloat64(segs) - Int32.toFloat64(s))

    // ── 帯の行の割り出し ──

    /// その升目の列で、升目を敷き始める行（輪郭 y(x) より必ず下）。
    /// 升目の幅の中で y(x) がいちばん低い所を 3 点で見て、その下の行から敷く。
    def firstRowOf(topAt: Float64 -> Float64, cell: Float64, cx: Float64): Int32 =
        let d = cell / 2.0 - 0.5;
        let t = Float64.max(topAt(cx - d), Float64.max(topAt(cx), topAt(cx + d)));
        intOf(Float64.ceil(t / cell))

    /// その升目の列で、升目を敷き終える行（下端 y(x) より必ず上）。
    def lastRowOf(bottomAt: Float64 -> Float64, cell: Float64, cx: Float64): Int32 =
        let d = cell / 2.0 - 0.5;
        let b = Float64.min(bottomAt(cx - d), Float64.min(bottomAt(cx), bottomAt(cx + d)));
        intOf(Float64.floor(b / cell))

    def intOf(v: Float64): Int32 =
        Float64.tryToInt32(Float64.floor(v)) |> Option.getWithDefault(0)

    def countOf(span: Float64): Int32 =
        Float64.tryToInt32(Float64.ceil(span)) |> Option.getWithDefault(1) |> Int32.max(0)
}
