// TitleView — タイトルの画面: 夜明けの山並みと坑道の入口の 1 枚絵・題字（world）と、メニュー・制作の字（HUD）。
mod TitleView {
    use fge::{ZStack}
    use Sheet.SheetId
    use ZOrder.{HudLayer, Layer}

    /// メニューの項目（字と選べるか）・カーソルの番号・制作の字。
    pub type alias In = { entries = List[(String, Bool)], selected = Int32, credit = String }

    /// world の層: 1 枚絵（地面の層）と題字（重ねる物の層）。
    pub def world(env: WindowView.Env): List[(Layer, ZStack.Tree[Layer, Unit])] =
        let back = Sheet.draw(env#res#sheets, env#res#palette, env#t,
            { part = Sheet.cycling(SheetId.BattleFx, "title_bg", 2.0, "fc0C", { x = 256.0, y = 240.0 }),
              at = { x = 0.0, y = 0.0 }, z = 0 });
        let logoPart = Sheet.part(SheetId.Ui, "logo", "base", "fc28", { x = 160.0, y = 34.0 });
        let logoSize = Sheet.sizeOf(env#res#sheets, logoPart);
        let logo = Sheet.draw(env#res#sheets, env#res#palette, env#t,
            { part = logoPart, at = { x = Float64.floor((256.0 - logoSize#x) / 2.0), y = 40.0 }, z = 0 });
        (Layer.Ground, ZStack.leaf(back)) :: (Layer.Over, ZStack.leaf(logo)) :: Nil

    /// HUD の層: メニューのウィンドウと制作の字。
    pub def hud(env: WindowView.Env, title: In): List[(HudLayer, ZStack.Tree[HudLayer, Unit])] =
        let rect = WindowView.grid({ col = 10, row = 20, cols = 12, rows = 5 });
        let menu = WindowView.choices(env, { rect = rect, entries = title#entries, selected = title#selected }, 0);
        let credit = WindowView.labelIn(env, "fc10", title#credit, { x = 34.0, y = 222.0 }, 0);
        (HudLayer.Window, ZStack.of(ZStack.leaf(menu) :: ZStack.leaf(credit :: Nil) :: Nil)) :: Nil
}
