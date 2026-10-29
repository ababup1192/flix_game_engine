// Flag — 名前付きの旗の名前（FlagId）。物が立て、別の物や会話が読む。物の行（MapDoc）・立っている旗（Progress）・
// セーブ（Saves）のどれからも使うので、どれも使わない下の層に置く。
// 名前から作るのは読む所だけ（JSON の字・Starts の flags=）。
// WhyNot: コードの中で名前を書いて作る口を出さない — 書き損じた旗はどの物も立てず、読む側の扉が黙って開かなくなる。
mod Flag {
    use Util.Json.Json
    use fge::JsonCodec

    enum FlagKey with Eq, Order, ToString {
        case Key(String)
    }

    /// 旗の名前（作るのは fromJson と listOfArg だけ）。
    pub type alias FlagId = FlagKey

    /// JSON の字の旗（物の行の欄・セーブの flags の 1 つ）。字でない・空の字は None。
    pub def fromJson(json: Json): Option[FlagId] =
        JsonCodec.expectString(json) |> Option.filter(name -> not String.isEmpty(name)) |> Option.map(FlagKey.Key)

    /// Starts の flags=（, で区切った名前。空の名前は飛ばす）。
    pub def listOfArg(text: String): List[FlagId] =
        text |> String.splitOn(substr = ",") |> List.map(String.trim) |> List.filter(name -> not String.isEmpty(name)) |> List.map(FlagKey.Key)

    /// 書く名前（セーブ）。
    pub def nameOf(flag: FlagId): String = match flag { case FlagKey.Key(name) => name }
}
