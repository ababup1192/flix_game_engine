// ThemeDoc — tetris.theme.json（色票）の宣言ドキュメント層と、ミノの種類 → 実色の resolver。
// 盤・枠・ゴースト・閃光の色と、7 ミノの定番配色（I=シアン, O=黄, T=紫, S=緑, Z=赤, J=青, L=橙）を持つ。
// 派生色（ゴーストの薄めなど）は基準色から導ける範囲はコードで導く（導出できる値は Doc に置かない）。
// fail-open: 読めない・壊れているときは defaults() へ落とす。
mod ThemeDoc {
    use Util.Json.Json
    use World.Kind

    /// 画面の色票。bg = 盤の外の背景、board = 盤の中の背景（bg よりわずかに明るい）、
    /// grid = マス目の線（薄い）、wall = 盤を囲う枠、ghost = 着地予測の色、
    /// flash = ライン消しの閃光（白系）、colorI..colorL = 7 ミノの色。
    pub type alias Rec = {
        version = Int32,
        bg = Color,
        board = Color,
        grid = Color,
        wall = Color,
        ghost = Color,
        flash = Color,
        colorI = Color,
        colorO = Color,
        colorT = Color,
        colorS = Color,
        colorZ = Color,
        colorJ = Color,
        colorL = Color
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/tetris.theme.json"

    /// 色見本の 6 桁 16 進をそのまま書くための近道。読めない綴りはマゼンタ
    /// （書き間違いが画面で目に見える）。
    def hex(code: String): Color =
        Color.hex(code) |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 })

    /// コード側の既定値（assets/tetris.theme.json と同じ色から出発する）。
    /// 生成りの紙に版で刷った色、という見立ての色票。ミノの色は蛍光色にせず、
    /// インクらしく彩度を落としてある（紙の上で 7 色が喧嘩しない）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          bg     = hex("#efe6d2"),   // 盤外の紙
          board  = hex("#dccfae"),   // 盤の中（紙が一段沈んで見える）
          grid   = hex("#cdbd9c"),   // マス目の罫線
          wall   = hex("#6b5b45"),   // 枠とラベルのインク
          ghost  = hex("#b5a486"),   // 着地予測（下書きの薄い線）
          flash  = hex("#fffdf5"),   // 消えるときの閃光（紙より白い）
          colorI = hex("#3f9aa8"),   // 青緑
          colorO = hex("#e0a52e"),   // 山吹
          colorT = hex("#8a5aa8"),   // すみれ
          colorS = hex("#5f9e4f"),   // 若草
          colorZ = hex("#c2494b"),   // 朱
          colorJ = hex("#3b5f9e"),   // 藍
          colorL = hex("#d4763a") })  // 柿

    /// ミノの種類 → 実色（固定セル・落下中ミノ・NEXT が使う）。
    pub def colorOf(doc: Doc, kind: Kind): Color =
        let r = rec(doc);
        match kind {
            case Kind.I => r#colorI
            case Kind.O => r#colorO
            case Kind.T => r#colorT
            case Kind.S => r#colorS
            case Kind.Z => r#colorZ
            case Kind.J => r#colorJ
            case Kind.L => r#colorL
        }

    /// テキストから Doc へ（fail-open）。色の表記（#rrggbb）は UiDoc.colorOf に委ねる。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          bg     = colorOr(d#bg, "bg", root),
          board  = colorOr(d#board, "board", root),
          grid   = colorOr(d#grid, "grid", root),
          wall   = colorOr(d#wall, "wall", root),
          ghost  = colorOr(d#ghost, "ghost", root),
          flash  = colorOr(d#flash, "flash", root),
          colorI = colorOr(d#colorI, "colorI", root),
          colorO = colorOr(d#colorO, "colorO", root),
          colorT = colorOr(d#colorT, "colorT", root),
          colorS = colorOr(d#colorS, "colorS", root),
          colorZ = colorOr(d#colorZ, "colorZ", root),
          colorJ = colorOr(d#colorJ, "colorJ", root),
          colorL = colorOr(d#colorL, "colorL", root) })

    def colorOr(fallbackColor: Color, key: String, obj: Map[String, Json]): Color =
        Map.get(key, obj)
            |> Option.flatMap(json -> UiDoc.colorOf(Map.empty(), key, json) |> Result.toOption)
            |> Option.getWithDefault(fallbackColor)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
