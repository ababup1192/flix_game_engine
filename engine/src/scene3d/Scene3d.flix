// Scene3d — 3D の場面を 1 つの描き物として渡すための値（光・環境・置いた物・ビルボード・命令）。
// 部品は同じフォルダの Vec3・Mat4・Transform3d・Mesh3d・Camera3d。GL と CPU の描き方はどちらもこれらだけを読み、
// 座標の約束をここに一本化する。
//
// 座標: 左手系（Unity と同じ）。X = 東・Y = 上・Z = 北。yaw = 0 で +Z を向き、増えると +X（東）へ回る。
// pitch は正で下を向く。yaw 0 では +X が画面の右に来る。
// 表の面 = 外から見て頂点が時計回り。法線はその巻き方で cross(b − a, c − a) が外を向く。
// GL の右手系の clip 空間へは viewMatrix で Z を反転して渡す。Z の反転は画面の上の x・y を変えないので、
// 表の面は画面の上でも時計回りに写る（GL では glFrontFace(GL_CW) で表になる）。

/// 3D の場面 1 つの中身（光・環境・置いた物・ビルボード）と、Shader 効果へ渡す命令。
pub mod Scene3d {

    /// 点光源。range より遠い所には届かない（落ち方は (1 − d² / range²)²）。
    pub type alias PointLight = { position = Vec3.Vec3, color = Color, intensity = Float64, range = Float64 }

    /// 影の地図（段 C）。mapSize = 一辺の画素数・bias = 自分の面に影を落とさないための奥行きのずらし・
    /// pcfRadius = 周りを平均する幅（画素）・strength = 影の濃さ（0〜1）。
    pub type alias ShadowMap = { mapSize = Int32, bias = Float64, pcfRadius = Int32, strength = Float64 }

    /// スポットライト。position から target を向き、fovY（ラジアン）の円錐の中だけを照らす。shadow が Some なら影を落とす（段 C）。
    pub type alias SpotLight = { position = Vec3.Vec3, target = Vec3.Vec3, fovY = Float64, color = Color, intensity = Float64,
                                 range = Float64, shadow = Option[ShadowMap] }

    /// 距離のかすみ。目からの距離が near から far へ向かって color に寄る。
    pub type alias DistanceFog = { color = Color, near = Float64, far = Float64 }

    /// 場面全体の光。ambient = どこにでも当たる光の色・hemisphere = 上を向く面ほど明るくする量（0 で無し）・
    /// toonSteps = 明るさの段の数（0 で段を付けない）・fog = 距離のかすみ・
    /// background = 場面の矩形の中で何も描かれない画素の色（None なら下の 2D が見える）。
    pub type alias Environment3d = { ambient = Color, hemisphere = Float64, toonSteps = Int32, fog = Option[DistanceFog], background = Option[Color] }

    /// 描く解像度。Native = 窓の画素で描く・Design = 設計の解像度で描いてから拡げる（ドット絵と画素の大きさをそろえる）。
    pub enum Resolution with Eq {
        case Native
        case Design
    }

    /// 書き出す物。Color = 色・Depth = 目からの奥行きの灰色（near で黒・near + range で白。ピントの Pass の入力）。
    // WhyNot: with Eq を付けない — Depth の欄に名前を残すためのレコードには Eq が無い。比べたい所は match で開く。
    pub enum Output {
        case Color
        case Depth({ near = Float64, range = Float64 })
    }

    /// 材質（段 B）。spec の Out の色 = 光を当てる前の色・params = spec の Param・
    /// cutout = 真なら α が 0.5 未満の画素を捨てる・emission = 光の計算の後に足す、自分で光る色。
    pub type alias Material3d = { spec = ShaderDoc.Spec, params = Map[String, Float64], cutout = Bool, emission = Option[ShaderDoc.Shade] }

    /// 置いた物の中身。mesh = 形・world = 形の座標 → world の行列・tint = 頂点の色に掛ける色・material = 材質（None なら頂点の色）・
    /// pose = ジョイントの行列（None ならバインドポーズのまま。曲げるかどうかは skinningOf で決める）。
    pub type alias InstanceFields = { mesh = Mesh3d.Mesh3d, world = Mat4.Mat4, tint = Color, material = Option[Material3d],
                                      pose = Option[Pose3d.Pose3d] }

    enum InstanceData { case InstanceData(InstanceFields) }

    /// 置いた物（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。
    pub type alias Instance3d = InstanceData

    /// 形を world の行列で置く（tint 白・材質なし）。
    pub def meshInstance(mesh: Mesh3d.Mesh3d, world: Mat4.Mat4): Instance3d =
        InstanceData.InstanceData({ mesh = mesh, world = world, tint = Color.rgb(1.0, 1.0, 1.0), material = None, pose = None })

    pub def withTint(c: Color, i: Instance3d): Instance3d =
        let InstanceData.InstanceData(r) = i;
        InstanceData.InstanceData({ tint = c | r })

    pub def withMaterial(m: Material3d, i: Instance3d): Instance3d =
        let InstanceData.InstanceData(r) = i;
        InstanceData.InstanceData({ material = Some(m) | r })

    /// ジョイントの行列で曲げる（mesh にジョイントの重みが無ければ描く時に無視される）。
    pub def withPose(p: Pose3d.Pose3d, i: Instance3d): Instance3d =
        let InstanceData.InstanceData(r) = i;
        InstanceData.InstanceData({ pose = Some(p) | r })

    /// 描く時に曲げる Pose（GL と CPU が同じ判定に使う）。None ならバインドポーズのまま描く:
    ///   - pose が None
    ///   - mesh にジョイントの重みが無い（pose を無視する）
    ///   - mesh のジョイントの番号の最大 ≧ Pose のジョイントの数（skinningWarning が知らせる文を返す）
    pub def skinningOf(i: Instance3d): Option[Pose3d.Pose3d] =
        let r = instanceFieldsOf(i);
        Option.flatMap(p -> Option.flatMap(top ->
            if (top < Pose3d.jointCount(p)) Some(p) else None, Mesh3d.maxSkinJoint(r#mesh)), r#pose)

    /// skinningOf がジョイントの数の食い違いでバインドポーズへ落とす時の、知らせる 1 行（落とさない時は None）。
    /// 毎コマ通るので、呼ぶ側が形の contentHash ごとに初回 1 回だけ出す。
    // WhyNot: skinningOf の中で Log へ出さない — 純粋な関数は「初回だけ」を覚えられず、毎コマ同じ行が流れる。
    pub def skinningWarning(i: Instance3d): Option[String] =
        let r = instanceFieldsOf(i);
        Option.flatMap(p -> Option.flatMap(top -> {
            if (top < Pose3d.jointCount(p)) None
            else Some("scene3d: 形のジョイントの番号 ${top} が Pose のジョイントの数 ${Pose3d.jointCount(p)} 以上なので、曲げずに描く")
        }, Mesh3d.maxSkinJoint(r#mesh)), r#pose)

    /// 置いた物の中身を読む（GL・CPU・鍵が使う）。
    pub def instanceFieldsOf(i: Instance3d): InstanceFields =
        let InstanceData.InstanceData(r) = i;
        r

    /// ビルボードの中身。texture と regionRect = 貼る絵（テクスチャの px）・position = 立てる world の点・
    /// size = world の幅と高さ・anchor = position に合わせる絵の中の点（0〜1。(0.5, 1) で足元の真ん中）・
    /// tint = 絵に掛ける色・lit = 光とかすみを当てるか。
    pub type alias BillboardFields = { texture = String, regionRect = Rect2.Rect2, position = Vec3.Vec3, size = Vec2.Vec2,
                                       anchor = Vec2.Vec2, tint = Color, lit = Bool }

    enum BillboardData { case BillboardData(BillboardFields) }

    /// 深度つきのビルボード（ドット絵を 3D に立てる。閉じた型 — 欄を後から足してもゲームの値が壊れない）。
    pub type alias Billboard3d = BillboardData

    /// anchor 足元の真ん中・tint 白・光を当てる。
    pub def billboard(texture: String, regionRect: Rect2.Rect2, position: Vec3.Vec3, size: Vec2.Vec2): Billboard3d =
        BillboardData.BillboardData({ texture = texture, regionRect = regionRect, position = position, size = size,
                                      anchor = { x = 0.5, y = 1.0 }, tint = Color.rgb(1.0, 1.0, 1.0), lit = true })

    pub def withAnchor(a: Vec2.Vec2, b: Billboard3d): Billboard3d =
        let BillboardData.BillboardData(r) = b;
        BillboardData.BillboardData({ anchor = a | r })

    pub def withBillboardTint(c: Color, b: Billboard3d): Billboard3d =
        let BillboardData.BillboardData(r) = b;
        BillboardData.BillboardData({ tint = c | r })

    /// 光とかすみを当てない（炎・光る目）。
    pub def unlit(b: Billboard3d): Billboard3d =
        let BillboardData.BillboardData(r) = b;
        BillboardData.BillboardData({ lit = false | r })

    /// ビルボードの中身を読む（GL・CPU・鍵が使う）。
    pub def billboardFieldsOf(b: Billboard3d): BillboardFields =
        let BillboardData.BillboardData(r) = b;
        r

    /// 場面 1 つ。size = 描き物の大きさ（位置は PlacedItem の at。Shader 面と同じ決まり）・zIndex = 2D の並びの中の重なり順。
    pub type alias Scene3dCmd = { size = Vec2.Vec2, camera = Camera3d.Camera3d, instances = List[Instance3d], billboards = List[Billboard3d],
                                  pointLights = List[PointLight], spotLights = List[SpotLight], environment = Environment3d,
                                  resolution = Resolution, output = Output, zIndex = Int32, time = Float64 }

    /// 空の場面（環境光は白・光なし・かすみなし・地の色なし・Native・色を書き出す・zIndex 0・時刻 0）。
    /// time = 材質の ShaderDoc の時刻（秒）（ゲームの遊びの時計を渡すと、ポーズやヒットストップで材質の動きも止まる）。
    /// Scene3dCmd は開いたレコードなので `{ instances = … | s }` で足す。
    // WhyNot: 環境光を黒にしない — 光を置く前の場面が真っ黒になり、形を置いたのに何も出ないように見える。
    pub def scene(camera: Camera3d.Camera3d, size: Vec2.Vec2): Scene3dCmd =
        { size = size, camera = camera, instances = Nil, billboards = Nil, pointLights = Nil, spotLights = Nil,
          environment = { ambient = Color.rgb(1.0, 1.0, 1.0), hemisphere = 0.0, toonSteps = 0, fog = None, background = None },
          resolution = Resolution.Native, output = Output.Color, zIndex = 0, time = 0.0 }

    /// 1 つの場面で計算する点光源の上限。
    pub def maxPointLights(): Int32 = 8

    /// 1 つの場面で計算するスポットライトの上限。
    pub def maxSpotLights(): Int32 = 2

    /// 影の地図の縦横の上限（GL 3.3 が約束する大きさより大きいが、今の GPU なら作れる）。GL と CPU が同じ値で頭打ちにする。
    pub def maxShadowMapSize(): Int32 = 4096

    /// pcfRadius の上限（(2r+1)² 回の読みを画素ごとに行うので、大きすぎる値で GPU を止めない）。GL と CPU が同じ値で頭打ちにする。
    pub def maxShadowPcfRadius(): Int32 = 8

    /// スポットライトから見たカメラ（影の地図を描く目）。位置から target を向き、fovY の角で見る。near は 1・far は range。
    /// target が位置と同じ所なら真下を向く。
    pub def shadowCamera(spot: SpotLight): Camera3d.Camera3d =
        let d = Vec3.sub(spot#target, spot#position);
        let len = Vec3.length(d);
        let dir = if (len < 0.000001) { x = 0.0, y = -1.0, z = 0.0 } else Vec3.mul(d, 1.0 / len);
        let flat = Vec2.sqrt(dir#x * dir#x + dir#z * dir#z);
        { eye = spot#position, yaw = Vec2.atan2(dir#x, dir#z), pitch = Vec2.atan2(0.0 - dir#y, flat),
          fovY = spot#fovY, near = 1.0, far = Float64.max(2.0, spot#range) }

    /// 影の地図の行列（world → 光の clip 空間。縦横の比は 1）。GL と CPU が同じ物を使う。
    /// 影の判定の約束（GL と CPU で同じ）:
    ///   1. world の点 p をこの行列で写し、w で割った NDC の x・y が −1..1 の外なら光の外（影にしない）
    ///   2. 地図の値 = 光から見た一番近い面の NDC の z を 0..1 にした物（z × 0.5 + 0.5）
    ///   3. 画素の z（同じく 0..1）から bias を引いた値が、地図の値以下なら照らされている
    ///   4. pcfRadius = r なら周りの (2r+1)² 個の地図の画素で 3 を数え、照らされている割合 f を出す
    ///   5. そのスポットの光の量に (1 − strength × (1 − f)) を掛ける（点光源・環境光には掛けない）
    pub def shadowMatrix(spot: SpotLight): Mat4.Mat4 =
        let c = shadowCamera(spot);
        Mat4.mul(Camera3d.projectionMatrix(c, 1.0), Camera3d.viewMatrix(c))

    /// 上限を超えた光を、目に近い物から選んで残す（同じ距離なら並びの前の物）。残った物は元の並びの順のまま。
    /// 境をまたいだ光がぱっと点いたり消えたりするのは許す（決まった手順で毎回同じなので、気になれば光を減らす）。
    /// GL と CPU が同じ物を使う。
    pub def pickLights(eye: Vec3.Vec3, cmd: Scene3dCmd): Scene3dCmd =
        { pointLights = nearest(maxPointLights(), eye, l -> l#position, cmd#pointLights),
          spotLights = nearest(maxSpotLights(), eye, l -> l#position, cmd#spotLights) | cmd }

    // WhyNot: List.sortBy に距離だけを渡さない — 安定ソートではないので、同じ距離の光の選ばれ方が並びの順にならない。
    def nearest(limit: Int32, eye: Vec3.Vec3, positionOf: a -> Vec3.Vec3, lights: List[a]): List[a] =
        if (List.length(lights) <= limit) lights
        else
            List.zip(List.range(0, List.length(lights)), lights)
                |> List.map(pair -> ((Vec3.distanceSquared(positionOf(snd(pair)), eye), fst(pair)), pair))
                |> List.sortBy(fst)
                |> List.take(limit)
                |> List.map(snd)
                |> List.sortBy(fst)
                |> List.map(snd)

    /// Shader 効果へ渡す場面 1 つ。at = 描き物の左上（画面の px）・clip = 切り抜く矩形（画面の px）。
    // WhyNot: core の DrawCmd に置かない — 材質が ShaderDoc を持ち、core は ShaderDoc を参照しない層だから。
    pub type alias RenderCmd = { at = Vec2.Vec2, clip = Option[Rect2.Rect2], scene = Scene3dCmd }
}
