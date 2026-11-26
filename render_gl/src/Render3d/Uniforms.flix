// Render3d.Uniforms — 3D の描き手の uniform の handle の表（GLSL の宣言の字・GL の location を引く名前・WGSL の読む字を 1 か所に）。
// GL の location は、プログラムを組んだ時に、そのプログラムの GLSL が宣言した uniform だけを引いて UniformLocations（handle → location）に持つ。
// 値を差す所は handle を渡す（名前の字を書かない）。宣言していない handle に差すと何も呼ばない。
pub mod Render3d.Uniforms {
    import fge.gl.GlContext
    use ShaderAst.Ty

    /// 3D の描き手の GLSL の uniform（材質の部品の uParamN・uTexN などは番号つき）。PointShadow(i) は点光源の影の配列の i 番目の location を引くだけの handle
    /// （木で読むのは配列の PointShadows）。
    pub enum R3dUniform with Eq, Order {
        case View, Proj, InstanceBase, InstanceTexture, JointTexture
        case Ambient, Hemisphere, ToonSteps, PointCount, PointPos, PointColor, PointRange
        case SpotCount, SpotPos, SpotDir, SpotColor, SpotRange, SpotCone, FogOn, FogColor, FogRange, Eye
        case ShadowOn, ShadowSpot, ShadowMatrix, ShadowMap, ShadowBias, ShadowPcf, ShadowStrength
        case SunDir, SunColor, SunShadowOn, SunMatrix, SunMap, SunBias, SunNormalShift, SunPcf, SunStrength, SunForward, SunFade
        case PointShadow(Int32)
        case PointShadows
        case PointShadowAtlas, PointShadowBias, PointShadowMap
        case InverseUnitsPerMeterSquared, Psx, PsxTarget, VertexSnap, Sh, SkyContribution
        case Zenith, Horizon, Ground, Curve, EnvOn, EnvBoxOn, EnvBoxMin, EnvBoxMax, EnvBoxCenter, EnvMap, EnvLevels, EnvIntensity, EnvSrgb
        case DepthRange, DepthOut, Cutout, Time
        case Param(Int32)
        case Tex(Int32)
        case TexFlip(Int32)
        case TexLevels(Int32)
        case NormalMap, NormalStrength, NormalFlip, NormalLevels
        case Lightmap, LightmapLevels, LightmapUvRect, LightmapSrgb, LightmapIntensity
        case Right, Up, RightPerBillboard, Facing, Image, Viewport, Forward
        case AoMask, AoValues
    }

    /// uniform の表の 1 行: name = GLSL の名前（location を引く字）・glsl = GLSL の宣言の型の字・length = 配列の長さ（GLSL の宣言の [N]）。
    /// 木で読む時の型と WGSL で読む字は treeRowOf。
    // WhyNot: 木で読む時の欄（ShaderAst.Ty・ShaderAst.Access）をこの行に持たない — location を引くだけのブラウザの描き手まで、木の型の値を組む物を wasm に持つ。
    pub type alias UniformRow = { name = String, glsl = String, length = Option[Int32] }

    def row(name: String, glsl: String): UniformRow = { name = name, glsl = glsl, length = None }

    def arrayRow(name: String, glsl: String, length: Int32): UniformRow = { name = name, glsl = glsl, length = Some(length) }

    def at(base: String): Option[ShaderAst.Access] = Some({ base = base, swizzle = "" })

    def scene(name: String): Option[ShaderAst.Access] = at("r3d." + name)
    def light(name: String): Option[ShaderAst.Access] = at("r3dLight." + name)
    def draw(name: String): Option[ShaderAst.Access] = at("r3dDraw." + name)
    def camera(name: String, swizzle: String): Option[ShaderAst.Access] = Some({ base = "r3dCamera." + name, swizzle = swizzle })

    /// handle u の行。
    pub def rowOf(u: R3dUniform): UniformRow =
        let p = Scene3d.maxPointLights();
        let s = Scene3d.maxSpotLights();
        match u {
            case R3dUniform.View            => row("uView", "mat4")
            case R3dUniform.Proj            => row("uProj", "mat4")
            case R3dUniform.InstanceBase    => row("uInstanceBase", "int")
            case R3dUniform.InstanceTexture => row("uInstanceTexture", "sampler2D")
            case R3dUniform.JointTexture    => row("uJointTexture", "sampler2D")
            case R3dUniform.Ambient         => row("uAmbient", "vec3")
            case R3dUniform.Hemisphere      => row("uHemisphere", "float")
            case R3dUniform.ToonSteps       => row("uToonSteps", "int")
            case R3dUniform.PointCount      => row("uPointCount", "int")
            case R3dUniform.PointPos        => arrayRow("uPointPos", "vec3", p)
            case R3dUniform.PointColor      => arrayRow("uPointColor", "vec3", p)
            case R3dUniform.PointRange      => arrayRow("uPointRange", "float", p)
            case R3dUniform.SpotCount       => row("uSpotCount", "int")
            case R3dUniform.SpotPos         => arrayRow("uSpotPos", "vec3", s)
            case R3dUniform.SpotDir         => arrayRow("uSpotDir", "vec3", s)
            case R3dUniform.SpotColor       => arrayRow("uSpotColor", "vec3", s)
            case R3dUniform.SpotRange       => arrayRow("uSpotRange", "float", s)
            case R3dUniform.SpotCone        => arrayRow("uSpotCone", "vec2", s)
            case R3dUniform.FogOn           => row("uFogOn", "int")
            case R3dUniform.FogColor        => row("uFogColor", "vec3")
            case R3dUniform.FogRange        => row("uFogRange", "vec2")
            case R3dUniform.Eye             => row("uEye", "vec3")
            case R3dUniform.ShadowOn        => row("uShadowOn", "int")
            case R3dUniform.ShadowSpot      => row("uShadowSpot", "int")
            case R3dUniform.ShadowMatrix    => row("uShadowMatrix", "mat4")
            case R3dUniform.ShadowMap       => row("uShadowMap", "sampler2D")
            case R3dUniform.ShadowBias      => row("uShadowBias", "float")
            case R3dUniform.ShadowPcf       => row("uShadowPcf", "int")
            case R3dUniform.ShadowStrength  => row("uShadowStrength", "float")
            case R3dUniform.SunDir          => row("uSunDir", "vec3")
            case R3dUniform.SunColor        => row("uSunColor", "vec3")
            case R3dUniform.SunShadowOn     => row("uSunShadowOn", "int")
            case R3dUniform.SunMatrix       => row("uSunMatrix", "mat4")
            case R3dUniform.SunMap          => row("uSunMap", "sampler2D")
            case R3dUniform.SunBias         => row("uSunBias", "float")
            case R3dUniform.SunNormalShift  => row("uSunNormalShift", "float")
            case R3dUniform.SunPcf          => row("uSunPcf", "int")
            case R3dUniform.SunStrength     => row("uSunStrength", "float")
            case R3dUniform.SunForward      => row("uSunForward", "vec3")
            case R3dUniform.SunFade         => row("uSunFade", "vec2")
            case R3dUniform.PointShadow(i)  => row("uPointShadow[${i}]", "vec4")
            case R3dUniform.PointShadows    => arrayRow("uPointShadow", "vec4", p)
            case R3dUniform.PointShadowAtlas => row("uPointShadowAtlas", "vec4")
            case R3dUniform.PointShadowBias => row("uPointShadowBias", "vec2")
            case R3dUniform.PointShadowMap  => row("uPointShadowMap", "sampler2D")
            case R3dUniform.InverseUnitsPerMeterSquared => row("uInverseUnitsPerMeterSquared", "float")
            case R3dUniform.Psx             => row("uPsx", "vec4")
            case R3dUniform.PsxTarget       => row("uPsxTarget", "vec4")
            case R3dUniform.VertexSnap      => row("uVertexSnap", "float")
            case R3dUniform.Sh              => arrayRow("uSh", "vec3", 9)
            case R3dUniform.SkyContribution => row("uSkyContribution", "float")
            case R3dUniform.Zenith          => row("uZenith", "vec3")
            case R3dUniform.Horizon         => row("uHorizon", "vec3")
            case R3dUniform.Ground          => row("uGround", "vec3")
            case R3dUniform.Curve           => row("uCurve", "float")
            case R3dUniform.EnvOn           => row("uEnvOn", "int")
            case R3dUniform.EnvBoxOn        => row("uEnvBoxOn", "int")
            case R3dUniform.EnvBoxMin       => row("uEnvBoxMin", "vec3")
            case R3dUniform.EnvBoxMax       => row("uEnvBoxMax", "vec3")
            case R3dUniform.EnvBoxCenter    => row("uEnvBoxCenter", "vec3")
            case R3dUniform.EnvMap          => row("uEnvMap", "sampler2D")
            case R3dUniform.EnvLevels       => row("uEnvLevels", "float")
            case R3dUniform.EnvIntensity    => row("uEnvIntensity", "float")
            case R3dUniform.EnvSrgb         => row("uEnvSrgb", "int")
            case R3dUniform.DepthRange      => row("uDepthRange", "vec2")
            case R3dUniform.DepthOut        => row("uDepthOut", "int")
            case R3dUniform.Cutout          => row("uCutout", "int")
            case R3dUniform.Time            => row("uTime", "float")
            case R3dUniform.AoMask          => row("uAoMask", "sampler2D")
            case R3dUniform.AoValues        => row("uAo", "vec4")
            case R3dUniform.Param(i)        => row("uParam${i}", "float")
            case R3dUniform.Tex(i)          => row("uTex${i}", "sampler2D")
            case R3dUniform.TexFlip(i)      => row("uTexFlip${i}", "float")
            case R3dUniform.TexLevels(i)    => row("uTexLevels${i}", "float")
            case R3dUniform.NormalMap       => row("uNormalMap", "sampler2D")
            case R3dUniform.NormalStrength  => row("uNormalStrength", "float")
            case R3dUniform.NormalFlip      => row("uNormalFlip", "float")
            case R3dUniform.NormalLevels    => row("uNormalLevels", "float")
            case R3dUniform.Lightmap        => row("uLightmap", "sampler2D")
            case R3dUniform.LightmapLevels  => row("uLightmapLevels", "float")
            case R3dUniform.LightmapUvRect  => row("uLightmapUvRect", "vec4")
            case R3dUniform.LightmapSrgb    => row("uLightmapSrgb", "int")
            case R3dUniform.LightmapIntensity => row("uLightmapIntensity", "float")
            case R3dUniform.Right           => row("uRight", "vec3")
            case R3dUniform.Up              => row("uUp", "vec3")
            case R3dUniform.RightPerBillboard => row("uRightPerBillboard", "int")
            case R3dUniform.Facing          => row("uFacing", "vec3")
            case R3dUniform.Image           => row("uImage", "sampler2D")
            case R3dUniform.Viewport        => row("uViewport", "vec4")
            case R3dUniform.Forward         => row("uForward", "vec3")
        }

    /// 番号の無い handle の全部（GLSL の名前から handle を引く表を作る）。
    def plainHandles(): List[R3dUniform] =
        R3dUniform.View :: R3dUniform.Proj :: R3dUniform.InstanceBase :: R3dUniform.InstanceTexture :: R3dUniform.JointTexture ::
        R3dUniform.Ambient :: R3dUniform.Hemisphere :: R3dUniform.ToonSteps :: R3dUniform.PointCount :: R3dUniform.PointPos :: R3dUniform.PointColor ::
        R3dUniform.PointRange :: R3dUniform.SpotCount :: R3dUniform.SpotPos :: R3dUniform.SpotDir :: R3dUniform.SpotColor :: R3dUniform.SpotRange ::
        R3dUniform.SpotCone :: R3dUniform.FogOn :: R3dUniform.FogColor :: R3dUniform.FogRange :: R3dUniform.Eye ::
        R3dUniform.ShadowOn :: R3dUniform.ShadowSpot :: R3dUniform.ShadowMatrix :: R3dUniform.ShadowMap :: R3dUniform.ShadowBias :: R3dUniform.ShadowPcf ::
        R3dUniform.ShadowStrength :: R3dUniform.SunDir :: R3dUniform.SunColor :: R3dUniform.SunShadowOn :: R3dUniform.SunMatrix :: R3dUniform.SunMap ::
        R3dUniform.SunBias :: R3dUniform.SunNormalShift :: R3dUniform.SunPcf :: R3dUniform.SunStrength :: R3dUniform.SunForward :: R3dUniform.SunFade ::
        R3dUniform.PointShadows :: R3dUniform.PointShadowAtlas :: R3dUniform.PointShadowBias :: R3dUniform.PointShadowMap ::
        R3dUniform.InverseUnitsPerMeterSquared :: R3dUniform.Psx :: R3dUniform.PsxTarget :: R3dUniform.VertexSnap :: R3dUniform.Sh :: R3dUniform.SkyContribution ::
        R3dUniform.Zenith :: R3dUniform.Horizon :: R3dUniform.Ground :: R3dUniform.Curve :: R3dUniform.EnvOn :: R3dUniform.EnvBoxOn :: R3dUniform.EnvBoxMin ::
        R3dUniform.EnvBoxMax :: R3dUniform.EnvBoxCenter :: R3dUniform.EnvMap :: R3dUniform.EnvLevels :: R3dUniform.EnvIntensity :: R3dUniform.EnvSrgb ::
        R3dUniform.DepthRange :: R3dUniform.DepthOut :: R3dUniform.Cutout :: R3dUniform.Time ::
        R3dUniform.NormalMap :: R3dUniform.NormalStrength :: R3dUniform.NormalFlip :: R3dUniform.NormalLevels ::
        R3dUniform.Lightmap :: R3dUniform.LightmapLevels :: R3dUniform.LightmapUvRect :: R3dUniform.LightmapSrgb :: R3dUniform.LightmapIntensity ::
        R3dUniform.Right :: R3dUniform.Up :: R3dUniform.RightPerBillboard :: R3dUniform.Facing :: R3dUniform.Image :: R3dUniform.Viewport :: R3dUniform.Forward ::
        R3dUniform.AoMask :: R3dUniform.AoValues :: Nil

    /// GLSL の名前から番号の無い handle を引く表（handleIn に渡す）。
    pub type alias NameTable = Map[String, R3dUniform]

    /// 番号の無い handle の表（1 回作って handleIn に渡す）。
    pub def nameTable(): NameTable = plainHandles() |> List.map(u -> (rowOf(u)#name, u)) |> List.toMap

    /// 番号つきの名前の頭と handle（長い頭が先: uTexLevels3 を uTex で読まない）。
    def numberedPrefixes(): List[(String, Int32 -> R3dUniform)] =
        ("uTexLevels", R3dUniform.TexLevels) :: ("uTexFlip", R3dUniform.TexFlip) :: ("uParam", R3dUniform.Param) :: ("uTex", R3dUniform.Tex) :: Nil

    /// 字 digits が 1 字以上の数字だけか。
    def isNumber(digits: String): Bool = not String.isEmpty(digits) and List.forAll(Char.isDigit, String.toList(digits))

    /// GLSL の宣言の名前 name（配列の [N] を除く）の handle（番号つきは頭 + 数字で読む。表に無ければ None）。
    pub def handleIn(table: NameTable, name: String): Option[R3dUniform] = match Map.get(name, table) {
        case Some(u) => Some(u)
        case None    => numberedPrefixes() |> List.findMap(pm -> {
            let (prefix, make) = pm;
            let digits = String.dropLeft(String.length(prefix), name);
            if (String.startsWith(prefix = prefix, name) and isNumber(digits)) Int32.fromString(digits) |> Option.map(make) else None
        })
    }

    /// GLSL の字 source が宣言した uniform の名前（`uniform <型> <名前>` で始まる行の名前。配列の [N] は除く）。
    pub def declaredNames(source: String): List[String] =
        TextSplit.lines(source) |> List.filterMap(line ->
            if (not String.startsWith(prefix = "uniform ", line)) None
            else match TextSplit.split(" ", line) {
                case _ :: _ :: name :: _ => Some(String.takeWhile(ch -> ch != '[' and ch != ';', name))
                case _                   => None
            })

    /// GLSL の字 sources が宣言した uniform の handle と、表に無い名前。
    pub def handlesOf(sources: List[String]): (List[R3dUniform], List[String]) =
        let table = nameTable();
        let found = sources |> List.flatMap(declaredNames) |> List.distinct |> List.map(n -> (n, handleIn(table, n)));
        (found |> List.filterMap(snd), found |> List.filterMap(nf -> if (Option.isEmpty(snd(nf))) Some(fst(nf)) else None))

    /// handlesOf の、表に無い名前があれば止める版。
    def handlesOfOrBug(sources: List[String]): List[R3dUniform] = match handlesOf(sources) {
        case (known, Nil) => known
        case (_, unknown) => bug!("Render3d.Uniforms: GLSL の uniform ${unknown} が handle の表に無い")
    }

    /// handle u の location を引く handle（点光源の影の配列は要素ごと）。
    def locationHandles(u: R3dUniform): List[R3dUniform] = match u {
        case R3dUniform.PointShadows => List.range(0, Scene3d.maxPointLights()) |> List.map(R3dUniform.PointShadow)
        case _                       => u :: Nil
    }

    /// プログラムの uniform の location（handle → location。プログラムが宣言していない handle は入らない）。
    pub type alias UniformLocations = Map[R3dUniform, Int32]

    /// 宣言の無いプログラムの location（何も差さない）。
    pub def noLocations(): UniformLocations = Map.empty()

    /// プログラム program の、GLSL の字 sources が宣言した uniform の location（表に無い名前があれば止める）。
    // WhyNot: 表の全部の handle の location を引かない — プログラムを組むたびに GL への呼び出しが 100 回ほど増え、宣言していない名前の -1 を持つだけになる。
    pub def locationsOf(gl: GlContext, program: Int32, sources: List[String]): UniformLocations \ IO =
        handlesOfOrBug(sources) |> List.flatMap(locationHandles) |> List.foldLeft((acc, u) -> {
            let at = gl.getUniformLocation(program, rowOf(u)#name);
            if (at < 0) acc else Map.insert(u, at, acc)
        }, Map.empty())

    /// プログラムが u を宣言しているか。
    pub def has(u: R3dUniform, locs: UniformLocations): Bool = Map.memberOf(u, locs)

    /// u を宣言していれば f(location) を呼ぶ。
    def withLocation(u: R3dUniform, locs: UniformLocations, f: Int32 -> Unit \ IO): Unit \ IO = match Map.get(u, locs) {
        case Some(at) => f(at)
        case None     => ()
    }

    pub def put1i(gl: GlContext, locs: UniformLocations, u: R3dUniform, v: Int32): Unit \ IO = withLocation(u, locs, at -> gl.uniform1i(at, v))
    pub def put1f(gl: GlContext, locs: UniformLocations, u: R3dUniform, v: Float32): Unit \ IO = withLocation(u, locs, at -> gl.uniform1f(at, v))
    pub def put2f(gl: GlContext, locs: UniformLocations, u: R3dUniform, x: Float32, y: Float32): Unit \ IO = withLocation(u, locs, at -> gl.uniform2f(at, x, y))
    pub def put3f(gl: GlContext, locs: UniformLocations, u: R3dUniform, x: Float32, y: Float32, z: Float32): Unit \ IO =
        withLocation(u, locs, at -> gl.uniform3f(at, x, y, z))
    pub def put4f(gl: GlContext, locs: UniformLocations, u: R3dUniform, x: Float32, y: Float32, z: Float32, w: Float32): Unit \ IO =
        withLocation(u, locs, at -> gl.uniform4f(at, x, y, z, w))
    pub def put1fv(gl: GlContext, locs: UniformLocations, u: R3dUniform, v: Array[Float32, Static]): Unit \ IO = withLocation(u, locs, at -> gl.uniform1fv(at, v))
    pub def put2fv(gl: GlContext, locs: UniformLocations, u: R3dUniform, v: Array[Float32, Static]): Unit \ IO = withLocation(u, locs, at -> gl.uniform2fv(at, v))
    pub def put3fv(gl: GlContext, locs: UniformLocations, u: R3dUniform, v: Array[Float32, Static]): Unit \ IO = withLocation(u, locs, at -> gl.uniform3fv(at, v))
    pub def putMatrix4(gl: GlContext, locs: UniformLocations, u: R3dUniform, m: Array[Float32, Static]): Unit \ IO =
        withLocation(u, locs, at -> gl.uniformMatrix4fv(at, false, m))

    // ── 木で読む ──

    /// handle u を木で読む時の型と、WGSL で読む字（None は WGSL に無い欄）。
    def treeRowOf(u: R3dUniform): (Ty, Option[ShaderAst.Access]) =
        match u {
            case R3dUniform.View            => (Ty.Mat4, camera("uView", ""))
            case R3dUniform.Proj            => (Ty.Mat4, camera("uProj", ""))
            case R3dUniform.InstanceBase    => (Ty.I32, None)
            case R3dUniform.InstanceTexture => (Ty.Texture2d, None)
            case R3dUniform.JointTexture    => (Ty.Texture2d, None)
            case R3dUniform.Ambient         => (Ty.Vec3, scene("uAmbient"))
            case R3dUniform.Hemisphere      => (Ty.F32, scene("uHemisphere"))
            case R3dUniform.ToonSteps       => (Ty.I32, scene("uToonSteps"))
            case R3dUniform.PointCount      => (Ty.I32, scene("uPointCount"))
            case R3dUniform.PointPos        => (Ty.Vec3, scene("uPointPos"))
            case R3dUniform.PointColor      => (Ty.Vec3, scene("uPointColor"))
            case R3dUniform.PointRange      => (Ty.F32, scene("uPointRange"))
            case R3dUniform.SpotCount       => (Ty.I32, scene("uSpotCount"))
            case R3dUniform.SpotPos         => (Ty.Vec3, scene("uSpotPos"))
            case R3dUniform.SpotDir         => (Ty.Vec3, scene("uSpotDir"))
            case R3dUniform.SpotColor       => (Ty.Vec3, scene("uSpotColor"))
            case R3dUniform.SpotRange       => (Ty.F32, scene("uSpotRange"))
            case R3dUniform.SpotCone        => (Ty.Vec2, scene("uSpotCone"))
            case R3dUniform.FogOn           => (Ty.I32, scene("uFogOn"))
            case R3dUniform.FogColor        => (Ty.Vec3, scene("uFogColor"))
            case R3dUniform.FogRange        => (Ty.Vec2, scene("uFogRange"))
            case R3dUniform.Eye             => (Ty.Vec3, scene("uEye"))
            case R3dUniform.ShadowOn        => (Ty.I32, scene("uShadowOn"))
            case R3dUniform.ShadowSpot      => (Ty.I32, scene("uShadowSpot"))
            case R3dUniform.ShadowMatrix    => (Ty.Mat4, scene("uShadowMatrix"))
            case R3dUniform.ShadowMap       => (Ty.DepthTexture2d, at("uShadowMap"))
            case R3dUniform.ShadowBias      => (Ty.F32, scene("uShadowBias"))
            case R3dUniform.ShadowPcf       => (Ty.I32, scene("uShadowPcf"))
            case R3dUniform.ShadowStrength  => (Ty.F32, scene("uShadowStrength"))
            case R3dUniform.SunDir          => (Ty.Vec3, scene("uSunDir"))
            case R3dUniform.SunColor        => (Ty.Vec3, scene("uSunColor"))
            case R3dUniform.SunShadowOn     => (Ty.I32, scene("uSunShadowOn"))
            case R3dUniform.SunMatrix       => (Ty.Mat4, scene("uSunMatrix"))
            case R3dUniform.SunMap          => (Ty.DepthTexture2d, at("uSunMap"))
            case R3dUniform.SunBias         => (Ty.F32, scene("uSunBias"))
            case R3dUniform.SunNormalShift  => (Ty.F32, scene("uSunNormalShift"))
            case R3dUniform.SunPcf          => (Ty.I32, scene("uSunPcf"))
            case R3dUniform.SunStrength     => (Ty.F32, scene("uSunStrength"))
            case R3dUniform.SunForward      => (Ty.Vec3, scene("uSunForward"))
            case R3dUniform.SunFade         => (Ty.Vec2, scene("uSunFade"))
            case R3dUniform.PointShadow(_)  => (Ty.Vec4, light("uPointShadow"))
            case R3dUniform.PointShadows    => (Ty.Vec4, light("uPointShadow"))
            case R3dUniform.PointShadowAtlas => (Ty.Vec4, light("uPointShadowAtlas"))
            case R3dUniform.PointShadowBias => (Ty.Vec2, light("uPointShadowBias"))
            case R3dUniform.PointShadowMap  => (Ty.DepthTexture2d, at("uPointShadowMap"))
            case R3dUniform.InverseUnitsPerMeterSquared => (Ty.F32, light("uInverseUnitsPerMeterSquared"))
            case R3dUniform.Psx             => (Ty.Vec4, light("uPsx"))
            case R3dUniform.PsxTarget       => (Ty.Vec4, None)
            case R3dUniform.VertexSnap      => (Ty.F32, camera("uSnap", "z"))
            case R3dUniform.Sh              => (Ty.Vec3, light("uSh"))
            case R3dUniform.SkyContribution => (Ty.F32, light("uSkyContribution"))
            case R3dUniform.Zenith          => (Ty.Vec3, scene("uZenith"))
            case R3dUniform.Horizon         => (Ty.Vec3, scene("uHorizon"))
            case R3dUniform.Ground          => (Ty.Vec3, scene("uGround"))
            case R3dUniform.Curve           => (Ty.F32, scene("uCurve"))
            case R3dUniform.EnvOn           => (Ty.I32, scene("uEnvOn"))
            case R3dUniform.EnvBoxOn        => (Ty.I32, scene("uEnvBoxOn"))
            case R3dUniform.EnvBoxMin       => (Ty.Vec3, scene("uEnvBoxMin"))
            case R3dUniform.EnvBoxMax       => (Ty.Vec3, scene("uEnvBoxMax"))
            case R3dUniform.EnvBoxCenter    => (Ty.Vec3, scene("uEnvBoxCenter"))
            case R3dUniform.EnvMap          => (Ty.Texture2d, at("uEnvMap"))
            case R3dUniform.EnvLevels       => (Ty.F32, scene("uEnvLevels"))
            case R3dUniform.EnvIntensity    => (Ty.F32, scene("uEnvIntensity"))
            case R3dUniform.EnvSrgb         => (Ty.I32, scene("uEnvSrgb"))
            case R3dUniform.DepthRange      => (Ty.Vec2, scene("uDepthRange"))
            case R3dUniform.DepthOut        => (Ty.I32, scene("uDepthOut"))
            case R3dUniform.Cutout          => (Ty.Bool, draw("uCutout"))
            case R3dUniform.Time            => (Ty.F32, None)
            case R3dUniform.AoMask          => (Ty.Texture2d, at("uAoMask"))
            case R3dUniform.AoValues        => (Ty.Vec4, at("r3dAo.uValues"))
            case R3dUniform.Param(_)        => (Ty.F32, None)
            case R3dUniform.Tex(_)          => (Ty.Texture2d, None)
            case R3dUniform.TexFlip(_)      => (Ty.F32, None)
            case R3dUniform.TexLevels(_)    => (Ty.F32, None)
            case R3dUniform.NormalMap       => (Ty.Texture2d, at("uNormalMap"))
            case R3dUniform.NormalStrength  => (Ty.F32, draw("uNormalStrength"))
            case R3dUniform.NormalFlip      => (Ty.F32, None)
            case R3dUniform.NormalLevels    => (Ty.F32, draw("uNormalLevels"))
            case R3dUniform.Lightmap        => (Ty.Texture2d, at("uLightmap"))
            case R3dUniform.LightmapLevels  => (Ty.F32, draw("uLightmapLevels"))
            case R3dUniform.LightmapUvRect  => (Ty.Vec4, draw("uLightmapUvRect"))
            case R3dUniform.LightmapSrgb    => (Ty.I32, draw("uLightmapSrgb"))
            case R3dUniform.LightmapIntensity => (Ty.F32, draw("uLightmapIntensity"))
            case R3dUniform.Right           => (Ty.Vec3, camera("uRight", "xyz"))
            case R3dUniform.Up              => (Ty.Vec3, camera("uUp", "xyz"))
            case R3dUniform.RightPerBillboard => (Ty.I32, None)
            case R3dUniform.Facing          => (Ty.Vec3, camera("uFacing", "xyz"))
            case R3dUniform.Image           => (Ty.Texture2d, at("uImage"))
            case R3dUniform.Viewport        => (Ty.Vec4, None)
            case R3dUniform.Forward         => (Ty.Vec3, None)
        }


    /// handle u を木で読む uniform（GLSL の名前・型・言語ごとの読む字・GLSL の宣言の型と長さ）。PointShadow(i) は読めない（止める）。
    pub def refOf(u: R3dUniform): ShaderAst.UniformRef = match u {
        case R3dUniform.PointShadow(i) => notReadableOrBug(i)
        case _ =>
            let r = rowOf(u);
            let (ty, wgsl) = treeRowOf(u);
            { name = r#name, ty = ty, glsl = Some({ base = r#name, swizzle = "" }), wgsl = wgsl, glslType = r#glsl, length = r#length }
    }

    def notReadableOrBug(i: Int32): a = bug!("Render3d.Uniforms: PointShadow(${i}) は location を引くだけの handle（木では PointShadows を読む）")

    /// 番号の無い handle の全部を木で読む物（生成した字が読む uniform を探す候補）。
    pub def namedRefs(): List[ShaderAst.UniformRef] = plainHandles() |> List.map(refOf)

    /// handles の GLSL の宣言の行（並べた順。頂点シェーダーのように木で書いていない字が使う）。
    pub def glslDeclarations(handles: List[R3dUniform]): String = ShaderAst.Glsl.uniformDeclarations(handles |> List.map(refOf))
}
