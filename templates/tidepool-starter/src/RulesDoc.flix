// RulesDoc — tidepool.rules.json（潮の既定の満ち引き・貝殻の幅・動きの秒・先読みの濃さ・取り消しの数）の Doc 層。
// 水の広がり・押す表・行ける条件はコード（Tide・World）。ここに if を書き始めたら Doc の境界を越えている。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod RulesDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 遊びの決まりの値。
    ///   cycle          … 手数 t → 潮位の表の既定（面の Doc に cycle があれば面が勝つ）。
    ///   shellWidth     … 貝殻 2 個の幅（手数が par + 幅 以下なら 2 個、par 以下なら 3 個）。
    ///   tweenSeconds   … 1 手の水位の変化をつなぐ秒。
    ///   forecastAlpha  … 先読み（次の手で沈む・現れるマス）の重ねの濃さ（0..1）。
    ///   undoCap        … 取り消しで戻れる手の数。
    ///   quitPrompt     … 終了の確認の文言。
    pub type alias Rec = {
        version = Int32,
        cycle = List[Int32],
        shellWidth = Int32,
        tweenSeconds = Float64,
        forecastAlpha = Float64,
        undoCap = Int32,
        quitPrompt = String
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/tidepool.rules.json"

    /// コード側の既定値（assets/tidepool.rules.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          cycle = 0 :: 1 :: 2 :: 3 :: 2 :: 1 :: Nil,
          shellWidth = 3,
          tweenSeconds = 0.35,
          forecastAlpha = 0.5,
          undoCap = 512,
          quitPrompt = "やめますか?  Enter: はい  /  Esc: いいえ" })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          cycle = cycleOr(d#cycle, "cycle", root),
          shellWidth = JsonCodec.intOr("shellWidth", d#shellWidth, root),
          tweenSeconds = JsonCodec.floatOr("tweenSeconds", d#tweenSeconds, root),
          forecastAlpha = JsonCodec.floatOr("forecastAlpha", d#forecastAlpha, root),
          undoCap = JsonCodec.intOr("undoCap", d#undoCap, root),
          quitPrompt = JsonCodec.stringOr("quitPrompt", d#quitPrompt, root) })

    /// 潮位の表を読む。配列でない・数でない物が混じる・空のときは fallback（levels の Doc も同じ読み方）。
    def cycleOr(fallback: List[Int32], key: String, obj: Map[String, Json]): List[Int32] =
        cycleAt(key, obj) |> Option.getWithDefault(fallback)

    /// 潮位の表があれば読む（無い・壊れている・空なら None）。
    pub def cycleAt(key: String, obj: Map[String, Json]): Option[List[Int32]] =
        Map.get(key, obj)
            |> Option.flatMap(json -> JsonCodec.decodeList(JsonCodec.expectInt, json))
            |> Option.filter(xs -> not List.isEmpty(xs))

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
