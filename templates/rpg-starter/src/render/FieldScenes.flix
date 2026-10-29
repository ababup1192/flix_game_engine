// FieldScenes — まだ World から描けない見下ろしの場面（帰村）を、描き出し用に直に組む。
// 地図の格子と人・物の置き場をコードに書いてあるのは、その場面を遊べるようにするフェーズまでの置き場で、
// 遊べるようにした時にマップの Doc（assets/maps/*.map.json）へ移し、Starts から描く形に替える（各節の見出しに、どの場面か）。
// ここは仮の物（帰村を遊べるようにしたら消す）。中の関数を写さない — 新しい場面は Starts + View.frame / View.hud で描く。
// 村の地図と凡例は、もう Doc（assets/maps/village.map.json）と Tileset にある物を読む。
mod FieldScenes {
    use fge::{Render, Vec2}
    use Sheet.SheetId
    use FieldView.Facing
    use Autotile.Cell

    type alias Env = WindowView.Env

    // 場面の中の重なり順。
    def zGround(): Int32 = 0
    def zProp(): Int32 = 2
    def zPeople(): Int32 = 4
    def zWindow(): Int32 = 10

    def propOf(sheet: SheetId, sprite: String, frame: String, placeholder: String, size: Vec2.Vec2): Sheet.Part =
        Sheet.part(sheet, sprite, frame, placeholder, size)

    // ── 升目に置く（この仮の場面だけが使う） ──

    def cellAt(col: Float64, row: Float64): Vec2.Vec2 = { x = col * FieldView.tile(), y = row * FieldView.tile() }

    /// 文字の格子（1 文字 = 1 タイル・左上が (0, 0)）を、凡例の Cell で引いて敷く。
    /// 重ねる部品（Over）は z を 2 つずつ上げる（間の z + 1 に、地面へ落ちる影を差し込めるように）。
    /// 凡例に無い文字は色票の外の色の四角になる（書き損じを目に見せる）。
    def tiles(env: WindowView.Env, legend: Map[Char, Autotile.Cell], rows: List[String], z: Int32): List[Render.PlacedItem] =
        let grid = Autotile.gridOf(rows);
        grid |> Vector.toList |> List.zipWithIndex |> List.flatMap(rowEntry -> {
            let (r, row) = rowEntry;
            List.range(0, Vector.length(row)) |> List.flatMap(c -> {
                let at = cellAt(Int32.toFloat64(c), Int32.toFloat64(r));
                Autotile.cellPartsAt(env#res#sheets, legend, grid, c, r) |> List.zipWithIndex |> List.flatMap(layer -> {
                    let (i, part) = layer;
                    Sheet.drawTile(env#res#sheets, env#res#palette, env#t, { part = part, at = at, z = z + 2 * i })
                })
            })
        })

    /// 物を升目に置く（左上を合わせる）。
    def place(env: WindowView.Env, part: Sheet.Part, col: Float64, row: Float64, z: Int32): List[Render.PlacedItem] =
        Sheet.draw(env#res#sheets, env#res#palette, env#t, { part = part, at = cellAt(col, row), z = z })

    /// 人（rpg.chars.sprite.json の 1 人）を升目に置く。人の anchor は足元の中央なので、マスの下端の中央に合わせる。
    /// 歩きの 2 コマは時刻 t で選ぶ。placeholder は絵が無い時の仮の四角の色（人ごとに変えて、誰がどこにいるか見分ける）。
    def person(env: WindowView.Env, spec: { who = String, facing = Facing, placeholder = String },
                   col: Float64, row: Float64, z: Int32): List[Render.PlacedItem] =
        FieldView.personAt(env, spec, cellAt(col, row), z)

    /// 隊列（先頭から順に、同じ向きで 1 升ずつ後ろへ並ぶ）。後ろの人は前の人の 1 升ぶん逆向きに立つ。
    def party(env: WindowView.Env, members: List[{ who = String, placeholder = String }], facing: Facing,
                  col: Float64, row: Float64, z: Int32): List[Render.PlacedItem] =
        let (dc, dr) = match facing {
            case Facing.Down  => (0.0, -1.0)
            case Facing.Up    => (0.0, 1.0)
            case Facing.Left  => (1.0, 0.0)
            case Facing.Right => (-1.0, 0.0)
        };
        members |> List.zipWithIndex |> List.flatMap(entry -> {
            let (i, member) = entry;
            let k = Int32.toFloat64(i);
            person(env, { who = member#who, facing = facing, placeholder = member#placeholder },
                   col + dc * k, row + dr * k, z)
        })

    // ── 顔ぶれ（rpg.chars.sprite.json の絵の名前と、絵が無い時の仮の色） ──

    def hero(): { who = String, placeholder = String } = { who = "hero", placeholder = "fc12" }
    def miner(): { who = String, placeholder = String } = { who = "mina", placeholder = "fc27" }
    def toto(): { who = String, placeholder = String } = { who = "toto", placeholder = "fc14" }

    def fullParty(): List[{ who = String, placeholder = String }] = hero() :: miner() :: toto() :: Nil

    def npc(env: Env, who: String, placeholder: String, facing: Facing, col: Float64, row: Float64): List[Render.PlacedItem] =
        person(env, { who = who, facing = facing, placeholder = placeholder }, col, row, zPeople())

    // ── ルーネ村（帰村: 泉の湧いた村を遊べるようにしたら Starts から描く） ──

    /// 村の地図（マップの Doc の格子。読めなければ空）と凡例。
    def villageRows(env: Env): List[String] =
        Map.get("village", env#res#maps) |> Option.map(map -> MapDoc.rec(map)#rows) |> Option.getWithDefault(Nil)

    def villageLegend(): Map[Char, Cell] = Tileset.legendOf(Tileset.TilesetId.Village)

    /// 家の右と下の草へ落ちる影（凡例の組の決まりで）。
    def houseShadows(env: Env, rows: List[String]): List[Render.PlacedItem] =
        Tileset.shadowsOf(Tileset.TilesetId.Village)
            |> Option.map(spec -> Autotile.dropShadows(env#res#palette, { +rows = rows | spec }, zGround() + 1))
            |> Option.getWithDefault(Nil)

    /// 村の地図と泉と大きな木。full = 泉に水があるか。
    def villageGround(env: Env, full: Bool): List[Render.PlacedItem] =
        let spring = if (full) Sheet.cycling(SheetId.Town, "spring_full", 3.0, "fc21", { x = 32.0, y = 32.0 })
                     else propOf(SheetId.Town, "spring_dry", "idle", "fc18", { x = 32.0, y = 32.0 });
        List.flatten(
            tiles(env, villageLegend(), villageRows(env), zGround()) ::
            houseShadows(env, villageRows(env)) ::
            place(env, spring, 7.0, 6.0, zProp()) ::
            place(env, propOf(SheetId.Town, "big_tree", "idle", "fc0A", { x = 32.0, y = 32.0 }), 14.0, 0.0, zProp()) ::
            Nil)

    /// 依頼を果たして村へ帰った: 泉に水が戻り、村人が集まる。
    pub def clear(env: Env): List[Render.PlacedItem] =
        let rect = WindowView.grid({ col = 1, row = 22, cols = 30, rows = 7 });
        List.flatten(
            villageGround(env, true) ::
            party(env, fullParty(), Facing.Up, 7.5, 8.0, zPeople()) ::
            npc(env, "chief", "fc00", Facing.Down, 7.5, 5.0) ::
            npc(env, "woman", "fc25", Facing.Right, 6.0, 7.0) ::
            npc(env, "child", "fc29", Facing.Left, 9.0, 6.0) ::
            npc(env, "merchant", "fc1C", Facing.Left, 9.0, 8.0) ::
            npc(env, "smith", "fc07", Facing.Right, 5.0, 8.0) ::
            WindowView.message(env, rect,
                "いずみに みずが もどった！" :: "ルカたちは 300G を うけとった。" :: Nil, false, zWindow()) ::
            Nil)
}
