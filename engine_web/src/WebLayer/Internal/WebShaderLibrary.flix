// WebLayer.Internal.WebShaderLibrary — ブラウザの 3D の描き手がシェーダーの字を引く表（書き出しの時に shader-bake が作り、fge.web.ShaderLibraryData へ埋めた物）。
// 表に無い鍵の扱い（既定の一式は止める・記録に依る物は描かずに知らせる）は Render3d.ShaderLibrary。
pub mod WebLayer.Internal.WebShaderLibrary {
    import fge.web.ShaderLibraryData

    /// 埋めた表を引く API（描き手を作る時に 1 回だけ表を読む）。
    pub def provider(): Render3d.ShaderSourceProvider \ IO = Render3d.ShaderLibrary.providerOfTable(tableOf(ShaderLibraryData.table()))

    /// 表 table（[鍵, 切れ端の数, 切れ端…] の繰り返し）の 鍵 → 字。
    def tableOf(table: Array[String, Static]): Map[String, String] \ IO =
        let n = Array.length(table);
        def go(i, acc) =
            if (i + 1 >= n) acc
            else {
                let count = countOrBug(Array.get(i + 1, table));
                let text = List.range(i + 2, i + 2 + count) |> List.map(j -> Array.get(j, table)) |> String.flatten;
                go(i + 2 + count, Map.insert(Array.get(i, table), text, acc))
            };
        go(0, Map.empty())

    /// 表の切れ端の数の字（書き出しの道具 ShaderEmbed が書く。数でないのは道具と読み手の約束が破れた所なので止める）。
    def countOrBug(text: String): Int32 = match Int32.fromString(text) {
        case Some(n) => n
        case None    => bug!("WebLayer.Internal.WebShaderLibrary: シェーダーの表の切れ端の数 '${text}' が数でない（ShaderEmbed と食い違い）")
    }
}
