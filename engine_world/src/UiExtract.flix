// UiExtract — 配置と表示可否が決まった UI を、描画部が食べられる絵の列に変換する。
// レイアウト結果をそのまま画面に出せる形に落とすので、UI の見た目づくりと描画を切り離せる。
// 注意: 画面固定の HUD 想定でカメラの拡大縮小は掛けない。文字の実寸は engine の純粋関数を使う。

pub mod UiExtract {

    /// text コンポーネントの内在サイズ（measure）を求める。
    /// atlasOf は font 名→FontAtlas（呼び側が Game.getFontAtlas 等で組む）。
    /// atlasOf が副作用を持つ場合はその effect が伝播する。
    pub def measureTexts(texts: Map[EntityId, UiWidget.TextComp], atlasOf: String -> FontAtlas \ ef): Map[EntityId, Vec2.Vec2] \ ef =
        texts |> Map.map(comp -> Text.measure(
            Text.make(comp#text, atlasOf(comp#font), comp#fontSize)
                |> Text.setWrapWidth(intrinsicWrapOf(comp))))

    /// 内在サイズの計測に効かせられる折り返しは数値（px）だけ。auto は「自分の矩形の幅」で、
    /// その矩形はこの計測の結果から決まるので、計測に混ぜると循環する。
    /// pub なのは UiDoc（Flex 経路）が同じ計測規則で内在サイズを出すため。
    pub def intrinsicWrapOf(comp: UiWidget.TextComp): Option[Float64] =
        match comp#wrap {
            case UiWidget.TextWrap.WrapPx(w) => Some(w)
            case _                           => None
        }

    /// UI entity を PlacedItem（置き場所つきの描画物）列へ射影する。可視 entity のみ・矩形が確定したもののみ。
    /// 並びは (zIndex, 階層深さ, order, id) で安定ソートする（背面から前面へ）。
    /// box → 単色塗り（alpha 反映。skin 指定時は九分割スキン）、text → 着色テキスト、sprite → スプライト。
    /// 文字実寸は `atlasOf`、sprite のセル分割（frame→regionRect）のテクスチャ寸法は `textureInfoOf`
    /// で引く。どちらも呼び側が注入するので、画面なしのテストでは純粋関数を渡せる。
    pub def extract(ui: UiStore.UiWorld, rects: Map[EntityId, Rect2.Rect2],
                    vis: Map[EntityId, Bool], atlasOf: String -> FontAtlas \ ef,
                    textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef): List[Render.PlacedItem] \ ef =
        let hoveredId = hoveredIdOf(ui);
        // box は 1 entity が複数枚（九分割スキン）になり得るので、rect 左上からのずれを entry に持たせる。
        let boxEntries = ui#boxes |> Map.foldLeftWithKey((acc, id, box) ->
            match Map.get(id, rects) {
                case None       => acc
                case Some(rect) =>
                    let placed = boxPlacedItems(hoverBox(hoverFor(ui, hoveredId, id), box), rect#size, textureInfoOf);
                    List.append(placed |> List.map(p -> (id, box#zIndex, p#at, p#item)), acc)
            }, Nil);
        let spriteEntries = ui#sprites |> Map.foldLeftWithKey((acc, id, sprite) ->
            (id, sprite#zIndex, Vec2.zero(), spriteItem(hoverSprite(hoverFor(ui, hoveredId, id), sprite), textureInfoOf)) :: acc, Nil);
        // text は wrap="auto" / fit が自分のレイアウト矩形を基準にするため、rect を引いてから組む
        // （rect が無い text はどのみち後段の filterMap で落ちる）。
        let textEntries = Map.foldLeftWithKey((acc, id, comp) ->
            match Map.get(id, rects) {
                case None       => acc
                case Some(rect) =>
                    (id, comp#zIndex, Vec2.zero(),
                     textItem(hoverText(hoverFor(ui, hoveredId, id), comp), rect#size, atlasOf)) :: acc
            },
            (Nil : List[(EntityId, Int32, Vec2.Vec2, Render.Item)]), ui#texts);
        List.append(boxEntries, List.append(spriteEntries, textEntries))
            |> List.filter(entry -> {let (id, _z, _off, _item) = entry; Option.getWithDefault(true, Map.get(id, vis))})
            |> List.filterMap(entry -> {
                let (id, z, off, item) = entry;
                Map.get(id, rects) |> Option.map(rect -> (id, z, Vec2.add(rect#position, off), item))
            })
            |> List.map(entry -> {let (id, z, _pos, _item) = entry; (sortKeyOf(id, z, ui), entry)})
            |> List.sortBy(fst)
            |> List.map(pair -> {let (_id, _z, pos, item) = snd(pair); { at = pos, item = item }})

    /// hovered 名前パスに対応する entity（未設定・パス消滅は None）。
    def hoveredIdOf(ui: UiStore.UiWorld): Option[EntityId] =
        ui#hovered |> Option.flatMap(path -> UiStore.idOf(path, ui))

    /// id が hover 中なら宣言された上書き（hovers）を返す。hover 宣言の無い entity は None。
    def hoverFor(ui: UiStore.UiWorld, hoveredId: Option[EntityId], id: EntityId): Option[UiWidget.HoverStyle] =
        if (hoveredId == Some(id)) Map.get(id, ui#hovers) else None

    def hoverBox(h: Option[UiWidget.HoverStyle], comp: UiWidget.BoxComp): UiWidget.BoxComp =
        match h {
            case None     => comp
            case Some(hs) => { color = Option.getWithDefault(comp#color, hs#color),
                               borderColor = Option.getWithDefault(comp#borderColor, hs#borderColor),
                               alpha = Option.getWithDefault(comp#alpha, hs#alpha) | comp }
        }

    def hoverText(h: Option[UiWidget.HoverStyle], comp: UiWidget.TextComp): UiWidget.TextComp =
        match h {
            case None     => comp
            case Some(hs) => { tint = Option.getWithDefault(comp#tint, hs#tint) | comp }
        }

    /// sprite に効く hover は tint のみ（alpha は SpriteComp が持たない — 宣言しても効かない
    /// のではなく、そもそも sprite の宣言語彙に無い）。
    def hoverSprite(h: Option[UiWidget.HoverStyle], comp: UiWidget.SpriteComp): UiWidget.SpriteComp =
        match h {
            case None     => comp
            case Some(hs) => { tint = Option.getWithDefault(comp#tint, hs#tint) | comp }
        }

    /// poly に効く hover は color / alpha。
    def hoverPoly(h: Option[UiWidget.HoverStyle], comp: UiWidget.PolyComp): UiWidget.PolyComp =
        match h {
            case None     => comp
            case Some(hs) => { color = Option.getWithDefault(comp#color, hs#color),
                               alpha = Option.getWithDefault(comp#alpha, hs#alpha) | comp }
        }

    def hoverShape(h: Option[UiWidget.HoverStyle], comp: UiShape.ShapeComp): UiShape.ShapeComp =
        match h {
            case None     => comp
            case Some(hs) => { color = Option.getWithDefault(comp#color, hs#color),
                               borderColor = match hs#borderColor {
                                   case Some(c) => Some(c)
                                   case None    => comp#borderColor
                               },
                               alpha = Option.getWithDefault(comp#alpha, hs#alpha) | comp }
        }

    /// poly entity を (id, rect 左上, ワールド座標へ移した PolyComp) 列へ射影する。可視かつ rect 確定のみ。
    /// PolyComp#polys の各サブポリ頂点はレイアウト矩形左上を原点とするローカル design px。ここで rect
    /// 左上を全頂点へ足し、design 空間の絶対座標にした polys を持つ PolyComp を返す（tuple の Vec2 は
    /// 適用した左上そのもの）。
    /// 並びは extract と同じ (zIndex, 階層深さ, order, id)。PolygonRenderCmd への最終変換
    /// （layer zIndex 加算・engine 型への詰め替え）は UiRender が行い、ここは engine 型へ依存しない。
    pub def extractPolys(ui: UiStore.UiWorld, rects: Map[EntityId, Rect2.Rect2],
                         vis: Map[EntityId, Bool]): List[(EntityId, Vec2.Vec2, UiWidget.PolyComp)] =
        let hoveredId = hoveredIdOf(ui);
        ui#polys
            |> Map.toList
            |> List.filter(entry -> {let (id, _poly) = entry; Option.getWithDefault(true, Map.get(id, vis))})
            |> List.filterMap(entry -> {
                let (id, poly) = entry;
                Map.get(id, rects) |> Option.map(rect ->
                    (id, rect#position, offsetPoly(hoverPoly(hoverFor(ui, hoveredId, id), poly), rect#position)))
            })
            |> List.map(entry -> {let (id, _pos, poly) = entry; (sortKeyOf(id, poly#zIndex, ui), entry)})
            |> List.sortBy(fst)
            |> List.map(snd)

    /// shape entity を PlacedItem 列へ射影する。可視かつ rect 確定のみ。
    /// 並びは extract と同じ (zIndex, 階層深さ, order, id)。幾何は UiShape.placedItems に委譲する
    /// （UiDoc の Flex 経路と同じ関数 — 同じ JSON の図形が経路によらず同じ絵になる）。
    pub def extractShapes(ui: UiStore.UiWorld, rects: Map[EntityId, Rect2.Rect2],
                          vis: Map[EntityId, Bool]): List[Render.PlacedItem] =
        let hoveredId = hoveredIdOf(ui);
        ui#shapes
            |> Map.toList
            |> List.filter(entry -> {let (id, _s) = entry; Option.getWithDefault(true, Map.get(id, vis))})
            |> List.filterMap(entry -> {
                let (id, s) = entry;
                Map.get(id, rects) |> Option.map(rect -> (id, s, rect))
            })
            |> List.map(entry -> {let (id, s, _rect) = entry; (sortKeyOf(id, s#zIndex, ui), entry)})
            |> List.sortBy(fst)
            |> List.flatMap(pair -> {let (id, s, rect) = snd(pair); UiShape.placedItems(hoverShape(hoverFor(ui, hoveredId, id), s), rect)})

    /// PolyComp の全サブポリの各頂点にレイアウト矩形左上 origin を足し、ローカル座標を design 空間の
    /// 絶対座標へ移す。
    def offsetPoly(poly: UiWidget.PolyComp, origin: Vec2.Vec2): UiWidget.PolyComp =
        {polys = poly#polys |> List.map(sub ->
            sub |> List.map(p -> ({x = p#x + origin#x, y = p#y + origin#y}: Vec2.Vec2))) | poly}

    /// box の Item。BoxComp の枠・角丸を BoxStyle へ写す（stripe 系は UI では未使用）。
    /// borderWidth>0 のときだけ borderAlpha=1.0 にして枠を有効化する。
    /// pub なのは UiDoc（Flex 経路）が同じ box 意味論で描くため — BoxComp→Item 変換の唯一の実装。
    pub def boxItem(box: UiWidget.BoxComp, size: Vec2.Vec2): Render.Item =
        // stripe・市松は defaultStyle と同じ無効値のまま。
        let style = DrawCmd.styleFromParts(
            box#cornerRadius, box#borderWidth, box#borderColor,
            if (box#borderWidth > 0.0) 1.0 else 0.0,
            box#borderColor, 0.0, 0.0, 0.0, 0,
            box#borderColor, 0.0, 0.0);
        Render.Item.Box({size = size, color = box#color, alpha = box#alpha, rotation = 0.0,
                         style = Some(style), zIndex = box#zIndex,
                         blend = DrawCmd.BlendMode.Normal})

    /// box の PlacedItem 列（`at` は箱の左上からのずれ — 置き場所は呼び手が足す）。
    /// skin が無ければ従来の Box 1 枚。skin があればテクスチャを九分割した Sprite 群にする。
    /// skin 名のテクスチャが引けないときは従来の Box へ静かに落とす（fail-open — パネルは壊れない）。
    /// pub なのは UiDoc（Flex 経路）と extract（UiStore 経路）が同じ box 意味論で描くため —
    /// BoxComp→PlacedItem 変換の唯一の実装。
    pub def boxPlacedItems(box: UiWidget.BoxComp, size: Vec2.Vec2,
                           textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef): List[Render.PlacedItem] \ ef =
        match box#skin {
            case None       => plainBox(box, size)
            case Some(name) => match textureInfoOf(name) {
                case None       => plainBox(box, size)
                case Some(info) => nineSlice(box, name, info, size)
            }
        }

    def plainBox(box: UiWidget.BoxComp, size: Vec2.Vec2): List[Render.PlacedItem] =
        ({ at = Vec2.zero(), item = boxItem(box, size) }) :: Nil

    /// 九分割スキン: テクスチャを角の厚み c（テクスチャ px、既定 短辺/3）で 3×3 に割り、
    /// 角 4 枚は等倍のまま、辺 4 枚と中 1 枚は箱のサイズまで伸ばす。箱が角 2 つ分より
    /// 小さいときだけ角も半分サイズまで縮める（裏返って重なる絵を作らない）。
    /// 幅か高さが 0 以下の矩形（角の厚みちょうどのテクスチャ等）は出さない。
    def nineSlice(box: UiWidget.BoxComp, texture: String, info: GameEngine.TextureInfo,
                  size: Vec2.Vec2): List[Render.PlacedItem] =
        let c = Option.getWithDefault(Float64.min(info#width, info#height) / 3.0, box#skinCorner);
        let cw = Float64.min(c, size#x / 2.0);
        let ch = Float64.min(c, size#y / 2.0);
        // 各帯 = (src 始点, src 長, dst 始点, dst 長)。cols × rows の 9 交差が九分割。
        let cols = (0.0, c, 0.0, cw)
                :: (c, info#width - c * 2.0, cw, size#x - cw * 2.0)
                :: (info#width - c, c, size#x - cw, cw) :: Nil;
        let rows = (0.0, c, 0.0, ch)
                :: (c, info#height - c * 2.0, ch, size#y - ch * 2.0)
                :: (info#height - c, c, size#y - ch, ch) :: Nil;
        cols |> List.flatMap(col -> rows |> List.filterMap(row -> {
            let (sx, sw, dx, dw) = col;
            let (sy, sh, dy, dh) = row;
            if (sw <= 0.0 or sh <= 0.0 or dw <= 0.0 or dh <= 0.0) None
            else Some({ at = ({ x = dx, y = dy }: Vec2.Vec2),
                        item = slicePiece(box, texture, info,
                                          { position = { x = sx, y = sy }, size = { x = sw, y = sh } },
                                          { x = dw, y = dh }) })
        }))

    /// 九分割の 1 枚。レンダラは quad を「テクスチャ全体サイズ × scale」で張る（regionRect は
    /// UV だけ）ので、置き先サイズ dst になる scale = dst / テクスチャ全体サイズ を渡す。
    def slicePiece(box: UiWidget.BoxComp, texture: String, info: GameEngine.TextureInfo,
                   src: Rect2.Rect2, dst: Vec2.Vec2): Render.Item =
        Render.Item.Sprite({
            texture = texture, tint = { r = 1.0, g = 1.0, b = 1.0 }, alpha = box#alpha,
            scale = { x = dst#x / info#width, y = dst#y / info#height },
            rotation = 0.0, centered = false, flipH = false, flipV = false,
            regionRect = Some(src), zIndex = box#zIndex, blend = DrawCmd.BlendMode.Normal,
            maskPolys = Nil })

    /// text の Item。atlasOf で font 名から FontAtlas を引き、wrap 宣言を実際の折り返し幅へ
    /// 解き、fit なら矩形の縦に収まる fontSize まで縮めてから組む。
    /// pub なのは UiDoc（Flex 経路）が同じ text 意味論で描くため — TextComp→Item 変換の唯一の実装。
    pub def textItem(comp: UiWidget.TextComp, rectSize: Vec2.Vec2,
                     atlasOf: String -> FontAtlas \ ef): Render.Item \ ef =
        let atlas = atlasOf(comp#font);
        let wrapW = resolvedWrapOf(comp, rectSize#x);
        let size = fittedFontSize(comp, atlas, wrapW, rectSize#y);
        match wrapW {
            case None    => Render.textTinted(comp#text, atlas, size, comp#tint, comp#zIndex)
            case Some(w) => Render.textWrapped(comp#text, atlas,
                                { fontSize = size, wrapWidth = w, tint = comp#tint, zIndex = comp#zIndex })
        }

    /// wrap 宣言 → 実際の折り返し幅（px）。auto は自分のレイアウト矩形の幅を使う。
    pub def resolvedWrapOf(comp: UiWidget.TextComp, rectWidth: Float64): Option[Float64] =
        match comp#wrap {
            case UiWidget.TextWrap.WrapOff   => None
            case UiWidget.TextWrap.WrapAuto  => Some(rectWidth)
            case UiWidget.TextWrap.WrapPx(w) => Some(w)
        }

    /// fit 適用後の fontSize。折った後の縦が rectHeight に収まるまで step 刻みで下げ、
    /// minSize で打ち切る — 無限に縮めないのは、読めない字ははみ出しと別種の事故のため。
    pub def fittedFontSize(comp: UiWidget.TextComp, atlas: FontAtlas,
                           wrapW: Option[Float64], rectHeight: Float64): Float64 =
        match comp#fit {
            case None      => comp#fontSize
            case Some(fit) =>
                if (fit#step <= 0.0) comp#fontSize
                else shrinkToFit(comp#text, atlas, wrapW, rectHeight, fit, comp#fontSize)
        }

    /// 収まるか下限に達するまで fontSize を fit#step ずつ下げる。
    def shrinkToFit(content: String, atlas: FontAtlas, wrapW: Option[Float64],
                    rectHeight: Float64, fit: UiWidget.TextFit, size: Float64): Float64 =
        let dims = Text.measure(Text.make(content, atlas, size) |> Text.setWrapWidth(wrapW));
        if (dims#y <= rectHeight or size - fit#step < fit#minSize) size
        else shrinkToFit(content, atlas, wrapW, rectHeight, fit, size - fit#step)

    /// sprite の Item。左上原点（centered=false）でレイアウト矩形の位置に合わせる。
    /// regionRect を持たず格子分割（hframes*vframes>1）があるときは frame からセル矩形を導く
    /// （テクスチャ寸法は `textureInfoOf` で引く）。
    /// pub なのは UiDoc（Flex 経路）が同じ sprite 意味論で描くため — 経路で絵が変わらない契約。
    pub def spriteItem(sprite: UiWidget.SpriteComp,
                       textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef): Render.Item \ ef =
        let regionOpt = resolveRegion(sprite, textureInfoOf);
        Render.Item.Sprite({texture = sprite#texture, tint = sprite#tint, alpha = 1.0,
                                  scale = regionAdjustedScale(sprite, regionOpt, textureInfoOf), rotation = 0.0, centered = false,
                                  flipH = sprite#flipH, flipV = sprite#flipV,
                                  regionRect = regionOpt, zIndex = sprite#zIndex,
                                  blend = DrawCmd.BlendMode.Normal, maskPolys = Nil})

    /// region 使用時の描画 scale 補正。レンダラは quad を「テクスチャ全体サイズ × scale」で張るため、
    /// region（セル）描画では scale に regionSize/texSize を掛けて quad をセルサイズ × scale にする
    /// （engine `spriteToDrawable` の drawScale と同じ補正。`Render.drawWith` は UV のみ計算し
    /// scale を素通しするので、ここで織り込まないとアトラス全体サイズで巨大描画される）。
    /// region なし・テクスチャ未登録のときは無補正。
    def regionAdjustedScale(sprite: UiWidget.SpriteComp, regionOpt: Option[Rect2.Rect2],
                            textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef): Vec2.Vec2 \ ef =
        match regionOpt {
            case None       => sprite#scale
            case Some(rect) => match textureInfoOf(sprite#texture) {
                case None       => sprite#scale
                case Some(info) =>
                    {x = sprite#scale#x * rect#size#x / info#width,
                     y = sprite#scale#y * rect#size#y / info#height}
            }
        }

    /// 表示セルの切り出し矩形を求める。regionRect が明示されていればそれを使う。
    /// 無く格子分割がある場合はテクスチャ寸法を引き、frame をセルへ写す（engine Sprite.computeUv と
    /// 同じ規則: cellW=texW/hframes, cellH=texH/vframes, col=frame mod hframes, row=frame/hframes）。
    /// テクスチャ未登録・分割なしのときはテクスチャ全体（None）。
    def resolveRegion(sprite: UiWidget.SpriteComp,
                      textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef): Option[Rect2.Rect2] \ ef =
        if (sprite#hframes * sprite#vframes > 1 and Option.isEmpty(sprite#regionRect))
            match textureInfoOf(sprite#texture) {
                case None       => None
                case Some(info) => Some(frameRect(info#width, info#height, sprite#hframes, sprite#vframes, sprite#frame))
            }
        else sprite#regionRect

    /// テクスチャ全体を hframes×vframes に等分し、frame 番目のセル矩形（左上原点・px）を返す。
    def frameRect(texWidth: Float64, texHeight: Float64, hframes: Int32, vframes: Int32, frame: Int32): Rect2.Rect2 =
        let cellWidth  = texWidth  / Int32.toFloat64(hframes);
        let cellHeight = texHeight / Int32.toFloat64(vframes);
        let col = Int32.modulo(frame, hframes);
        let row = frame / hframes;
        {position = {x = Int32.toFloat64(col) * cellWidth, y = Int32.toFloat64(row) * cellHeight},
         size = {x = cellWidth, y = cellHeight}}

    /// 描画の並びのキー（背面から前面へ: zIndex, 階層深さ, order, id）。
    /// 末尾の id は entity ごとに一意なので、同じキーになる 2 つは存在しない。
    def sortKeyOf(id: EntityId, z: Int32, ui: UiStore.UiWorld): (Int32, Int32, Int32, EntityId) =
        (z, UiHierarchy.depthOf(id, ui#parents), orderOf(id, ui), id)

    /// entity の兄弟内並び順（未登録は 0）。
    def orderOf(id: EntityId, ui: UiStore.UiWorld): Int32 =
        Option.getWithDefault(0, Map.get(id, ui#order))
}
