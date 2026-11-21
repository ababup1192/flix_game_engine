// MapView — 古びた紙のマップを HUD に描く（純粋）。中身（線・丸・名前の位置）は PaperMap が組み、ここは絵を貼るだけ。
//
// ── 絵の下限の 5 性質 ──
//   面に階調か質感 … 焼けて折り目のある紙の絵（map_paper）
//   主役が背景から分離 … 紙の下の 3D の場面を暗く沈め、紙だけを浮かせる
//   層が分かれている … 紙 → 階の名前と鉛筆の線 → 赤い丸 → 名前 → 今いる所の印、の順に重ねる
//   時間が流れている … 今いる所の印がゆっくり明滅する
//   形が物として読める … 鉛筆の線は少しはみ出して揺れ、丸は部屋ごとに違う描き癖で傾く（手描きの線）
// 絵は project.json の textures（assets/ui/map/）。名前と大きさの表は textures()。
mod MapView {
    use fge::{Color, DrawCmd, FontAtlas, GameEngine, GpuHandle, Hash01, Num, RawDraw, Render, TextDraw, Vec2}
    use fge::Render.Item

    /// 描くのに要る値。floor = 見ている階・here = 今いる階・you = 今いる所（紙の上）・floors = 表にある階の番号。
    pub type alias In = { t = Float64, sheet = PaperMap.Sheet, floors = List[Int32], here = Int32, you = Vec2.Vec2, atlas = FontAtlas }

    /// マップの絵の名前と、assets からのパスと大きさ（project.json の textures と同じ名前）。
    pub def textures(): List[(String, String, Int32, Int32)] =
        ("map_paper", "assets/ui/map/map_paper.png", 288, 208) ::
        ("floor_label_1f", "assets/ui/map/floor_label_1f.png", 48, 26) :: ("floor_label_2f", "assets/ui/map/floor_label_2f.png", 48, 26) ::
        ("floor_label_3f", "assets/ui/map/floor_label_3f.png", 48, 26) ::
        ("circle_1", "assets/ui/map/circle_1.png", 48, 32) :: ("circle_2", "assets/ui/map/circle_2.png", 48, 32) ::
        ("circle_3", "assets/ui/map/circle_3.png", 48, 32) :: ("circle_4", "assets/ui/map/circle_4.png", 48, 32) ::
        ("you_are_here", "assets/ui/map/you_are_here.png", 12, 12) ::
        ("pencil_line_h", "assets/ui/map/pencil_line_h.png", 64, 4) :: ("pencil_line_v", "assets/ui/map/pencil_line_v.png", 4, 64) :: Nil

    /// 絵の大きさ（画面なしの描き出しが Sprite の寸法を引く）。
    pub def textureInfoOf(name: String): Option[GameEngine.TextureInfo] =
        textures() |> List.find(e -> { let (n, _, _, _) = e; n == name })
            |> Option.map(e -> { let (_, _, w, h) = e; { id = GpuHandle.wrapTextureId(0), width = Int32.toFloat64(w), height = Int32.toFloat64(h) } })

    /// 鉛筆の色（灰黒）。
    def pencil(): Color = Color.rgb(0.2, 0.18, 0.16)

    /// 絵 1 枚を中心 center に、倍率 scale・傾き tilt（回転数）で置く。
    def spriteAt(texture: String, center: Vec2.Vec2, scale: Vec2.Vec2, tilt: Float64, alpha: Float64, z: Int32): Render.PlacedItem =
        { at = center, item = Item.Sprite({ texture = texture, tint = Color.rgb(1.0, 1.0, 1.0), alpha = alpha, scale = scale, rotation = tilt,
                                             centered = true, flipH = false, flipV = false, regionRect = None, zIndex = z,
                                             blend = DrawCmd.BlendMode.Normal, maskPolys = Nil, squashY = 1.0 }) }

    /// マップ 1 枚（奥から: 場面を沈める幕・紙・階の名前・線・丸・名前・今いる所）。
    pub def items(v: In): List[Render.PlacedItem] =
        let paper = PaperMap.paperAt();
        let size = PaperMap.paperSize();
        let center = { x = paper#x + size#x / 2.0, y = paper#y + size#y / 2.0 };
        List.flatten(
            ({ at = Vec2.zero(), item = RawDraw.box({ x = World.width(), y = World.height() }, Color.rgb(0.0, 0.0, 0.02), 0) |> Render.fade(0.7) } :: Nil)
            :: (spriteAt("map_paper", center, { x = 1.0, y = 1.0 }, 0.0, 1.0, 1) :: Nil)
            :: floorTitle(v)
            :: (v#sheet#walls |> List.zipWithIndex |> List.flatMap(e -> pencilLine(snd(e), fst(e), 0.95, 3)))
            :: (v#sheet#steps |> List.zipWithIndex |> List.flatMap(e -> pencilLine(snd(e), fst(e) + 500, 0.6, 3)))
            :: (v#sheet#marks |> List.flatMap(m -> mark(v, m)))
            :: you(v)
            :: Nil)

    /// 紙の上辺の真ん中に、見ている階の名前だけを鉛筆の字で書く（ほかの階の名前は書かない。切り替えは操作だけ）。
    /// 字は手描きの絵（floor_label_<n>f）。絵の無い階（4 階より上）はゲームの字形で「四階」のように書く。
    // WhyNot: 階ごとのタブを並べない — ボタンのように見えて、紙のマップらしさが無くなる（人の注文）。
    def floorTitle(v: In): List[Render.PlacedItem] =
        let paper = PaperMap.paperAt();
        let at = { x = paper#x + PaperMap.paperSize()#x / 2.0, y = paper#y + 20.0 };
        let label = "floor_label_${Int32.toString(v#sheet#floor)}f";
        if (Option.nonEmpty(textureInfoOf(label))) spriteAt(label, at, { x = 1.0, y = 1.0 }, 0.0, 1.0, 2) :: Nil
        else TextDraw.centeredAt({ text = PaperMap.floorName(v#sheet#floor), atlas = v#atlas, size = 10.0, color = pencil(), z = 2, center = at }) :: Nil

    /// 鉛筆の線 1 本: 線の絵（64 px）を伸ばさずに並べ（端数は並べた数で割って少しだけ伸ばす）、両端を 1 px ずつはみ出させ、
    /// 線ごとに少し揺らす。
    // WhyNot: 1 枚を線の長さまで伸ばさない — 絵のかすれの切れ目まで伸びて、長い壁が点線に見えた。
    def pencilLine(s: PaperMap.Seg, i: Int32, alpha: Float64, z: Int32): List[Render.PlacedItem] =
        let dx = s#b#x - s#a#x;
        let dy = s#b#y - s#a#y;
        let horizontal = Float64.abs(dx) >= Float64.abs(dy);
        let len = Float64.abs(if (horizontal) dx else dy) + 2.0;
        let n = Int32.max(1, Num.floorInt(len / 64.0 + 0.5));
        let piece = len / Int32.toFloat64(n);
        let wobble = (Hash01.at(i, 3) - 0.5) * 1.2;
        let start = if (horizontal) Float64.min(s#a#x, s#b#x) - 1.0 else Float64.min(s#a#y, s#b#y) - 1.0;
        List.range(0, n) |> List.map(k -> {
            let c = start + piece * (Int32.toFloat64(k) + 0.5);
            let tilt = (Hash01.at(i * 16 + k, 4) - 0.5) * 0.002;
            if (horizontal) spriteAt("pencil_line_h", { x = c, y = s#a#y + wobble }, { x = piece / 64.0, y = 1.0 }, tilt, alpha, z)
            else spriteAt("pencil_line_v", { x = s#a#x + wobble, y = c }, { x = 1.0, y = piece / 64.0 }, tilt, alpha, z)
        })

    /// 行った部屋: 手描きの丸と名前。
    def mark(v: In, m: PaperMap.Mark): List[Render.PlacedItem] =
        spriteAt("circle_${Int32.toString(m#circle)}", m#center, { x = 1.0, y = 1.0 }, m#tilt, 0.9, 4)
            :: TextDraw.centeredAt({ text = m#label, atlas = v#atlas, size = 10.0, color = pencil(), z = 5, center = m#center })
            :: Nil

    /// 今いる所の印（今いる階を見ている時だけ。ゆっくり明滅する）。
    def you(v: In): List[Render.PlacedItem] =
        if (v#sheet#floor != v#here) Nil
        else spriteAt("you_are_here", v#you, { x = 1.0, y = 1.0 }, 0.0, 0.65 + 0.35 * Num.sin(v#t * 3.0), 6) :: Nil
}
