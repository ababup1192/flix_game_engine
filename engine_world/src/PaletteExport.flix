// PaletteExport — 色票 Doc（`*.palette.json`）を書き出す。
// ドット絵の legend が指す意味色キー（"leaf3" のような名前）と実色の対応表で、
// Studio のドット絵エディタはここか `*.theme.json` のトップレベルからしか名前を解けない。
//
// 何のためにあるか: 実色をコードで導いている絵（テーマの色 3 つから段の列を作る等）では、
// theme にどの段の色も載っていない。手で色票へ書き写すと導出の式が 2 か所に増え、
// 編集画面と実機の配色が黙って食い違う。導いた色をそのまま書き出せば式は 1 か所のまま。
//
// 利用例（ゲームの `make palette` の中身）:
//   PaletteExport.write("assets/hill.palette.json",
//       { note = "make palette が書き出す。手で編集しない",
//         colors = PaletteExport.fromKeys(myResolver, myToneKeys()) })
//
// 注意: 書き出すのは Studio に見せる色票だけで、ゲームの絵はここを読まない
// （実行時は resolver を通る）。色票が古くてもゲームの絵は正しく、ずれるのは編集画面だけ。
pub mod PaletteExport {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JString, JNumber}

    /// 色票 Doc の version。外形（version / note / colors）が変わるときだけ上げる。
    pub def version(): Int32 = 1

    /// 意味色キーの列を resolver に通して「名前 → 実色」の表にする。
    /// resolver はゲームが絵を描くときに使っている物をそのまま渡す — 色票のためだけの
    /// 別の式を書くと、その 2 つがずれた瞬間に編集画面と実機の配色が食い違う。
    pub def fromKeys(resolver: String -> Color, keys: List[String]): Map[String, Color] =
        keys |> List.map(key -> (key, resolver(key))) |> List.toMap

    /// 色票 Doc 1 枚ぶんの JSON テキスト（末尾に改行付き）。
    /// 色は `Color.toHex` の "#rrggbb" にそろえる。キーは Map なので常に同じ並びで出る —
    /// 書き出すたびに行が入れ替わると、git の差分が読めなくなる。
    pub def build(spec: { note = String, colors = Map[String, Color] }): String =
        let colors = spec#colors
            |> Map.map(c -> JString(Color.toHex(c)))
            |> JObject;
        let top = Map#{
            "version" => JNumber(JsonCodec.intToBd(version())),
            "note"    => JString(spec#note),
            "colors"  => colors
        };
        Util.Json.toPrettyString(2, JObject(top)) + "\n"

    /// 色票 Doc を path へ書き出す。親ディレクトリは作らない（`Fs.WriteFile` の流儀）。
    pub def write(path: String, spec: { note = String, colors = Map[String, Color] }):
            Result[String, Unit] \ Fs.FileWrite =
        let result = run {
            Fs.WriteFile.write({ str = build(spec) }, path)
        } with Fs.WriteFile.runWithFileWrite;
        match result {
            case Ok(_)      => Ok(())
            case Err(error) => Err("palette write failed: ${error}")
        }
}
