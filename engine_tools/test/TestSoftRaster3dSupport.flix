// 3D の CPU の描き手のテストが共に使う下ごしらえ（drawScene を直に呼んで描く）。
mod TestSoftRaster3dSupport {
    import java.awt.image.BufferedImage

    /// drawScene を linear = false（0.78 の式）で直に呼び、side × side の不透明の黒の上へ描いた絵。
    /// textures = 場面が読む絵（鍵の色空間は偽の描き手の SoftRaster.mipKeySpace と同じ Linear）。
    pub def renderUnconvertedWith(side: Int32, textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]],
                                  scene: Scene3d.Scene3dCmd): BufferedImage \ IO =
        let img = new BufferedImage(side, side, BufferedImage.TYPE_INT_ARGB);
        List.range(0, side * side) |> List.forEach(k -> img.setRGB(Int32.remainder(k, side), k / side, -16777216));
        SoftRaster3d.drawScene(img, 1.0, textures, false, 0.0, { at = Vec2.zero(), clip = None, scene = scene });
        img

    /// renderUnconvertedWith の、絵を読まない場面の版。
    pub def renderUnconvertedOn(side: Int32, scene: Scene3d.Scene3dCmd): BufferedImage \ IO = renderUnconvertedWith(side, Map.empty(), scene)
}
