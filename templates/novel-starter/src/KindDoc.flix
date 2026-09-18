// KindDoc — novel.kind.json（手触りの数値）の宣言ドキュメント層。
// Doc は「初期値の宣言」まで: 規則（文字送りの進め方・暗くする条件）はコード側。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod KindDoc {
    use Util.Json.Json

    /// 手触りの数値。cps = 文字送りの速さ（1 秒あたりの文字数）、
    /// dim = 灯りが 1 つ消えるごとに部屋へ重なる暗さ（0〜1 の濃さ）、
    /// bodySize / bodyGap = 本文の文字の大きさ・行間（px）。
    pub type alias Rec = {
        version = Int32,
        cps = Float64,
        dim = Float64,
        bodySize = Float64,
        bodyGap = Float64
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.kind.json"

    /// コード側の既定値（assets/novel.kind.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, cps = 30.0, dim = 0.22, bodySize = 10.0, bodyGap = 3.0 })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  cps = JsonCodec.floatOr("cps", d#cps, root),
                  dim = JsonCodec.floatOr("dim", d#dim, root),
                  bodySize = JsonCodec.floatOr("bodySize", d#bodySize, root),
                  bodyGap = JsonCodec.floatOr("bodyGap", d#bodyGap, root) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
