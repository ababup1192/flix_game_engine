// EffectsDoc — novel.effects.json（画面の粒の演出の表）の宣言ドキュメント層: <<fx 名>> の名前 → 描き方の種類・層の数・一度だけ出す秒。
// 粒の数や速さなどの手触りは novel.kind.json（fireflies・snow）、描き方は ViewStage（コード）。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod EffectsDoc {
    use fge::{DocJson, JsonCodec, Log}
    use Util.Json.Json

    /// 粒の描き方。Fireflies = 漂って明滅する光（novel.kind.json の fireflies）、Snow = 降る雪（novel.kind.json の snow）。
    pub enum Look with Eq, ToString {
        case Fireflies
        case Snow
    }

    /// 粒の演出 1 つ。look = 描き方、layer = world の層の数（背景 0・人物 500・小物 600 と並べる）、onceSeconds = <<fx 名 once=true>> で出す秒。
    pub type alias Particle = { look = Look, layer = Int32, onceSeconds = Float64 }

    /// particles = <<fx 名>> の名前 → 粒の演出。
    pub type alias Rec = { version = Int32, particles = Map[String, Particle] }

    /// 型検査が record を展開しないため、Res が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.effects.json"

    /// 層の数を書かない粒の既定（人物 500・小物 600 より手前）。
    pub def defaultLayer(): Int32 = 700

    /// コード側の既定値（蛍と雪）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, particles = Map#{ "fireflies" => { look = Look.Fireflies, layer = defaultLayer(), onceSeconds = 2.0 },
                                                 "snow" => { look = Look.Snow, layer = defaultLayer(), onceSeconds = 2.0 } } })

    /// 名前の粒の演出（知らない名前は None）。
    pub def particleOf(name: String, doc: Doc): Option[Particle] = Map.get(name, rec(doc)#particles)

    def lookOf(name: String): Option[Look] = match name {
        case "fireflies" => Some(Look.Fireflies)
        case "snow"      => Some(Look.Snow)
        case _           => None
    }

    def particleFrom(json: Json): Option[Particle] =
        JsonCodec.expectObject(json) |> Option.flatMap(obj ->
            lookOf(JsonCodec.stringOr("look", "", obj)) |> Option.map(look ->
                { look = look, layer = JsonCodec.intOr("layer", defaultLayer(), obj), onceSeconds = JsonCodec.floatOr("onceSeconds", 2.0, obj) }))

    pub def fromJson(text: String): Option[Doc] = DocJson.decodeObject(fromRoot, text)

    /// 書き損じの粒 1 つだけを既定（雪・層の数 700）にして知らせ、ほかの粒は書いたとおりに読む。
    // WhyNot: 粒の表を丸ごと既定へ落とさない — 1 つの書き損じで、書いた粒が全部消えて蛍と雪に戻る。
    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let fallback = { look = Look.Snow, layer = defaultLayer(), onceSeconds = 2.0 };
        let entries = Map.get("particles", root) |> Option.flatMap(JsonCodec.expectObject);
        let read = (name, json) -> match particleFrom(json) {
            case Some(p) => p
            case None    => Log.fellBackThen("effects", "novel.effects.json の粒 '${name}'", "雪（既定）", "look が fireflies・snow のどれでもないか、形が違う", fallback)
        };
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  particles = entries |> Option.map(Map.mapWithKey(read)) |> Option.getWithDefault(d#particles) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead = DocJson.loadOr(fromJson, defaults(), p)
}
