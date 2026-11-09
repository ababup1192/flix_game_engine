// CastDoc — novel.cast.json（立ち絵と小物）の宣言ドキュメント層: 位置（横と縦）・人物と小物の一覧・出入りの秒・息の揺れ・縦の頁の覆いの倍率。
// 出し方と重ね方の決まりは Cast のコード、シナリオの書き方は Stage の頭のコメント（<<char>> / <<item>>）。
// テクスチャの名前は「cast_<名前>_<表情>」で導き、project.json の textures にこの名前で登録する（TestDocs が見る）。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod CastDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 列: Character = 人物（1 つの位置に 1 人ずつ、同時に何人も）、Prop = 小物（1 つだけ・人物より手前）。
    pub enum Lane with Eq, Order, ToString {
        case Character
        case Prop
    }

    /// 位置 1 つ。どれも画面に対する割合: x = 絵の中心の横の位置、bottom = 足元の縦の位置、height = 絵の高さ。
    pub type alias Slot = { x = Float64, bottom = Float64, height = Float64 }

    /// 人物か小物 1 つ。label = 人に見せる名前、aspect = 絵の横 ÷ 縦（実物の PNG と一致するかは make lint-cast）、
    /// scale = 位置の高さに掛ける倍率、face = 既定の表情、slot = 既定の位置、faces = 表情の名前の一覧。
    pub type alias Entry = { label = String, aspect = Float64, scale = Float64, face = String, slot = String, faces = List[String] }

    /// fadeSeconds = 出入りと入れ替えの既定の秒、sway = 息の揺れの幅（画面の高さに対する割合・0 で止める）、
    /// portraitVeilWithCast = 縦の画面で人物が出ている間に頁の覆いの濃さへ掛ける倍率（1 = 変えない）、
    /// slots / portraitSlots = 横と縦の画面の位置（名前の集まりは同じにする）、cast = 人物、props = 小物。
    pub type alias Rec = {
        version = Int32,
        fadeSeconds = Float64,
        sway = Float64,
        portraitVeilWithCast = Float64,
        slots = Map[String, Slot],
        portraitSlots = Map[String, Slot],
        cast = Map[String, Entry],
        props = Map[String, Entry]
    }

    /// 型検査が record を展開しないため、Res が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.cast.json"

    /// コード側の既定値（assets/novel.cast.json と同じ値から出発する）。人物と小物は空。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, fadeSeconds = 0.4, sway = 0.002, portraitVeilWithCast = 1.0,
                  slots = Map#{ "left" => { x = 0.25, bottom = 1.0, height = 0.9 }, "center" => { x = 0.5, bottom = 1.0, height = 0.9 },
                                "right" => { x = 0.75, bottom = 1.0, height = 0.9 }, "item" => { x = 0.5, bottom = 0.62, height = 0.36 } },
                  portraitSlots = Map#{ "left" => { x = 0.28, bottom = 1.0, height = 0.6 }, "center" => { x = 0.5, bottom = 1.0, height = 0.6 },
                                        "right" => { x = 0.72, bottom = 1.0, height = 0.6 }, "item" => { x = 0.5, bottom = 0.55, height = 0.25 } },
                  cast = Map.empty(), props = Map.empty() })

    /// 描き出しとテストが使う見本: 既定の Doc に、テスト用の透過画像（assets/cast/_sample_plain.png・art/cast/sample.py が作る）の人物を 1 人足した物。
    /// WhyNot: 作例のシナリオと novel.cast.json に載せない — テンプレートの物語に立ち絵は出さず、仕組みだけを見せる。
    pub def sample(): Doc =
        let d = rec(defaults());
        Doc.Doc({ cast = Map#{ sampleName() => { label = "見本", aspect = 0.4, scale = 1.0, face = "plain", slot = "center", faces = "plain" :: Nil } } | d })

    /// 見本の人物の名前。
    pub def sampleName(): String = "_sample"

    /// 人物か小物のテクスチャの名前（project.json の textures の name）。
    pub def textureOf(name: String, face: String): String = "cast_${name}_${face}"

    /// 列の一覧から名前の項目を引く（人物は cast、小物は props）。
    pub def entryOf(lane: Lane, name: String, doc: Doc): Option[Entry] = match lane {
        case Lane.Character => Map.get(name, rec(doc)#cast)
        case Lane.Prop      => Map.get(name, rec(doc)#props)
    }

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def slotFrom(json: Json): Option[Slot] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { x = JsonCodec.floatOr("x", 0.5, obj), bottom = JsonCodec.floatOr("bottom", 1.0, obj), height = JsonCodec.floatOr("height", 0.9, obj) })

    def entryFrom(slot: String, json: Json): Option[Entry] =
        JsonCodec.expectObject(json) |> Option.map(obj -> {
            let faces = Map.get("faces", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.getWithDefault(Nil);
            let face = JsonCodec.stringOr("face", List.head(faces) |> Option.getWithDefault(""), obj);
            { label = JsonCodec.stringOr("label", "", obj), aspect = JsonCodec.floatOr("aspect", 0.5, obj),
              scale = JsonCodec.floatOr("scale", 1.0, obj), face = face, slot = JsonCodec.stringOr("slot", slot, obj), faces = faces }
        })

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  fadeSeconds = JsonCodec.floatOr("fadeSeconds", d#fadeSeconds, root),
                  sway = JsonCodec.floatOr("sway", d#sway, root),
                  portraitVeilWithCast = JsonCodec.floatOr("portraitVeilWithCast", d#portraitVeilWithCast, root),
                  slots = catalogOr(root, "slots", slotFrom, d#slots),
                  portraitSlots = catalogOr(root, "portraitSlots", slotFrom, d#portraitSlots),
                  cast = catalogOr(root, "cast", entryFrom("center"), d#cast),
                  props = catalogOr(root, "props", entryFrom("item"), d#props) })

    /// 名前 → 中身の辞書の欄（読めない項目は落とし、欄が無い・辞書でなければ fallback）。
    def catalogOr(root: Map[String, Json], key: String, decode: Json -> Option[t], fallback: Map[String, t]): Map[String, t] =
        Map.get(key, root) |> Option.flatMap(JsonCodec.decodeStringMap(decode)) |> Option.getWithDefault(fallback)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
