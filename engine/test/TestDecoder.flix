// TestDecoder — engine のテストが PNG / JPEG を解くためのデコーダー（engine の src は javax.imageio を持たない）。
mod TestDecoder {
    import java.awt.image.BufferedImage
    import java.io.ByteArrayInputStream
    import javax.imageio.ImageIO

    pub def imageIo(): ImageData.ImageDecoder = { decode = decode }

    def decode(bytes: Vector[Int8]): Result[String, ImageData.ImageData] \ IO =
        let image = ImageIO.read(new ByteArrayInputStream(unchecked_cast(bytes as Array[Int8, Static])));
        if (Object.isNull(image)) Err("PNG / JPEG として読めない")
        else Ok({ width = image.getWidth(), height = image.getHeight(), argb = argbOf(image) })

    def argbOf(image: BufferedImage): Vector[Int32] \ IO = region rc {
        let w = image.getWidth();
        let h = image.getHeight();
        let buf: Array[Int32, rc] = Array.empty(rc, w * h);
        discard image.getRGB(0, 0, w, h, buf, 0, w);
        Array.toVector(buf)
    }
}
