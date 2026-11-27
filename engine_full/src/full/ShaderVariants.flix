// ShaderVariants — ブラウザ版を出す 3D のゲームのテストが、シェーダーの記録（web/shader-variants.json）の漏れを確かめる入口。
// 書き出し（bin/fge export-web）は記録の分だけシェーダーの字を作るので、記録に無い場面の物はブラウザで描かれない。
// 記録は fge run・fge debug で遊ぶと 3D の描き手が書き足す。遊んでいない場面の漏れは、描き出しの場面を集めてここで確かめる。
//
// ゲームに置く形（test/TestShaderVariants.flix）:
//   let scenes = SceneRender.shaderScenes();
//   ShaderVariants.recordFromEnv(scenes);
//   Assert.assertEq(expected = Nil, ShaderVariants.missingFrom("web/shader-variants.json", scenes))
pub mod ShaderVariants {

    /// 場面 scenes を描く時に使う鍵のうち、記録 path に無い物の名前（全部あれば Nil）。記録が読めなければ理由の 1 行。
    pub def missingFrom(path: String, scenes: List[Scene3d.Scene3dCmd]): List[String] \ IO =
        let used = keysOf(scenes);
        match Render3d.ShaderLibrary.loadCollection(path) {
            case Err(e)       => e :: Nil
            case Ok(recorded) => missing(recorded#variants, used#variants, "変種") ::: missing(recorded#materialShapes, used#materialShapes, "材質の形")
        }

    /// 環境変数 FLIX_GE_SHADER_VARIANTS（記録の道）があれば、場面 scenes を描く時に使う鍵をその記録へ書き足す（無ければ何もしない）。
    pub def recordFromEnv(scenes: List[Scene3d.Scene3dCmd]): Unit \ IO =
        let env = run { Sys.Env.getEnv() } with Sys.Env.runWithIO;
        match Map.get("FLIX_GE_SHADER_VARIANTS", env) |> Option.filter(p -> not String.isEmpty(p)) {
            case None       => ()
            case Some(path) => match Render3d.ShaderLibrary.recordTo(path, keysOf(scenes)) {
                case Ok(_)  => ()
                case Err(e) => Log.fellBack("shader", path, "書かない", e)
            }
        }

    def keysOf(scenes: List[Scene3d.Scene3dCmd]): Render3d.ShaderLibrary.CollectionKeys =
        scenes |> List.foldLeft((acc, s) -> Render3d.ShaderLibrary.unionCollection(acc, Render3d.ShaderLibrary.collectionKeysOf(s)),
                                Render3d.ShaderLibrary.emptyCollection())

    def missing(have: Map[String, a], want: Map[String, b], label: String): List[String] =
        Map.keysOf(want) |> Set.toList |> List.filter(k -> not Map.memberOf(k, have)) |> List.map(k -> "${label} ${k}")
}
