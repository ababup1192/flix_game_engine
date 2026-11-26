// ShaderBake — ブラウザ版の書き出し（bin/fge export-web）が流す道具。ゲームの記録（web/shader-variants.json）から、3D の描き手のシェーダーの字の表を作る。
// 字は PC の描き手と同じ関数（Render3dShaders.makeRuntimeProvider）で作るので、作る道の違いで字はずれない。
// 環境変数 FGE_SHADER_BAKE_VARIANTS = 記録の道（無いファイルは空の記録 = 既定の一式だけ）・FGE_SHADER_BAKE_OUT = 表の JSON を書く道。
// 表は { "<言語>:<鍵の字>": 字 } の 1 つの object（鍵の字は Render3d.ShaderSourceKey.toKeyString）。
mod ShaderBake {
    import java.nio.file.Files
    import java.nio.file.Path
    import java.lang.System
    use Util.Json.Json.{JObject, JString}

    def main(): Unit \ IO =
        let env = run { Sys.Env.getEnv() } with Sys.Env.runWithIO;
        match (Map.get("FGE_SHADER_BAKE_VARIANTS", env), Map.get("FGE_SHADER_BAKE_OUT", env)) {
            case (Some(input), Some(output)) => bake(input, output)
            case _ =>
                System.exit(Log.warnThen("使い方: FGE_SHADER_BAKE_VARIANTS=<web/shader-variants.json> FGE_SHADER_BAKE_OUT=<表.json> java -jar shader-bake.jar", 2))
        }

    def bake(input: String, output: String): Unit \ IO = match Render3d.ShaderLibrary.loadCollection(input) {
        case Err(e) =>
            System.exit(Log.warnThen("shader-bake: ${e}", 1))
        case Ok(collection) =>
            let table = Render3d.ShaderLibrary.bakeTableOf(Render3dShaders.makeRuntimeProvider(), collection);
            let json = JObject(table |> List.map(kt -> (fst(kt), JString(snd(kt)))) |> List.toMap);
            discard Files.writeString(Path.of(output), Util.Json.toPrettyString(0, json));
            let chars = table |> List.foldLeft((acc, kt) -> acc + String.length(snd(kt)), 0);
            println("shader-bake ${List.length(table)} ${chars}")
    }
}
