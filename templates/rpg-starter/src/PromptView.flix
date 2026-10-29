// PromptView — 一番手前の確認のウィンドウ（Esc の「ゲームを おわりますか？」と はい / いいえ）。
mod PromptView {
    use fge::{Vec2, ZStack}
    use ZOrder.HudLayer

    pub def quit(env: WindowView.Env, text: TextDoc.Doc, answer: World.Answer): ZStack.Tree[HudLayer, Unit] =
        let rect = WindowView.grid({ col = 6, row = 11, cols = 20, rows = 6 });
        let line = i -> WindowView.lineAt(rect, i);
        let option = col -> ({ x = line(1)#x + col * 64.0, y = line(1)#y }: Vec2.Vec2);
        let at = if (answer == World.Answer.Yes) option(0.0) else option(1.0);
        ZStack.leaf(List.flatten(
            WindowView.frame(env, rect, 0) ::
            (WindowView.label(env, TextDoc.menuText(TextDoc.MenuText.QuitAsk, text), { x = line(0)#x - 8.0, y = line(0)#y }, 0) ::
             WindowView.label(env, TextDoc.menuText(TextDoc.MenuText.Yes, text), option(0.0), 0) ::
             WindowView.label(env, TextDoc.menuText(TextDoc.MenuText.No, text), option(1.0), 0) :: Nil) ::
            WindowView.cursor(env, at, 0) :: Nil))
}
