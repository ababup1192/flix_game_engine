// Sheet — 絵の部品の 1 ファイル（assets/rpg.<種類>.sprite.json）と、それから生成したアトラス。
// 部品を置く口（draw）はここだけにまとめ、絵がまだ無い・名前が無い時は目立つ仮の四角で描く。
mod Sheet {
    use fge::{PxSprite, PxSpriteAtlas, PxSpriteDoc, RawDraw, Render, Vec2}

    /// 絵の部品のファイルの種類（担当ごとに 1 ファイル）。
    pub enum SheetId with Eq, Order, ToString {
        case Town
        case WorldMap
        case Mine
        case Chars
        case Monsters
        case BattleFx
        case Ui
    }

    /// 1 ファイルぶん: 読んだ Doc・生成したアトラス・GPU で待ち合わせるテクスチャの名前と、画素から導いた鍵。
    /// WhyNot: 鍵をテクスチャの名前だけにしない — Doc や色票を保存し直して絵が変わっても、鍵が同じだと GPU に古い絵が残る。
    pub type alias Sheet = { texture = String, key = String, doc = PxSpriteDoc.Doc, baked = PxSpriteAtlas.Baked }

    pub def all(): List[SheetId] =
        SheetId.Town :: SheetId.WorldMap :: SheetId.Mine :: SheetId.Chars ::
        SheetId.Monsters :: SheetId.BattleFx :: SheetId.Ui :: Nil

    /// ファイル名の真ん中（rpg.<これ>.sprite.json）。
    def stemOf(id: SheetId): String = match id {
        case SheetId.Town     => "town"
        case SheetId.WorldMap => "world"
        case SheetId.Mine     => "mine"
        case SheetId.Chars    => "chars"
        case SheetId.Monsters => "monsters"
        case SheetId.BattleFx => "battlefx"
        case SheetId.Ui       => "ui"
    }

    pub def pathOf(id: SheetId): String = "assets/rpg.${stemOf(id)}.sprite.json"

    def textureOf(id: SheetId): String = "px_${stemOf(id)}"

    /// 読んだ Doc からアトラスを生成する（色票を差し替えた時も、これで作り直す）。
    pub def fromDoc(palette: Palette.Palette, id: SheetId, doc: PxSpriteDoc.Doc): Sheet =
        let baked = PxSpriteAtlas.bake(doc, Palette.resolve(palette));
        let h = baked#pixels |> Vector.foldLeft((acc, px) -> acc * 31 + px, 17);
        { texture = textureOf(id), key = "${textureOf(id)}:${Int32.toString(baked#side)}:${Int32.toString(h)}",
          doc = doc, baked = baked }

    /// 色違いの 1 体ぶんのアトラス: doc の sprite の絵だけを、色票の鍵を swaps で差し替えて生成する（テクスチャは px_foe_<name>）。
    /// WhyNot: ファイル全体を焼き直さない — 色違い 1 体ごとに 8 体ぶん（ボスの 96×80 も）の画素がテクスチャに入り、5 枚で 5 倍になる。
    pub def recolored(palette: Palette.Palette, name: String, swaps: Map[String, String], sprite: String, doc: PxSpriteDoc.Doc): Sheet =
        let only = { sprites = Map.get(sprite, doc#sprites) |> Option.map(sp -> Map#{sprite => sp}) |> Option.getWithDefault(Map.empty()) | doc };
        let baked = PxSpriteAtlas.bake(only, key -> Palette.resolve(palette, Map.getWithDefault(key, key, swaps)));
        let h = baked#pixels |> Vector.foldLeft((acc, px) -> acc * 31 + px, 17);
        let texture = "px_foe_${name}";
        { texture = texture, key = "${texture}:${Int32.toString(baked#side)}:${Int32.toString(h)}", doc = only, baked = baked }

    /// どのコマを出すか。
    pub enum FramePick with Eq {
        /// 名前で 1 コマ。
        case Named(String)
        /// 名前の順に並べたコマを、1 秒に fps コマで回す（コマが 1 枚なら止まったまま）。
        case Cycle(Float64)
    }

    /// 置く部品 1 つ: どのファイルのどの絵の、どのコマか。placeholder は絵が無い時の仮の四角の色（色票のキー）と大きさ。
    pub type alias Part = { sheet = SheetId, sprite = String, pick = FramePick, placeholder = String, size = Vec2.Vec2 }

    /// 名前で 1 コマを選ぶ部品の近道。
    pub def part(sheet: SheetId, sprite: String, frame: String, placeholder: String, size: Vec2.Vec2): Part =
        { sheet = sheet, sprite = sprite, pick = FramePick.Named(frame), placeholder = placeholder, size = size }

    /// コマを回す部品の近道。
    pub def cycling(sheet: SheetId, sprite: String, fps: Float64, placeholder: String, size: Vec2.Vec2): Part =
        { sheet = sheet, sprite = sprite, pick = FramePick.Cycle(fps), placeholder = placeholder, size = size }

    /// 時刻 t に出すコマの名前。名前で選んだコマが無い時は先頭のコマへ落とす
    /// （他の担当がコマ名を変えても、絵がある限り絵で出す）。
    pub def frameAt(doc: PxSpriteDoc.Doc, sprite: String, pick: FramePick, t: Float64): Option[String] =
        let names = Map.get(sprite, doc#sprites)
            |> Option.map(sp -> Map.keysOf(sp#frames) |> Set.toList)
            |> Option.getWithDefault(Nil);
        match pick {
            case FramePick.Named(name) =>
                if (List.memberOf(name, names)) Some(name) else List.head(names)
            case FramePick.Cycle(fps)  => cycleOf(names, fps, t)
        }

    def cycleOf(names: List[String], fps: Float64, t: Float64): Option[String] =
        let count = List.length(names);
        if (count == 0) None
        else {
            let step = Float64.floor(t * fps) |> Float64.tryToInt32 |> Option.getWithDefault(0);
            List.nth(Int32.modulo(step, count), names)
        }

    /// 部品の絵の左上を at に置く（anchor は見ない）。絵があればアトラスから 1 枚、無ければ仮の四角
    /// （placeholder の色の面に色票の外の色の縁）。WhyNot: 仮の四角を黙って透明にしない — 欠けた部品が画面から消え、
    /// レイアウトの目視で気づけなくなる。
    pub def draw(sheets: Map[SheetId, Sheet], palette: Palette.Palette, t: Float64,
                 placed: { part = Part, at = Vec2.Vec2, z = Int32 }): List[Render.PlacedItem] =
        drawOr(sheets, t, placed, Placement.TopLeft, placeholderBox(palette, true, placed#part, placed#at, placed#z))

    /// 部品の anchor（絵ごとに決めた握る所: 人の足元・背の高い水晶の足元のマス）を at に置く。
    /// 仮の四角は at から右下へ描く。
    pub def drawAnchored(sheets: Map[SheetId, Sheet], palette: Palette.Palette, t: Float64,
                         placed: { part = Part, at = Vec2.Vec2, z = Int32 }): List[Render.PlacedItem] =
        drawOr(sheets, t, placed, Placement.Anchor, placeholderBox(palette, true, placed#part, placed#at, placed#z))

    /// draw のタイル版。仮の四角に縁を付けない。WhyNot: 縁を付けると地図が仮色の格子線で埋まり、
    /// 置き場所の目視の邪魔になる（タイルが仮かどうかは面の平らさで分かる）。
    pub def drawTile(sheets: Map[SheetId, Sheet], palette: Palette.Palette, t: Float64,
                     placed: { part = Part, at = Vec2.Vec2, z = Int32 }): List[Render.PlacedItem] =
        drawOr(sheets, t, placed, Placement.TopLeft, placeholderBox(palette, false, placed#part, placed#at, placed#z))

    /// at が絵のどこに当たるか。
    enum Placement { case TopLeft case Anchor }

    def drawOr(sheets: Map[SheetId, Sheet], t: Float64, placed: { part = Part, at = Vec2.Vec2, z = Int32 },
               placement: Placement, placeholder: List[Render.PlacedItem]): List[Render.PlacedItem] =
        let p = placed#part;
        let drawn = Map.get(p#sheet, sheets) |> Option.flatMap(sheet ->
            frameAt(sheet#doc, p#sprite, p#pick, t) |> Option.map(frame -> match placement {
                case Placement.TopLeft =>
                    PxSprite.drawQuadTopLeft({ doc = sheet#doc, baked = sheet#baked, texture = sheet#texture,
                                               sprite = p#sprite, frame = frame, at = placed#at, scale = 1, z = placed#z })
                case Placement.Anchor =>
                    PxSprite.drawQuad(sheet#doc, sheet#baked, sheet#texture, p#sprite, frame, placed#at, false, 1, placed#z)
            }))
            |> Option.getWithDefault(Nil);
        if (List.isEmpty(drawn)) placeholder else drawn

    def placeholderBox(palette: Palette.Palette, edged: Bool, p: Part, at: Vec2.Vec2, z: Int32): List[Render.PlacedItem] =
        let face = RawDraw.box(p#size, Palette.resolve(palette, p#placeholder), z);
        let shown = if (edged) Render.outline(Palette.missing(), 1.0, face) else face;
        Render.at(at, shown) :: Nil

    /// その絵のコマの大きさ（px）。絵が無ければ仮の四角の大きさ。
    pub def sizeOf(sheets: Map[SheetId, Sheet], p: Part): Vec2.Vec2 =
        Map.get(p#sheet, sheets)
            |> Option.flatMap(sheet ->
                frameAt(sheet#doc, p#sprite, p#pick, 0.0) |> Option.flatMap(frame ->
                    PxSpriteDoc.gridSizeOf(sheet#doc, p#sprite, frame)))
            |> Option.map(grid -> ({ x = Int32.toFloat64(grid#cols), y = Int32.toFloat64(grid#rows) }: Vec2.Vec2))
            |> Option.getWithDefault(p#size)
}
