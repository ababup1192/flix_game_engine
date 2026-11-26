// ProjectLoader.Internal — project.json の一部だけを、project.json を持たない所（ブラウザの glb の Web Worker）で読む口。

/// ProjectLoader の中身。ゲームからは呼ばない。
pub mod ProjectLoader.Internal {

    /// project.json の "gltf" の値の JSON の字（無ければ空の字）を Gltf.LoadOptions にする（読み方は Model3d.loader と同じ）。
    pub def gltfOptionsOf(text: String): Result[String, Gltf.LoadOptions] =
        if (String.isEmpty(String.trim(text))) Ok(Gltf.defaultLoadOptions())
        else match Util.Json.parse(text) {
            case Ok(json) => ProjectLoader.readGltf(Map#{ "gltf" => json }) |> Result.mapErr(e -> ToString.toString(e))
            case Err(e)   => Err("gltf が JSON として読めない（${e}）")
        }
}
