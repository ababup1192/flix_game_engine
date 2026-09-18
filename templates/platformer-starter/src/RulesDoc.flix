// RulesDoc — platformer.rules.json(収支と進行のノブ)の宣言ドキュメント層。
// 「いつ加点するか・いつ場面が変わるか」の規則はコード(World)側で、ここに出すのは
// その規則が読む数値だけ。難易度と褒美の匙加減は遊びながら何度も触るので、
// コードに埋めるとビルド待ちが調整の邪魔になる。壊れていれば defaults(fail-open)。
mod RulesDoc {
    use Util.Json.Json

    pub type alias Rec = {
        version = Int32,
        coinScore = Int32, stompScore = Int32, goalScore = Int32, // 加点(コイン/踏み/旗)
        maxHearts = Int32,     // ハートの上限(= 開始時の残機)
        clearWaitSec = Float64,// clear の幕を見せてから次の面へ移るまでの秒
        overWaitSec = Float64  // over の幕を見せてから最初の面へ戻るまでの秒
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/platformer.rules.json"

    /// コード側の既定値(assets/platformer.rules.json と同じ値から出発する)。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          coinScore = 100, stompScore = 200, goalScore = 500,
          maxHearts = 3, clearWaitSec = 1.6, overWaitSec = 2.0 })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version      = JsonCodec.intOr("version", d#version, root),
          coinScore    = JsonCodec.intOr("coinScore", d#coinScore, root),
          stompScore   = JsonCodec.intOr("stompScore", d#stompScore, root),
          goalScore    = JsonCodec.intOr("goalScore", d#goalScore, root),
          maxHearts    = JsonCodec.intOr("maxHearts", d#maxHearts, root),
          clearWaitSec = JsonCodec.floatOr("clearWaitSec", d#clearWaitSec, root),
          overWaitSec  = JsonCodec.floatOr("overWaitSec", d#overWaitSec, root) })

    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
