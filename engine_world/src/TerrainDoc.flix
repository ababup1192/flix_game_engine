// TerrainDoc — セル文字→質感の表の宣言(*.terrain.json)を読む codec 層。
// 色は「#rrggbb リテラル」か「@キー(テーマ色参照)」の文字列で持ち、実色への解決は
// 呼び側 resolver(specOf の第1引数)に委ねる — テーマを差し替えると地形の色も追随する
// (PxSprite / ThemeDoc.resolver と同じ流儀)。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
// decode の契約: entries の char 重複は先勝ち・surface の未知 preset 名は除去・
// edge は uniform 先勝ち(いずれも壊れ扱いにせず静かに受け入れる)。

pub mod TerrainDoc {
    use Util.Json.Json

    /// 縁の色の決め方(Material.EdgeKind の色を文字列参照にした Doc 形)。
    /// Uniform = 全周同じ色。ByNormal = 外向き法線で選ぶ(上=top、横=side、下=shade)。
    pub enum EdgeRef {
        case Uniform(String)
        case ByNormal({ top = String, side = String, shade = String })
    }

    /// 表の1行の宣言。char = rows の文字、name = パレットに出る名前(Studio の1ボタン)、
    /// fill = 塗り("#rrggbb" | "@wall")、edge / edgeWidth = 輪郭フチ、
    /// style = 角の形("round"|"square"|"diamond"|"mix")、jitter = 対角辺の岩肌の揺らぎ、
    /// surface = 表面の粒(preset 名+1色。preset は "grain"|"sparkle"|"scales"|"bubble"|"glow")、
    /// mottle = セル別の明度ゆらぎの最大量(0 = なし)、
    /// height = 持ち上げ(None = 平ら)。
    pub type alias EntryDoc = {
        char = Char, name = String,
        fill = String,
        edge = EdgeRef,
        edgeWidth = Float64,
        style = String,
        jitter = Float64,
        surface = List[{ preset = String, color = String }],
        mottle = Float64,
        height = Option[{ lift = Float64, front = String, shade = String, clipToFloor = Bool }]
    }

    /// 表全体。styleMix = 角の形(丸/四角)の混ぜ具合、entries = セル文字→質感の表
    /// (char は一意が契約 — 重複は fromJson が先勝ちでまとめる)。
    pub type alias Doc = { version = Int32, styleMix = DualGrid.StyleMix,
                           entries = List[EntryDoc] }

    /// コード側の既定値。石垣('#')と畑(',')の2行 — Doc が読めなくても地形は描ける。
    /// 初期値は dungeon の実績値(styleMix 0.4/0.4・jitter 0)から出発。色は @キーで持ち、
    /// 実色は呼び側テーマの resolver が決める。
    pub def defaults(): Doc =
        { version = 1,
          styleMix = { round = 0.4, square = 0.4 },
          entries =
              { char = '#', name = "石垣",
                fill = "@wall",
                edge = EdgeRef.ByNormal({ top = "@wallTop", side = "@wallSide",
                                          shade = "@wallShade" }),
                edgeWidth = 2.5, style = "mix", jitter = 0.0,
                surface = Nil, mottle = 0.0,
                height = Some({ lift = 6.0, front = "@wallFront", shade = "@wallShade",
                                clipToFloor = true }) }
           :: { char = ',', name = "畑",
                fill = "@field",
                edge = EdgeRef.Uniform("@fieldShade"),
                edgeWidth = 1.5, style = "round", jitter = 0.0,
                surface = Nil, mottle = 0.0, height = None }
           :: Nil }

    /// テキストから Doc へ(fail-open)。entries の char 重複は先勝ちでまとめ(Studio 契約)、
    /// surface の未知 preset 名は decode 時に捨てる(specOf 側 presetOf の None は防衛の二重化)。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.parse(String.trim(text))
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(fromRoot)

    /// path の Doc を読む。読めない・壊れているときは defaults(fail-open)。
    /// 読み込みを DocJson.loadOr に委譲し、既定値へ落とした事実は標準エラーへ 1 行出る。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(decodeWithWarnings, defaults(), p)

    /// 読み込みで使う decode。捨てた宣言を標準エラーへ 1 行ずつ知らせる。
    /// 純粋な fromJson を静かなままにするのは、値だけ欲しい呼び側（Studio プレビュー・
    /// テスト）が同じ Doc を何度読んでも 1 行も出さないようにするため。
    def decodeWithWarnings(text: String): Option[Doc] =
        fromJson(text) |> Option.map(doc -> warnDroppedPresets(text, warnEntries(doc)))

    /// 壊れた色表記・知らない style 名を 1 行ずつ知らせてから doc を返す。
    def warnEntries(doc: Doc): Doc =
        let _ = doc#entries |> List.forEach(e -> {
            let _ = colorRefsOf(e) |> List.filter(s -> not isKnownColorRef(s)) |> List.distinct
                |> List.forEach(s -> Log.fellBack("terrain", "'${e#char}' の色 '${s}'", "resolver の未知キー既定", "#rrggbb でも @キー でもありません"));
            if (isKnownStyle(e#style))
                ()
            else
                Log.fellBack("terrain", "'${e#char}' の style '${e#style}'", "styleMix の混ぜ", "知らない名前です")
        });
        doc

    /// 捨てた preset 名を 1 行ずつ知らせてから doc を返す。名前を元のテキストから
    /// 拾い直すのは、decode が未知の preset を落とした後の Doc には名前が残らないため。
    def warnDroppedPresets(text: String, doc: Doc): Doc =
        let _ = presetNamesIn(text) |> List.filter(name -> not isKnownPreset(name))
            |> List.forEach(name ->
                Log.warn("terrain fail-open: preset '${name}' を捨てました — 知らない名前なので表面の演出は出ません"));
        doc

    /// 生の JSON に書かれている surface の preset 名を全部拾う。
    def presetNamesIn(text: String): List[String] =
        DocJson.parse(String.trim(text))
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(root -> Map.get("entries", root))
            |> Option.flatMap(JsonCodec.decodeList(json -> Some(presetNamesOfEntry(json))))
            |> Option.getWithDefault(Nil)
            |> List.flatten

    /// entry 1 件に書かれている surface の preset 名。
    def presetNamesOfEntry(json: Json): List[String] =
        JsonCodec.expectObject(json)
            |> Option.flatMap(obj -> Map.get("surface", obj))
            |> Option.flatMap(JsonCodec.decodeList(fxOf))
            |> Option.getWithDefault(Nil)
            |> List.map(fx -> fx#preset)

    /// EntryDoc(文字列の色)→ Material.Spec(実色)。resolve は呼び側供給
    /// (rpg-starter なら key -> ThemeDoc.resolver(theme, key))。壊れた表記・存在しない
    /// @キーは resolve の未知キー既定(ThemeDoc.resolver ならマゼンタ = 描き忘れが目に
    /// 見える)へ落ち、例外は投げない — fail-open。
    pub def specOf(resolve: String -> Color, e: EntryDoc): Material.Spec =
        { fill = colorOf(resolve, e#fill),
          edge = edgeKindOf(resolve, e#edge),
          edgeWidth = e#edgeWidth,
          forceStyle = forceStyleOf(e#style),
          jitter = e#jitter,
          surface = e#surface |> List.filterMap(fx -> presetOf(resolve, fx)),
          blotch = None,
          mottle = e#mottle,
          height = heightOf(resolve, e#height) }

    /// Studio パレット供給口: entries の {char, name} だけを並べる(1エントリ=1ボタン)。
    pub def palette(doc: Doc): List[{ char = Char, name = String }] =
        doc#entries |> List.map(e -> { char = e#char, name = e#name })

    // ════════════════════════════════════════════════════════
    // decode(JSON → Doc。欠け・壊れはフィールド単位で既定へ)
    // ════════════════════════════════════════════════════════

    /// トップレベルの読み。欠けたフィールドは defaults の値のまま。
    def fromRoot(root: Map[String, Json]): Doc =
        let d = defaults();
        { version = JsonCodec.intOr("version", d#version, root),
          styleMix = styleMixOr(d#styleMix, root),
          entries = Map.get("entries", root)
              |> Option.flatMap(JsonCodec.decodeList(json -> Some(entryOf(json))))
              |> Option.map(entries -> entries |> List.filterMap(x -> x) |> dedupeByChar)
              |> Option.getWithDefault(d#entries) }

    /// styleMix(record)の読み。欠け・オブジェクトでないときは既定へ。
    def styleMixOr(fallback: DualGrid.StyleMix, root: Map[String, Json]): DualGrid.StyleMix =
        Map.get("styleMix", root)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(obj -> { round = JsonCodec.floatOr("round", fallback#round, obj),
                                   square = JsonCodec.floatOr("square", fallback#square, obj) })
            |> Option.getWithDefault(fallback)

    /// 1エントリの読み。オブジェクトでない・char が読めない(空文字)ものだけ None =
    /// そのエントリを静かに捨てる(fail-open — 1行の壊れが表全体を壊さない)。
    /// 塗りの書き忘れはマゼンタ = 描き忘れが目に見える(resolver の未知キー既定と同じ流儀)。
    def entryOf(json: Json): Option[EntryDoc] =
        JsonCodec.expectObject(json) |> Option.flatMap(obj -> {
            let fill = JsonCodec.stringOr("fill", "#ff00ff", obj);
            JsonCodec.stringOr("char", "", obj) |> String.toList |> List.head
                |> Option.map(ch ->
                    { char = ch,
                      name = JsonCodec.stringOr("name", "", obj),
                      fill = fill,
                      edge = edgeOf(fill, obj),
                      edgeWidth = JsonCodec.floatOr("edgeWidth", 1.5, obj),
                      style = JsonCodec.stringOr("style", "mix", obj),
                      jitter = JsonCodec.floatOr("jitter", 0.0, obj),
                      surface = surfaceOf(obj),
                      mottle = JsonCodec.floatOr("mottle", 0.0, obj),
                      height = heightDocOf(fill, obj) })
        })

    /// entry が持つ色文字列を全部並べる（fill・edge・surface・height）。
    def colorRefsOf(e: EntryDoc): List[String] =
        (e#fill :: edgeRefsOf(e#edge))
            ::: (e#surface |> List.map(fx -> fx#color))
            ::: (e#height |> Option.map(h -> h#front :: h#shade :: Nil)
                          |> Option.getWithDefault(Nil))

    /// EdgeRef が持つ色文字列。
    def edgeRefsOf(edge: EdgeRef): List[String] =
        match edge {
            case EdgeRef.Uniform(s)  => s :: Nil
            case EdgeRef.ByNormal(b) => b#top :: b#side :: b#shade :: Nil
        }

    /// colorOf が実色にできる表記かどうか（"@キー" か、UiDoc.colorOf が読める "#rrggbb"）。
    def isKnownColorRef(s: String): Bool =
        String.startsWith(prefix = "@", s)
            or (Util.Json.Json.JString(s)
                    |> (json -> UiDoc.colorOf(Map.empty(), "terrain", json))
                    |> Result.isOk)

    /// forceStyleOf が受け取れる名前（"mix" は「混ぜる」を選ぶ正常系なので含む）。
    def isKnownStyle(name: String): Bool =
        name == "round" or name == "square" or name == "diamond" or name == "mix"

    /// 縁の読み。優先順(この順で判定): (1) "uniform" キーがあれば Uniform — top 等が
    /// 混在していても uniform 先勝ちで ByNormal 側は読まない。(2) "uniform" が無く
    /// top / side / shade のいずれかがあれば ByNormal(欠けたキーは既定色=塗り色で埋める)。
    /// (3) どちらとも読めない(edge 欠落・オブジェクトでない等)は既定の縁 =
    /// 塗りと同色の Uniform(実質フチ無しに近い)へ落とす — fail-open。
    def edgeOf(fill: String, obj: Map[String, Json]): EdgeRef =
        match Map.get("edge", obj) |> Option.flatMap(JsonCodec.expectObject) {
            case None => EdgeRef.Uniform(fill)
            case Some(edgeObj) =>
                match Map.get("uniform", edgeObj) |> Option.flatMap(JsonCodec.expectString) {
                    case Some(u) => EdgeRef.Uniform(u)
                    case None =>
                        if (Map.memberOf("top", edgeObj) or Map.memberOf("side", edgeObj)
                                or Map.memberOf("shade", edgeObj))
                            EdgeRef.ByNormal({ top = JsonCodec.stringOr("top", fill, edgeObj),
                                               side = JsonCodec.stringOr("side", fill, edgeObj),
                                               shade = JsonCodec.stringOr("shade", fill, edgeObj) })
                        else EdgeRef.Uniform(fill)
                }
        }

    /// 表面の粒の読み。未知の preset 名はここで捨てる(fail-open で演出なし)。
    def surfaceOf(obj: Map[String, Json]): List[{ preset = String, color = String }] =
        Map.get("surface", obj)
            |> Option.flatMap(JsonCodec.decodeList(fxOf))
            |> Option.getWithDefault(Nil)
            |> List.filter(fx -> isKnownPreset(fx#preset))

    /// 粒1件の読み(preset 名+1色)。
    def fxOf(json: Json): Option[{ preset = String, color = String }] =
        JsonCodec.expectObject(json) |> Option.map(fxObj ->
            { preset = JsonCodec.stringOr("preset", "", fxObj),
              color = JsonCodec.stringOr("color", "#ff00ff", fxObj) })

    /// presetOf が受け取れる名前だけを通す(decode 時の除去と specOf 側の None の二重防衛)。
    /// presetOf の case と 1 対 1 で対応させる — 片方だけ増やすと、その preset は
    /// ここで捨てられて presetOf まで届かず、絵が出ないまま警告 1 行で終わる。
    def isKnownPreset(name: String): Bool =
        name == "grain" or name == "sparkle" or name == "scales"
            or name == "bubble" or name == "glow"

    /// 持ち上げの読み。height が無い・オブジェクトでないときは None = 平ら。
    def heightDocOf(fill: String, obj: Map[String, Json]):
            Option[{ lift = Float64, front = String, shade = String, clipToFloor = Bool }] =
        Map.get("height", obj)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(h -> { lift = JsonCodec.floatOr("lift", 6.0, h),
                                 front = JsonCodec.stringOr("front", fill, h),
                                 shade = JsonCodec.stringOr("shade", fill, h),
                                 clipToFloor = JsonCodec.boolOr("clipToFloor", true, h) })

    /// char の二重宣言を先勝ちでまとめる(壊れ扱いにしない = fail-open。Studio 契約: 先の宣言が有効)。
    def dedupeByChar(entries: List[EntryDoc]): List[EntryDoc] =
        entries |> List.foldLeft((acc, e) ->
            if (List.exists(seen -> seen#char == e#char, acc)) acc else e :: acc, Nil)
            |> List.reverse

    // ════════════════════════════════════════════════════════
    // 解決(文字列の色・名前 → Material の実値。specOf の内部)
    // ════════════════════════════════════════════════════════

    /// 色文字列 → 実色。"#rrggbb" はリテラル(UiDoc.colorOf 委譲)、"@key" は resolve(key)。
    /// 壊れた表記・壊れた @キーは resolve の未知キー既定(ThemeDoc.resolver ならマゼンタ =
    /// 描き忘れが目に見える)へ落とす — fail-open。
    def colorOf(resolve: String -> Color, s: String): Color =
        if (String.startsWith(prefix = "@", s))
            resolve(String.drop(1, s))
        else
            Util.Json.Json.JString(s)
                |> (json -> UiDoc.colorOf(Map.empty(), "terrain", json))
                |> Result.toOption
                |> Option.getWithDefault(resolve(s))    // "#" でも "@" でもない → 未知キー扱い

    /// EdgeRef(文字列の色)→ Material.EdgeKind(実色)。
    def edgeKindOf(resolve: String -> Color, edge: EdgeRef): Material.EdgeKind =
        match edge {
            case EdgeRef.Uniform(s)  => Material.EdgeKind.Uniform(colorOf(resolve, s))
            case EdgeRef.ByNormal(b) =>
                Material.EdgeKind.ByNormal({ top = colorOf(resolve, b#top),
                                             side = colorOf(resolve, b#side),
                                             shade = colorOf(resolve, b#shade) })
        }

    /// 角の形の固定。"mix"(と未知の名前)は None = 場所ごとに styleMix で混ぜる。
    def forceStyleOf(style: String): Option[DualGrid.CornerStyle] =
        match style {
            case "round"   => Some(DualGrid.CornerStyle.Round)
            case "square"  => Some(DualGrid.CornerStyle.Square)
            case "diamond" => Some(DualGrid.CornerStyle.Diamond)
            case _         => None
        }

    /// preset 名+1色 → Material の表面の粒。未知の preset 名は None(fail-open で演出なし)。
    /// scales だけ3色ランプが要るので1色から導く。count / period 等の細部ノブは
    /// Material のプリセット関数内の定数(ロジックを JSON に書かない原則)。
    def presetOf(resolve: String -> Color,
                 fx: { preset = String, color = String }): Option[Material.SurfaceFx] =
        let c = colorOf(resolve, fx#color);
        match fx#preset {
            case "sparkle" => Some(Material.sparkle(c))
            case "grain"   => Some(Material.grain(c))
            case "scales"  => Some(Material.scales(
                                  { deep = Color.darken(c, 0.25),
                                    mid = c,
                                    lite = Color.lighten(c, 0.25) }, 1.0))
            case "bubble"  => Some(Material.bubble(c))
            case "glow"    => Some(Material.glow(c))
            case _         => None
        }

    /// 持ち上げの解決。Some = Lifted(輪郭を lift ぶん持ち上げ、立ち面と落ち影を張る)、
    /// None = Flat(平ら)。
    def heightOf(resolve: String -> Color,
                 height: Option[{ lift = Float64, front = String, shade = String,
                                  clipToFloor = Bool }]): Material.HeightProfile =
        match height {
            case None    => Material.HeightProfile.Flat
            case Some(h) => Material.HeightProfile.Lifted({ height = h#lift,
                                                            front = colorOf(resolve, h#front),
                                                            shade = colorOf(resolve, h#shade),
                                                            clipToFloor = h#clipToFloor })
        }
}
