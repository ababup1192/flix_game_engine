// Gltf.Internal — glb の読み込みが使う、ノードの姿勢と左右の反転の計算と、頂点の色（COLOR_0）の読み方と、頂点の並びの組み立て。

/// Gltf の中身。ゲームからは呼ばない。
pub mod Gltf.Internal {
    import java.lang.Float

    pub def mirror(): Mat4.Mat4 = Mat4.scale(Vec3.v3(-1.0, 1.0, 1.0))

    /// COLOR_0 の accessor の形 width と型 componentType が読める物か（VEC3・VEC4 と、FLOAT か正規化した UNSIGNED_BYTE・UNSIGNED_SHORT）。読めなければ理由。
    pub def colorAccessorProblem(width: Int32, componentType: Int32, normalized: Bool): Option[String] =
        if (width != 3 and width != 4) Some("glTF: COLOR_0 の幅 ${width} は読まない（VEC3 か VEC4）")
        else if (componentType == 5126 or ((componentType == 5121 or componentType == 5123) and normalized)) None
        else Some("glTF: COLOR_0 の componentType ${componentType} は読まない（FLOAT か正規化した UNSIGNED_BYTE・UNSIGNED_SHORT）")

    /// 頂点の色の欄（頂点ごとに r, g, b の画面の値）。base = baseColorFactor の色（画面の値の 3 つ）・vertex = COLOR_0 の (幅, 値)（正規化の後の 0..1）。
    /// COLOR_0 は glTF の決まりどおり線形の値として読み、0..1 に切ってから画面の値へ戻して base に掛ける（α は読まない）。無ければ base の色だけ。
    // WhyNot: 線形の値のまま描き手へ渡さない — 描き手は頂点の色を画面の値として読む（材質は絵 × 頂点の色を画面の値どうしで掛ける）。
    //   戻さないと Blender でベイクした明るさが暗く沈む。画面の値どうしの掛け算は Blender の線形の掛け算と暗い所で少しずれる（docs/scene3d.md の glTF の頂点の色）。
    pub def colorsOf(count: Int32, base: Vector[Float64], vertex: Option[(Int32, Vector[Float64])]): Vector[Float64] =
        Vector.range(0, count * 3) |> Vector.map(j -> {
            let c = Int32.remainder(j, 3);
            Vector.get(c, base) * vertexChannel(vertex, j / 3, c)
        })

    def vertexChannel(vertex: Option[(Int32, Vector[Float64])], v: Int32, c: Int32): Float64 = match vertex {
        case None              => 1.0
        case Some((w, values)) => screenOfLinear(Vector.get(v * w + c, values))
    }

    // WhyNot: 1 を linearToSrgb に通さない — 式の丸めで 0.9999999999999999 になり、白の COLOR_0 の形が白い頂点の形と別の色（別の鍵）になる。
    def screenOfLinear(x: Float64): Float64 =
        if (x >= 1.0) 1.0 else if (x <= 0.0 or Float64.isNan(x)) 0.0 else Texture3d.linearToSrgb(x)

    /// S·M·S（glTF の座標の行列 → engine の座標の行列）。
    pub def mirrorMat4(m: Mat4.Mat4): Mat4.Mat4 = Mat4.mul(mirror(), Mat4.mul(m, mirror()))

    pub def mirrorPose(p: Skin3d.JointPose): Skin3d.JointPose =
        { translation = Vec3.v3(0.0 - p#translation#x, p#translation#y, p#translation#z),
          rotation = { x = p#rotation#x, y = 0.0 - p#rotation#y, z = 0.0 - p#rotation#z, w = p#rotation#w },
          scale = p#scale }

    /// 列優先の 16 個を平行移動・回転・倍率に分ける（行列式が負なら x の倍率を負にする）。
    pub def decompose(cells: Vector[Float64]): Skin3d.JointPose =
        let c = i -> Vector.get(i, cells);
        let len = (i: Int32) -> Num.sqrt(c(i) * c(i) + c(i + 1) * c(i + 1) + c(i + 2) * c(i + 2));
        let det = c(0) * (c(5) * c(10) - c(9) * c(6)) - c(4) * (c(1) * c(10) - c(9) * c(2)) + c(8) * (c(1) * c(6) - c(5) * c(2));
        let sx = if (det < 0.0) 0.0 - len(0) else len(0);
        let sy = len(4);
        let sz = len(8);
        let safe = s -> if (Float64.abs(s) < 1.0e-12) 1.0 else s;
        let m = (row: Int32, col: Int32) -> c(col * 4 + row) / safe(if (col == 0) sx else if (col == 1) sy else sz);
        { translation = Vec3.v3(c(12), c(13), c(14)), rotation = quatOfRotation(m), scale = Vec3.v3(sx, sy, sz) }

    pub def quatOfRotation(m: (Int32, Int32) -> Float64): Quat.Quat =
        let trace = m(0, 0) + m(1, 1) + m(2, 2);
        let q =
            if (trace > 0.0) {
                let s = Num.sqrt(trace + 1.0) * 2.0;
                { x = (m(2, 1) - m(1, 2)) / s, y = (m(0, 2) - m(2, 0)) / s, z = (m(1, 0) - m(0, 1)) / s, w = 0.25 * s }
            } else if (m(0, 0) > m(1, 1) and m(0, 0) > m(2, 2)) {
                let s = Num.sqrt(1.0 + m(0, 0) - m(1, 1) - m(2, 2)) * 2.0;
                { x = 0.25 * s, y = (m(0, 1) + m(1, 0)) / s, z = (m(0, 2) + m(2, 0)) / s, w = (m(2, 1) - m(1, 2)) / s }
            } else if (m(1, 1) > m(2, 2)) {
                let s = Num.sqrt(1.0 + m(1, 1) - m(0, 0) - m(2, 2)) * 2.0;
                { x = (m(0, 1) + m(1, 0)) / s, y = 0.25 * s, z = (m(1, 2) + m(2, 1)) / s, w = (m(0, 2) - m(2, 0)) / s }
            } else {
                let s = Num.sqrt(1.0 + m(2, 2) - m(0, 0) - m(1, 1)) * 2.0;
                { x = (m(0, 2) + m(2, 0)) / s, y = (m(1, 2) + m(2, 1)) / s, z = 0.25 * s, w = (m(1, 0) - m(0, 1)) / s }
            };
        Quat.normalized(q)

    pub def vec3At(v: Vector[Float64], k: Int32): Vec3.Vec3 = Vec3.v3(Vector.get(k, v), Vector.get(k + 1, v), Vector.get(k + 2, v))

    pub def quatOf(v: Vector[Float64]): Quat.Quat = { x = Vector.get(0, v), y = Vector.get(1, v), z = Vector.get(2, v), w = Vector.get(3, v) }

    /// count 行 × width 列の並び（行 k・列 c の値は cell(k, c)）。
    // WhyNot: 行ごとの小さな Vector を Vector.flatMap でつながない — 頂点数万の glb で数百 ms かかる。
    pub def rowsOf(count: Int32, width: Int32, cell: (Int32, Int32) -> a \ ef): Vector[a] \ ef =
        Vector.range(0, count * width) |> Vector.map(j -> cell(j / width, Int32.remainder(j, width)))

    /// src（頂点ごとに width 個）から、sources の頂点の順に写した並び。
    pub def gather(width: Int32, src: Vector[a], sources: Vector[Int32]): Vector[a] =
        rowsOf(Vector.length(sources), width, (k, c) -> Vector.get(Vector.get(k, sources) * width + c, src))

    /// v の [start, end) を写す。
    // WhyNot: Vector.slice・take・drop を使わない — 標準の版は v 全体を配列へ写してから切るので、1.5 MB の束から絵 46 枚を切ると 70 MB 写す。
    // WhyNot: 1 つずつ Vector.get で写さない — 絵のバイトを切り出すたびに要素ごとの呼び出しが乗り、Worker の結果を組むコマで目立つ。
    pub def copyRange(start: Int32, end: Int32, v: Vector[a]): Vector[a] =
        if (end <= start) Vector.empty()
        else region rc {
            let src: Array[a, rc] = unchecked_cast(v as Array[a, rc]);
            unchecked_cast(Array.copyOfRange(rc, start, end, src) as Vector[a])
        }

    /// IEEE 754 の単精度のビットから組む。
    pub def float32OfBits(bits: Int32): Float64 = Float32.toFloat64(Float.intBitsToFloat(bits))

    pub def flatXyz(vs: Vector[Vec3.Vec3]): Vector[Float64] = rowsOf(Vector.length(vs), 3, (k, c) -> component(c, Vector.get(k, vs)))

    pub def component(c: Int32, v: Vec3.Vec3): Float64 = if (c == 0) v#x else if (c == 1) v#y else v#z

    /// model の形の中身の鍵を key から作った物にする（part ごとに "key#part<番号>"・まとめた形は "key#all"）。
    pub def withKeyedMeshes(key: String, model: Model3d.Model3d): Model3d.Model3d =
        { mesh = Mesh3d.withContentKey("${key}#all", model#mesh), parts = model#parts |> List.mapWithIndex((k, part) -> { mesh = Mesh3d.withContentKey("${key}#part${k}", part#mesh) | part }) | model }

    /// parse の結果 parsed に、絵と材質と形の鍵を付けて Model3d にする（bytes = parse に渡したのと同じ glb のバイト。絵を切り出す）。
    /// key の意味は Gltf.decodeWith のとおり。
    pub def assemble(decoder: ImageData.ImageDecoder, options: Gltf.LoadOptions, key: Option[String], bytes: Vector[Int8],
                     parsed: Gltf.Internal.Parse.Parsed): Model3d.Model3d \ IO =
        match key {
            case Some(k) => Gltf.assembleBy(keyedImageOf(k, decoder), options, bytes, parsed) |> withKeyedMeshes(k)
            case None    => Gltf.assembleBy((_, _, image) -> Texture3d.decodeUsing(decoder, image), options, bytes, parsed)
        }

    /// 機種がメインの外で解いた結果を戻す。戻せない時と、解いた時の選択肢が options と違う時は 1 行知らせて None（呼ぶ側はバイトから読み直す）。
    pub def toParsed(options: Gltf.LoadOptions, path: String, preparsed: LoadProgress.Preparsed): Option[Gltf.Internal.Parse.Parsed] =
        match Gltf.Internal.Codec.deserialize(LoadProgress.Internal.partsOf(preparsed)) {
            case Err(e) => Log.fellBackThen("scene3d", "${path} の Worker で解いた結果", "メインで読み直す", e, None)
            case Ok(parsed) =>
                let wanted = Gltf.Internal.Parse.readOptionsOf(options);
                if (parsed#read#pbr == wanted#pbr and parsed#read#vertexColors == wanted#vertexColors) Some(parsed)
                else Log.fellBackThen("scene3d", "${path} の Worker で解いた結果", "メインで読み直す", "読んだ時の gltf の選択肢が違う", None)
        }

    /// Worker が解く仕事: project.json の "gltf" の値の字 gltfText で bytes を parse して並びにする。
    /// 並びと、使う絵（Gltf.decodeWith が解く絵）の (画像の番号, バイトの中の始まり, 長さ) を返す。
    pub def preparse(gltfText: String, bytes: Vector[Int8]): Result[String, (LoadProgress.Internal.PreparsedParts, List[(Int32, Int32, Int32)])] =
        forM (
            options <- ProjectLoader.Internal.gltfOptionsOf(gltfText);
            parsed <- Gltf.Internal.Parse.parse(Gltf.Internal.Parse.readOptionsOf(options), bytes)
        ) yield {
            let used = Gltf.usedImages(options, parsed#materials);
            let ranges = parsed#images |> Vector.toList |> List.zipWithIndex |> List.filterMap(entry -> match entry {
                case (k, Gltf.Internal.Parse.ImageSource.InBin(start, length)) if Map.memberOf(k, used) => Some((k, start, length))
                case _ => None
            });
            (Gltf.Internal.Codec.serialize(parsed), ranges)
        }

    /// 小さな parse の結果（形・骨・アニメ・ノード・材質・画像を 1 つずつ）の並び。
    /// ブラウザで後回しの glb を Worker で解くゲームが、読み込みの間に 1 回、機種の受け渡しと warmUpCodec を通す（戻す関数をメインのスレッドで 1 度走らせておく）。
    // WhyNot: 初めて Worker の結果が届いたコマで初めて戻さない — wasm の関数は初めて呼ぶ時に組まれ、束の大きさによらず 4 倍の絞りで 20 ms ほどがそのコマに乗る。
    pub def warmUpWire(): Result[String, LoadProgress.Internal.PreparsedParts] =
        let tri = Mesh3d.fromArrays({ positions = Vector#{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0 },
                                      normals = Vector#{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0 },
                                      colors = Vector.repeat(9, 1.0), indices = Vector#{ 0, 1, 2 },
                                      skin = Some({ joints = Vector.repeat(12, 0), weights = Vector#{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 } }) })
            |> Result.flatMap(Mesh3d.withUvs(Vector#{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0 }))
            |> Result.flatMap(Mesh3d.withTangents(Vector#{ 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0 }))
            |> Result.flatMap(Mesh3d.withUvs2(Vector#{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0 }));
        let spec = { names = Vector#{ "j" }, parents = Vector#{ -1 }, rest = Vector#{ { translation = Vec3.zero(), rotation = Quat.identity(), scale = Vec3.one() } },
                     inverseBinds = Some(Vector#{ Mat4.identity() }), rootTransform = Mat4.identity() };
        let clip = { name = "a", channels = { joint = 0, path = AnimationClip3d.Path.Rotation, times = Vector#{ 0.0, 1.0 },
                                              values = Vector#{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0 }, interpolation = AnimationClip3d.Interpolation.Linear } :: Nil };
        let info = { index = Some(0), texCoord = 0, transform = Some({ offsetU = 0.0, offsetV = 0.0, rotation = 0.0, scaleU = 1.0, scaleV = 1.0, texCoord = Some(0) }),
                     source = Some(0), nearest = false, clamp = false, mirrored = false };
        let material = { name = Some("m"), alphaMode = Model3d.AlphaMode.Mask, alphaCutoff = 0.5, doubleSided = true, base = info, normal = info, normalScale = Some(1.0),
                         emissive = info, emissiveFactor = { r = 1.0, g = 1.0, b = 1.0 }, emissiveFactorError = Some("e"), emissiveStrength = 1.0, metalRough = info,
                         hasPbr = true, hasMetallic = true, hasRoughness = true, metallicFactor = Some(1.0), roughnessFactor = Some(1.0),
                         occlusion = info, occlusionStrength = 1.0 };
        let built = forM (
            mesh <- tri;
            skin <- Skin3d.make(spec);
            made <- Gltf.Internal.Parse.makeClip(clip)
        ) yield {
            mesh = mesh, skin = Some(skin), skinSpec = Some(spec), clips = Gltf.Internal.Parse.clipsByName(made :: Nil), clipSpecs = clip :: Nil,
            parts = { mesh = mesh, node = 0, material = Some(0), givenTangents = true } :: Nil,
            nodes = { name = "n", parent = None, local = Mat4.identity(), world = Mat4.identity(), localBounds = Some(Mesh3d.bounds(mesh)), parts = 0 :: Nil } :: Nil,
            materials = Vector#{ material },
            images = Vector#{ Gltf.Internal.Parse.ImageSource.InBin(0, 0), Gltf.Internal.Parse.ImageSource.Unreadable("u"),
                              Gltf.Internal.Parse.ImageSource.ExternalUri, Gltf.Internal.Parse.ImageSource.NoSource },
            lines = "l" :: Nil, droppedLines = "d" :: Nil, read = { pbr = true, vertexColors = true }
        };
        built |> Result.map(Gltf.Internal.Codec.serialize)

    /// warmUpWire の並びを戻せたか（戻す関数を 1 度走らせる）。
    pub def warmUpCodec(wire: LoadProgress.Internal.PreparsedParts): Bool =
        Gltf.Internal.Codec.deserialize(wire) |> Result.map(p -> Vector.length(Mesh3d.positions(p#mesh)) == 9) |> Result.getWithDefault(false)

    /// 鍵つきの読み方の、images[k] のバイト image の絵（上限 maxSide）。機種の側に持てて（id は "key#image<番号>"）上限の内なら画素を読まず、ほかは画素へ戻す。
    // WhyNot: 上限より大きい機種の側の絵を使わない — Texture3d.limitSize は機種の側の絵を縮めず、場面の絵の置き場を上限の外の大きさで食う。
    pub def keyedImageOf(key: String, decoder: ImageData.ImageDecoder, k: Int32, maxSide: Int32, image: Vector[Int8]): Result[String, Texture3d.Texture3d] \ IO =
        match (decoder#platformImageOfBytes)("${key}#image${k}", image) {
            case Some(p) if Int32.max(p#width, p#height) <= maxSide => Texture3d.fromPlatformImage(p)
            case _ => Texture3d.decodeUsing(decoder, image)
        }
}
