// ThemeDoc — rpg.theme.json（色票）の宣言ドキュメント層と、スプライトの意味色キーを
// 実色に解決する resolver。派生色（ハイライト・薬草の葉）は基準色から導く（導出できる値は
// Doc に置かない）。fail-open: 読めない・壊れているときは defaults() へ落とす。
mod ThemeDoc {
    use Util.Json.Json

    /// 画面の色票と幕の暗さ。sky = 夕暮れの空（背景）、path = 道、field = 畑、wall = 石垣、
    /// fog = 霧、paper = ふきだしの紙、ink = 文字と輪郭、accent = 灯り、cloth = 住人の服、
    /// titleVeil / clearVeil = 表紙・クリア画面の幕の暗さ（0〜1）。
    pub type alias Rec = {
        version = Int32,
        sky = Color,
        path = Color,
        field = Color,
        wall = Color,
        fog = Color,
        paper = Color,
        ink = Color,
        accent = Color,
        cloth = Color,
        titleVeil = Float64,
        clearVeil = Float64
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/rpg.theme.json"

    /// 色見本の 6 桁 16 進をそのまま書くための近道。読めない綴りはマゼンタ
    /// （書き間違いが画面で目に見える）。
    def hex(code: String): Color =
        Color.hex(code) |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 })

    /// コード側の既定値（assets/rpg.theme.json と同じ色から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          sky    = hex("#73a6d9"),   // 晴れた昼の空
          path   = hex("#6e5f4e"),   // 道
          field  = hex("#46603f"),   // 畑
          wall   = hex("#55505e"),   // 石垣
          fog    = hex("#b8b4c8"),   // 霧
          paper  = hex("#f2ead8"),   // ふきだしの紙
          ink    = hex("#26222e"),   // 文字と輪郭
          accent = hex("#ffb454"),   // 灯り・主人公の外套
          cloth  = hex("#4f7f9e"),   // 住人の服
          titleVeil = 0.45,
          clearVeil = 0.55 })

    /// テキストから Doc へ（fail-open）。色の表記（#rrggbb）は UiDoc.colorOf に委ねる。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          sky    = colorOr(d#sky, "sky", root),
          path   = colorOr(d#path, "path", root),
          field  = colorOr(d#field, "field", root),
          wall   = colorOr(d#wall, "wall", root),
          fog    = colorOr(d#fog, "fog", root),
          paper  = colorOr(d#paper, "paper", root),
          ink    = colorOr(d#ink, "ink", root),
          accent = colorOr(d#accent, "accent", root),
          cloth  = colorOr(d#cloth, "cloth", root),
          titleVeil = JsonCodec.floatOr("titleVeil", d#titleVeil, root),
          clearVeil = JsonCodec.floatOr("clearVeil", d#clearVeil, root) })

    def colorOr(fallbackColor: Color, key: String, obj: Map[String, Json]): Color =
        Map.get(key, obj)
            |> Option.flatMap(json -> UiDoc.colorOf(Map.empty(), key, json) |> Result.toOption)
            |> Option.getWithDefault(fallbackColor)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)

    // ── 派生色と resolver ──

    /// 白に近づける（ハイライト）。
    pub def lighten(c: Color, k: Float64): Color =
        Color.lighten(c, k)

    /// 黒に近づける（影・くぼみの陰）。
    pub def darken(c: Color, k: Float64): Color =
        Color.darken(c, k)

    /// 屋根の赤茶の基準色（煉瓦の赤 3/4 + 灯りの橙 1/4）。
    def roofBase(doc: Rec): Color =
        Color.mix(doc#accent, Color.rgb(0.47, 0.20, 0.15), 0.74)

    /// 藁の麦わら色の基準（灯りの橙と道の褐色の中間を、彩度を残して沈める）。
    def strawBase(doc: Rec): Color =
        Color.warm(darken(Color.mix(doc#accent, doc#path, 0.45), 0.16), 0.06)

    /// スプライトの意味色キー → 実色。未知のキーはマゼンタ（描き忘れが目に見える）。
    /// wall*/fieldShade は基準色（wall/field）から導く派生色
    /// （導出できる値は Doc に置かない）。
    pub def resolver(d: Doc, key: String): Color =
        let doc = rec(d);
        match key {
            case "accent"      => doc#accent
            case "accentLight" => lighten(doc#accent, 0.5)
            case "cloth"       => doc#cloth
            case "clothLight"  => lighten(doc#cloth, 0.5)
            case "ink"         => doc#ink
            case "paper"       => doc#paper
            case "leaf"        => lighten(doc#field, 0.35)
            case "leafLight"   => lighten(doc#field, 0.60)
            // 人の肌と髪。灯りの色を薄めて肌に、輪郭の色を持ち上げて髪にする
            // （色票に足さずに済む＝調整する物を増やさない）。
            case "skin"        => Color.warm(lighten(doc#accent, 0.55), 0.06)
            case "skinLight"   => Color.warm(lighten(doc#accent, 0.75), 0.04)
            case "hair"        => Color.warm(lighten(doc#ink, 0.22), 0.10)
            // 魔物。畑の緑を寒色へ振って、里の物と見分けがつく色にする。
            case "foe"         => Color.cool(lighten(doc#field, 0.22), 0.14)
            case "foeLight"    => Color.cool(lighten(doc#field, 0.50), 0.10)
            case "wall"        => doc#wall
            case "field"       => doc#field
            // 街タイル・建物（town_*.sprite.json）。素材ごとに「明・中・影・締め」の4階調を
            // 基準色から導く（色票に足すのは導けない色だけ、の原則を崩さない）。
            // 明は warm・影は cool へ寄せ、同じ色の明暗だけの階調にしない。純黒は使わない。
            // 芝（明るい黄緑 〜 深緑）
            case "grassBright" => Color.warm(lighten(doc#field, 0.52), 0.10)
            case "grass"       => lighten(doc#field, 0.30)
            case "grassDark"   => lighten(doc#field, 0.10)
            case "grassDeep"   => Color.cool(darken(doc#field, 0.16), 0.05)
            case "grassLight"  => lighten(doc#field, 0.50)
            // 石畳（暖灰4段階。水路の岸・建物の基礎も同じランプを使う）
            case "paveLight"   => Color.warm(lighten(doc#wall, 0.55), 0.05)
            case "pave"        => Color.warm(lighten(doc#wall, 0.40), 0.04)
            case "paveDark"    => Color.warm(lighten(doc#wall, 0.24), 0.03)
            case "paveDeep"    => Color.warm(lighten(doc#wall, 0.06), 0.02)
            // 水（青緑3段階）
            case "waterGlint"  => Color.cool(lighten(doc#cloth, 0.50), 0.05)
            case "water"       => Color.cool(lighten(doc#cloth, 0.05), 0.08)
            case "waterDeep"   => Color.cool(darken(doc#cloth, 0.22), 0.10)
            case "waterShade"  => Color.cool(darken(doc#cloth, 0.40), 0.10)
            // 漆喰3階調（むらの明・地・影）
            case "plasterHi"   => lighten(doc#paper, 0.05)
            case "plasterMid"  => darken(doc#paper, 0.07)
            case "plasterShade" => darken(doc#paper, 0.24)
            // 屋根の赤茶5階調。灯りの橙だけでは黄に寄りすぎるので、煉瓦の赤へ大きく近づける
            // （accent を混ぜて残すのは、テーマの暖色を変えたとき屋根も一緒に振れるため）。
            // roofLine は最暗の締めだが純黒にはしない（画風宣言）。
            case "roofHi"      => Color.warm(lighten(roofBase(doc), 0.34), 0.10)
            case "roofLight"   => lighten(roofBase(doc), 0.16)
            case "roofMid"     => roofBase(doc)
            case "roofDark"    => darken(roofBase(doc), 0.20)
            case "roofLine"    => darken(roofBase(doc), 0.40)
            // 藁葺き4階調（2棟目の店の屋根。灯りの橙と道の褐色の間の麦わら色）
            case "strawHi"     => Color.warm(lighten(strawBase(doc), 0.25), 0.08)
            case "strawMid"    => strawBase(doc)
            case "strawDark"   => darken(strawBase(doc), 0.18)
            case "strawLine"   => darken(strawBase(doc), 0.36)
            // スレート石屋根4階調（教会。石垣の灰を青みへ近づける — 民家の赤茶と対比）
            case "slateHi"     => Color.cool(lighten(doc#wall, 0.42), 0.06)
            case "slateMid"    => Color.cool(lighten(doc#wall, 0.22), 0.07)
            case "slateDark"   => Color.cool(lighten(doc#wall, 0.04), 0.08)
            case "slateLine"   => Color.cool(darken(doc#wall, 0.20), 0.08)
            // 木3階調（梁・扉・看板。道の暖褐から）
            case "woodLight"   => lighten(doc#path, 0.32)
            case "woodMid"     => lighten(doc#path, 0.10)
            case "woodDark"    => darken(doc#path, 0.28)
            // 窓の室内光2階調（夜色の穴でなく「灯りのある窓」に見せる）
            case "windowLight" => Color.warm(lighten(doc#accent, 0.30), 0.06)
            case "windowDim"   => Color.warm(darken(doc#accent, 0.08), 0.04)
            case "wallTop"     => lighten(doc#wall, 0.18)
            case "wallSide"    => darken(doc#wall, 0.12)
            case "wallShade"   => darken(doc#wall, 0.35)
            case "wallFront"   => darken(doc#wall, 0.22)
            case "fieldShade"  => darken(doc#field, 0.35)
            case _             => { r = 1.0, g = 0.0, b = 1.0 }
        }
}
