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
        let outerCos = Num.cos(half);
        let innerCos = Num.cos(innerHalf);
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
    /// normalMap = 法線マップ（None なら頂点の法線のまま）・wrap = spec の Tex が 0..1 の外の uv を読む時の読み方（法線マップにも掛かる）・
    /// blend = 真なら spec の α で下の絵に重ねる半透明（深度は読むが書かない。描く順は blendOrderOf）・
    /// doubleSided = 真なら裏の面も描く（裏の面は光の計算の法線を裏返す）・
    /// emissionIntensity = emission を線形の量に戻した後に掛ける倍率（PointLight の intensity と同じ意味・既定 1）・
    /// metallicRoughness = 金属っぽさと粗さ（None なら今までどおり拡散光だけ。withMetallicRoughness で付ける）・
    /// metallicRoughnessShade = metallicRoughness から作る、光の計算に渡す色の場（r = metallic・g = roughness。値は params の pbrParamMetallic・pbrParamRoughness の Param、
    /// 絵があれば Tex の B・G を掛ける。描き手が読む。None と同時に None）・
    /// shaderHash = GLSL を決める中身（spec・emission・metallicRoughnessShade）の鍵（ShaderGen.hashMaterial。params・cutout などは入れない。GL が材質のプログラムを引く。初めて読んだ時に求める）。
    /// spec の Tex の名前は、"tex3d:" で始まれば場面の textures（Texture3d.name）、ほかは全体の登録（project.json の textures・
    /// レンダーターゲット）から引く。無い名前は 0（黒・透明）。1 つの材質が読める (名前, 補間) の組は maxMaterialTextures() まで。
    pub type alias MaterialFields = { spec = ShaderDoc.Spec, params = Map[String, Float64], cutout = Bool, emission = Option[ShaderDoc.Shade],
                                      normalMap = Option[NormalMap], wrap = Wrap, blend = Bool, doubleSided = Bool, emissionIntensity = Float64,
                                      metallicRoughness = Option[MetallicRoughness], metallicRoughnessShade = Option[ShaderDoc.Shade], shaderHash = Lazy[Int64] }

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
                                    metallicRoughness = None, metallicRoughnessShade = None, shaderHash = shaderHashOf(spec, None, None) })

    /// spec と emission の鍵を、初めて読まれた時に求める形で持つ。
    // WhyNot: 作る時にすぐ求めない — View で毎コマ材質を組み直すゲームでは、CPU の描き出しのように鍵を読まない描き手でも払うことになる。
    // WhyNot: 鍵のための lock の表（memo）を置かない — Flix の Lazy は force を lock で守って 1 回だけ求め、鍵は材質の値が持つので、
    //   別のスレッドから材質を読んでも表の取り合いが起きない。
    def shaderHashOf(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade], metallicRoughness: Option[ShaderDoc.Shade]): Lazy[Int64] =
        lazy ShaderGen.hashMaterial(spec, emission, metallicRoughness)

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
        MaterialData.MaterialData({ emission = Some(s), shaderHash = shaderHashOf(r#spec, Some(s), r#metallicRoughnessShade) | r })

    /// emission を外す（glb の emissive で光らせたくない時）。emissionIntensity も 1 に戻す。
    pub def withoutEmission(m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ emission = None, emissionIntensity = 1.0, shaderHash = shaderHashOf(r#spec, None, r#metallicRoughnessShade) | r })

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
        MaterialData.MaterialData({ spec = spec, shaderHash = shaderHashOf(spec, r#emission, r#metallicRoughnessShade) | r })

    /// 金属っぽさ metallic と粗さ roughness を付ける（Unity の Standard・Godot の StandardMaterial3D と同じ 2 つの値。どちらも 0..1 に丸める）。
    /// 鏡面ハイライトと空の映り込みが付き、拡散光は (1 − metallic) 倍になる。付けない材質の絵は変わらない。
    /// 絵（withMetallicRoughnessTexture）が付いていれば、絵の値に掛ける係数になる。毎コマ変えてもプログラムを組み直さない（params の値）。
    /// glb の材質は、pbrMetallicRoughness に metallicFactor・roughnessFactor・metallicRoughnessTexture のどれかがあれば読み込む時に付く。
    // WhyNot: 場面の環境（Environment3d）に metallic を置かない — 材質ごとの値で、同じ場面に金属と木が並ぶ。
    pub def withMetallicRoughness(metallic: Float64, roughness: Float64, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        let texture = r#metallicRoughness |> Option.flatMap(mr -> mr#texture);
        withMetallicRoughnessOf({ metallic = unitOf(metallic), roughness = unitOf(roughness), texture = texture }, r)

    /// metallic と roughness を絵 texture から読む（glTF の metallicRoughnessTexture と同じ決まり: B = metallic・G = roughness）。
    /// 付いている metallic・roughness は絵の値に掛ける係数のまま残り、まだ無ければ 1・1（glTF の既定）。名前の決まりは Texture の Tex と同じ
    /// （"tex3d:" で始まれば場面の textures）。絵は材質の絵の上限（maxMaterialTextures）の 1 組に数える。
    pub def withMetallicRoughnessTexture(texture: String, m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        let (metallic, roughness) = r#metallicRoughness |> Option.map(mr -> (mr#metallic, mr#roughness)) |> Option.getWithDefault((1.0, 1.0));
        withMetallicRoughnessOf({ metallic = metallic, roughness = roughness, texture = Some(texture) }, r)

    /// metallic と roughness を外す（glb の材質を今までのマットな絵に戻す時）。
    pub def withoutMetallicRoughness(m: Material3d): Material3d =
        let MaterialData.MaterialData(r) = m;
        MaterialData.MaterialData({ metallicRoughness = None, metallicRoughnessShade = None, params = withoutPbrParams(r#params),
                                    shaderHash = shaderHashOf(r#spec, r#emission, None) | r })

    /// 付いている metallic と roughness（無ければ None）。
    pub def metallicRoughnessOf(m: Material3d): Option[MetallicRoughness] = materialFieldsOf(m)#metallicRoughness

    def withMetallicRoughnessOf(mr: MetallicRoughness, r: MaterialFields): Material3d =
        let shade = metallicRoughnessShadeOf(mr#texture);
        MaterialData.MaterialData({ metallicRoughness = Some(mr), metallicRoughnessShade = Some(shade), params = withPbrParams(Some(mr), r#params),
                                    shaderHash = shaderHashOf(r#spec, r#emission, Some(shade)) | r })

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
    // WhyNot: List.sortBy に距離だけを渡さない — 安定ソートではないので、同じ距離の物の重なり方がコマごと・描き手ごとに入れ替わりうる。
    pub def blendOrderOf(eye: Vec3.Vec3, fieldsOf: a -> InstanceFields, xs: List[a]): List[a] =
        List.zipWithIndex(xs)
            |> List.map(entry -> {
                let (index, x) = entry;
                ((0.0 - Vec3.distanceSquared(drawCenterOf(fieldsOf(x)), eye), index), x)
            })
            |> List.sortBy(fst)
            |> List.map(snd)

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
            List.append(ShaderDoc.materialTexReads(f#spec, f#emission, f#metallicRoughnessShade) |> List.map(fst), f#normalMap |> Option.toList |> List.map(n -> n#texture))
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
    /// textures = 材質が "tex3d:" の名前（Texture3d.name）で読む絵・
    /// sky = 何も描かれない画素に描く空（gradientSky。Some なら environment の background は使わない）・
    /// environmentMap = metallic と roughness を持つ材質の映り込みが読む周りの景色（environmentMap。None なら空のグラデーションを映す）。
    pub type alias Scene3dCmd = { size = Vec2.Vec2, camera = Camera3d.Camera3d, instances = List[Instance3d], billboards = List[Billboard3d],
                                  pointLights = List[PointLight], spotLights = List[SpotLight], environment = Environment3d,
                                  resolution = Resolution, output = Output, zIndex = Int32, time = Float64,
                                  textures = List[Texture3d.Texture3d], sky = Option[Sky3d], environmentMap = Option[EnvironmentMap] }

    /// 空の場面（環境光は白・光なし・かすみなし・地の色なし・Native・色を書き出す・zIndex 0・時刻 0・絵なし・空なし）。
    /// time = 材質の ShaderDoc の時刻（秒）（ゲームの遊びの時計を渡すと、ポーズやヒットストップで材質の動きも止まる）。
    /// Scene3dCmd は開いたレコードなので `{ instances = … | s }` で足す。
    // WhyNot: 環境光を黒にしない — 光を置く前の場面が真っ黒になり、形を置いたのに何も出ないように見える。
    pub def scene(camera: Camera3d.Camera3d, size: Vec2.Vec2): Scene3dCmd =
        { size = size, camera = camera, instances = Nil, billboards = Nil, pointLights = Nil, spotLights = Nil,
          environment = { ambient = Color.rgb(1.0, 1.0, 1.0), hemisphere = 0.0, toonSteps = 0, fog = None, background = None },
          resolution = Resolution.Native, output = Output.Color, zIndex = 0, time = 0.0, textures = Nil, sky = None, environmentMap = None }

    // ── 環境マップ ──

    /// 環境マップの箱。室内の壁の位置（world）。min・max = 箱の対角の 2 点・center = 絵を撮った点（景色の向きの中心）。
    pub type alias EnvironmentBox = { min = Vec3.Vec3, max = Vec3.Vec3, center = Vec3.Vec3 }

    /// 環境マップの中身。texture = 場面の textures の絵の名前（Texture3d.name）・intensity = 線形の量に戻した後に掛ける倍率・
    /// box = 室内の壁の補正（None なら無限に遠い景色）・asBackground = 空の代わりに背景へも描くか。
    pub type alias EnvironmentMapFields = { texture = String, intensity = Float64, box = Option[EnvironmentBox], asBackground = Bool }

    enum EnvironmentMapData { case EnvironmentMapData(EnvironmentMapFields) }

    /// 周りの景色のパノラマの絵（閉じた型 — 欄を後から足しても、ゲームの書いた値が壊れない）。environmentMap から作り、with… で足す。
    /// Unity の Skybox（Panoramic）と Reflection Probe の Box Projection・Godot の PanoramaSkyMaterial と ReflectionProbe の box_projection に当たる。
    pub type alias EnvironmentMap = EnvironmentMapData

    /// 正距円筒（横 2：縦 1）のパノラマの絵 texture を景色にする。絵は Scene3dCmd の textures にも載せる（"tex3d:" の名前）。
    /// 色は sRGB の絵として読み、強さ 1・箱なし・背景には描かない。向きと絵の座標は LightModel3d.environmentUvOf。
    /// 映るのは metallic と roughness を持つ材質の映り込みだけで、拡散の光（ambient と hemisphere）は変わらない。
    pub def environmentMap(texture: Texture3d.Texture3d): EnvironmentMap =
        EnvironmentMapData.EnvironmentMapData({ texture = Texture3d.name(texture), intensity = 1.0, box = None, asBackground = false })

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

    /// 画素の向きを組む材料（場面のカメラから 1 回だけ作る）。forward = 見ている向き・right = 画面の右の向き × tan(fovY / 2) × 縦横の比・
    /// up = 画面の上の向き × tan(fovY / 2)。NDC の点 (x, y) の向きは skyDirectionOf（Camera3d.screenPointToRay と同じ式）。
    pub type alias SkyBasis = { forward = Vec3.Vec3, right = Vec3.Vec3, up = Vec3.Vec3 }

    /// 場面 scene のカメラと縦横の比（aspectOf）で、空の画素の向きを組む材料を作る。GL と CPU が同じ物を使う。
    pub def skyBasisOf(scene: Scene3dCmd): SkyBasis =
        let c = scene#camera;
        let half = c#fovY / 2.0;
        let tanHalf = Num.sin(half) / Num.cos(half);
        { forward = Camera3d.forward(c), right = Vec3.mul(Camera3d.right(c), tanHalf * aspectOf(scene)), up = Vec3.mul(Camera3d.up(c), tanHalf) }

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

    /// スポットライトから見たカメラ（影の地図を描く目）。位置から target を向き、fovY の角で見る。near は 1・far は range。
    /// target が位置と同じ所なら真下を向く。
    pub def shadowCamera(spot: SpotLight): Camera3d.Camera3d =
        let d = Vec3.sub(spot#target, spot#position);
        let len = Vec3.length(d);
        let dir = if (len < 0.000001) { x = 0.0, y = -1.0, z = 0.0 } else Vec3.mul(d, 1.0 / len);
        let flat = Num.sqrt(dir#x * dir#x + dir#z * dir#z);
        { eye = spot#position, yaw = Num.atan2(dir#x, dir#z), pitch = Num.atan2(0.0 - dir#y, flat),
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

    /// pickLights が上限を超えて落とす光の数（points = 点光源・spots = スポット）。落とす物が無ければ 0。
    pub def droppedLightsOf(cmd: Scene3dCmd): { points = Int32, spots = Int32 } =
        { points = Int32.max(0, List.length(cmd#pointLights) - maxPointLights()),
          spots = Int32.max(0, List.length(cmd#spotLights) - maxSpotLights()) }

    /// 1 コマに描く 3D の場面の列で pickLights が落とす光の数の合計（points = 点光源・spots = スポット）。
    /// GL の描き手が F3 の診断（FrameDiagnostics の droppedPointLights・droppedSpotLights）に足す数と、CPU の描き出しが落とす数に同じ。
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
            "scene3d: ${kind}が ${Int32.toString(given)} 本ある — 上限 ${Int32.toString(limit)} 本を目に近い順に選び、残りは描かない（Scene3d.pickLights）";
        (if (d#points > 0) ("@lights:point", line("点光源", List.length(cmd#pointLights), maxPointLights())) :: Nil else Nil)
            ::: (if (d#spots > 0) ("@lights:spot", line("スポットライト", List.length(cmd#spotLights), maxSpotLights())) :: Nil else Nil)

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

    /// 描き手へ渡す、先に GPU へ上げる物の宣言（App.withPreload3d）。key = 中身を決める全入力をまとめた字・
    /// instances・textures = 上げる物と、その材質が "tex3d:" の名前で読む絵の作り方（key が変わった時だけ呼ばれる）。
    pub type alias PreloadCmd = { key = DrawCmd.StaticKey, instances = Unit -> List[Instance3d], textures = Unit -> List[Texture3d.Texture3d] }
}
