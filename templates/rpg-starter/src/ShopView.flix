// ShopView — 道具屋の絵（HUD）。左上に かう / うる / やめる・その下に手持ちのお金・右に品と値段・品の左下に個数（右下は はい / いいえ の場所）。
// 店の人の台詞と「〜G で かいますか？」の はい / いいえ は、会話のウィンドウ（FieldScreen）が画面の下に出す。
mod ShopView {
    use fge::{Rect2, Render, ZStack}
    use ZOrder.HudLayer

    /// 描くのに要る値。top = かう / うる / やめる・gold = お金のウィンドウの名前と額・goods = 品の一覧・
    /// count = 個数のウィンドウの字（個数と合計の値段）と、カーソルが個数にあるか（偽なら止まった ▶）。
    pub type alias In = {
        top = WindowView.ListBox,
        gold = (String, String),
        goods = Option[WindowView.ListBox],
        count = Option[(String, String, Bool)]
    }

    def topRect(): Rect2.Rect2 = WindowView.grid({ col = 1, row = 1, cols = 9, rows = WindowView.rowsFor(3) })

    def goldRect(): Rect2.Rect2 = WindowView.grid({ col = 1, row = 10, cols = 9, rows = 4 })

    def goodsRect(n: Int32): Rect2.Rect2 = WindowView.grid({ col = 11, row = 1, cols = 20, rows = WindowView.rowsFor(Int32.max(n, 4)) })

    def countRect(): Rect2.Rect2 = WindowView.grid({ col = 11, row = 13, cols = 10, rows = 4 })

    /// 店のウィンドウ（奥から: かう / うる・お金・品・個数）。
    pub def tree(env: WindowView.Env, shop: In): ZStack.Tree[HudLayer, Unit] =
        let goods = shop#goods |> Option.map(box -> WindowView.listWindow(env, goodsRect(List.length(box#rows)), box, 0)) |> Option.getWithDefault(Nil);
        let count = shop#count |> Option.map(countItems(env)) |> Option.getWithDefault(Nil);
        ZStack.of(ZStack.leaf(WindowView.listWindow(env, topRect(), shop#top, 0)) :: ZStack.leaf(goldItems(env, shop#gold)) ::
                  ZStack.leaf(goods) :: ZStack.leaf(count) :: Nil)

    def goldItems(env: WindowView.Env, gold: (String, String)): List[Render.PlacedItem] =
        let rect = goldRect();
        let (title, amount) = gold;
        let at = WindowView.lineAt(rect, 0);
        List.flatten(WindowView.frame(env, rect, 0) :: WindowView.title(env, rect, title, 0) ::
                     (WindowView.labelRight(env, "fc30", amount, rect#position#x + rect#size#x - WindowView.cell() - 2.0, at#y, 0) :: Nil) :: Nil)

    def countItems(env: WindowView.Env, count: (String, String, Bool)): List[Render.PlacedItem] =
        let rect = countRect();
        let (times, price, active) = count;
        let at = WindowView.lineAt(rect, 0);
        List.flatten(WindowView.frame(env, rect, 0) ::
                     (WindowView.label(env, times, at, 0) ::
                      WindowView.labelRight(env, "fc30", price, rect#position#x + rect#size#x - WindowView.cell() - 2.0, at#y, 0) :: Nil) ::
                     (if (active) WindowView.cursor(env, at, 0) else WindowView.cursorStill(env, at, 0)) :: Nil)
}
