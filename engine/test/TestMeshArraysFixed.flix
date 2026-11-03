// TestMeshArraysFixed — Mesh3d・Gltf の頂点の並びと Mip.build の全部の段の画素を、固定値（並びの SHA-256）で押さえる。
// 書き方を速くしても値が 1 bit も変わらないことを確かめる。contentHash は鍵の作り方で字が変わるので比べない。
mod TestMeshArraysFixed {

    // ── 指紋 ──────────────────────────────────────────────

    def digestOf(text: String): String = Util.Codec.encodeHex(Util.Checksum.sha256(String.toBytes(text)))

    def floats(v: Vector[Float64]): String = digestOf(Vector.join(",", v))

    def ints(v: Vector[Int32]): String = digestOf(Vector.join(",", v))

    /// 形の並びの名前と指紋（uv・タンジェント・スキンの無い形は "-"）。
    def meshPrints(label: String, m: Mesh3d.Mesh3d): List[(String, String)] =
        let b = Mesh3d.bounds(m);
        ("${label}.positions", floats(Mesh3d.positions(m))) ::
        ("${label}.normals", floats(Mesh3d.normals(m))) ::
        ("${label}.colors", floats(Mesh3d.colors(m))) ::
        ("${label}.indices", ints(Mesh3d.indices(m))) ::
        ("${label}.uvs", Mesh3d.uvs(m) |> Option.map(floats) |> Option.getWithDefault("-")) ::
        ("${label}.tangents", Mesh3d.tangents(m) |> Option.map(floats) |> Option.getWithDefault("-")) ::
        ("${label}.skinJoints", Mesh3d.skinJoints(m) |> Option.map(ints) |> Option.getWithDefault("-")) ::
        ("${label}.skinWeights", Mesh3d.skinWeights(m) |> Option.map(floats) |> Option.getWithDefault("-")) ::
        ("${label}.bounds", "${b#min#x},${b#min#y},${b#min#z},${b#max#x},${b#max#y},${b#max#z}") :: Nil

    def mipPrint(t: ShaderEval.TexData): String =
        digestOf(Mip.build(Mip.Average.Raw, t) |> List.map(l -> "${l#width}x${l#height}:${Vector.join(",", l#pixels)}") |> List.join("|"))

    // ── 素材 ──────────────────────────────────────────────

    def okOrBug(r: Result[String, a]): a = match r {
        case Ok(x)  => x
        case Err(e) => bug!(e)
    }

    /// 四角・五角形・三角（全部の頂点に vt）。負の番号と v/vt/vn の形を混ぜる。
    def objWithUvs(): String = String.unlines(
        "v 0 0 0" :: "v 1 0 0" :: "v 1 1 0" :: "v 0 1 0" :: "v 2 0 1" :: "v 3 0.5 1.5" :: "v 2.5 2 1" :: "v 1.5 1.5 0.5" :: "v 2 -1 2" ::
        "vt 0 0" :: "vt 1 0" :: "vt 1 1" :: "vt 0 1" :: "vt 0.25 0.75" ::
        "usemtl red" :: "f 1/1 2/2 3/3 4/4" :: "f 5/1/1 6/2/1 7/3/1 8/4/1 9/5/1" ::
        "usemtl blue" :: "f -1/-1 -3/-2 -5/-3" :: Nil)

    def mtl(): String = String.unlines("newmtl red" :: "Kd 0.8 0.1 0.1" :: "newmtl blue" :: "Kd 0.1 0.2 0.9" :: "newmtl plain" :: Nil)

    /// 斜めの面（箱投影で軸が混ざる）と vt の無い面。
    def objNoUvs(): String = String.unlines(
        "v 0 0 0" :: "v 1 0.2 0" :: "v 1.3 1 0.4" :: "v 0.1 1.1 0.9" :: "v -0.5 0.3 1.7" ::
        "usemtl plain" :: "f 1 2 3 4 5" :: "usemtl red" :: "f 1 3 5" :: "usemtl none" :: "f 2 4 5" :: Nil)

    def cube(): Mesh3d.Mesh3d =
        let p = (x: Float64, y: Float64, z: Float64) -> Vec3.v3(x, y, z);
        let face = (c: Color, pts: List[Vec3.Vec3]) -> { points = pts, color = c };
        Mesh3d.fromPolygons(
            face(Color.rgb(1.0, 0.0, 0.0), p(1.0, -1.0, -1.0) :: p(1.0, 1.0, -1.0) :: p(1.0, 1.0, 1.0) :: p(1.0, -1.0, 1.0) :: Nil) ::
            face(Color.rgb(0.0, 1.0, 0.0), p(-1.0, -1.0, 1.0) :: p(-1.0, 1.0, 1.0) :: p(-1.0, 1.0, -1.0) :: p(-1.0, -1.0, -1.0) :: Nil) ::
            face(Color.rgb(0.0, 0.0, 1.0), p(-1.0, 1.0, -1.0) :: p(-1.0, 1.0, 1.0) :: p(1.0, 1.0, 1.0) :: p(1.0, 1.0, -1.0) :: Nil) ::
            face(Color.rgb(0.5, 0.5, 0.0), p(-1.0, -1.0, 1.0) :: p(-1.0, -1.0, -1.0) :: p(1.0, -1.0, -1.0) :: p(1.0, -1.0, 1.0) :: Nil) ::
            face(Color.rgb(0.0, 0.5, 0.5), p(-1.0, -1.0, -1.0) :: p(-1.0, 1.0, -1.0) :: p(1.0, 1.0, -1.0) :: p(1.0, -1.0, -1.0) :: Nil) ::
            face(Color.rgb(0.5, 0.0, 0.5), p(1.0, -1.0, 1.0) :: p(1.0, 1.0, 1.0) :: p(-1.0, 1.0, 1.0) :: p(-1.0, -1.0, 1.0) :: Nil) ::
            { points = p(0.0, 0.0, 0.0) :: p(1.0, 1.0, 1.0) :: Nil, color = Color.rgb(1.0, 1.0, 1.0) } :: Nil)

    /// 頂点を面で共有する八面体（スキンつき）。箱投影で頂点が分かれ、スキンの欄も一緒に写る。
    def octahedron(): Mesh3d.Mesh3d =
        let positions = Vector#{ 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0 };
        let normals = positions;
        let colors = Vector.range(0, 18) |> Vector.map(i -> Int32.toFloat64(Int32.remainder(i * 7, 10)) / 10.0);
        let indices = Vector#{ 0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0, 4, 2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3, 5 };
        let joints = Vector.range(0, 24) |> Vector.map(i -> Int32.remainder(i, 3));
        let weights = Vector.range(0, 24) |> Vector.map(i -> Int32.toFloat64(Int32.remainder(i, 4) + 1));
        okOrBug(Mesh3d.fromArrays({ positions = positions, normals = normals, colors = colors, indices = indices,
                                    skin = Some({ joints = joints, weights = weights }) }))

    /// 決まった並びの擬似乱数で埋めた絵（線形合同法）。
    def noise(w: Int32, h: Int32, seed: Int32): ShaderEval.TexData =
        let step = (x: Int32) -> x * 1103515245 + 12345;
        let (_, revPixels) = List.range(0, w * h) |> List.foldLeft((acc, _) -> {
            let (s, out) = acc;
            let next = step(s);
            (next, next :: out)
        }, (seed, Nil));
        { width = w, height = h, pixels = List.toVector(List.reverse(revPixels)) }

    // ── 固定値 ──────────────────────────────────────────────

    /// 形の並びの指紋（全部の素材）。
    def meshCases(): List[(String, String)] =
        let withUvs = okOrBug(Mesh3d.fromObj(objWithUvs(), mtl()));
        let noUvs = okOrBug(Mesh3d.fromObj(objNoUvs(), mtl()));
        List.flatten(
            meshPrints("objUv", withUvs) :: meshPrints("objUvBox", Mesh3d.withBoxUvs(0.6, withUvs)) ::
            meshPrints("objPlain", noUvs) :: meshPrints("objPlainBox", Mesh3d.withBoxUvs(0.6, noUvs)) ::
            meshPrints("cube", cube()) :: meshPrints("cubeBox", Mesh3d.withBoxUvs(0.5, cube())) ::
            meshPrints("octa", octahedron()) :: meshPrints("octaBox", Mesh3d.withBoxUvs(1.0, octahedron())) :: Nil)

    /// glb の形の並びの指紋（mesh と parts）。
    def gltfCases(): List[(String, String)] \ Fs.FileRead + IO =
        let joints = okOrBug(Gltf.load("test/data/two_joints.glb"));
        let textured = okOrBug(Gltf.loadTexturedUsing(TestDecoder.imageIo(), Gltf.noTextureLimits(), "test/data/textured_two_materials.glb"));
        let partPrints = (label: String, m: Model3d.Model3d) ->
            m#parts |> List.zipWithIndex |> List.flatMap(pi -> { let (i, part) = pi; meshPrints("${label}.part${i}", part#mesh) });
        List.flatten(
            meshPrints("joints", joints#mesh) :: partPrints("joints", joints) ::
            meshPrints("textured", textured#mesh) :: partPrints("textured", textured) ::
            (textured#textures |> List.zipWithIndex |> List.map(ti -> { let (i, t) = ti; ("textured.texture${i}", ints(Texture3d.argb(t))) })) :: Nil)

    /// Mip.build の全部の段の画素の指紋。
    def mipCases(): List[(String, String)] =
        ("mip.4x4", mipPrint(noise(4, 4, 1))) :: ("mip.3x5", mipPrint(noise(3, 5, 2))) ::
        ("mip.1x7", mipPrint(noise(1, 7, 3))) :: ("mip.37x23", mipPrint(noise(37, 23, 4))) ::
        ("mip.64x64", mipPrint(noise(64, 64, 5))) :: Nil

    /// 直す前の実装で出した指紋（並びの名前 → 指紋）。
    def expected(): Map[String, String] = Map#{
        "objUv.positions" => "0311d7b4b9b97f652acb3eb554f9de9df1fd269d097fea7f920293c7955d1464",
        "objUv.normals" => "0a9cf92e74586991de72ca49f9799fb954490ae1b96eaadf7da050453bdf0aeb",
        "objUv.colors" => "e500e7ed6470d911eaac477bfed7a8f8f0d3f5411b7df34bf477b655bb9ea86d",
        "objUv.indices" => "a23f83f7c25d03024eb06d4aa1215f323f67624a320daa945ad65ab4d57d8fc3",
        "objUv.uvs" => "c5099f8029002c9bf2d33a96c35d57b7cedcc76013fa44a7abb02ba1fa53106a",
        "objUv.tangents" => "1402334bbe2b28f072a6d5af2f417289f3e472f397f7a1c36fc0de39944f392d",
        "objUv.skinJoints" => "-",
        "objUv.skinWeights" => "-",
        "objUv.bounds" => "0.0,-1.0,0.0,3.0,2.0,2.0",
        "objUvBox.positions" => "dfa939f703cb126e4401999c99f7d5d8643ec1c6007daf5fc454a9cc917a9dde",
        "objUvBox.normals" => "ad3d7a9d313ef2c35abd09830fbb88fc994238468cb43364c458458bff9c962e",
        "objUvBox.colors" => "cce7d3802d5441555c435e1b00cccf8575206d8b713e2c3183bb1b55e0931751",
        "objUvBox.indices" => "99d7861f2889623dde75f475b64c6a76ae4a33e28d3147b7d1ff3655a2617978",
        "objUvBox.uvs" => "f551d0d89550fd46228dd4980640e3d2ed0916252489cc0cb83fc92003884a79",
        "objUvBox.tangents" => "b611e9fba607b55a330f76c0b6638c53367ddc550a062e176c6b3144b99c093e",
        "objUvBox.skinJoints" => "-",
        "objUvBox.skinWeights" => "-",
        "objUvBox.bounds" => "0.0,-1.0,0.0,3.0,2.0,2.0",
        "objPlain.positions" => "d6c2ecb50a97a3a54f2929a5231f47a62c5d8d96eeeeaf35990384c2edbe809f",
        "objPlain.normals" => "d6ab62f0facb5201a2df93e263f646d3a608dd8c3f7af95b2fb36bf1ec2dd19b",
        "objPlain.colors" => "e6809dae6d9c09da423072bb9f7b9c282a4ec70dbd5e427c33c0803e22f785c6",
        "objPlain.indices" => "bedffb2b1712d8c083baa86e94e4cb34a7617bfde87bb52c74af8bbb4972f5c1",
        "objPlain.uvs" => "-",
        "objPlain.tangents" => "-",
        "objPlain.skinJoints" => "-",
        "objPlain.skinWeights" => "-",
        "objPlain.bounds" => "-0.5,0.0,0.0,1.3,1.1,1.7",
        "objPlainBox.positions" => "e148b14e97a44c56adead81bf6f5b3ee21a36b93e93e4ebda9705cc5e9e207f9",
        "objPlainBox.normals" => "11654ceaa4d54e26f3476fdda43d784480e44eabcabf380cfe553482957baae7",
        "objPlainBox.colors" => "7882261dad22e0112de960e1d3486041528a2c3e28fbc962ee27cb606e831b90",
        "objPlainBox.indices" => "7901e2c4bf2ba1d8b436a6297e685e1377f6258003bba4ba1438be2f7e1009cb",
        "objPlainBox.uvs" => "055549736641d2937ab48c91f61157c455842506de9f0dfc4585122ab9e4c811",
        "objPlainBox.tangents" => "ab294a351d76cd5c67c6049c00c3544159d8cf36467f861938f81602a51c06a4",
        "objPlainBox.skinJoints" => "-",
        "objPlainBox.skinWeights" => "-",
        "objPlainBox.bounds" => "-0.5,0.0,0.0,1.3,1.1,1.7",
        "cube.positions" => "8d23a0feaa68ae1d1cbbd39ca8c1a88697e24bd69639d1d71591e4ff118c5b44",
        "cube.normals" => "ab9dc632cf2deeb1186de834ac902833923a97857bb736bea5642f5f60637790",
        "cube.colors" => "59c59e86e65a23eb06a1fadc0ca16a62183c538f51f2f999e5586780a2de7b1e",
        "cube.indices" => "6c0e6fff826fe04d3836ea85df968f06e6cfd079402156425ca424712a3b246d",
        "cube.uvs" => "-",
        "cube.tangents" => "-",
        "cube.skinJoints" => "-",
        "cube.skinWeights" => "-",
        "cube.bounds" => "-1.0,-1.0,-1.0,1.0,1.0,1.0",
        "cubeBox.positions" => "8d23a0feaa68ae1d1cbbd39ca8c1a88697e24bd69639d1d71591e4ff118c5b44",
        "cubeBox.normals" => "ab9dc632cf2deeb1186de834ac902833923a97857bb736bea5642f5f60637790",
        "cubeBox.colors" => "59c59e86e65a23eb06a1fadc0ca16a62183c538f51f2f999e5586780a2de7b1e",
        "cubeBox.indices" => "6c0e6fff826fe04d3836ea85df968f06e6cfd079402156425ca424712a3b246d",
        "cubeBox.uvs" => "f6fc37b3106a676b72057abbc7611200f2e21730185059c1c7ddbc4d7e5a62cb",
        "cubeBox.tangents" => "36339659c64757a016cf28b19b969f0dae7100b4bb9528abd3c0c06f72e58ed3",
        "cubeBox.skinJoints" => "-",
        "cubeBox.skinWeights" => "-",
        "cubeBox.bounds" => "-1.0,-1.0,-1.0,1.0,1.0,1.0",
        "octa.positions" => "2a26e70983956bcc817cfbe0471e3be26d1c971b2d3387f91e98eb6fcf70c16e",
        "octa.normals" => "2a26e70983956bcc817cfbe0471e3be26d1c971b2d3387f91e98eb6fcf70c16e",
        "octa.colors" => "5c56f858cc8fdfa04f2f550cc4854bd8731e56c91027cc1efdf44ff3433559d5",
        "octa.indices" => "b373ce8c8d2f4f2f62f73a98f1c4ba6263fd4b21ad4d521c25076c9ed48a195c",
        "octa.uvs" => "-",
        "octa.tangents" => "-",
        "octa.skinJoints" => "f24e695632e6af2e25eafd5c2affa9d3d5d52e5580eb3a0e6dcfa6a001cf2c7d",
        "octa.skinWeights" => "7fcff4e553f8c5eb8b87e616bd0aab0e37d818030278c62c6a5add64b336641c",
        "octa.bounds" => "-1.0,-1.0,-1.0,1.0,1.0,1.0",
        "octaBox.positions" => "033d8968531271d9d957e0f29bfad7d80c9158746fa72994eb64179bf5e02d27",
        "octaBox.normals" => "033d8968531271d9d957e0f29bfad7d80c9158746fa72994eb64179bf5e02d27",
        "octaBox.colors" => "693118c2d6c40a13c945b3791a3748f7b4df9b00f6814d33f0728ef23d405f98",
        "octaBox.indices" => "024f4491c92af76cc907e054891401477cc15195b4b45a32fd3341dd89fa5a93",
        "octaBox.uvs" => "ab2b33d08cce128d35cf37c56bd4f2d4677963fbd17444c425e63b9a239ac421",
        "octaBox.tangents" => "d698497786a539b2c5859118cb39de6a8621655047a3d5ae7572c0280492e6e1",
        "octaBox.skinJoints" => "a02a2837ec132119ef4d4a69b14197994cfa92e01b1721f41677a6273bfb3602",
        "octaBox.skinWeights" => "2fb081c6462a820d44b5737f08c0fba82e97038588124679e73344e24872c725",
        "octaBox.bounds" => "-1.0,-1.0,-1.0,1.0,1.0,1.0",
        "joints.positions" => "74768732a62c97b6a10fb228d89b0bf0a331fe6bdbc403d111059a26e26d4550",
        "joints.normals" => "61575e6db8d14a873bcfff37affcfa3da8ea82c18ff05f1bfe7af7f4ebde1c09",
        "joints.colors" => "4a829ce6dd6adcae9f204e3d30af22b5fff21fa8f8580734828f82489cfb1c4a",
        "joints.indices" => "be7140894d4ec09bfa9345fa9c7dce6f7159048ea71cf2203e42c14bca58695d",
        "joints.uvs" => "-",
        "joints.tangents" => "-",
        "joints.skinJoints" => "707b82dc020a9afaa1fc4269691e6ea4ac40e048714a78cd8428098ac30da98b",
        "joints.skinWeights" => "94287d48123b7b5032c978cf2073e7a378a7626600ca54d04262670f5564f48e",
        "joints.bounds" => "-0.10000000149011612,0.0,0.0,0.10000000149011612,1.0,0.0",
        "joints.part0.positions" => "74768732a62c97b6a10fb228d89b0bf0a331fe6bdbc403d111059a26e26d4550",
        "joints.part0.normals" => "61575e6db8d14a873bcfff37affcfa3da8ea82c18ff05f1bfe7af7f4ebde1c09",
        "joints.part0.colors" => "4a829ce6dd6adcae9f204e3d30af22b5fff21fa8f8580734828f82489cfb1c4a",
        "joints.part0.indices" => "be7140894d4ec09bfa9345fa9c7dce6f7159048ea71cf2203e42c14bca58695d",
        "joints.part0.uvs" => "-",
        "joints.part0.tangents" => "-",
        "joints.part0.skinJoints" => "707b82dc020a9afaa1fc4269691e6ea4ac40e048714a78cd8428098ac30da98b",
        "joints.part0.skinWeights" => "94287d48123b7b5032c978cf2073e7a378a7626600ca54d04262670f5564f48e",
        "joints.part0.bounds" => "-0.10000000149011612,0.0,0.0,0.10000000149011612,1.0,0.0",
        "textured.positions" => "64b8c1ec36ef7e6ca09687aded4190beef9984ec40c4e1959209c818e15ebc4e",
        "textured.normals" => "12c251ada3e0e3dc3dcf3fb19e3a414d548aaaa9caaab2ebd807203100e49487",
        "textured.colors" => "19f625215cbcba8bc432974ce4bd756f877eeec944d8fe5875cc787684d1583a",
        "textured.indices" => "b8657fcf0810fbf68bbf5bfce8c03b3882b51a09c574092a0f355eb6556458d3",
        "textured.uvs" => "-",
        "textured.tangents" => "-",
        "textured.skinJoints" => "-",
        "textured.skinWeights" => "-",
        "textured.bounds" => "-1.5,0.0,0.0,1.5,1.0,0.0",
        "textured.part0.positions" => "6948066744e370066a39f0dc805bb9ec5ffca8d2feb68c6e364ed37c17fb2859",
        "textured.part0.normals" => "61575e6db8d14a873bcfff37affcfa3da8ea82c18ff05f1bfe7af7f4ebde1c09",
        "textured.part0.colors" => "4a829ce6dd6adcae9f204e3d30af22b5fff21fa8f8580734828f82489cfb1c4a",
        "textured.part0.indices" => "be7140894d4ec09bfa9345fa9c7dce6f7159048ea71cf2203e42c14bca58695d",
        "textured.part0.uvs" => "89f7739f78a8fd596f5e103b433e82af3f1fdc3242970b4c4076b0c74a548cdc",
        "textured.part0.tangents" => "7f1c2143c043574553c735831c319a264e438f29597d4920d4d75397ff5b750d",
        "textured.part0.skinJoints" => "-",
        "textured.part0.skinWeights" => "-",
        "textured.part0.bounds" => "0.5,0.0,0.0,1.5,1.0,0.0",
        "textured.part1.positions" => "d3fe82cd78a46bade48d930b5057e4b4e6c7873347548a8f3cef126b12a2bd69",
        "textured.part1.normals" => "61575e6db8d14a873bcfff37affcfa3da8ea82c18ff05f1bfe7af7f4ebde1c09",
        "textured.part1.colors" => "3c672697e928d4ead7a4d915e9570e51eab8a9a960c1623ca604b0ce8e840c58",
        "textured.part1.indices" => "be7140894d4ec09bfa9345fa9c7dce6f7159048ea71cf2203e42c14bca58695d",
        "textured.part1.uvs" => "89f7739f78a8fd596f5e103b433e82af3f1fdc3242970b4c4076b0c74a548cdc",
        "textured.part1.tangents" => "7f1c2143c043574553c735831c319a264e438f29597d4920d4d75397ff5b750d",
        "textured.part1.skinJoints" => "-",
        "textured.part1.skinWeights" => "-",
        "textured.part1.bounds" => "-1.5,0.0,0.0,-0.5,1.0,0.0",
        "textured.texture0" => "b7a2355c35201c3eff55b9705917e86c76692fddec11209289b6c80d8ba60916",
        "textured.texture1" => "a1bb6e75e816460f0cf06939833cabc45f135ee317d6a7f4420537ecf46c9ecb",
        "mip.4x4" => "5cad60891e3dd48b287d56766e16a4e494eaf6c14222574a29aa593d4e6c0f17",
        "mip.3x5" => "a3302209377abcba924d6bbb2b4c84f2e005681441336eb5df00754d99c900db",
        "mip.1x7" => "13caedf56dbd89bce1cdf4e1e284ec2d05fe96ad89b816153e0b351e12f0a5e8",
        "mip.37x23" => "22f09dd0270589fd3f7b0b1035ec11eeb1bdaafa41c50e0fd1900dc12c2efbb5",
        "mip.64x64" => "163dfe6231c724d59ebd4dcaf31fe2d217bd1e8e3299baecdda4834984256db3"
    }

    /// 指紋が固定値と違う並びの名前（固定値に無い名前も含む）。
    def mismatches(actual: List[(String, String)]): List[String] =
        let table = expected();
        actual |> List.filter(kv -> Map.get(fst(kv), table) != Some(snd(kv))) |> List.map(fst)

    /// OBJ・多角形・頂点の並びから作った形と、その箱投影の uv の並びが固定値と同じ。
    @Test
    def testMeshArraysMatchFixedValues(): Unit \ Assert =
        Assert.assertEq(expected = Nil, mismatches(meshCases()))

    /// glb から読んだ形（mesh と parts）と絵の画素が固定値と同じ。
    @Test
    def testGltfArraysMatchFixedValues(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = Nil, mismatches(gltfCases()))

    /// Mip.build の全部の段の寸法と画素が固定値と同じ。
    @Test
    def testMipLevelsMatchFixedValues(): Unit \ Assert =
        Assert.assertEq(expected = Nil, mismatches(mipCases()))
}
