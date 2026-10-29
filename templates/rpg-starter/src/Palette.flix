// Palette — 色票（assets/rpg.palette.json）を読んで、色票のキー（fcXX・ink）を実色へ解く。
// sprite.json の legend の値は色票のキーそのものなので、ドット絵もコードの色もこの 1 枚で引く。
mod Palette {
    use fge::{Color, DocJson, UiDoc}
    use Util.Json.Json

    /// 色票のキー → 実色。
    pub type alias Palette = Map[String, Color]

    pub def path(): String = "assets/rpg.palette.json"

    /// 色票に無いキーの色。WhyNot: 近い色へ丸めない — 書き損じが絵に紛れて気づけなくなる。
    pub def missing(): Color = { r = 1.0, g = 0.0, b = 1.0 }

    /// テキストから色票へ。色の形（{"rgb":[…]}）をしていない欄（version・説明の "//"）は読み飛ばす。
    def fromJson(text: String): Option[Palette] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Palette =
        root |> Map.foldLeftWithKey((acc, key, json) ->
            match UiDoc.colorOf(Map.empty(), key, json) {
                case Ok(color) => Map.insert(key, color, acc)
                case Err(_)    => acc
            }, Map.empty())

    /// 色票を読む。読めない・壊れているときは空（どのキーも missing の色で描かれる）。
    pub def load(): Palette \ Fs.FileRead =
        DocJson.loadOr(fromJson, Map.empty(), path())

    /// キー → 実色（sprite の bake とコードの色の両方がここを通る）。
    pub def resolve(palette: Palette, key: String): Color =
        Map.getWithDefault(key, missing(), palette)
}
