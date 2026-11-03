// 3D の場面を CPU（SoftRaster3d）で描いた画素の SHA-256 を固定する（光の式・影・深度・裏の面を 1 枚にまとめた場面と、
// 同じ形に半球の光・霧・トゥーンの段・地の色を足した場面）。
// 光の式を書き換えても「CPU の絵が 1 bit も変わらない」を毎回のテストで守る。
// 違ったら、足す順まで今の式に揃えるか、場面ごとの違う画素の数を人に見せてから撮り直す（値だけ貼り替えない）。
mod TestSoftRaster3dPinned {
    import java.awt.image.BufferedImage
    import java.security.MessageDigest
    import java.util.HexFormat

    def size(): Float64 = 32.0

    def sha256(text: String): String = unsafe IO {
        HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(String.toBytes(text)))
    }

    /// 画像の全部の画素（左上から行ごと）の ARGB を , でつないだ字の SHA-256。
    def pixelHash(img: BufferedImage): String \ IO =
        let side = Float64.round(size()) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        List.range(0, side * side)
            |> List.map(i -> Int32.toString(img.getRGB(Int32.modulo(i, side), i / side)))
            |> String.intercalate(",")
            |> sha256

    def white(): Color = { r = 1.0, g = 1.0, b = 1.0 }

    def quad(color: Color, points: List[Vec3.Vec3]): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons({ points = points, color = color } :: Nil), Mat4.identity())

    /// 床（y = −1）・宙に浮く板（y = 1・下のカメラへ裏を向ける）・奥の赤い壁と、真上の影を落とすスポット・左の点光源。
    def scene(): Scene3d.Scene3dCmd =
        let camera = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0 };
        let floor = quad(white(), Vec3.v3(-5.0, -1.0, -5.0) :: Vec3.v3(-5.0, -1.0, 5.0) :: Vec3.v3(5.0, -1.0, 5.0) :: Vec3.v3(5.0, -1.0, -5.0) :: Nil);
        let board = quad({ r = 0.2, g = 0.6, b = 0.9 }, Vec3.v3(-1.0, 1.0, 1.5) :: Vec3.v3(-1.0, 1.0, 3.5) :: Vec3.v3(1.0, 1.0, 3.5) :: Vec3.v3(1.0, 1.0, 1.5) :: Nil);
        let wall = quad({ r = 0.8, g = 0.2, b = 0.2 }, Vec3.v3(-3.0, 3.0, 4.0) :: Vec3.v3(3.0, 3.0, 4.0) :: Vec3.v3(3.0, -1.0, 4.0) :: Vec3.v3(-3.0, -1.0, 4.0) :: Nil);
        let spot = { color = white(), range = 8.0, shadow = Some({ mapSize = 64, bias = 0.005, pcfRadius = 1, strength = 0.8 }),
                     innerFovY = Some(0.8) | Scene3d.spotLight(Vec3.v3(0.0, 3.0, 2.5), Vec3.v3(0.0, -1.0, 2.5), 1.5707963267948966) };
        let lamp = { position = Vec3.v3(-2.0, 0.5, 2.0), color = { r = 1.0, g = 0.8, b = 0.5 }, intensity = 1.5, range = 4.0 };
        let base = Scene3d.scene(camera, { x = size(), y = size() });
        { instances = floor :: board :: wall :: Nil, spotLights = spot :: Nil, pointLights = lamp :: Nil,
          environment = { ambient = { r = 0.15, g = 0.15, b = 0.2 } | base#environment } | base }

    /// 同じ形を、半球の光・霧・トゥーンの段・地の色で描く場面（光の式の残りの項）。点光源は外す。
    def hazyToonScene(): Scene3d.Scene3dCmd =
        let base = scene();
        { pointLights = Nil,
          environment = { hemisphere = 0.6, toonSteps = 3, background = Some({ r = 0.1, g = 0.12, b = 0.2 }),
                          fog = Some({ color = { r = 0.3, g = 0.35, b = 0.45 }, near = 1.0, far = 6.0 }) | base#environment } | base }

    def render(): BufferedImage \ IO = renderScene(scene())

    def renderScene(cmd: Scene3d.Scene3dCmd): BufferedImage \ IO =
        let side = Float64.round(size()) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        TestSoftRaster3dSupport.renderOn(side, cmd)

    /// 32×32 の場面の画素が 0.84.0 の CPU の描き手と同じ。
    @Test
    def testLitShadowedScenePixelsAreUnchanged(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "68ec928f6d0460b14eb2b12329fe1ff6ab655e5055bcccfa7191a47abc23b020", pixelHash(render()))

    /// 半球の光・霧・トゥーンの段・地の色を足した同じ大きさの場面の画素が 0.84.0 の CPU の描き手と同じ。
    @Test
    def testHazyToonScenePixelsAreUnchanged(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "9bb86bc392ed2ea13ac90b41fcd4522b5149d8a279323f5fe1fa116ba1d9b763", pixelHash(renderScene(hazyToonScene())))
}
