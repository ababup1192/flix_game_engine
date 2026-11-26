// ShaderVariants — ブラウザ版を出す 3D のゲームのテストが、シェーダーの記録（web/shader-variants.json）の漏れを確かめる入口。
// 書き出し（bin/fge export-web）は記録の分だけシェーダーの字を作るので、記録に無い場面の物はブラウザで描かれない。
// 記録は fge run・fge debug で遊ぶと 3D の描き手が書き足す。遊んでいない場面の漏れは、描き出しの場面を集めてここで確かめる。
//
// ゲームに置く形（test/TestShaderVariants.flix）:
//   Assert.assertEq(expected = Nil, ShaderVariants.missingFrom("web/shader-variants.json", SceneRender.shaderScenes()))
pub mod ShaderVariants {

    /// 場面 scenes を描く時に使う鍵のうち、記録 path に無い物の名前（全部あれば Nil・記録が無ければ全部）。
    /// 環境変数 FLIX_GE_SHADER_VARIANTS（記録の道）があれば、先にその記録へ書き足す。
    pub def missingFrom(path: String, scenes: List[Scene3d.Scene3dCmd]): List[String] \ IO =
        let used = scenes |> List.foldLeft((acc, s) -> Render3d.ShaderLibrary.unionCollection(acc, Render3d.ShaderLibrary.collectionKeysOf(s)),
                                           Render3d.ShaderLibrary.emptyCollection());
        let recording = Render3d.ShaderLibrary.recordingFromEnv(Render3dShaders.makeRuntimeProvider());
        recording#record(used);
        let recorded = Render3d.ShaderLibrary.loadCollection(path) |> Result.getWithDefault(Render3d.ShaderLibrary.emptyCollection());
        missing(recorded#variants, used#variants, "変種") ::: missing(recorded#materialShapes, used#materialShapes, "材質の形")

    def missing(have: Map[String, a], want: Map[String, b], label: String): List[String] =
        Map.keysOf(want) |> Set.toList |> List.filter(k -> not Map.memberOf(k, have)) |> List.map(k -> "${label} ${k}")
}
