// PaletteDoc — race.palette.json（ドット絵の色票）の宣言ドキュメント層。
// *.sprite.json の legend が使う「意味色キー → 実色」の表。マシンのタイヤ・キャノピー・
// ヤシの幹と葉・コーン・アイテム箱など、ドット絵の細かい色はここに集める
// （画面の大きな配色は ThemeDoc — 関心が違うので Doc を分ける）。
// Studio のドット絵エディタも同じファイルを paletteFile として読む（make lint-palette のゲート）。
// 車体の色（body 系）だけは描くとき ThemeDoc の player / rivalA..C で塗り替える —
// ここに置くのは Studio のプレビュー用の基準色（自機の赤）。
// fail-open: 読めない・壊れているときは defaults() へ落とす。
mod PaletteDoc {
    use flix_game_engine::{Color, DocJson, JsonCodec}
    use Util.Json.Json

    /// 意味色キー → 実色 の表。
    pub type alias Doc = Map[String, Color]

    pub def path(): String = "assets/race.palette.json"

    def hex(code: String): Color =
        Color.hex(code) |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 })

    /// コード側の既定値（assets/race.palette.json の colors と同じ値から出発する）。
    pub def defaults(): Doc =
        defaultRows() |> List.map(row -> { let (name, code) = row; (name, hex(code)) }) |> List.toMap

    /// 既定の (キー, 色) の一覧。assets 側の JSON を書き出すときの source of truth もこの並び。
    pub def defaultRows(): List[(String, String)] =
           ("ink",         "#20242e")   // 輪郭
        :: ("body",        "#e63946")   // 車体（描くときテーマ色で塗り替え）
        :: ("bodyLight",   "#ff7d6e")   // 車体の日の当たる面
        :: ("bodyDark",    "#9e1f2e")   // 車体の影の面
        :: ("canopy",      "#17303f")   // キャノピー（風防ガラス）
        :: ("canopyShine", "#8fd8ec")   // ガラスの照り返し
        :: ("tire",        "#14171c")   // タイヤ
        :: ("tireShine",   "#3c434e")   // タイヤのハイライト
        :: ("wing",        "#262b35")   // リアウィング
        :: ("lamp",        "#fff6d8")   // ヘッドライト
        :: ("tail",        "#ff5148")   // テールランプ
        :: ("stripe",      "#f7f9fb")   // センターストライプ
        :: ("trunk",       "#8a5a34")   // ヤシの幹
        :: ("trunkDark",   "#6b4423")   // ヤシの幹の影
        :: ("leaf",        "#2f8f45")   // ヤシの葉
        :: ("leafLight",   "#5cc46a")   // ヤシの葉の明るい側
        :: ("leafDark",    "#1f6a33")   // ヤシの葉の影
        :: ("cone",        "#ff8c2a")   // コーン
        :: ("coneLight",   "#ffb46a")   // コーンの日の当たる面
        :: ("coneWhite",   "#f5f7f9")   // コーンの白帯
        :: ("itemGold",    "#f6a800")   // アイテム箱の金
        :: ("itemDark",    "#8a5c00")   // アイテム箱の影
        :: ("itemMark",    "#fff3c8")   // アイテム箱の「?」
        :: Nil

    /// テキストから Doc へ（fail-open）。colors の下の「名前: "#rrggbb"」だけ拾い、
    /// 読めない色は落として既定で補う（欠けた色で絵に穴を開けない）。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let loaded = Map.get("colors", root)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(obj -> obj
                |> Map.toList
                |> List.filterMap(entry -> {
                    let (name, json) = entry;
                    JsonCodec.expectString(json)
                        |> Option.flatMap(Color.hex)
                        |> Option.map(color -> (name, color))
                })
                |> List.toMap)
            |> Option.getWithDefault(Map.empty());
        // 既定の上に読めた色を重ねる（欠けたキーは既定で埋まる = fail-open）。
        Map.foldLeftWithKey((acc, name, color) -> Map.insert(name, color, acc), defaults(), loaded)

    /// 車の意味色: body 系 3 キーだけ車体色 bodyColor から導き、残りはこの表で引く。
    /// アトラス生成（World）と box 列（ViewCar）が同じ導出をここで見る — 2 か所に式を持つと
    /// クアッドと box の車体色が静かに食い違う。
    pub def carInk(doc: Doc, bodyColor: Color, key: String): Color =
        match key {
            case "body"      => bodyColor
            case "bodyLight" => Color.lighten(bodyColor, 0.22)
            case "bodyDark"  => Color.darken(bodyColor, 0.28)
            case _           => resolve(doc, key)
        }

    /// 意味色キー → 実色。無いキーはマゼンタ（書き間違いが画面で目に見える）。
    pub def resolve(doc: Doc, name: String): Color =
        Map.get(name, doc) |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
