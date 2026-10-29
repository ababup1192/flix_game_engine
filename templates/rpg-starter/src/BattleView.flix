// BattleView — 正面の戦いの画面: 背景の帯・敵・演出（world）と、仲間の HP / MP・コマンド・敵の一覧・伝言のウィンドウ（HUD）。
// 上に仲間のウィンドウ、その下に背景の帯（256 × 64）と敵（足元を 1 本の線にそろえる）、下にコマンドと敵の一覧か伝言。
// 何を出すか（今の Beat・ページ）は ViewBattle.battleIn が World から組む。
mod BattleView {
    use fge::{Rect2, Render, Vec2, ZStack}
    use Sheet.SheetId
    use ZOrder.{HudLayer, Layer}

    /// 敵 1 体の描き方: 部品・色違いのアトラス（無ければ元の色）・横の真ん中・足元を上げる高さ・描くか（点滅の消えるコマ・倒れた敵は偽）。
    pub type alias Foe = { part = Sheet.Part, recolor = Option[Sheet.Sheet], centerX = Float64, lift = Float64, shown = Bool }

    /// 仲間 1 人の欄（名前・HP・MP・倒れているか・眠っているか）。
    pub type alias Ally = { name = String, hp = Int32, mp = Int32, down = Bool, asleep = Bool }

    /// コマンドを選んでいる間のウィンドウ: 誰の・項目（字と選べるか）・カーソル・コマンドのカーソルが動くか・
    /// 右の一覧（呪文・道具・的を選んでいる間。None なら敵の名前と数）。
    pub type alias Command = { who = String, entries = List[(String, Bool)], cursor = Int32, active = Bool, side = Option[WindowView.ListBox] }

    /// 伝言のウィンドウ: 出している行（文字送りの途中まで）と、出し切ったか。
    pub type alias Message = { lines = List[String], done = Bool }

    /// 演出: 種類の絵の名前（battlefx）と、その絵の左上・進み具合（0..1）。
    pub type alias Fx = { sprite = String, at = Vec2.Vec2, t = Float64 }

    /// 描くのに要る値。backdrop = 背景の帯の絵の名前・shake = 背景をずらす px（仲間が叩かれた演出）・
    /// foeNames = 敵の一覧（名前と数・生きている物だけ）。
    pub type alias In = {
        backdrop = String,
        shake = Float64,
        foes = List[Foe],
        fx = List[Fx],
        members = List[Ally],
        foeNames = List[(String, Int32)],
        command = Option[Command],
        message = Option[Message]
    }

    /// 背景の帯の上端と、敵の足元の線（px）。
    def bandTop(): Float64 = 72.0

    pub def footY(): Float64 = 132.0

    /// 敵の左上（足元を footY − lift に、横を centerX にそろえる）。
    pub def foeTopLeft(env: WindowView.Env, foe: Foe): Vec2.Vec2 =
        let size = Sheet.sizeOf(sheetsFor(env, foe), foe#part);
        { x = Float64.floor(foe#centerX - size#x / 2.0), y = footY() - foe#lift - size#y }

    /// 敵の大きさ（px）。
    pub def foeSize(env: WindowView.Env, foe: Foe): Vec2.Vec2 = Sheet.sizeOf(sheetsFor(env, foe), foe#part)

    /// 色違いなら敵の絵のファイルだけ差し替えたアトラスの表。
    def sheetsFor(env: WindowView.Env, foe: Foe): Map[SheetId, Sheet.Sheet] =
        foe#recolor |> Option.map(sheet -> Map.insert(SheetId.Monsters, sheet, env#res#sheets)) |> Option.getWithDefault(env#res#sheets)

    // ── world ──

    pub def world(env: WindowView.Env, battle: In): List[(Layer, ZStack.Tree[Layer, Unit])] =
        let band = Sheet.draw(env#res#sheets, env#res#palette, env#t,
            { part = Sheet.part(SheetId.BattleFx, battle#backdrop, "idle", "fc2D", { x = 256.0, y = 64.0 }),
              at = { x = battle#shake, y = bandTop() }, z = 0 });
        let foes = battle#foes |> List.filter(f -> f#shown) |> List.flatMap(f ->
            Sheet.draw(sheetsFor(env, f), env#res#palette, env#t, { part = f#part, at = foeTopLeft(env, f), z = 0 }));
        let fx = battle#fx |> List.flatMap(fxItems(env));
        (Layer.Battle, ZStack.of(ZStack.leaf(band) :: ZStack.leaf(foes) :: ZStack.leaf(fx) :: Nil)) :: Nil

    /// 演出の絵（コマは進み具合で選ぶ）。
    def fxItems(env: WindowView.Env, fx: Fx): List[Render.PlacedItem] =
        let frames = Map.get(SheetId.BattleFx, env#res#sheets)
            |> Option.flatMap(sheet -> Map.get(fx#sprite, sheet#doc#sprites))
            |> Option.map(sp -> Map.keysOf(sp#frames) |> Set.toList) |> Option.getWithDefault(Nil);
        let count = Int32.max(1, List.length(frames));
        let at = Float64.floor(fx#t * Int32.toFloat64(count)) |> Float64.tryToInt32 |> Option.getWithDefault(0) |> Int32.min(count - 1);
        let frame = List.nth(at, frames) |> Option.getWithDefault("f0");
        Sheet.draw(env#res#sheets, env#res#palette, env#t,
            { part = Sheet.part(SheetId.BattleFx, fx#sprite, frame, "fc30", { x = 32.0, y = 32.0 }), at = fx#at, z = 0 })

    // ── HUD ──

    def statusRect(): Rect2.Rect2 = WindowView.grid({ col = 1, row = 1, cols = 30, rows = 7 })

    def commandRect(): Rect2.Rect2 = WindowView.grid({ col = 1, row = 18, cols = 11, rows = 11 })

    def foeListRect(): Rect2.Rect2 = WindowView.grid({ col = 12, row = 18, cols = 19, rows = 11 })

    def messageRect(): Rect2.Rect2 = WindowView.grid({ col = 1, row = 19, cols = 30, rows = 9 })

    /// 伝言のウィンドウの 1 行の幅（px）。
    pub def messageWidth(): Float64 = messageRect()#size#x - WindowView.padLeft() - WindowView.cell()

    pub def hud(env: WindowView.Env, battle: In): List[(HudLayer, ZStack.Tree[HudLayer, Unit])] =
        let command = battle#command |> Option.map(commandItems(env, battle)) |> Option.getWithDefault(Nil);
        let message = battle#message |> Option.map(m -> WindowView.message(env, messageRect(), m#lines, m#done, 0)) |> Option.getWithDefault(Nil);
        (HudLayer.Window, ZStack.of(ZStack.leaf(statusItems(env, battle#members)) :: ZStack.leaf(command) :: ZStack.leaf(message) :: Nil)) :: Nil

    /// 仲間の列の左端（px）。
    def memberLeftX(i: Int32): Float64 = statusRect()#position#x + 16.0 + Int32.toFloat64(i) * 78.0

    /// 仲間の列の真ん中（px。仲間への演出を置く横の位置）。
    pub def memberCenterX(i: Int32): Float64 = memberLeftX(i) + 23.0

    /// 名前の色: 倒れた人は赤・眠っている人は水色。
    def nameColorOf(m: Ally): String =
        if (m#down) "fc16" else if (m#asleep) "fc21" else "fc30"

    /// 仲間のウィンドウ（1 人 1 列: 名前・HP・MP。倒れた人の名前は赤・眠っている人は水色）。
    def statusItems(env: WindowView.Env, members: List[Ally]): List[Render.PlacedItem] =
        let rect = statusRect();
        let columns = members |> List.zipWithIndex |> List.flatMap(match (i, m) -> {
            let x = memberLeftX(i);
            let y = row -> WindowView.lineAt(rect, row)#y;
            WindowView.labelIn(env, nameColorOf(m), m#name, { x = x, y = y(0) }, 0) ::
            WindowView.labelIn(env, "fc31", "HP", { x = x, y = y(1) }, 0) ::
            WindowView.labelRight(env, "fc30", "${m#hp}", x + 46.0, y(1), 0) ::
            WindowView.labelIn(env, "fc31", "MP", { x = x, y = y(2) }, 0) ::
            WindowView.labelRight(env, "fc30", "${m#mp}", x + 46.0, y(2), 0) :: Nil
        });
        List.append(WindowView.frame(env, rect, 0), columns)

    /// コマンドのウィンドウ（上の縁に誰の）と、右の敵の一覧（名前と数）か、呪文・道具・的の一覧。
    def commandItems(env: WindowView.Env, battle: In, c: Command): List[Render.PlacedItem] =
        let commandBox = { title = c#who, cursor = c#cursor, active = c#active,
                           rows = c#entries |> List.map(match (text, open) -> { text = text, right = "", open = open }) };
        let foeNames = { title = "", cursor = 0, active = false, rows = battle#foeNames |> List.map(match (n, k) -> { text = n, right = "${k}", open = true }) };
        let rightItems = c#side |> Option.map(box -> WindowView.listWindow(env, foeListRect(), box, 0)) |> Option.getWithDefault(foeListItems(env, foeNames));
        List.append(WindowView.listWindow(env, commandRect(), commandBox, 0), rightItems)

    /// 敵の一覧（カーソルを出さない）。
    def foeListItems(env: WindowView.Env, box: WindowView.ListBox): List[Render.PlacedItem] =
        let rect = foeListRect();
        let right = rect#position#x + rect#size#x - WindowView.cell() - 2.0;
        let rows = box#rows |> List.zipWithIndex |> List.flatMap(match (i, row) -> {
            let at = WindowView.lineAt(rect, i);
            WindowView.label(env, row#text, { x = at#x - 8.0, y = at#y }, 0) ::
            WindowView.labelRight(env, "fc30", row#right, right, at#y, 0) :: Nil
        });
        List.append(WindowView.frame(env, rect, 0), rows)
}
