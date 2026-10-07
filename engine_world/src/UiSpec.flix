// UiSpec — UI ツリーの宣言層（ui.json → UiStore spawn）
//
// ui.json のパースは UiDoc（唯一のパーサ）に一本化し、ここは UiDoc.Spec を UiStore 向けの
// flat な Spec へ射影して spawn / respawn / リロードレジストリを担う。
//
// UiDoc の poly rotation/pivot 拡張は UiStore 経路では未対応 — 黙って無視すると同じ JSON が
// 経路によって絵を変えてしまうため、loud に Err する。

pub mod UiSpec {
    use Util.Json.Json
    use Util.Json.JsonError
    use DocJson.PathTag.Root

    /// ノードの描画種別。box=単色矩形、text=テキスト、sprite=スプライト、poly=塗り潰し多角形、
    /// shape=パラメトリック図形（circle/ngon/star/ellipse/sector/segment/line/polyline/bezier）、
    /// none=描画を持たないレイアウト専用コンテナ。
    pub enum Widget with Eq {
        case BoxW
        case TextW
        case SpriteW
        case PolyW
        case ShapeW
        case NoneW
    }

    /// テンプレート解決済みの UI ノード。ツリーは children で再帰する。
    /// `name`: 兄弟内で一意な識別名（名前パスの構成要素）。
    /// `widget`: 描画種別。`style`: レイアウト属性。
    /// `box`/`text`/`sprite`/`poly`/`shape`: widget に対応する描画コンポーネント（それ以外は None）。
    /// `visible`: 初期可視。`binding`: text 流し込み先の bind key。
    /// `meta`: メニュー項目等の識別 metadata。`layer`: root の描画レイヤ（非 root では無視）。
    /// `children`: 子ノード（宣言順）。
    pub enum Spec {
        case Spec({
            name     = String,
            widget   = Widget,
            style    = UiLayout.Style,
            box      = Option[UiWidget.BoxComp],
            text     = Option[UiWidget.TextComp],
            sprite   = Option[UiWidget.SpriteComp],
            poly     = Option[UiWidget.PolyComp],
            shape    = Option[UiShape.ShapeComp],
            hover    = Option[UiWidget.HoverStyle],
            visible  = Bool,
            binding  = Option[String],
            meta     = Option[String],
            layer    = Int32,
            children = List[Spec]
        })
    }

    // ========================================================================
    // parse（純粋 — 方言は UiDoc、ここは射影のみ）
    // ========================================================================

    /// ui.json を Spec へ読み取る。パースは UiDoc.parse（templates/use・スタイル・全 widget・
    /// 色 3 表記・version・ノードパス付きエラー）に委譲し、UiStore 向けの形へ射影する。
    pub def parse(json: Json): Result[JsonError, Spec] =
        UiDoc.parse(json) |> Result.flatMap(spec -> toSpec(spec))

    /// UiDoc.Spec（payload 持ち Widget）→ UiStore 向けの flat な Spec。
    def toSpec(doc: UiDoc.Spec): Result[JsonError, Spec] =
        let UiDoc.Spec.Spec(node) = doc;
        forM (
            comps    <- projectWidget(node#name, node#widget);
            children <- Result.traverse(child -> toSpec(child), node#children)
        ) yield Spec.Spec({
            name = node#name, widget = comps#widget, style = node#style,
            box = comps#box, text = comps#text, sprite = comps#sprite,
            poly = comps#poly, shape = comps#shape, hover = node#hover,
            visible = node#visible, binding = node#binding, meta = node#meta,
            layer = node#layer, children = children
        })

    /// widget 1 個ぶんの射影結果（種別タグ + 対応コンポーネントだけ Some）。
    type alias WidgetComps = {
        widget = Widget,
        box = Option[UiWidget.BoxComp], text = Option[UiWidget.TextComp],
        sprite = Option[UiWidget.SpriteComp], poly = Option[UiWidget.PolyComp],
        shape = Option[UiShape.ShapeComp]
    }

    def noComps(widget: Widget): WidgetComps =
        { widget = widget, box = None, text = None, sprite = None, poly = None, shape = None }

    /// 傾きが指定されていたら断る（黙って傾きを落とすと、経路によって絵が変わる）。
    def turnUnsupported(name: String, kind: String, rotation: Float64,
                        pivot: Option[Vec2.Vec2]): Result[JsonError, Unit] =
        if (rotation != 0.0 or not Option.isEmpty(pivot))
            Err(DocJson.jsonError(Root, Set#{
                "at ${name}: ${kind} rotation/pivot is not supported via UiSpec/UiStore yet (use the UiDoc/Flex path)"}))
        else Ok(())

    def projectWidget(name: String, w: UiDoc.Widget): Result[JsonError, WidgetComps] =
        match w {
            case UiDoc.Widget.NoneW      => Ok(noComps(Widget.NoneW))
            case UiDoc.Widget.BoxW(b)    =>
                turnUnsupported(name, "box", b#rotation, b#pivot)
                    |> Result.map(_ -> { box = Some(b#box) | noComps(Widget.BoxW) })
            case UiDoc.Widget.TextW(t)   =>
                turnUnsupported(name, "text", t#rotation, t#pivot)
                    |> Result.map(_ -> { text = Some(t#text) | noComps(Widget.TextW) })
            case UiDoc.Widget.SpriteW(s) => Ok({ sprite = Some(s) | noComps(Widget.SpriteW) })
            case UiDoc.Widget.ShapeW(s)  =>
                turnUnsupported(name, "shape", s#rotation, s#pivot)
                    |> Result.map(_ -> { shape = Some(s#shape) | noComps(Widget.ShapeW) })
            case UiDoc.Widget.PolyW(p)   =>
                if (p#rotation != 0.0 or not Option.isEmpty(p#pivot))
                    Err(DocJson.jsonError(Root, Set#{
                        "at ${name}: poly rotation/pivot is not supported via UiSpec/UiStore yet (use the UiDoc/Flex path)"}))
                else
                    Ok({ poly = Some(({ polys = p#points :: Nil, color = p#color,
                                        alpha = p#alpha, zIndex = p#zIndex }: UiWidget.PolyComp))
                         | noComps(Widget.PolyW) })
        }

    // ========================================================================
    // load（ファイル読み）
    // ========================================================================

    /// ui.json を読み込んで Spec にする。instance の参照先も UiDoc.load が読み集める。
    pub def load(path: String): Result[JsonError, Spec] \ Fs.FileRead =
        UiDoc.load(path) |> Result.flatMap(spec -> toSpec(spec))

    /// メモリ上のドキュメントを Spec にする。instance / paletteFile の参照ファイルは baseDir 起点で読む。
    pub def parseAt(baseDir: String, json: Json): Result[JsonError, Spec] \ Fs.FileRead =
        UiDoc.parseAt(baseDir, json) |> Result.flatMap(spec -> toSpec(spec))

    // ========================================================================
    // spawn / respawn
    // ========================================================================

    /// Spec の全ノードを UiStore へ登録し、root の EntityId と更新後の UiWorld を返す。
    /// 名前パスは root 名を起点に "root/child/..." で組み立てる。
    /// （`spawn` は Flix の予約語のため `spawnRoot` と名付ける。despawnRoot と対になる。）
    pub def spawnRoot(spec: Spec, ui: UiStore.UiWorld): (EntityId, UiStore.UiWorld) =
        spawnNode(spec, nameOf(spec), None, 0, ui)

    /// spec 由来 store を root ごと捨ててから spawnRoot し直す。selection/focus は String キーゆえ生存する。
    /// さらに despawn 前の「名前パス→可視」を採取し、再 spawn 後に同じ名前パスへ引き継ぐ。
    /// これによりゲームが動的に切り替えた可視状態（バー表示・集合中ラベル等）がリロードを生き延びる。
    /// 再 spawn で新設された名前パスは spec 既定の可視のまま。
    pub def respawn(spec: Spec, ui: UiStore.UiWorld): (EntityId, UiStore.UiWorld) =
        let rootPath = nameOf(spec);
        let visibleBefore = UiStore.visibleByPath(rootPath, ui);
        let (id, ui2) = spawnRoot(spec, UiStore.despawnRoot(rootPath, ui));
        (id, UiStore.applyVisibleByPath(visibleBefore, ui2))

    /// ui.json を読み込んで spawnRoot し、root 名パス→アセットパスを sources レジストリへ登録する。
    /// これ 1 本で「読む・木を作る・リロードレジストリに載せる」が揃う。load/parse 失敗は Err。
    pub def spawnAsset(path: String, ui: UiStore.UiWorld): Result[JsonError, (EntityId, UiStore.UiWorld)] \ Fs.FileRead =
        forM (spec <- load(path)) yield {
            let (id, ui2) = spawnRoot(spec, ui);
            (id, UiStore.putSource(nameOf(spec), path, ui2))
        }

    /// `spawnAsset` の別名 root 版。同じアセットを複数の root として組みたいとき（味方カードと
    /// 敵カードが 1 枚の `UnitCard.ui.json` を左右 2 root で使う等）に、spec の root 名を
    /// `rootName` に差し替えてから spawn し、`rootName` をキーに sources レジストリへ登録する。
    /// sources のキー（登録した root 名）は名前パス機構とコードの契約なので、reloadAll は
    /// このキーへ強制的に付け直す（後述 reloadOne）。load/parse 失敗は Err。
    pub def spawnAssetAs(path: String, rootName: String, ui: UiStore.UiWorld): Result[JsonError, (EntityId, UiStore.UiWorld)] \ Fs.FileRead =
        forM (spec <- load(path)) yield {
            let (id, ui2) = spawnRoot(withRootName(spec, rootName), ui);
            (id, UiStore.putSource(rootName, path, ui2))
        }

    /// spec の root ノードの `name` だけを差し替える（子孫はそのまま）。別名 spawn / リロードで使う。
    def withRootName(spec: Spec, rootName: String): Spec =
        let Spec.Spec(fields) = spec;
        Spec.Spec({name = rootName | fields})

    /// sources レジストリの全 root を走査し、各アセットを読み直して respawn する（F1 ホットリロード）。
    /// load/parse に失敗した root は旧ツリーを保持し、残りの root のリロードは続行する。
    /// respawn は sources を触らないため、走査中にレジストリは変わらない。
    pub def reloadAll(ui: UiStore.UiWorld): UiStore.UiWorld \ Fs.FileRead =
        let (ui2, _) = reloadAllWithReport(ui);
        ui2

    /// reloadAll と同じリロードに加えて、失敗した root の (root 名, エラー文言) のリストを返す。
    pub def reloadAllWithReport(ui: UiStore.UiWorld): (UiStore.UiWorld, List[(String, String)]) \ Fs.FileRead =
        ui#sources |> Map.foldLeftWithKey((acc, rootName, assetPath) -> {
            let (uiAcc, errs) = acc;
            match load(assetPath) {
                case Err(e)   => (uiAcc, (rootName, DocJson.describe(e)) :: errs)
                case Ok(spec) =>
                    let (_, ui2) = respawn(withRootName(spec, rootName), uiAcc);
                    (ui2, errs)
            }
        }, (ui, Nil))

    /// 1 ノードを採番して各 store に登録し、子孫を再帰登録する。
    /// `path`: このノードの完全名パス。`parent`: 親 entity（root は None）。`orderIndex`: 兄弟内の順序。
    def spawnNode(spec: Spec, path: String, parent: Option[EntityId], orderIndex: Int32,
                  ui: UiStore.UiWorld): (EntityId, UiStore.UiWorld) =
        let Spec.Spec(fields) = spec;
        let (id, ui1) = UiStore.alloc(ui);
        let parents1  = match parent { case None => ui1#parents, case Some(pid) => Map.insert(id, pid, ui1#parents) };
        let boxes1    = insertOpt(id, fields#box, ui1#boxes);
        let texts1    = insertOpt(id, fields#text, ui1#texts);
        let sprites1  = insertOpt(id, fields#sprite, ui1#sprites);
        let polys1    = insertOpt(id, fields#poly, ui1#polys);
        let shapes1   = insertOpt(id, fields#shape, ui1#shapes);
        let hovers1   = insertOpt(id, fields#hover, ui1#hovers);
        let bindings1 = insertOpt(id, fields#binding, ui1#bindings);
        let metas1    = insertOpt(id, fields#meta, ui1#metas);
        let layers1   = match parent { case None => Map.insert(id, fields#layer, ui1#layers), case Some(_) => ui1#layers };
        let ui2 = {
            names    = Map.insert(path, id, ui1#names),
            parents  = parents1,
            order    = Map.insert(id, orderIndex, ui1#order),
            styles   = Map.insert(id, fields#style, ui1#styles),
            boxes    = boxes1,
            texts    = texts1,
            sprites  = sprites1,
            polys    = polys1,
            shapes   = shapes1,
            hovers   = hovers1,
            visible  = Map.insert(id, fields#visible, ui1#visible),
            bindings = bindings1,
            metas    = metas1,
            layers   = layers1
            | ui1
        };
        let stepped = List.foldLeft((state, child) -> {
            let childPath = "${path}/${nameOf(child)}";
            let (_, acc2) = spawnNode(child, childPath, Some(id), state#index, state#ui);
            {index = state#index + 1, ui = acc2}
        }, {index = 0, ui = ui2}, fields#children);
        (id, stepped#ui)

    /// Option が Some のときだけ map へ挿入する。
    def insertOpt(id: EntityId, opt: Option[v], m: Map[EntityId, v]): Map[EntityId, v] =
        match opt {
            case None    => m
            case Some(v) => Map.insert(id, v, m)
        }

    /// Spec ノードの name を取り出す。
    def nameOf(spec: Spec): String =
        let Spec.Spec(fields) = spec;
        fields#name

    // ========================================================================
    // Spec ツリーの走査（宣言検査用）
    // ========================================================================

    /// Spec ノードの子一覧を取り出す。
    def childrenOf(spec: Spec): List[Spec] =
        let Spec.Spec(fields) = spec;
        fields#children

    /// 直下の子から name が一致する最初のノードを引く。
    def childNamed(name: String, spec: Spec): Option[Spec] =
        childrenOf(spec) |> List.findLeft(child -> nameOf(child) == name)

    /// 名前列 path で spec を上から辿った先のノード（途中で見つからなければ None）。
    def navigate(path: List[String], spec: Spec): Option[Spec] =
        match path {
            case Nil          => Some(spec)
            case name :: rest => childNamed(name, spec) |> Option.flatMap(child -> navigate(rest, child))
        }

    /// spec を名前列 path で辿った先のノードの直下で、name が prefix で始まる子の数を返す。
    /// 途中のノードが見つからなければ 0。ui.json のスロット宣言数を（UiWorld を組まずに）
    /// 数えてコード側の想定数と突き合わせるテスト seam。
    pub def countPrefixedChildren(path: List[String], prefix: String, spec: Spec): Int32 =
        match navigate(path, spec) {
            case None       => 0
            case Some(node) => childrenOf(node) |> List.count(child -> String.startsWith({prefix = prefix}, nameOf(child)))
        }
}
