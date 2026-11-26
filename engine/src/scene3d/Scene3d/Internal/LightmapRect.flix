// Scene3d.Internal.LightmapRect — lightmap の atlas の中の矩形（Scene3d.Lightmap の uvRect）の既定と検査。

/// lightmap の矩形の中身。ゲームは呼ばない（{ uvRect = .. | Scene3d.lightmap(name) } で書く）。
pub mod Scene3d.Internal.LightmapRect {

    /// 絵の全部（位置 (0, 0)・大きさ (1, 1)。読む uv = uv2 × 1 + 0 で、uv2 のまま）。
    pub def whole(): Rect2.Rect2 = { position = Vec2.v2(0.0, 0.0), size = Vec2.v2(1.0, 1.0) }

    /// 描き手がそのまま使える矩形か（大きさが正・4 つの数が有限）。
    pub def isUsable(r: Rect2.Rect2): Bool =
        r#size#x > 0.0 and r#size#y > 0.0 and Float64.isFinite(r#size#x) and Float64.isFinite(r#size#y)
            and Float64.isFinite(r#position#x) and Float64.isFinite(r#position#y)

    /// 使えない矩形の知らせ（使えるなら None）。
    pub def problemOf(texture: String, r: Rect2.Rect2): Option[String] =
        if (isUsable(r)) None
        else Some("scene3d: lightmap ${texture} の uvRect の大きさが 0 以下か数でない — 絵の全部で読む")

    /// 絵の全部の矩形か（描き出しの鍵が既定の時は書かない）。
    pub def isWhole(r: Rect2.Rect2): Bool = r#position#x == 0.0 and r#position#y == 0.0 and r#size#x == 1.0 and r#size#y == 1.0
}
