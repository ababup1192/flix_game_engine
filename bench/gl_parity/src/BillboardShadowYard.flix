// ビルボードの太陽の影（Scene3d.withCastShadows / withReceiveShadows）を描き手どうしで突き合わせる場面の中身（GL と SoftRaster は bench/gl_parity の Scenes・
// GL と WebGPU は bench/webgpu_v2 が木を組む時にこのファイルを写して使う）。
// 見下ろしの町の一角（床・建物・宙に浮いた屋根）に、Pass で描いた人の形のビルボードを 2 枚立てる。1 枚は日なた（影を地面へ落とす）、
// もう 1 枚は屋根の影の中（影を受けて暗くなる）。太陽の向きは 3 つ（カメラの軸・斜め 45°・横）。
// WhyNot: use fge:: を 2 行に分けない — bench/webgpu_v2 は木を組む時にこの 1 行を消して写す（木の中では engine が fge に載らない）。
mod BillboardShadowYard {

    use fge::{Color, Mat4, Mesh3d, Render, RawDraw, RenderTarget, Scene3d, Vec2, Vec3}

    /// 人の形を描く Pass の名前。
    pub def charPassName(): String = "hd2dChar"

    /// Pass の中の人の形の範囲（Pass の画素）。
    def charRegion(): { position = Vec2.Vec2, size = Vec2.Vec2 } = { position = { x = 0.0, y = 0.0 }, size = { x = 24.0, y = 40.0 } }

    /// 人の形（髪・顔・胴・腕・脚。脚の間は透明）を透明の上に描く Pass。
    pub def charPass(): Render.Pass =
        let place = (x: Float64, y: Float64, w: Float64, h: Float64, c: Color) ->
            ({ at = { x = x, y = y }, item = RawDraw.box({ x = w, y = h }, c, 1) }: Render.PlacedItem);
        { name = charPassName(), clear = RenderTarget.LoadOp.ClearTransparent,
          items = place(6.0, 1.0, 12.0, 5.0, Color.rgb(0.35, 0.2, 0.12)) ::
                  place(7.0, 4.0, 10.0, 8.0, Color.rgb(0.95, 0.78, 0.62)) ::
                  place(5.0, 12.0, 14.0, 14.0, Color.rgb(0.25, 0.4, 0.85)) ::
                  place(2.0, 13.0, 3.0, 11.0, Color.rgb(0.95, 0.78, 0.62)) ::
                  place(19.0, 13.0, 3.0, 11.0, Color.rgb(0.95, 0.78, 0.62)) ::
                  place(6.0, 26.0, 5.0, 14.0, Color.rgb(0.2, 0.18, 0.25)) ::
                  place(13.0, 26.0, 5.0, 14.0, Color.rgb(0.2, 0.18, 0.25)) :: Nil }

    /// 太陽の向き（光が進む向き）の 3 つ。Axis = カメラの後ろから奥へ・Diagonal = 斜め 45°・Side = 左から右へ。
    pub enum SunSide {
        case Axis
        case Diagonal
        case Side
    }

    def directionOf(side: SunSide): Vec3.Vec3 = match side {
        case SunSide.Axis     => Vec3.v3(0.0, -0.8, 0.6)
        case SunSide.Diagonal => Vec3.v3(0.42, -0.8, 0.42)
        case SunSide.Side     => Vec3.v3(0.6, -0.8, 0.0)
    }

    /// 宙に浮いた屋根の真ん中と高さ。
    def roofCenter(): Vec3.Vec3 = Vec3.v3(-1.3, 2.9, 3.2)

    def roofHalf(): Float64 = 1.3

    /// 高さ y の水平な四角（上を向く）。
    def upQuad(x0: Float64, x1: Float64, z0: Float64, z1: Float64, y: Float64, c: Color): Mesh3d.Polygon =
        { points = Vec3.v3(x0, y, z0) :: Vec3.v3(x0, y, z1) :: Vec3.v3(x1, y, z1) :: Vec3.v3(x1, y, z0) :: Nil, color = c }

    /// 高さ y の水平な四角（下を向く）。
    def downQuad(x0: Float64, x1: Float64, z0: Float64, z1: Float64, y: Float64, c: Color): Mesh3d.Polygon =
        { points = Vec3.v3(x0, y, z0) :: Vec3.v3(x1, y, z0) :: Vec3.v3(x1, y, z1) :: Vec3.v3(x0, y, z1) :: Nil, color = c }

    /// 底の無い箱（x0..x1・z0..z1・高さ 0..h。面は外から見て時計回り）。
    def boxPolys(x0: Float64, x1: Float64, z0: Float64, z1: Float64, h: Float64, wall: Color, top: Color): List[Mesh3d.Polygon] =
        let v = Vec3.v3;
        { points = v(x0, 0.0, z0) :: v(x0, h, z0) :: v(x1, h, z0) :: v(x1, 0.0, z0) :: Nil, color = wall } ::
        { points = v(x1, 0.0, z1) :: v(x1, h, z1) :: v(x0, h, z1) :: v(x0, 0.0, z1) :: Nil, color = wall } ::
        { points = v(x0, 0.0, z1) :: v(x0, h, z1) :: v(x0, h, z0) :: v(x0, 0.0, z0) :: Nil, color = wall } ::
        { points = v(x1, 0.0, z0) :: v(x1, h, z0) :: v(x1, h, z1) :: v(x1, 0.0, z1) :: Nil, color = wall } ::
        upQuad(x0, x1, z0, z1, h, top) :: Nil

    /// 市松の床（1 m の升・x −6..6・z −2..10）。
    def floorPolys(): List[Mesh3d.Polygon] =
        List.range(0, 12) |> List.flatMap(i -> List.range(0, 12) |> List.map(j -> {
            let x0 = Int32.toFloat64(i - 6);
            let z0 = Int32.toFloat64(j - 2);
            let c = if (Int32.modulo(i + j, 2) == 0) Color.rgb(0.78, 0.72, 0.6) else Color.rgb(0.66, 0.6, 0.5);
            upQuad(x0, x0 + 1.0, z0, z0 + 1.0, 0.0, c)
        }))

    def shapeOf(polys: List[Mesh3d.Polygon]): Scene3d.Instance3d = Scene3d.meshInstance(Mesh3d.fromPolygons(polys), Mat4.identity())

    /// 屋根の影の中に立つ足元（胸の高さ 0.8 の所が屋根の影の真ん中に来る点）。
    def shadedFootOf(side: SunSide): Vec3.Vec3 =
        let d = directionOf(side);
        let c = roofCenter();
        let rise = c#y - 0.8;
        Vec3.v3(c#x + d#x / (0.0 - d#y) * rise, 0.0, c#z + d#z / (0.0 - d#y) * rise)

    def person(at: Vec3.Vec3, tint: Color, withShadows: Bool): Scene3d.Billboard3d =
        let b = Scene3d.billboard(charPassName(), charRegion(), at, { x = 0.9, y = 1.6 }) |> Scene3d.withBillboardTint(tint);
        if (withShadows) b |> Scene3d.withCastShadows(true) |> Scene3d.withReceiveShadows(true) else b

    /// 町の一角の場面（大きさ size・zIndex 1）。withShadows = 2 枚のビルボードに影の欄を付けるか。
    pub def scene(side: SunSide, size: Vec2.Vec2, withShadows: Bool): Scene3d.Scene3dCmd =
        let c = roofCenter();
        let r = roofHalf();
        let roof = shapeOf(upQuad(c#x - r, c#x + r, c#z - r, c#z + r, c#y, Color.rgb(0.7, 0.3, 0.25)) ::
                           downQuad(c#x - r, c#x + r, c#z - r, c#z + r, c#y - 0.15, Color.rgb(0.45, 0.25, 0.2)) :: Nil);
        let house = shapeOf(boxPolys(1.8, 4.2, 4.4, 6.4, 2.6, Color.rgb(0.85, 0.82, 0.74), Color.rgb(0.55, 0.3, 0.25)));
        let sun = { intensity = 1.0, color = Color.rgb(1.0, 0.95, 0.85),
                    shadow = Some({ mapSize = 1024, pcfRadius = 1, distance = 30.0, casterReach = 20.0 | Scene3d.directionalShadow() })
                    | Scene3d.directionalLight(directionOf(side)) };
        let camera = { eye = Vec3.v3(0.3, 6.0, -7.0), yaw = 0.0, pitch = 0.5, fovY = 0.62, near = 1.0, far = 60.0, lensShift = Vec2.zero() };
        let base = Scene3d.scene(camera, size);
        { instances = shapeOf(floorPolys()) :: roof :: house :: Nil,
          billboards = person(Vec3.v3(1.0, 0.0, 1.0), Color.rgb(1.0, 1.0, 1.0), withShadows) ::
                       person(shadedFootOf(side), Color.rgb(1.0, 0.85, 0.85), withShadows) :: Nil,
          directionalLight = Some(sun), zIndex = 1,
          environment = { ambient = Color.rgb(0.38, 0.4, 0.5), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(Color.rgb(0.05, 0.05, 0.12)) }
          | base }
}
