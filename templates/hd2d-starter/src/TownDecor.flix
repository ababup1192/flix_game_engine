// TownDecor — 広場の小物と NPC の Doc（assets/*.decor.json の props の list）を読む。1 件 = 地図のマスに立てる板 1 枚。
mod TownDecor {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 小物の板 1 枚。sprite = 絵（assets からの相対）・col・row = マス・
    /// offX・offY = マスの真ん中からのずれ（m・offY は北が正）・z = 地面からの高さ（m）・frames・frameSec・seq・phase = 横 1 列の絵のコマ・
    /// flip = 左右を裏返す・sway = 揺れ（振れ幅 m と周期 秒）・shadow = 影の付け方・height = 板の高さ（m・無ければ絵の高さ）・
    /// passable = 歩いて通れるか（鳩や宙の風船）。
    pub type alias Decor = { sprite = String, col = Int32, row = Int32, offX = Float64, offY = Float64, z = Float64,
                             frames = Int32, frameSec = Float64, seq = List[Int32], phase = Float64, flip = Bool,
                             sway = Option[(Float64, Float64)], shadow = DecorShadow, height = Option[Float64], passable = Bool }

    /// 小物の板の影（Doc の shadow = 足元の影・cast = 太陽の影を落とす の組）。
    pub enum DecorShadow with Eq {
        case Full
        case FootOnly
        case CastOnly
        case NoShadow
    }

    /// 足元の影を置くか。
    pub def hasFootShadow(s: DecorShadow): Bool = s == DecorShadow.Full or s == DecorShadow.FootOnly

    /// 太陽の影を落とすか。
    pub def castsShadow(s: DecorShadow): Bool = s == DecorShadow.Full or s == DecorShadow.CastOnly

    /// path の小物を読む。
    pub def load(path: String): Result[String, List[Decor]] \ Fs.FileRead =
        DocJson.readJson(path)
            |> Result.mapErr(e -> "${path}: ${DocJson.describe(e)}")
            |> Result.flatMap(json -> decode(json) |> Result.mapErr(why -> "${path}: ${why}"))

    /// JSON の props の list を読む（sprite の無い件は飛ばす）。
    pub def decode(json: Json): Result[String, List[Decor]] =
        JsonCodec.expectObject(json) |> Option.flatMap(Map.get("props")) |> Option.flatMap(JsonCodec.decodeList(decorOf))
            |> Option.map(List.filterMap(identity)) |> Option.toOk("props が list でない")

    def shadowOf(foot: Bool, cast: Bool): DecorShadow =
        if (foot and cast) DecorShadow.Full else if (foot) DecorShadow.FootOnly else if (cast) DecorShadow.CastOnly else DecorShadow.NoShadow

    def decorOf(j: Json): Option[Option[Decor]] =
        JsonCodec.expectObject(j) |> Option.map(o -> {
            let num = (key: String, fallback: Float64) -> JsonCodec.floatOr(key, fallback, o);
            let toInt = (v: Float64) -> Float64.round(v) |> Float64.tryToInt32 |> Option.getWithDefault(0);
            let sprite = JsonCodec.stringOr("sprite", "", o);
            if (sprite == "") None
            else Some({ sprite = "sprites/${sprite}",
                        col = JsonCodec.intOr("col", 0, o), row = JsonCodec.intOr("row", 0, o), offX = num("offX", 0.0), offY = num("offY", 0.0), z = num("z", 0.0),
                        frames = JsonCodec.intOr("frames", 1, o), frameSec = num("frameSec", 0.8),
                        seq = Map.get("seq", o) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat)) |> Option.getWithDefault(Nil) |> List.map(toInt),
                        phase = num("phase", 0.0), flip = JsonCodec.boolOr("flip", false, o),
                        sway = if (num("swayAmp", 0.0) > 0.0) Some((num("swayAmp", 0.0), Float64.max(0.01, num("swaySec", 1.0)))) else None,
                        shadow = shadowOf(JsonCodec.boolOr("shadow", true, o), JsonCodec.boolOr("cast", true, o)),
                        height = Map.get("height", o) |> Option.flatMap(JsonCodec.expectFloat),
                        passable = JsonCodec.boolOr("passable", false, o) })
        })
}
