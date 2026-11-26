// TestGltfPreparsed — glb の parse を並びにして戻した物（Gltf.Internal.Codec）が、戻す前と欄ごとに同じで、
// 戻した物から組んだ Model3d と出した知らせが Gltf.decodeWith と同じ。
mod TestGltfPreparsed {
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System

    def options(): Gltf.LoadOptions = { limits = Gltf.noTextureLimits(), pbr = true, vertexColors = true }

    def bytesOf(path: String): Vector[Int8] \ Fs.FileRead =
        Fs.FileRead.readBytes(path) |> Result.getWithDefault(Vector.empty())

    def parsedOf(bytes: Vector[Int8]): Gltf.Internal.Parse.Parsed =
        match Gltf.Internal.Parse.parse(Gltf.Internal.Parse.readOptionsOf(options()), bytes) {
            case Ok(p)  => p
            case Err(e) => bug!(e)
        }

    def roundTrip(p: Gltf.Internal.Parse.Parsed): Gltf.Internal.Parse.Parsed =
        match Gltf.Internal.Codec.deserialize(Gltf.Internal.Codec.serialize(p)) {
            case Ok(q)  => q
            case Err(e) => bug!(e)
        }

    def same(name: String, x: Bool): List[String] = if (x) Nil else name :: Nil

    /// 形の欄の名前のうち、a と b で違う物。
    def meshDifferences(label: String, a: Mesh3d.Mesh3d, b: Mesh3d.Mesh3d): List[String] =
        List.flatten(
            same("${label}.positions", Mesh3d.positions(a) == Mesh3d.positions(b)) ::
            same("${label}.normals", Mesh3d.normals(a) == Mesh3d.normals(b)) ::
            same("${label}.colors", Mesh3d.colors(a) == Mesh3d.colors(b)) ::
            same("${label}.indices", Mesh3d.indices(a) == Mesh3d.indices(b)) ::
            same("${label}.uvs", Mesh3d.uvs(a) == Mesh3d.uvs(b)) ::
            same("${label}.uvs2", Mesh3d.uvs2(a) == Mesh3d.uvs2(b)) ::
            same("${label}.tangents", Mesh3d.tangents(a) == Mesh3d.tangents(b)) ::
            same("${label}.skinJoints", Mesh3d.skinJoints(a) == Mesh3d.skinJoints(b)) ::
            same("${label}.skinWeights", Mesh3d.skinWeights(a) == Mesh3d.skinWeights(b)) ::
            same("${label}.maxSkinJoint", Mesh3d.maxSkinJoint(a) == Mesh3d.maxSkinJoint(b)) ::
            same("${label}.bounds", boundsKey(Mesh3d.bounds(a)) == boundsKey(Mesh3d.bounds(b))) ::
            same("${label}.contentHash", Mesh3d.contentHash(a) == Mesh3d.contentHash(b)) :: Nil)

    def vec3Key(v: Vec3.Vec3): String = "${v#x},${v#y},${v#z}"

    def boundsKey(b: Mesh3d.Bounds): String = "${vec3Key(b#min)}/${vec3Key(b#max)}"

    def poseKey(p: Skin3d.JointPose): String =
        "${vec3Key(p#translation)}/${p#rotation#x},${p#rotation#y},${p#rotation#z},${p#rotation#w}/${vec3Key(p#scale)}"

    def matKey(m: Mat4.Mat4): String = ToString.toString(Mat4.toColumns(m))

    def nodeKey(n: Model3d.ModelNode): String =
        "${n#name}|${n#parent}|${matKey(n#local)}|${matKey(n#world)}|${Option.map(boundsKey, n#localBounds)}|${n#parts}"

    def skinKey(s: Skin3d.Skin3d): String =
        "${Skin3d.names(s)}|${Skin3d.parents(s)}|${Vector.map(poseKey, Skin3d.restPose(s))}|${Vector.map(matKey, Skin3d.inverseBinds(s))}|${matKey(Skin3d.rootTransform(s))}"

    /// クリップの名前・長さと、頭から終わりまで 7 か所で取った姿勢。
    def clipKey(skin: Option[Skin3d.Skin3d], clips: Map[String, AnimationClip3d.AnimationClip3d]): String =
        Map.toList(clips) |> List.map(entry -> {
            let (name, clip) = entry;
            let d = AnimationClip3d.duration(clip);
            let poses = skin |> Option.map(s -> List.range(0, 7) |> List.map(k ->
                Vector.map(poseKey, AnimationClip3d.sample(s, clip, d * Int32.toFloat64(k) / 6.0, false)))) |> Option.getWithDefault(Nil);
            "${name}|${d}|${poses}"
        }) |> ToString.toString

    def textureInfoKey(t: Gltf.Internal.Parse.TextureInfo): String =
        "${t#index},${t#texCoord},${t#transform},${t#source},${t#nearest},${t#clamp},${t#mirrored}"

    def materialSpecKey(m: Gltf.Internal.Parse.MaterialSpec): String =
        "${m#name}|${m#alphaMode}|${m#alphaCutoff}|${m#doubleSided}|${textureInfoKey(m#base)}|${textureInfoKey(m#normal)}|${m#normalScale}|" +
        "${textureInfoKey(m#emissive)}|${m#emissiveFactor#r},${m#emissiveFactor#g},${m#emissiveFactor#b}|${m#emissiveFactorError}|${m#emissiveStrength}|" +
        "${textureInfoKey(m#metalRough)}|${m#hasPbr}|${m#hasMetallic}|${m#hasRoughness}|${m#metallicFactor}|${m#roughnessFactor}"

    def materialKey(m: Option[Scene3d.Material3d]): Option[String] = m |> Option.map(mat -> {
        let f = Scene3d.materialFieldsOf(mat);
        let normal = f#normalMap |> Option.map(n -> "${n#texture},${n#strength}");
        let metal = f#metallicRoughness |> Option.map(r -> "${r#metallic},${r#roughness},${r#texture}");
        "${force f#shaderHash}|${f#spec#name}|${f#params}|${f#cutout}|${f#wrap == Scene3d.Wrap.Clamp}|${f#blend}|${f#doubleSided}|" +
        "${f#emissionIntensity}|${normal}|${metal}|${f#maxMipLevels}|${force f#texReads |> List.map(fst)}"
    })

    def gltfMaterialKey(m: Option[Model3d.GltfMaterial]): Option[String] = m |> Option.map(g ->
        "${g#name}|${g#alphaMode}|${g#alphaCutoff}|${g#doubleSided}|${g#baseColorTexture}|${g#normalTexture}|${g#emissiveTexture}|" +
        "${g#emissive#r},${g#emissive#g},${g#emissive#b}|${g#metallic}|${g#roughness}|${g#metallicRoughnessTexture}")

    /// parse の結果 a と b の欄のうち違う物の名前。
    def parsedDifferences(a: Gltf.Internal.Parse.Parsed, b: Gltf.Internal.Parse.Parsed): List[String] =
        let parts = List.zip(a#parts, b#parts) |> List.mapWithIndex((k, pq) -> {
            let (p, q) = pq;
            List.append(same("part${k}.meta", p#node == q#node and p#material == q#material and p#givenTangents == q#givenTangents),
                        meshDifferences("part${k}", p#mesh, q#mesh))
        }) |> List.flatten;
        List.flatten(
            same("partCount", List.length(a#parts) == List.length(b#parts)) :: parts ::
            meshDifferences("mesh", a#mesh, b#mesh) ::
            same("skin", Option.map(skinKey, a#skin) == Option.map(skinKey, b#skin)) ::
            same("clips", clipKey(a#skin, a#clips) == clipKey(b#skin, b#clips)) ::
            same("nodes", List.map(nodeKey, a#nodes) == List.map(nodeKey, b#nodes)) ::
            same("materials", Vector.map(materialSpecKey, a#materials) == Vector.map(materialSpecKey, b#materials)) ::
            same("images", a#images == b#images) ::
            same("lines", a#lines == b#lines) ::
            same("droppedLines", a#droppedLines == b#droppedLines) ::
            same("read", (a#read#pbr, a#read#vertexColors) == (b#read#pbr, b#read#vertexColors)) :: Nil)

    /// 組んだ Model3d a と b の欄のうち違う物の名前。
    def modelDifferences(a: Model3d.Model3d, b: Model3d.Model3d): List[String] =
        let parts = List.zip(a#parts, b#parts) |> List.mapWithIndex((k, pq) -> {
            let (p, q) = pq;
            let meta = materialKey(p#material) == materialKey(q#material) and gltfMaterialKey(p#gltfMaterial) == gltfMaterialKey(q#gltfMaterial) and p#node == q#node;
            List.append(same("part${k}.material", meta), meshDifferences("part${k}", p#mesh, q#mesh))
        }) |> List.flatten;
        List.flatten(
            same("partCount", List.length(a#parts) == List.length(b#parts)) :: parts ::
            meshDifferences("mesh", a#mesh, b#mesh) ::
            same("skin", Option.map(skinKey, a#skin) == Option.map(skinKey, b#skin)) ::
            same("clips", clipKey(a#skin, a#clips) == clipKey(b#skin, b#clips)) ::
            same("textures", List.map(Texture3d.name, a#textures) == List.map(Texture3d.name, b#textures)) ::
            same("nodes", List.map(nodeKey, a#nodes) == List.map(nodeKey, b#nodes)) :: Nil)

    /// f を呼ぶ間に stderr へ出た字と f の値。
    // WhyNot: 引数無しの純粋な式を渡さない — Flix は純粋な式を stderr の差し替えより前へ動かせる（TestGltf.loadSkinned と同じ）。
    def captured(bytes: Vector[Int8], f: Vector[Int8] -> a \ IO): (a, String) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let v = f(Vector.drop(buf.size(), bytes));
        System.setErr(old);
        (v, buf.toString())

    /// 並びにして戻した物から組んだ Model3d と知らせが、decodeWith と同じか（違う欄の名前）。
    def assembledDifferences(key: Option[String], bytes: Vector[Int8]): List[String] \ IO =
        let decoder = TestDecoder.imageIo();
        let (direct, directLog) = captured(bytes, b -> Gltf.decodeWith(decoder, options(), key, b));
        let (carried, carriedLog) = captured(bytes, b -> Gltf.Internal.assemble(decoder, options(), key, b, roundTrip(parsedOf(b))));
        match direct {
            case Ok(m)  => List.append(modelDifferences(m, carried), same("log", directLog == carriedLog))
            case Err(e) => "decodeWith: ${e}" :: Nil
        }

    @Test
    def testRoundTripKeepsTexturedModel(): Unit \ {Assert, Fs.FileRead} =
        let p = parsedOf(bytesOf("test/data/textured_two_materials.glb"));
        Assert.assertEq(expected = Nil, parsedDifferences(p, roundTrip(p)))

    @Test
    def testRoundTripKeepsSkinnedModel(): Unit \ {Assert, Fs.FileRead} =
        let p = parsedOf(bytesOf("test/data/two_joints.glb"));
        Assert.assertEq(expected = Nil, parsedDifferences(p, roundTrip(p)))

    @Test
    def testRoundTripKeepsEmissiveModel(): Unit \ {Assert, Fs.FileRead} =
        let p = parsedOf(bytesOf("test/data/testdata/emissive_plates.glb"));
        Assert.assertEq(expected = Nil, parsedDifferences(p, roundTrip(p)))

    @Test
    def testRoundTripKeepsCubicSplineAndDroppedLines(): Unit \ Assert =
        let p = parsedOf(TestGltf.skinnedGlb());
        Assert.assertEq(expected = Nil, parsedDifferences(p, roundTrip(p)))

    @Test
    def testRoundTripKeepsUnreadableUvLines(): Unit \ Assert =
        let p = parsedOf(TestGltf.triangleWithUvsGlb(0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil));
        Assert.assertEq(expected = Nil, parsedDifferences(p, roundTrip(p)))

    @Test
    def testAssembledTexturedMatchesDecodeWith(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = Nil, assembledDifferences(None, bytesOf("test/data/textured_two_materials.glb")))

    @Test
    def testAssembledKeyedTexturedMatchesDecodeWith(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = Nil, assembledDifferences(Some("props.glb@1"), bytesOf("test/data/textured_two_materials.glb")))

    @Test
    def testAssembledSkinnedMatchesDecodeWith(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = Nil, assembledDifferences(None, bytesOf("test/data/two_joints.glb")))

    @Test
    def testAssembledEmissiveMatchesDecodeWith(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = Nil, assembledDifferences(None, bytesOf("test/data/testdata/emissive_plates.glb")))

    @Test
    def testAssembledWarningsMatchDecodeWith(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Nil, assembledDifferences(None, TestGltf.skinnedGlb()))

    @Test
    def testBrokenWireIsErr(): Unit \ Assert =
        let wire = Gltf.Internal.Codec.serialize(parsedOf(TestGltf.skinnedGlb()));
        Assert.assertTrue(Result.isErr(Gltf.Internal.Codec.deserialize({ ints = Vector.drop(1, wire#ints) | wire })))
}
