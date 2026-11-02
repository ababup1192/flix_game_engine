// Texture3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 3D の材質が読む絵（閉じた型 — 作る関数からだけ作り、画素と contentHash が食い違わない）。
/// 場面の textures に入れると、材質の Tex が name の名前で読む。GL は contentHash ごとに 1 回だけ GPU へ上げる。
pub mod Texture3d {
    import java.awt.image.BufferedImage
    import java.io.ByteArrayInputStream
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

    /// PNG / JPEG のバイトを画素に戻す（javax.imageio）。読めない・辺が fromArgb の決まりの外、は Err。
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
