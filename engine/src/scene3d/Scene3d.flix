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

    /// スポットライト。position から target を向き、fovY（ラジアン・円錐の全体の角）の円錐の中だけを照らす。shadow が Some なら影を落とす（段 C）。
    /// innerFovY = 縁で暗くなり始める角（ラジアン・全体の角）。この角の内側は縁による減り無しで、そこから fovY まで暗くなる。
    /// None なら fovY × spotInnerRatio()。小さくするほど輪の縁が広くぼける（懐中電灯）。直し方は spotConeOf。
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
        let outerCos = Vec2.cos(half);
        let innerCos = Vec2.cos(innerHalf);
        { outerCos = outerCos, innerCos = if (innerCos == outerCos) innerCos + 0.000001 else innerCos }

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

    /// uv が 0..1 の外へ出た時の読み方。Repeat = 繰り返す・Clamp = 端の色を伸ばす。
    pub enum Wrap with Eq {
        case Repeat
        case Clamp
    }

    /// 法線マップ。texture = 絵の名前（タンジェント空間・緑が絵の上）・strength = でこぼこの強さ（1 で絵のまま）。
    pub type alias NormalMap = { texture = String, strength = Float64 }

    /// 材質の中身。spec の Out の色 = 光を当てる前の色・params = spec の Param・
    /// cutout = 真なら α が 0.5 未満の画素を捨てる・emission = 光の計算の後に足す、自分で光る色・
    /// normalMap = 法線マップ（None なら頂点の法線のまま）・wrap = spec の Tex が 0..1 の外の uv を読む時の読み方（法線マップにも掛かる）。
    /// spec の Tex の名前は、"tex3d:" で始まれば場面の textures（Texture3d.name）、ほかは全体の登録（project.json の textures・
    /// レンダーターゲット）から引く。無い名前は 0（黒・透明）。1 つの材質が読める (名前, 補間) の組は maxMaterialTextures() まで。
    pub type alias MaterialFields = { spec = ShaderDoc.Spec, params = Map[String, Float64], cutout = Bool, emission = Option[ShaderDoc.Shade],
                                      normalMap = Option[NormalMap], wrap = Wrap }

    enum MaterialData { case MaterialData(MaterialFields) }

    /// 材質（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。material から作り、with… で足す。
    pub type alias Material3d = MaterialData

    /// spec だけの材質（params 空・cutout なし・emission なし・法線マップなし・Repeat）。
    pub def material(spec: ShaderDoc.Spec): Material3d =
        MaterialData.MaterialData({ spec = spec, params = Map.empty(), cutout = false, emission = None, normalMap = None, wrap = Wrap.Repeat })

    /// spec の Param に渡す値（Unity のマテリアルの float の値を渡すのと同じ。渡さない名前は 0）。
    pub def withParams(p: Map[String, Float64], m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ params = p | r })

    /// on が真なら α が 0.5 未満の画素を捨てる（深度も書かない）。
    pub def withCutout(on: Bool, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ cutout = on | r })

    /// 光の計算の後に足す、自分で光る色（かすみに沈まない）。
    /// 名前の付いた材質（Gltf の読んだ材質など）の emission を別の木に差し替えたら、withSpecName で名前も替える。
    /// GL は材質のプログラムを spec の名前と emission の有無で引くので、名前が同じで emission の木だけ違う材質が並ぶと毎コマ組み直す。
    pub def withEmission(s: ShaderDoc.Shade, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ emission = Some(s) | r })

    /// emission を外す（glb の emissive で光らせたくない時）。
    pub def withoutEmission(m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ emission = None | r })

    /// spec の名前だけを替える。spec の木か emission の木を差し替えた材質に、木ごとに違う名前を付ける
    /// （部品ごとに emission の mask が違うなら部品ごとの名前）。同じ名前を木の違う 2 つの材質に付けると、GL が毎コマ組み直す。
    pub def withSpecName(name: String, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ spec = { name = name | r#spec } | r })

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
    /// lightmap = ベイクした光（None なら無し。使うかどうかは lightmapOf で決める）。
    pub type alias InstanceFields = { mesh = Mesh3d.Mesh3d, world = Mat4.Mat4, tint = Color, material = Option[Material3d],
                                      pose = Option[Pose3d.Pose3d], lightmap = Option[Lightmap] }

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
        InstanceData.InstanceData({ mesh = mesh, world = world, tint = Color.rgb(1.0, 1.0, 1.0), material = None, pose = None, lightmap = None })

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
    pub def worldBoundsOf(i: Instance3d): Option[Mesh3d.Bounds] =
        let r = instanceFieldsOf(i);
        if (Option.nonEmpty(skinningOfFields(r)) or Mesh3d.vertexCount(r#mesh) == 0) None
        else {
            let corners = Mesh3d.cornersOf(Mesh3d.bounds(r#mesh)) |> List.map(Mat4.apply(r#world));
            let pick = (f: (Float64, Float64) -> Float64, axis: Vec3.Vec3 -> Float64) ->
                corners |> List.map(axis) |> List.reduceLeft(f) |> Option.getWithDefault(0.0);
            Some({ min = Vec3.v3(pick(Float64.min, v -> v#x), pick(Float64.min, v -> v#y), pick(Float64.min, v -> v#z)),
                   max = Vec3.v3(pick(Float64.max, v -> v#x), pick(Float64.max, v -> v#y), pick(Float64.max, v -> v#z)) })
        }

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
        not Frustum.intersectsSphere(f, r#position, Vec2.sqrt(rx * rx + ry * ry))

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
            List.append(ShaderDoc.materialTexReads(f#spec, f#emission) |> List.map(fst), f#normalMap |> Option.toList |> List.map(n -> n#texture))
        });
        List.append(fromMaterial, lightmapOf(i) |> Option.toList |> List.map(lm -> lm#texture))

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

    /// 場面 1 つ。size = 描き物の大きさ（位置は PlacedItem の at。Shader 面と同じ決まり）・zIndex = 2D の並びの中の重なり順・
    /// textures = 材質が "tex3d:" の名前（Texture3d.name）で読む絵。
    pub type alias Scene3dCmd = { size = Vec2.Vec2, camera = Camera3d.Camera3d, instances = List[Instance3d], billboards = List[Billboard3d],
                                  pointLights = List[PointLight], spotLights = List[SpotLight], environment = Environment3d,
                                  resolution = Resolution, output = Output, zIndex = Int32, time = Float64,
                                  textures = List[Texture3d.Texture3d] }

    /// 空の場面（環境光は白・光なし・かすみなし・地の色なし・Native・色を書き出す・zIndex 0・時刻 0・絵なし）。
    /// time = 材質の ShaderDoc の時刻（秒）（ゲームの遊びの時計を渡すと、ポーズやヒットストップで材質の動きも止まる）。
    /// Scene3dCmd は開いたレコードなので `{ instances = … | s }` で足す。
    // WhyNot: 環境光を黒にしない — 光を置く前の場面が真っ黒になり、形を置いたのに何も出ないように見える。
    pub def scene(camera: Camera3d.Camera3d, size: Vec2.Vec2): Scene3dCmd =
        { size = size, camera = camera, instances = Nil, billboards = Nil, pointLights = Nil, spotLights = Nil,
          environment = { ambient = Color.rgb(1.0, 1.0, 1.0), hemisphere = 0.0, toonSteps = 0, fog = None, background = None },
          resolution = Resolution.Native, output = Output.Color, zIndex = 0, time = 0.0, textures = Nil }

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
    /// GL と CPU が同じ物を使う。ゲームが選ばなくても描き手がこれで選ぶので、pointLights・spotLights には全部の光を渡してよい
    /// （ゲームの側で近い順に選び直さない）。
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
