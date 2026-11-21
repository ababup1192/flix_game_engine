// CastDoc — characters.kind.json（校舎にいる人物の置き場所と向き・話しかけの決まり）の宣言ドキュメント層。
// 置き場所は配置の表（layout.json）と同じ glTF の座標で書く（読む時に X を反転する）。向きも表と同じく glTF の +Y まわりの度で、0 が glTF の −Z。
// 話し方（範囲・角・首と体を向ける速さ・身振りの間・文字送りの速さ）も同じ Doc に置く。誰が何を話すかの文は assets/talk/*.yarn。
// fail-open — 読めない・壊れているときは defaults() へ落とす。行の欄が欠けた人物はその 1 人だけ置かない。
mod CastDoc {
    use fge::{DocJson, JsonCodec, Num, Vec3}
    use Util.Json.Json

    /// 人物 1 人。model = assets/characters/<model>.glb・speaker = 会話の窓に出す名前（.yarn の話し手と同じ字）・node = 話す .yarn のノード・
    /// feet = 足元（engine の座標）・yaw = 体の向き（engine のカメラの yaw と同じ約束・ラジアン）・
    /// gestures = 話す間に台詞の行ごとに順に回す身振り（glb のアニメの名前）。
    pub type alias Member = { id = String, model = String, speaker = String, node = String, feet = Vec3.Vec3, yaw = Float64, gestures = List[String] }

    /// talkReach = 話しかけられる距離（m）・talkAngleDeg = 視線の正面から何度以内か・headTurnSec = 首を向け切るまでの秒・
    /// headMaxDeg = 首を回す角の上限・cps = 会話の文字送り（1 秒の字数）。
    /// bodyTurnSec = 体ごとプレイヤーへ向き直る秒・lingerSec = 話し終えてから向いたままでいる秒・returnSec = 元の向きへ戻る秒・
    /// gestureDelaySec = 行を出してから身振りを始めるまでの秒・gestureFadeSec = 身振りを idle と混ぜて出し入れする秒。
    /// talkHint = 話しかけられる時に画面の真ん中の下に出す字。
    pub type alias Rec = { version = Int32, talkReach = Float64, talkAngleDeg = Float64, headTurnSec = Float64, headMaxDeg = Float64, cps = Float64,
                           bodyTurnSec = Float64, lingerSec = Float64, returnSec = Float64, gestureDelaySec = Float64, gestureFadeSec = Float64,
                           talkHint = String, members = List[Member] }
    pub enum Doc(Rec)
    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/characters.kind.json"

    /// コード側の既定値（人物は置かない。話し方の値は assets/characters.kind.json と同じ）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, talkReach = 2.0, talkAngleDeg = 25.0, headTurnSec = 0.8, headMaxDeg = 70.0, cps = 18.0,
                  bodyTurnSec = 1.1, lingerSec = 1.5, returnSec = 1.8, gestureDelaySec = 0.6, gestureFadeSec = 0.3, talkHint = "Space: 話す", members = Nil })

    pub def fromJson(text: String): Option[Doc] = DocJson.decodeObject(fromRoot, text)

    pub def load(p: String): Doc \ Fs.FileRead = DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, root);
        let members = Map.get("characters", root) |> Option.flatMap(JsonCodec.decodeList(Some)) |> Option.getWithDefault(Nil)
            |> List.filterMap(j -> JsonCodec.expectObject(j) |> Option.flatMap(memberOf));
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root), talkReach = num("talkReach", d#talkReach),
                  talkAngleDeg = num("talkAngleDeg", d#talkAngleDeg), headTurnSec = num("headTurnSec", d#headTurnSec),
                  headMaxDeg = num("headMaxDeg", d#headMaxDeg), cps = num("cps", d#cps),
                  bodyTurnSec = num("bodyTurnSec", d#bodyTurnSec), lingerSec = num("lingerSec", d#lingerSec), returnSec = num("returnSec", d#returnSec),
                  gestureDelaySec = num("gestureDelaySec", d#gestureDelaySec), gestureFadeSec = num("gestureFadeSec", d#gestureFadeSec), talkHint = JsonCodec.stringOr("talkHint", d#talkHint, root),
                  members = members })

    /// 表と同じ約束で読む: [x, y, z] は X を反転・yaw は π − 度（Layout の始まりと同じ）。
    def memberOf(obj: Map[String, Json]): Option[Member] =
        let pos = Map.get("pos", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat)) |> Option.flatMap(xs -> match xs {
            case x :: y :: z :: Nil => Some(Vec3.v3(0.0 - x, y, z))
            case _                  => None
        });
        forM (
            id <- Map.get("id", obj) |> Option.flatMap(JsonCodec.expectString);
            model <- Map.get("model", obj) |> Option.flatMap(JsonCodec.expectString);
            feet <- pos
        ) yield { id = id, model = model, speaker = JsonCodec.stringOr("speaker", id, obj), node = JsonCodec.stringOr("node", id, obj),
                  feet = feet, yaw = Num.pi() - JsonCodec.floatOr("yaw", 0.0, obj) * Num.pi() / 180.0,
                  gestures = Map.get("gestures", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.getWithDefault(Nil) }
}
