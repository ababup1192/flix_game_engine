// ビルボードの場面（R2b・P8 の (7a)）: bench/scene3d の部屋にビルボードを立て、GL と WebGPU で比べる。
// 絵は 2 つ: 組み込みの放射の絵（RadialBuiltin.lightName・全面が不透明で中心が白い坂）と、毎コマ 2D の形を透明の上に描く Pass（sign・穴の空いた看板）。
// Pass の絵は GL では行 0 が下・WebGPU では上なので、貼る範囲の上下の取り違えが絵に出る。穴（α < 0.5）は捨てて奥の物が見える。
// 光を当てる物・当てない物・家具に半分隠れる物（深度の判定）・目の後ろの物（描かない）・絵の一部を貼る物を混ぜる。
mod V2Billboards {

    /// 部屋の 1 m（bench/scene3d の Room の長さの単位）。
    def meter(): Float64 = 16.0

    def m(x: Float64, y: Float64, z: Float64): Vec3.Vec3 = Vec3.v3(x * meter(), y * meter(), z * meter())

    /// 看板の Pass の名前。
    pub def signName(): String = "v2sign"

    /// 看板の Pass: 透明から、色の違う箱 3 つと斜めの帯（間に透明の隙間）を描く。
    pub def signPass(): Render.Pass =
        let place = (x: Float64, y: Float64, item: Render.Item) -> ({ at = { x = x, y = y }, item = item }: Render.PlacedItem);
        { name = signName(), clear = RenderTarget.LoadOp.ClearTransparent,
          items = place(20.0, 20.0, RawDraw.box({ x = 120.0, y = 60.0 }, Color.rgb(0.9, 0.25, 0.2), 1)) ::
                  place(170.0, 30.0, RawDraw.box({ x = 120.0, y = 50.0 }, Color.rgb(0.2, 0.7, 0.3), 1)) ::
                  place(40.0, 110.0, RawDraw.box({ x = 240.0, y = 50.0 }, Color.rgb(0.25, 0.35, 0.9), 1)) ::
                  place(0.0, 0.0, RawDraw.polygon({ x = 150.0, y = 0.0 } :: { x = 180.0, y = 0.0 } :: { x = 120.0, y = 180.0 } :: { x = 90.0, y = 180.0 } :: Nil,
                                                  Color.rgb(0.95, 0.85, 0.3), 2)) :: Nil }

    def radial(position: Vec3.Vec3, w: Float64, h: Float64): Scene3d.Billboard3d =
        let side = Int32.toFloat64(RadialBuiltin.size());
        Scene3d.billboard(RadialBuiltin.lightName(), { position = { x = 0.0, y = 0.0 }, size = { x = side, y = side } }, position, { x = w * meter(), y = h * meter() })

    def sign(source: Rect2.Rect2, position: Vec3.Vec3, w: Float64, h: Float64): Scene3d.Billboard3d =
        Scene3d.billboard(signName(), source, position, { x = w * meter(), y = h * meter() })

    /// 部屋に立てるビルボード（来た順に描く）。
    pub def billboards(): List[Scene3d.Billboard3d] =
        let whole = { position = { x = 0.0, y = 0.0 }, size = Room.design() };
        (radial(m(2.7, 0.0, 2.6), 0.9, 1.1) |> Scene3d.withBillboardTint(Color.rgb(1.0, 0.75, 0.5))) ::
        (radial(m(5.1, 0.6, 3.3), 0.7, 0.7) |> Scene3d.withBillboardTint(Color.rgb(0.4, 0.9, 1.0)) |> Scene3d.unlit) ::
        sign(whole, m(4.1, 0.0, 4.6), 2.0, 1.125) ::
        radial(m(4.0, 1.0, -3.0), 1.0, 1.0) ::
        (sign({ position = { x = 100.0, y = 20.0 }, size = { x = 120.0, y = 100.0 } }, m(3.4, 1.5, 2.0), 0.6, 0.5) |> Scene3d.withAnchor({ x = 0.5, y = 0.5 })) :: Nil

    /// 部屋（正面）にビルボードを足した場面。
    pub def room(kit: Room.Kit): Scene3d.Scene3dCmd =
        let r = Room.scene(kit, 0.0);
        { billboards = billboards() | r }

    /// 半透明の板（V2Blend）の奥と手前にビルボードがある場面（ビルボードは半透明の物より先に描くので、手前の板の色が上に重なる）。
    pub def behindGlass(kit: Room.Kit): Scene3d.Scene3dCmd =
        let r = V2Blend.room(kit);
        let back = radial(m(3.6, 0.9, 3.6), 0.9, 0.9) |> Scene3d.withBillboardTint(Color.rgb(1.0, 1.0, 0.6)) |> Scene3d.unlit;
        let front = sign({ position = { x = 0.0, y = 0.0 }, size = Room.design() }, m(4.4, 1.0, 1.6), 0.8, 0.45);
        { billboards = back :: front :: Nil | r }

    /// history の場面の Pass の名前。
    pub def trailName(): String = "v2trail"

    /// Pass trail に、部屋とその Pass 自身の history を貼るビルボードを描く（毎コマ前のコマの絵が看板の中に入れ子で写る）。
    pub def trailPass(kit: Room.Kit): Render.Pass =
        let board = Scene3d.billboard(RenderTarget.historyName(trailName()), { position = { x = 0.0, y = 0.0 }, size = Room.design() },
                                      m(4.6, 0.3, 3.4), { x = 1.6 * meter(), y = 0.9 * meter() }) |> Scene3d.unlit;
        let scene = { billboards = board :: Nil | Room.scene(kit, 0.1) };
        { name = trailName(), clear = RenderTarget.LoadOp.Clear(Color.rgb(0.1, 0.05, 0.15)),
          items = Render.scene3d(Vec2.zero(), scene) :: ({ at = { x = 20.0, y = 20.0 }, item = RawDraw.box({ x = 40.0, y = 30.0 }, Color.rgb(0.9, 0.9, 0.2), 2) }: Render.PlacedItem) :: Nil }
}
