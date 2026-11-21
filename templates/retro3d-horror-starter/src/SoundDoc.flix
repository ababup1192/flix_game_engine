// SoundDoc — sound.kind.json（音の大きさと、音を出す物からの距離での聞こえ方）の宣言ドキュメント層。
// 足音を主役にして、ほかの音（空気・風・戸・時計・紙）は足音より小さく置く。時計・戸・風は音を出す物に近いほど大きい。
// どの音をいつ鳴らすか・距離から音量を出す式はコード（Sounds）。
// fail-open — 読めない・壊れているときは defaults() へ落とす。
mod SoundDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 距離での聞こえ方: near m までは最大・far m で消える・curve = 間の落ち方（1 で真っすぐ・大きいほど近くを離れるとすぐ小さくなる）。
    pub type alias Falloff = { near = Float64, far = Float64, curve = Float64 }

    /// step〜paper = 音の大きさ（0〜1・近くで鳴った時）。dashStep = 走っている間の足音の大きさ。clock・door・wind = 距離での聞こえ方。
    pub type alias Rec = { version = Int32, step = Float64, dashStep = Float64, ambience = Float64, wind = Float64, door = Float64, clock = Float64, paper = Float64,
                           clockFalloff = Falloff, doorFalloff = Falloff, windFalloff = Falloff }
    pub enum Doc(Rec)
    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/sound.kind.json"

    /// コード側の既定値（assets/sound.kind.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, step = 0.6, dashStep = 0.85, ambience = 0.12, wind = 0.09, door = 0.18, clock = 0.18, paper = 0.3,
                  clockFalloff = { near = 1.0, far = 9.0, curve = 1.5 }, doorFalloff = { near = 1.5, far = 10.0, curve = 1.5 },
                  windFalloff = { near = 2.0, far = 12.0, curve = 1.5 } })

    def fromJson(text: String): Option[Doc] = DocJson.decodeObject(fromRoot, text)

    pub def load(p: String): Doc \ Fs.FileRead = DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, root);
        let falloff = (key, fallback: Falloff) -> Map.get(key, root) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(o -> { near = JsonCodec.floatOr("near", fallback#near, o), far = JsonCodec.floatOr("far", fallback#far, o),
                                 curve = JsonCodec.floatOr("curve", fallback#curve, o) })
            |> Option.getWithDefault(fallback);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  step = num("step", d#step), dashStep = num("dashStep", d#dashStep), ambience = num("ambience", d#ambience), wind = num("wind", d#wind),
                  door = num("door", d#door), clock = num("clock", d#clock), paper = num("paper", d#paper),
                  clockFalloff = falloff("clockFalloff", d#clockFalloff), doorFalloff = falloff("doorFalloff", d#doorFalloff),
                  windFalloff = falloff("windFalloff", d#windFalloff) })
}
