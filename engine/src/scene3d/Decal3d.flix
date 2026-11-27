// Decal3d — 壁・床・道に汚れ・血・弾痕・標示を、形の上の薄い板（mesh decal）で貼る。

/// デカール。値は decal で作り、欄は { size = … | Decal3d.decal(…) } で替える。
/// 板はふつうの置いた物（Instance3d）として返すので、描き手は今の不透明・半透明の道のまま描く。
pub mod Decal3d {

    /// 貼る 1 枚。
    /// material = 板の材質（blend も cutout も偽なら buildInstances が半透明にする）・
    /// center = 貼る点・normal = 貼る面の向き（箱は −normal の向きへ投げる。RayHit の点と面の向きをそのまま渡せる）・
    /// size = 箱の幅・高さ・奥行き（場面の長さ。箱は center から前後へ奥行きの半分ずつ延びる。奥行きは面のでこぼこを拾う厚み）・
    /// rotation = normal を軸にした回り（度・正面から見て反時計回り）・uvRect = 絵の中で読む矩形（0..1。1 枚の atlas に血・すす・ひびを並べる時）・
    /// angleCutoff = 投げる向きと面の向きの角がこれ（度）を超える三角形は貼らない（床に投げた血が壁を這い上がらない）・
    /// offset = 面から浮かせる量（場面の長さ。None なら幅と高さの短い方の 1%）。
    pub type alias Decal = { material = Scene3d.Material3d, center = Vec3.Vec3, normal = Vec3.Vec3, size = Vec3.Vec3, rotation = Float64,
                             uvRect = Rect2.Rect2, angleCutoff = Float64, offset = Option[Float64] }

    /// 既定値のデカール（size 1 × 1 × 0.5・rotation 0・uvRect は絵の全部・angleCutoff 70 度・offset は幅と高さの短い方の 1%）。
    // WhyNot: 大きさを引数で受けない — Vec3 が 3 つ並ぶと点・向き・大きさを取り違えても型が通る。
    pub def decal(material: Scene3d.Material3d, center: Vec3.Vec3, normal: Vec3.Vec3): Decal =
        { material = material, center = center, normal = normal, size = Vec3.v3(1.0, 1.0, 0.5), rotation = 0.0,
          uvRect = { position = Vec2.v2(0.0, 0.0), size = Vec2.v2(1.0, 1.0) }, angleCutoff = 70.0, offset = None }

    /// デカールの列を的（targets）に貼った板の置いた物の列（高い・毎コマ呼ばない）。
    /// 重さは箱が掛かる的の三角形の数 × デカールの数。読み込みか当たった時に 1 回呼んで、結果を Resources に持つ（staticGroup と同じ決まり）。
    /// 板は (的, 材質) ごとに world の座標の 1 つの形へつなぎ（world は単位行列・tint は的の tint・lightmap は的の lightmap）、
    /// 形の中はデカールの列の順に並べる（列の後ろが上）。名前は <的の名前>:decal（材質が 2 つ以上なら :decal<1 からの番号>）。
    /// 骨つきの的と半透明の的は貼らずに 1 行言う。どの的にも貼れなければ空の列。
    pub def buildInstances(decals: List[Decal], targets: List[Scene3d.Instance3d]): List[Scene3d.Instance3d] =
        let (placed, warnings) = Decal3d.Internal.Merge.build(decals, targets);
        Log.warnAllThen(warnings, placed)
}
