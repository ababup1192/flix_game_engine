// SampleDoc — sample.kind.json（手触りの数値）の宣言ドキュメント層。
// Doc は「初期値の宣言」まで: 規則（動き方）はコード（World）側。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod SampleDoc {
    use Util.Json.Json

    // World が持つ record は enum で包む（型検査が record を展開しないため）。
    pub type alias Rec = {
        version = Int32,
        speed = Float64
    }
    pub enum Doc(Rec)
    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/sample.kind.json"

    /// コード側の既定値（assets/sample.kind.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, speed = 120.0 })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  speed = JsonCodec.floatOr("speed", d#speed, root) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
