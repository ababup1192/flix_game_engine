// Texture3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 3D の材質が読む絵（閉じた型 — 作る関数からだけ作り、画素と contentHash が食い違わない）。
/// 場面の textures に入れると、材質の Tex が name の名前で読む。GL は contentHash ごとに 1 回だけ GPU へ上げる。
pub mod Texture3d {
    import java.awt.image.BufferedImage
    import java.io.ByteArrayInputStream
    import java.lang.Math
    import java.nio.ByteBuffer
    import java.security.MessageDigest
    import javax.imageio.ImageIO

    /// width × height・argb = ARGB（行優先・行 0 が絵の上）・hash = 寸法と画素の SHA-256 の 16 進。
    type alias Texture3dRec = { width = Int32, height = Int32, argb = Vector[Int32], hash = String }

    enum Texture3dData { case Texture3dData(Texture3dRec) }

    pub type alias Texture3d = Texture3dData

    def recOf(t: Texture3d): Texture3dRec = let Texture3dData.Texture3dData(r) = t; r

    /// 辺の上限（GL 3.3 が約束する大きさより大きいが、今の GPU なら作れる）。
    pub def maxSide(): Int32 = 8192

    /// ARGB（行優先・行 0 が絵の上）から作る。数の食い違い・辺が 0 以下・辺が maxSide() を超える、は Err。
    pub def fromArgb(width: Int32, height: Int32, argb: Vector[Int32]): Result[String, Texture3d] =
        if (width <= 0 or height <= 0) Err("Texture3d.fromArgb: 辺が 0 以下（${width} × ${height}）")
        else if (width > maxSide() or height > maxSide()) Err("Texture3d.fromArgb: 辺が ${maxSide()} を超える（${width} × ${height}）")
        else if (Vector.length(argb) != width * height) Err("Texture3d.fromArgb: argb の数が ${width} × ${height} でない")
        else Ok(Texture3dData.Texture3dData({ width = width, height = height, argb = argb, hash = hashOf(width, height, argb) }))

    /// 解いた絵から作る（決まりは fromArgb と同じ）。
    pub def fromImage(image: ImageData.ImageData): Result[String, Texture3d] = fromArgb(image#width, image#height, image#argb)

    /// PNG / JPEG のバイトを decoder で画素に戻して作る（decoder は LoadProgress.imageDecoder() で受け取る）。
    /// 読めない・辺が fromArgb の決まりの外、は Err。
    pub def decodeUsing(decoder: ImageData.ImageDecoder, bytes: Vector[Int8]): Result[String, Texture3d] \ IO =
        (decoder#decode)(bytes) |> Result.mapErr(e -> "Texture3d.decodeUsing: ${e}") |> Result.flatMap(fromImage)

    /// PNG / JPEG のバイトを画素に戻す（javax.imageio）。読めない・辺が fromArgb の決まりの外、は Err。
    /// 0.84.0 で消える: decodeUsing(LoadProgress.imageDecoder() で受け取った物, bytes) に替える（engine に機種の物を置かないため）。
    pub def decode(bytes: Vector[Int8]): Result[String, Texture3d] \ IO =
        let image = ImageIO.read(new ByteArrayInputStream(unchecked_cast(bytes as Array[Int8, Static])));
        if (Object.isNull(image)) Err("Texture3d.decode: PNG / JPEG として読めない")
        else fromArgb(image.getWidth(), image.getHeight(), argbOf(image))

    def argbOf(image: BufferedImage): Vector[Int32] \ IO = region rc {
        let w = image.getWidth();
        let h = image.getHeight();
        let buf: Array[Int32, rc] = Array.empty(rc, w * h);
        discard image.getRGB(0, 0, w, h, buf, 0, w);
        Array.toVector(buf)
    }

    pub def width(t: Texture3d): Int32 = recOf(t)#width

    pub def height(t: Texture3d): Int32 = recOf(t)#height

    /// ARGB（行優先・行 0 が絵の上）。
    pub def argb(t: Texture3d): Vector[Int32] = recOf(t)#argb

    /// 中身の鍵（寸法と画素の SHA-256 の 16 進）。同じ画素なら同じ字になる。
    pub def contentHash(t: Texture3d): String = recOf(t)#hash

    /// 材質の Tex の読み先の名前（"tex3d:" + contentHash の頭 16 字）。場面の textures に入れた絵はこの名前で引く。
    pub def name(t: Texture3d): String = namePrefix() + String.takeLeft(16, contentHash(t))

    /// 場面の textures から引く名前の頭（GL と CPU が名前の引き分けに使う）。
    pub def namePrefix(): String = "tex3d:"

    /// 長い辺が maxSide 以下になるまで半分にした絵（mip の段を作るのと同じ縮め方。もう収まっていれば t のまま）。
    /// 大きすぎる絵を読み込みの時に縮め、場面の絵の上限（project.json の scene3dTextureBudgetMB）に収めるのに使う。
    pub def limitSize(maxSide: Int32, t: Texture3d): Texture3d =
        let r = recOf(t);
        if (Int32.max(r#width, r#height) <= maxSide) t
        else {
            let small = Mip.shrinkTo(maxSide, { width = r#width, height = r#height, pixels = r#argb });
            Texture3dData.Texture3dData({ width = small#width, height = small#height, argb = small#pixels,
                                          hash = hashOf(small#width, small#height, small#pixels) })
        }

    // ── 色空間（8bit の絵の値の意味）──

    /// 8bit の絵の値の意味。Srgb = sRGB の曲線で書いた値（Blender の PNG・色の絵）・Linear = 値がそのまま量（法線マップ・数値の絵）。
    pub enum ColorSpace with Eq, Order, Hash, ToString {
        case Srgb
        case Linear
    }

    /// 3D の描き手が絵を貼る使い方（段の平均の仕方を決める）。MaterialTexture = 材質の色の絵（Srgb として平均する）・
    /// NormalMap = 法線マップ（Linear）・Lightmap = ベイクした光（その色空間）。
    // WhyNot: 絵ごとに色空間を持たせない — 材質の色は Spec の出口でまとめて線形へ戻すので、絵ごとの色空間を読むのは段の平均と lightmap だけ。
    //   数の絵（mask・ノイズ）を材質に貼った時は遠くの段が少し変わる。Linear で平均したい使い手が出たら、ここに使い方を足す。
    pub enum TextureUse with Eq, Order, Hash, ToString {
        case MaterialTexture
        case NormalMap
        case Lightmap(ColorSpace)
    }

    /// 3D の色を線形の量で計算する描き手が、使い方 textureUse の絵の段を平均する時の色空間（GL と CPU が同じ判定を使う）。
    /// 画素の値のまま計算する描き手はこれを呼ばず、全部 Linear で平均する。
    pub def mipSpaceOf(textureUse: TextureUse): ColorSpace = match textureUse {
        case TextureUse.MaterialTexture => ColorSpace.Srgb
        case TextureUse.NormalMap       => ColorSpace.Linear
        case TextureUse.Lightmap(space) => space
    }

    /// 色空間 space の絵の段の平均の仕方（Mip.build に渡す）。
    pub def mipAverageOf(space: ColorSpace): Mip.Average = match space {
        case ColorSpace.Srgb   => Mip.Average.SrgbCurve
        case ColorSpace.Linear => Mip.Average.Raw
    }

    /// sRGB の曲線で書いた値 s（0〜1）を線形の量へ戻す（区分の式: s ≦ 0.04045 は s / 12.92、ほかは ((s + 0.055) / 1.055)^2.4）。
    pub def srgbToLinear(s: Float64): Float64 =
        if (s <= srgbEdge()) s / srgbSlope()
        else Float64.pow({ base = (s + srgbOffset()) / (1.0 + srgbOffset()) }, srgbGamma())

    /// 線形の量 l を sRGB の曲線の値へ（l ≦ 0.0031308 は 12.92 l、ほかは 1.055 l^(1/2.4) − 0.055）。1 を超えても同じ式で返し、負は 0。
    pub def linearToSrgb(l: Float64): Float64 =
        let x = Float64.max(0.0, l);
        if (x <= linearEdge()) x * srgbSlope()
        else (1.0 + srgbOffset()) * Float64.pow({ base = x }, 1.0 / srgbGamma()) - srgbOffset()

    /// 色の 3 成分をそれぞれ srgbToLinear で線形の量へ戻した色（1 を超える成分も同じ式で伸ばす）。
    /// 3D の描き手が場面ごと・物ごとの色（光の color・ambient・tint・かすみ・空）を線形の量で計算する時に通す。
    pub def srgbToLinearColor(c: Color): Color =
        Color.rgb(srgbToLinear(c#r), srgbToLinear(c#g), srgbToLinear(c#b))

    /// srgbToLinear と linearToSrgb を、0〜1 を lutSteps() 段に刻んだ表と隣り合う 2 点の間の直線で近づけた物（閉じた型。colorLut で作る）。
    /// CPU の描き手が画素ごとに色を変換する時に使う（式との差は 8bit の 1 段の 1/100 未満）。
    // WhyNot: 画素ごとに式（pow）を呼ばない — 材質の画素は albedo・emission・出口で最大 9 回変換し、CPU の 3D の描き出しが 1 割を超えて遅くなる。
    enum ColorLutData { case ColorLutData(Vector[Float64], Vector[Float64]) }

    pub type alias ColorLut = ColorLutData

    /// 表の段の数（表の点は 0 から 1 まで lutSteps() + 1 個）。
    pub def lutSteps(): Int32 = 4096

    /// srgbToLinear と linearToSrgb の表を作る（場面を描く前に 1 回）。
    pub def colorLut(): ColorLut =
        let n = lutSteps();
        let at = (k: Int32) -> Int32.toFloat64(k) / Int32.toFloat64(n);
        ColorLutData.ColorLutData(Vector.range(0, n + 1) |> Vector.map(k -> srgbToLinear(at(k))),
                                  Vector.range(0, n + 1) |> Vector.map(k -> linearToSrgb(at(k))))

    /// srgbToLinear の表の版（0〜1 の外は式のまま）。
    pub def srgbToLinearLut(lut: ColorLut, s: Float64): Float64 =
        let ColorLutData.ColorLutData(toLinear, _) = lut;
        if (s >= 0.0 and s <= 1.0) lerpTable(toLinear, s) else srgbToLinear(s)

    /// linearToSrgb の表の版（0〜1 の外は式のまま。負は 0・1 を超えても切らない）。
    pub def linearToSrgbLut(lut: ColorLut, l: Float64): Float64 =
        let ColorLutData.ColorLutData(_, toSrgb) = lut;
        if (l >= 0.0 and l <= 1.0) lerpTable(toSrgb, l) else linearToSrgb(l)

    /// 0〜1 の x の、表 table（lutSteps() + 1 個）の隣り合う 2 点の間の直線の値。
    def lerpTable(table: Vector[Float64], x: Float64): Float64 =
        let n = lutSteps();
        let scaled = x * Int32.toFloat64(n);
        // WhyNot: Float64.clampToInt32 や tryToInt32 で整数にしない — 画素ごとにレコードか Option を作る。x は 0〜1 なので Java の切り捨てで足りる。
        let i = Int32.min(n - 1, unchecked_cast(Math.toIntExact(Math.round(Math.floor(scaled))) as _ \ {}));
        let t = scaled - Int32.toFloat64(i);
        let a = Vector.get(i, table);
        a + (Vector.get(i + 1, table) - a) * t

    /// srgbToLinear と同じ式の GLSL の関数（float → float）。名前は呼ぶ側が決める（ShaderGen の sg_ と重ねない）。
    // WhyNot: この関数を vec3 の版にしない — 光の式の木（LightModel3d）は成分ごとに書くので、vec3 で呼ぶと 1 成分のために 3 成分を計算する。
    //   木の外の色の変換（材質の出口・頂点の色）は render_gl の Render3dGlsl がこの関数を成分ごとに呼ぶ vec3 の版を持つ。
    pub def srgbToLinearGlsl(name: String): String =
        "float ${name}(float s) {\n" +
        "    return s <= ${glslFloat(srgbEdge())} ? s / ${glslFloat(srgbSlope())}\n" +
        "                                   : pow((s + ${glslFloat(srgbOffset())}) / ${glslFloat(1.0 + srgbOffset())}, ${glslFloat(srgbGamma())});\n" +
        "}\n"

    /// linearToSrgb と同じ式の GLSL の関数（float → float。負は 0・1 を超えても切らない）。
    pub def linearToSrgbGlsl(name: String): String =
        "float ${name}(float l) {\n" +
        "    float x = max(l, 0.0);\n" +
        "    return x <= ${glslFloat(linearEdge())} ? x * ${glslFloat(srgbSlope())}\n" +
        "                                   : ${glslFloat(1.0 + srgbOffset())} * pow(x, 1.0 / ${glslFloat(srgbGamma())}) - ${glslFloat(srgbOffset())};\n" +
        "}\n"

    def srgbEdge(): Float64 = 0.04045
    def linearEdge(): Float64 = 0.0031308
    def srgbSlope(): Float64 = 12.92
    def srgbOffset(): Float64 = 0.055
    def srgbGamma(): Float64 = 2.4

    /// GLSL の float の字（整数に見える数にも小数点を付ける）。
    def glslFloat(x: Float64): String =
        let s = Float64.toString(x);
        if (String.contains(substr = ".", s) or String.contains(substr = "E", s)) s else s + ".0"

    // WhyNot: 画素を文字列につないでから SHA を取らない — 1024² の絵で数十 MB の字を作ることになる。
    def hashOf(width: Int32, height: Int32, argb: Vector[Int32]): String =
        unsafe IO {
            let buffer = ByteBuffer.allocate(8 + Vector.length(argb) * 4);
            discard buffer.putInt(width);
            discard buffer.putInt(height);
            discard buffer.asIntBuffer().put(unchecked_cast(argb as Array[Int32, Static]));
            let digest = MessageDigest.getInstance("SHA-256").digest(buffer.array());
            Util.Codec.encodeHex(Array.toVector(digest))
        }
}
