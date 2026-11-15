// PromptsDoc — novel.prompts.json（入力の案内）の宣言ドキュメント層: 払い・タップで選ぶ選択肢（Gate）の案内の絵と色・矢印・
// 押し始めを払いにしない画面の端の帯・tap の当たる物の矩形・tap の輪。案内の描き方は Hint、選び方は Gate と Controls（コード）。
// 名前は Unity の Input System・Xbox の button prompt に合わせた。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod PromptsDoc {
    use fge::{Color, DocJson, JsonCodec}
    use Util.Json.Json

    /// 案内に添える絵 1 つ（#icon:名前）。texture = project.json の textures の名前（空なら絵を出さず色だけ）、color = その選択肢の矢印と輪の色。
    pub type alias Icon = { texture = String, color = Color }

    /// 矢印: color = 色、speed = 1 秒に流れる回数、y = 矢印の真ん中の高さ（画面の高さに対する割合）。
    pub type alias Arrow = { color = Color, speed = Float64, y = Float64 }

    /// tap の当たる物の載る先。Photo = 背景の写真（今の背景がその写真の時だけ）、Actor = 名前付きの絵（出ている時だけ）。
    pub enum Anchor with Eq {
        case Photo(String)
        case Actor(String)
    }

    /// tap の当たる物 1 つ（#at:名前）: anchor = 載る先、rect = 載る先の矩形の中の矩形（左上 0・右下 1 の割合）。
    pub type alias Target = { anchor = Anchor, rect = { x = Float64, y = Float64, w = Float64, h = Float64 } }

    /// tap の輪: rate = 1 秒に脈打つ回数、spread = 外の輪が広がる割合（内の輪の半径に比べる）。
    pub type alias Pulse = { rate = Float64, spread = Float64 }

    /// icons = 案内の絵、arrow = 矢印、edge = 押し始めが左右の端からこの幅（design px）の内なら横の払いにしない帯、targets = tap の当たる物、pulse = tap の輪、
    /// margin = 案内を並べる左右の余白（design px）、captionSize = 案内の字の大きさ（入り切らなければ 0.6 倍まで縮める）。
    pub type alias Rec = { version = Int32, icons = Map[String, Icon], arrow = Arrow, edge = Float64, targets = Map[String, Target], pulse = Pulse,
                           margin = Float64, captionSize = Float64 }

    /// 型検査が record を展開しないため、Res が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.prompts.json"

    def hex(code: String): Color = Color.hex(code) |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 })

    /// コード側の既定値（矢印と字だけ。絵と当たる物は無い）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, icons = Map.empty(), arrow = { color = hex("#e9c873"), speed = 0.8, y = 0.62 }, edge = 24.0,
                  targets = Map.empty(), pulse = { rate = 0.9, spread = 0.4 }, margin = 24.0, captionSize = 20.0 })

    /// 名前の絵（無ければ None）。
    pub def iconOf(name: String, doc: Doc): Option[Icon] = Map.get(name, rec(doc)#icons)

    /// 名前の当たる物（無ければ None）。
    pub def targetOf(name: String, doc: Doc): Option[Target] = Map.get(name, rec(doc)#targets)

    pub def fromJson(text: String): Option[Doc] = DocJson.decodeObject(fromRoot, text)

    def colorOr(key: String, fallback: Color, obj: Map[String, Json]): Color =
        Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString) |> Option.flatMap(Color.hex) |> Option.getWithDefault(fallback)

    def iconFrom(fallback: Color, json: Json): Option[Icon] =
        JsonCodec.expectObject(json) |> Option.map(obj -> { texture = JsonCodec.stringOr("texture", "", obj), color = colorOr("color", fallback, obj) })

    /// { "photo": 写真の名前 } か { "actor": 絵の名前 } と { "rect": { x, y, w, h } }。載る先の無い行は読めない。
    def targetFrom(json: Json): Option[Target] =
        JsonCodec.expectObject(json) |> Option.flatMap(obj -> {
            let text = key -> Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString) |> Option.filter(s -> not String.isEmpty(s));
            let anchor = text("photo") |> Option.map(Anchor.Photo) |> Option.withDefault(default = text("actor") |> Option.map(Anchor.Actor));
            let r = Map.get("rect", obj) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
            anchor |> Option.map(a -> { anchor = a, rect = { x = JsonCodec.floatOr("x", 0.0, r), y = JsonCodec.floatOr("y", 0.0, r),
                                                               w = JsonCodec.floatOr("w", 1.0, r), h = JsonCodec.floatOr("h", 1.0, r) } })
        })

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let section = key -> Map.get(key, root) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
        let arrow = section("arrow");
        let pulse = section("pulse");
        let arrowColor = colorOr("color", d#arrow#color, arrow);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  icons = Map.get("icons", root) |> Option.flatMap(JsonCodec.decodeStringMap(iconFrom(arrowColor))) |> Option.getWithDefault(d#icons),
                  arrow = { color = arrowColor, speed = JsonCodec.floatOr("speed", d#arrow#speed, arrow), y = JsonCodec.floatOr("y", d#arrow#y, arrow) },
                  edge = JsonCodec.floatOr("edge", d#edge, root),
                  targets = Map.get("targets", root) |> Option.flatMap(JsonCodec.decodeStringMap(targetFrom)) |> Option.getWithDefault(d#targets),
                  pulse = { rate = JsonCodec.floatOr("rate", d#pulse#rate, pulse), spread = JsonCodec.floatOr("spread", d#pulse#spread, pulse) },
                  margin = JsonCodec.floatOr("margin", d#margin, root), captionSize = JsonCodec.floatOr("captionSize", d#captionSize, root) })

    /// path の Doc を読む。無い・読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead = DocJson.loadOr(fromJson, defaults(), p)
}
