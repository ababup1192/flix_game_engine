// 拾える物と鍵の戸の決まり（Items・World）と、items.kind.json の橋渡し。
// 校舎はテストの中に書いた小さな表で組む: 1 階に「lib」（鍵のかかった部屋・engine の x = −4..0・z = 0..4）と、その南の廊下（z = −2..0）。
// 境の壁（z = 0）は engine の x = −2..−1 が戸口で、開いた位置の戸（door-0）は x = −2.5 にある。
// 期待値の数は items.kind.json と characters.kind.json の既定（talkReach）から導く。
mod TestItems {

    use fge::{Mesh3d, Model3d, Num, Vec2, Vec3, Yarn}

    /// glTF の座標の表（engine では X が反転する）。
    def layoutJson(): String =
        "{\"floors\":[{\"index\":1,\"y\":0," +
        "\"rooms\":[{\"id\":\"lib\",\"name\":\"書庫\",\"kind\":\"special\",\"min\":[0,0],\"max\":[4,4]},{\"id\":\"hall\",\"name\":\"廊下\",\"kind\":\"corridor\",\"min\":[0,-2],\"max\":[4,0]}]," +
        "\"colliders\":[{\"min\":[-10,-0.2,-10],\"max\":[10,0,10]},{\"min\":[0,0,-0.07],\"max\":[1,2,0.07]},{\"min\":[2,0,-0.07],\"max\":[4,2,0.07]}]}]," +
        "\"props\":[{\"prop\":\"door-0\",\"floor\":1,\"pos\":[2.5,0,-0.1],\"yaw\":180}]," +
        "\"spawn\":{\"pos\":[1.5,0,-1.6],\"yaw\":0}}"

    def layout(): Layout.Layout = Layout.fromJson(layoutJson()) |> Result.getWithDefault(Layout.empty())

    /// 鍵（廊下の engine の (−3.5, 0, −1)）と名札（戸口の手前 engine の (−1.5, 0, −0.8)）・lib は鍵で開く。
    def itemsJson(): String =
        "{\"items\":[{\"id\":\"key\",\"name\":\"鍵\",\"glb\":\"prop_item_key\"},{\"id\":\"tag\",\"name\":\"名札\",\"glb\":\"prop_item_tag\"}]," +
        "\"pickups\":[{\"id\":\"p_key\",\"item\":\"key\",\"floor\":1,\"pos\":[3.5,0,-1]},{\"id\":\"p_tag\",\"item\":\"tag\",\"floor\":1,\"pos\":[1.5,0,-0.8]}]," +
        "\"locks\":[{\"room\":\"lib\",\"key\":\"key\"}]}"

    def items(): ItemsDoc.Doc = ItemsDoc.fromJson(itemsJson()) |> Result.getWithDefault(ItemsDoc.defaults())

    /// 形の代わり（形の無い模型）。拾えるのは形の読めた物だけなので、持ち物の glb の名前で置く。
    def blank(): Model3d.Model3d =
        { mesh = Mesh3d.fromPolygons(Nil), skin = None, clips = Map.empty(), parts = Nil, textures = Nil, nodes = Nil }

    def resWith(cast: CastDoc.Doc): Res.Res =
        Res.build({ walk = WalkDoc.defaults(), keys = KeysDoc.defaults(), look = LookDoc.defaults(), sound = SoundDoc.defaults(), layout = layout(),
                    assets = { floors = Map.empty(), props = Map#{"item_key" => blank(), "item_tag" => blank(), "door-0" => blank()}, surfaces = Map.empty() },
                    items = items(), cast = cast, people = Map#{"girl_student" => blank()}, dialogue = Yarn.empty(), bundles = Nil, pending = Res.nothingPending() })

    def res(): Res.Res = resWith(CastDoc.defaults())

    def texts(): ItemsDoc.Texts = ItemsDoc.rec(items())#texts

    def reach(): Float64 = CastDoc.rec(CastDoc.defaults())#talkReach

    /// 足元 (x, 0, z) に yaw（ラジアン）を向いて立ち、持ち物 held を持った World。
    def standing(x: Float64, z: Float64, yaw: Float64, held: List[String]): World.World =
        let r = res();
        let w0 = World.placeAt(r, Vec3.v3(x, 0.0, z), yaw, World.initial(r));
        World.withItems(r, held, w0) |> Result.getWithDefault(w0)

    /// 戸口の手前（engine の (−1.5, 0, −1.6)）で戸の方（+Z）を向いた所。
    def atTheDoor(held: List[String]): World.World = standing(-1.5, -1.6, 0.0, held)

    def forward(): World.Input = { forward = 1.0, strafe = 0.0, turn = 0.0, pitch = 0.0, look = Vec2.zero(), dash = false, active = true }

    /// 2 秒（20 コマ）前へ歩いた World。
    def walkedOn(w: World.World): World.World =
        let r = res();
        List.range(0, 20) |> List.foldLeft((acc, _) -> World.step(r, forward(), 0.1, acc), w)

    def idsOf(w: World.World): List[String] = World.inventoryIdsOf(res(), w)

    /// 名札のすぐ奥（engine の (−1.5, 0, −0.5)）に人物を 1 人置いた Doc。
    def castNearTheTag(): CastDoc.Doc =
        CastDoc.fromJson("{\"characters\":[{\"id\":\"g\",\"model\":\"girl_student\",\"pos\":[1.5,0,-0.5],\"yaw\":0}]}") |> Option.getWithDefault(CastDoc.defaults())

    // ── 鍵の戸 ──

    @Test
    def testLockedDoorSaysItIsLockedWithoutTheKey(): Unit \ Assert =
        // 名札だけを持って戸を調べると開かず、Doc の「鍵がかかっている。」が出る。
        let w = World.tryDoor(res(), atTheDoor("tag" :: Nil));
        Assert.assertEq(expected = (false, Some(texts()#locked)), (World.isUnlocked("lib", w), World.noticeOf(w) |> Option.map(n -> n#text)))

    @Test
    def testDoorOpensWithTheKey(): Unit \ Assert =
        // 鍵を持って調べると開き、Doc の「{name}で開けた。」に鍵の名前が入る。
        let w = World.tryDoor(res(), atTheDoor("tag" :: "key" :: Nil));
        Assert.assertEq(expected = (true, Some(ItemsDoc.fill(texts()#opened, "鍵"))), (World.isUnlocked("lib", w), World.noticeOf(w) |> Option.map(n -> n#text)))

    @Test
    def testClosedDoorStopsTheBody(): Unit \ Assert =
        // 開けていない戸口へ 2 秒歩いても、壁の線（z = 0）の手前で止まる。
        Assert.assertTrue(World.feetOf(walkedOn(atTheDoor("tag" :: Nil)))#z < 0.0)

    @Test
    def testOpenedDoorLetsTheBodyThrough(): Unit \ Assert =
        // 開けた戸口へ 2 秒歩くと、壁の線（z = 0）を越えて部屋へ入る。
        Assert.assertTrue(World.feetOf(walkedOn(World.tryDoor(res(), atTheDoor("tag" :: "key" :: Nil))))#z > 0.0)

    @Test
    def testOpenedDoorIsNoLongerATarget(): Unit \ Assert =
        // 開けた戸は 2 回目は調べる物にならない（何も言わない）。
        let opened = World.tryDoor(res(), atTheDoor("tag" :: "key" :: Nil));
        Assert.assertEq(expected = None, World.doorTargetOf(res(), opened) |> Option.map(d -> d#room))

    // ── 拾う ──

    @Test
    def testPickupOnlyWithinReach(): Unit \ Assert =
        // 鍵の方（−X）を向いて、talkReach より 0.2 m 近ければ拾える・0.5 m 遠ければ拾えない（名札は先に持たせて外す）。
        let id = (d: Float64) -> World.pickupTargetOf(res(), standing(-3.5 + d, -1.0, 0.0 - Num.pi() / 2.0, "tag" :: Nil)) |> Option.map(p -> p#id);
        Assert.assertEq(expected = (Some("p_key"), None), (id(reach() - 0.2), id(reach() + 0.5)))

    @Test
    def testPickingUpAddsTheItemOnce(): Unit \ Assert =
        // 名札を拾って演出を終え、もう一度決定しても、持ち物は名札 1 つ。
        let r = res();
        let d = ItemsDoc.rec(items())#pickup;
        let picked = World.step(r, forward(), d#flySec + d#showSec, World.startPickup(r, atTheDoor(Nil)));
        Assert.assertEq(expected = "tag" :: Nil, idsOf(World.startPickup(r, picked)))

    @Test
    def testPickedItemLeavesTheFloor(): Unit \ Assert =
        // 拾い始めた所で、名札の置き場所は拾った物に入る（床に描かない・拾える物でなくなる）。
        let picking = World.startPickup(res(), atTheDoor(Nil));
        Assert.assertEq(expected = (true, "p_tag" :: Nil), (World.isPickingUp(picking), World.takenOf(picking)))

    @Test
    def testPickupScreenEndsAfterItsSeconds(): Unit \ Assert =
        // 拾う演出は Doc の flySec + showSec が過ぎると歩く画面へ戻る。
        let r = res();
        let d = ItemsDoc.rec(items())#pickup;
        let picking = World.startPickup(r, atTheDoor(Nil));
        Assert.assertEq(expected = (true, false), (World.isPickingUp(World.step(r, forward(), d#flySec + d#showSec - 0.1, picking)),
                                                   World.isPickingUp(World.step(r, forward(), d#flySec + d#showSec, picking))))

    // ── 決定の順（人 > 物 > 戸） ──

    @Test
    def testPersonComesBeforeAnItem(): Unit \ Assert =
        // 名札のすぐ奥に人物が立っていれば、話しかける相手が先で、名札は拾える物にならない。
        let r = resWith(castNearTheTag());
        let w = World.placeAt(r, Vec3.v3(-1.5, 0.0, -1.6), 0.0, World.initial(r));
        Assert.assertEq(expected = (Some("g"), None), (World.talkTargetOf(r, w) |> Option.map(m -> m#id), World.pickupTargetOf(r, w) |> Option.map(p -> p#id)))

    @Test
    def testItemComesBeforeTheDoor(): Unit \ Assert =
        // 名札の奥に鍵の戸があっても、拾える名札が先で、戸は調べる物にならない。
        let w = atTheDoor(Nil);
        Assert.assertEq(expected = (Some("p_tag"), None), (World.pickupTargetOf(res(), w) |> Option.map(p -> p#id), World.doorTargetOf(res(), w) |> Option.map(d -> d#room)))

    // ── items.kind.json の橋渡し ──

    @Test
    def testDocRefusesAPickupOfAnUnknownItem(): Unit \ Assert =
        // 置き場所が items に無い持ち物を指していれば、読み込みは Err。
        Assert.assertTrue(Result.isErr(ItemsDoc.fromJson("{\"items\":[],\"pickups\":[{\"id\":\"p\",\"item\":\"ghost\",\"floor\":1,\"pos\":[0,0,0]}]}")))

    @Test
    def testDocRefusesALockWithAnUnknownKey(): Unit \ Assert =
        // 鍵が items に無い持ち物を指していれば、読み込みは Err。
        Assert.assertTrue(Result.isErr(ItemsDoc.fromJson("{\"items\":[],\"locks\":[{\"room\":\"lib\",\"key\":\"ghost\"}]}")))

    @Test
    def testDocOverridesOneValue(): Unit \ Assert =
        // 1 つだけ書いた値（flySec）はその値になり、ほかは既定のまま。
        let d = ItemsDoc.fromJson("{\"flySec\":1.0}") |> Result.map(x -> (ItemsDoc.rec(x)#pickup#flySec, ItemsDoc.rec(x)#pickup#showSec));
        Assert.assertEq(expected = Ok((1.0, ItemsDoc.rec(ItemsDoc.defaults())#pickup#showSec)), d)

    @Test
    def testDoorwayIsFoundFromTheWalls(): Unit \ Assert =
        // 戸口は壁の箱の切れ目（engine の x = −2..−1）の真ん中に見つかり、戸はそこで閉まる。
        Assert.assertEq(expected = Some((-1.5, 0.0)), res()#doors |> List.head |> Option.map(d -> (d#center#x, d#center#z)))
}
