// CastDoc — novel.cast.json（立ち絵と小物）の宣言ドキュメント層: 位置（横と縦・1 つしか立てない位置）・人物と小物の一覧（重ね順・背景に付く絵）・
// 出入りの秒・端から滑る距離・息の揺れ・縦の頁の覆いの倍率・話し手を明るくする量・絵の中の点（markers）・出ている間は文字の枠を消すか。
// 出し方と重ね方の決まりは Cast のコード、シナリオの書き方は Commands の頭のコメント（<<show>> / <<hide>>）。
// テクスチャの名前は「cast_<名前>_<表情>」で導き、project.json の textures にこの名前で登録する（TestDocs が見る）。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod CastDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 列: Character = 人物、Prop = 小物（既定の重ね順が人物より手前・NVL の頁では幕の上）。何人・何個でも同時に出せる。
    pub enum Kind with Eq, Order, ToString {
        case Character
        case Prop
    }

    /// 位置 1 つ。x / bottom / height は画面に対する割合: x = 絵の中心の横の位置、bottom = 足元の縦の位置、height = 絵の高さ。
    /// exclusive = その位置に出せるのは 1 つ（後から出した物が前の物を消す）。
    pub type alias Slot = { x = Float64, bottom = Float64, height = Float64, exclusive = Bool }

    /// 絵の付く先。Screen = 画面（ふつうの立ち絵と小物）、Backdrop = 背景（背景のすぐ上に描き、写真の名前 → 横のずれ（画面の幅に対する割合）の分だけずらす）。
    pub enum Attach with Eq {
        case Screen
        case Backdrop(Map[String, Float64])
    }

    /// 人物か小物 1 つ。label = 人に見せる名前、aspect = 絵の横 ÷ 縦（実物の PNG と一致するかは make lint-cast）、
    /// scale = 位置の高さに掛ける倍率、face = 既定の表情、slot = 既定の位置、faces = 表情の名前の一覧、
    /// layer = 重ね順（大きいほど手前。既定は人物 500・小物 600・背景に付く絵 100）、attach = 付く先、
    /// markers = 絵の中の点の名前 → 位置（<<fx 名 on=絵.点>>・<<speak>> が粒を出す所）、
    /// hideWindow = 出ている間は文字の枠と字を消す、speakFx = <<speak 名>> が markers の mouth から一度出す粒（novel.effects.json の particles）。
    pub type alias Entry = { label = String, aspect = Float64, scale = Float64, face = String, slot = String, faces = List[String],
                             layer = Int32, attach = Attach, markers = Map[String, Marker], hideWindow = Bool, speakFx = Option[String] }

    /// 絵の中の点（絵の左上 0・右下 1 の割合）。名前は Godot の Marker2D に合わせた。
    pub type alias Marker = { x = Float64, y = Float64 }

    /// 話し手を明るくする: dim = 話していない人物を暗くする量（0 = 暗くしない・1 = 真っ黒）、seconds = 明るさを替える秒、
    /// voices = 立ち絵を持たないが、話している間はほかの人物を暗くする話し手の id（声だけの人物・ゲームが自分で描く人物）。
    pub type alias Highlight = { dim = Float64, seconds = Float64, voices = Set[String] }

    /// fadeSeconds = 出入りと入れ替えの既定の秒、slideDistance = from= / to= で端から滑る距離（画面に対する割合。1 で画面の外まで）、
    /// sway = 息の揺れの幅（画面の高さに対する割合・0 で止める）、
    /// portraitVeilWithCast = 縦の画面で人物が出ている間に頁の覆いの濃さへ掛ける倍率（1 = 変えない）、highlight = 話し手を明るくする量と秒、
    /// slots / portraitSlots = 横と縦の画面の位置（名前の集まりは同じにする）、cast = 人物、props = 小物。
    pub type alias Rec = {
        version = Int32,
        fadeSeconds = Float64,
        slideDistance = Float64,
        sway = Float64,
        portraitVeilWithCast = Float64,
        highlight = Highlight,
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
        Doc.Doc({ version = 1, fadeSeconds = 0.4, slideDistance = 1.0, sway = 0.002, portraitVeilWithCast = 1.0,
                  highlight = { dim = 0.35, seconds = 0.25, voices = Set.empty() },
                  slots = Map#{ "left" => { x = 0.25, bottom = 1.0, height = 0.9, exclusive = true }, "center" => { x = 0.5, bottom = 1.0, height = 0.9, exclusive = true },
                                "right" => { x = 0.75, bottom = 1.0, height = 0.9, exclusive = true }, "item" => { x = 0.5, bottom = 0.62, height = 0.36, exclusive = true } },
                  portraitSlots = Map#{ "left" => { x = 0.28, bottom = 1.0, height = 0.6, exclusive = true }, "center" => { x = 0.5, bottom = 1.0, height = 0.6, exclusive = true },
                                        "right" => { x = 0.72, bottom = 1.0, height = 0.6, exclusive = true }, "item" => { x = 0.5, bottom = 0.55, height = 0.25, exclusive = true } },
                  cast = Map.empty(), props = Map.empty() })

    /// 描き出しとテストが使う見本: 既定の Doc に、テスト用の透過画像（project.json の textures の cast__sample_plain）の人物を 1 人足した物。
    /// WhyNot: 作例のシナリオと novel.cast.json に載せない — 単色の形は仕組みを確かめるためだけの絵で、物語の人物ではない。
    pub def sample(): Doc = withSample(defaults())

    /// doc の人物に、テスト用の透過画像の人物を 1 人足した物（物語の人物と小物はそのまま残る）。
    pub def withSample(doc: Doc): Doc =
        let d = rec(doc);
        let entry = { label = "見本", aspect = 0.4, scale = 1.0, face = "plain", slot = "center", faces = "plain" :: Nil,
                      layer = defaultLayerOf(Kind.Character, Attach.Screen), attach = Attach.Screen,
                      markers = Map.empty(), hideWindow = false, speakFx = None };
        Doc.Doc({ cast = Map.insert(sampleName(), entry, d#cast) | d })

    /// 見本の人物の名前。
    pub def sampleName(): String = "_sample"

    /// 人物か小物のテクスチャの名前（project.json の textures の name）。
    pub def textureOf(name: String, face: String): String = "cast_${name}_${face}"

    /// 重ね順の既定（背景に付く絵 100・人物 500・小物 600）。
    pub def defaultLayerOf(kind: Kind, attach: Attach): Int32 = match (attach, kind) {
        case (Attach.Backdrop(_), _)   => 100
        case (_, Kind.Character)       => 500
        case (_, Kind.Prop)            => 600
    }

    /// 背景の写真 photo の上で付く絵をずらす横の量（画面の幅に対する割合。画面に付く絵と、表に無い写真は 0）。
    pub def attachShiftOf(photo: Option[String], attach: Attach): Float64 = match (attach, photo) {
        case (Attach.Backdrop(shifts), Some(p)) => Map.get(p, shifts) |> Option.getWithDefault(0.0)
        case _                                  => 0.0
    }

    /// 背景に付く絵か。
    pub def isAttachedToBackdrop(entry: Entry): Bool = entry#attach != Attach.Screen

    /// 名前の絵（人物か小物）の点 point（無い名前・無い点は None）。
    pub def markerOf(name: String, point: String, doc: Doc): Option[Marker] =
        Map.get(name, rec(doc)#cast) |> Option.withDefault(default = Map.get(name, rec(doc)#props)) |> Option.flatMap(e -> Map.get(point, e#markers))

    /// 列の一覧から名前の項目を引く（人物は cast、小物は props）。
    pub def entryOf(kind: Kind, name: String, doc: Doc): Option[Entry] = match kind {
        case Kind.Character => Map.get(name, rec(doc)#cast)
        case Kind.Prop      => Map.get(name, rec(doc)#props)
    }

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def slotFrom(json: Json): Option[Slot] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { x = JsonCodec.floatOr("x", 0.5, obj), bottom = JsonCodec.floatOr("bottom", 1.0, obj), height = JsonCodec.floatOr("height", 0.9, obj),
              exclusive = JsonCodec.boolOr("exclusive", true, obj) })

    def entryFrom(kind: Kind, slot: String, json: Json): Option[Entry] =
        JsonCodec.expectObject(json) |> Option.map(obj -> {
            let faces = Map.get("faces", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.getWithDefault(Nil);
            let face = JsonCodec.stringOr("face", List.head(faces) |> Option.getWithDefault(""), obj);
            let attach = attachFrom(Map.get("attach", obj));
            { label = JsonCodec.stringOr("label", "", obj), aspect = JsonCodec.floatOr("aspect", 0.5, obj),
              scale = JsonCodec.floatOr("scale", 1.0, obj), face = face, slot = JsonCodec.stringOr("slot", slot, obj), faces = faces,
              layer = JsonCodec.intOr("layer", defaultLayerOf(kind, attach), obj), attach = attach,
              markers = Map.get("markers", obj) |> Option.flatMap(JsonCodec.decodeStringMap(markerFrom)) |> Option.getWithDefault(Map.empty()),
              hideWindow = JsonCodec.boolOr("hideWindow", false, obj),
              speakFx = Map.get("speakFx", obj) |> Option.flatMap(JsonCodec.expectString) |> Option.filter(n -> not String.isEmpty(n)) }
        })

    /// { "x": 割合, "y": 割合 } を読む（欠けた欄は真ん中）。
    def markerFrom(json: Json): Option[Marker] =
        JsonCodec.expectObject(json) |> Option.map(obj -> { x = JsonCodec.floatOr("x", 0.5, obj), y = JsonCodec.floatOr("y", 0.5, obj) })

    /// "highlight": { "dim", "seconds", "voices" } を読む（欠けた欄は fallback の値）。
    def highlightFrom(fallback: Highlight, json: Option[Json]): Highlight =
        json |> Option.flatMap(JsonCodec.expectObject)
             |> Option.map(obj -> { dim = JsonCodec.floatOr("dim", fallback#dim, obj), seconds = JsonCodec.floatOr("seconds", fallback#seconds, obj),
                                    voices = Map.get("voices", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.map(List.toSet)
                                                 |> Option.getWithDefault(fallback#voices) })
             |> Option.getWithDefault(fallback)

    /// "attach": { "bg": { 写真の名前: 横のずれ } } を読む（無い・読めなければ画面に付く）。
    def attachFrom(json: Option[Json]): Attach =
        json |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(obj -> Map.get("bg", obj))
             |> Option.map(bg -> JsonCodec.decodeStringMap(JsonCodec.expectFloat, bg) |> Option.getWithDefault(Map.empty()))
             |> Option.map(Attach.Backdrop) |> Option.getWithDefault(Attach.Screen)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  fadeSeconds = JsonCodec.floatOr("fadeSeconds", d#fadeSeconds, root),
                  slideDistance = JsonCodec.floatOr("slideDistance", d#slideDistance, root),
                  sway = JsonCodec.floatOr("sway", d#sway, root),
                  portraitVeilWithCast = JsonCodec.floatOr("portraitVeilWithCast", d#portraitVeilWithCast, root),
                  highlight = highlightFrom(d#highlight, Map.get("highlight", root)),
                  slots = catalogOr(root, "slots", slotFrom, d#slots),
                  portraitSlots = catalogOr(root, "portraitSlots", slotFrom, d#portraitSlots),
                  cast = catalogOr(root, "cast", entryFrom(Kind.Character, "center"), d#cast),
                  props = catalogOr(root, "props", entryFrom(Kind.Prop, "item"), d#props) }) |> withKnownNames

    /// 項目の既定の表情を faces の中へ、既定の位置を slots の中へ丸める（無ければ faces の頭・slots の鍵の頭）。
    // WhyNot: 書き損じの名前のまま残さない — 既定の表情から導いたテクスチャは未登録で、出した人が見えなくなる。
    def withKnownNames(doc: Doc): Doc =
        let d = rec(doc);
        let firstSlot = Map.keysOf(d#slots) |> Set.toList |> List.head |> Option.getWithDefault("");
        let known = (e: Entry) ->
            { face = if (List.memberOf(e#face, e#faces)) e#face else List.head(e#faces) |> Option.getWithDefault(e#face),
              slot = if (Map.memberOf(e#slot, d#slots)) e#slot else firstSlot | e };
        Doc.Doc({ cast = Map.map(known, d#cast), props = Map.map(known, d#props) | d })

    /// 名前 → 中身の辞書の欄（読めない項目は落とし、欄が無い・辞書でなければ fallback）。
    def catalogOr(root: Map[String, Json], key: String, decode: Json -> Option[t], fallback: Map[String, t]): Map[String, t] =
        Map.get(key, root) |> Option.flatMap(JsonCodec.decodeStringMap(decode)) |> Option.getWithDefault(fallback)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
