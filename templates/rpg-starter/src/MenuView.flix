// MenuView — フィールドのメニューの絵（HUD）。配置は gallery/item.png: 左上に項目（2 列 × 3 行）・右に一覧・
// 左の中ほどに誰を選ぶ小さいウィンドウ・下につよさ。どのウィンドウを出すかは ViewMenu.menuIn がページから決める。
mod MenuView {
    use fge::{Rect2, Render, Vec2, ZStack}
    use ZOrder.HudLayer

    /// つよさのウィンドウ: 名前・レベル（見出しと値）・左の列（HP・MP・ぶき・よろい）・右の列（ちから・すばやさ・みのまもり・ゴールド）。
    pub type alias StatusBox = { name = String, level = (String, String), left = List[(String, String)], right = List[(String, String)] }

    /// 描くのに要る値。root = 項目（字と選べるか）・rootCursor・rootActive = カーソルが Root にあるか、
    /// picker = 誰を・どこを選ぶ小さいウィンドウ・list = 右の一覧・status = 下のつよさ。
    pub type alias In = {
        root = List[(String, Bool)],
        rootCursor = Int32,
        rootActive = Bool,
        picker = Option[WindowView.ListBox],
        list = Option[WindowView.ListBox],
        status = Option[StatusBox]
    }

    def rootRect(): Rect2.Rect2 = WindowView.grid({ col = 1, row = 1, cols = 15, rows = 7 })

    def listRect(n: Int32): Rect2.Rect2 = WindowView.grid({ col = 16, row = 2, cols = 15, rows = WindowView.rowsFor(Int32.max(n, 4)) })

    def pickerRect(n: Int32): Rect2.Rect2 = WindowView.grid({ col = 1, row = 9, cols = 9, rows = WindowView.rowsFor(n) })

    def statusRect(): Rect2.Rect2 = WindowView.grid({ col = 1, row = 18, cols = 30, rows = 11 })

    /// Root の 2 列目の字の左までの幅（px）。
    def columnWidth(): Float64 = 56.0

    /// メニューのウィンドウ（奥から: 項目・一覧・選ぶ小さいウィンドウ・つよさ）。
    pub def tree(env: WindowView.Env, menu: In): ZStack.Tree[HudLayer, Unit] =
        let list = menu#list |> Option.map(box -> WindowView.listWindow(env, listRect(List.length(box#rows)), box, 0)) |> Option.getWithDefault(Nil);
        let picker = menu#picker |> Option.map(box -> WindowView.listWindow(env, pickerRect(List.length(box#rows)), box, 0)) |> Option.getWithDefault(Nil);
        let status = menu#status |> Option.map(statusItems(env)) |> Option.getWithDefault(Nil);
        ZStack.of(ZStack.leaf(rootItems(env, menu)) :: ZStack.leaf(list) :: ZStack.leaf(picker) :: ZStack.leaf(status) :: Nil)

    /// 項目のウィンドウ（2 列。選べない項目は灰色。カーソルが他のページにある間は止まった ▶）。
    def rootItems(env: WindowView.Env, menu: In): List[Render.PlacedItem] =
        let rect = rootRect();
        let posOf = i -> {
            let base = WindowView.lineAt(rect, i / 2);
            ({ x = base#x + Int32.toFloat64(Int32.modulo(i, 2)) * columnWidth(), y = base#y }: Vec2.Vec2)
        };
        let texts = menu#root |> List.zipWithIndex |> List.map(match (i, (text, open)) ->
            WindowView.labelIn(env, if (open) "fc30" else "fc00", text, posOf(i), 0));
        let pointer = if (menu#rootActive) WindowView.cursor(env, posOf(menu#rootCursor), 0)
                      else WindowView.cursorStill(env, posOf(menu#rootCursor), 0);
        List.flatten(WindowView.frame(env, rect, 0) :: texts :: pointer :: Nil)

    /// つよさのウィンドウ（見出しは水色・値は白）。
    def statusItems(env: WindowView.Env, status: StatusBox): List[Render.PlacedItem] =
        let rect = statusRect();
        let head = WindowView.lineAt(rect, 0);
        let column = (pairs, dx, valueDx) -> pairs |> List.zipWithIndex |> List.flatMap(match (i, (key, value)) -> {
            let at = WindowView.lineAt(rect, i + 1);
            WindowView.labelIn(env, "fc31", key, { x = at#x - 8.0 + dx, y = at#y }, 0) ::
            WindowView.label(env, value, { x = at#x - 8.0 + dx + valueDx, y = at#y }, 0) :: Nil
        });
        let (levelKey, levelValue) = status#level;
        List.flatten(
            WindowView.frame(env, rect, 0) ::
            (WindowView.label(env, status#name, { x = head#x - 8.0, y = head#y }, 0) ::
             WindowView.labelIn(env, "fc31", levelKey, { x = head#x + 128.0, y = head#y }, 0) ::
             WindowView.label(env, levelValue, { x = head#x + 192.0, y = head#y }, 0) :: Nil) ::
            column(status#left, 0.0, 36.0) ::
            column(status#right, 136.0, 56.0) ::
            Nil)
}
