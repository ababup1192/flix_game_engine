// App.Internal.LoadingView — ブラウザ版で App が届いていない物を待つ間の、engine の既定の表示: 押した点から広がる波紋と、画面の右下の小さな輪
// （届いた割合の弧と、回り続ける光の点）。字は出さない。z は ZBand.loadingBase の範囲。
// ゲームからは呼ばない（App の中身。替えるのは App.withLoadingIndicator）。
pub mod App.Internal.LoadingView {

    /// 輪を出し始める待ちの秒。
    pub def indicatorSeconds(): Float64 = 0.5

    /// 輪がにじみ出る秒。
    def fadeInSeconds(): Float64 = 0.15

    /// この秒を超えたら、回り方をゆっくりにして板の色を替える（通信を待っている形）。
    def slowSeconds(): Float64 = 20.0

    /// 波紋が広がり切って消える秒。
    def rippleSeconds(): Float64 = 0.45

    /// 待ちの表示の絵。press = 押した点（design 座標。キーで押した時は None で画面の真ん中）。
    /// 波紋は押した時の待ちの頭だけ・輪は待ちが indicatorSeconds を超えてから。
    pub def itemsOf(design: Vec2.Vec2, wait: LoadProgress.LoadWait, press: Option[Vec2.Vec2]): List[Render.PlacedItem] =
        List.append(rippleOf(design, wait, press), indicatorOf(design, wait))

    def white(): Color = { r = 1.0, g = 1.0, b = 1.0 }

    def rippleOf(design: Vec2.Vec2, wait: LoadProgress.LoadWait, press: Option[Vec2.Vec2]): List[Render.PlacedItem] =
        let t = wait#waited / rippleSeconds();
        if (not wait#pressed or t >= 1.0) Nil
        else {
            let center = Option.getWithDefault({ x = design#x * 0.5, y = design#y * 0.5 }, press);
            let left = 1.0 - Float64.max(0.0, t);
            let radius = Float64.max(2.0, (1.0 - left * left) * Float64.min(design#x, design#y) * 0.14);
            let z = ZBand.loadingBase();
            let disc = RawDraw.circleAt(center, radius, white(), z) |> Render.overItem(Render.fade(0.28 * left));
            disc :: arcAt(center, { radius = radius, width = Float64.max(1.0, radius * 0.06) }, { fromT = 0.0, toT = 1.0 }, 0.55 * left, z + 1)
        }

    def indicatorOf(design: Vec2.Vec2, wait: LoadProgress.LoadWait): List[Render.PlacedItem] =
        let shown = (wait#waited - indicatorSeconds()) / fadeInSeconds();
        if (shown <= 0.0) Nil
        else {
            let a = Float64.min(1.0, shown);
            let unit = Float64.max(6.0, Float64.min(20.0, Float64.min(design#x, design#y) * 0.035));
            let half = unit * 1.5;
            let center = { x = design#x - half - unit * 0.6, y = design#y - half - unit * 0.6 };
            let slow = wait#waited > slowSeconds();
            let z = ZBand.loadingBase() + 2;
            let plateColor = if (slow) { r = 0.09, g = 0.11, b = 0.2 } else { r = 0.0, g = 0.0, b = 0.0 };
            let plate = RawDraw.boxAt(center, { x = half * 2.0, y = half * 2.0 }, plateColor, z)
                |> Render.overItem(item -> item |> Render.rounded(half * 0.45) |> Render.fade(0.55 * a));
            let ring = { radius = unit, width = Float64.max(1.0, unit * 0.2) };
            let sweep = Float64.max(0.04, Float64.min(1.0, wait#progress));
            let turn = wait#waited * (if (slow) 0.35 else 1.1);
            let spot = Vec2.add(center, Vec2.onEllipse({ x = unit - ring#width * 0.5, y = unit - ring#width * 0.5 }, turn - Float64.floor(turn)));
            let glow = RawDraw.circleAt(spot, unit * 0.34, white(), z + 4) |> Render.overItem(Render.fade(0.22 * a));
            let dot = RawDraw.circleAt(spot, unit * 0.15, white(), z + 5) |> Render.overItem(Render.fade(a));
            plate :: List.append(arcAt(center, ring, { fromT = 0.0, toT = 1.0 }, 0.28 * a, z + 1),
                                 List.append(arcAt(center, ring, { fromT = 0.0, toT = sweep }, 0.85 * a, z + 2), glow :: dot :: Nil))
        }

    /// center を中心に、fromT..toT（1 周 = 1.0・0 が真上・時計回り）の白い弧を台形を並べて描く。
    def arcAt(center: Vec2.Vec2, ring: { radius = Float64, width = Float64 }, sweep: { fromT = Float64, toT = Float64 },
              alpha: Float64, zIndex: Int32): List[Render.PlacedItem] =
        let inner = Float64.max(0.0, ring#radius - ring#width);
        let segs = Int32.max(4, Float64.ceil(32.0 * (sweep#toT - sweep#fromT)) |> Float64.tryToInt32 |> Option.getWithDefault(32));
        let at = i -> sweep#fromT + (sweep#toT - sweep#fromT) * Int32.toFloat64(i) / Int32.toFloat64(segs);
        let on = (r, t) -> Vec2.onEllipse({ x = r, y = r }, t);
        List.range(0, segs) |> List.map(i -> {
            let (t0, t1) = (at(i), at(i + 1));
            let quad = on(ring#radius, t0) :: on(ring#radius, t1) :: on(inner, t1) :: on(inner, t0) :: Nil;
            Render.at(center, RawDraw.polygon(quad, white(), zIndex) |> Render.fade(alpha))
        })
}
