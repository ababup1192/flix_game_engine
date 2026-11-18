// ExploreDoc — 町を歩き回る手触りの Doc（assets/explore.json）。歩き・隊列・立ち始め・カメラ・ぶつかり・描き方の重さ。
// 無い・壊れた欄は既定値で続ける。描き方の重さは、実機は環境変数・ブラウザは頁の URL の query で差し替える（qualityWith）。
mod ExploreDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 描き方の重さ（スマホで落とす手）。shadowMapSize = 太陽の影の地図の一辺の画素（0 で影なし）・
    /// depthOfField = 手前と奥のぼけ・post = 画面全体のポストプロセス。
    pub type alias Quality = { shadowMapSize = Int32, depthOfField = Bool, post = Bool }

    /// つまみ。
    /// speed = 歩く速さ（m/秒・スティックは倒した量を掛ける）・walkFrameSec = 歩きのコマを替える秒・radius = 先頭をぶつける円の半径（m）・
    /// spacing = 隊列の間（m）・party = 隊列（先頭から）・idleFrameSec・idlePhaseSec = 待機モーションのコマを替える秒と、1 人ごとのずれ・
    /// startCol・startRow・startFace = 先頭が立つマスと向き・
    /// feetV = 先頭の足元を写す画面の高さ（上の端 0・下の端 1）・walkZoom = カメラの引き（足元の点からの距離の倍率）・
    /// heightLagK = カメラの高さが足元の高さを遅れて追う速さ（/秒）・aheadMeters・aheadRate = 歩く向きへ先を見せる長さ（m・0 で見せない）と寄る速さ（/秒）・
    /// frameWidth・frameV・frameTargetZ = 引き 1 の時の写す範囲（高さ frameTargetZ の地面の点を画面の上から frameV に置き、その奥行きで画面の横幅が frameWidth m）・
    /// seenHeight・hideReach = 建物の北で、足元からこの高さ（m）の点が建物に隠れるマスを塞ぐ（北へ hideReach 行まで）・quality = 描き方の重さの既定・
    /// quitPrompt = 終了の確認の窓の文言。
    pub type alias Rec = { speed = Float64, walkFrameSec = Float64, radius = Float64,
                           spacing = Float64, party = List[Walkers.Walker], idleFrameSec = Float64, idlePhaseSec = Float64,
                           startCol = Int32, startRow = Int32, startFace = Facing.Dir,
                           feetV = Float64, walkZoom = Float64, heightLagK = Float64, aheadMeters = Float64, aheadRate = Float64,
                           frameWidth = Float64, frameV = Float64, frameTargetZ = Float64,
                           seenHeight = Float64, hideReach = Int32, quality = Quality, quitPrompt = String }

    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/explore.json"

    /// 既定の隊列（旅人・商人・女の子）。
    def defaultParty(): List[Walkers.Walker] =
        let w = (name: String) -> { strip = "sprites/${name}_walk4.png", idleStrip = "sprites/${name}_idle.png", dirs = "nes" };
        w("traveler") :: w("merchant") :: w("girl") :: Nil

    pub def defaults(): Doc = Doc.Doc(defaultRec())

    def defaultRec(): Rec =
        { speed = 4.85, walkFrameSec = 0.24, radius = 0.3,
          spacing = 1.0, party = defaultParty(), idleFrameSec = 0.8, idlePhaseSec = 0.27,
          startCol = 13, startRow = 54, startFace = Facing.Dir.North,
          feetV = 0.62, walkZoom = 1.35, heightLagK = 12.0, aheadMeters = 0.0, aheadRate = 2.0,
          frameWidth = 16.3, frameV = 0.72, frameTargetZ = 1.25,
          seenHeight = 0.9, hideReach = 8, quality = { shadowMapSize = 4096, depthOfField = true, post = true },
          quitPrompt = "終了しますか？（Enter: はい / Esc: いいえ）" }

    /// テキストから Doc へ。JSON のオブジェクトでなければ None。
    pub def fromJson(text: String): Option[Doc] = DocJson.decodeObject(decode, text)

    /// path の Doc を読む。無ければ黙って既定値・読めなければ 1 行言って既定値。
    pub def load(p: String): Doc \ Fs.FileRead = DocJson.loadOr(fromJson, defaults(), p)

    def decode(m: Map[String, Json]): Doc =
        let d = defaultRec();
        let num = (key: String, fallback: Float64) -> JsonCodec.floatOr(key, fallback, m);
        let q = Map.get("quality", m) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
        let party = Map.get("party", m) |> Option.flatMap(JsonCodec.decodeList(walkerOf)) |> Option.map(List.filterMap(identity))
            |> Option.flatMap(ws -> if (List.isEmpty(ws)) None else Some(ws)) |> Option.getWithDefault(d#party);
        Doc.Doc({
            speed = num("speed", d#speed), walkFrameSec = num("walkFrameSec", d#walkFrameSec), radius = num("radius", d#radius),
            spacing = num("spacing", d#spacing), party = party,
            idleFrameSec = num("idleFrameSec", d#idleFrameSec), idlePhaseSec = num("idlePhaseSec", d#idlePhaseSec),
            startCol = JsonCodec.intOr("startCol", d#startCol, m), startRow = JsonCodec.intOr("startRow", d#startRow, m),
            startFace = Facing.ofLetter(JsonCodec.stringOr("startFace", Facing.letterOf(d#startFace), m)),
            feetV = num("feetV", d#feetV), walkZoom = num("walkZoom", d#walkZoom), heightLagK = num("heightLagK", d#heightLagK),
            aheadMeters = num("aheadMeters", d#aheadMeters), aheadRate = num("aheadRate", d#aheadRate),
            frameWidth = num("frameWidth", d#frameWidth), frameV = num("frameV", d#frameV), frameTargetZ = num("frameTargetZ", d#frameTargetZ),
            seenHeight = num("seenHeight", d#seenHeight), hideReach = JsonCodec.intOr("hideReach", d#hideReach, m),
            quality = { shadowMapSize = JsonCodec.intOr("shadowMapSize", d#quality#shadowMapSize, q),
                        depthOfField = JsonCodec.boolOr("depthOfField", d#quality#depthOfField, q),
                        post = JsonCodec.boolOr("post", d#quality#post, q) },
            quitPrompt = JsonCodec.stringOr("quitPrompt", d#quitPrompt, m) })

    /// 隊列の 1 人（strip の無い人は飛ばす）。
    def walkerOf(j: Json): Option[Option[Walkers.Walker]] =
        JsonCodec.expectObject(j) |> Option.map(o -> {
            let strip = JsonCodec.stringOr("strip", "", o);
            if (strip == "") None
            else Some({ strip = "sprites/${strip}", idleStrip = "sprites/${JsonCodec.stringOr("idleStrip", strip, o)}",
                        dirs = JsonCodec.stringOr("dirs", "nes", o) })
        })

    /// 描き方の重さを、つまみの表 knobs（実機は環境変数・ブラウザは頁の URL の query）で差し替える。
    /// shadow = 影の地図の一辺（0 で影なし）・dof = 0 / 1・post = 0 / 1。知らない値は Doc のまま。
    pub def qualityWith(knobs: Map[String, String], q: Quality): Quality =
        let flag = (key: String, fallback: Bool) -> match Map.get(key, knobs) {
            case Some("0") => false
            case Some("1") => true
            case _         => fallback
        };
        { shadowMapSize = Map.get("shadow", knobs) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(q#shadowMapSize),
          depthOfField = flag("dof", q#depthOfField), post = flag("post", q#post) }
}
