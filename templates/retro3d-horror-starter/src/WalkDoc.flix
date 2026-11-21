// WalkDoc — walk.kind.json（歩きの手触り）の宣言ドキュメント層。
// 歩く速さと走る速さ・向きを変える速さ・見上げ見下ろしの速さと限り・目の高さ・体の大きさ・頭の揺れ・部屋の名前の字幕の決まり・終了の確認の文言・しばらく操作しないと出る操作方法の表示。
// 歩き方の規則（壁で滑る・坂を上る）はコード（World と engine の CharacterBody3d）。
// fail-open — 読めない・壊れているときは defaults() へ落とす。
mod WalkDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 操作方法の表示を置く画面の隅。
    pub enum Corner with Eq {
        case TopLeft
        case TopRight
        case BottomLeft
        case BottomRight
    }

    /// 操作方法の表示。wait = 何も操作しない秒がこれだけ続いたら出す・fade = 出る・消える秒・alpha = 濃さ（「話す」の印の濃さに掛ける）・
    /// corner = 置く隅・margin = 画面の縁からの間（design px）・touchLines = 指の端末で出す行（仮想パッドの説明）。
    pub type alias Hint = { wait = Float64, fade = Float64, alpha = Float64, corner = Corner, margin = Float64, touchLines = List[String] }

    pub type alias Rec = {
        version = Int32,
        speed = Float64,
        backSpeed = Float64,
        dashSpeed = Float64,
        dashStride = Float64,
        turnDegPerSec = Float64,
        mouseDegPerPx = Float64,
        pitchDegPerSec = Float64,
        pitchLimitDeg = Float64,
        eyeHeight = Float64,
        radius = Float64,
        height = Float64,
        bob = Float64,
        stride = Float64,
        signReach = Float64,
        captionAngleDeg = Float64,
        captionDelay = Float64,
        captionFade = Float64,
        captionSize = Float64,
        captionOn = Bool,
        quitPrompt = String,
        hint = Hint
    }
    pub enum Doc(Rec)
    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/walk.kind.json"

    /// コード側の既定値（assets/walk.kind.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, speed = 1.3, backSpeed = 0.8, dashSpeed = 2.4, dashStride = 0.9, turnDegPerSec = 80.0, mouseDegPerPx = 0.15, pitchDegPerSec = 60.0, pitchLimitDeg = 60.0,
                  eyeHeight = 1.5, radius = 0.25, height = 1.6, bob = 0.025, stride = 0.7, signReach = 4.0, captionAngleDeg = 35.0, captionDelay = 0.25, captionFade = 0.3, captionSize = 20.0, captionOn = false,
                  quitPrompt = "やめますか  Enter: はい / Esc: いいえ",
                  hint = { wait = 7.0, fade = 0.4, alpha = 0.8, corner = Corner.BottomLeft, margin = 6.0,
                           touchLines = "移動・向き　十字キー" :: "走る　「走る」を押したまま" :: "調べる　「調べる」" :: "持ち物　「持ち物」" :: "地図　「地図」" :: Nil } })

    pub def fromJson(text: String): Option[Doc] = DocJson.decodeObject(fromRoot, text)

    pub def load(p: String): Doc \ Fs.FileRead = DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, root);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  speed = num("speed", d#speed), backSpeed = num("backSpeed", d#backSpeed),
                  dashSpeed = num("dashSpeed", d#dashSpeed), dashStride = num("dashStride", d#dashStride),
                  turnDegPerSec = num("turnDegPerSec", d#turnDegPerSec), mouseDegPerPx = num("mouseDegPerPx", d#mouseDegPerPx),
                  pitchDegPerSec = num("pitchDegPerSec", d#pitchDegPerSec), pitchLimitDeg = num("pitchLimitDeg", d#pitchLimitDeg),
                  eyeHeight = num("eyeHeight", d#eyeHeight), radius = num("radius", d#radius), height = num("height", d#height),
                  bob = num("bob", d#bob), stride = num("stride", d#stride), signReach = num("signReach", d#signReach),
                  captionAngleDeg = num("captionAngleDeg", d#captionAngleDeg), captionDelay = num("captionDelay", d#captionDelay),
                  captionFade = num("captionFade", d#captionFade), captionSize = num("captionSize", d#captionSize),
                  captionOn = JsonCodec.boolOr("captionOn", d#captionOn, root),
                  quitPrompt = JsonCodec.stringOr("quitPrompt", d#quitPrompt, root),
                  hint = { wait = num("hintWait", d#hint#wait), fade = num("hintFade", d#hint#fade), alpha = num("hintAlpha", d#hint#alpha),
                           corner = Map.get("hintCorner", root) |> Option.flatMap(JsonCodec.expectString) |> Option.flatMap(cornerOf) |> Option.getWithDefault(d#hint#corner),
                           margin = num("hintMargin", d#hint#margin),
                           touchLines = Map.get("hintTouchLines", root) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.getWithDefault(d#hint#touchLines) } })

    /// 隅の名前（TopLeft・TopRight・BottomLeft・BottomRight）→ Corner。知らない名前は None。
    def cornerOf(name: String): Option[Corner] = match name {
        case "TopLeft"     => Some(Corner.TopLeft)
        case "TopRight"    => Some(Corner.TopRight)
        case "BottomLeft"  => Some(Corner.BottomLeft)
        case "BottomRight" => Some(Corner.BottomRight)
        case _             => None
    }
}
