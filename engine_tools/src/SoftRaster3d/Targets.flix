// SoftRaster3d.Targets — 3D の場面 1 つを Rgba16Float と R32Float の描き先へ置く（層を塗り、書く範囲の画素へ写す）。SoftRaster3d の中身。
// 8bit の描き先は SoftRaster3d.drawScene。

/// 3D の場面を float の描き先へ置く中身（ゲームは呼ばない）。
pub mod SoftRaster3d.Targets {

    /// 場面 cmd を描き先（幅 × 高さ = size・design px → 画素の倍率 sf）に置く所。rect = 場面の矩形の画素（左上・幅・高さ）・
    /// box = clip と描き先で切った書く範囲（左上・幅・高さ）・layer = 層の画素の大きさ（Native は rect の大きさ・Design は場面の design の大きさ）。
    pub type alias SceneRegion = { rect = (Int32, Int32, Int32, Int32), box = (Int32, Int32, Int32, Int32), layer = (Int32, Int32) }

    /// 場面 cmd の SceneRegion（書く範囲が無ければ None）。
    pub def sceneRegionOf(size: (Int32, Int32), sf: Float64, cmd: Scene3d.RenderCmd): Option[SceneRegion] =
        let (width, height) = size;
        let scene = cmd#scene;
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, { position = cmd#at, size = scene#size });
        let dw = rx1 - rx0;
        let dh = ry1 - ry0;
        let (cx0, cy0, cx1, cy1) = match cmd#clip {
            case None    => (rx0, ry0, rx1, ry1)
            case Some(r) => DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, r)
        };
        let x0 = Int32.max(0, Int32.max(rx0, cx0));
        let y0 = Int32.max(0, Int32.max(ry0, cy0));
        let x1 = Int32.min(width, Int32.min(rx1, cx1));
        let y1 = Int32.min(height, Int32.min(ry1, cy1));
        let w = x1 - x0;
        let h = y1 - y0;
        if (dw <= 0 or dh <= 0 or w <= 0 or h <= 0 or scene#size#x <= 0.0 or scene#size#y <= 0.0) None
        else {
            let layer = match scene#resolution {
                case Scene3d.Resolution.Native => (dw, dh)
                case Scene3d.Resolution.Design =>
                    (Int32.max(1, SoftRaster3d.Internal.roundInt(scene#size#x)), Int32.max(1, SoftRaster3d.Internal.roundInt(scene#size#y)))
            };
            Some({ rect = (rx0, ry0, dw, dh), box = (x0, y0, w, h), layer = layer })
        }

    /// 場面 cmd を 1 画素 4 つの層に塗り、書く範囲の描き先の画素ごとに put(描き先の画素の番号, 層, 層の画素の番号 × 4) を呼ぶ。
    def drawLayerWith(size: (Int32, Int32), sf: Float64, textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]],
                      time: Float64, cmd: Scene3d.RenderCmd, put: (Int32, Array[Float64, Static], Int32) -> Unit \ IO): Unit \ IO =
        let (width, _) = size;
        sceneRegionOf(size, sf, cmd) |> Option.forEach(placed -> {
            let (rx0, ry0, dw, dh) = placed#rect;
            let (x0, y0, w, h) = placed#box;
            let (lw, lh) = placed#layer;
            let layer: Array[Float64, Static] = Array.repeat(Static, lw * lh * 4, 0.0);
            SoftRaster3d.renderLayer(cmd#scene, lw, lh, textures, time, SoftRaster3d.LayerOut.Rgba(layer));
            List.range(0, h) |> List.forEach(j -> {
                let ly = SoftRaster3d.nearestIndex(y0 + j - ry0, dh, lh);
                List.range(0, w) |> List.forEach(i -> put((y0 + j) * width + x0 + i, layer, (ly * lw + SoftRaster3d.nearestIndex(x0 + i - rx0, dw, lw)) * 4))
            })
        })

    /// drawScene の Rgba16Float の描き先版。rgba = 描き先（1 画素に r, g, b, α の 4 つ）・size = その幅と高さ。
    /// 層は色を切らずに塗り（emission が 1 を超えて残る）、SoftRaster.blendPixelF の Normal で重ねる。
    pub def drawSceneHdr(rgba: Array[Float64, Static], size: (Int32, Int32), sf: Float64, textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]],
                         time: Float64, cmd: Scene3d.RenderCmd): Unit \ IO =
        drawLayerWith(size, sf, textures, time, cmd, (at, layer, k) ->
            SoftRaster.blendPixelF(DrawCmd.BlendMode.Normal, Array.get(k, layer), Array.get(k + 1, layer), Array.get(k + 2, layer),
                                   Array.get(k + 3, layer), rgba, at))

    /// drawScene の R32Float の描き先版（奥行きの絵の Pass）。層の赤を置き換えで (赤, 0, 0, 1) に書く（GPU の R32Float の描き先は blend しない・half に丸めない）。
    /// 層の α が 0 の画素（場面が何も描かない所）は描き先の値を残す。
    pub def drawSceneR32(rgba: Array[Float64, Static], size: (Int32, Int32), sf: Float64, textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]],
                         time: Float64, cmd: Scene3d.RenderCmd): Unit \ IO =
        drawLayerWith(size, sf, textures, time, cmd, (at, layer, k) ->
            if (Array.get(k + 3, layer) <= 0.0) ()
            else {
                let o = at * 4;
                Array.put(Array.get(k, layer), o, rgba);
                Array.put(0.0, o + 1, rgba);
                Array.put(0.0, o + 2, rgba);
                Array.put(1.0, o + 3, rgba)
            })
}
