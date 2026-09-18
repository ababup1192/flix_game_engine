// Theme — theme.json(色)の宣言ドキュメント層。画風「夕方の空気」の色は全部ここ。
// legend の色キー(sprite.json)と View の空・遠景の色を 1 枚の表で持つ。
// 既定はコード側(defaults)。theme.json は上書きしたい色だけ書けばよい(fail-open)。
//
// 画風の決まり(AGENTS.local.md): 夕空の青 / コインの金 / 影の藍。黒は使わない —
// 最暗部も ink(藍 #23283A)まで。
mod Theme {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JString}

    pub type alias Rec = { version = Int32, colors = Map[String, Color] }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/platformer.theme.json"

    def c(r: Int32, g: Int32, b: Int32): Color = Color.rgb8(r, g, b)

    /// 全色キーの既定値。sprite の legend が使う名前 + View の空気の名前。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, colors = Map#{
            // 輪郭と暗部(黒の代わり)
            "ink" => c(35, 40, 58),
            // 地形
            "dirt" => c(107, 91, 62), "dirtDark" => c(87, 73, 47), "dirtLight" => c(138, 122, 85),
            "grass" => c(181, 160, 58), "grassDark" => c(138, 122, 42),
            "stone" => c(122, 126, 140), "stoneDark" => c(90, 94, 110), "stoneLight" => c(154, 160, 176),
            "wallCave" => c(58, 62, 82), "wallCaveDark" => c(46, 50, 68),
            "plank" => c(138, 107, 58), "plankDark" => c(110, 85, 48),
            "metal" => c(176, 184, 196), "metalDark" => c(122, 130, 144),
            // 報酬と主役(暖色)
            "coin" => c(224, 178, 63), "coinDark" => c(138, 100, 16), "coinLight" => c(245, 208, 128),
            "flag" => c(224, 178, 63), "pole" => c(87, 73, 47),
            "torchWood" => c(110, 85, 48), "flame" => c(232, 160, 85), "flameCore" => c(245, 208, 128),
            "skin" => c(232, 192, 154), "hair" => c(87, 73, 47),
            "shirt" => c(217, 147, 47), "shirtDark" => c(166, 106, 30),
            "pants" => c(62, 90, 125), "boots" => c(87, 73, 47),
            // 敵(寒色寄り — 主役との分離)
            "enemyA" => c(122, 74, 138), "enemyADark" => c(90, 52, 104),
            "enemyB" => c(74, 125, 138), "enemyBDark" => c(53, 96, 108),
            "enemyC" => c(138, 74, 74), "enemyCDark" => c(108, 53, 53),
            "shot" => c(232, 106, 90), "heart" => c(232, 106, 122),
            "dust" => c(200, 186, 150),   // 着地・バネの砂煙
            "eyeWhite" => c(251, 250, 246),
            // 空気(View が引く)
            "skyTop" => c(74, 127, 168), "skyBottom" => c(232, 185, 106),
            "sun" => c(232, 194, 90),
            "bgMountain" => c(70, 96, 140), "bgMountainDark" => c(58, 76, 116),
            "bgRim" => c(201, 162, 90),
            "bgHill" => c(78, 116, 136), "bgHillDark" => c(64, 96, 111),
            "bgForest" => c(53, 82, 92), "bgForestDark" => c(44, 68, 80),
            "cloud" => c(240, 232, 220), "cloudShade" => c(214, 198, 186),
            "caveTop" => c(28, 32, 48), "caveBottom" => c(40, 44, 66),
            "towerTop" => c(53, 96, 140), "towerBottom" => c(201, 138, 106)
        } })

    /// 色キー → 実色。知らないキーは ink(描き忘れが黒穴でなく藍で出る — 気づける)。
    pub def resolve(doc: Doc, key: String): Color =
        Map.get(key, rec(doc)#colors)
            |> Option.getWithDefault(Map.get("ink", rec(defaults())#colors)
                |> Option.getWithDefault(Color.rgb(1.0, 1.0, 1.0)))

    /// { "colors": { "名前": "#RRGGBB" } } の形。壊れは既定へ(fail-open)。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let over = match Map.get("colors", root) {
            case Some(JObject(obj)) =>
                obj |> Map.foldLeftWithKey((acc, k, v) -> match v {
                    case JString(s) => match Color.hex(s) {
                        case Some(col) => Map.insert(k, col, acc)
                        case None      => acc
                    }
                    case _ => acc
                }, Map.empty())
            case _ => Map.empty()
        };
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          colors = Map.foldLeftWithKey((acc, k, v) -> Map.insert(k, v, acc), d#colors, over) })

    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
