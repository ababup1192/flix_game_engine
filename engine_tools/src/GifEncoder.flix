// GifEncoder — BufferedImage 列をアニメーション GIF ファイルに描き出すエンコーダ。
//
// 外部依存を足さず javax.imageio の GIF ImageWriter でフレーム列を書き出す。各フレームの
// 表示時間は GraphicControlExtension の delayTime（センチ秒）で、無限ループは
// ApplicationExtension（NETSCAPE2.0・loop count 0）で設定する定石実装。
//
// SoftRaster.renderToImage が 1 フレームずつ描き出した BufferedImage を集め、ここで 1 本の
// GIF にまとめる。GL 無しの操作リプレイ動画（呼び出し側が outPath を渡し、任意の場所へ永続化
// する）を作る経路。
pub mod GifEncoder {
    import java.awt.image.BufferedImage
    import java.awt.image.RenderedImage
    import java.io.File
    import java.lang.{Object => JObject}
    import java.util.{List => JList}
    import javax.imageio.ImageIO
    import javax.imageio.ImageWriter
    import javax.imageio.ImageWriteParam
    import javax.imageio.IIOImage
    import javax.imageio.ImageTypeSpecifier
    import javax.imageio.metadata.IIOMetadata
    import javax.imageio.metadata.IIOMetadataNode
    import javax.imageio.stream.FileImageOutputStream
    import org.w3c.dom.Node

    /// アニメ GIF とコマ送りビューア用のコマ別 PNG（`Filmstrip.renderFrames`）をペアで描き出す。
    /// ギャラリーの定石（GIF は流し見・コマ別 PNG は 1 コマずつ精査）を 1 呼び出しにする。
    pub def encodeWithFrames(frames: List[BufferedImage], delayMs: Int32,
                             gifPath: String, framesDir: String): Unit \ IO =
        encode(frames, delayMs, gifPath);
        discard Filmstrip.renderFrames(frames, framesDir)

    /// アニメ GIF を `outPath` へ書き出す。`frames` は同寸の BufferedImage 列、`delayMs` は各フレームの
    /// 表示時間（ms）。無限ループ再生に設定する。frames が空なら何もしない（呼び側の sanity 用）。
    pub def encode(frames: List[BufferedImage], delayMs: Int32, outPath: String): Unit \ IO =
        match frames {
            case Nil => ()
            case _   =>
                let file = new File(outPath);
                let parent = file.getParentFile();
                if (not Object.isNull(parent)) discard parent.mkdirs() else ();
                let writer = firstGifWriter();
                let out = new FileImageOutputStream(file);
                writer.setOutput(unchecked_cast(out as JObject));
                writer.prepareWriteSequence(unchecked_cast(null as IIOMetadata));
                List.forEach(img -> writeFrame(writer, img, delayMs), frames);
                writer.endWriteSequence();
                out.close();
                writer.dispose()
        }

    /// "gif" フォーマットの最初の ImageWriter を取り出す。
    def firstGifWriter(): ImageWriter \ IO =
        let it = ImageIO.getImageWritersByFormatName("gif");
        it.next()

    /// 1 フレームを sequence に書く。フレームごとに default metadata を作り、delay とループを差し込む。
    def writeFrame(writer: ImageWriter, img: BufferedImage, delayMs: Int32): Unit \ IO =
        // TYPE_INT_ARGB(2) の型指定で GIF 用の default image metadata を得る。
        let specifier = ImageTypeSpecifier.createFromBufferedImageType(2i32);
        let meta = writer.getDefaultImageMetadata(specifier, unchecked_cast(null as ImageWriteParam));
        let fmt = meta.getNativeMetadataFormatName();
        let root = unchecked_cast(meta.getAsTree(fmt) as IIOMetadataNode);
        configureGce(root, delayMs);
        configureLoop(root);
        meta.setFromTree(fmt, root);
        let iio = new IIOImage(unchecked_cast(img as RenderedImage), unchecked_cast(null as JList[JObject]), meta);
        writer.writeToSequence(iio, unchecked_cast(null as ImageWriteParam))

    /// GraphicControlExtension に表示時間（センチ秒）と非透過・非破棄を設定する。
    def configureGce(root: IIOMetadataNode, delayMs: Int32): Unit \ IO =
        let gce = getOrCreateChild(root, "GraphicControlExtension");
        gce.setAttribute("disposalMethod", "none");
        gce.setAttribute("userInputFlag", "FALSE");
        gce.setAttribute("transparentColorFlag", "FALSE");
        gce.setAttribute("delayTime", "${delayMs / 10i32}");
        gce.setAttribute("transparentColorIndex", "0")

    /// ApplicationExtension（NETSCAPE2.0）で無限ループを設定する。
    /// userObject は {sub-block id=1, loop count=0（無限・LE 16bit）} の 3 バイト。
    def configureLoop(root: IIOMetadataNode): Unit \ IO =
        let appExts = getOrCreateChild(root, "ApplicationExtensions");
        let child = new IIOMetadataNode("ApplicationExtension");
        child.setAttribute("applicationID", "NETSCAPE");
        child.setAttribute("authenticationCode", "2.0");
        let bytes = Array#{1i8, 0i8, 0i8} @ Static;
        child.setUserObject(unchecked_cast(bytes as JObject));
        discard appExts.appendChild(unchecked_cast(child as Node))

    /// root 直下の name 子を返す。無ければ作って足す。
    def getOrCreateChild(root: IIOMetadataNode, name: String): IIOMetadataNode \ IO =
        match findChild(root, name, 0i32, root.getLength()) {
            case Some(node) => node
            case None       =>
                let node = new IIOMetadataNode(name);
                discard root.appendChild(unchecked_cast(node as Node));
                node
        }

    /// root の子 [i, n) を走査し nodeName == name の最初を返す。
    def findChild(root: IIOMetadataNode, name: String, i: Int32, n: Int32): Option[IIOMetadataNode] \ IO =
        if (i >= n) None
        else {
            let item = root.item(i);
            if (item.getNodeName() == name) Some(unchecked_cast(item as IIOMetadataNode))
            else findChild(root, name, i + 1i32, n)
        }
}
