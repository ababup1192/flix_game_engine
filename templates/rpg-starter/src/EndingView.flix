// EndingView — エンディングの HUD: 下のウィンドウの中をスタッフの字が下から上へ流れ、流れ切ると「おわり」。
// 絵の下敷きは報告した村のフィールド（View が FieldScreen で描く。水の戻った泉と集まった人）。入った時は墨から晴らす。
// 字は 1 行ずつ、ウィンドウの中に全部収まる行だけを出す（FC の字は欠けて出ない。途中で切れた行を描かない）。
mod EndingView {
    use fge::{Rect2, Transition, Vec2, ZStack}
    use ZOrder.HudLayer

    /// 描くのに要る値（View.endingIn が World から組む）。lines = スタッフの字（上から。{lv}・{gold} は埋めてある）、
    /// scrolled = 流れた割合（0 = 1 行目がウィンドウの下の端・1 = 最後の行が上の端を抜けた）、theEnd = 流れ切った後の字、
    /// fadeIn = 墨から晴らす進み具合（0..1。1 で晴れ切る）。
    pub type alias In = { lines = List[String], scrolled = Float64, theEnd = String, fadeIn = Float64 }

    /// スタッフの字が流れるウィンドウ（会話のウィンドウと同じ所）。
    def rect(): Rect2.Rect2 = WindowView.grid({ col = 1, row = 19, cols = 30, rows = 9 })

    pub def hud(env: WindowView.Env, viewport: Vec2.Vec2, ending: In): List[(HudLayer, ZStack.Tree[HudLayer, Unit])] =
        let box = rect();
        let center = box#position#x + box#size#x / 2.0;
        let top = box#position#y + WindowView.padTop();
        let bottom = box#position#y + box#size#y - WindowView.padTop();
        let step = WindowView.lineHeight();
        let travel = Int32.toFloat64(List.length(ending#lines)) * step + (bottom - top);
        let offset = Float64.floor(Float64.max(0.0, Float64.min(1.0, ending#scrolled)) * travel);
        let shown = if (ending#scrolled >= 1.0)
                WindowView.labelCentered(env, "fc30", ending#theEnd, center, Float64.floor((top + bottom - step) / 2.0), 0) :: Nil
            else ending#lines |> List.zipWithIndex |> List.filterMap(match (i, text) -> {
                let y = bottom - offset + Int32.toFloat64(i) * step;
                if (y >= top and y + step <= bottom and not String.isEmpty(text)) Some(WindowView.labelCentered(env, "fc30", text, center, y, 0)) else None
            });
        let window = List.append(WindowView.frame(env, box, 0), shown);
        let cover = if (ending#fadeIn >= 1.0) Nil
            else Transition.itemsAt({ kind = Transition.Kind.FadeIn, t = ending#fadeIn, viewport = viewport,
                                      color = Palette.resolve(env#res#palette, "ink"), z = 0 });
        (HudLayer.Window, ZStack.leaf(window)) :: (HudLayer.Transition, ZStack.leaf(cover)) :: Nil
}
