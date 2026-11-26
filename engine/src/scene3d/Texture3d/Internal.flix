// Texture3d.Internal — 絵ごとに 1 回だけ求める控え（環境マップの拡散の光）を描き手と SphericalHarmonics へ渡す口と、.hdr（RGBE）の解き方。

/// Texture3d の中身。ゲームは呼ばない。
pub mod Texture3d.Internal {
    import java.lang.{Float => JFloat}

    /// 絵 t を正距円筒の景色として求めた拡散の光の控え（初めて force した時に 1 回だけ求める）。
    pub def irradianceOf(t: Texture3d.Texture3d): Lazy[Option[SphericalHarmonics.SphericalHarmonics]] = Texture3d.recOf(t)#irradiance

    /// 画素の在りか source（width × height）の拡散の光。8bit の絵は sRGB の値を線形の量へ戻して足し、half の絵はそのまま足す。機種の側の絵は画素が無いので None。
    pub def equirectangularIrradianceOf(width: Int32, height: Int32, source: Texture3d.Source): Option[SphericalHarmonics.SphericalHarmonics] =
        match source {
            case Texture3d.Source.PlatformImage(_) => None
            case Texture3d.Source.Argb(argb)       => region rc {
                let toLinear = Vector.range(0, 256) |> Vector.map(v -> Texture3d.srgbToLinear(Int32.toFloat64(v) / 255.0)) |> Vector.toArray(rc);
                let pixels = Vector.toArray(rc, argb);
                SphericalHarmonics.Internal.fromLinear(rc, width, height, (x, y, out) -> {
                    let p = Array.get(y * width + x, pixels);
                    Array.put(Array.get(Int32.bitwiseAnd(Int32.rightShift(p, 16), 255), toLinear), 0, out);
                    Array.put(Array.get(Int32.bitwiseAnd(Int32.rightShift(p, 8), 255), toLinear), 1, out);
                    Array.put(Array.get(Int32.bitwiseAnd(p, 255), toLinear), 2, out)
                })
            }
            case Texture3d.Source.Rgba16Float(halves) => region rc {
                let values = Vector.toArray(rc, halves);
                SphericalHarmonics.Internal.fromLinear(rc, width, height, (x, y, out) -> {
                    let at = (y * width + x) * 4;
                    Array.put(fromHalfBits(Array.get(at, values)), 0, out);
                    Array.put(fromHalfBits(Array.get(at + 1, values)), 1, out);
                    Array.put(fromHalfBits(Array.get(at + 2, values)), 2, out)
                })
            }
        }

    /// half の絵を材質の Tex が読んだ時の知らせ（3 つの描き手で同じ文面。どれも 0 で読む）。
    pub def hdrInMaterialLine(name: String): String =
        "scene3d: HDR の絵 '${name}' は環境マップと lightmap だけが読む — 材質の Tex は 0（黒・透明）で読む"

    /// half の bit の 1（α に入れる）。
    def halfOne(): Int16 = 15360i16

    /// Radiance の .hdr（RGBE）を解いた (幅, 高さ, half の bit の並び（1 画素 r, g, b, α = 1・行 0 が絵の上）)。
    /// 見出しは #?RADIANCE か #?RGBE で始まり、FORMAT があれば 32-bit_rle_rgbe・大きさの行は -Y 高さ +X 幅 だけ。行は新しい RLE（2 2 hi lo で始まる）か平らな RGBE。
    /// 値は RGBE の m × 2^(e − 136)（e = 0 は 0）を half に丸めた物。
    // WhyNot: 画素を Vector とクロージャーで回さない — 2048 × 1024 で 200 万画素になり、箱が画素ごとに作られる（Mip.build の WhyNot）。配列へ数を数える輪で書く。
    pub def decodeRadiance(bytes: Vector[Int8]): Result[String, (Int32, Int32, Vector[Int16])] = region rc {
        let data = Vector.toArray(rc, bytes);
        let n = Array.length(data);
        let lineEnd = (start: Int32) -> lineEndFrom(data, n, start);
        let first = asciiOf(data, 0, lineEnd(0));
        if (not (String.startsWith(prefix = "#?RADIANCE", first) or String.startsWith(prefix = "#?RGBE", first))) Err("Texture3d.decodeHdr: Radiance の .hdr でない（頭が #?RADIANCE でも #?RGBE でもない）")
        else match headerEnd(data, n, lineEnd(0) + 1) {
            case Err(e) => Err(e)
            case Ok((formatOk, resolutionAt)) =>
                if (not formatOk) Err("Texture3d.decodeHdr: FORMAT が 32-bit_rle_rgbe でない（XYZE は読まない）")
                else {
                    let resolutionEnd = lineEnd(resolutionAt);
                    match sizeOf(asciiOf(data, resolutionAt, resolutionEnd)) {
                        case Err(e) => Err(e)
                        case Ok((w, h)) =>
                            if (w <= 0 or h <= 0 or w > Texture3d.maxSide() or h > Texture3d.maxSide()) Err("Texture3d.decodeHdr: 大きさが 1〜${Texture3d.maxSide()} の外（${w} × ${h}）")
                            else {
                                let out = Array.repeat(rc, w * h * 4, halfOne());
                                let scales = Vector.range(0, 256) |> Vector.map(e -> if (e == 0) 0.0 else Float64.pow(base = 2.0, Int32.toFloat64(e - 136))) |> Vector.toArray(rc);
                                let row = Array.repeat(rc, w * 4, 0);
                                decodeRows(data, n, w, h, row, scales, out, resolutionEnd + 1, 0) |> Result.map(_ -> (w, h, Array.toVector(out)))
                            }
                    }
                }
        }
    }

    /// start から見て次の改行（0x0A）の位置（無ければ n）。
    def lineEndFrom(data: Array[Int8, r], n: Int32, start: Int32): Int32 \ r =
        if (start >= n or Int8.toInt32(Array.get(start, data)) == 10) start else lineEndFrom(data, n, start + 1)

    /// data の [start, to) を ASCII の字に。
    def asciiOf(data: Array[Int8, r], start: Int32, to: Int32): String \ r =
        String.fromBytes(List.range(start, Int32.min(to, start + 256)) |> List.map(i -> Array.get(i, data)) |> List.toVector)

    /// 見出しの残り（start から空行まで）を読み、(FORMAT が読める形か, 大きさの行の位置)。
    def headerEnd(data: Array[Int8, r], n: Int32, start: Int32): Result[String, (Bool, Int32)] \ r =
        headerEndWith(data, n, start, true)

    def headerEndWith(data: Array[Int8, r], n: Int32, start: Int32, formatOk: Bool): Result[String, (Bool, Int32)] \ r =
        if (start >= n) Err("Texture3d.decodeHdr: 見出しの終わり（空行）が無い")
        else {
            let end = lineEndFrom(data, n, start);
            let line = asciiOf(data, start, end);
            if (end == start) Ok((formatOk, start + 1))
            else if (String.startsWith(prefix = "FORMAT=", line)) headerEndWith(data, n, end + 1, formatOk and String.trim(line) == "FORMAT=32-bit_rle_rgbe")
            else headerEndWith(data, n, end + 1, formatOk)
        }

    /// 大きさの行（-Y 高さ +X 幅）の (幅, 高さ)。ほかの向きは Err。
    def sizeOf(line: String): Result[String, (Int32, Int32)] =
        match TextSplit.split(" ", String.trim(line)) |> List.filter(s -> not String.isEmpty(s)) {
            case "-Y" :: h :: "+X" :: w :: Nil =>
                match (Int32.parse(10, w), Int32.parse(10, h)) {
                    case (Ok(wi), Ok(hi)) => Ok((wi, hi))
                    case _                => Err("Texture3d.decodeHdr: 大きさの行が読めない（${line}）")
                }
            case _ => Err("Texture3d.decodeHdr: 向きは -Y 高さ +X 幅 だけ読む（${line}）")
        }

    /// 行 y から下を解いて out へ書く。at = 次に読むバイトの位置。
    def decodeRows(data: Array[Int8, r], n: Int32, w: Int32, h: Int32, row: Array[Int32, r], scales: Array[Float64, r], out: Array[Int16, r], at: Int32, y: Int32): Result[String, Unit] \ r =
        if (y >= h) Ok(())
        else match readRow(data, n, w, row, at) {
            case Err(e)   => Err("Texture3d.decodeHdr: 行 ${y}: ${e}")
            case Ok(next) =>
                writeRow(w, row, scales, out, y * w * 4, 0);
                decodeRows(data, n, w, h, row, scales, out, next, y + 1)
        }

    /// 1 行の RGBE を row（チャンネルごとに w 個: r の並び・g の並び・b の並び・e の並び）へ読み、次の位置を返す。
    def readRow(data: Array[Int8, r], n: Int32, w: Int32, row: Array[Int32, r], at: Int32): Result[String, Int32] \ r =
        let byteAt = (i: Int32) -> if (i < n) Int32.bitwiseAnd(Int8.toInt32(Array.get(i, data)), 255) else -1;
        if (at + 4 > n) Err("バイトが足りない")
        else if (w >= 8 and w < 32768 and byteAt(at) == 2 and byteAt(at + 1) == 2 and Int32.bitwiseOr(Int32.leftShift(byteAt(at + 2), 8), byteAt(at + 3)) == w)
            readRleChannel(data, n, w, row, 0, 0, at + 4)
        else if (byteAt(at) == 1 and byteAt(at + 1) == 1 and byteAt(at + 2) == 1) Err("古い形の RLE は読まない（Blender か oiiotool で書き直す）")
        else if (at + 4 * w > n) Err("バイトが足りない")
        else { readFlat(data, w, row, at, 0); Ok(at + 4 * w) }

    /// 平らな行（画素ごとに r, g, b, e）。
    def readFlat(data: Array[Int8, r], w: Int32, row: Array[Int32, r], at: Int32, x: Int32): Unit \ r =
        if (x >= w) ()
        else {
            foreach (c <- List.range(0, 4)) {
                Array.put(Int32.bitwiseAnd(Int8.toInt32(Array.get(at + 4 * x + c, data)), 255), c * w + x, row)
            };
            readFlat(data, w, row, at, x + 1)
        }

    /// 新しい RLE のチャンネル c の x から先（count > 128 は次のバイトを count − 128 個・ほかは count 個をそのまま）。
    def readRleChannel(data: Array[Int8, r], n: Int32, w: Int32, row: Array[Int32, r], c: Int32, x: Int32, at: Int32): Result[String, Int32] \ r =
        if (c >= 4) Ok(at)
        else if (x >= w) readRleChannel(data, n, w, row, c + 1, 0, at)
        else if (at >= n) Err("バイトが足りない")
        else {
            let count = Int32.bitwiseAnd(Int8.toInt32(Array.get(at, data)), 255);
            if (count > 128) {
                let length = count - 128;
                if (x + length > w or at + 1 >= n) Err("RLE の長さが行の外に出る")
                else {
                    let v = Int32.bitwiseAnd(Int8.toInt32(Array.get(at + 1, data)), 255);
                    fillRun(row, c * w + x, length, v);
                    readRleChannel(data, n, w, row, c, x + length, at + 2)
                }
            } else if (count == 0 or x + count > w or at + 1 + count > n) Err("RLE の長さが行の外に出る")
            else {
                copyRun(data, row, at + 1, c * w + x, count);
                readRleChannel(data, n, w, row, c, x + count, at + 1 + count)
            }
        }

    def fillRun(row: Array[Int32, r], start: Int32, count: Int32, v: Int32): Unit \ r =
        if (count <= 0) () else { Array.put(v, start, row); fillRun(row, start + 1, count - 1, v) }

    def copyRun(data: Array[Int8, r], row: Array[Int32, r], src: Int32, dst: Int32, count: Int32): Unit \ r =
        if (count <= 0) () else { Array.put(Int32.bitwiseAnd(Int8.toInt32(Array.get(src, data)), 255), dst, row); copyRun(data, row, src + 1, dst + 1, count - 1) }

    /// row の RGBE を half の bit にして out の base から書く（α は 1 のまま）。
    def writeRow(w: Int32, row: Array[Int32, r], scales: Array[Float64, r], out: Array[Int16, r], base: Int32, x: Int32): Unit \ r =
        if (x >= w) ()
        else {
            let s = Array.get(Array.get(3 * w + x, row), scales);
            Array.put(toHalfBits(Int32.toFloat64(Array.get(x, row)) * s), base + 4 * x, out);
            Array.put(toHalfBits(Int32.toFloat64(Array.get(w + x, row)) * s), base + 4 * x + 1, out);
            Array.put(toHalfBits(Int32.toFloat64(Array.get(2 * w + x, row)) * s), base + 4 * x + 2, out);
            writeRow(w, row, scales, out, base, x + 1)
        }

    /// x を half の bit に（half の最大 65504 で頭打ち・負の向きも同じ）。
    // WhyNot: 65504 を超える値を無限大のままにしない — .hdr の太陽は 10 万を超えることがあり、無限大は段の平均と拡散の光（SH）を全部無限大・NaN にする。
    pub def toHalfBits(x: Float64): Int16 = JFloat.floatToFloat16(RenderUtil.f32(Float64.max(-65504.0, Float64.min(65504.0, x))))

    /// half の bit の値。
    pub def fromHalfBits(b: Int16): Float64 = Float32.toFloat64(JFloat.float16ToFloat(b))
}
