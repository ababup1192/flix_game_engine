// SoftRaster.Internal.Surface — 宣言シェーダーの面を画素ごとに評価して描く（mask・縮んだターゲットの評価点つき）。
// SoftRaster の中身。
// ゲームからは呼ばない（SoftRaster の中身。ゲーム向けの関数は SoftRaster にある）。
pub mod SoftRaster.Internal.Surface {
    import java.awt.image.BufferedImage
    import java.util.concurrent.ConcurrentHashMap
    use SoftRaster.{HdrCanvas, SurfaceCmd, argbOfRgba, blendPixel, blendPixelF, forEachPixel, onceOutsideLoop, pickedPixel, shadeAll}
    use SoftRaster.Internal.Hdr.{writeRule}

    /// シェーダー面を画素ごとに描き出す。rect を出力ピクセルへ量子化し、各画素の中心を
    /// uv（rect 内 0..1）に写して ShaderEval.compile で組み直した面（色と α を 1 回の shared
    /// 先行評価で一緒に返す）を evalCompiled で評価、blendPixel で本体へ混ぜる
    /// （Normal / Add / Multiply とも GL 側と同じ合成式）。
    /// 描き出しの時間のほとんどはここなので、Spec は面ごとに 1 回だけ組み直し、
    /// 画素は shadeAll でコアの数だけ並べて評価する。
    /// mask が非空なら「どれかの多角形の内側」の画素だけ塗る（GL のステンシル抜きと同じ意図）。
    /// memo があれば、混ぜる前の画素の列を面の入力の字（memoKeyOf）で控え、2 回目に見た同じ面から使い回す
    /// （evalCompiled は面の入力と画素の位置だけで決まる純関数なので、使い回した列は評価し直した列と同じ）。
    pub def drawSurface(image: BufferedImage, sf: Float64, texEnv: Map[String, ShaderEval.TexImage],
                    texels: Option[(Int32, Int32)], memo: Option[SurfaceMemo], s: SurfaceCmd): Unit \ IO = region rc {
        let dw = image.getWidth();
        let dh = image.getHeight();
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, s#rect);
        let x0 = Int32.max(0i32, rx0);
        let y0 = Int32.max(0i32, ry0);
        let x1 = Int32.min(dw, rx1);
        let y1 = Int32.min(dh, ry1);
        let w = x1 - x0;
        let h = y1 - y0;
        if (w <= 0i32 or h <= 0i32 or s#rect#size#x <= 0.0 or s#rect#size#y <= 0.0) ()
        else {
            let n = w * h;
            let buf: Array[Int32, rc] = Array.empty(rc, n);
            discard image.getRGB(x0, y0, w, h, buf, 0i32, w);
            let maskPolys = onceOutsideLoop(rc, List.map(List.toVector, s#mask));
            let blend = onceOutsideLoop(rc, s#blend);
            let sample = onceOutsideLoop(rc, sampleRatios(texels, dw, dh));
            // 下地の画素（読むだけ）。1 画素の答えは下地と面の式だけで決まる純関数なので、
            // どの順・どのスレッドで評価しても同じ画素になる。
            let dstPixels = Array.toVector(buf);
            // 出力ピクセル中心 → design px（縮んだターゲットへ拾う時は、この画素を拾うテクセルの中心 = GL がそのテクセルを塗る点）。
            // 塗らない画素（mask の外・拾われない画素）は None。
            let pointOf = i -> {
                let px = Int32.remainder(i, w) + x0;
                let py = i / w + y0;
                let (pickedX, sampleX) = samplePoint(px, sample |> Option.map(fst), false);
                let (pickedY, sampleY) = samplePoint(py, sample |> Option.map(snd), true);
                let dx = sampleX / sf;
                let dy = sampleY / sf;
                let inside = match maskPolys {
                    case Nil => true
                    case _   => insideMask(maskPolys, { x = dx, y = dy })
                };
                if (not inside or not pickedX or not pickedY) None else Some((dx, dy))
            };
            let src = onceOutsideLoop(rc, srcPixels(rc, texEnv, memo, sf, texels, dw, dh, n, pointOf, s));
            let mixed = shadeAll(n, i -> {
                let dst = Vector.get(i, dstPixels);
                if (Option.isEmpty(pointOf(i))) dst else blendPixel(blend, Vector.get(i, src), dst)
            });
            image.setRGB(x0, y0, w, h, mixed, 0i32, w)
        }
    }

    /// 面の混ぜる前の画素の列（memo に控えがあれば写さずに返し、無ければ評価する。2 回目に見た面の列は控える）。
    def srcPixels(rc: Region[r], texEnv: Map[String, ShaderEval.TexImage], memo: Option[SurfaceMemo],
                  sf: Float64, texels: Option[(Int32, Int32)], dw: Int32, dh: Int32, n: Int32,
                  pointOf: Int32 -> Option[(Float64, Float64)], s: SurfaceCmd): Vector[Int32] \ {IO, r} =
        let key = memo |> Option.flatMap(m -> memoKeyOf(m, sf, texels, dw, dh, s) |> Option.map(k -> (m, k)));
        let remembered = key |> Option.flatMap(match (m, k) -> recallSrc(m, k, n));
        match remembered {
            case Some(src) => src
            case None =>
                let src = evalSrc(rc, texEnv, s, n, pointOf);
                key |> Option.forEach(match (m, k) -> rememberSrc(m, k, src));
                src
        }

    /// 面の画素 0..n−1 の、混ぜる前の ARGB の列（塗らない画素は 0。混ぜる側が pointOf で飛ばす）。
    def evalSrc(rc: Region[r], texEnv: Map[String, ShaderEval.TexImage], s: SurfaceCmd, n: Int32,
                pointOf: Int32 -> Option[(Float64, Float64)]): Vector[Int32] \ {IO, r} =
        let compiled = onceOutsideLoop(rc, ShaderEval.compile(s#spec, texEnv));
        let (ox, oy, sw, sh, time) = onceOutsideLoop(rc,
            (s#rect#position#x, s#rect#position#y, s#rect#size#x, s#rect#size#y, s#time));
        Array.toVector(shadeAll(n, i -> match pointOf(i) {
            case None => 0i32
            case Some((dx, dy)) =>
                let (r, g, b, a0) = ShaderEval.evalCompiled(compiled, (dx - ox) / sw, (dy - oy) / sh, time);
                argbOfRgba(r, g, b, Float64.max(0.0, Float64.min(1.0, a0)))
        }))

    /// シェーダー面の画素の控え: table = 面の入力の字 → 混ぜる前の画素の列、seen = 1 回見た面の字、
    /// pathOf = 名前 → ファイルの絵のパス（控えてよい絵だけ）。
    pub type alias SurfaceMemo = {
        table = ConcurrentHashMap[String, Vector[Int32]],
        seen = ConcurrentHashMap[String, Bool],
        pathOf = String -> Option[String]
    }

    /// 面の入力の字（rect・Spec・time・mask・倍率・拾い方・出力の大きさ・読む絵のパス）。控えてよくない面は None。
    // WhyNot: 字を SHA-256 に畳まない — 字そのものを鍵にすれば、違う面が同じ鍵になることが無い。
    def memoKeyOf(memo: SurfaceMemo, sf: Float64, texels: Option[(Int32, Int32)], dw: Int32, dh: Int32, s: SurfaceCmd): Option[String] =
        let names = ShaderDoc.texNames(s#spec) |> List.distinct;
        let paths = names |> List.map(name -> memo#pathOf(name) |> Option.map(path -> "${name}=${path}"));
        if (List.exists(Option.isEmpty, paths)) None
        else {
            let r = s#rect;
            // WhyNot: doubleToLongBits を使わない — Java の IO になる。Float64.toString は値ごとに 1 つの字（往復で同じ値・-0.0 も別の字）。
            let bits = x -> Float64.toString(x);
            let mask = s#mask |> List.map(path -> path |> List.map(v -> "${bits(v#x)},${bits(v#y)}") |> String.intercalate(" ")) |> String.intercalate("|");
            let fields = bits(r#position#x) :: bits(r#position#y) :: bits(r#size#x) :: bits(r#size#y) ::
                         bits(s#time) :: bits(sf) :: ToString.toString(texels) :: Int32.toString(dw) :: Int32.toString(dh) :: mask ::
                         List.filterMap(identity, paths);
            Some(String.intercalate(";", fields) + "#" + ToString.toString(ShaderJson.toJson(s#spec)))
        }

    /// 控えた列（長さが合う時だけ）。
    def recallSrc(memo: SurfaceMemo, key: String, n: Int32): Option[Vector[Int32]] \ IO =
        let hit: Vector[Int32] = memo#table.get(key);
        if (Object.isNull(hit) or Vector.length(hit) != n) None else Some(hit)

    /// 1 回目に見た面は字だけを seen に控え、2 回目に評価した列を table に控える。どちらも上限を超えたら全部捨てる。
    // WhyNot: 1 回目から列を控えない — 時刻で毎コマ変わる面（雪・切り替えの途中）は 2 度と当たらず、控えが画面の大きさの列で膨らむ。
    def rememberSrc(memo: SurfaceMemo, key: String, src: Vector[Int32]): Unit \ IO =
        let seen = memo#seen;
        let table = memo#table;
        if (seen.containsKey(key)) {
            if (table.size() >= memoLimit()) table.clear() else ();
            discard table.put(key, src)
        } else {
            if (seen.size() >= seenLimit()) seen.clear() else ();
            discard seen.put(key, true)
        }

    /// 控える列の数の上限（1 本は出力の画素の数の Int32。1280×720 なら約 3.7 MB）。
    def memoLimit(): Int32 = 24

    def seenLimit(): Int32 = 4096

    def samplePoint(p: Int32, ratio: Option[Float64], vertical: Bool): (Bool, Float64) =
        match ratio {
            case None => (true, Int32.toFloat64(p) + 0.5)
            case Some(k) =>
                let i = Float64.floor((Int32.toFloat64(p) + 0.5) * k);
                let center = (i + 0.5) / k;
                (pickedPixel(center, vertical) == Int32.toFloat64(p), center)
        }

    /// シェーダー面の Rgba16Float 版（drawSurface と同じ画素・同じ評価点。値は切らずに writeRule で切って blendPixelF で混ぜる）。
    pub def drawSurfaceHdr(canvas: HdrCanvas, sf: Float64, texEnv: Map[String, ShaderEval.TexImage],
                       texels: Option[(Int32, Int32)], s: SurfaceCmd): Unit \ IO = region rc {
        let dw = canvas#width;
        let dh = canvas#height;
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, s#rect);
        let x0 = Int32.max(0i32, rx0);
        let y0 = Int32.max(0i32, ry0);
        let w = Int32.min(dw, rx1) - x0;
        let h = Int32.min(dh, ry1) - y0;
        if (w <= 0i32 or h <= 0i32 or s#rect#size#x <= 0.0 or s#rect#size#y <= 0.0) ()
        else {
            let compiled = onceOutsideLoop(rc, ShaderEval.compile(s#spec, texEnv));
            let maskPolys = onceOutsideLoop(rc, List.map(List.toVector, s#mask));
            let (ox, oy, sw, sh, time) = onceOutsideLoop(rc,
                (s#rect#position#x, s#rect#position#y, s#rect#size#x, s#rect#size#y, s#time));
            let blend = onceOutsideLoop(rc, s#blend);
            let sample = onceOutsideLoop(rc, sampleRatios(texels, dw, dh));
            forEachPixel(w * h, j -> {
                let px = Int32.remainder(j, w) + x0;
                let py = j / w + y0;
                let (pickedX, sampleX) = samplePoint(px, sample |> Option.map(fst), false);
                let (pickedY, sampleY) = samplePoint(py, sample |> Option.map(snd), true);
                let dx = sampleX / sf;
                let dy = sampleY / sf;
                if (not pickedX or not pickedY or not insideMask(maskPolys, { x = dx, y = dy })) ()
                else {
                    let (r0, g0, b0, a0) = ShaderEval.evalCompiled(compiled, (dx - ox) / sw, (dy - oy) / sh, time);
                    let (r, g, b, a) = writeRule(r0, g0, b0, a0);
                    blendPixelF(blend, r, g, b, a, canvas#rgba, py * dw + px)
                }
            })
        }
    }

    /// 縮んだターゲットへ拾う時の、テクセル / 画素の比（横・縦）。None は縮めない。
    def sampleRatios(texels: Option[(Int32, Int32)], dw: Int32, dh: Int32): Option[(Float64, Float64)] =
        texels |> Option.map(t -> {
            let (tw, th) = t;
            (Int32.toFloat64(tw) / Int32.toFloat64(dw), Int32.toFloat64(th) / Int32.toFloat64(dh))
        })

    /// mask が空なら常に真。非空なら「どれかの多角形の内側」（偶奇の交差数判定）。
    def insideMask(mask: List[Vector[Vec2.Vec2]], p: Vec2.Vec2): Bool =
        match mask {
            case Nil => true
            case _   => List.exists(vs -> pointInPoly(vs, p), mask)
        }

    /// 偶奇規則の point-in-polygon（水平レイキャスト）。
    def pointInPoly(vs: Vector[Vec2.Vec2], p: Vec2.Vec2): Bool =
        let n = Vector.length(vs);
        if (n == 0) false
        else Int32.modulo(countCrossings(vs, n, p, 0, 0), 2) == 1

    /// 辺 i→i+1 が p から右へ伸びる水平線を跨ぐ回数を、添字 i から末尾まで数え上げる。
    def countCrossings(vs: Vector[Vec2.Vec2], n: Int32, p: Vec2.Vec2, i: Int32, hits: Int32): Int32 =
        if (i >= n) hits
        else {
            let a = Vector.get(i, vs);
            let b = Vector.get(Int32.modulo(i + 1, n), vs);
            let crosses = ((a#y > p#y) != (b#y > p#y))
                and (p#x < (b#x - a#x) * (p#y - a#y) / (b#y - a#y) + a#x);
            countCrossings(vs, n, p, i + 1, if (crosses) hits + 1 else hits)
        }
}
