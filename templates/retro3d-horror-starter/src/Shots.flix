// Shots — ギャラリーの場面（make render-all の 1 枚）の World を組む。描き出し（SceneRender）と実機（Game の App.withShots。
// START=shot:<場面>）が同じ関数で組むので、実機で開いた場面はギャラリーの絵と同じ World から始まる。
// 立つ所は配置の表（部屋の範囲・階段の坂）から導く — 仮の校舎でも作り込んだ校舎でも同じ名前で同じ種類の場面になる。
// WhyNot: 描き出しの物（HeadlessRender・HeadlessFont・java.io）を引かない — Game.app から engine_tools へつながり、ブラウザ版で組めなくなる。
mod Shots {
    use fge::{Clock, Num, Sort, Vec3}

    /// 描き出せる場面の名前（make render の使い方も SHOT の当たり判定も、この並びが source of truth）。
    /// 場面を足したら、ここと sceneOf と Makefile の SHOTS を一緒に足す。題と一言は assets/night_school.scenes.json。
    pub def names(): List[String] =
        "entrance" :: "corridor" :: "classroom" :: "stairs" :: "map" :: "map2f" :: "talk_girl" :: "talk_teacher" :: "talk_bright" :: "hint" :: "hint_bright" :: "idle_controls" :: "quit" :: "door_locked" :: "pickup_key" :: "items" :: Nil

    /// 名前 → その場面の World（表に当たる部屋や階段が無ければ None）。
    pub def worldOf(name: String, res: Res.Res): Option[World.World] =
        let w0 = { t = renderTime() | World.initial(res) };
        match name {
            case "entrance"  => Some(w0)
            case "corridor"  => corridorView(res) |> Option.map(at -> World.placeAt(res, fst(at), snd(at), w0))
            case "classroom" => classroomView(res) |> Option.map(at -> World.placeAt(res, fst(at), snd(at), w0))
            case "stairs"    => stairsView(res) |> Option.map(at -> World.placeAt(res, fst(at), snd(at), w0))
            case "map"       => Some(World.openMap(res, World.withVisited(firstRooms(res, 1, 2), w0)))
            case "map2f"     => Some(World.showFloor(res, 2, World.openMap(res, World.withVisited(firstRooms(res, 2, 1), World.withVisited(firstRooms(res, 1, 2), w0)))))
            case "talk_girl"    => talkView(res, "girl", w0)
            case "talk_teacher" => talkView(res, "teacher_man", w0)
            case "talk_bright"  => talkView(res, "teacher_man", lookedDown(res, w0))
            case "hint"         => facing(res, "girl", w0)
            case "hint_bright"  => facing(res, "teacher_man", w0)
            case "idle_controls" => corridorView(res) |> Option.map(at -> waitedIdle(res, World.placeAt(res, fst(at), snd(at), w0)))
            case "quit"      => Some(World.askQuit(w0))
            case "door_locked" => doorView(res, "library", w0) |> Option.map(World.tryDoor(res))
            case "pickup_key"  => pickupView(res, "library_key", w0)
            case "items"       => corridorView(res) |> Option.flatMap(at -> World.withItems(res, "library_key" :: "science_key" :: Nil, World.placeAt(res, fst(at), snd(at), w0)) |> Result.toOption)
                                      |> Option.map(w -> { t = w0#t + 1.0 | World.moveItemCursor(res, 1, World.openItems({ t = w0#t - 1.0 | w })) })
            case _           => None
        }

    /// 描き出しの時刻（秒）。灯りのゆらぎがこの t だけで決まるので、何度描いても同じ PNG になる。
    def renderTime(): Float64 = 3.0

    /// 0.5 秒見下ろした所（字幕の後ろに懐中電灯で明るい床が来る場面を作る）。
    def lookedDown(res: Res.Res, w: World.World): World.World =
        World.step(res, { forward = 0.0, strafe = 0.0, turn = 0.0, pitch = 1.0, look = { x = 0.0, y = 0.0 }, dash = false, active = true }, 0.5, w)

    /// 何も操作しないで、操作方法の表示が出切るまで待った所（Doc の待つ秒と出る秒）。灯りのゆらぎの時刻は待つ前のまま。
    def waitedIdle(res: Res.Res, w: World.World): World.World =
        let h = Res.walkOf(res)#hint;
        let still = World.step(res, { forward = 0.0, strafe = 0.0, turn = 0.0, pitch = 0.0, look = { x = 0.0, y = 0.0 }, dash = false, active = false }, h#wait + h#fade, w);
        { t = w#t | still }

    /// 人物 id の正面 1.4 m に立って向き合った所（話しかける前・「話す」の印が出る）。
    def facing(res: Res.Res, id: String, w0: World.World): Option[World.World] =
        Cast.memberOf(res#cast, id) |> Option.map(m -> {
            let feet = Vec3.v3(m#feet#x + 1.4 * Num.sin(m#yaw), m#feet#y, m#feet#z + 1.4 * Num.cos(m#yaw));
            World.turnTo(res, feet, yawToward(feet, m#feet), w0)
        })

    /// 人物 id の正面 1.4 m に立って向き合い、話しかけた所（首を向け切った後・最初の行を出し切った後）。
    def talkView(res: Res.Res, id: String, w0: World.World): Option[World.World] =
        Cast.memberOf(res#cast, id) |> Option.map(m -> {
            let feet = Vec3.v3(m#feet#x + 1.4 * Num.sin(m#yaw), m#feet#y, m#feet#z + 1.4 * Num.cos(m#yaw));
            let talking = World.startTalk(res, Clock.zero(), World.turnTo(res, feet, yawToward(feet, m#feet), w0));
            World.advanceTalk(Clock.zero(), { t = w0#t + CastDoc.rec(res#cast)#headTurnSec | talking })
        })

    /// 部屋 room の最初の戸口の 1.4 m 外（廊下の側）に立ち、戸口を向いた所。
    def doorView(res: Res.Res, room: String, w0: World.World): Option[World.World] =
        Items.doorsOfRoom(room, res#doors) |> List.head |> Option.map(d -> {
            let feet = Vec3.add(d#center, Vec3.mul(d#outside, 1.4));
            World.turnTo(res, feet, yawToward(feet, d#center), w0)
        })

    /// 持ち物 id の最初の置き場所の 1 m 手前（部屋の真ん中の側）に立って拾い、目の前で回っている途中の所（鍵の部屋は開けておく）。
    def pickupView(res: Res.Res, id: String, w0: World.World): Option[World.World] =
        Items.firstPickupOf(res#items, id) |> Option.flatMap(Items.pickupOf(res#items)) |> Option.flatMap(p ->
            Layout.roomAt(p#pos, res#layout) |> Option.map(r -> {
                let floorY = Layout.floorAt(p#floor, res#layout) |> Option.map(f -> f#y) |> Option.getWithDefault(p#pos#y);
                let mid = Vec3.v3((r#min#x + r#max#x) / 2.0, floorY, (r#min#y + r#max#y) / 2.0);
                let toward = Vec3.normalized(Vec3.v3(mid#x - p#pos#x, 0.0, mid#z - p#pos#z));
                let feet = Vec3.add(Vec3.v3(p#pos#x, floorY, p#pos#z), toward);
                let d = ItemsDoc.rec(res#items)#pickup;
                let picking = World.startPickup(res, World.turnTo(res, feet, yawToward(feet, p#pos), w0));
                { t = w0#t + d#flySec + d#showSec * 0.3 | picking }
            }))

    /// 階 index の最初の n 部屋の鍵（マップの場面で「行った」ことにする部屋）。
    def firstRooms(res: Res.Res, index: Int32, n: Int32): Set[String] =
        Layout.floorAt(index, res#layout) |> Option.map(f -> f#rooms |> List.take(n) |> List.map(r -> PaperMap.roomKey(index, r#id)) |> List.toSet)
            |> Option.getWithDefault(Set.empty())

    /// 足元と向き（yaw）。
    type alias Stand = (Vec3.Vec3, Float64)

    def firstFloor(res: Res.Res): Option[Layout.Floor] = res#layout#floors |> List.minimumBy((a, b) -> a#index <=> b#index)

    def yawToward(origin: Vec3.Vec3, target: Vec3.Vec3): Float64 = Num.atan2(target#x - origin#x, target#z - origin#z)

    /// 1 階の廊下: 表の部屋の種類が corridor の一番長い四角の西の端（engine の x の大きい側）の真ん中に立ち、東の端を見通す。
    /// corridor の四角が無い表（種類を書いていない古い表）では、表の始まりから一番遠い部屋の端を向く。
    def corridorView(res: Res.Res): Option[Stand] =
        firstFloor(res) |> Option.flatMap(f -> {
            let corridors = f#rooms |> List.filter(r -> r#kind == "corridor");
            match corridors |> List.maximumBy((a, b) -> (a#max#x - a#min#x) <=> (b#max#x - b#min#x)) {
                case Some(r) =>
                    let z = (r#min#y + r#max#y) / 2.0;
                    let feet = Vec3.v3(r#max#x - 1.5, f#y, z);
                    Some((feet, yawToward(feet, Vec3.v3(r#min#x, f#y, z))))
                case None =>
                    let start = res#layout#start#pos;
                    f#rooms |> List.flatMap(r -> r#min#x :: r#max#x :: Nil)
                        |> List.maximumBy((a, b) -> Float64.abs(a - start#x) <=> Float64.abs(b - start#x))
                        |> Option.map(x -> (start, yawToward(start, Vec3.v3(x, start#y, start#z))))
            }
        })

    /// 1 階の普通の教室（id が class で始まる最初の部屋）: 後ろの角から黒板（表の西の壁 = engine の x の大きい側）を見る。
    def classroomView(res: Res.Res): Option[Stand] =
        firstFloor(res) |> Option.flatMap(f -> f#rooms |> List.find(r -> String.startsWith(prefix = "class", r#id)) |> Option.map(r -> {
            let feet = Vec3.v3(r#min#x + 1.1, f#y, r#min#y + (r#max#y - r#min#y) * 0.88);
            (feet, yawToward(feet, Vec3.v3(r#max#x, f#y, (r#min#y + r#max#y) / 2.0)))
        }))

    /// 1 階から上る最初の階段: 1 本目の坂の下の端の 0.6 m 手前から、坂の上る向きを見る。
    def stairsView(res: Res.Res): Option[Stand] =
        firstFloor(res) |> Option.flatMap(f -> List.head(f#stairs)) |> Option.flatMap(s -> List.head(s#ramps)) |> Option.map(ramp -> {
            let sorted = ramp |> Sort.sortStableBy(p -> p#y);
            let mean = (ps: List[Vec3.Vec3]) -> Vec3.mul(ps |> List.foldLeft(Vec3.add, Vec3.zero()), 1.0 / Int32.toFloat64(Int32.max(1, List.length(ps))));
            let low = mean(List.take(2, sorted));
            let high = mean(List.drop(2, sorted));
            let dir = Vec3.normalized(Vec3.v3(high#x - low#x, 0.0, high#z - low#z));
            let feet = Vec3.sub(low, Vec3.mul(dir, 0.6));
            (feet, yawToward(feet, high))
        })
}
