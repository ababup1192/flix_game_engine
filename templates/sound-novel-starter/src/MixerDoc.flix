// MixerDoc — novel.mixer.json のうちテンプレートが読む欄: 名前付きの音量（<<audio … volume=名前>>）と、効果音の後に台詞を送れない秒。
// バス・ダッキング・スナップショットの欄はエンジンの AudioMixerDoc が同じファイルから読む（ここは読まない）。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod MixerDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// volumes = 音量の名前 → 0〜1、lockSeconds = 効果音の名前 → 鳴らした後に押しても台詞を送らない秒。
    pub type alias Rec = { volumes = Map[String, Float64], lockSeconds = Map[String, Float64] }

    /// 型検査が record を展開しないため、Res が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    /// 名前付きの音量も送れない秒も無い既定。
    pub def defaults(): Doc = Doc.Doc({ volumes = Map.empty(), lockSeconds = Map.empty() })

    /// 名前の音量（知らない名前は None）。
    pub def volumeOf(name: String, doc: Doc): Option[Float64] = Map.get(name, rec(doc)#volumes)

    /// 効果音 sound を鳴らした後に送れない秒（無ければ None）。
    pub def lockOf(sound: String, doc: Doc): Option[Float64] = Map.get(sound, rec(doc)#lockSeconds)

    def numbers(key: String, root: Map[String, Json]): Map[String, Float64] =
        Map.get(key, root) |> Option.flatMap(JsonCodec.decodeStringMap(JsonCodec.expectFloat)) |> Option.getWithDefault(Map.empty())

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(root -> Doc.Doc({ volumes = numbers("volumes", root), lockSeconds = numbers("lockSeconds", root) }), text)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead = DocJson.loadOr(fromJson, defaults(), p)
}
