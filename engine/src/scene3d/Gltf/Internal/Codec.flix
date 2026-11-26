// Gltf.Internal.Codec — parse の結果を、数・字・配列の並び（LoadProgress.Internal.PreparsedParts）にして運び、戻す。
// ブラウザは Web Worker の中で parse して serialize し、メインが deserialize して assemble する。

/// glb の parse の結果の運び方。ゲームからは呼ばない。
// WhyNot: JSON で運ばない — メインで JSON を読み直すと、Worker へ出したかった仕事の一部がメインに戻る。
// WhyNot: 頂点を 1 つのバイト列に詰めない — wasm の中でバイトから Float64 を組み直すと、配列のまま渡すより 3〜5 倍遅い。
pub mod Gltf.Internal.Codec {
    use Gltf.Internal.Parse.{Parsed, ParsedPart, MaterialSpec, TextureInfo, ImageSource, SkinSpec, ClipSpec}

    /// 並びの形の版。読む側と書く側が同じ wasm なので、違えば壊れた物として読まない。
    def formatVersion(): Int32 = 1

    type alias Writer[r: Region] = { ints = MutList[Int32, r], floats = MutList[Float64, r], strings = MutList[String, r],
                                     f64s = MutList[Vector[Float64], r], i32s = MutList[Vector[Int32], r] }

    /// parsed を並びにする。
    pub def serialize(parsed: Parsed): LoadProgress.Internal.PreparsedParts = region rc {
        let w = { ints = MutList.empty(rc), floats = MutList.empty(rc), strings = MutList.empty(rc),
                  f64s = MutList.empty(rc), i32s = MutList.empty(rc) };
        putInt(w, formatVersion());
        putBool(w, parsed#read#pbr);
        putBool(w, parsed#read#vertexColors);
        putBool(w, Option.nonEmpty(parsed#skin));
        putList(w, putPart(w), parsed#parts);
        putOption(w, putSkinSpec(w), parsed#skinSpec);
        putList(w, putClipSpec(w), parsed#clipSpecs);
        putList(w, putNode(w), parsed#nodes);
        putList(w, putMaterial(w), Vector.toList(parsed#materials));
        putList(w, putImage(w), Vector.toList(parsed#images));
        putList(w, putString(w), parsed#lines);
        putList(w, putString(w), parsed#droppedLines);
        { strings = MutList.toVector(w#strings), ints = MutList.toVector(w#ints), floats = MutList.toVector(w#floats),
          f64s = MutList.toVector(w#f64s), i32s = MutList.toVector(w#i32s) }
    }

    def putInt(w: Writer[r], v: Int32): Unit \ r = MutList.push(v, w#ints)

    def putBool(w: Writer[r], v: Bool): Unit \ r = putInt(w, if (v) 1 else 0)

    def putFloat(w: Writer[r], v: Float64): Unit \ r = MutList.push(v, w#floats)

    def putString(w: Writer[r], v: String): Unit \ r = MutList.push(v, w#strings)

    def putF64s(w: Writer[r], v: Vector[Float64]): Unit \ r = MutList.push(v, w#f64s)

    def putI32s(w: Writer[r], v: Vector[Int32]): Unit \ r = MutList.push(v, w#i32s)

    def putList(w: Writer[r], put: a -> Unit \ r, xs: List[a]): Unit \ r =
        putInt(w, List.length(xs));
        List.forEach(put, xs)

    def putOption(w: Writer[r], put: a -> Unit \ r, o: Option[a]): Unit \ r = match o {
        case Some(v) => { putBool(w, true); put(v) }
        case None    => putBool(w, false)
    }

    def putVec3(w: Writer[r], v: Vec3.Vec3): Unit \ r =
        putFloat(w, v#x);
        putFloat(w, v#y);
        putFloat(w, v#z)

    def putMat4(w: Writer[r], m: Mat4.Mat4): Unit \ r = Mat4.toColumns(m) |> Vector.forEach(putFloat(w))

    def putPart(w: Writer[r], part: ParsedPart): Unit \ r =
        let a = Mesh3d.Internal.trustedPartsOf(part#givenTangents, part#mesh);
        putInt(w, part#node);
        putOption(w, putInt(w), part#material);
        putBool(w, part#givenTangents);
        putF64s(w, a#positions);
        putF64s(w, a#normals);
        putF64s(w, a#colors);
        putI32s(w, a#indices);
        putOption(w, sw -> { putI32s(w, sw#joints); putF64s(w, sw#weights) }, a#skin);
        putOption(w, putF64s(w), a#uvs);
        putOption(w, putF64s(w), a#tangents);
        putOption(w, putF64s(w), a#uvs2);
        putVec3(w, a#low);
        putVec3(w, a#high);
        putOption(w, putInt(w), a#maxJoint)

    def putSkinSpec(w: Writer[r], spec: SkinSpec): Unit \ r =
        putList(w, putString(w), Vector.toList(spec#names));
        putI32s(w, spec#parents);
        putF64s(w, spec#rest |> Vector.flatMap(p -> Vector#{ p#translation#x, p#translation#y, p#translation#z,
                                                              p#rotation#x, p#rotation#y, p#rotation#z, p#rotation#w,
                                                              p#scale#x, p#scale#y, p#scale#z }));
        putOption(w, binds -> putF64s(w, Vector.flatMap(Mat4.toColumns, binds)), spec#inverseBinds);
        putMat4(w, spec#rootTransform)

    def putClipSpec(w: Writer[r], spec: ClipSpec): Unit \ r =
        putString(w, spec#name);
        putList(w, ch -> {
            putInt(w, ch#joint);
            putInt(w, pathCode(ch#path));
            putBool(w, ch#interpolation == AnimationClip3d.Interpolation.Step);
            putF64s(w, ch#times);
            putF64s(w, ch#values)
        }, spec#channels)

    def pathCode(p: AnimationClip3d.Path): Int32 = match p {
        case AnimationClip3d.Path.Translation => 0
        case AnimationClip3d.Path.Rotation    => 1
        case AnimationClip3d.Path.Scale       => 2
    }

    def putNode(w: Writer[r], node: Model3d.ModelNode): Unit \ r =
        putString(w, node#name);
        putOption(w, putInt(w), node#parent);
        putMat4(w, node#local);
        putMat4(w, node#world);
        putOption(w, b -> { putVec3(w, b#min); putVec3(w, b#max) }, node#localBounds);
        putList(w, putInt(w), node#parts)

    def putTextureInfo(w: Writer[r], t: TextureInfo): Unit \ r =
        putOption(w, putInt(w), t#index);
        putInt(w, t#texCoord);
        putBool(w, t#transform);
        putOption(w, putInt(w), t#source);
        putBool(w, t#nearest);
        putBool(w, t#clamp);
        putBool(w, t#mirrored)

    def putMaterial(w: Writer[r], m: MaterialSpec): Unit \ r =
        putOption(w, putString(w), m#name);
        putInt(w, alphaCode(m#alphaMode));
        putFloat(w, m#alphaCutoff);
        putBool(w, m#doubleSided);
        putTextureInfo(w, m#base);
        putTextureInfo(w, m#normal);
        putOption(w, putFloat(w), m#normalScale);
        putTextureInfo(w, m#emissive);
        putFloat(w, m#emissiveFactor#r);
        putFloat(w, m#emissiveFactor#g);
        putFloat(w, m#emissiveFactor#b);
        putOption(w, putString(w), m#emissiveFactorError);
        putFloat(w, m#emissiveStrength);
        putTextureInfo(w, m#metalRough);
        putBool(w, m#hasPbr);
        putBool(w, m#hasMetallic);
        putBool(w, m#hasRoughness);
        putOption(w, putFloat(w), m#metallicFactor);
        putOption(w, putFloat(w), m#roughnessFactor)

    def alphaCode(mode: Model3d.AlphaMode): Int32 = match mode {
        case Model3d.AlphaMode.Opaque => 0
        case Model3d.AlphaMode.Mask   => 1
        case Model3d.AlphaMode.Blend  => 2
    }

    def putImage(w: Writer[r], image: ImageSource): Unit \ r = match image {
        case ImageSource.InBin(start, length) => { putInt(w, 0); putInt(w, start); putInt(w, length) }
        case ImageSource.Unreadable(e)        => { putInt(w, 1); putString(w, e) }
        case ImageSource.ExternalUri          => putInt(w, 2)
        case ImageSource.NoSource             => putInt(w, 3)
    }

    // ── 戻す ──

    /// cursors = ints・floats・strings・f64s・i32s の次に読む番号・broken[0] = 並びの外を読んだ。
    type alias Reader[r: Region] = { wire = LoadProgress.Internal.PreparsedParts, cursors = Array[Int32, r], broken = Array[Bool, r] }

    /// serialize の逆。並びの形の版が違う・並びが足りない・余る時は Err。
    pub def deserialize(wire: LoadProgress.Internal.PreparsedParts): Result[String, Parsed] = region rc {
        let rd = { wire = wire, cursors = Array.repeat(rc, 5, 0), broken = Array.repeat(rc, 1, false) };
        let version = getInt(rd);
        if (version != formatVersion()) Err("glb の Worker の結果: 並びの形の版 ${version}（読めるのは ${formatVersion()}）")
        else {
            let read = { pbr = getBool(rd), vertexColors = getBool(rd) };
            let skinned = getBool(rd);
            let parts = getList(rd, () -> getPart(rd));
            let skinSpec = getOption(rd, () -> getSkinSpec(rd));
            let clipSpecs = getList(rd, () -> getClipSpec(rd));
            let nodes = getList(rd, () -> getNode(rd));
            let materials = getList(rd, () -> getMaterial(rd));
            let images = getList(rd, () -> getImage(rd));
            let lines = getList(rd, () -> getString(rd));
            let droppedLines = getList(rd, () -> getString(rd));
            let used = Array.toVector(rd#cursors);
            let lengths = Vector#{ Vector.length(wire#ints), Vector.length(wire#floats), Vector.length(wire#strings),
                                   Vector.length(wire#f64s), Vector.length(wire#i32s) };
            if (Array.get(0, rd#broken) or used != lengths) Err("glb の Worker の結果: 並びの数が合わない")
            else forM (
                skin <- traverseOption(spec -> Skin3d.make(spec) |> Result.mapErr(e -> "glTF: ${e}"), skinSpec);
                clips <- Result.traverse(Gltf.Internal.Parse.makeClip, clipSpecs)
            ) yield {
                { mesh = Mesh3d.Internal.concatTrusted(skinned, List.map(p -> p#arrays, parts)),
                  skin = skin, skinSpec = skinSpec, clips = Gltf.Internal.Parse.clipsByName(clips), clipSpecs = clipSpecs,
                  parts = parts |> List.map(p -> { mesh = Mesh3d.Internal.fromTrusted(p#arrays), node = p#node, material = p#material,
                                                   givenTangents = p#givenTangents }),
                  nodes = nodes, materials = List.toVector(materials), images = List.toVector(images),
                  lines = lines, droppedLines = droppedLines, read = read }
            }
        }
    }

    def traverseOption(f: a -> Result[String, b], o: Option[a]): Result[String, Option[b]] = match o {
        case Some(v) => Result.map(Some, f(v))
        case None    => Ok(None)
    }

    /// 並び k（0 = ints …）の次の番号を返して 1 つ進める。並びの外なら broken を立てる。
    def advance(rd: Reader[r], k: Int32, length: Int32): Option[Int32] \ r =
        let at = Array.get(k, rd#cursors);
        Array.put(at + 1, k, rd#cursors);
        if (at < length) Some(at) else { Array.put(true, 0, rd#broken); None }

    def getInt(rd: Reader[r]): Int32 \ r =
        advance(rd, 0, Vector.length(rd#wire#ints)) |> Option.map(i -> Vector.get(i, rd#wire#ints)) |> Option.getWithDefault(0)

    def getBool(rd: Reader[r]): Bool \ r = getInt(rd) == 1

    def getFloat(rd: Reader[r]): Float64 \ r =
        advance(rd, 1, Vector.length(rd#wire#floats)) |> Option.map(i -> Vector.get(i, rd#wire#floats)) |> Option.getWithDefault(0.0)

    def getString(rd: Reader[r]): String \ r =
        advance(rd, 2, Vector.length(rd#wire#strings)) |> Option.map(i -> Vector.get(i, rd#wire#strings)) |> Option.getWithDefault("")

    def getF64s(rd: Reader[r]): Vector[Float64] \ r =
        advance(rd, 3, Vector.length(rd#wire#f64s)) |> Option.map(i -> Vector.get(i, rd#wire#f64s)) |> Option.getWithDefault(Vector.empty())

    def getI32s(rd: Reader[r]): Vector[Int32] \ r =
        advance(rd, 4, Vector.length(rd#wire#i32s)) |> Option.map(i -> Vector.get(i, rd#wire#i32s)) |> Option.getWithDefault(Vector.empty())

    /// 数を読み、その数だけ get で読む。負の数は 0 個として broken を立てる。
    def getList(rd: Reader[r], get: Unit -> a \ r): List[a] \ r =
        let n = getInt(rd);
        if (n < 0) { Array.put(true, 0, rd#broken); Nil }
        else List.range(0, n) |> List.map(_ -> get())

    def getOption(rd: Reader[r], get: Unit -> a \ r): Option[a] \ r =
        if (getBool(rd)) Some(get()) else None

    def getVec3(rd: Reader[r]): Vec3.Vec3 \ r =
        let x = getFloat(rd);
        let y = getFloat(rd);
        let z = getFloat(rd);
        Vec3.v3(x, y, z)

    def getMat4(rd: Reader[r]): Mat4.Mat4 \ r =
        let cells = List.range(0, 16) |> List.map(_ -> getFloat(rd)) |> List.toVector;
        mat4OfColumns(rd, cells)

    def mat4OfColumns(rd: Reader[r], cells: Vector[Float64]): Mat4.Mat4 \ r = match Mat4.ofColumns(cells) {
        case Ok(m)  => m
        case Err(_) => { Array.put(true, 0, rd#broken); Mat4.identity() }
    }

    /// 運んだ part 1 つ（arrays = 形の中身）。
    type alias PartWire = { node = Int32, material = Option[Int32], givenTangents = Bool, arrays = Mesh3d.Internal.TrustedArrays }

    def getPart(rd: Reader[r]): PartWire \ r =
        let node = getInt(rd);
        let material = getOption(rd, () -> getInt(rd));
        let givenTangents = getBool(rd);
        let positions = getF64s(rd);
        let normals = getF64s(rd);
        let colors = getF64s(rd);
        let indices = getI32s(rd);
        let skin = getOption(rd, () -> { let joints = getI32s(rd); { joints = joints, weights = getF64s(rd) } });
        let uvs = getOption(rd, () -> getF64s(rd));
        let tangents = getOption(rd, () -> getF64s(rd));
        let uvs2 = getOption(rd, () -> getF64s(rd));
        let low = getVec3(rd);
        let high = getVec3(rd);
        let maxJoint = getOption(rd, () -> getInt(rd));
        let arrays = { positions = positions, normals = normals, colors = colors, indices = indices, skin = skin,
                       uvs = uvs, tangents = tangents, uvs2 = uvs2, low = low, high = high, maxJoint = maxJoint };
        { node = node, material = material, givenTangents = givenTangents, arrays = arrays }

    def getSkinSpec(rd: Reader[r]): SkinSpec \ r =
        let names = getList(rd, () -> getString(rd)) |> List.toVector;
        let parents = getI32s(rd);
        let restCells = getF64s(rd);
        let binds = getOption(rd, () -> getF64s(rd));
        let root = getMat4(rd);
        let cell = (k: Int32) -> Vector.nth(k, restCells) |> Option.getWithDefault(0.0);
        let rest = Vector.range(0, Vector.length(restCells) / 10) |> Vector.map(j -> {
            let b = j * 10;
            { translation = Vec3.v3(cell(b), cell(b + 1), cell(b + 2)),
              rotation = { x = cell(b + 3), y = cell(b + 4), z = cell(b + 5), w = cell(b + 6) },
              scale = Vec3.v3(cell(b + 7), cell(b + 8), cell(b + 9)) }
        });
        let inverseBinds = binds |> Option.map(cells ->
            Vector.range(0, Vector.length(cells) / 16) |> Vector.map(j -> mat4OfColumns(rd, Gltf.Internal.copyRange(j * 16, j * 16 + 16, cells))));
        { names = names, parents = parents, rest = rest, inverseBinds = inverseBinds, rootTransform = root }

    def getClipSpec(rd: Reader[r]): ClipSpec \ r =
        let name = getString(rd);
        let channels = getList(rd, () -> {
            let joint = getInt(rd);
            let path = pathOfCode(getInt(rd));
            let step = getBool(rd);
            let times = getF64s(rd);
            let values = getF64s(rd);
            { joint = joint, path = path, times = times, values = values,
              interpolation = if (step) AnimationClip3d.Interpolation.Step else AnimationClip3d.Interpolation.Linear }
        });
        { name = name, channels = channels }

    def pathOfCode(code: Int32): AnimationClip3d.Path =
        if (code == 1) AnimationClip3d.Path.Rotation else if (code == 2) AnimationClip3d.Path.Scale else AnimationClip3d.Path.Translation

    def getNode(rd: Reader[r]): Model3d.ModelNode \ r =
        let name = getString(rd);
        let parent = getOption(rd, () -> getInt(rd));
        let local = getMat4(rd);
        let world = getMat4(rd);
        let localBounds = getOption(rd, () -> { let low = getVec3(rd); { min = low, max = getVec3(rd) } });
        let parts = getList(rd, () -> getInt(rd));
        { name = name, parent = parent, local = local, world = world, localBounds = localBounds, parts = parts }

    def getTextureInfo(rd: Reader[r]): TextureInfo \ r =
        let index = getOption(rd, () -> getInt(rd));
        let texCoord = getInt(rd);
        let transform = getBool(rd);
        let source = getOption(rd, () -> getInt(rd));
        let nearest = getBool(rd);
        let clamp = getBool(rd);
        let mirrored = getBool(rd);
        { index = index, texCoord = texCoord, transform = transform, source = source, nearest = nearest, clamp = clamp, mirrored = mirrored }

    def getMaterial(rd: Reader[r]): MaterialSpec \ r =
        let name = getOption(rd, () -> getString(rd));
        let alphaMode = alphaOfCode(getInt(rd));
        let alphaCutoff = getFloat(rd);
        let doubleSided = getBool(rd);
        let base = getTextureInfo(rd);
        let normal = getTextureInfo(rd);
        let normalScale = getOption(rd, () -> getFloat(rd));
        let emissive = getTextureInfo(rd);
        let er = getFloat(rd);
        let eg = getFloat(rd);
        let eb = getFloat(rd);
        let emissiveFactorError = getOption(rd, () -> getString(rd));
        let emissiveStrength = getFloat(rd);
        let metalRough = getTextureInfo(rd);
        let hasPbr = getBool(rd);
        let hasMetallic = getBool(rd);
        let hasRoughness = getBool(rd);
        let metallicFactor = getOption(rd, () -> getFloat(rd));
        let roughnessFactor = getOption(rd, () -> getFloat(rd));
        { name = name, alphaMode = alphaMode, alphaCutoff = alphaCutoff, doubleSided = doubleSided,
          base = base, normal = normal, normalScale = normalScale, emissive = emissive,
          emissiveFactor = { r = er, g = eg, b = eb }, emissiveFactorError = emissiveFactorError,
          emissiveStrength = emissiveStrength, metalRough = metalRough, hasPbr = hasPbr, hasMetallic = hasMetallic,
          hasRoughness = hasRoughness, metallicFactor = metallicFactor, roughnessFactor = roughnessFactor }

    def alphaOfCode(code: Int32): Model3d.AlphaMode =
        if (code == 1) Model3d.AlphaMode.Mask else if (code == 2) Model3d.AlphaMode.Blend else Model3d.AlphaMode.Opaque

    def getImage(rd: Reader[r]): ImageSource \ r =
        let tag = getInt(rd);
        if (tag == 0) { let start = getInt(rd); ImageSource.InBin(start, getInt(rd)) }
        else if (tag == 1) ImageSource.Unreadable(getString(rd))
        else if (tag == 2) ImageSource.ExternalUri
        else ImageSource.NoSource
}
