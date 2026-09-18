// RivalsDoc — race.rivals.json（敵の性格と追いかけ方）の宣言ドキュメント層。
// 「難易度の調整」で読み直したい値だけを持つ（手触りの調整は RulesDoc — 関心が違うので Doc を分ける）。
//   - ラバーバンド: 自機との距離差でライバルの速度を補正する強さ（離されると速く・千切ると遅く）。
//   - rows: ライバル 1 台 = 1 行。台数を増減するとレースの台数が変わる。
// 追いかける・避ける・コーナーで減速するの規則そのものはコード（World）側。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod RivalsDoc {
    use Util.Json.Json

    /// ライバル 1 台の性格。
    ///   speed  … 基本の速さ（px/秒。補正が掛かる前の地力）。
    ///   corner … コーナーの上手さ（0..1。1 = 減速なしで曲がる、0 = 大きく減速する）。
    ///   lane   … 好みの走行位置（-1..1。0 = 道の真ん中、負 = 左寄り、正 = 右寄り）。
    pub type alias Entry = { speed = Float64, corner = Float64, lane = Float64 }

    /// 敵の性格と追いかけ方。
    ///   rubberRange    … 補正が最大になる自機との距離差（px）。
    ///   rubberCatchUp  … 離されたときの加速の上限（0.45 = +45%）。
    ///   rubberSlowDown … 先行したときの減速の上限（0.22 = -22%）。
    ///   laneChangeSpeed … 横へ寄る速さ（px/秒）。
    ///   cornerSlow     … コーナーが下手な敵（corner = 0）が急カーブで落とす速度の底（0..1）。
    pub type alias Rec = {
        version = Int32,
        rubberRange = Float64,
        rubberCatchUp = Float64,
        rubberSlowDown = Float64,
        laneChangeSpeed = Float64,
        cornerSlow = Float64,
        rows = List[Entry]
    }

    // 型検査が record を展開しないため、World が持つ公開の型は enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/race.rivals.json"

    /// コード側の既定値（assets/race.rivals.json と同じ値から出発する）。
    /// 3 台の役割: 逃げ役（直線で速いがコーナーで大きく膨らむ）/ ブロック役（平均・右寄りで
    /// 進路を塞ぐ）/ 職人（遅いがコーナーほぼ減速なし — ブレーキで曲がると抜き返される）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          rubberRange = 220.0,
          rubberCatchUp = 0.45,
          rubberSlowDown = 0.22,
          laneChangeSpeed = 140.0,
          cornerSlow = 0.70,
          rows =
              { speed = 127.0, corner = 0.3,  lane = -0.9 }
           :: { speed = 120.0, corner = 0.6,  lane = 0.9 }
           :: { speed = 115.0, corner = 0.95, lane = 0.0 }
           :: Nil })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          rubberRange = JsonCodec.floatOr("rubberRange", d#rubberRange, root),
          rubberCatchUp = JsonCodec.floatOr("rubberCatchUp", d#rubberCatchUp, root),
          rubberSlowDown = JsonCodec.floatOr("rubberSlowDown", d#rubberSlowDown, root),
          laneChangeSpeed = JsonCodec.floatOr("laneChangeSpeed", d#laneChangeSpeed, root),
          cornerSlow = JsonCodec.floatOr("cornerSlow", d#cornerSlow, root),
          rows = rowsOr(d#rows, root) })

    /// rows（ライバルの一覧）を読む。配列でない・空のときは既定の 3 台を使う。
    /// 1 台ぶんの欄が欠けた行は、その欄だけ既定 1 台目の値を使う（行ごと捨てない）。
    def rowsOr(fallback: List[Entry], root: Map[String, Json]): List[Entry] =
        Map.get("rows", root)
            |> Option.flatMap(JsonCodec.decodeList(entryOf))
            |> Option.filter(rows -> not List.isEmpty(rows))
            |> Option.getWithDefault(fallback)

    /// ライバル 1 行を読む。オブジェクトでなければ捨てる（None）。
    def entryOf(json: Json): Option[Entry] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { speed = JsonCodec.floatOr("speed", 105.0, obj),
              corner = JsonCodec.floatOr("corner", 0.6, obj),
              lane = JsonCodec.floatOr("lane", 0.0, obj) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
