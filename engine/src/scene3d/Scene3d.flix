// Scene3d — 3D の場面を 1 つの描き物として渡すための値（光・環境・置いた物・ビルボード・命令）。
// 部品は同じフォルダの Vec3・Mat4・Transform3d・Mesh3d・Camera3d。GL と CPU の描き方はどちらもこれらだけを読み、
// 座標の約束をここに一本化する。
//
// 座標: 左手系（Unity と同じ）。X = 東・Y = 上・Z = 北。yaw = 0 で +Z を向き、増えると +X（東）へ回る。
// pitch は正で下を向く。yaw 0 では +X が画面の右に来る。
// 表の面 = 外から見て頂点が時計回り。法線はその巻き方で cross(b − a, c − a) が外を向く。
// GL の右手系の clip 空間へは viewMatrix で Z を反転して渡す。Z の反転は画面の上の x・y を変えないので、
// 表の面は画面の上でも時計回りに写る（GL では glFrontFace(GL_CW) で表になる）。
//
// 3D の色: 書く値（材質の Spec・tint・頂点の色・光の color・ambient・かすみ・空・絵）は 2D と同じ画面の値（sRGB の値）。
// 描き手は 3D の中だけそれを線形の量へ戻してから光を足し掛けし、3D の色を作った直後に 1 回だけ画面の値へ戻す
// （半透明の混ぜ・MSAA・後処理・2D は画面の値のまま）。光の intensity・range・hemisphere・lightmap の intensity・
// emissionIntensity は線形の量。法線マップ・影の地図・Output.Depth の灰色・background は変換しない。

/// 3D の場面 1 つの中身（光・環境・置いた物・ビルボード）と、Shader 効果へ渡す命令。
pub mod Scene3d {

    /// 点光源。range より遠い所には届かない。intensity の読み方は場面の LightUnits で決まる:
    /// Legacy（既定）= 光の真下の明るさの倍率。落ち方は (1 − d² / range²)²（光の所で intensity・range で 0）、拡散は albedo × 色 × intensity × facing。
    /// Physical = 1 m 離れた所の照度（cd に当たる）。落ち方は intensity / max(d_m², 1e−4) に range の窓 clamp01(1 − (d² / range²)²)² を掛けた物
    ///   （d_m = d / unitsPerMeter。1 m で intensity・2 m で 1/4）、拡散は albedo / π × 色 × 照度 × facing。
    /// 字で全部の欄を書かず、pointLight(position, range) を `{ intensity = 2.0 | Scene3d.pointLight(p, 6.0) }` の形で替える。
    pub type alias PointLight = { position = Vec3.Vec3, color = Color, intensity = Float64, range = Float64 }

    /// 白・intensity 1 の点光源。ほかの値は `{ color = .., intensity = 2.0 | Scene3d.pointLight(p, range) }` の形で替える。
    pub def pointLight(position: Vec3.Vec3, range: Float64): PointLight =
        { position = position, color = Color.rgb(1.0, 1.0, 1.0), intensity = 1.0, range = range }

    /// 影の地図（段 C）。mapSize = 一辺の画素数・bias = 自分の面に影を落とさないための奥行きのずらし・
    /// pcfRadius = 周りを平均する幅（画素）・strength = 影の濃さ（0〜1）。
    pub type alias ShadowMap = { mapSize = Int32, bias = Float64, pcfRadius = Int32, strength = Float64 }

    /// スポットライト。position から target を向き、fovY（ラジアン・円錐の全体の角）の円錐の中だけを照らす。shadow が Some なら影を落とす（段 C）。
    /// innerFovY = 縁で暗くなり始める角（ラジアン・全体の角）。この角の内側は縁による減り無しで、そこから fovY まで暗くなる。
    /// None なら fovY × spotInnerRatio()。小さくするほど輪の縁が広くぼける（懐中電灯）。直し方は spotConeOf。
    /// intensity の読み方は点光源（PointLight）と同じで、円錐の縁の減り（spotConeOf）をさらに掛ける:
    /// Legacy = 倍率・落ち方は (1 − d² / range²)²。Physical = 1 m 離れた所の照度（cd に当たる）・逆二乗 × range の窓・拡散に 1/π。
    /// 字で全部の欄を書かず、spotLight(position, target, fovY) を `{ color = .. | Scene3d.spotLight(p, t, fov) }` の形で替える。
    pub type alias SpotLight = { position = Vec3.Vec3, target = Vec3.Vec3, fovY = Float64, innerFovY = Option[Float64],
                                 color = Color, intensity = Float64, range = Float64, shadow = Option[ShadowMap] }

    /// 白・intensity 1・range 10・影なし・innerFovY = None のスポットライト。
    /// ほかの値は `{ intensity = 3.0, innerFovY = Some(0.3) | Scene3d.spotLight(p, t, fov) }` の形で替える。
    pub def spotLight(position: Vec3.Vec3, target: Vec3.Vec3, fovY: Float64): SpotLight =
        { position = position, target = target, fovY = fovY, innerFovY = None,
          color = Color.rgb(1.0, 1.0, 1.0), intensity = 1.0, range = 10.0, shadow = None }

    /// innerFovY が None の時の、縁で暗くなり始める角の割合（fovY に対する）。
    pub def spotInnerRatio(): Float64 = 0.8

    /// スポットの円錐の縁の cos（GL と CPU が同じ物を使う）。cone = smoothstep(outerCos, innerCos, dot(−l, スポットの向き))。
    /// outerCos = cos(fovY / 2)・innerCos = cos(innerFovY / 2)。innerFovY は fovY より大きければ fovY に、
    /// 0 未満と NaN は 0 に直す。None は fovY × spotInnerRatio()。
    /// 内と外が同じ cos になる時は innerCos に 1e-6 を足す（GLSL の smoothstep は両端が同じだと値が決まらない）。
    pub def spotConeOf(spot: SpotLight): { outerCos = Float64, innerCos = Float64 } =
        let half = spot#fovY / 2.0;
        let innerHalf = match spot#innerFovY {
            case None    => half * spotInnerRatio()
            case Some(a) => (if (Float64.isNan(a) or a < 0.0) 0.0 else Float64.min(a, spot#fovY)) / 2.0
        };
        let outerCos = Num.cos(half);
        let innerCos = Num.cos(innerHalf);
        { outerCos = outerCos, innerCos = if (innerCos == outerCos) innerCos + 0.000001 else innerCos }

    /// 太陽の光（平行光源。Unity・Unreal の Directional Light・Godot の DirectionalLight3D と同じ）。direction = 光が進む向き（長さは問わない。描く時に長さ 1 にする）・
    /// color = 光の色（画面の値）・shadow が Some なら影を落とす。場面に 1 つまで（Scene3dCmd の directionalLight）。
    /// intensity の読み方は場面の LightUnits で決まり、どちらも距離では落ちない:
    /// Legacy（既定）= 線形の倍率（拡散は albedo × 色 × intensity × facing）。Physical = 光に向いた面の照度（lux に当たる。拡散は albedo / π × 色 × 照度 × facing）。
    /// 字で全部の欄を書かず、directionalLight(direction) を `{ intensity = 1.2 | Scene3d.directionalLight(d) }` の形で替える。
    /// 拡散は 点光源と同じ facing（clamp01(n·l)）に color × intensity を掛け、metallic と roughness を持つ材質には鏡面も足す。
    /// lightmap の面には拡散を足さず（ベイクに含める）、鏡面だけ足す。ビルボード（lit）は点光源と同じく法線をカメラへ向けて光を受け、影は受けない。
    /// Scene3d.scene() の ambient は白なので、太陽を足したら ambient を下げる（白く飛ぶ）。
    pub type alias DirectionalLight = { direction = Vec3.Vec3, color = Color, intensity = Float64, shadow = Option[DirectionalShadow] }

    /// 太陽の影（カスケード 1 段）。mapSize = 一辺の画素数（0 以下なら影なし）・bias と normalBias は world の長さ（m）・
    /// bias = 自分の面に影を落とさないための奥行きのずらし（描く時に bias / 奥行きの幅 の値へ直す）・
    /// normalBias = 受ける点を、法線の向きに normalBias × 地図の 1 画素の world の幅だけずらしてから地図を引く量（法線マップを当てる前の法線で）・
    /// pcfRadius = 周りを平均する幅（画素）・strength = 影の濃さ（0〜1）・
    /// distance = カメラからどこまでに影を落とすか（Unity の Shadow Distance。min(distance, カメラの far) を使う）・
    /// casterReach = 光の側へ、影を落とす物を拾う箱をどこまで延ばすか（画面の外の高い建物の影を拾う）。
    pub type alias DirectionalShadow = { mapSize = Int32, bias = Float64, normalBias = Float64, pcfRadius = Int32, strength = Float64,
                                         distance = Float64, casterReach = Float64 }

    /// 白・intensity 1・影なしの太陽。ほかの値は `{ intensity = 1.2, shadow = Some(Scene3d.directionalShadow()) | Scene3d.directionalLight(d) }` の形で替える。
    pub def directionalLight(direction: Vec3.Vec3): DirectionalLight =
        { direction = direction, color = Color.rgb(1.0, 1.0, 1.0), intensity = 1.0, shadow = None }

    /// mapSize 2048・bias 0.05 m・normalBias 1・pcfRadius 1・strength 0.8・distance 150 m・casterReach 200 m の太陽の影。
    pub def directionalShadow(): DirectionalShadow =
        { mapSize = 2048, bias = 0.05, normalBias = 1.0, pcfRadius = 1, strength = 0.8, distance = 150.0, casterReach = 200.0 }

    /// 端末の区分ごとの太陽の影。Small（スマホ）= mapSize 1024・Medium と Large = 2048。ほかの欄は directionalShadow() と同じ。
    pub def directionalShadowFor(sizeClass: Display.SizeClass): DirectionalShadow = match sizeClass {
        case Display.SizeClass.Small  => { mapSize = 1024 | directionalShadow() }
        case Display.SizeClass.Medium => directionalShadow()
        case Display.SizeClass.Large  => directionalShadow()
    }

    /// 描く時に使う太陽（使える時だけ Some。direction は長さ 1 にした光の進む向き）。GL・CPU・描き出しの鍵はこれだけを読む。
    /// 向きの長さが 0 か有限でない・intensity が 0 以下か有限でない・色が黒の時は None（太陽なしと同じ。影の地図も描かない）。
    pub def directionalLightOf(scene: Scene3dCmd): Option[DirectionalLight] =
        scene#directionalLight |> Option.filter(l -> Option.isEmpty(directionalLightProblem(l)))
            |> Option.map(l -> { direction = Vec3.normalized(l#direction) | l })

    /// 太陽を使わない理由（1 行）。使える時と、太陽が無い時は None。毎コマ通るので、呼ぶ側が鍵（"@sun:direction"）ごとに初回 1 回だけ出す
    /// （GL は warnSceneOnce・CPU の描き出しも同じ文面）。
    // WhyNot: 純粋な関数の中で Log.warnThen を使わない — 毎コマ通る道で初回だけを覚えられない。
    pub def directionalLightWarning(scene: Scene3dCmd): Option[String] =
        scene#directionalLight |> Option.flatMap(directionalLightProblem)

    def directionalLightProblem(l: DirectionalLight): Option[String] =
        let d = l#direction;
        let length = Vec3.length(d);
        if (not (Float64.isFinite(length)) or length < 0.000001) Some("scene3d: 太陽の direction の長さが 0 か有限でない — 太陽なしで描く")
        else if (not (Float64.isFinite(l#intensity)) or l#intensity <= 0.0) Some("scene3d: 太陽の intensity が 0 以下か有限でない — 太陽なしで描く")
        else if (not (l#color#r > 0.0 or l#color#g > 0.0 or l#color#b > 0.0)) Some("scene3d: 太陽の色が黒 — 太陽なしで描く")
        else None

    /// 太陽の光（directionalLightOf の値）が、点から光源へ向かう向き（長さ 1）と、線形の量にした color × intensity。GL の uniform と CPU の引数に同じ値を入れる。
    pub def sunTermsOf(l: DirectionalLight): { toward = Vec3.Vec3, color = Vec3.Vec3 } =
        let c = Texture3d.srgbToLinearColor(l#color);
        { toward = Vec3.mul(l#direction, -1.0), color = Vec3.v3(c#r * l#intensity, c#g * l#intensity, c#b * l#intensity) }

    /// 太陽の影の地図を描く材料。matrix = world → 光の clip（正射影・Float64）・frustum = 影を落とす物の間引き（matrix の箱）・
    /// mapSize と pcfRadius は上限（maxShadowMapSize・maxShadowPcfRadius）で頭打ちにした値・strength = 影の濃さ・
    /// depthBias = 地図の値（z × 0.5 + 0.5）から引く量（bias / 奥行きの幅）・normalShift = 受ける点を法線の向きへずらす world の長さ（normalBias × 地図の 1 画素の幅）・
    /// forward = カメラの前の向き・distance = min(distance, カメラの far)・fadeWidth = distance の手前から影を薄める幅・radius = 箱の横の半径（world）。
    pub type alias SunShadowSetup = { matrix = Mat4.Mat4, frustum = Frustum.Frustum, mapSize = Int32, pcfRadius = Int32, strength = Float64,
                                      depthBias = Float64, normalShift = Float64, forward = Vec3.Vec3, distance = Float64, fadeWidth = Float64,
                                      radius = Float64 }

    /// 太陽の影の地図の約束（GL と CPU で同じ。スポットの shadowMatrix の判定 1〜4 と同じ読み方で、行列だけ正射影）:
    ///   箱の横: カメラの視錐台のうち、目の前の向きの奥行き d が near..D（D = min(distance, far)）の部分の 8 つの角を囲む球。
    ///     k = sqrt(1 + aspect²) × tan(fovY / 2)・k² ≥ (D − near) / (D + near) なら 中心 = 目 + 前 × D・r = D × k、
    ///     ほかは 中心 = 目 + 前 × (D + near) / 2 × (1 + k²)・r = sqrt((D − near)² + 2 (D² + near²) k² + (D + near)² k⁴) / 2。
    ///     r はカメラの向きに依らない（回しても地図の幅が変わらない）。
    ///   箱の奥行き: 光の向きに 球の中心の奥行き − r − casterReach（光の側へ延ばす）から 球の中心の奥行き + r まで。
    ///   丸め: 地図の 1 画素の幅 = 2r / mapSize。光の空間（光の向きの軸・原点は world の原点）での球の中心の x・y を floor(c / 幅) × 幅 に。
    ///     カメラを動かしても world の点が地図の画素の中で動かない（ちらつかない）。太陽の向きを毎コマ変える場面は、軸が回るのでちらつく。
    ///   判定: 点を normalShift だけ法線へずらして matrix で写し、NDC の x・y が −1..1 の外なら影にしない。z × 0.5 + 0.5 − depthBias が地図の値以下なら照らされる。
    ///   薄め: カメラの前の向きの深さ d で fade = clamp01((distance − d) / fadeWidth)。受ける点の光の量に 1 − strength × fade × (1 − 照らされる割合) を掛ける。
    /// Output.Depth・置いた物の無い場面・mapSize が 0 以下・太陽を使えない時・distance が near 以下の時は None。
    pub def directionalShadowOf(scene: Scene3dCmd): Option[SunShadowSetup] =
        let castsShadow = match scene#output {
            case Output.Color    => hasDrawnInstance(scene)
            case Output.Depth(_) => false
        };
        if (not castsShadow) None
        else directionalLightOf(scene) |> Option.flatMap(l ->
            l#shadow |> Option.filter(s -> s#mapSize > 0) |> Option.flatMap(sunShadowSetupOf(scene, l#direction)))

    def sunShadowSetupOf(scene: Scene3dCmd, direction: Vec3.Vec3, s: DirectionalShadow): Option[SunShadowSetup] =
        let cam = scene#camera;
        let distance = Float64.min(s#distance, cam#far);
        if (not (Float64.isFinite(distance) and Float64.isFinite(cam#near) and cam#near > 0.0 and distance > cam#near)) None
        else {
            let (center, radius) = frustumSphereOf(cam, aspectOf(scene), distance);
            let size = Int32.min(s#mapSize, maxShadowMapSize());
            let texel = 2.0 * radius / Int32.toFloat64(size);
            let view = sunViewMatrix(direction);
            let c = Mat4.apply(view, center);
            let snappedX = Float64.floor(c#x / texel) * texel;
            let snappedY = Float64.floor(c#y / texel) * texel;
            let depth = 0.0 - c#z;
            let reach = Float64.max(0.0, s#casterReach);
            let proj = Mat4.orthographic({ left = snappedX - radius, right = snappedX + radius, bottom = snappedY - radius, top = snappedY + radius,
                                           near = depth - radius - reach, far = depth + radius });
            let matrix = Mat4.mul(proj, view);
            Some({ matrix = matrix, frustum = Frustum.ofClipMatrix(matrix), mapSize = size,
                   pcfRadius = Int32.max(0, Int32.min(s#pcfRadius, maxShadowPcfRadius())), strength = s#strength,
                   depthBias = Float64.max(0.0, s#bias) / (reach + 2.0 * radius), normalShift = Float64.max(0.0, s#normalBias) * texel,
                   forward = Camera3d.forward(cam), distance = distance, fadeWidth = Float64.max(distance * 0.1, 0.000001), radius = radius })
        }

    /// カメラの視錐台のうち、前の向きの奥行きが near..far の部分を囲む球（中心, 半径）。式は directionalShadowOf の doc。
    def frustumSphereOf(cam: Camera3d.Camera3d, aspect: Float64, far: Float64): (Vec3.Vec3, Float64) =
        if (Camera3d.hasLensShift(cam)) shiftedFrustumSphereOf(cam, aspect, far) else centeredFrustumSphereOf(cam, aspect, far)

    /// レンズシフトのある視錐台の near..far の 8 つの角を囲む球（角の平均を中心に、一番遠い角まで）。
    /// 半径はカメラの位置と向きによらない（角の並びは目から見て同じ形のまま回るだけ）ので、影の地図の画素は動いても揺れない。
    def shiftedFrustumSphereOf(cam: Camera3d.Camera3d, aspect: Float64, far: Float64): (Vec3.Vec3, Float64) =
        let half = cam#fovY / 2.0;
        let tanHalf = Num.sin(half) / Num.cos(half);
        let f = Camera3d.forward(cam);
        let r = Camera3d.right(cam);
        let u = Camera3d.up(cam);
        let sx = cam#lensShift#x;
        let sy = cam#lensShift#y;
        let cornerAt = (d, kx, ky) -> Vec3.add(cam#eye, Vec3.add(Vec3.mul(f, d),
            Vec3.add(Vec3.mul(r, (kx + 2.0 * sx) * tanHalf * aspect * d), Vec3.mul(u, (ky + 2.0 * sy) * tanHalf * d))));
        let corners = List.flatMap(d -> List.flatMap(kx -> List.map(ky -> cornerAt(d, kx, ky), -1.0 :: 1.0 :: Nil), -1.0 :: 1.0 :: Nil),
                                   cam#near :: far :: Nil);
        let center = Vec3.mul(List.foldLeft(Vec3.add, Vec3.zero(), corners), 1.0 / 8.0);
        let radius = List.foldLeft((acc, p) -> Float64.max(acc, Vec3.length(Vec3.sub(p, center))), 0.0, corners);
        (center, radius)

    def centeredFrustumSphereOf(cam: Camera3d.Camera3d, aspect: Float64, far: Float64): (Vec3.Vec3, Float64) =
        let half = cam#fovY / 2.0;
        let tanHalf = Num.sin(half) / Num.cos(half);
        let k2 = (1.0 + aspect * aspect) * tanHalf * tanHalf;
        let near = cam#near;
        let (reach, radius) = if (k2 >= (far - near) / (far + near)) (far, far * Num.sqrt(k2))
            else ((far + near) / 2.0 * (1.0 + k2),
                  Num.sqrt((far - near) * (far - near) + 2.0 * (far * far + near * near) * k2 + (far + near) * (far + near) * k2 * k2) / 2.0);
        (Vec3.add(cam#eye, Vec3.mul(Camera3d.forward(cam), reach)), radius)

    /// 光の進む向き direction（長さ 1）を前にした、原点の目の行列（world → 光の目の座標。回転だけ）。
    // WhyNot: 光の目を箱の中心に置かない — 中心が動くたびに目の座標の原点が動き、地図の画素の丸め（directionalShadowOf の doc）が効かなくなる。
    def sunViewMatrix(direction: Vec3.Vec3): Mat4.Mat4 =
        let flat = Num.sqrt(direction#x * direction#x + direction#z * direction#z);
        Camera3d.viewMatrix({ eye = Vec3.zero(), yaw = Num.atan2(direction#x, direction#z), pitch = Num.atan2(0.0 - direction#y, flat),
                              fovY = 1.0, near = 1.0, far = 2.0, lensShift = Vec2.zero() })

    /// 点光源の影（光から見た 6 方向の深度を 1 枚の絵 atlas に並べる。Unity・Unreal の Shadow Atlas・Bevy の PointLightShadowMap に当たる）。
    /// maxShadowedLights = 影を落とす灯りの数の上限（0 以下で影なし・maxShadowedPointLights() で頭打ち。どの灯りかは Scene3d.PointShadows.atlasOf）・
    /// mapSize = 面 1 つの一辺の画素（16 未満は 16。atlas が maxShadowMapSize() に収まるよう縮める）・
    /// bias = world の長さ。比べる奥行きから引く量（太陽の bias と同じ単位）・
    /// normalBias = 受ける点を形の法線の向きに「面 1 画素の world の幅 × normalBias × (pcfRadius + 1)」だけずらしてから地図を引く量・
    /// pcfRadius = 周りを平均する幅（画素）・strength = 影の濃さ（0〜1）。
    /// 字で全部の欄を書かず、pointShadowMap() を `{ maxShadowedLights = 2 | Scene3d.pointShadowMap() }` の形で替える。
    pub type alias PointShadowMap = { maxShadowedLights = Int32, mapSize = Int32, bias = Float64, normalBias = Float64, pcfRadius = Int32, strength = Float64 }

    /// maxShadowedLights 4・mapSize 512・bias 0.05・normalBias 1・pcfRadius 1・strength 0.8 の点光源の影（pointShadowMapFor(Large) と同じ）。
    /// 端末で重さを替えるなら pointShadowMapFor(ctx#display#sizeClass)。
    pub def pointShadowMap(): PointShadowMap =
        { maxShadowedLights = 4, mapSize = 512, bias = 0.05, normalBias = 1.0, pcfRadius = 1, strength = 0.8 }

    /// 端末の区分ごとの点光源の影（PostStack.resolveQuality と同じく区分で重さを決める）。
    /// Small（スマホ）= 1 本・256（atlas 768 × 512）・Medium（タブレット）= 2 本・512・Large（PC）= 4 本・512。ほかの欄は pointShadowMap() と同じ。
    pub def pointShadowMapFor(sizeClass: Display.SizeClass): PointShadowMap = match sizeClass {
        case Display.SizeClass.Small  => { maxShadowedLights = 1, mapSize = 256 | pointShadowMap() }
        case Display.SizeClass.Medium => { maxShadowedLights = 2, mapSize = 512 | pointShadowMap() }
        case Display.SizeClass.Large  => pointShadowMap()
    }

    /// 場面に点光源の影を付ける（Scene3dCmd の pointShadows = Some(m)）。
    pub def withPointShadows(m: PointShadowMap, scene: Scene3dCmd): Scene3dCmd = { pointShadows = Some(m) | scene }

    /// 1 つの場面で影を落とす点光源の上限。
    pub def maxShadowedPointLights(): Int32 = 8

    /// 光の量の読み方（Godot の Use Physical Light Units に当たる切り替え）。
    /// Legacy = 点・スポットの落ち方は (1 − d² / range²)²・拡散に 1/π を掛けない（今までの絵）。
    /// Physical = 点・スポットの落ち方は 逆二乗 × range の窓 clamp01(1 − (d² / range²)²)² / max(d_m², 1e−4)（d_m = d / unitsPerMeter。Filament・UE4 と同じ形）、
    ///   点・スポット・太陽の拡散に 1/π（鏡面と ambient・hemisphere・lightmap・emission は同じ）。intensity は点・スポットが 1 m の所の照度（cd に当たる）・太陽が照度（lux に当たる）。
    pub enum LightUnits with Eq, ToString {
        case Legacy
        case Physical
    }

    /// 場面の光の量の読み方を替える（Scene3dCmd の lightUnits）。
    pub def withLightUnits(u: LightUnits, scene: Scene3dCmd): Scene3dCmd = { lightUnits = u | scene }

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

    /// ディザの表（4×4 の画素の格子で繰り返す）。Psx = PS1 の GPU の表（−4〜3。5 ビットの色の 1 段の半分ほど揺らす）・
    /// Bayer4x4 = 4×4 の Bayer 行列（1 段を 16 に割った揺らし）・Off = ディザなしで切り捨てるだけ。
    pub enum DitherPattern with Eq, ToString {
        case Psx
        case Bayer4x4
        case Off
    }

    /// PS1 風の描き方（PSX 風シェーダーの手。psxOff の値で全部切れる）。
    /// colorDepth = 色の 1 成分のビット数（0 で切る・1〜8。PS1 は 5 = 15 ビットの色）・dither = 丸める前に足すディザの表・
    /// ditherStrength = ディザの強さ（1 で表のまま・0 でディザなし）・
    /// vertexSnap = 投影した頂点の x・y を丸める格子の大きさ（場面の描き先の画素。0 で切る・1 で 1 画素・2 で 2 画素。奥行きは丸めない）・
    /// affineTextureMapping = 材質の uv を遠近で補正しない割合（0 = 遠近の補正どおり・1 = 画面の上でまっすぐつなぐアフィン。間は 2 つの uv を混ぜる）。
    /// 色の丸めとディザの格子は場面の描き先の画素（Resolution.Design なら design の画素）にそろう。
    pub type alias PsxLook = { colorDepth = Int32, dither = DitherPattern, ditherStrength = Float64, vertexSnap = Float64, affineTextureMapping = Float64 }

    /// 全部切った PsxLook（Scene3d.scene の既定）。欄を書き替えて使う: `{ colorDepth = 5 | Scene3d.psxOff() }`。
    pub def psxOff(): PsxLook = { colorDepth = 0, dither = DitherPattern.Psx, ditherStrength = 1.0, vertexSnap = 0.0, affineTextureMapping = 0.0 }

    /// PS1 の GPU に近い値（15 ビットの色・PS1 の表のディザ・1 画素の頂点の揺れ・完全なアフィン）。大きな床と壁は流れが強いので affineTextureMapping を下げる。
    pub def psxPreset(): PsxLook = { colorDepth = 5, dither = DitherPattern.Psx, ditherStrength = 1.0, vertexSnap = 1.0, affineTextureMapping = 1.0 }

    /// 場面の PS1 風の描き方を替える（Scene3dCmd の psx）。
    pub def withPsx(look: PsxLook, scene: Scene3dCmd): Scene3dCmd = { psx = look | scene }

    /// 書き出す物。Color = 色・Depth = 目からの奥行きの灰色（near で黒・near + range で白。ピントの Pass の入力）。
    // WhyNot: with Eq を付けない — Depth の欄に名前を残すためのレコードには Eq が無い。比べたい所は match で開く。
    pub enum Output {
        case Color
        case Depth({ near = Float64, range = Float64 })
    }

    /// uv が 0..1 の外へ出た時の読み方。Repeat = 繰り返す・Clamp = 端の色を伸ばす。
    pub enum Wrap with Eq {
        case Repeat
        case Clamp
    }

    /// 法線マップ。texture = 絵の名前（タンジェント空間・緑が絵の上）・strength = でこぼこの強さ（1 で絵のまま）。
    pub type alias NormalMap = { texture = String, strength = Float64 }

    /// 材質の中身。spec の Out の色 = 光を当てる前の色・params = spec の Param・
    /// cutout = 真なら α が 0.5 未満の画素を捨てる・emission = 光の計算の後に足す、自分で光る色・
    /// normalMap = 法線マップ（None なら頂点の法線のまま）・wrap = spec の Tex が 0..1 の外の uv を読む時の読み方（法線マップにも掛かる）・
    /// blend = 真なら spec の α で下の絵に重ねる半透明（深度は読むが書かない。描く順は blendOrderOf）・
    /// doubleSided = 真なら裏の面も描く（裏の面は光の計算の法線を裏返す）・
    /// emissionIntensity = emission を線形の量に戻した後に掛ける倍率（PointLight の intensity と同じ意味・既定 1）・
    /// metallicRoughness = 金属っぽさと粗さ（None なら今までどおり拡散光だけ。withMetallicRoughness で付ける）・
    /// metallicRoughnessShade = metallicRoughness から作る、光の計算に渡す色の場（r = metallic・g = roughness。値は params の pbrParamMetallic・pbrParamRoughness の Param、
    /// 絵があれば Tex の B・G を掛ける。描き手が読む。None と同時に None）・
    /// shaderHash = GLSL を決める中身（spec・emission・metallicRoughnessShade）の鍵（ShaderGen.hashMaterial。params・cutout などは入れない。GL が材質のプログラムを引く。初めて読んだ時に求める）・
    /// texReads = materialTexReadsOf の答え（材質の値ごとに初めて読んだ時に求める）。
    /// spec・emission・metallicRoughnessShade は Scene3d の with… でだけ替える（record を外で組み替えると shaderHash と texReads が古いまま残る）。
    /// spec の Tex の名前は、"tex3d:" で始まれば場面の textures（Texture3d.name）、ほかは全体の登録（project.json の textures・
    /// レンダーターゲット）から引く。無い名前は 0（黒・透明）。1 つの材質が読める (名前, 補間) の組は maxMaterialTextures() まで。
    /// maxMipLevels = spec の Tex の絵を読む mip のレベルの数の上限（withMaxMipLevels。既定は上限なし。Lightmap の maxLevels と同じ考え）。
    pub type alias MaterialFields = { spec = ShaderDoc.Spec, params = Map[String, Float64], cutout = Bool, emission = Option[ShaderDoc.Shade],
                                      normalMap = Option[NormalMap], wrap = Wrap, blend = Bool, doubleSided = Bool, emissionIntensity = Float64,
                                      metallicRoughness = Option[MetallicRoughness], metallicRoughnessShade = Option[ShaderDoc.Shade], shaderHash = Lazy[Int64],
                                      texReads = Lazy[List[(String, ShaderDoc.FilterMode)]], maxMipLevels = Int32 }

    /// 材質の金属っぽさ（metallic・0 で絶縁体・1 で金属）と粗さ（roughness・0 で鏡・1 でざらざら）。どちらも 0..1。
    /// texture = 絵の名前（glTF の metallicRoughnessTexture と同じ決まり: B = metallic・G = roughness。絵の値に metallic・roughness を掛ける）・None なら値だけ。
    pub type alias MetallicRoughness = { metallic = Float64, roughness = Float64, texture = Option[String] }

    enum MaterialData { case MaterialData(MaterialFields) }

    /// 材質（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。material から作り、with… で足す。
    pub type alias Material3d = MaterialData

    /// spec だけの材質（params 空・cutout なし・emission なし・法線マップなし・Repeat・不透明・表の面だけ）。
    pub def material(spec: ShaderDoc.Spec): Material3d =
        MaterialData.MaterialData({ spec = spec, params = Map.empty(), cutout = false, emission = None, normalMap = None, wrap = Wrap.Repeat,
                                    blend = false, doubleSided = false, emissionIntensity = 1.0,
                                    metallicRoughness = None, metallicRoughnessShade = None, shaderHash = lazy 0i64, texReads = lazy Nil,
                                    maxMipLevels = Int32.maxValue() } |> withShaderKeys)

    /// spec の Tex の絵を読む mip のレベルの数を levels までにする（1 以上に直す。1 なら縮んでも元の絵だけを読む）。
    /// ドット絵のアトラスを貼る材質で、遠くや斜めで 1 つのタイルが 1 画素より小さく縮んだ所に隣のタイルの色が混ざるのを止める（atlasMipLevelsFor）。
    /// 法線マップの絵には掛けない。
    pub def withMaxMipLevels(levels: Int32, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ maxMipLevels = Int32.max(1, levels) | r })

    /// 一辺 tilePx の正方形のタイルを、tilePx の倍数の位置に詰めたアトラスで、隣のタイルを混ぜない mip のレベルの数（withMaxMipLevels へ渡す）。
    /// レベル k の 1 テクセルは 2^k の倍数の位置から始まる 2^k px の塊の平均なので、2^k が tilePx を割り切るレベルまでは 1 つのタイルの中だけを平均する。
    /// 16 px で 5（レベル 0〜4）・32 px で 6・24 px で 4・48 px で 5。アトラスの幅と高さも 2^(レベルの数 − 1) で割り切れる大きさにする。
    pub def atlasMipLevelsFor(tilePx: Int32): Int32 =
        if (tilePx < 2 or Int32.remainder(tilePx, 2) != 0) 1 else 1 + atlasMipLevelsFor(tilePx / 2)

    /// 材質の絵を段の数 textureLevels の絵で読む時の段の数（GL の uniform・WebGPU の values・CPU の描き手が同じ数を使う）。
    pub def materialMipLevelsOf(m: MaterialFields, textureLevels: Int32): Int32 = Int32.min(textureLevels, m#maxMipLevels)

    /// r の spec・emission・metallicRoughnessShade から導く欄（shaderHash・texReads）を、初めて読まれた時に求める形で作り直す。
    /// この 3 つを替える口は全部ここを通す。
    // WhyNot: 作る時にすぐ求めない — View で毎コマ材質を組み直すゲームでは、CPU の描き出しのように鍵を読まない描き手でも払うことになる。
    // WhyNot: 鍵のための lock の表（memo）を置かない — Flix の Lazy は force を lock で守って 1 回だけ求め、鍵は材質の値が持つので、
    //   別のスレッドから材質を読んでも表の取り合いが起きない。
    // WhyNot: 絵の組を描き手の側の shaderHash の表に控えない — shaderHash は絵の名前を比べない鍵で、同じ木で別の絵を貼る材質が同じ鍵になる。
    def withShaderKeys(r: MaterialFields): MaterialFields =
        let (spec, emission, metallicRoughness) = (r#spec, r#emission, r#metallicRoughnessShade);
        { shaderHash = lazy ShaderGen.hashMaterial(spec, emission, metallicRoughness),
          texReads = lazy ShaderDoc.materialTexReads(spec, emission, metallicRoughness) | r }

    /// 材質 m が読む絵の (名前, 補間) の組（ShaderDoc.materialTexReads と同じ並び・上限で切る前）。材質の値ごとに 1 回だけ数える。
    pub def materialTexReadsOf(m: MaterialFields): List[(String, ShaderDoc.FilterMode)] = force m#texReads

    /// spec の Param に渡す値（Unity のマテリアルの float の値を渡すのと同じ。渡さない名前は 0）。
    /// withMetallicRoughness の値（pbrParamMetallic・pbrParamRoughness の名前）は p に同じ名前があっても残る。
    pub def withParams(p: Map[String, Float64], m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ params = withPbrParams(r#metallicRoughness, p) | r })

    /// on が真なら α が 0.5 未満の画素を捨てる（深度も書かない）。
    pub def withCutout(on: Bool, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ cutout = on | r })

    /// on が真なら半透明（窓ガラス・網・水面）: 色 = spec の色 × α + 下の色 × (1 − α)。深度は読むが書かない（奥の半透明も透けて見える）。
    /// 不透明の物とビルボードの後に、world の境界の真ん中が目から遠い物から描く（blendOrderOf）。1 つの物の中の三角形は並べ替えない。
    /// cutout と両方真なら、α が 0.5 未満の画素を捨ててから重ねる。影は落とさない・Output.Depth には書かない（奥にピントが合う）。
    pub def withAlphaBlend(on: Bool, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ blend = on | r })

    /// on が真なら裏の面も描く（ガラスの板・網・葉など、裏から見ても見える物）。裏の面は光の計算の法線を裏返す
    /// （spec の Normal は裏返さない）。
    pub def withDoubleSided(on: Bool, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ doubleSided = on | r })

    /// 光の計算の後に足す、自分で光る色（かすみに沈まない）。名前は替えなくてよい（GL は spec と emission の中身の鍵でプログラムを引く）。
    /// 毎コマ変わる数（明滅の強さ）は木の Const に入れず、ShaderDoc の param にして withParams で渡す（木の数が変わると GL がプログラムを組み直す）。
    /// emissionIntensity はそのまま残る（glb の emissive_strength の付いた材質で差し替えた色も、その倍率で光る。戻すなら withEmissionIntensity(1.0, ..)）。
    pub def withEmission(s: ShaderDoc.Shade, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData(withShaderKeys({ emission = Some(s) | r }))

    /// emission を外す（glb の emissive で光らせたくない時）。emissionIntensity も 1 に戻す。
    pub def withoutEmission(m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData(withShaderKeys({ emission = None, emissionIntensity = 1.0 | r }))

    /// emission を線形の量に戻した後に掛ける倍率 k（既定 1。Godot の emission_energy_multiplier・Unity の Emission Intensity と同じ分け方）。
    /// 1 を超える明るさ（glTF の emissive_strength など）は emission の Spec に書かずにここで渡す — Spec は画面の値（sRGB の値）で、
    /// 線形へ戻すと 1 を超える値は 1 次より強く伸びる（2.0 → 約 4.95）。毎コマ変えてもプログラムを組み直さない（描く物ごとの uniform）。
    pub def withEmissionIntensity(k: Float64, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ emissionIntensity = k | r })

    /// spec の名前だけを替える（知らせの文面・GL のプログラムの名前に出る）。木の違う材質に別の名前を付けなくてよい
    /// — GL は spec と emission の中身の鍵でプログラムを引くので、同じ名前で木の違う材質が並んでも組み直さない。
    pub def withSpecName(name: String, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        let spec = { name = name | r#spec };
        MaterialData.MaterialData(withShaderKeys({ spec = spec | r }))

    /// 金属っぽさ metallic と粗さ roughness を付ける（Unity の Standard・Godot の StandardMaterial3D と同じ 2 つの値。どちらも 0..1 に丸める）。
    /// 鏡面ハイライトと空の映り込みが付き、拡散光は (1 − metallic) 倍になる。付けない材質の絵は変わらない。
    /// 絵（withMetallicRoughnessTexture）が付いていれば、絵の値に掛ける係数になる。毎コマ変えてもプログラムを組み直さない（params の値）。
    /// withMetallicRoughnessShade の後に呼ぶと shade を値で書き替える（後に呼んだ物が勝つ）。
    /// glb の材質は、pbrMetallicRoughness に metallicFactor・roughnessFactor・metallicRoughnessTexture のどれかがあれば読み込む時に付く。
    // WhyNot: 場面の環境（Environment3d）に metallic を置かない — 材質ごとの値で、同じ場面に金属と木が並ぶ。
    pub def withMetallicRoughness(metallic: Float64, roughness: Float64, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        let texture = r#metallicRoughness |> Option.flatMap(mr -> mr#texture);
        withMetallicRoughnessOf({ metallic = unitOf(metallic), roughness = unitOf(roughness), texture = texture }, r)

    /// metallic と roughness を絵 texture から読む（glTF の metallicRoughnessTexture と同じ決まり: B = metallic・G = roughness）。
    /// 付いている metallic・roughness は絵の値に掛ける係数のまま残り、まだ無ければ 1・1（glTF の既定）。名前の決まりは Texture の Tex と同じ
    /// （"tex3d:" で始まれば場面の textures）。絵は材質の絵の上限（maxMaterialTextures）の 1 組に数える。
    /// withMetallicRoughness・withMetallicRoughnessShade とは後に呼んだ物が勝つ（どれも同じ欄を書き替える）。
    pub def withMetallicRoughnessTexture(texture: String, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        let (metallic, roughness) = r#metallicRoughness |> Option.map(mr -> (mr#metallic, mr#roughness)) |> Option.getWithDefault((1.0, 1.0));
        withMetallicRoughnessOf({ metallic = metallic, roughness = roughness, texture = Some(texture) }, r)

    /// metallic と roughness を色の場 shade で付ける（r = metallic・g = roughness・b は使わない。Godot の ShaderMaterial で METALLIC・ROUGHNESS を書くのに当たる）。
    /// 頂点の色で 2 枚の絵の roughness を混ぜる地面のように、値 1 つや絵 1 枚で書けない時に使う（docs/scene3d.md の「頂点の色で地面の絵を混ぜる」）。
    /// shade の場は材質の Spec と同じ物が書け、絵は材質の絵の上限（maxMaterialTextures）に数える。metallicRoughnessOf は None になる。
    /// withMetallicRoughness・withMetallicRoughnessTexture とは後に呼んだ物が勝つ（どれも同じ欄を書き替える）。
    pub def withMetallicRoughnessShade(shade: ShaderDoc.Shade, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData(withShaderKeys({ metallicRoughness = None, metallicRoughnessShade = Some(shade), params = withoutPbrParams(r#params) | r }))

    /// metallic と roughness を外す（glb の材質を今までのマットな絵に戻す時）。
    pub def withoutMetallicRoughness(m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData(withShaderKeys({ metallicRoughness = None, metallicRoughnessShade = None, params = withoutPbrParams(r#params) | r }))

    /// 付いている metallic と roughness（無ければ None）。
    pub def metallicRoughnessOf(m: Material3d): Option[MetallicRoughness] = materialFieldsOf(m)#metallicRoughness

    def withMetallicRoughnessOf(mr: MetallicRoughness, r: MaterialFields): Material3d =
        let shade = metallicRoughnessShadeOf(mr#texture);
        MaterialData.MaterialData(withShaderKeys({ metallicRoughness = Some(mr), metallicRoughnessShade = Some(shade), params = withPbrParams(Some(mr), r#params) | r }))

    /// 0..1 に丸める（NaN は 0）。
    def unitOf(x: Float64): Float64 = if (Float64.isNan(x)) 0.0 else Float64.max(0.0, Float64.min(1.0, x))

    /// metallicRoughnessShade の中の Param の名前（ほかの Param と重ならない字）。
    pub def pbrParamMetallic(): String = "pbr:metallic"

    pub def pbrParamRoughness(): String = "pbr:roughness"

    /// r = metallic・g = roughness の色。形は絵の名前だけで決まる（値は Param なので、値を替えても GLSL は同じ）。
    // WhyNot: 値を Const で書かない — Const は GLSL の字に入り、値ごとに別のプログラムを組む（球を粗さで 10 個並べると 10 本）。
    def metallicRoughnessShadeOf(texture: Option[String]): ShaderDoc.Shade =
        let factor = (name: String) -> ShaderDoc.Field.Param({ name = name });
        let read = (name: String, chan: ShaderDoc.TexChan) -> match texture {
            case None    => factor(name)
            case Some(t) =>
                ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = factor(name),
                                      b = ShaderDoc.Field.Sampler({ filter = ShaderDoc.FilterMode.Linear,
                                                                   of = ShaderDoc.Field.Tex({ name = t, chan = chan }) }) })
        };
        ShaderDoc.Shade.Rgb({ r = read(pbrParamMetallic(), ShaderDoc.TexChan.B), g = read(pbrParamRoughness(), ShaderDoc.TexChan.G),
                              b = ShaderDoc.Field.Const(0.0) })

    /// params に metallic・roughness の値を入れた物（mr が None なら入れない）。
    def withPbrParams(mr: Option[MetallicRoughness], params: Map[String, Float64]): Map[String, Float64] = match mr {
        case None     => params
        case Some(v)  => Map.insert(pbrParamRoughness(), v#roughness, Map.insert(pbrParamMetallic(), v#metallic, params))
    }

    def withoutPbrParams(params: Map[String, Float64]): Map[String, Float64] =
        Map.remove(pbrParamRoughness(), Map.remove(pbrParamMetallic(), params))

    pub def withNormalMap(n: NormalMap, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ normalMap = Some(n) | r })

    pub def withWrap(w: Wrap, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ wrap = w | r })

    /// 材質の中身を読む（GL・CPU・鍵が使う）。
    pub def materialFieldsOf(m: Material3d): MaterialFields =
        let MaterialData.MaterialData(r) = m;
        r

    /// 絵 1 枚 × 頂点の色の材質（絵の r・g・b に VertexColor の r・g・b を掛け、α は絵の α）。filter = 絵の読み方（ドット絵なら Nearest）。
    /// 頂点の色が灰色の形（Kd の無い OBJ の材質は 0.6）に貼ると、その分だけ暗くなる。
    pub def texturedMaterial(texture: String, filter: ShaderDoc.FilterMode): Material3d =
        let read = (chan: ShaderDoc.TexChan) -> ShaderDoc.Field.Sampler({ filter = filter, of = ShaderDoc.Field.Tex({ name = texture, chan = chan }) });
        let tinted = (chan: ShaderDoc.TexChan) ->
            ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = read(chan), b = ShaderDoc.Field.VertexColor({ chan = chan }) });
        material({ name = "scene3d:textured:${ToString.toString(filter)}", cycleRate = 0.0, bindings = Nil,
                   out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = tinted(ShaderDoc.TexChan.R), g = tinted(ShaderDoc.TexChan.G),
                                                                            b = tinted(ShaderDoc.TexChan.B) }),
                                              alpha = read(ShaderDoc.TexChan.A) }) })

    /// 1 つの材質が読める (テクスチャ名, 補間) の組の上限（ShaderDoc.materialTexReads の並びの前から。法線マップは別枠）。
    /// 超えた組は描く時に 0 になり、材質ごとに 1 回知らせる（GL と CPU で同じ）。寸法だけを引く TexSize の名前も 1 組として数える（寸法は段 0 の数）。
    pub def maxMaterialTextures(): Int32 = 6

    /// 置いた物の中身。mesh = 形・world = 形の座標 → world の行列・tint = 頂点の色に掛ける色・material = 材質（None なら頂点の色）・
    /// pose = ジョイントの行列（None ならバインドポーズのまま。曲げるかどうかは skinningOf で決める）・
    /// lightmap = ベイクした光（None なら無し。使うかどうかは lightmapOf で決める）・
    /// name = 置いた物の名前（withName。空なら無し。F8 の注釈が 3D の場面の中の物を名前で指す。絵には出ない）。
    pub type alias InstanceFields = { mesh = Mesh3d.Mesh3d, world = Mat4.Mat4, tint = Color, material = Option[Material3d],
                                      pose = Option[Pose3d.Pose3d], lightmap = Option[Lightmap], name = String }

    /// 3D のベイクした光（Blender などで前もって計算した光の絵。2D の Light.lightMapPass とは別）。
    /// texture = 絵の名前（Texture3d.name。場面の textures から引く）・colorSpace = 8bit の絵の値の意味・
    /// intensity = 線形の光の量に戻した後に掛ける倍率（PointLight の intensity と同じ意味。露出の stop の数ではない）・
    /// maxLevels = 読む mip のレベルの数の上限（UV の島の間が狭い lightmap は lightmapLevelsForGap で小さくする）。
    /// 欄は後から増えうるので、{ intensity = 2.0 | Scene3d.lightmap(name) } のようにレコードの更新で書く。
    pub type alias Lightmap = { texture = String, colorSpace = Texture3d.ColorSpace, intensity = Float64, maxLevels = Int32 }

    enum InstanceData { case InstanceData(InstanceFields) }

    /// 置いた物（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。
    pub type alias Instance3d = InstanceData

    /// 形を world の行列で置く（tint 白・材質なし）。
    pub def meshInstance(mesh: Mesh3d.Mesh3d, world: Mat4.Mat4): Instance3d =
        InstanceData.InstanceData({ mesh = mesh, world = world, tint = Color.rgb(1.0, 1.0, 1.0), material = None, pose = None, lightmap = None, name = "" })

    pub def withTint(c: Color, i: Instance3d): Instance3d =
        let InstanceData.InstanceData(r) = i;
        InstanceData.InstanceData({ tint = c | r })

    pub def withMaterial(m: Material3d, i: Instance3d): Instance3d =
        let InstanceData.InstanceData(r) = i;
        InstanceData.InstanceData({ material = Some(m) | r })

    /// 置いた物に名前を付ける（F8 で 3D の場面の中を囲むと、注釈のチケットにこの名前が出る。絵は変わらない）。
    /// glb から組んだ物は Model3d がノードの名前を入れる。後から付けた名前が勝つ。
    pub def withName(name: String, i: Instance3d): Instance3d =
        let InstanceData.InstanceData(r) = i;
        InstanceData.InstanceData({ name = name | r })

    /// 置いた物の名前（付けていなければ空）。
    pub def nameOf(i: Instance3d): String = instanceFieldsOf(i)#name

    /// ジョイントの行列で曲げる（mesh にジョイントの重みが無ければ描く時に無視される）。
    pub def withPose(p: Pose3d.Pose3d, i: Instance3d): Instance3d =
        let InstanceData.InstanceData(r) = i;
        InstanceData.InstanceData({ pose = Some(p) | r })

    /// 描く時に曲げる Pose（GL と CPU が同じ判定に使う）。None ならバインドポーズのまま描く:
    ///   - pose が None
    ///   - mesh にジョイントの重みが無い（pose を無視する）
    ///   - mesh のジョイントの番号の最大 ≧ Pose のジョイントの数（skinningWarning が知らせる文を返す）
    pub def skinningOf(i: Instance3d): Option[Pose3d.Pose3d] = skinningOfFields(instanceFieldsOf(i))

    def skinningOfFields(r: InstanceFields): Option[Pose3d.Pose3d] =
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

    /// 置いた物の world の境界（形の境界の 8 つの角を world で写した物を囲む AABB）。
    /// 骨つき（skinningOf が Some。Pose で形が境界の外へ出うる）と頂点の無い形は None。
    pub def worldBoundsOf(i: Instance3d): Option[Mesh3d.Bounds] = worldBoundsOfFields(instanceFieldsOf(i))

    def worldBoundsOfFields(r: InstanceFields): Option[Mesh3d.Bounds] =
        if (Option.nonEmpty(skinningOfFields(r)) or Mesh3d.vertexCount(r#mesh) == 0) None
        else Some(Mesh3d.boundsOfPoints(Mesh3d.cornersOf(Mesh3d.bounds(r#mesh)) |> List.map(Mat4.apply(r#world))))

    /// 置いた物の、描く順を決める点（world の境界の真ん中。骨つきと頂点の無い形は world の原点）。
    pub def drawCenterOf(r: InstanceFields): Vec3.Vec3 =
        worldBoundsOfFields(r)
            |> Option.map(b -> Vec3.mul(Vec3.add(b#min, b#max), 0.5))
            |> Option.getWithDefault(Mat4.apply(r#world, Vec3.zero()))

    /// 半透明の物を描く順に並べる（drawCenterOf が目 eye から遠い順・同じ距離なら並びの前）。GL と CPU が同じ物を使う。
    /// fieldsOf = 要素から置いた物の中身を引く関数。
    pub def blendOrderOf(eye: Vec3.Vec3, fieldsOf: a -> InstanceFields, xs: List[a]): List[a] =
        xs |> Sort.sortStableBy(x -> 0.0 - Vec3.distanceSquared(drawCenterOf(fieldsOf(x)), eye))

    /// 半透明の材質（withAlphaBlend）が付いた置いた物か。
    pub def isBlendedFields(r: InstanceFields): Bool =
        r#material |> Option.exists(m -> materialFieldsOf(m)#blend)

    /// 描き手が視錐台 f の外として描かなくてよい物か（迷ったら偽 = 描く）。GL と CPU と影の地図が同じ判定を使う。
    /// 骨つきと頂点の無い形はいつも偽。8 つの角が 6 つの面のどれか 1 つの外に全部あれば真。
    pub def isOutsideFrustum(f: Frustum.Frustum, i: Instance3d): Bool = isOutsideFrustumFields(f, instanceFieldsOf(i))

    /// isOutsideFrustum の本体（置いた物の中身から。CPU の描き手が使う）。
    pub def isOutsideFrustumFields(f: Frustum.Frustum, r: InstanceFields): Bool =
        if (Option.nonEmpty(skinningOfFields(r)) or Mesh3d.vertexCount(r#mesh) == 0) false
        else {
            let b = Mesh3d.bounds(r#mesh);
            not Frustum.intersectsBox(f, b#min, b#max, r#world)
        }

    /// ビルボードが視錐台 f の外か（外接球で見る。半径 = (size.x × max(|anchor.x|, |1 − anchor.x|), size.y × 同じ y) の長さ）。
    pub def isBillboardOutsideFrustum(f: Frustum.Frustum, b: Billboard3d): Bool =
        let r = billboardFieldsOf(b);
        let reach = (a: Float64) -> Float64.max(Float64.abs(a), Float64.abs(1.0 - a));
        let rx = r#size#x * reach(r#anchor#x);
        let ry = r#size#y * reach(r#anchor#y);
        not Frustum.intersectsSphere(f, r#position, Num.sqrt(rx * rx + ry * ry))

    /// 場面の縦横の比（幅 / 高さ。高さは 1e-6 未満にしない）。GL と CPU の射影の行列と視錐台が同じ値を使う。
    pub def aspectOf(scene: Scene3dCmd): Float64 = scene#size#x / Float64.max(0.000001, scene#size#y)

    /// 場面のカメラで見る視錐台（縦横の比は aspectOf。GL と CPU が同じ物を使う）。
    pub def frustumOf(scene: Scene3dCmd): Frustum.Frustum =
        Camera3d.frustum(scene#camera, aspectOf(scene))

    /// スポットの影の地図を描く目の視錐台（縦横の比は 1）。目に見えない物も影は落とすので、影の地図はこちらで間引く。
    pub def shadowFrustumOf(spot: SpotLight): Frustum.Frustum =
        Camera3d.frustum(shadowCamera(spot), 1.0)

    /// lightmap を読む mip のレベルの数の上限の既定（レベル 0〜3。UV の島の間が 16 px の lightmap に合う）。
    // WhyNot: 全部のレベルを読まない — UV のアイランドの間の空き（黒）がレベルが上がるほど混ざり、継ぎ目が暗くなる。
    pub def lightmapMaxLevels(): Int32 = 4

    /// UV の島の間の px（読み込んだ lightmap の絵の上で）から、読む mip のレベルの数の上限を決める（1 以上）。
    /// レベル k の 1 texel は元の 2^k px で、Linear は隣の texel も読むので、2^(上限のレベル + 1) ≦ 島の間。16 px で 4（レベル 0〜3）・7 px で 2。
    /// Texture3d.limitSize で lightmap を半分にしたら、島の間も半分になる。
    pub def lightmapLevelsForGap(gapPx: Int32): Int32 =
        if (gapPx < 4) 1 else 1 + lightmapLevelsForGap(gapPx / 2)

    /// colorSpace = Srgb・intensity = 1・maxLevels = lightmapMaxLevels() の lightmap。ほかの値は { intensity = 2.0 | Scene3d.lightmap(name) } の形で替える。
    pub def lightmap(texture: String): Lightmap =
        { texture = texture, colorSpace = Texture3d.ColorSpace.Srgb, intensity = 1.0, maxLevels = lightmapMaxLevels() }

    /// 置いた物にベイクした光を付ける（2 本目の uv で読む）。付けた物は環境光と hemisphere を足さず、動く光（点光源・スポット）は足す。
    /// ベイクに入れた光は pointLights に入れない（二重に照らす）。骨つき・材質の無い物・2 本目の uv の無い形には使われない（lightmapWarning）。
    pub def withLightmap(lm: Lightmap, i: Instance3d): Instance3d =
        let InstanceData.InstanceData(r) = i;
        InstanceData.InstanceData({ lightmap = Some(lm) | r })

    /// 描く時に使う lightmap（使える時だけ Some。intensity の負・NaN・無限は 0 に・maxLevels は 1 以上に直す）。GL・CPU・描き出しの鍵はこれだけを読む。
    pub def lightmapOf(i: Instance3d): Option[Lightmap] = lightmapOfFields(instanceFieldsOf(i))

    /// lightmapOf の本体（置いた物の中身から。描き出しの鍵が使う）。
    pub def lightmapOfFields(f: InstanceFields): Option[Lightmap] =
        if (Option.nonEmpty(lightmapProblem(f))) None
        else f#lightmap |> Option.map(lm -> { intensity = if (lm#intensity > 0.0 and not Float64.isInfinite(lm#intensity)) lm#intensity else 0.0,
                                              maxLevels = Int32.max(1, lm#maxLevels) | lm })

    /// 付けたのに使わない理由（1 行）。理由が重なる時は 1 行だけ（材質が無い → 骨つき → 2 本目の uv が無い → tex3d: でない の順）。
    /// 毎コマ通るので、呼ぶ側が名前ごとに初回 1 回だけ出す。
    pub def lightmapWarning(i: Instance3d): Option[String] = lightmapProblem(instanceFieldsOf(i))

    def lightmapProblem(f: InstanceFields): Option[String] =
        f#lightmap |> Option.flatMap(lm ->
            if (Option.isEmpty(f#material)) Some("scene3d: lightmap ${lm#texture} を付けた物に材質が無い — lightmap を使わずに描く（Scene3d.material で包む）")
            else if (Option.nonEmpty(skinningOfFields(f))) Some("scene3d: lightmap ${lm#texture} は骨つきの物には使わない — 今の光で描く")
            else if (Option.isEmpty(Mesh3d.uvs2(f#mesh))) Some("scene3d: lightmap ${lm#texture} を付けた形に 2 本目の uv が無い — lightmap を使わずに描く（glb の TEXCOORD_1 か Mesh3d.withUvs2）")
            else if (not String.startsWith(prefix = Texture3d.namePrefix(), lm#texture)) Some("scene3d: lightmap の名前 ${lm#texture} は場面の textures の絵（Texture3d.name）でない — lightmap を使わずに描く")
            else None)

    /// 置いた物が読む絵の名前（材質の tex 場と emission・法線マップ・使える lightmap）。材質の絵の上限（maxMaterialTextures）で切らずに全部。
    /// 描き出しが読む絵の組・描き出しの鍵の絵の一覧は、これから数える。
    pub def textureNamesOf(i: Instance3d): List[String] =
        let fromMaterial = instanceFieldsOf(i)#material |> Option.toList |> List.flatMap(m -> {
            let f = materialFieldsOf(m);
            List.append(materialTexReadsOf(f) |> List.map(fst), f#normalMap |> Option.toList |> List.map(n -> n#texture))
        });
        List.append(fromMaterial, lightmapOf(i) |> Option.toList |> List.map(lm -> lm#texture))

    /// ビルボードの中身。texture と regionRect = 貼る絵（テクスチャの px）・position = 立てる world の点・
    /// size = world の幅と高さ・anchor = position に合わせる絵の中の点（0〜1。(0.5, 1) で足元の真ん中）・
    /// tint = 絵に掛ける色・lit = 光とかすみを当てるか・
    /// castShadows = 太陽と点光源の影の地図に描くか（withCastShadows）・receiveShadows = 太陽の影を受けるか（withReceiveShadows。lit の時だけ効く）・
    /// shadowCasterScale = 影の地図に描く板の幅と高さに掛ける倍率（withShadowCasterScale。既定 (1, 1)）。
    pub type alias BillboardFields = { texture = String, regionRect = Rect2.Rect2, position = Vec3.Vec3, size = Vec2.Vec2,
                                       anchor = Vec2.Vec2, tint = Color, lit = Bool, castShadows = Bool, receiveShadows = Bool,
                                       shadowCasterScale = Vec2.Vec2 }

    enum BillboardData { case BillboardData(BillboardFields) }

    /// 深度つきのビルボード（ドット絵を 3D に立てる。閉じた型 — 欄を後から足してもゲームの値が壊れない）。
    pub type alias Billboard3d = BillboardData

    /// anchor 足元の真ん中・tint 白・光を当てる・影を落とさない・影を受けない。
    pub def billboard(texture: String, regionRect: Rect2.Rect2, position: Vec3.Vec3, size: Vec2.Vec2): Billboard3d =
        BillboardData.BillboardData({ texture = texture, regionRect = regionRect, position = position, size = size,
                                      anchor = { x = 0.5, y = 1.0 }, tint = Color.rgb(1.0, 1.0, 1.0), lit = true,
                                      castShadows = false, receiveShadows = false, shadowCasterScale = Vec2.one() })

    /// 太陽の影の地図に描く（Unity の Cast Shadows・Godot の cast_shadow）。地図の中では、同じ大きさの板を地面に垂直に立て、
    /// 太陽の方へ向けて（billboardShadowRightOf）絵の α < 0.5 を捨てて描くので、影は絵の形で太陽の向きに伸びる。
    /// 点光源の影（withPointShadows）の地図にも、板を光の方へ向けて描く（Scene3d.PointShadows.castingBillboardsOf）。スポットの影の地図には描かない。影の地図の無い場面では何もしない。
    // WhyNot: スポットの影に入れない — スポットの影の判定は光の式の木の中（spotShadow）で受ける点を動かせず、ビルボードが自分の影を受けて黒くなる。
    pub def withCastShadows(on: Bool, b: Billboard3d): Billboard3d =
        let BillboardData.BillboardData(r) = b;
        BillboardData.BillboardData({ castShadows = on | r })

    /// 影の地図に描く板の大きさの倍率（x = 幅・y = 高さ。既定 (1, 1)）。見えている板は変えず、影だけを細く・短くする
    /// （ドット絵のキャラの影が「人形がそのまま大きくなった」ように見える時に、幅を 0.5〜0.7・高さを 0.6〜0.8 に絞る）。
    /// 板は anchor を中心に縮むので、anchor が足元なら影の根元は足元のまま。太陽と点光源の影の両方に効く。0 以下の成分は影を描かない。
    // WhyNot: 影の板をカメラの向きへ寄せる角度で細くしない — 太陽が横からの時ほど細り方が変わり、点光源では灯りごとに違う角度になる。倍率なら光の向きに依らず同じ細さ。
    pub def withShadowCasterScale(scale: Vec2.Vec2, b: Billboard3d): Billboard3d =
        let BillboardData.BillboardData(r) = b;
        BillboardData.BillboardData({ shadowCasterScale = scale | r })

    /// 影の地図に描く時の板（size に shadowCasterScale を掛けた物）。描き手は影の地図にこの値を描く。
    pub def shadowCasterFieldsOf(f: BillboardFields): BillboardFields =
        { size = Vec2.v2(f#size#x * f#shadowCasterScale#x, f#size#y * f#shadowCasterScale#y) | f }

    /// 影の地図に描く大きさが残るか（shadowCasterScale の成分が両方とも正）。
    def hasShadowCasterSize(f: BillboardFields): Bool = f#shadowCasterScale#x > 0.0 and f#shadowCasterScale#y > 0.0

    /// 太陽の影を受ける（Unity の Receive Shadows）。lit の時だけ効く。受ける点は絵の中の高さごとに 1 つ（billboardShadowPointOf）で、
    /// 建物の影に入ると絵の行ごとに暗くなる。
    pub def withReceiveShadows(on: Bool, b: Billboard3d): Billboard3d =
        let BillboardData.BillboardData(r) = b;
        BillboardData.BillboardData({ receiveShadows = on | r })

    /// 影の地図に描くビルボードの板の横の向き（長さ 1・水平）。toward = 点から太陽への向き・fallback = 太陽が真上の時の向き（カメラの right）。
    /// 太陽がカメラの後ろにある時にカメラの right と同じ向きになる（影の絵が見える絵と左右で合う）。
    // WhyNot: 太陽が前（逆光）の時にカメラの right へそろえ直さない — 光の側から見た板の絵は左右が返るのが本当の影の向きで、
    //   そろえ直すと太陽が真横を回る所で影の絵がぱっと左右に入れ替わる。
    pub def billboardShadowRightOf(toward: Vec3.Vec3, fallback: Vec3.Vec3): Vec3.Vec3 =
        let hx = toward#x;
        let hz = toward#z;
        let len = Num.sqrt(hx * hx + hz * hz);
        if (len < 1.0e-6) fallback
        else Vec3.v3(0.0 - hz / len, 0.0, hx / len)

    /// 場面の太陽の影の地図に描くビルボードの板の横の向き（太陽の無い場面はカメラの right）。GL・WebGPU・CPU の描き手がこれ 1 つを読む。
    pub def billboardShadowRightOfScene(scene: Scene3dCmd): Vec3.Vec3 =
        let fallback = Camera3d.right(scene#camera);
        directionalLightOf(scene) |> Option.map(l -> billboardShadowRightOf(sunTermsOf(l)#toward, fallback)) |> Option.getWithDefault(fallback)

    /// ビルボードが太陽の影を受ける点: 絵の中の縦の位置 v（0 = 絵の上・1 = 絵の下）の、影の地図に描いた板の真ん中の縦の線の上の点を、
    /// 太陽の方へ billboardShadowOffsetOf(f) / max(toward の水平の長さ, billboardShadowMinFlat()) だけ進めた点。GL・WebGPU・CPU の描き手が画素ごとに同じ式で求める。
    /// 板から水平に幅の半分だけ離れるので、太陽の高さ約 75° までは pcf の周りの画素でも自分の影を拾わない（それより高い太陽では足元から拾い始める）。
    // WhyNot: 見えている板（カメラへ向く）の上の点で引かない — 影の地図の板は太陽へ向けて立てた別の向きで、見えている板の半分が自分の影に入る。
    // WhyNot: 太陽の方へ進めずに板の上の点で引かない — 点が自分の影の板の上に乗り、pcf の周りの画素で板の傾きの分だけ自分の影を拾う。
    // WhyNot: 太陽が高いほど進める長さを上限なしに伸ばさない — 点が上へ逃げ、軒下に立った板が軒の影から抜けて明るくなる。
    pub def billboardShadowPointOf(f: BillboardFields, toward: Vec3.Vec3, v: Float64): Vec3.Vec3 =
        let flat = Float64.max(billboardShadowMinFlat(), Num.sqrt(toward#x * toward#x + toward#z * toward#z));
        let offset = billboardShadowOffsetOf(f) / flat;
        Vec3.v3(f#position#x + toward#x * offset, f#position#y + (f#anchor#y - v) * f#size#y + toward#y * offset, f#position#z + toward#z * offset)

    /// 影を受ける点を板から水平に離す長さ（板の幅の半分）。billboardShadowPointOf が太陽の高さで割って太陽の方へ進める。
    pub def billboardShadowOffsetOf(f: BillboardFields): Float64 = 0.5 * Float64.abs(f#size#x)

    /// billboardShadowPointOf が割る、太陽への向きの水平の長さの下限（太陽の高さ約 75.5°）。GLSL・WGSL の字にも同じ数を書く。
    pub def billboardShadowMinFlat(): Float64 = 0.25

    /// 太陽の影の地図に描くビルボード（castShadows が真で、影を落とす物の視錐台 frustum の中の物。来た順）。大きさは shadowCasterFieldsOf の物。
    pub def shadowCastingBillboardsOf(frustum: Frustum.Frustum, scene: Scene3dCmd): List[BillboardFields] =
        scene#billboards |> List.filter(b -> { let f = billboardFieldsOf(b); f#castShadows and hasShadowCasterSize(f) } and not isBillboardOutsideFrustum(frustum, b))
            |> List.map(b -> shadowCasterFieldsOf(billboardFieldsOf(b)))

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

    /// 場面 1 つ。size = 描き物の大きさ（位置は PlacedItem の at。Shader 面と同じ決まり）・zIndex = 2D の並びの中の重なり順・
    /// textures = 材質が "tex3d:" の名前（Texture3d.name）で読む絵・
    /// sky = 何も描かれない画素に描く空（gradientSky。Some なら environment の background は使わない）・
    /// environmentMap = metallic と roughness を持つ材質の映り込みが読む周りの景色（environmentMap。None なら空のグラデーションを映す）・
    /// directionalLight = 太陽（1 つまで。None なら無し。使うかどうかは directionalLightOf で決める）・
    /// groups = 動かない物の集まり（staticGroup。中の物は instances と同じに描かれる。読むのは instancesOf）・multiMeshes = 同じ形をたくさん（MultiMesh3d.build。既定 Nil）・
    /// unitsPerMeter = 1 m が場面の長さのいくつか（withUnitsPerMeter。Legacy の光では描き方は変えず、m で受ける値（PostStack の奥行きのぼかし）と Physical の光の逆二乗が読む）・
    /// pointShadows = 点光源の影（withPointShadows。None なら影なし）・lightUnits = 光の量の読み方（withLightUnits。既定 Legacy）・
    /// psx = PS1 風の描き方（withPsx。既定 psxOff = 全部切る）。
    pub type alias Scene3dCmd = { size = Vec2.Vec2, camera = Camera3d.Camera3d, instances = List[Instance3d], groups = List[StaticGroup], multiMeshes = List[MultiMesh3d.MultiMesh3d], billboards = List[Billboard3d],
                                  pointLights = List[PointLight], spotLights = List[SpotLight], directionalLight = Option[DirectionalLight], environment = Environment3d,
                                  resolution = Resolution, output = Output, zIndex = Int32, time = Float64,
                                  textures = List[Texture3d.Texture3d], sky = Option[Sky3d], environmentMap = Option[EnvironmentMap], unitsPerMeter = Float64,
                                  pointShadows = Option[PointShadowMap], lightUnits = LightUnits, psx = PsxLook }

    /// 空の場面（環境光は白・光なし・かすみなし・地の色なし・Native・色を書き出す・zIndex 0・時刻 0・絵なし・空なし・1 m = 1・点光源の影なし・Legacy の光・PS1 風は切る）。
    /// time = 材質の ShaderDoc の時刻（秒）（ゲームの遊びの時計を渡すと、ポーズやヒットストップで材質の動きも止まる）。
    /// Scene3dCmd は開いたレコードなので `{ instances = … | s }` で足す。
    // WhyNot: 環境光を黒にしない — 光を置く前の場面が真っ黒になり、形を置いたのに何も出ないように見える。
    pub def scene(camera: Camera3d.Camera3d, size: Vec2.Vec2): Scene3dCmd =
        { size = size, camera = camera, instances = Nil, groups = Nil, multiMeshes = Nil, billboards = Nil, pointLights = Nil, spotLights = Nil, directionalLight = None,
          environment = { ambient = Color.rgb(1.0, 1.0, 1.0), hemisphere = 0.0, toonSteps = 0, fog = None, background = None },
          resolution = Resolution.Native, output = Output.Color, zIndex = 0, time = 0.0, textures = Nil, sky = None, environmentMap = None,
          unitsPerMeter = 1.0, pointShadows = None, lightUnits = LightUnits.Legacy, psx = psxOff() }

    /// 1 m が場面の長さのいくつかを言う（既定 1 = glTF・Blender と同じ）。Blender の 1 m を 16 で置いた場面は 16。
    pub def withUnitsPerMeter(k: Float64, scene: Scene3dCmd): Scene3dCmd = { unitsPerMeter = k | scene }

    // ── 動かない物の集まり ──

    /// 動かない物の集まりの中身。name = 診断と知らせに出す名前・items = (鍵, 置いた物) の並び・removed = 描かない物の鍵（withoutItems）・
    /// tint = 中の物の tint に掛ける色（withGroupTint。白なら変えない）。
    pub type alias StaticGroupFields = { name = String, items = List[(String, Instance3d)], removed = Set[String], tint = Color }

    enum StaticGroupData { case StaticGroupData(StaticGroupFields) }

    /// 動かない物の集まり（Unity の Static・Unreal の Mobility = Static に当たる）。場面の groups に載せると、中の物は instances と同じ絵で描かれ、
    /// 描き手は同じ集まりが続くコマで計画と描く行を持ち越す。同じ集まりかは、staticGroup で作った items の値そのもの・removed・tint で見る。
    /// 集まりは読み込みの時に 1 回作って Resources に持ち、毎コマ同じ値を渡す（毎コマ staticGroup を呼ぶと、絵は同じだが毎コマ作り直しになり遅い）。
    /// 中の 1 個だけ動かす・色を変える物は withoutItems で外し、instances に普通に置く。
    pub type alias StaticGroup = StaticGroupData

    /// name の集まり（items の鍵は集まりの中で重ならない物にする。withoutItems が鍵で外す）。
    pub def staticGroup(name: String, items: List[(String, Instance3d)]): StaticGroup =
        StaticGroupData.StaticGroupData({ name = name, items = items, removed = Set.empty(), tint = Color.rgb(1.0, 1.0, 1.0) })

    /// keys の鍵の物を描かない集まり（前に外した鍵に足す）。外す物を変えたコマは、描き手が持ち越しを作り直す。
    pub def withoutItems(keys: Set[String], g: StaticGroup): StaticGroup =
        let StaticGroupData.StaticGroupData(r) = g;
        StaticGroupData.StaticGroupData({ removed = Set.union(r#removed, keys) | r })

    /// 中の物の tint に c を掛ける集まり（前の withGroupTint の色は置き換える）。色を変えたコマは、描き手が持ち越しを作り直す。
    // WhyNot: 毎コマ変わる色をここで渡さない書き方を勧める — 色は 1 体ごとの値に入るので、変わるたびに集まりの物を全部詰め直す。
    pub def withGroupTint(c: Color, g: StaticGroup): StaticGroup =
        let StaticGroupData.StaticGroupData(r) = g;
        StaticGroupData.StaticGroupData({ tint = c | r })

    /// 集まりの中身を読む（描き手が使う）。
    pub def staticGroupFieldsOf(g: StaticGroup): StaticGroupFields =
        let StaticGroupData.StaticGroupData(r) = g;
        r

    /// 集まりの描く物（外した鍵の物を除き、tint を掛けた物・来た順）。
    pub def groupInstancesOf(g: StaticGroup): List[Instance3d] =
        let r = staticGroupFieldsOf(g);
        let white = r#tint#r == 1.0 and r#tint#g == 1.0 and r#tint#b == 1.0;
        r#items |> List.filterMap(match (key, i) ->
            if (Set.memberOf(key, r#removed)) None
            else if (white) Some(i)
            else Some(tintedBy(r#tint, i)))

    def tintedBy(c: Color, i: Instance3d): Instance3d =
        let InstanceData.InstanceData(f) = i;
        InstanceData.InstanceData({ tint = Color.rgb(f#tint#r * c#r, f#tint#g * c#g, f#tint#b * c#b) | f })

    /// 場面に描く物が 1 つでもあるか（集まりは外していない鍵が 1 つでもあるか・MultiMesh は 1 体でもあるか。先頭で止まり、描く物の列を作らない。描き手が影を落とすかを決める）。
    pub def hasDrawnInstance(scene: Scene3dCmd): Bool =
        not List.isEmpty(scene#instances) or List.exists(g -> { let r = staticGroupFieldsOf(g); List.exists(kv -> not Set.memberOf(fst(kv), r#removed), r#items) }, scene#groups) or List.exists(mm -> MultiMesh3d.countOf(mm) > 0, scene#multiMeshes)

    /// 場面の描く物の全部（instances の後ろに groups の物を集まりの順に、その後ろに multiMeshes の物を 1 体ずつ）。CPU の描き手と描き出しが描く（GL と WebGPU は groups と multiMeshes を別に持つ）。
    pub def instancesOf(scene: Scene3dCmd): List[Instance3d] =
        let base = if (List.isEmpty(scene#groups)) scene#instances else List.append(scene#instances, List.flatMap(groupInstancesOf, scene#groups));
        if (List.isEmpty(scene#multiMeshes)) base else List.append(base, List.flatMap(MultiMesh3d.toInstances, scene#multiMeshes))

    // ── 環境マップ ──

    /// 環境マップの箱。室内の壁の位置（world）。min・max = 箱の対角の 2 点・center = 絵を撮った点（景色の向きの中心）。
    pub type alias EnvironmentBox = { min = Vec3.Vec3, max = Vec3.Vec3, center = Vec3.Vec3 }

    /// 環境マップの中身。texture = 場面の textures の絵の名前（Texture3d.name）・intensity = 線形の量に戻した後に掛ける倍率・
    /// box = 室内の壁の補正（None なら無限に遠い景色）・asBackground = 空の代わりに背景へも描くか・skyContribution = 拡散の光に景色を混ぜる割合（0..1）・
    /// irradiance = withIrradiance で渡した拡散の光・textureIrradiance = 絵から求める拡散の光（初めて読んだ時に 1 回だけ求める）・
    /// colorSpace = 絵の値の意味（8bit の絵は Srgb で線形へ戻して読む・half の絵は Linear でそのまま読む。environmentMap が絵の形式から決める）。
    pub type alias EnvironmentMapFields = { texture = String, intensity = Float64, box = Option[EnvironmentBox], asBackground = Bool, colorSpace = Texture3d.ColorSpace,
                                            skyContribution = Float64, irradiance = Option[SphericalHarmonics.SphericalHarmonics],
                                            textureIrradiance = Lazy[Option[SphericalHarmonics.SphericalHarmonics]] }

    enum EnvironmentMapData { case EnvironmentMapData(EnvironmentMapFields) }

    /// 周りの景色のパノラマの絵（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。environmentMap から作り、with… で足す。
    /// Unity の Skybox（Panoramic）と Reflection Probe の Box Projection・Godot の PanoramaSkyMaterial と ReflectionProbe の box_projection に当たる。
    pub type alias EnvironmentMap = EnvironmentMapData

    /// 正距円筒（横 2：縦 1）のパノラマの絵 texture を景色にする。絵は Scene3dCmd の textures にも載せる（"tex3d:" の名前）。
    /// 8bit の絵は sRGB の絵として・half の絵（Texture3d.decodeHdr）は線形の量のまま読み、強さ 1・箱なし・背景には描かない。向きと絵の座標は LightModel3d.environmentUvOf。
    /// 映るのは metallic と roughness を持つ材質の映り込みだけで、拡散の光（ambient と hemisphere）は変わらない（変えるのは withSkyContribution）。
    pub def environmentMap(texture: Texture3d.Texture3d): EnvironmentMap =
        let colorSpace = if (Texture3d.formatOf(texture) == Texture3d.Format.Rgba16Float) Texture3d.ColorSpace.Linear else Texture3d.ColorSpace.Srgb;
        EnvironmentMapData.EnvironmentMapData({ texture = Texture3d.name(texture), intensity = 1.0, box = None, asBackground = false, colorSpace = colorSpace,
                                                skyContribution = 0.0, irradiance = None, textureIrradiance = Texture3d.Internal.irradianceOf(texture) })

    /// 拡散の光（ambient）を景色から求めた光へ混ぜる割合 k（Godot の ambient_light_sky_contribution）。0..1 に丸め、NaN は 0。既定 0（ambient のまま）。
    /// 光 = ambient + (景色の拡散の光 × 強さ − ambient) × k。景色の拡散の光は withIrradiance で渡した物、無ければ絵から求めた物
    /// （SphericalHarmonics.fromEquirectangular。機種の側の絵は求められないので ambient のまま描いて 1 回知らせる）。
    /// hemisphere も空の光なので、k を上げる時は hemisphere を 0 にする（2 回足すと 1 回知らせる）。lightmap の面には足さない。
    pub def withSkyContribution(k: Float64, e: EnvironmentMap): EnvironmentMap =
        let EnvironmentMapData.EnvironmentMapData(r) = e;
        EnvironmentMapData.EnvironmentMapData({ skyContribution = if (Float64.isNan(k)) 0.0 else Num.clamp01(k) | r })

    /// 拡散の光に景色を混ぜる割合（withSkyContribution で丸めた後の値）。
    pub def skyContributionOf(e: EnvironmentMap): Float64 = environmentMapFieldsOf(e)#skyContribution

    /// 景色の拡散の光を外から渡す（前に求めた SH を JSON で持つ・空の色から作る時。Filament の IndirectLight.irradiance）。絵から求める物より先に使う。
    pub def withIrradiance(sh: SphericalHarmonics.SphericalHarmonics, e: EnvironmentMap): EnvironmentMap =
        let EnvironmentMapData.EnvironmentMapData(r) = e;
        EnvironmentMapData.EnvironmentMapData({ irradiance = Some(sh) | r })

    /// withIrradiance で渡した拡散の光（渡していなければ None。絵から求めはしない）。
    pub def irradianceOf(e: EnvironmentMap): Option[SphericalHarmonics.SphericalHarmonics] = environmentMapFieldsOf(e)#irradiance

    /// 映り込みの強さの倍率（線形の量に戻した後に掛ける。0 で映り込み無し。負・NaN は 0 として描く）。
    pub def withEnvironmentIntensity(k: Float64, e: EnvironmentMap): EnvironmentMap =
        let EnvironmentMapData.EnvironmentMapData(r) = e;
        EnvironmentMapData.EnvironmentMapData({ intensity = k | r })

    /// 室内の壁の補正（Box Projection）。跳ね返りの線を点から伸ばして箱の内側の面と交わる点を、center から見た向きで絵を読む。
    /// 部屋の中の物に使い、屋外の空には付けない（景色が無限に遠いので補正が要らない）。
    pub def withEnvironmentBox(box: EnvironmentBox, e: EnvironmentMap): EnvironmentMap =
        let EnvironmentMapData.EnvironmentMapData(r) = e;
        EnvironmentMapData.EnvironmentMapData({ box = Some(box) | r })

    /// 真なら、何も描かれない画素に景色の絵を空として描く（屋外の景色の絵向き。向きは映り込みと同じ・段 0 で読み、強さも掛かる。sky があればそちらが勝つ）。
    pub def withEnvironmentAsBackground(on: Bool, e: EnvironmentMap): EnvironmentMap =
        let EnvironmentMapData.EnvironmentMapData(r) = e;
        EnvironmentMapData.EnvironmentMapData({ asBackground = on | r })

    /// 環境マップの中身を読む（GL・CPU・鍵が使う）。intensity は描き手が environmentIntensityOf で直した値を読む。
    pub def environmentMapFieldsOf(e: EnvironmentMap): EnvironmentMapFields =
        let EnvironmentMapData.EnvironmentMapData(r) = e;
        r

    /// 描く時に使う強さ（負・NaN・無限は 0）。GL と CPU が同じ値を使う。
    pub def environmentIntensityOf(e: EnvironmentMap): Float64 =
        let k = environmentMapFieldsOf(e)#intensity;
        if (Float64.isFinite(k) and k > 0.0) k else 0.0

    /// 場面の環境マップが読む絵の名前（無ければ空）。描き出しが読む絵の組・描き出しの鍵の絵の一覧は、材質の絵（textureNamesOf）とこれから数える。
    pub def environmentTextureNamesOf(scene: Scene3dCmd): List[String] =
        scene#environmentMap |> Option.toList |> List.map(e -> environmentMapFieldsOf(e)#texture)

    /// 空の代わりに背景へ景色を描く時の環境マップ（asBackground が真で、sky が無い時だけ Some。sky があれば sky が勝つ）。
    pub def backgroundEnvironmentOf(scene: Scene3dCmd): Option[EnvironmentMap] =
        if (Option.nonEmpty(scene#sky)) None
        else scene#environmentMap |> Option.filter(e -> environmentMapFieldsOf(e)#asBackground)

    /// 描き手が空として塗る物（sky があれば sky・無くて景色を背景に描くなら黒の空 — 色は景色の絵が上書きするので使われない）。
    pub def drawnSkyOf(scene: Scene3dCmd): Option[Sky3d] =
        match scene#sky {
            case Some(s) => Some(s)
            case None    => backgroundEnvironmentOf(scene) |> Option.map(_ -> gradientSky(Color.rgb(0.0, 0.0, 0.0), Color.rgb(0.0, 0.0, 0.0), Color.rgb(0.0, 0.0, 0.0)))
        }

    /// 環境マップの箱の 3 点を GL の uniform と CPU の引数に渡す形にそろえる（min と max は軸ごとに小さい方を min に）。
    pub def environmentBoxOf(b: EnvironmentBox): EnvironmentBox =
        { min = Vec3.v3(Float64.min(b#min#x, b#max#x), Float64.min(b#min#y, b#max#y), Float64.min(b#min#z, b#max#z)),
          max = Vec3.v3(Float64.max(b#min#x, b#max#x), Float64.max(b#min#y, b#max#y), Float64.max(b#min#z, b#max#z)) | b }

    // ── 空 ──

    /// 空の中身。zenith = 真上の色・horizon = 地平の色・ground = 真下の色・curve = 地平から真上（真下）へ向かう色の寄り方
    /// （1 で角度の sin にまっすぐ・大きいほど地平の色が広い。Godot の ProceduralSkyMaterial の sky_curve と同じ向き）。
    pub type alias SkyFields = { zenith = Color, horizon = Color, ground = Color, curve = Float64 }

    enum SkyData { case SkyData(SkyFields) }

    /// 3D の場面の空（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。gradientSky から作り、with… で替える。
    pub type alias Sky3d = SkyData

    /// 上下のグラデーションの空（曲がり 1）。目から見た向き d の色は、d.y ≥ 0 なら horizon と zenith の間を d.y^curve で、
    /// d.y < 0 なら horizon と ground の間を (−d.y)^curve でつなぐ（LightModel3d.skyModel）。かすみは掛けない
    /// （地平の色をかすみの色にそろえると、遠くの物と空の継ぎ目が消える）。
    pub def gradientSky(zenith: Color, horizon: Color, ground: Color): Sky3d =
        SkyData.SkyData({ zenith = zenith, horizon = horizon, ground = ground, curve = 1.0 })

    /// 地平から真上・真下へ向かう色の寄り方を替える。0 以下・NaN・無限は 1 として描く（skyCurveOf）。
    pub def withSkyCurve(curve: Float64, s: Sky3d): Sky3d =
        let SkyData.SkyData(r) = s;
        SkyData.SkyData({ curve = curve | r })

    /// 空の中身を読む（GL・CPU・鍵が使う）。
    pub def skyFieldsOf(s: Sky3d): SkyFields =
        let SkyData.SkyData(r) = s;
        r

    /// 描く時に使う曲がり（0 以下・NaN・無限は 1）。GL と CPU が同じ値を使う。
    pub def skyCurveOf(s: Sky3d): Float64 =
        let c = skyFieldsOf(s)#curve;
        if (Float64.isFinite(c) and c > 0.0) c else 1.0

    /// 画素の向きを組む材料（場面のカメラから 1 回だけ作る）。forward = 画面の真ん中の画素の向き（レンズシフトが 0 なら見ている向き。長さは 1 とは限らない）・right = 画面の右の向き × tan(fovY / 2) × 縦横の比・
    /// up = 画面の上の向き × tan(fovY / 2)。NDC の点 (x, y) の向きは skyDirectionOf（Camera3d.screenPointToRay と同じ式）。
    pub type alias SkyBasis = { forward = Vec3.Vec3, right = Vec3.Vec3, up = Vec3.Vec3 }

    /// 場面 scene のカメラと縦横の比（aspectOf）で、空の画素の向きを組む材料を作る。GL と CPU が同じ物を使う。
    pub def skyBasisOf(scene: Scene3dCmd): SkyBasis =
        let c = scene#camera;
        let half = c#fovY / 2.0;
        let tanHalf = Num.sin(half) / Num.cos(half);
        let right = Vec3.mul(Camera3d.right(c), tanHalf * aspectOf(scene));
        let up = Vec3.mul(Camera3d.up(c), tanHalf);
        let center = if (Camera3d.hasLensShift(c))
                Vec3.add(Camera3d.forward(c), Vec3.add(Vec3.mul(right, 2.0 * c#lensShift#x), Vec3.mul(up, 2.0 * c#lensShift#y)))
            else Camera3d.forward(c);
        { forward = center, right = right, up = up }

    /// NDC の点 ndc（−1..1・y は上へ）を通って目から伸びる向き（長さ 1）。
    pub def skyDirectionOf(b: SkyBasis, ndc: Vec2.Vec2): Vec3.Vec3 =
        Vec3.normalized(Vec3.add(b#forward, Vec3.add(Vec3.mul(b#right, ndc#x), Vec3.mul(b#up, ndc#y))))

    /// sky と environment の background が両方 Some の時の、知らせる 1 行（background は使わない）。毎コマ通るので呼ぶ側が初回 1 回だけ出す。
    pub def skyWarning(scene: Scene3dCmd): Option[String] =
        if (Option.nonEmpty(scene#sky) and Option.nonEmpty(scene#environment#background))
            Some("scene3d: sky と environment の background が両方ある — background は使わず空を描く")
        else None

    /// 1 つの場面で計算する点光源の上限。
    pub def maxPointLights(): Int32 = 8

    /// 1 つの場面で計算するスポットライトの上限。
    pub def maxSpotLights(): Int32 = 2

    /// 影の地図の縦横の上限（GL 3.3 が約束する大きさより大きいが、今の GPU なら作れる）。GL と CPU が同じ値で頭打ちにする。
    pub def maxShadowMapSize(): Int32 = 4096

    /// pcfRadius の上限（(2r+1)² 回の読みを画素ごとに行うので、大きすぎる値で GPU を止めない）。GL と CPU が同じ値で頭打ちにする。
    pub def maxShadowPcfRadius(): Int32 = 8

    /// スポットライトから見たカメラ（影の地図を描く目）。位置から target を向き、fovY の角で見る。far は max(2, range)・near は min(1, far / 100)。
    /// target が位置と同じ所なら真下を向く。
    // WhyNot: near を 1 に決め打ちしない — 1 = 1 m の部屋の卓上の灯り（光から 1 m 以内に物がある）では、影を落とす物も受ける面も near の手前で切れて影が出ない。
    // WhyNot: near を range に依らず小さく決めない — 奥行きの値の細かさは far / near で決まり、range の長い光（街の灯り）の影の地図が粗くなる。
    pub def shadowCamera(spot: SpotLight): Camera3d.Camera3d =
        let d = Vec3.sub(spot#target, spot#position);
        let len = Vec3.length(d);
        let dir = if (len < 0.000001) { x = 0.0, y = -1.0, z = 0.0 } else Vec3.mul(d, 1.0 / len);
        let flat = Num.sqrt(dir#x * dir#x + dir#z * dir#z);
        let far = Float64.max(2.0, spot#range);
        { eye = spot#position, yaw = Num.atan2(dir#x, dir#z), pitch = Num.atan2(0.0 - dir#y, flat),
          fovY = spot#fovY, near = Float64.min(1.0, far / 100.0), far = far, lensShift = Vec2.zero() }

    /// スポットの影の判定で地図の値と比べる時に引く値（ShadowMap の bias を、shadowCamera の near で縮めた物）。GL・WebGPU・CPU の描き手がこの値を使う。
    /// bias × near × (far − 1) / (far − near)。near が 1 の光（range 100 以上）は bias のまま。
    // WhyNot: bias をそのまま引かない — 透視の奥行きの値の傾きは near に比例し、同じ bias が world で表す長さは near に反比例する。
    //   near を 1 から下げた分そのまま引くと、range の短いスポットの影が物の根元から浮く（range 8 で約 12 倍）。
    pub def spotShadowDepthBiasOf(spot: SpotLight, bias: Float64): Float64 =
        let c = shadowCamera(spot);
        bias * c#near * (c#far - 1.0) / (c#far - c#near)

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

    /// 上限を超えた光を選んで残す。残った物は元の並びの順のまま。上限以下の光は何も変えない（intensity も触らない）。
    /// 点光源: range の球が視錐台に掛からない物と、range か intensity が 0 以下の物を落とし、残りを画面の真ん中に近い順に maxPointLights 本選ぶ
    ///   （同じ近さなら並びの前の物）。選んだ物の intensity には 0〜1 の重みを掛ける。境の近くの光は強さが 0 へ寄るので、
    ///   カメラや光が動いて選ばれる物が替わっても、ぱっと点いたり消えたりしない。
    /// スポット: 目に近い物から選ぶ（同じ距離なら並びの前の物）。境をまたぐとぱっと切り替わる。
    /// GL・WebGPU・CPU が同じ物を使う。ゲームが選ばなくても描き手がこれで選ぶので、pointLights・spotLights には全部の光を渡してよい
    /// （ゲームの側で選び直さない）。
    // WhyNot: スポットを点光源と同じ選び方にしない — 上限が 2 本で入れ替わりが少なく、影を落とすのは選んだ後の並びの最初の 1 本なので、
    //   重みで暗くした光が影の地図を持つと、光が消えかけても影だけ濃く残る。
    pub def pickLights(cmd: Scene3dCmd): Scene3dCmd =
        { pointLights = Scene3d.Internal.PointLights.pickPointLights(cmd),
          spotLights = Scene3d.Internal.PointLights.nearest(maxSpotLights(), cmd#camera#eye, l -> l#position, cmd#spotLights) | cmd }

    /// 上限を超えた光の本数（points = 点光源・spots = スポット）。上限以下なら 0。
    /// pickLights は画面の外の光も落とすが、ここでは数えない（数がカメラの向きで揺れないように、渡した本数 − 上限）。
    pub def droppedLightsOf(cmd: Scene3dCmd): { points = Int32, spots = Int32 } =
        { points = Int32.max(0, List.length(cmd#pointLights) - maxPointLights()),
          spots = Int32.max(0, List.length(cmd#spotLights) - maxSpotLights()) }

    /// 1 コマに描く 3D の場面の列で上限を超えた光の本数の合計（points = 点光源・spots = スポット。droppedLightsOf の和）。
    /// GL・WebGPU の描き手が F3 の診断（FrameDiagnostics の droppedPointLights・droppedSpotLights）に足す数と同じ。
    /// 画面なしで確かめる時は `Scene3d.droppedLightsOfScenes(Render.drawScenes3d(items))`（描き出しの SoftScene なら `soft#scenes`）。
    pub def droppedLightsOfScenes(scenes: List[RenderCmd]): { points = Int32, spots = Int32 } =
        scenes |> List.foldLeft((acc, c) -> {
            let d = droppedLightsOf(c#scene);
            { points = acc#points + d#points, spots = acc#spots + d#spots }
        }, { points = 0, spots = 0 })

    /// 落とす光があれば、種類ごとに (鍵, 知らせる 1 行)。毎コマ通るので、呼ぶ側が鍵ごとに初回 1 回だけ出す（GL と CPU で同じ文面）。
    pub def droppedLightsWarnings(cmd: Scene3dCmd): List[(String, String)] =
        let d = droppedLightsOf(cmd);
        let line = (kind: String, given: Int32, limit: Int32) ->
            "scene3d: ${kind}が ${Int32.toString(given)} 本ある — 上限 ${Int32.toString(limit)} 本を選び、残りは描かない（Scene3d.pickLights）";
        (if (d#points > 0) ("@lights:point", line("点光源", List.length(cmd#pointLights), maxPointLights())) :: Nil else Nil)
            ::: (if (d#spots > 0) ("@lights:spot", line("スポットライト", List.length(cmd#spotLights), maxSpotLights())) :: Nil else Nil)

    /// Shader 効果へ渡す場面 1 つ。at = 描き物の左上（画面の px）・clip = 切り抜く矩形（画面の px）。
    // WhyNot: core の DrawCmd に置かない — 材質が ShaderDoc を持ち、core は ShaderDoc を参照しない層だから。
    pub type alias RenderCmd = { at = Vec2.Vec2, clip = Option[Rect2.Rect2], scene = Scene3dCmd }

    /// 描き手へ渡す、先に GPU へ上げる物の宣言（App.withPreload3d）。key = 中身を決める全入力をまとめた字・
    /// instances・textures = 上げる物と、その材質が "tex3d:" の名前で読む絵の作り方（key が変わった時だけ呼ばれる）・
    /// variants = 既定の版に足して組むシェーダーの変種（preloadVariantOf）・groups と scenes = 先に計画を作る動かない物の集まりと、それを描く場面
    /// （集まりごと・場面ごとに、描き手が描く時と同じ持ち越しの行を作る。key が変わった時だけ呼ばれる）。
    pub type alias PreloadCmd = { key = DrawCmd.StaticKey, instances = Unit -> List[Instance3d], textures = Unit -> List[Texture3d.Texture3d],
                                  variants = List[PreloadVariant], groups = Unit -> List[StaticGroup], scenes = Unit -> List[Scene3dCmd] }

    /// textures・variants・groups・scenes が空の宣言（`{ textures = () -> .. | Scene3d.preloadCmd(key, instances) }` で替える）。
    pub def preloadCmd(key: DrawCmd.StaticKey, instances: Unit -> List[Instance3d]): PreloadCmd =
        { key = key, instances = instances, textures = () -> Nil, variants = Nil, groups = () -> Nil, scenes = () -> Nil }

    /// 先に上げる宣言の進み具合。total = 作る物の数（集まり × 場面）・done = そのうち作り終えた数。全部済めば done == total
    /// （計画を持たない描き手と、集まりを宣言しないゲームはいつも 0 と 0）。
    pub type alias PreloadProgress = { done = Int32, total = Int32 }

    /// 作る物の無い進み具合（0 と 0。済んでいる）。
    pub def noPreload(): PreloadProgress = { done = 0, total = 0 }

    /// 進み具合 p が全部済んでいるか。
    pub def isPreloaded(p: PreloadProgress): Bool = p#done >= p#total

    /// 先に組むシェーダーの変種（場面の設定で決まる版）。pointShadows = 点光源の影を引く版（場面の pointShadows が Some・描き手の鍵の +ps）・
    /// physicalUnits = Physical の光の版（場面の lightUnits が Physical・+pu）・psx = PS1 風の版（場面の psx が Scene3d.Psx.isOn・+psx）。どれも偽なら既定の版（いつも組む）。
    /// skyIrradiance = 景色の拡散の光を混ぜる版（環境マップがあり skyContribution が 0 より大きい・+sh）。
    pub type alias PreloadVariant = { pointShadows = Bool, physicalUnits = Bool, psx = Bool, skyIrradiance = Bool }

    /// 場面 scene を描く時に描き手が組む変種（先に上げる宣言に、遊びで出す場面の設定から渡す）。
    pub def preloadVariantOf(scene: Scene3dCmd): PreloadVariant =
        { pointShadows = Option.nonEmpty(scene#pointShadows), physicalUnits = scene#lightUnits == LightUnits.Physical, psx = Scene3d.Psx.isOn(scene#psx),
          skyIrradiance = Scene3d.Internal.SkyIrradiance.isOn(scene) }

    /// 変種 v の字（"" = 既定・+ps・+pu・+psx・+sh の組。描き手のプログラムの鍵と同じ並び）。
    pub def preloadVariantKey(v: PreloadVariant): String =
        (if (v#pointShadows) "+ps" else "") + (if (v#physicalUnits) "+pu" else "") + (if (v#psx) "+psx" else "") + (if (v#skyIrradiance) "+sh" else "")
}
