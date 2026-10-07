// UiDoc — ui.json の宣言ドキュメントを Spec（pure data）へ読み取り、Flex（→ UiLayout）で
// レイアウトして Render.PlacedItem の列に落とす。**ui.json 方言の唯一のパーサ** —
// UiSpec.parse はこの parse の結果を UiStore コンポーネントへ射影する薄い層で、
// 方言の定義はこのモジュールに一本化されている。
//
// 事故りやすい点:
//   - 図形 widget（circle/ngon/star/ellipse/sector/segment/line/polyline/bezier）と
//     poly の rotation/pivot は Flex 経路限定 — UiStore 経路（UiSpec）は loud に断る。
//   - エラーはノードの名前パス付き（例: `at gallery/row1/box: 'color' is required`）。
//   - build（Flex 経路）は bind/meta/layer を使わない（動的束縛・レイヤ重ねは UiSpec/UiStore
//     の領分）が、Spec には保持する — 同じ JSON が経路を変えても意味を失わないための契約。

pub mod UiDoc {
    import java.math.BigDecimal
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JString, JNumber, JBool}
    use Util.Json.JsonError
    use DocJson.PathTag.Root

    // ========================================================================
    // 型（テンプレ解決済み・pure data）
    // ========================================================================

    /// `note`: エディタで表示するノートコメント（描画には影響しない）。
    /// `origin`: このノードが instance 合成の根なら参照パス、それ以外は None（子孫には付けない）。
    pub enum Spec {
        case Spec({ name = String, widget = Widget, style = UiLayout.Style,
                    visible = Bool, binding = Option[String], meta = Option[String],
                    hover = Option[UiWidget.HoverStyle],
                    note = Option[String], origin = Option[String],
                    layer = Int32, children = List[Spec] })
    }

    pub enum Widget {
        case NoneW
        case BoxW(BoxSpec)
        case TextW(TextSpec)
        case SpriteW(UiWidget.SpriteComp)
        case PolyW(PolySpec)
        case ShapeW(ShapeSpec)
    }

    /// poly widget（UiWidget.PolyComp の宣言形 + rotation/pivot 拡張）。
    pub type alias PolySpec = {
        points = List[Vec2.Vec2], color = Color, alpha = Float64, zIndex = Int32,
        rotation = Float64, pivot = Option[Vec2.Vec2]
    }

    /// box widget（UiWidget.BoxComp + 傾き）。rotation は回転数（1 周 = 1.0）。
    /// pivot は rect 左上からの相対点で、未指定なら rect の中心を軸にする。
    pub type alias BoxSpec = {
        box = UiWidget.BoxComp, rotation = Float64, pivot = Option[Vec2.Vec2]
    }

    /// text widget（UiWidget.TextComp + 傾き）。軸の決め方は BoxSpec と同じ。
    pub type alias TextSpec = {
        text = UiWidget.TextComp, rotation = Float64, pivot = Option[Vec2.Vec2]
    }

    /// 図形 widget（UiShape.ShapeComp + 傾き）。軸の決め方は BoxSpec と同じ。
    pub type alias ShapeSpec = {
        shape = UiShape.ShapeComp, rotation = Float64, pivot = Option[Vec2.Vec2]
    }

    pub def nameOf(spec: Spec): String =
        let Spec.Spec(node) = spec;
        node#name

    // ========================================================================
    // parse（純粋）
    // ========================================================================

    /// パース全体で引き回す環境。
    type alias ParseEnv = {
        templates = Map[String, Map[String, Json]],  // いま効いているテンプレート（use の参照先）
        defaultFont = String,                        // font 未指定の text が使うフォント名
        palette = Map[String, Color],                // "@name" 色参照の解決表（ドキュメントごと）
        resolver = Map[String, Json],                // instance のパス → 読み込み済み JSON
        stack = List[String]                         // 解決中の instance パスの連なり（循環検出用）
    }

    /// ドキュメント（version + templates + root）を Spec へ読み取る。instance を含むときは load を使う。
    pub def parse(json: Json): Result[JsonError, Spec] =
        parseWith(Map.empty(), json)

    /// parse と同じ。加えて resolver（パス → JSON）で instance 参照を解決できる。
    pub def parseWith(resolver: Map[String, Json], json: Json): Result[JsonError, Spec] =
        parseTop(resolver, Nil, json)

    def parseTop(resolver: Map[String, Json], stack: List[String], json: Json): Result[JsonError, Spec] =
        match json {
            case JObject(topMap) => forM (
                top  <- parseTopLevel(topMap);
                spec <- parseNode({ templates = top#templates, defaultFont = top#defaultFont,
                                    palette = top#palette,
                                    resolver = resolver, stack = stack }, "", 0, top#rootMap)
            ) yield spec
            case _ => Err(DocJson.jsonError(Root, Set#{"UiDoc must be a JSON object with a 'root'"}))
        }

    /// トップレベル（version / templates / defaultFont / palette / root）をまとめて取り出す。
    /// ドキュメントの入口（parseTop）と instance の参照先（resolveInstance）が同じ形を読むための共通部。
    def parseTopLevel(topMap: Map[String, Json]):
            Result[JsonError, { templates = Map[String, Map[String, Json]], defaultFont = String,
                                palette = Map[String, Color], rootMap = Map[String, Json] }] =
        forM (
            _v          <- DocJson.checkVersion("ui document", topMap);
            templates   <- parseTemplates(topMap);
            defaultFont <- parseDefaultFont(topMap);
            palette     <- parsePalette(topMap);
            rootMap     <- (DocJson.getAtKey(Root, "root", topMap): Result[JsonError, Map[String, Json]])
        ) yield { templates = templates, defaultFont = defaultFont, palette = palette, rootMap = rootMap }

    /// "palette": { "名前": <色> }。ノードの色値から "@名前" で参照する。
    /// パレットの値自体に "@..." は書けない（自己参照を作らない）。
    def parsePalette(topMap: Map[String, Json]): Result[JsonError, Map[String, Color]] =
        match (DocJson.getAtKeyOpt(Root, "palette", topMap): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)      => Err(e)
            case Ok(None)    => Ok(Map.empty())
            case Ok(Some(m)) =>
                m |> Map.toList |> Result.traverse(entry -> {
                    let (name, json) = entry;
                    colorOf(Map.empty(), "palette '${name}'", json) |> Result.map(c -> (name, c))
                }) |> Result.map(List.toMap)
        }

    def parseDefaultFont(topMap: Map[String, Json]): Result[JsonError, String] =
        (DocJson.getAtKeyOpt(Root, "defaultFont", topMap): Result[JsonError, Option[String]])
            |> Result.map(Option.getWithDefault("ui"))

    def parseTemplates(topMap: Map[String, Json]): Result[JsonError, Map[String, Map[String, Json]]] =
        match (DocJson.getAtKeyOpt(Root, "templates", topMap): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)      => Err(e)
            case Ok(None)    => Ok(Map.empty())
            case Ok(Some(m)) =>
                Map.foldLeftWithKey((acc, tname, json) -> forM (
                    sofar <- acc;
                    tmap  <- DocJson.asObject("template '${tname}'", json)
                ) yield Map.insert(tname, tmap, sofar), Ok(Map.empty()), m)
        }

    /// 1 ノードを Spec へ（"instance" があれば参照先ドキュメントを合成してから）。
    /// ordinal は兄弟内の位置で、name 確定前のエラーを `parent[ordinal]` で指すのに使う。
    def parseNode(env: ParseEnv, parentPath: String, ordinal: Int32,
                  nodeMap: Map[String, Json]): Result[JsonError, Spec] =
        match (DocJson.getAtKeyOpt(Root, "instance", nodeMap): Result[JsonError, Option[String]]) {
            case Err(e)             => Err(e)
            case Ok(Some(instPath)) =>
                DocJson.atNode(siteTag(parentPath, ordinal),
                    resolveInstance(env, parentPath, ordinal, instPath, nodeMap))
            case Ok(None)           => parsePlainNode(env, parentPath, ordinal, nodeMap)
        }

    /// use のテンプレ値の上にノード値を重ね（ノード勝ち）、属性と子をまとめる。
    /// エラーはこのノードの名前パスでタグする（子は子が自分でタグ済み）。
    def parsePlainNode(env: ParseEnv, parentPath: String, ordinal: Int32,
                       nodeMap: Map[String, Json]): Result[JsonError, Spec] =
        match nodeIdentity(env, parentPath, ordinal, nodeMap) {
            case Err(e) => Err(e)
            case Ok((name, merged)) =>
                let path = if (parentPath == "") name else "${parentPath}/${name}";
                forM (
                    own      <- DocJson.atNode(path, parseOwnFields(env, merged));
                    children <- parseChildren(env, path, merged);
                    _uniq    <- DocJson.atNode(path, ensureUniqueNames(children))
                ) yield Spec.Spec({
                    name = name, widget = own#widget, style = own#style,
                    visible = own#visible, binding = own#binding, meta = own#meta,
                    hover = own#hover, note = own#note, origin = None,
                    layer = own#layer, children = children
                })
        }

    /// エラータグ用のノード位置（name 確定前は「親パス[兄弟内位置]」、root は "(root)"）。
    def siteTag(parentPath: String, ordinal: Int32): String =
        if (parentPath == "") "(root)" else "${parentPath}[${ordinal}]"

    /// use 解決と name の取り出し。name 確定前の失敗は siteTag でタグする。
    def nodeIdentity(env: ParseEnv, parentPath: String, ordinal: Int32,
                     nodeMap: Map[String, Json]): Result[JsonError, (String, Map[String, Json])] =
        DocJson.atNode(siteTag(parentPath, ordinal), forM (
            merged <- resolveTemplate(env#templates, nodeMap);
            name   <- (DocJson.getAtKey(Root, "name", merged): Result[JsonError, String]);
            _valid <- validateName(name)
        ) yield (name, merged))

    // ── instance（別ドキュメントの合成）──

    /// instance ノードの解決: 参照先の root にノード自身のフィールドを重ね、override の
    /// パッチを当ててから通常のパースへ流す。テンプレと defaultFont は参照先のものが効く。
    def resolveInstance(env: ParseEnv, parentPath: String, ordinal: Int32,
                        instPath: String, nodeMap: Map[String, Json]): Result[JsonError, Spec] =
        forM (
            _noCycle  <- if (List.memberOf(instPath, env#stack))
                             Err(DocJson.jsonError(Root, Set#{
                                 "instance cycle: ${String.intercalate(" -> ", List.reverse(instPath :: env#stack))}"}))
                         else Ok(());
            docJson   <- Map.get(instPath, env#resolver) |> Option.toOk(unloadedErr(instPath));
            topMap    <- DocJson.asObject("instance '${instPath}'", docJson);
            top       <- parseTopLevel(topMap);
            own       <- instanceOwnFields(nodeMap);
            overrides <- parseOverrides(nodeMap);
            patched   <- applyOverrides(overrides, mergeNode(top#rootMap, own));
            spec      <- parseNode({ templates = top#templates, defaultFont = top#defaultFont,
                                     palette = top#palette,
                                     resolver = env#resolver, stack = instPath :: env#stack },
                                   parentPath, ordinal, patched)
        ) yield withOrigin(instPath, spec)

    /// instance の根だけに参照パスを刻む。子孫まで刻むとエディタが「どこから編集すべきか」を
    /// 見誤る（差し替え単位は根のファイル参照 1 点）ので、根に限る。
    def withOrigin(instPath: String, spec: Spec): Spec =
        let Spec.Spec(node) = spec;
        Spec.Spec({ origin = Some(instPath) | node })

    /// instance ノード自身のフィールド（参照先 root にノード勝ちで重ねる分）。
    /// children の丸ごと差し替えと use の併用は意味が曖昧なので断る。
    def instanceOwnFields(nodeMap: Map[String, Json]): Result[JsonError, Map[String, Json]] =
        if (Map.memberOf("children", nodeMap))
            Err(DocJson.jsonError(Root, Set#{"an instance node cannot have 'children' — use \"override\" to patch descendants"}))
        else if (Map.memberOf("use", nodeMap))
            Err(DocJson.jsonError(Root, Set#{"'use' and 'instance' cannot be combined"}))
        else Ok(nodeMap |> Map.remove("instance") |> Map.remove("override"))

    /// "override": { "相対名パス": { 部分フィールド } } を読む。patch には葉のフィールドだけ許す。
    def parseOverrides(nodeMap: Map[String, Json]): Result[JsonError, List[(String, Map[String, Json])]] =
        match (DocJson.getAtKeyOpt(Root, "override", nodeMap): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)      => Err(e)
            case Ok(None)    => Ok(Nil)
            case Ok(Some(m)) => m |> Map.toList |> Result.traverse(entry -> {
                let (relPath, json) = entry;
                forM (
                    patch <- DocJson.asObject("override '${relPath}'", json);
                    _ok   <- validatePatch(relPath, patch)
                ) yield (relPath, patch)
            })
        }

    def validatePatch(relPath: String, patch: Map[String, Json]): Result[JsonError, Unit] =
        let keys = "children" :: "instance" :: "override" :: Nil;
        let banned = List.filter(k -> Map.memberOf(k, patch), keys);
        if (List.isEmpty(banned)) Ok(())
        else Err(DocJson.jsonError(Root, Set#{
            "override '${relPath}' cannot contain ${String.intercalate(", ", banned)} — patch leaf fields only"}))

    def applyOverrides(overrides: List[(String, Map[String, Json])],
                       rootMap: Map[String, Json]): Result[JsonError, Map[String, Json]] =
        List.foldLeft((acc, entry) -> acc |> Result.flatMap(m -> {
            let (relPath, patch) = entry;
            patchAt(String.splitOn(substr = "/", relPath), patch, relPath, m)
        }), Ok(rootMap), overrides)

    /// 相対名パスの先のノードに patch を重ねる。各段は children の name で辿る
    /// （name をテンプレ任せにした子は辿れない — ノード側に name を書くこと）。
    def patchAt(segments: List[String], patch: Map[String, Json], fullPath: String,
                nodeMap: Map[String, Json]): Result[JsonError, Map[String, Json]] =
        match segments {
            case Nil => Ok(mergeNode(nodeMap, patch))
            case seg :: rest => match Map.get("children", nodeMap) {
                case Some(JArray(arr)) => forM (
                    patchedChildren <- patchChild(seg, rest, patch, fullPath, Vector.toList(arr))
                ) yield Map.insert("children", JArray(List.toVector(patchedChildren)), nodeMap)
                case _ => Err(DocJson.jsonError(Root, Set#{"override path '${fullPath}' not found: node has no children"}))
            }
        }

    def patchChild(seg: String, rest: List[String], patch: Map[String, Json], fullPath: String,
                   children: List[Json]): Result[JsonError, List[Json]] =
        match children {
            case Nil => Err(DocJson.jsonError(Root, Set#{"override path '${fullPath}' not found: no child named '${seg}'"}))
            case child :: tail => match namedObject(seg, child) {
                case Some(m) =>
                    let patchedM = if (List.isEmpty(rest)) Ok(mergeNode(m, patch))
                                   else patchAt(rest, patch, fullPath, m);
                    patchedM |> Result.map(m2 -> JObject(m2) :: tail)
                case None =>
                    patchChild(seg, rest, patch, fullPath, tail) |> Result.map(r -> child :: r)
            }
        }

    /// child が「name = seg の JSON Object」ならその map。
    def namedObject(seg: String, child: Json): Option[Map[String, Json]] =
        match child {
            case JObject(m) => if (nameIs(seg, m)) Some(m) else None
            case _          => None
        }

    def nameIs(seg: String, m: Map[String, Json]): Bool =
        match Map.get("name", m) {
            case Some(JString(n)) => n == seg
            case _                => false
        }

    def unloadedErr(path: String): JsonError =
        DocJson.jsonError(Root, Set#{"instance '${path}' is not loaded (use UiDoc.load)"})

    /// ノード自身の属性（widget・style・visible・bind/meta/hover/note/layer）。
    def parseOwnFields(env: ParseEnv, merged: Map[String, Json]):
            Result[JsonError, { widget = Widget, style = UiLayout.Style, visible = Bool,
                                binding = Option[String], meta = Option[String],
                                note = Option[String],
                                hover = Option[UiWidget.HoverStyle], layer = Int32 }] =
        forM (
            widgetOpt  <- (DocJson.getAtKeyOpt(Root, "widget", merged): Result[JsonError, Option[String]]);
            widget     <- parseWidget(widgetOpt, env, merged);
            style      <- parseStyle(merged);
            visibleOpt <- (DocJson.getAtKeyOpt(Root, "visible", merged): Result[JsonError, Option[Bool]]);
            bindingOpt <- (DocJson.getAtKeyOpt(Root, "bind", merged): Result[JsonError, Option[String]]);
            metaOpt    <- (DocJson.getAtKeyOpt(Root, "meta", merged): Result[JsonError, Option[String]]);
            noteOpt    <- (DocJson.getAtKeyOpt(Root, "note", merged): Result[JsonError, Option[String]]);
            hover      <- parseHoverOpt(env#palette, merged);
            layerOpt   <- (DocJson.getAtKeyOpt(Root, "layer", merged): Result[JsonError, Option[Int32]])
        ) yield {
            widget = widget, style = applyIntrinsic(widget, style),
            visible = Option.getWithDefault(true, visibleOpt),
            binding = bindingOpt, meta = metaOpt, hover = hover,
            note = noteOpt,
            layer = Option.getWithDefault(0, layerOpt)
        }

    /// "hover": { color / borderColor / tint / alpha } — hover 時の部分上書き。
    /// 効くのは UiStore 経路（extract）のみで、Flex 経路は静的なので持たない。
    def parseHoverOpt(palette: Map[String, Color], map: Map[String, Json]): Result[JsonError, Option[UiWidget.HoverStyle]] =
        match (DocJson.getAtKeyOpt(Root, "hover", map): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)      => Err(e)
            case Ok(None)    => Ok(None)
            case Ok(Some(m)) => forM (
                color       <- parseColorOpt(palette, "color", m);
                borderColor <- parseColorOpt(palette, "borderColor", m);
                tint        <- parseColorOpt(palette, "tint", m);
                alphaOpt    <- (DocJson.getAtKeyOpt(Root, "alpha", m): Result[JsonError, Option[Float64]])
            ) yield Some({ color = color, borderColor = borderColor, tint = tint,
                           alpha = alphaOpt })
        }

    def resolveTemplate(templates: Map[String, Map[String, Json]],
                        nodeMap: Map[String, Json]): Result[JsonError, Map[String, Json]] =
        match (DocJson.getAtKeyOpt(Root, "use", nodeMap): Result[JsonError, Option[String]]) {
            case Err(e)          => Err(e)
            case Ok(None)        => Ok(nodeMap)
            case Ok(Some(tname)) => match Map.get(tname, templates) {
                case None       => Err(DocJson.jsonError(Root, Set#{"unknown template: ${tname}"}))
                case Some(tmap) => Ok(mergeNode(tmap, nodeMap))
            }
        }

    def mergeNode(base: Map[String, Json], over: Map[String, Json]): Map[String, Json] =
        Map.foldLeftWithKey((acc, key, value) -> Map.insert(key, value, acc), base, over)

    def parseChildren(env: ParseEnv, path: String, map: Map[String, Json]): Result[JsonError, List[Spec]] =
        match Map.get("children", map) {
            case None              => Ok(Nil)
            case Some(JArray(arr)) =>
                Result.traverse(entry -> {
                    let (i, child) = entry;
                    forM (
                        m    <- DocJson.atNode("${path}[${i}]", DocJson.asObject("child", child));
                        spec <- parseNode(env, path, i, m)
                    ) yield spec
                }, List.zipWithIndex(Vector.toList(arr)))
            case Some(_)           => Err(DocJson.jsonError(Root, Set#{"children must be an array"}))
        }

    def validateName(name: String): Result[JsonError, Unit] =
        if (name == "")
            Err(DocJson.jsonError(Root, Set#{"node name must not be empty"}))
        else if (String.contains(substr = "/", name))
            Err(DocJson.jsonError(Root, Set#{"node name must not contain '/' (got: ${name})"}))
        else Ok(())

    def ensureUniqueNames(children: List[Spec]): Result[JsonError, Unit] =
        let names = List.map(child -> nameOf(child), children);
        if (List.length(names) == Set.size(List.toSet(names))) Ok(())
        else Err(DocJson.jsonError(Root, Set#{"sibling names must be unique (got: ${names})"}))

    /// 図形 widget の width/height 未指定（Auto）を内在サイズの Px に置き換える。
    def applyIntrinsic(widget: Widget, style: UiLayout.Style): UiLayout.Style =
        match widget {
            case Widget.ShapeW(s) =>
                let size = UiShape.intrinsicSize(s#shape#shape);
                let w = match style#width {
                    case UiLayout.SizeSpec.Auto => UiLayout.SizeSpec.Px(size#x)
                    case other                  => other
                };
                let h = match style#height {
                    case UiLayout.SizeSpec.Auto => UiLayout.SizeSpec.Px(size#y)
                    case other                  => other
                };
                { width = w, height = h | style }
            case _ => style
        }

    // ========================================================================
    // widget 解析
    // ========================================================================

    def parseWidget(opt: Option[String], env: ParseEnv,
                    map: Map[String, Json]): Result[JsonError, Widget] =
        let palette = env#palette;
        match opt {
            case None             => Ok(Widget.NoneW)
            case Some("none")     => Ok(Widget.NoneW)
            case Some("box")      => parseBoxSpec(palette, map)                  |> Result.map(b -> Widget.BoxW(b))
            case Some("text")     => parseTextSpec(env#defaultFont, palette, map) |> Result.map(t -> Widget.TextW(t))
            case Some("sprite")   => parseSprite(palette, map)                   |> Result.map(sp -> Widget.SpriteW(sp))
            case Some("poly")     => parsePoly(palette, map)                     |> Result.map(p -> Widget.PolyW(p))
            case Some("circle")   => shapeWidget(palette, map, parseCircle(map))
            case Some("ngon")     => shapeWidget(palette, map, parseNgon(map))
            case Some("star")     => shapeWidget(palette, map, parseStar(map))
            case Some("ellipse")  => shapeWidget(palette, map, parseEllipse(map))
            case Some("sector")   => shapeWidget(palette, map, parseSweep(map, true))
            case Some("segment")  => shapeWidget(palette, map, parseSweep(map, false))
            case Some("line")     => shapeWidget(palette, map, parseLine(map))
            case Some("polyline") => shapeWidget(palette, map, parsePolyline(map))
            case Some("bezier")   => shapeWidget(palette, map, parseBezier(map))
            case Some(unknown)    => Err(DocJson.jsonError(Root, Set#{"unknown widget (got: ${unknown})"}))
        }

    /// box / text の傾き（回転数）と軸（rect 左上からの相対点・省略で rect 中心）。
    def parseTurn(map: Map[String, Json]): Result[JsonError, { rotation = Float64, pivot = Option[Vec2.Vec2] }] =
        forM (
            rotationOpt <- (DocJson.getAtKeyOpt(Root, "rotation", map): Result[JsonError, Option[Float64]]);
            pivot       <- parseVec2Opt("pivot", map)
        ) yield { rotation = Option.getWithDefault(0.0, rotationOpt), pivot = pivot }

    def parseBoxSpec(palette: Map[String, Color], map: Map[String, Json]): Result[JsonError, BoxSpec] =
        forM (
            box  <- parseBox(palette, map);
            turn <- parseTurn(map)
        ) yield ({ box = box, rotation = turn#rotation, pivot = turn#pivot }: BoxSpec)

    def parseTextSpec(defaultFont: String, palette: Map[String, Color],
                      map: Map[String, Json]): Result[JsonError, TextSpec] =
        forM (
            text <- parseText(defaultFont, palette, map);
            turn <- parseTurn(map)
        ) yield ({ text = text, rotation = turn#rotation, pivot = turn#pivot }: TextSpec)

    def parseBox(palette: Map[String, Color], map: Map[String, Json]): Result[JsonError, UiWidget.BoxComp] =
        forM (
            color           <- parseColor(palette, "color", map);
            alphaOpt        <- (DocJson.getAtKeyOpt(Root, "alpha", map): Result[JsonError, Option[Float64]]);
            zIndexOpt       <- (DocJson.getAtKeyOpt(Root, "zIndex", map): Result[JsonError, Option[Int32]]);
            cornerRadiusOpt <- (DocJson.getAtKeyOpt(Root, "cornerRadius", map): Result[JsonError, Option[Float64]]);
            borderWidthOpt  <- (DocJson.getAtKeyOpt(Root, "borderWidth", map): Result[JsonError, Option[Float64]]);
            borderColorOpt  <- parseColorOpt(palette, "borderColor", map);
            skinOpt         <- (DocJson.getAtKeyOpt(Root, "skin", map): Result[JsonError, Option[String]]);
            skinCornerOpt   <- (DocJson.getAtKeyOpt(Root, "skinCorner", map): Result[JsonError, Option[Float64]])
        ) yield ({
            color = color,
            alpha = Option.getWithDefault(1.0, alphaOpt),
            zIndex = Option.getWithDefault(0, zIndexOpt),
            cornerRadius = Option.getWithDefault(0.0, cornerRadiusOpt),
            borderWidth = Option.getWithDefault(0.0, borderWidthOpt),
            borderColor = Option.getWithDefault(white(), borderColorOpt),
            skin = skinOpt,
            skinCorner = skinCornerOpt
        }: UiWidget.BoxComp)

    def parseText(defaultFont: String, palette: Map[String, Color], map: Map[String, Json]): Result[JsonError, UiWidget.TextComp] =
        forM (
            textOpt     <- (DocJson.getAtKeyOpt(Root, "text", map): Result[JsonError, Option[String]]);
            fontOpt     <- (DocJson.getAtKeyOpt(Root, "font", map): Result[JsonError, Option[String]]);
            fontSizeOpt <- (DocJson.getAtKeyOpt(Root, "fontSize", map): Result[JsonError, Option[Float64]]);
            tintOpt     <- parseColorOpt(palette, "tint", map);
            zIndexOpt   <- (DocJson.getAtKeyOpt(Root, "zIndex", map): Result[JsonError, Option[Int32]]);
            wrap        <- parseTextWrap(map);
            fit         <- parseTextFit(map)
        ) yield ({
            text = Option.getWithDefault("", textOpt),
            font = Option.getWithDefault(defaultFont, fontOpt),
            fontSize = Option.getWithDefault(8.0, fontSizeOpt),
            tint = Option.getWithDefault(white(), tintOpt),
            zIndex = Option.getWithDefault(0, zIndexOpt),
            wrap = wrap,
            fit = fit
        }: UiWidget.TextComp)

    /// text の "wrap": "auto"（自分のレイアウト矩形の幅で折る）か、正の数値（折り返し幅 px）。
    /// 真偽値はコンテナの flex wrap（parseStyle の領分）なので、ここでは折らない扱いで素通しする
    /// — 同じキーを 2 つの意味で読むが、断ると既存の「text ノードをコンテナ兼用にした宣言」が壊れる。
    def parseTextWrap(map: Map[String, Json]): Result[JsonError, UiWidget.TextWrap] =
        match Map.get("wrap", map) {
            case None                  => Ok(UiWidget.TextWrap.WrapOff)
            case Some(JString("auto")) => Ok(UiWidget.TextWrap.WrapAuto)
            case Some(JString(other))  => Err(DocJson.jsonError(Root, Set#{
                "text wrap must be \"auto\" or a positive number (got: ${other})"}))
            case Some(JNumber(bd))     =>
                let w = bigDecToF64(bd);
                if (w > 0.0) Ok(UiWidget.TextWrap.WrapPx(w))
                else Err(DocJson.jsonError(Root, Set#{"text wrap width must be > 0 (got: ${w})"}))
            case Some(JBool(_))        => Ok(UiWidget.TextWrap.WrapOff)
            case Some(_)               => Err(DocJson.jsonError(Root, Set#{
                "text wrap must be \"auto\" or a positive number"}))
        }

    /// "fit": true で、折った後の縦がレイアウト矩形を超えたら fontSize を fitStep 刻みで
    /// fitMin まで縮める。刻みと下限の既定値はスキーマ（ui.schema.json）と対の
    /// UiWidget.fitStepDefault / fitMinDefault。
    def parseTextFit(map: Map[String, Json]): Result[JsonError, Option[UiWidget.TextFit]] =
        forM (
            fitOpt  <- (DocJson.getAtKeyOpt(Root, "fit", map): Result[JsonError, Option[Bool]]);
            stepOpt <- (DocJson.getAtKeyOpt(Root, "fitStep", map): Result[JsonError, Option[Float64]]);
            minOpt  <- (DocJson.getAtKeyOpt(Root, "fitMin", map): Result[JsonError, Option[Float64]])
        ) yield {
            if (Option.getWithDefault(false, fitOpt))
                Some(({ step = Option.getWithDefault(UiWidget.fitStepDefault(), stepOpt),
                        minSize = Option.getWithDefault(UiWidget.fitMinDefault(), minOpt) }: UiWidget.TextFit))
            else None
        }

    /// sprite（既存 ui.json と同義。tint は色 3 表記の上位互換）。
    def parseSprite(palette: Map[String, Color], map: Map[String, Json]): Result[JsonError, UiWidget.SpriteComp] =
        forM (
            texture    <- (DocJson.getAtKey(Root, "texture", map): Result[JsonError, String]);
            regionRect <- parseRegionRectOpt(map);
            scale      <- parseVec2Or("scale", {x = 1.0, y = 1.0}, map);
            flipHOpt   <- (DocJson.getAtKeyOpt(Root, "flipH", map): Result[JsonError, Option[Bool]]);
            flipVOpt   <- (DocJson.getAtKeyOpt(Root, "flipV", map): Result[JsonError, Option[Bool]]);
            tintOpt    <- parseColorOpt(palette, "tint", map);
            zIndexOpt  <- (DocJson.getAtKeyOpt(Root, "zIndex", map): Result[JsonError, Option[Int32]]);
            hframesOpt <- (DocJson.getAtKeyOpt(Root, "hframes", map): Result[JsonError, Option[Int32]]);
            vframesOpt <- (DocJson.getAtKeyOpt(Root, "vframes", map): Result[JsonError, Option[Int32]]);
            frameOpt   <- (DocJson.getAtKeyOpt(Root, "frame", map): Result[JsonError, Option[Int32]])
        ) yield ({
            texture = texture, regionRect = regionRect, scale = scale,
            flipH = Option.getWithDefault(false, flipHOpt),
            flipV = Option.getWithDefault(false, flipVOpt),
            tint = Option.getWithDefault(white(), tintOpt),
            zIndex = Option.getWithDefault(0, zIndexOpt),
            hframes = Option.getWithDefault(1, hframesOpt),
            vframes = Option.getWithDefault(1, vframesOpt),
            frame = Option.getWithDefault(0, frameOpt)
        }: UiWidget.SpriteComp)

    def parsePoly(palette: Map[String, Color], map: Map[String, Json]): Result[JsonError, PolySpec] =
        forM (
            points      <- parsePointList(map);
            _enough     <- if (List.length(points) >= 3) Ok(())
                           else Err(DocJson.jsonError(Root, Set#{"poly points must have >= 3 entries (got: ${List.length(points)})"}));
            color       <- parseColor(palette, "color", map);
            alphaOpt    <- (DocJson.getAtKeyOpt(Root, "alpha", map): Result[JsonError, Option[Float64]]);
            zIndexOpt   <- (DocJson.getAtKeyOpt(Root, "zIndex", map): Result[JsonError, Option[Int32]]);
            rotationOpt <- (DocJson.getAtKeyOpt(Root, "rotation", map): Result[JsonError, Option[Float64]]);
            pivot       <- parseVec2Opt("pivot", map)
        ) yield ({
            points = points, color = color,
            alpha = Option.getWithDefault(1.0, alphaOpt),
            zIndex = Option.getWithDefault(0, zIndexOpt),
            rotation = Option.getWithDefault(0.0, rotationOpt),
            pivot = pivot
        }: PolySpec)

    // ── 図形 widget の共通フィールドと各パラメータ ──

    def shapeWidget(palette: Map[String, Color], map: Map[String, Json], shapeRes: Result[JsonError, UiShape.Shape]): Result[JsonError, Widget] =
        forM (
            shape          <- shapeRes;
            color          <- parseColor(palette, "color", map);
            alphaOpt       <- (DocJson.getAtKeyOpt(Root, "alpha", map): Result[JsonError, Option[Float64]]);
            zIndexOpt      <- (DocJson.getAtKeyOpt(Root, "zIndex", map): Result[JsonError, Option[Int32]]);
            borderWidthOpt <- (DocJson.getAtKeyOpt(Root, "borderWidth", map): Result[JsonError, Option[Float64]]);
            borderColorOpt <- parseColorOpt(palette, "borderColor", map);
            turn           <- parseTurn(map)
        ) yield Widget.ShapeW({
            shape = ({
                shape = shape, color = color,
                alpha = Option.getWithDefault(1.0, alphaOpt),
                zIndex = Option.getWithDefault(0, zIndexOpt),
                borderWidth = Option.getWithDefault(0.0, borderWidthOpt),
                borderColor = borderColorOpt
            }: UiShape.ShapeComp),
            rotation = turn#rotation, pivot = turn#pivot
        })

    def parseCircle(map: Map[String, Json]): Result[JsonError, UiShape.Shape] =
        forM (radius <- (DocJson.getAtKey(Root, "radius", map): Result[JsonError, Float64]))
        yield UiShape.Shape.CircleS({ radius = radius })

    def parseNgon(map: Map[String, Json]): Result[JsonError, UiShape.Shape] =
        forM (
            n      <- (DocJson.getAtKey(Root, "n", map): Result[JsonError, Int32]);
            radius <- (DocJson.getAtKey(Root, "radius", map): Result[JsonError, Float64])
        ) yield UiShape.Shape.NgonS({ n = n, radius = radius })

    def parseStar(map: Map[String, Json]): Result[JsonError, UiShape.Shape] =
        forM (
            points <- (DocJson.getAtKey(Root, "points", map): Result[JsonError, Int32]);
            outer  <- (DocJson.getAtKey(Root, "outer", map): Result[JsonError, Float64]);
            inner  <- (DocJson.getAtKey(Root, "inner", map): Result[JsonError, Float64]);
            via    <- parseVia(map)
        ) yield UiShape.Shape.StarS({ points = points, outer = outer, inner = inner, via = via })

    def parseEllipse(map: Map[String, Json]): Result[JsonError, UiShape.Shape] =
        forM (
            radii    <- parseVec2("radii", map);
            segsOpt  <- (DocJson.getAtKeyOpt(Root, "segments", map): Result[JsonError, Option[Int32]]);
            via      <- parseVia(map)
        ) yield UiShape.Shape.EllipseS({ radii = radii, segments = Option.getWithDefault(32, segsOpt), via = via })

    /// sector / segment 共通（radius + from/to）。isSector で作る形を選ぶ。
    def parseSweep(map: Map[String, Json], isSector: Bool): Result[JsonError, UiShape.Shape] =
        forM (
            radius <- (DocJson.getAtKey(Root, "radius", map): Result[JsonError, Float64]);
            fromT  <- (DocJson.getAtKey(Root, "from", map): Result[JsonError, Float64]);
            toT    <- (DocJson.getAtKey(Root, "to", map): Result[JsonError, Float64])
        ) yield {
            if (isSector) UiShape.Shape.SectorS({ radius = radius, fromT = fromT, toT = toT })
            else          UiShape.Shape.SegmentS({ radius = radius, fromT = fromT, toT = toT })
        }

    def parseLine(map: Map[String, Json]): Result[JsonError, UiShape.Shape] =
        forM (
            points    <- parsePointList(map);
            lineWidth <- (DocJson.getAtKey(Root, "lineWidth", map): Result[JsonError, Float64]);
            shape     <- match points {
                case a :: b :: Nil => Ok(UiShape.Shape.LineS({ a = a, b = b, lineWidth = lineWidth }))
                case _ => Err(DocJson.jsonError(Root, Set#{"line points must be [[x1,y1],[x2,y2]]"}))
            }
        ) yield shape

    def parsePolyline(map: Map[String, Json]): Result[JsonError, UiShape.Shape] =
        forM (
            points    <- parsePointList(map);
            lineWidth <- (DocJson.getAtKey(Root, "lineWidth", map): Result[JsonError, Float64]);
            _enough   <- if (List.length(points) >= 2) Ok(())
                         else Err(DocJson.jsonError(Root, Set#{"polyline points must have >= 2 entries"}))
        ) yield UiShape.Shape.PolylineS({ points = points, lineWidth = lineWidth })

    def parseBezier(map: Map[String, Json]): Result[JsonError, UiShape.Shape] =
        forM (
            points   <- parsePointList(map);
            stepsOpt <- (DocJson.getAtKeyOpt(Root, "steps", map): Result[JsonError, Option[Int32]]);
            taper    <- parseTaper(map);
            shape    <- match points {
                case p0 :: ctrl :: p1 :: Nil =>
                    Ok(UiShape.Shape.BezierS({ p0 = p0, ctrl = ctrl, p1 = p1,
                                               steps = Option.getWithDefault(16, stepsOpt),
                                               widthFrom = taper#w0, widthTo = taper#w1 }))
                case _ => Err(DocJson.jsonError(Root, Set#{"bezier points must be [[p0],[ctrl],[p1]]"}))
            }
        ) yield shape

    def parseVia(map: Map[String, Json]): Result[JsonError, UiShape.Via] =
        match (DocJson.getAtKeyOpt(Root, "via", map): Result[JsonError, Option[String]]) {
            case Err(e)              => Err(e)
            case Ok(None)            => Ok(UiShape.Via.RenderVia)
            case Ok(Some("render"))  => Ok(UiShape.Via.RenderVia)
            case Ok(Some("bezier"))  => Ok(UiShape.Via.BezierVia)
            case Ok(Some(unknown))   => Err(DocJson.jsonError(Root, Set#{"via must be render|bezier (got: ${unknown})"}))
        }

    /// "taper": {"from": w0, "to": w1}（bezier の線形太さ。t=0 で w0、t=1 で w1）。
    /// レコードラベルの from/to は Flix の予約語なので内部名は w0/w1。
    def parseTaper(map: Map[String, Json]): Result[JsonError, {w0 = Float64, w1 = Float64}] =
        match (DocJson.getAtKeyOpt(Root, "taper", map): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)      => Err(e)
            case Ok(None)    => Err(DocJson.jsonError(Root, Set#{"bezier requires 'taper' {\"from\": w0, \"to\": w1}"}))
            case Ok(Some(m)) => forM (
                w0 <- (DocJson.getAtKey(Root, "from", m): Result[JsonError, Float64]);
                w1 <- (DocJson.getAtKey(Root, "to", m): Result[JsonError, Float64])
            ) yield { w0 = w0, w1 = w1 }
        }

    // ========================================================================
    // スタイル解析
    // ========================================================================

    def parseStyle(map: Map[String, Json]): Result[JsonError, UiLayout.Style] =
        forM (
            dirOpt   <- (DocJson.getAtKeyOpt(Root, "dir", map): Result[JsonError, Option[String]]);
            dir      <- parseDir(dirOpt);
            gapOpt   <- (DocJson.getAtKeyOpt(Root, "gap", map): Result[JsonError, Option[Float64]]);
            pad      <- parsePad(map);
            width    <- parseSizeSpec("width", map);
            height   <- parseSizeSpec("height", map);
            mainOpt  <- (DocJson.getAtKeyOpt(Root, "mainAlign", map): Result[JsonError, Option[String]]);
            main     <- parseMainAlign(mainOpt);
            crossOpt <- (DocJson.getAtKeyOpt(Root, "crossAlign", map): Result[JsonError, Option[String]]);
            cross    <- parseCrossAlign(crossOpt);
            wrapOpt  <- parseFlexWrap(map);
            abs      <- parseVec2Opt("abs", map);
            wrap     <- validateWrap(wrapOpt, dir, width, height)
        ) yield ({
            dir = dir, gap = Option.getWithDefault(0.0, gapOpt),
            padLeft = pad#l, padTop = pad#t, padRight = pad#r, padBottom = pad#b,
            width = width, height = height,
            mainAlign = main, crossAlign = cross,
            wrap = wrap,
            abs = abs
        }: UiLayout.Style)

    /// コンテナの "wrap"（真偽値 — 主軸に収まらない子を次の行へ送る flex wrap）を読む。
    /// 文字列・数値は text widget の折り返し宣言（parseTextWrap の領分）なので、
    /// ここでは flex wrap 無しとして素通しする。
    def parseFlexWrap(map: Map[String, Json]): Result[JsonError, Bool] =
        match Map.get("wrap", map) {
            case None             => Ok(false)
            case Some(JBool(b))   => Ok(b)
            case Some(JString(_)) => Ok(false)
            case Some(JNumber(_)) => Ok(false)
            case Some(_)          => Err(DocJson.jsonError(Root, Set#{
                "wrap must be true/false (container) or \"auto\"/number (text)"}))
        }

    /// wrap の前提を検査する。折り返し位置は幅から、全体の高さは折り返し結果から決まるので、
    /// 幅と高さの両方を書いた Row でだけ使える（黙って変な形に潰さない）。
    def validateWrap(wrap: Bool, dir: UiLayout.Dir, width: UiLayout.SizeSpec,
                     height: UiLayout.SizeSpec): Result[JsonError, Bool] =
        if (not wrap) Ok(false)
        else if (dir != UiLayout.Dir.Row)
            Err(DocJson.jsonError(Root, Set#{"wrap is only supported with dir: \"row\""}))
        else if (isAuto(width) or isAuto(height))
            Err(DocJson.jsonError(Root, Set#{"wrap requires explicit width and height (px or \"grow\") — auto cannot be solved"}))
        else Ok(true)

    def isAuto(spec: UiLayout.SizeSpec): Bool =
        match spec { case UiLayout.SizeSpec.Auto => true case _ => false }

    def parseDir(opt: Option[String]): Result[JsonError, UiLayout.Dir] =
        match opt {
            case None           => Ok(UiLayout.Dir.Column)
            case Some("row")    => Ok(UiLayout.Dir.Row)
            case Some("column") => Ok(UiLayout.Dir.Column)
            case Some(unknown)  => Err(DocJson.jsonError(Root, Set#{"dir must be row|column (got: ${unknown})"}))
        }

    def parseMainAlign(opt: Option[String]): Result[JsonError, UiLayout.MainAlign] =
        match opt {
            case None                 => Ok(UiLayout.MainAlign.Start)
            case Some("start")        => Ok(UiLayout.MainAlign.Start)
            case Some("center")       => Ok(UiLayout.MainAlign.Center)
            case Some("end")          => Ok(UiLayout.MainAlign.End)
            case Some("spaceBetween") => Ok(UiLayout.MainAlign.SpaceBetween)
            case Some(unknown)        => Err(DocJson.jsonError(Root, Set#{"mainAlign unknown (got: ${unknown})"}))
        }

    def parseCrossAlign(opt: Option[String]): Result[JsonError, UiLayout.CrossAlign] =
        match opt {
            case None            => Ok(UiLayout.CrossAlign.Start)
            case Some("start")   => Ok(UiLayout.CrossAlign.Start)
            case Some("center")  => Ok(UiLayout.CrossAlign.Center)
            case Some("end")     => Ok(UiLayout.CrossAlign.End)
            case Some("stretch") => Ok(UiLayout.CrossAlign.Stretch)
            case Some(unknown)   => Err(DocJson.jsonError(Root, Set#{"crossAlign unknown (got: ${unknown})"}))
        }

    def parsePad(map: Map[String, Json]): Result[JsonError, {l = Float64, t = Float64, r = Float64, b = Float64}] =
        match (DocJson.getAtKeyOpt(Root, "pad", map): Result[JsonError, Option[List[Float64]]]) {
            case Err(e)   => Err(e)
            case Ok(None) => Ok({l = 0.0, t = 0.0, r = 0.0, b = 0.0})
            case Ok(Some(left :: top :: right :: bottom :: Nil)) => Ok({l = left, t = top, r = right, b = bottom})
            case Ok(Some(_)) => Err(DocJson.jsonError(Root, Set#{"pad must be [left, top, right, bottom]"}))
        }

    def parseSizeSpec(key: String, map: Map[String, Json]): Result[JsonError, UiLayout.SizeSpec] =
        match Map.get(key, map) {
            case None                  => Ok(UiLayout.SizeSpec.Auto)
            case Some(JString("auto")) => Ok(UiLayout.SizeSpec.Auto)
            case Some(JString("grow")) => Ok(UiLayout.SizeSpec.Grow(1.0))
            case Some(JNumber(bd))     => Ok(UiLayout.SizeSpec.Px(bigDecToF64(bd)))
            case Some(_)               => Err(DocJson.jsonError(Root, Set#{"${key} must be a number, \"auto\", or \"grow\""}))
        }

    // ========================================================================
    // 点・ベクトル・色
    // ========================================================================

    /// "points": [[x,y], ...] を Vec2 列へ（点数の下限は呼び手が形ごとに検査する）。
    def parsePointList(map: Map[String, Json]): Result[JsonError, List[Vec2.Vec2]] =
        match Map.get("points", map) {
            case None              => Err(DocJson.jsonError(Root, Set#{"'points' is required"}))
            case Some(JArray(arr)) => Result.traverse(pointJson -> parsePointJson(pointJson), Vector.toList(arr))
            case Some(_)           => Err(DocJson.jsonError(Root, Set#{"points must be an array of [x, y]"}))
        }

    def parsePointJson(json: Json): Result[JsonError, Vec2.Vec2] =
        match json {
            case JArray(v) => match Vector.toList(v) {
                case JNumber(x) :: JNumber(y) :: Nil => Ok({x = bigDecToF64(x), y = bigDecToF64(y)})
                case _                               => Err(DocJson.jsonError(Root, Set#{"point must be [x, y]"}))
            }
            case _ => Err(DocJson.jsonError(Root, Set#{"point must be [x, y]"}))
        }

    /// [x, y] を Vec2 へ（必須）。
    def parseVec2(key: String, map: Map[String, Json]): Result[JsonError, Vec2.Vec2] =
        match (DocJson.getAtKey(Root, key, map): Result[JsonError, List[Float64]]) {
            case Err(e)            => Err(e)
            case Ok(x :: y :: Nil) => Ok({x = x, y = y})
            case Ok(_)             => Err(DocJson.jsonError(Root, Set#{"${key} must be [x, y]"}))
        }

    /// [x, y] を Vec2 へ。キー欠落は None。
    def parseVec2Opt(key: String, map: Map[String, Json]): Result[JsonError, Option[Vec2.Vec2]] =
        match (DocJson.getAtKeyOpt(Root, key, map): Result[JsonError, Option[List[Float64]]]) {
            case Err(e)                  => Err(e)
            case Ok(None)                => Ok(None)
            case Ok(Some(x :: y :: Nil)) => Ok(Some({x = x, y = y}))
            case Ok(Some(_))             => Err(DocJson.jsonError(Root, Set#{"${key} must be [x, y]"}))
        }

    /// [x, y] を Vec2 へ。欠落は既定値。
    def parseVec2Or(key: String, fallback: Vec2.Vec2, map: Map[String, Json]): Result[JsonError, Vec2.Vec2] =
        parseVec2Opt(key, map) |> Result.map(Option.getWithDefault(fallback))

    /// "regionRect": {"pos": [x,y], "size": [w,h]} を Rect2 へ。欠落は None。
    def parseRegionRectOpt(map: Map[String, Json]): Result[JsonError, Option[Rect2.Rect2]] =
        match (DocJson.getAtKeyOpt(Root, "regionRect", map): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)      => Err(e)
            case Ok(None)    => Ok(None)
            case Ok(Some(m)) => forM (
                pos  <- parseVec2("pos", m);
                size <- parseVec2("size", m)
            ) yield Some(({position = pos, size = size}: Rect2.Rect2))
        }

    /// 色（必須）: "#rrggbb" | {"hsv":[h,s,v]} | {"rgb":[r,g,b]}。
    def parseColor(palette: Map[String, Color], key: String, map: Map[String, Json]): Result[JsonError, Color] =
        match Map.get(key, map) {
            case None       => Err(DocJson.jsonError(Root, Set#{"'${key}' is required"}))
            case Some(json) => colorOf(palette, key, json)
        }

    /// 色。キー欠落は None。
    def parseColorOpt(palette: Map[String, Color], key: String, map: Map[String, Json]): Result[JsonError, Option[Color]] =
        match Map.get(key, map) {
            case None       => Ok(None)
            case Some(json) => colorOf(palette, key, json) |> Result.map(color -> Some(color))
        }

    /// 色 1 値のパース（"#rrggbb" / {"hsv":[h,s,v]} / {"rgb":[r,g,b]} / "@パレット名"）。
    /// pub なのは fx.json（FxDoc）が同じ色表記を読むため — 色方言の定義はここに一本化する。
    pub def colorOf(palette: Map[String, Color], key: String, json: Json): Result[JsonError, Color] =
        match json {
            case JString(s) =>
                if (String.startsWith(prefix = "@", s))
                    Map.get(String.drop(1, s), palette) |> Option.toOk(DocJson.jsonError(Root,
                        Set#{"${key}: unknown palette color '${s}' (defined: ${definedNames(palette)})"}))
                else hexToColor(s)
            case JObject(m)   => match (Map.get("hsv", m), Map.get("rgb", m)) {
                case (Some(hsvJson), None) =>
                    floats3(key, hsvJson) |> Result.map(t -> {
                        let (h, s, v) = t;
                        Color.hsv({ h = h, s = s, v = v })
                    })
                case (None, Some(rgbJson)) =>
                    floats3(key, rgbJson) |> Result.map(t -> {
                        let (r, g, b) = t;
                        ({ r = r, g = g, b = b }: Color)
                    })
                case _ => Err(colorFormatError(key))
            }
            case _ => Err(colorFormatError(key))
        }

    /// パレット定義名の一覧を読みやすい形にする(空なら "none")。
    def definedNames(palette: Map[String, Color]): String =
        let names = Map.keysOf(palette) |> Set.toList;
        if (List.isEmpty(names)) "none" else String.intercalate(", ", names)

    def colorFormatError(key: String): JsonError =
        DocJson.jsonError(Root, Set#{"${key} must be \"#rrggbb\", {\"hsv\":[h,s,v]}, or {\"rgb\":[r,g,b]}"})

    def floats3(key: String, json: Json): Result[JsonError, (Float64, Float64, Float64)] =
        match json {
            case JArray(v) => match Vector.toList(v) {
                case JNumber(a) :: JNumber(b) :: JNumber(c) :: Nil =>
                    Ok((bigDecToF64(a), bigDecToF64(b), bigDecToF64(c)))
                case _ => Err(DocJson.jsonError(Root, Set#{"${key} components must be 3 numbers"}))
            }
            case _ => Err(DocJson.jsonError(Root, Set#{"${key} components must be 3 numbers"}))
        }

    /// "#rrggbb"（先頭 # は任意）を Color へ。6 桁 16 進以外は Err。
    /// 読み取り自体は Color.hex が持つ（Flix のリテラルからも同じ変換を使えるように）。
    /// ここは JSON の言葉づかいでの説明を足すだけ。
    def hexToColor(hex: String): Result[JsonError, Color] =
        match Color.hex(hex) {
            case Some(c) => Ok(c)
            case None    => Err(DocJson.jsonError(Root, Set#{"hex color must be #rrggbb (got: ${hex})"}))
        }

    def white(): Color = {r = 1.0, g = 1.0, b = 1.0}

    def bigDecToF64(bd: BigDecimal): Float64 =
        bd.doubleValue()

    // ========================================================================
    // build（Spec → Flex.Node — 静的な Flex 経路）
    // ========================================================================

    /// Spec を Flex 木へ。atlasOf はフォント名 → FontAtlas（text の実寸計測と描画に使う）。
    /// sprite ノードを含むドキュメントは buildWith / renderWith（textureInfoOf 注入）を使う —
    /// この近道はテクスチャ寸法を引けないので、格子分割 sprite はセル切り出しされない。
    /// visible=false の子は部分木ごと落とす（display:none）。root の visible は無視する。
    pub def build(atlasOf: String -> FontAtlas, spec: Spec): Flex.Node =
        buildWith(atlasOf, _ -> None, spec)

    /// build と同じ。加えて textureInfoOf（テクスチャ名 → 寸法）で sprite の frame 格子も解決できる。
    pub def buildWith(atlasOf: String -> FontAtlas,
                      textureInfoOf: String -> Option[GameEngine.TextureInfo],
                      spec: Spec): Flex.Node =
        buildAt("", atlasOf, textureInfoOf, spec)

    /// buildWith の実体。名前を "/" で繋いだ道（親/子/孫）を各ノードのラベルにする —
    /// これで描いたあとに「あの部品はどこに敷かれたか」を名前で引ける（rectsOf）。
    def buildAt(parentPath: String, atlasOf: String -> FontAtlas,
                textureInfoOf: String -> Option[GameEngine.TextureInfo],
                spec: Spec): Flex.Node =
        let Spec.Spec(node) = spec;
        let path = if (parentPath == "") node#name else "${parentPath}/${node#name}";
        let childNodes = node#children
            |> List.filter(child -> visibleOf(child))
            |> List.map(child -> buildAt(path, atlasOf, textureInfoOf, child));
        Flex.keyed(path, buildNode(atlasOf, textureInfoOf, node, childNodes))

    def buildNode(atlasOf: String -> FontAtlas,
                  textureInfoOf: String -> Option[GameEngine.TextureInfo],
                  node: { name = String, widget = Widget, style = UiLayout.Style,
                          visible = Bool, binding = Option[String], meta = Option[String],
                          hover = Option[UiWidget.HoverStyle], note = Option[String],
                          origin = Option[String], layer = Int32, children = List[Spec] },
                  childNodes: List[Flex.Node]): Flex.Node =
        match node#widget {
            case Widget.NoneW       => Flex.box(node#style, childNodes)
            case Widget.BoxW(b)     => Flex.boxDrawn(node#style, r -> drawBox(textureInfoOf, b, r), childNodes)
            case Widget.TextW(t)    => buildText(atlasOf, node#style, t, childNodes)
            case Widget.SpriteW(sp) => Flex.boxDrawn(node#style,
                r -> ({ at = r#position, item = UiExtract.spriteItem(sp, textureInfoOf) }) :: Nil,
                childNodes)
            case Widget.PolyW(p)    => Flex.boxDrawn(node#style, r -> drawPoly(p, r), childNodes)
            case Widget.ShapeW(s)   => Flex.boxDrawn(node#style,
                r -> turnedIn(s#rotation, s#pivot, r, UiShape.placedItems(s#shape, r)), childNodes)
        }

    def visibleOf(spec: Spec): Bool =
        let Spec.Spec(node) = spec;
        node#visible

    /// 近道: build して place まで。
    pub def render(atlasOf: String -> FontAtlas, spec: Spec, rootRect: Rect2.Rect2): List[Render.PlacedItem] =
        Flex.place(build(atlasOf, spec), rootRect)

    /// 敷いた結果の「名前の道（親/子/孫）→ 画面上の矩形」。当たり判定やツールチップの位置を、
    /// 描くのと同じ宣言から引くための関数 — 座標をコードにもう一度書くと二重管理になる。
    pub def rectsOf(atlasOf: String -> FontAtlas, spec: Spec,
                    rootRect: Rect2.Rect2): Map[String, Rect2.Rect2] =
        Flex.rectsOf(build(atlasOf, spec), rootRect)

    /// 描画物と名前つき矩形を 1 回のレイアウトで両方返す（毎フレーム 2 度敷かない近道）。
    pub def renderWithRects(atlasOf: String -> FontAtlas, spec: Spec, rootRect: Rect2.Rect2):
            (List[Render.PlacedItem], Map[String, Rect2.Rect2]) =
        Flex.placeWithRects(build(atlasOf, spec), rootRect)

    /// render と同じ。sprite を含むドキュメントはこちら（buildWith して place まで）。
    pub def renderWith(atlasOf: String -> FontAtlas,
                       textureInfoOf: String -> Option[GameEngine.TextureInfo],
                       spec: Spec, rootRect: Rect2.Rect2): List[Render.PlacedItem] =
        Flex.place(buildWith(atlasOf, textureInfoOf, spec), rootRect)

    /// text ノード。width/height 未指定なら実寸（Text.measure）を Px として敷く。
    /// 内在サイズに効く折り返しは数値（px）の wrap だけ（auto は矩形が決まってから折る —
    /// UiStore 経路の measureTexts と同じ規則）。描画は UiExtract.textItem に委譲する
    /// （wrap / fit の解決を 2 実装にすると経路で絵が変わるため）。
    def buildText(atlasOf: String -> FontAtlas, style: UiLayout.Style, spec: TextSpec,
                  childNodes: List[Flex.Node]): Flex.Node =
        let t = spec#text;
        let atlas = atlasOf(t#font);
        let dims = Text.measure(Text.make(t#text, atlas, t#fontSize)
            |> Text.setWrapWidth(UiExtract.intrinsicWrapOf(t)));
        let w = match style#width {
            case UiLayout.SizeSpec.Auto => UiLayout.SizeSpec.Px(dims#x)
            case other                  => other
        };
        let h = match style#height {
            case UiLayout.SizeSpec.Auto => UiLayout.SizeSpec.Px(dims#y)
            case other                  => other
        };
        Flex.boxDrawn({ width = w, height = h | style },
            r -> turnedIn(spec#rotation, spec#pivot, r,
                     ({ at = r#position,
                        item = UiExtract.textItem(t, r#size, atlasOf) }) :: Nil),
            childNodes)

    /// box: rect を塗る（skin があれば九分割スキン）。BoxComp→PlacedItem 変換は
    /// UiExtract.boxPlacedItems が唯一の実装（経路で絵が変わる二実装を作らない）。
    def drawBox(textureInfoOf: String -> Option[GameEngine.TextureInfo],
                spec: BoxSpec, r: Rect2.Rect2): List[Render.PlacedItem] =
        UiExtract.boxPlacedItems(spec#box, r#size, textureInfoOf)
            |> Render.movedAll(r#position)
            |> turnedIn(spec#rotation, spec#pivot, r)

    /// rect の中で傾ける。軸は pivot（rect 左上からの相対）か、省略時は rect の中心。
    /// 傾けても敷き詰めの計算（Flex）は動かない — 場所取りは回転前の rect のまま。
    def turnedIn(rotation: Float64, pivot: Option[Vec2.Vec2], r: Rect2.Rect2,
                 items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        if (rotation == 0.0) items
        else {
            let axis = match pivot {
                case Some(p) => Vec2.add(r#position, p)
                case None    => Rect2.center(r)
            };
            Render.turnedAll(rotation, axis, items)
        }

    /// poly: 頂点は rect 左上相対（UiSpec 互換）。rotation は pivot 未指定なら
    /// 「rect 中心を原点」に Render.rotated（頂点をどこ原点で組むかが軸、の流儀そのまま）。
    def drawPoly(p: PolySpec, r: Rect2.Rect2): List[Render.PlacedItem] =
        if (p#rotation == 0.0 and Option.isEmpty(p#pivot))
            ({ at = r#position, item = polyItem(p, p#points) }) :: Nil
        else match p#pivot {
            case Some(pivot) =>
                ({ at = r#position,
                   item = polyItem(p, Render.rotatedAround(p#rotation, pivot, p#points)) }) :: Nil
            case None =>
                let centerLocal = Vec2.div(r#size, 2.0);
                let rel = List.map(v -> Vec2.sub(v, centerLocal), p#points);
                ({ at = Rect2.center(r), item = polyItem(p, Render.rotated(p#rotation, rel)) }) :: Nil
        }

    def polyItem(p: PolySpec, vertices: List[Vec2.Vec2]): Render.Item =
        UiShape.fadeIf(p#alpha, RawDraw.polygon(vertices, p#color, p#zIndex))

    // ========================================================================
    // load（ファイル読み — parse は純粋なまま、IO はここだけ）
    // ========================================================================

    /// path とそこから instance 参照される全ドキュメントを読み、合成して Spec にする。
    /// トップに "paletteFile" があれば外部パレットもここで読んで合成する（リロードでも再読され、
    /// instance で参照される側のドキュメントにも効く — 合成は collectDocs の読み込みで行う）。
    pub def load(path: String): Result[JsonError, Spec] \ Fs.FileRead =
        collectDocs("", path :: Nil, Map.empty()) |> Result.flatMap(resolver ->
            Map.get(path, resolver) |> Option.toOk(unloadedErr(path))
                |> Result.flatMap(json -> parseWith(resolver, json)))

    /// メモリ上のドキュメントを、instance / paletteFile の参照ファイルだけ baseDir 起点で読んで
    /// Spec にする（保存前の編集中ドキュメントを本番と同じ解決で確かめる口）。
    /// resolver のキーは JSON に書かれたパス文字列のまま — ディスク上の置き場所をキーに混ぜると
    /// ドキュメント間の参照（循環検出・訪問済み判定）が食い違うので、結合はファイル読みに限る。
    pub def parseAt(baseDir: String, json: Json): Result[JsonError, Spec] \ Fs.FileRead =
        forM (
            merged   <- mergePaletteFile(baseDir, json);
            resolver <- collectDocs(baseDir, instanceRefs(merged), Map.empty());
            spec     <- parseWith(resolver, merged)
        ) yield spec

    /// baseDir と相対パスの単純連結。baseDir が空なら path をそのまま使う
    /// （load 経路の「CWD 基準のパスがそのまま resolver のキー」という既存契約を崩さない）。
    def joinPath(dir: String, rel: String): String =
        if (dir == "") rel
        else if (String.endsWith(suffix = "/", dir)) "${dir}${rel}"
        else "${dir}/${rel}"

    /// ドキュメント 1 枚を読み、トップに "paletteFile" があれば外部パレットを合成して返す
    /// （同名は inline 勝ち）。parse は純粋なまま — 外部参照はこの load 層で解決する。
    def readDocMerged(baseDir: String, path: String): Result[JsonError, Json] \ Fs.FileRead =
        DocJson.readJson(joinPath(baseDir, path)) |> Result.flatMap(json -> mergePaletteFile(baseDir, json))

    /// トップが object なら paletteFile の合成を試みる（object でなければそのまま）。
    def mergePaletteFile(baseDir: String, json: Json): Result[JsonError, Json] \ Fs.FileRead =
        match json {
            case JObject(top) => mergePaletteInto(baseDir, top)
            case _            => Ok(json)
        }

    /// "paletteFile" が無ければそのまま。パス文字列なら読んで "palette" キーを合成し直す。
    def mergePaletteInto(baseDir: String, top: Map[String, Json]): Result[JsonError, Json] \ Fs.FileRead =
        match Map.get("paletteFile", top) {
            case None                  => Ok(JObject(top))
            case Some(JString(pfPath)) => forM (
                filePalette <- readPaletteFile(baseDir, pfPath);
                merged      <- overlayInlinePalette(filePalette, top)
            ) yield JObject(Map.insert("palette", JObject(merged), top))
            case Some(_)               => Err(DocJson.jsonError(Root, Set#{"paletteFile must be a string path"}))
        }

    /// paletteFile を読んでパレットの Map にする。読めない・形が違うときは loud に Err（黙って無視しない）。
    /// "version" は Doc 規約のメタキーで色定義ではないので、ここで取り除く。
    def readPaletteFile(baseDir: String, path: String): Result[JsonError, Map[String, Json]] \ Fs.FileRead =
        DocJson.readJson(joinPath(baseDir, path))
            |> Result.mapErr(e -> DocJson.jsonError(Root, Set#{"paletteFile: ${DocJson.describe(e)}"}))
            |> Result.flatMap(json -> match json {
                case JObject(m) => Ok(Map.remove("version", m))
                case _          => Err(DocJson.jsonError(Root, Set#{"paletteFile must be an object"}))
            })

    /// inline "palette" を外部パレットの上に重ねる（同名は inline 勝ち）。inline が無ければ外部のまま。
    def overlayInlinePalette(filePalette: Map[String, Json], top: Map[String, Json]): Result[JsonError, Map[String, Json]] =
        match Map.get("palette", top) {
            case None    => Ok(filePalette)
            case Some(j) => DocJson.asObject("palette", j)
                |> Result.map(inline -> Map.foldLeftWithKey((acc, k, v) -> Map.insert(k, v, acc), filePalette, inline))
        }

    /// frontier のドキュメントを読み、instance 参照を辿って全部集める（訪問済みは読まない —
    /// 循環していても読み込みはここで止まり、循環自体は parse が Err にする）。
    def collectDocs(baseDir: String, frontier: List[String], acc: Map[String, Json]): Result[JsonError, Map[String, Json]] \ Fs.FileRead =
        match frontier {
            case Nil => Ok(acc)
            case path :: rest =>
                if (Map.memberOf(path, acc)) collectDocs(baseDir, rest, acc)
                else match readDocMerged(baseDir, path) {
                    case Err(e)   => Err(e)
                    case Ok(json) =>
                        let refs = instanceRefs(json) |> List.filter(p -> not Map.memberOf(p, acc));
                        collectDocs(baseDir, List.append(refs, rest), Map.insert(path, json, acc))
                }
        }

    /// JSON 木から "instance" 参照のパスを全部拾う。
    def instanceRefs(json: Json): List[String] =
        match json {
            case JObject(m) =>
                let own = instancePathOf(m) |> Option.toList;
                let nested = Map.valuesOf(m) |> List.flatMap(v -> instanceRefs(v));
                List.append(own, nested)
            case JArray(vs) => Vector.toList(vs) |> List.flatMap(v -> instanceRefs(v))
            case _          => Nil
        }

    def instancePathOf(m: Map[String, Json]): Option[String] =
        match Map.get("instance", m) {
            case Some(JString(p)) => Some(p)
            case _                => None
        }

    /// 起動時ロード用の近道。失敗はドキュメントの書き損じなので即死してエラーを見せる。
    pub def loadOrBug(path: String): Spec \ Fs.FileRead =
        match load(path) {
            case Ok(spec) => spec
            case Err(e)   => bug!("UiDoc.load(${path}): ${DocJson.describe(e)}")
        }
}
