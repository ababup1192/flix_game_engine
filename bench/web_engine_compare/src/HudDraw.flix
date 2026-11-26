// HudDraw — K9 の HUD（Scenes.Hud）を engine の 2D（withHudView の絵）で描く。座標は canvas の画素・色は sRGB のまま。
// 奥から 板 → 動かない icon → 名札（下地 → bar → icon → 字）→ 毎コマ変わる字。3D の後がけ（tone map・bloom）は掛からない。
mod HudDraw {
    use fge::{Color, DrawCmd, FontAtlas, RawDraw, Render, Text, Vec2}

    /// icon の atlas（project.json の textures の名前）と、HUD の字（fonts の名前）。
    pub def atlasTexture(): String = "hud_atlas"
    pub def fontName(): String = "hud"

    /// font-bake が src の文字列から字を集めるので、名札と毎コマ変わる字に出る数字をここに置く。
    pub def digits(): String = "0123456789"

    def atlasCell(): Float64 = 32.0
    def atlasCols(): Int32 = 8
    def labelSize(): Float64 = 12.0
    def dynamicSize(): Float64 = 14.0
    def iconSize(): Float64 = 16.0
    def barWidth(): Float64 = 48.0
    def barHeight(): Float64 = 6.0

    def white(): Color = Color.rgb(1.0, 1.0, 1.0)

    /// 名札の字の幅（動かない字なので読み込みの後に 1 回量る）。
    pub def labelWidths(font: FontAtlas, h: Scenes.Hud): Vector[Float64] =
        h#labels |> Vector.map(s -> Text.measure(Text.make(s, font, labelSize()))#x)

    /// atlas の升 cell を、左上 (x, y) に一辺 side で置く。
    def icon(cell: Int32, x: Float64, y: Float64, side: Float64, z: Int32): Render.PlacedItem =
        let col = Int32.toFloat64(Int32.remainder(cell, atlasCols()));
        let row = Int32.toFloat64(cell / atlasCols());
        // WhyNot: side / atlasCell() にしない — 升を切り出しても Sprite の scale は絵の全体（8 升）の大きさに掛かる。
        let k = side / (atlasCell() * Int32.toFloat64(atlasCols()));
        Render.at(Vec2.v2(x, y), Render.Item.Sprite({
            texture = atlasTexture(), tint = white(), alpha = 1.0, scale = Vec2.v2(k, k), rotation = 0.0, centered = false,
            flipH = false, flipV = false, regionRect = Some({ position = Vec2.v2(col * atlasCell(), row * atlasCell()), size = Vec2.v2(atlasCell(), atlasCell()) }),
            zIndex = z, blend = DrawCmd.BlendMode.Normal, maskPolys = Nil, squashY = 1.0 }))

    def rect(x: Float64, y: Float64, w: Float64, hgt: Float64, rgba: (Float64, Float64, Float64, Float64), z: Int32): Render.PlacedItem =
        let (r, g, b, a) = rgba;
        Render.at(Vec2.v2(x, y), RawDraw.box(Vec2.v2(w, hgt), Color.rgb(r, g, b), z) |> Render.fade(a))

    /// 名札 i の 4 つ（z は base + 4i から 4 つ）。
    def nameplate(h: Scenes.Hud, font: FontAtlas, widths: Vector[Float64], base: Int32, i: Int32, p: Scenes.Nameplate): List[Render.PlacedItem] =
        let z = base + i * 4;
        let top = p#y + labelSize() + 2.0;
        let left = p#x - barWidth() / 2.0;
        rect(left, top, barWidth(), barHeight(), (0.0, 0.0, 0.0, 0.6), z) ::
        rect(left, top, barWidth() * p#health, barHeight(), (0.2, 0.9, 0.3, 1.0), z + 1) ::
        icon(Vector.get(i, h#units#cell), left - iconSize() - 2.0, top, iconSize(), z + 2) ::
        Render.at(Vec2.v2(p#x - Vector.get(i, widths) / 2.0, p#y), Render.textTinted(Vector.get(i, h#labels), font, labelSize(), white(), z + 3)) :: Nil

    /// 時刻 t の HUD の絵。plates = 時刻 t の名札（場面の更新として外で作る）。
    pub def items(h: Scenes.Hud, font: FontAtlas, widths: Vector[Float64], plates: Vector[Scenes.Nameplate], t: Float64): List[Render.PlacedItem] =
        let iconZ = List.length(h#panels);
        let plateBase = iconZ + 1;
        let textZ = plateBase + h#units#count * 4;
        let panels = h#panels |> List.mapWithIndex((k, p) -> rect(p#x, p#y, p#w, p#h, p#color, k));
        let icons = List.range(0, Vector.length(h#icons#cell)) |> List.map(i ->
            icon(Vector.get(i, h#icons#cell), Vector.get(i, h#icons#x), Vector.get(i, h#icons#y), atlasCell(), iconZ));
        let names = plates |> Vector.toList |> List.mapWithIndex((i, p) -> nameplate(h, font, widths, plateBase, i, p)) |> List.flatten;
        let texts = List.range(0, Scenes.dynamicTextCount()) |> List.map(i -> {
            let (x, y, s) = Scenes.dynamicTextAt(t, i);
            Render.at(Vec2.v2(x, y), Render.textTinted(s, font, dynamicSize(), white(), textZ))
        });
        panels ::: icons ::: names ::: texts
}
