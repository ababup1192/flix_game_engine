// Render3d.ShaderLibrary — 3D の描き手がシェーダーの字を引く所（Render3d.ShaderSourceProvider）と、ブラウザ版に前もって作る分の記録（web/shader-variants.json）。
// Unreal の ShaderLibrary（書き出しの時に作るシェーダーの束）と Unity の ShaderVariantCollection（遊んで使った変種の記録）に当たる。
// 記録するのは言語と描き手によらない論理の鍵（場面の変種と材質の形）。書き出しの道具は requiredKeysOf で両方の言語の要る字へ広げて表にする。
// 材質の frag は部品の所が空いた字（Render3dGlsl.materialFragmentTemplate）を作っておき、描き手が ShaderGen の字を withMaterialPart で入れる。
pub mod Render3d.ShaderLibrary {
    import java.nio.file.Files
    import java.nio.file.Path
    import java.nio.file.StandardCopyOption
    import java.nio.file.NoSuchFileException
    import java.io.IOException
    import java.math.{BigDecimal => JBigDecimal}
    use Render3d.{ShaderSourceKey, ShaderSourceProvider}
    use Render3d.ProgramKey.{ShaderVariant, ProgramKind, defaultShaderVariant, variantKeyOf, billboardVariantOf}
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JString, JNumber, JBool}

    // ── 材質の部品を入れる ──

    /// 材質の frag の字の、材質の部品の字を入れる所。
    pub def materialPartPlaceholder(): String = "/*@R3D_MATERIAL_PLACEHOLDER@*/"

    /// 材質の frag の字の、cutout の α の式を入れる所（名前なので、木の print は括弧を付けずに置く）。
    pub def cutoutAlphaPlaceholder(): String = "r3d_cutoutAlphaPlaceholder"

    /// 部品の所が空いた字 template に、材質の部品の字 partText と cutout の α の式 cutoutAlpha を入れる（字のまま置き換える）。
    /// cutout の α は名前・呼び出し・欄の読みの形（ShaderText.isAtomText）だけを受ける（木で直に print した字と 1 字も同じになる約束）。
    // WhyNot: atom でない cutout の α を括弧で包んで受けない — 木の print は置く位置ごとに括弧を付けるかを決めるので、1 つの決め方で包むと直に print した字とずれる。
    // WhyNot: 材質の部品を先に入れない — 部品の字の中まで cutout の α の置き換えが届く。
    pub def withMaterialPart(template: String, partText: String, cutoutAlpha: String): String =
        templateOrBug(template) |> String.replace(src = cutoutAlphaPlaceholder(), dst = atomOrBug(cutoutAlpha))
                                |> String.replace(src = materialPartPlaceholder(), dst = partText)

    def atomOrBug(cutoutAlpha: String): String =
        if (ShaderText.isAtomText(cutoutAlpha)) cutoutAlpha
        else bug!("Render3d.ShaderLibrary: cutout の α '${cutoutAlpha}' が名前・呼び出しの形でない（ShaderGen の約束が破れた）")

    def templateOrBug(template: String): String =
        if (String.contains(substr = materialPartPlaceholder(), template)) template
        else bug!("Render3d.ShaderLibrary: 材質の frag の字に部品を入れる所が無い")

    /// GLSL の材質の部品 m の字（uniform の宣言と関数）。
    pub def glslPartText(m: ShaderGen.MaterialGlsl): String = m#uniforms + m#functions

    /// WGSL の材質の部品 m の字（binding の宣言と関数）。
    pub def wgslPartText(m: ShaderGen.Wgsl.MaterialWgsl): String = m#declarations + m#functions

    // ── 引く ──

    /// 描き手が持つ API。provider = 字を引く・record = 使った論理の鍵を記録する（PC で記録の旗が立っている時だけ書く。ほかは何もしない）。
    pub type alias ShaderSources = { provider = ShaderSourceProvider, record = CollectionKeys -> Unit \ IO }

    /// 記録しない ShaderSources。
    pub def withoutRecording(provider: ShaderSourceProvider): ShaderSources = { provider = provider, record = _ -> () }

    /// 既定の一式（requiredKeysOf の「いつも」）の GLSL の字。無いのは同じ engine の版の表の約束が破れた所なので止める。
    pub def glslOrBug(s: ShaderSources, key: ShaderSourceKey): String = match s#provider#glsl(key) {
        case Some(text) => text
        case None       => bug!("Render3d.ShaderLibrary: GLSL の字 ${Render3d.ShaderSourceKey.toKeyString(key)} が無い")
    }

    /// glslOrBug の WGSL の版。
    pub def wgslOrBug(s: ShaderSources, key: ShaderSourceKey): String = match s#provider#wgsl(key) {

        case Some(text) => text
        case None       => bug!("Render3d.ShaderLibrary: WGSL の字 ${Render3d.ShaderSourceKey.toKeyString(key)} が無い")
    }

    /// 記録に依る鍵（既定でない変種・材質の形）の GLSL の字。無ければ 1 行知らせて None（呼ぶ側はその描き物を描かず、答えを控えて同じ鍵で 2 度引かない）。
    pub def optionalGlsl(s: ShaderSources, key: ShaderSourceKey): Option[String] = s#provider#glsl(key) |> noteIfMissing(key)

    /// optionalGlsl の WGSL の版。
    pub def optionalWgsl(s: ShaderSources, key: ShaderSourceKey): Option[String] = s#provider#wgsl(key) |> noteIfMissing(key)

    def noteIfMissing(key: ShaderSourceKey, found: Option[String]): Option[String] = match found {
        case Some(text) => Some(text)
        case None       =>
            Log.fellBackThen("shader", Render3d.ShaderSourceKey.toKeyString(key), "描かない",
                             "web/shader-variants.json に無い。PC で fge run してその場面を一度通してから書き出し直す", None)
    }

    /// 材質 m（cutout = 材質の cutout）を形 kind で描く GLSL の frag（無ければ None）。使った変種と材質の形を記録する。
    pub def materialGlsl(s: ShaderSources, kind: ProgramKind, cutout: Bool, m: ShaderGen.MaterialGlsl): Option[String] \ IO =
        let readsTextures = not List.isEmpty(m#texReads);
        s#record(shapeKeys(kind, cutout, readsTextures));
        optionalGlsl(s, ShaderSourceKey.MaterialFragmentTemplate(kind, readsTextures)) |> Option.map(t -> withMaterialPart(t, glslPartText(m), m#cutoutAlpha))

    /// materialGlsl の WGSL の版。
    pub def materialWgsl(s: ShaderSources, kind: ProgramKind, cutout: Bool, m: ShaderGen.Wgsl.MaterialWgsl): Option[String] \ IO =
        let readsTextures = not List.isEmpty(m#texReads);
        s#record(shapeKeys(kind, cutout, readsTextures));
        optionalWgsl(s, ShaderSourceKey.MaterialFragmentTemplate(kind, readsTextures)) |> Option.map(t -> withMaterialPart(t, wgslPartText(m), m#cutoutAlpha))

    /// 変種 v を使ったと記録する（頂点の色とビルボードのプログラムを組む所）。
    pub def recordVariant(s: ShaderSources, v: ShaderVariant): Unit \ IO = s#record(variantKeys(v))

    // ── 記録の鍵 ──

    /// 材質の形（記録の 1 行）。ProgramKind から変種と coverage を除き、材質の cutout と、材質が絵を読むか（readsTextures）を足した物。
    pub type alias MaterialShape = { skinned = Bool, uv = Bool, normalMap = Bool, lightmap = Bool, blend = Bool, doubleSided = Bool,
                                     cutout = Bool, metallicRoughness = Bool, readsTextures = Bool }

    /// 記録した鍵。variants = 変種の鍵の字（variantKeyOf）→ 変種・materialShapes = 形の字 → 形。
    pub type alias CollectionKeys = { variants = Map[String, ShaderVariant], materialShapes = Map[String, MaterialShape] }

    /// 何も無い記録。
    pub def emptyCollection(): CollectionKeys = { variants = Map.empty(), materialShapes = Map.empty() }

    /// a と b を合わせた記録。
    pub def unionCollection(a: CollectionKeys, b: CollectionKeys): CollectionKeys =
        { variants = Map.union(a#variants, b#variants), materialShapes = Map.union(a#materialShapes, b#materialShapes) }

    /// c が d の鍵を全部持つか。
    def coversCollection(c: CollectionKeys, d: CollectionKeys): Bool =
        Map.forAll((k, _) -> Map.memberOf(k, c#variants), d#variants) and Map.forAll((k, _) -> Map.memberOf(k, c#materialShapes), d#materialShapes)

    /// 変種 v だけの記録。
    pub def variantKeys(v: ShaderVariant): CollectionKeys = { variants = Map#{ variantKeyOf(v) => v }, materialShapes = Map.empty() }

    /// 形 kind（材質の cutout と、絵を読むか readsTextures）の材質を使った記録（変種と形）。
    pub def shapeKeys(kind: ProgramKind, cutout: Bool, readsTextures: Bool): CollectionKeys =
        let shape = { skinned = kind#skinned, uv = kind#uv, normalMap = kind#normalMap, lightmap = kind#lightmap, blend = kind#blend,
                      doubleSided = kind#doubleSided, cutout = cutout, metallicRoughness = kind#metallicRoughness, readsTextures = readsTextures };
        { variants = Map#{ variantKeyOf(kind#variant) => kind#variant }, materialShapes = Map#{ shapeKeyOf(shape) => shape } }

    /// 形の字（記録の表の鍵）。
    def shapeKeyOf(s: MaterialShape): String =
        let pairs = shapeFields(s);
        let on = pairs |> List.filter(snd) |> List.map(fst);
        if (List.isEmpty(on)) "plain" else String.intercalate("+", on)

    /// 形の欄の名前と値（ファイルの欄の名前と同じ・並びも同じ）。
    def shapeFields(s: MaterialShape): List[(String, Bool)] =
        ("skinned", s#skinned) :: ("uv", s#uv) :: ("normalMap", s#normalMap) :: ("lightmap", s#lightmap) :: ("blend", s#blend) ::
        ("doubleSided", s#doubleSided) :: ("cutout", s#cutout) :: ("metallicRoughness", s#metallicRoughness) :: ("readsTextures", s#readsTextures) :: Nil

    /// 場面 scene を描く時に使う鍵（描き手を使わない純粋な決め方。描き手の Render3d.ScenePlan と同じ決め方を写す）。
    /// 色の場面は場面の変種・奥行きの場面（Output.Depth）は既定の変種で、cutout か両面の材質だけ・半透明は外す。
    /// 影の pass は既定の一式で描くので鍵が要らない。動かない物の集まりの中の物と、MultiMesh の先頭の物も数える。視錐台で間引く前の全部の物を数える。
    pub def collectionKeysOf(scene: Scene3d.Scene3dCmd): CollectionKeys =
        let v = Render3d.ProgramKey.passVariantOf(scene);
        let isDepth = match scene#output {
            case Scene3d.Output.Color    => false
            case Scene3d.Output.Depth(_) => true
        };
        let wants = (m: Scene3d.MaterialFields) -> if (isDepth) (m#cutout or m#doubleSided) and not m#blend else true;
        let placed = scene#instances ::: List.flatMap(Scene3d.groupInstancesOf, scene#groups);
        let drawOf = (i: Scene3d.Instance3d) -> { fields = Scene3d.instanceFieldsOf(i), pose = Scene3d.skinningOf(i), poseRow = 0, culled = false };
        let fromPlaced = placed |> List.filterMap(i -> {
            let d = drawOf(i);
            d#fields#material |> Option.map(Scene3d.materialFieldsOf) |> Option.filter(wants) |> Option.map(m -> (d, m))
        });
        let fromMulti = scene#multiMeshes |> List.filter(mm -> MultiMesh3d.countOf(mm) > 0) |> List.filterMap(mm -> {
            let head = { fields = Scene3d.instanceFieldsOf(MultiMesh3d.headOf(mm)), pose = None, poseRow = 0, culled = false };
            MultiMesh3d.fieldsOf(mm)#material |> Option.map(Scene3d.materialFieldsOf) |> Option.filter(wants) |> Option.map(m -> (head, m))
        });
        (fromPlaced ::: fromMulti) |> List.foldLeft((acc, dm) -> {
            let (d, m) = dm;
            let kind = Render3d.ScenePlan.kindOf(false, v, d, m);
            unionCollection(acc, shapeKeys(kind, m#cutout, not List.isEmpty(Scene3d.materialTexReadsOf(m))))
        }, variantKeys(v))

    // ── 広げる ──

    /// 記録 c から、書き出しで作る字の鍵（両方の言語の分。字の無い言語は表を作る時に飛ばす）。
    /// いつも（既定の一式）: 既定の変種の頂点の色とビルボード・空・奥行き・blit・置いた物の頂点・ビルボードの影の frag。
    /// 変種ごと: 頂点の色（骨つきと無し）・ビルボード・+ao なら画面の上の pass。材質の形 × 変種ごと: 材質の頂点と frag（cutout の形は coverage の真偽の両方）。
    // WhyNot: 材質の形を変種ごとに記録しない — 同じ形が変種の数だけ行になり、変種を切り替えるゲームの記録が漏れやすい。作る数は増えるが字は似ていて縮む。
    pub def requiredKeysOf(c: CollectionKeys): List[ShaderSourceKey] =
        let recorded = Map.valuesOf(c#variants);
        let always = ShaderSourceKey.SkyVertex :: ShaderSourceKey.SkyFragment :: ShaderSourceKey.DepthFragment :: ShaderSourceKey.BlitVertex ::
                     ShaderSourceKey.BlitFragment :: ShaderSourceKey.MeshVertex(false) :: ShaderSourceKey.MeshVertex(true) :: ShaderSourceKey.BillboardShadowFragment ::
                     ShaderSourceKey.BillboardVertex(defaultShaderVariant(), Render3dShaders.BillboardRight.PerBillboard) :: Nil;
        let perVariant = (defaultShaderVariant() :: recorded) |> List.flatMap(variantSourceKeys);
        let perShape = Map.valuesOf(c#materialShapes) |> List.flatMap(s -> recorded |> List.flatMap(shapeSourceKeys(s)));
        (always ::: perVariant ::: perShape) |> distinctKeys

    def variantSourceKeys(v: ShaderVariant): List[ShaderSourceKey] =
        let bv = billboardVariantOf(v);
        let screen = if (v#ambientOcclusion)
            ShaderSourceKey.ScreenPassFragment(Render3d.ScreenPasses.ScreenPassKind.AoMask) ::
            ShaderSourceKey.ScreenPassFragment(Render3d.ScreenPasses.ScreenPassKind.AoBlurH) ::
            ShaderSourceKey.ScreenPassFragment(Render3d.ScreenPasses.ScreenPassKind.ShowAo) :: Nil else Nil;
        ShaderSourceKey.LitVertex(false, v#psx) :: ShaderSourceKey.LitVertex(true, v#psx) :: ShaderSourceKey.LitFragment(v) ::
        ShaderSourceKey.BillboardVertex(bv, Render3dShaders.BillboardRight.ByUniform) ::
        ShaderSourceKey.BillboardVertex(webGpuBillboardVertexVariant(bv), Render3dShaders.BillboardRight.Camera) ::
        ShaderSourceKey.BillboardFragment(bv) :: screen

    /// WebGPU のビルボードの頂点シェーダーの鍵の変種（PS1 風でなければ既定の物を使う）。
    pub def webGpuBillboardVertexVariant(bv: ShaderVariant): ShaderVariant = if (bv#psx) bv else defaultShaderVariant()

    def shapeSourceKeys(s: MaterialShape, v: ShaderVariant): List[ShaderSourceKey] =
        let coverages = if (s#cutout and not s#blend) true :: false :: Nil else false :: Nil;
        let kindOf = (coverage: Bool) -> { skinned = s#skinned, uv = s#uv, normalMap = s#normalMap, lightmap = s#lightmap, blend = s#blend,
                                           doubleSided = s#doubleSided, coverage = coverage, metallicRoughness = s#metallicRoughness, variant = v };
        let vertex = ShaderSourceKey.MaterialVertex({ skinned = s#skinned, uv = s#uv, lightmap = s#lightmap, psx = v#psx });
        let bakedVertex = ShaderSourceKey.MaterialVertex({ skinned = s#skinned, uv = s#uv, lightmap = s#lightmap and not s#skinned, psx = v#psx });
        vertex :: bakedVertex :: (coverages |> List.map(c -> ShaderSourceKey.MaterialFragmentTemplate(kindOf(c), s#readsTextures)))

    def distinctKeys(keys: List[ShaderSourceKey]): List[ShaderSourceKey] =
        keys |> List.foldLeft((acc, k) -> {
            let (seen, out) = acc;
            let name = Render3d.ShaderSourceKey.toKeyString(k);
            if (Set.memberOf(name, seen)) acc else (Set.insert(name, seen), k :: out)
        }, (Set.empty(), Nil)) |> snd |> List.reverse

    /// 記録 c の字の表（(言語:鍵の字, 字) の並び。provider がその言語の字を持たない鍵は入れない）。書き出しの道具が wasm へ埋める。
    pub def bakeTableOf(provider: ShaderSourceProvider, c: CollectionKeys): List[(String, String)] =
        requiredKeysOf(c) |> List.flatMap(k -> {
            let name = Render3d.ShaderSourceKey.toKeyString(k);
            let glsl = provider#glsl(k) |> Option.map(t -> (tableKeyOf("glsl", name), t)) |> Option.toList;
            let wgsl = provider#wgsl(k) |> Option.map(t -> (tableKeyOf("wgsl", name), t)) |> Option.toList;
            glsl ::: wgsl
        })

    /// 表の鍵（言語 lang と鍵の字 name）。
    def tableKeyOf(lang: String, name: String): String = lang + ":" + name

    /// 表 table（(言語:鍵の字, 字) の並び）を引く API（ブラウザの描き手）。
    pub def providerOfTable(table: Map[String, String]): ShaderSourceProvider =
        { glsl = k -> Map.get(tableKeyOf("glsl", Render3d.ShaderSourceKey.toKeyString(k)), table),
          wgsl = k -> Map.get(tableKeyOf("wgsl", Render3d.ShaderSourceKey.toKeyString(k)), table) }

    // ── 記録のファイル（web/shader-variants.json） ──

    /// 記録のファイルの版。
    def collectionVersion(): Int32 = 1

    /// 記録 c の JSON の字（欄は名前の順・並びは鍵の字の順で、新しい鍵の時だけ git の差が出る）。
    pub def collectionToJson(c: CollectionKeys): String =
        let shapes = Map.valuesOf(c#materialShapes) |> List.map(s -> JObject(shapeFields(s) |> List.map(nb -> (fst(nb), JBool(snd(nb)))) |> List.toMap));
        let obj = JObject(Map#{
            "version"        => JNumber(JBigDecimal.valueOf(Int32.toInt64(collectionVersion()))),
            "variants"       => JArray(Map.keysOf(c#variants) |> Set.toList |> List.map(JString) |> List.toVector),
            "materialShapes" => JArray(shapes |> List.toVector)
        });
        Util.Json.toPrettyString(2, obj) + "\n"

    /// 記録の JSON の字 text を読む。知らない欄と知らないフラグの字は読み飛ばし、無い欄は偽で読む。版が今より新しければ Err。
    pub def collectionOfJson(text: String): Result[String, CollectionKeys] = match Util.Json.parse(text) {
        case Ok(JObject(m)) =>
            let version = match Map.get("version", m) {
                case Some(JNumber(n)) => BigDecimal.tryToFloat64(n) |> Option.map(Float64.floor) |> Option.flatMap(Float64.tryToInt32)
                                             |> Option.getWithDefault(collectionVersion() + 1)
                case _                => collectionVersion()
            };
            if (version > collectionVersion()) Err("記録の版 ${version} はこの engine（版 ${collectionVersion()}）より新しい — engine を上げる")
            else {
                let variants = arrayOf("variants", m) |> List.filterMap(j -> match j {
                    case JString(s) => Some(variantOfKey(s))
                    case _          => None
                });
                let shapes = arrayOf("materialShapes", m) |> List.filterMap(j -> match j {
                    case JObject(f) => Some(shapeOfFields(f))
                    case _          => None
                });
                Ok({ variants = variants |> List.map(v -> (variantKeyOf(v), v)) |> List.toMap,
                     materialShapes = shapes |> List.map(s -> (shapeKeyOf(s), s)) |> List.toMap })
            }
        case Ok(_)  => Err("記録の頭がオブジェクトでない")
        case Err(e) => Err("記録の JSON が読めない（${e}）")
    }

    def arrayOf(name: String, m: Map[String, Json]): List[Json] = match Map.get(name, m) {
        case Some(JArray(items)) => Vector.toList(items)
        case _                   => Nil
    }

    def shapeOfFields(f: Map[String, Json]): MaterialShape =
        let on = name -> Map.get(name, f) == Some(JBool(true));
        { skinned = on("skinned"), uv = on("uv"), normalMap = on("normalMap"), lightmap = on("lightmap"), blend = on("blend"),
          doubleSided = on("doubleSided"), cutout = on("cutout"), metallicRoughness = on("metallicRoughness"), readsTextures = on("readsTextures") }

    /// 変種の鍵の字 key（"+ps+psx" の形）の変種（知らないフラグの字は読み飛ばす）。
    pub def variantOfKey(key: String): ShaderVariant =
        let byKey = Render3d.ProgramKey.flagRows() |> List.map(row -> (row#key, row#flag)) |> List.toMap;
        TextSplit.split("+", key) |> List.filter(t -> not String.isEmpty(t))
            |> List.filterMap(t -> Map.get("+" + t, byKey)) |> List.toSet |> Render3d.ProgramKey.variantOf

    /// path の記録を読む。ファイルが無いのは正常で、空の記録。
    pub def loadCollection(path: String): Result[String, CollectionKeys] \ IO =
        try {
            collectionOfJson(Files.readString(Path.of(path)))
        } catch {
            case _: NoSuchFileException => Ok(emptyCollection())
            case e: IOException => Err("${path} を読めない（${e.getMessage()}）")
        }

    /// 記録 c を path へ書く（一時ファイルへ書いてから置き換える）。
    pub def saveCollection(path: String, c: CollectionKeys): Result[String, Unit] \ IO =
        try {
            let target = Path.of(path);
            let parent = target.toAbsolutePath().getParent();
            discard Files.createDirectories(parent);
            let temp = Files.createTempFile(parent, "shader-variants", ".json.tmp");
            discard Files.writeString(temp, collectionToJson(c));
            discard Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            Ok(())
        } catch {
            case e: IOException => Err("${path} へ書けない（${e.getMessage()}）")
        }

    /// 環境変数 FLIX_GE_SHADER_VARIANTS（記録のファイルの道。fge run と fge debug が web/WebMain.flix のあるゲームにだけ置く）があれば、
    /// provider に記録を足した ShaderSources（新しい鍵を見た時だけファイルへ書く）。無ければ記録しない ShaderSources。
    pub def recordingFromEnv(provider: ShaderSourceProvider): ShaderSources \ IO =
        match Map.get("FLIX_GE_SHADER_VARIANTS", LwjglEnv.snapshot()) |> Option.filter(p -> not String.isEmpty(p)) {
            case None       => withoutRecording(provider)
            case Some(path) =>
                let start = match loadCollection(path) {
                    case Ok(c)  => c
                    case Err(e) => Log.fellBackThen("shader", path, "空の記録", e, emptyCollection())

                };
                let held = Ref.fresh(Static, start);
                { provider = provider, record = keys -> {
                    let before = Ref.get(held);
                    if (coversCollection(before, keys)) ()
                    else {
                        let after = unionCollection(before, keys);
                        Ref.put(after, held);
                        match saveCollection(path, after) {
                            case Ok(_)  => ()
                            case Err(e) => Log.fellBack("shader", path, "書かない", e)
                        }
                    }
                } }
        }
}
