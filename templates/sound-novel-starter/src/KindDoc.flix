// KindDoc — novel.kind.json（手触りの数: 字の大きさ・行の数・オートとスキップの間・揺れ・粒）の宣言ドキュメント層。
// 設定の画面で人が変える値（文字の速さ・オートの待ち・音量）の出発点もここ（変えた値はセーブの config が持つ）。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod KindDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// bodySize / rubySize / nameSize = 本文・ルビ・名前の字の大きさ（px）、lineGap = 行の間（ルビが入るので rubySize 以上）、
    /// advRows / nvlRows = ADV の窓・NVL の頁に入る行の数（あふれる前に頁をめくる）、
    /// cps / autoWait / ambienceVolume / seVolume = 設定の既定（1 秒の字数・オートで読み終えてから送るまでの秒・音量 0〜1）、
    /// autoPerChar = オートの待ちに足す 1 字あたりの秒（長い行ほど長く待つ）、skipInterval = スキップで 1 行を出す間（秒）、
    /// logMax = ログに残す行の数、shakeSeconds / shakePx = <<shake>> の長さと揺れ幅、
    /// fireflies = <<fx fireflies>> の粒の数、creditsSpeed = クレジットが流れる速さ（px/秒）、toastSeconds = 知らせを出す秒。
    pub type alias Rec = {
        version = Int32,
        bodySize = Float64,
        rubySize = Float64,
        nameSize = Float64,
        lineGap = Float64,
        advRows = Int32,
        nvlRows = Int32,
        cps = Float64,
        autoWait = Float64,
        ambienceVolume = Float64,
        seVolume = Float64,
        autoPerChar = Float64,
        skipInterval = Float64,
        logMax = Int32,
        shakeSeconds = Float64,
        shakePx = Float64,
        fireflies = Int32,
        creditsSpeed = Float64,
        toastSeconds = Float64
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.kind.json"

    /// コード側の既定値（assets/novel.kind.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, bodySize = 22.0, rubySize = 11.0, nameSize = 19.0, lineGap = 14.0,
                  advRows = 3, nvlRows = 11, cps = 40.0, autoWait = 1.2, ambienceVolume = 0.7, seVolume = 0.8,
                  autoPerChar = 0.04, skipInterval = 0.06, logMax = 120, shakeSeconds = 0.35, shakePx = 7.0,
                  fireflies = 28, creditsSpeed = 34.0, toastSeconds = 1.6 })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, root);
        let int = (key, fallback) -> JsonCodec.intOr(key, fallback, root);
        Doc.Doc({ version = int("version", d#version),
                  bodySize = num("bodySize", d#bodySize), rubySize = num("rubySize", d#rubySize),
                  nameSize = num("nameSize", d#nameSize), lineGap = num("lineGap", d#lineGap),
                  advRows = int("advRows", d#advRows), nvlRows = int("nvlRows", d#nvlRows),
                  cps = num("cps", d#cps), autoWait = num("autoWait", d#autoWait),
                  ambienceVolume = num("ambienceVolume", d#ambienceVolume), seVolume = num("seVolume", d#seVolume),
                  autoPerChar = num("autoPerChar", d#autoPerChar), skipInterval = num("skipInterval", d#skipInterval),
                  logMax = int("logMax", d#logMax),
                  shakeSeconds = num("shakeSeconds", d#shakeSeconds), shakePx = num("shakePx", d#shakePx),
                  fireflies = int("fireflies", d#fireflies), creditsSpeed = num("creditsSpeed", d#creditsSpeed),
                  toastSeconds = num("toastSeconds", d#toastSeconds) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
