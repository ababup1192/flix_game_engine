// RadialBuiltin — 放射グラデ（中心から縁へ滑らかに変わる円）の組み込みテクスチャ。
// 画素の値だけを決める純関数で、GL（起動時に GPU へ上げる）と SoftRaster（描き出しの
// テクスチャ表へ混ぜる）が同じ列から絵を作る — 2 か所で別々に生成すると実機と描き出しの
// 絵が 1px 単位でずれるため、画素の出どころをここ 1 つにする。
// engine_tools の RadialGlow と式は同系（smoothstep 減衰）だが、engine から engine_tools
// へは依存できないため、式はここに自前で持つ。
pub mod RadialBuiltin {

    /// テクスチャの 1 辺の px 数（正方形）。Render.lightAt / darkAt が
    /// 「見た目半径 = radius」の拡大率をこの値から逆算するため、
    /// 生成する側と置く側が別の値を見ると光の大きさがずれる。
    pub def size(): Int32 = 256

    /// 明かり（Add 用）のテクスチャ名。`__` で始めるのはゲームのアセット名と
    /// 衝突させないため（普通のアセット名に使われない綴りを予約する）。
    pub def lightName(): String = "__radial_light"

    /// 翳り（Multiply 用）のテクスチャ名。
    pub def darkName(): String = "__radial_dark"

    /// 明かりの画素列（ARGB・行優先）。中心が白・外へ滑らかに減衰。
    /// 減衰カーブは rgb だけに反映し、alpha は常に 255 にする — alpha を可変にすると
    /// Add 合成の寄与が rgb×alpha の積になり、GL（float 合成）と SoftRaster（整数合成）で
    /// 丸めが食い違う。alpha=255 なら Add は d+s の整数の足し算で両経路バイト一致になる。
    /// Multiply に使うと「白は素通し」の式でほぼ恒等に潰れて何も起きない — Add 専用。
    /// 翳りは darkPixels を使う。
    pub def lightPixels(): Vector[Int32] =
        pixels((x, y) -> {
            let v = toByte(falloff(normalizedRadius(x, y)));
            let v2 = (v * v + 127) / 255;
            argb(255, v2, v2, v2)
        })

    /// 翳りの画素列（ARGB・行優先）。中心が黒・縁で白、alpha は常に不透明。
    /// Multiply の「白は素通し」で縁は何も変えず、中心だけ暗く沈む。強さは画素に
    /// 反映せず、置く側の alpha（Render.darkAt の strength）で調整する。
    /// Add に使うと常に明るく足されて翳りにならない — Multiply 専用。
    pub def darkPixels(): Vector[Int32] =
        pixels((x, y) -> {
            let v = toByte(1.0 - falloff(normalizedRadius(x, y)));
            argb(255, v, v, v)
        })

    /// size×size の全画素を pixelOf(x, y) で埋めた列（行優先）。
    def pixels(pixelOf: (Int32, Int32) -> Int32): Vector[Int32] = region rc {
        let s = size();
        let buf: Array[Int32, rc] = Array.empty(rc, s * s);
        Array.forEachWithIndex((i, _) ->
            Array.put(pixelOf(Int32.remainder(i, s), i / s), i, buf), buf);
        Array.toVector(buf)
    }

    /// 中心 0 → 縁 1 の距離 t を濃さ 0..1 へ写す減衰（smoothstep: x²(3−2x)、x = 1−t）。
    /// 直線減衰にしないのは、縁で傾きが 0 にならず正方形の輪郭が急な切り替わりとして
    /// 見えてしまうため（engine_world の Render.glowAt とも同じ式で、絵の系統が揃う）。
    def falloff(t: Float64): Float64 =
        let x = Num.clamp01(1.0 - t);
        x * x * (3.0 - 2.0 * x)

    /// 画素 (x, y) の、テクスチャ中心からの距離を 0（中心）→ 1（縁）に正規化した値。
    def normalizedRadius(x: Int32, y: Int32): Float64 =
        let half = Int32.toFloat64(size()) / 2.0;
        let dx = Int32.toFloat64(x) + 0.5 - half;
        let dy = Int32.toFloat64(y) + 0.5 - half;
        Num.clamp01(Vec2.length({ x = dx, y = dy }) / half)

    /// ARGB 1 画素を組む（shift 24/16/8/0 = A/R/G/B。SoftRaster.blendPixel と同じ配置）。
    def argb(a: Int32, r: Int32, g: Int32, b: Int32): Int32 =
        Int32.leftShift(a, 24)
            |> Int32.bitwiseOr(Int32.leftShift(r, 16))
            |> Int32.bitwiseOr(Int32.leftShift(g, 8))
            |> Int32.bitwiseOr(b)

    /// 0..1 を 0..255 の Int32 へ丸めてクランプする。
    def toByte(x: Float64): Int32 =
        let v = Float64.tryToInt32(Num.clamp01(x) * 255.0 + 0.5) |> Option.getWithDefault(0);
        Int32.max(0, Int32.min(255, v))
}
