// ItemsView — 拾える物と鍵の戸を 3D の場面に置く（純粋）。
// 床の物と戸は 1 枚目の場面（校舎と同じ光とかすみ）に、拾う間に目の前へ飛んでくる物とアイテム画面で回す物は
// 2 枚目の場面（View.frame が校舎の上に重ねる・灯りなし）に置く。
// 持ち物の glb は頂点の色のベイクが無いので、置いた部屋のベイクした明るさを掛ける（2 枚目の物も同じ明るさ — 拾う時と画面で同じに見える）。
// WhyNot: 飛んでくる物を 1 枚目の場面に置かない — 机やピアノの板に潜って欠ける。2 枚目は奥行きを持たないので、いつも手前に出る。
// WhyNot: 床の物を大きく光らせない — 夜の校舎の静けさを壊す。部屋の明るさの内でゆっくり明るくなる・暗くなるだけにする。
mod ItemsView {
    use fge::{Color, Mat4, Model3d, Num, Scene3d, Vec3}

    /// 描くのに要る値。props = 小物と持ち物の形（School.Assets#props）・taken = 拾った置き場所・unlocked = 開けた部屋の記録・
    /// pickup = 拾う演出の中身（その間だけ）・shown = アイテム画面で選んでいる持ち物と、選び直した時刻（開いている間だけ）・
    /// eye・yaw・forward = 目の位置・左右の向き・カメラの前の向き（上下の向き込み）。
    pub type alias In = { t = Float64, items = ItemsDoc.Doc, layout = Layout.Layout, props = Map[String, Model3d.Model3d], doors = List[Items.Door],
                          taken = List[String], unlocked = Map[String, World.Unlock], pickup = Option[World.PickupRec],
                          shown = Option[(ItemsDoc.Item, Float64)], eye = Vec3.Vec3, yaw = Float64, forward = Vec3.Vec3 }

    /// 1 枚目の場面に置く物: まだ拾っていない床の物と、鍵のかかった部屋の戸（閉まっている・開いていく・開いた位置）。
    pub def sceneInstances(v: In): List[Scene3d.Instance3d] =
        List.append(floorItems(v), v#doors |> List.flatMap(door(v)))

    /// 2 枚目の場面に置く物: 拾う間の飛んでくる物か、アイテム画面で回す物（どちらでもなければ空）。
    pub def overlayInstances(v: In): List[Scene3d.Instance3d] =
        List.append(v#pickup |> Option.map(flying(v)) |> Option.getWithDefault(Nil),
                    v#shown |> Option.map(spinning(v)) |> Option.getWithDefault(Nil))

    def modelOf(v: In, item: ItemsDoc.Item): Option[Model3d.Model3d] = Map.get(Res.itemModelKey(item), v#props)

    /// 色 c の明るさを k 倍した色。
    def scaled(c: Color, k: Float64): Color = { let (r, g, b) = Color.channels(c); Color.rgb(r * k, g * k, b * k) }

    /// 0..1 の進み具合を、出だしと終わりをゆっくりにした 0..1 にする。
    def ease(x: Float64): Float64 = { let p = Num.clamp01(x); p * p * (3.0 - 2.0 * p) }

    def lerp3(a: Vec3.Vec3, b: Vec3.Vec3, k: Float64): Vec3.Vec3 = Vec3.add(a, Vec3.mul(Vec3.sub(b, a), k))

    def floorItems(v: In): List[Scene3d.Instance3d] =
        let d = ItemsDoc.rec(v#items)#pickup;
        let glow = 1.0 + d#glowAmount * (0.5 + 0.5 * Num.sin(v#t * d#glowSpeed * 2.0 * Num.pi()));
        ItemsDoc.rec(v#items)#pickups |> List.filter(p -> not List.memberOf(p#id, v#taken)) |> List.flatMap(p ->
            Items.itemOf(v#items, p#item) |> Option.flatMap(modelOf(v)) |> Option.map(m ->
                Model3d.partInstances(School.matrixAt(p#pos, p#yaw), m) |> List.map(Scene3d.withTint(scaled(Layout.shadeAt(p#pos, v#layout), glow))))
                |> Option.getWithDefault(Nil))

    /// 戸 1 枚: 開けていない部屋は閉めた位置・開けた時に向いていた戸は doorOpenSec かけて開いた位置（小物の位置）へ滑り、ほかは開いた位置。
    def door(v: In, d: Items.Door): List[Scene3d.Instance3d] =
        let openSec = Float64.max(0.01, ItemsDoc.rec(v#items)#screens#doorOpenSec);
        let opened = (u: World.Unlock) -> match u#door {
            case Some(c) if Vec3.length(Vec3.sub(c, d#center)) < 0.01 => ease((v#t - u#at) / openSec)
            case _                                                   => 1.0
        };
        let k = Map.get(d#room, v#unlocked) |> Option.map(opened) |> Option.getWithDefault(0.0);
        Map.get(d#prop#prop, v#props) |> Option.map(m ->
            Model3d.partInstances(School.matrixAt(lerp3(d#closed, d#prop#pos, k), d#prop#yaw), m) |> List.map(Scene3d.withTint(d#prop#shade)))
            |> Option.getWithDefault(Nil)

    /// 目の前の位置（左右の向きだけで決める。見下ろしていても同じ高さに来る）。
    def holdPoint(v: In, bobAt: Float64): Vec3.Vec3 =
        let d = ItemsDoc.rec(v#items)#pickup;
        let ahead = Vec3.v3(Num.sin(v#yaw), 0.0, Num.cos(v#yaw));
        Vec3.add(Vec3.add(v#eye, Vec3.mul(ahead, d#holdDistance)), Vec3.v3(0.0, 0.0 - d#holdDrop + d#bob * Num.sin(bobAt * 2.0 * Num.pi()), 0.0))

    /// 拾う間の物: 置き場所から目の前へ flySec でなめらかに飛び、大きさと起こす角を目の前の形へ寄せる。
    /// 目の前では showSec かけて 1 回転しながら少し浮き沈みし、最後の少しで小さくなって消える。
    def flying(v: In, p: World.PickupRec): List[Scene3d.Instance3d] =
        let d = ItemsDoc.rec(v#items)#pickup;
        let elapsed = v#t - p#started;
        let fly = ease(elapsed / Float64.max(0.01, d#flySec));
        let show = Num.clamp01((elapsed - d#flySec) / Float64.max(0.01, d#showSec));
        let vanish = 1.0 - Num.clamp01((show - 0.85) / 0.15);
        Items.pickupOf(v#items, p#pickup) |> Option.flatMap(pk -> Items.itemOf(v#items, pk#item) |> Option.flatMap(item -> modelOf(v, item) |> Option.map(m -> {
            let at = lerp3(pk#pos, holdPoint(v, show), fly);
            let turn = Num.lerp(pk#yaw, v#yaw + Num.pi(), fly) + show * 2.0 * Num.pi();
            let size = Num.lerp(1.0, item#viewScale, fly) * vanish;
            let tilt = item#viewTiltDeg * Num.pi() / 180.0 * fly;
            placedFacing(m, at, turn, tilt, size, Layout.shadeAt(pk#pos, v#layout))
        }))) |> Option.getWithDefault(Nil)

    /// アイテム画面の物: カメラの真ん前 viewDistance に、起こして spinDegPerSec で回す。明るさはその物を置いてあった部屋の明るさ。
    def spinning(v: In, shown: (ItemsDoc.Item, Float64)): List[Scene3d.Instance3d] =
        let (item, since) = shown;
        let s = ItemsDoc.rec(v#items)#screens;
        let at = Vec3.add(v#eye, Vec3.mul(v#forward, s#viewDistance));
        let turn = v#yaw + Num.pi() + (v#t - since) * s#spinDegPerSec * Num.pi() / 180.0;
        let shade = Items.firstPickupOf(v#items, item#id) |> Option.flatMap(Items.pickupOf(v#items)) |> Option.map(pk -> Layout.shadeAt(pk#pos, v#layout))
            |> Option.getWithDefault(Color.rgb(1.0, 1.0, 1.0));
        modelOf(v, item) |> Option.map(m -> placedFacing(m, at, turn, item#viewTiltDeg * Num.pi() / 180.0, item#viewScale, shade)) |> Option.getWithDefault(Nil)

    /// 形を at に置き、手前へ tilt 起こしてから turn 回す（起こした向きのまま縦の軸で回る）。
    def placedFacing(m: Model3d.Model3d, at: Vec3.Vec3, turn: Float64, tilt: Float64, size: Float64, shade: Color): List[Scene3d.Instance3d] =
        let world = Mat4.mul(Mat4.translate(at), Mat4.mul(Mat4.rotateY(turn), Mat4.mul(Mat4.rotateX(tilt), Mat4.scale(Vec3.v3(size, size, size)))));
        Model3d.partInstances(world, m) |> List.map(Scene3d.withTint(shade))
}
