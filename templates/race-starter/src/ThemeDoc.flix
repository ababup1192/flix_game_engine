// ThemeDoc — race.theme.json（画面の色票）の宣言ドキュメント層。
// 真夏の海岸ハイウェイの色。空・海・草・路面・縁石と、マシン 4 台ぶんの色、炎と煙を持つ。
// 派生色（明るめ・暗め・遠くの霞み）は基準色から導ける範囲はコードで導く（導出できる値は
// Doc に置かない）。ドット絵の細かい色（タイヤ・キャノピー等）は別ファイル
// race.palette.json（PaletteDoc）— 画面の大きな配色と、ドット絵のパレットは関心が違う。
// fail-open: 読めない・壊れているときは defaults() へ落とす。
mod ThemeDoc {
    use Util.Json.Json

    /// 画面の色票。
    ///   skyTop / skyLow … 空のグラデ（上端 / 地平線）。
    ///   sea             … 海。きらめきはコードで明るめに導く。
    ///   grass / road    … 草地と路面。行ごとの縞はコードで明暗に振る。
    ///   sand            … 乾いた砂（路肩の筋・草の轍・海ぎわの浜）。
    ///   lane            … 路面の中央白線。
    ///   kerb            … 縁石の赤（白側は finish を使う）。
    ///   player / rivalA..C … マシンの車体色（ドット絵の body をこの色で塗り替える）。
    ///   flame / smoke   … ニトロの炎とドリフトの煙。
    ///   finish / text   … ゴール・白線の白と、HUD の文字。
    pub type alias Rec = {
        version = Int32,
        skyTop = Color,
        skyLow = Color,
        sea = Color,
        grass = Color,
        road = Color,
        sand = Color,
        lane = Color,
        kerb = Color,
        player = Color,
        rivalA = Color,
        rivalB = Color,
        rivalC = Color,
        flame = Color,
        smoke = Color,
        finish = Color,
        text = Color
    }

    // 型検査が record を展開しないため、World が持つ公開の型は enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/race.theme.json"

    /// 色見本の 6 桁 16 進をそのまま書くための近道。読めない綴りはマゼンタ
    /// （書き間違いが画面で目に見える）。
    def hex(code: String): Color =
        Color.hex(code) |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 })

    /// コード側の既定値（assets/race.theme.json と同じ色から出発する）。
    /// 真夏の昼。空は青く、海は光り、路面は白く灼けている。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          skyTop = hex("#1f86dd"),   // 空の上端（コバルト）
          skyLow = hex("#c2e7fc"),   // 地平線ぎわ（淡い水色）
          sea    = hex("#1273b8"),   // 海
          grass  = hex("#58b84e"),   // 草地
          road   = hex("#8a91a4"),   // 灼けたアスファルト
          sand   = hex("#dcc98f"),   // 乾いた砂（路肩・轍・浜）
          lane   = hex("#f4f7fa"),   // 中央の白線
          kerb   = hex("#d63a4a"),   // 縁石の赤
          player = hex("#e63946"),   // 自機（赤）
          rivalA = hex("#2e6fe0"),   // ライバル A（青）
          rivalB = hex("#f6a800"),   // ライバル B（黄）
          rivalC = hex("#8a4fd0"),   // ライバル C（紫）
          flame  = hex("#ff7a1a"),   // ニトロの炎（芯はコードで白へ導く）
          smoke  = hex("#f2f5f8"),   // ドリフトの白煙
          finish = hex("#eceff2"),   // ゴール・縁石の白
          text   = hex("#ffffff") })  // HUD の文字

    // ── 導出色（基準色から導けるので Doc には置かない） ──

    /// 遠くの路面・景色が空気に溶けていく先の色（昼の霞み = 地平線ぎわの空の色へ近づける）。
    pub def hazeTo(doc: Doc): Color = rec(doc)#skyLow

    /// 草地の影側。日向側の grassLight と色相でも分ける（明暗だけだと縞が金属的に見える）。
    pub def grassDark(doc: Doc): Color = Color.cool(Color.darken(rec(doc)#grass, 0.22), 0.12)

    /// 草地の日向側。
    pub def grassLight(doc: Doc): Color = Color.warm(Color.lighten(rec(doc)#grass, 0.12), 0.18)

    /// 路面の縞の明るい側。
    pub def roadLight(doc: Doc): Color = Color.lighten(rec(doc)#road, 0.07)

    /// 海のきらめき（白い短線）の色。
    pub def seaGlint(doc: Doc): Color = Color.lighten(rec(doc)#sea, 0.65)

    /// ニトロの炎の芯（外側 flame → 芯は白熱）。
    pub def flameCore(doc: Doc): Color = Color.mix(rec(doc)#flame, rec(doc)#text, 0.75)

    /// 炎の中ほど（芯の白と外炎のあいだの黄）。芯・中・裾の 3 段階があると
    /// 噴射炎が単色の塊にならない。
    pub def flameHot(doc: Doc): Color = Color.warm(Color.lighten(rec(doc)#flame, 0.3), 0.35)

    /// 炎の裾（燃え切る手前の赤）。
    pub def flameDeep(doc: Doc): Color = Color.warm(Color.darken(rec(doc)#flame, 0.42), -0.18)

    /// 火花の色（炎を少し黄へ近づける）。
    pub def spark(doc: Doc): Color = Color.warm(Color.lighten(rec(doc)#flame, 0.25), 0.2)

    /// すすけた煙・飛び散る破片の暗い側。白煙だけだと雲の塊にしか見えないので、
    /// 煙の階調と破片の色をここから引く。
    pub def ash(doc: Doc): Color = Color.darken(Color.cool(rec(doc)#smoke, 0.16), 0.5)

    /// テキストから Doc へ（fail-open）。色の表記（#rrggbb）は UiDoc.colorOf に委ねる。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          skyTop = colorOr(d#skyTop, "skyTop", root),
          skyLow = colorOr(d#skyLow, "skyLow", root),
          sea    = colorOr(d#sea, "sea", root),
          grass  = colorOr(d#grass, "grass", root),
          road   = colorOr(d#road, "road", root),
          sand   = colorOr(d#sand, "sand", root),
          lane   = colorOr(d#lane, "lane", root),
          kerb   = colorOr(d#kerb, "kerb", root),
          player = colorOr(d#player, "player", root),
          rivalA = colorOr(d#rivalA, "rivalA", root),
          rivalB = colorOr(d#rivalB, "rivalB", root),
          rivalC = colorOr(d#rivalC, "rivalC", root),
          flame  = colorOr(d#flame, "flame", root),
          smoke  = colorOr(d#smoke, "smoke", root),
          finish = colorOr(d#finish, "finish", root),
          text   = colorOr(d#text, "text", root) })

    def colorOr(fallbackColor: Color, key: String, obj: Map[String, Json]): Color =
        Map.get(key, obj)
            |> Option.flatMap(json -> UiDoc.colorOf(Map.empty(), key, json) |> Result.toOption)
            |> Option.getWithDefault(fallbackColor)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
