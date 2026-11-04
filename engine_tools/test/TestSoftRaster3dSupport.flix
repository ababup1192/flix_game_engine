// 3D の CPU の描き手のテストが共に使う下ごしらえ（drawScene を直に呼んで描く）。
mod TestSoftRaster3dSupport {
    import java.awt.image.BufferedImage

    /// drawScene を直に呼び、side × side の不透明の黒の上へ絵を読まない場面を描いた絵。
    pub def renderOn(side: Int32, scene: Scene3d.Scene3dCmd): BufferedImage \ IO =
        let img = new BufferedImage(side, side, BufferedImage.TYPE_INT_ARGB);
        List.range(0, side * side) |> List.forEach(k -> img.setRGB(Int32.remainder(k, side), k / side, -16777216));
        SoftRaster3d.drawScene(img, 1.0, Map.empty(), 0.0, { at = Vec2.zero(), clip = None, scene = scene });
        img
}
