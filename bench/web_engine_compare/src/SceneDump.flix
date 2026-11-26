// SceneDump — Scenes が作った場面の値を 1 場面 1 行の JSON で標準出力へ出す（比べる相手の場面と harness/compare-scenes.ts で比べる）。
// 出す場面の組は cases（harness/compare-scenes.ts の CASES と同じ並び）。
mod SceneDump {
    use fge::Num

    /// (場面, 段, 時刻) の組。
    pub def cases(): List[(Scenes.Scenario, Int32, Float64)] =
        (Scenes.Scenario.K1, 1, 0.0) :: (Scenes.Scenario.K1, 1, 1.25) ::
        (Scenes.Scenario.K2, 500, 0.0) :: (Scenes.Scenario.K2, 500, 1.25) :: (Scenes.Scenario.K2, 4000, 0.7) ::
        (Scenes.Scenario.K3, 2000, 0.0) :: (Scenes.Scenario.K3, 2000, 2.5) ::
        (Scenes.Scenario.K5, 20000, 3.0) :: (Scenes.Scenario.K7, 500, 0.8) :: (Scenes.Scenario.K8, 10000, 0.0) ::
        (Scenes.Scenario.K6, 25, 0.0) :: (Scenes.Scenario.K6, 400, 1.3) ::
        (Scenes.Scenario.K9, 250, 0.0) :: (Scenes.Scenario.K9, 250, 1.75) :: Nil

    def numbers(v: Vector[Float64]): String = "[${v |> Vector.map(Float64.toString) |> Vector.join(",")}]"

    def ints(v: Vector[Int32]): String = "[${v |> Vector.map(Int32.toString) |> Vector.join(",")}]"

    def v3(v: Scenes.V3): String = { let (x, y, z) = v; numbers(Vector#{x, y, z}) }

    def quats(spin: Scenes.Spin, t: Float64, count: Int32): Vector[Float64] =
        Vector.range(0, count) |> Vector.flatMap(i -> { let (x, y, z, w) = Scenes.quatAt(spin, t, i); Vector#{x, y, z, w} })

    /// 場面 1 つの JSON（欄の名前は比べる相手の FieldScene と同じ）。
    pub def jsonOf(scenario: Scenes.Scenario, level: Int32, t: Float64): String =
        let frame = Num.roundInt(t * 60.0);
        let seeded = if (scenario == Scenes.Scenario.K6) Scenes.crowdField(level, true, foxExtent()) else Scenes.build(scenario, level);
        let churned = scenario == Scenes.Scenario.K3;
        let f = if (churned) Scenes.churnedUpTo(frame, seeded) else seeded;
        let texture = if (churned and frame > 0) ints(Scenes.churnPixels(frame)) else "null";
        let camera = Scenes.cameraAt(f, t);
        let spinT = if (f#animated) t else 0.0;
        let materials = f#materials |> Vector.map(m -> "{\"color\":${v3(m#color)},\"roughness\":${m#roughness},\"metalness\":${m#metalness},\"opacity\":${m#opacity}}") |> Vector.join(",");
        let groups = match f#groups {
            case None    => "null"
            case Some(g) => "{\"count\":${g#count},\"parent\":${ints(g#parent)},\"position\":${numbers(g#position)},\"quat\":${numbers(quats(g#spin, t * g#timeScale, g#count))}}"
        };
        "{\"scenario\":\"${String.toLowerCase(ToString.toString(scenario))}\",\"level\":${level},\"t\":${t}," +
        "\"camera\":{\"position\":${v3(camera#position)},\"target\":${v3(camera#target)},\"fovY\":${f#camera#fovY}}," +
        "\"sun\":{\"direction\":${v3(f#sun#direction)},\"color\":${v3(f#sun#color)},\"intensity\":${f#sun#intensity}}," +
        "\"count\":${f#count},\"geom\":${ints(f#geom)},\"material\":${ints(f#material)},\"position\":${numbers(f#position)}," +
        "\"scale\":${numbers(f#scale)},\"quat\":${numbers(quats(f#spin, spinT, f#count))},\"materials\":[${materials}],\"groups\":${groups}," +
        "\"worldColumns\":${numbers(Vector.range(0, f#count) |> Vector.flatMap(i -> Scenes.worldColumns(f, t, i)))}," +
        "\"pickPoints\":${numbers(f#pickPoints)},\"texture\":${texture},\"hud\":${f#hud |> Option.map(hudJson(t)) |> Option.getWithDefault("null")},\"crowd\":${f#crowd |> Option.map(crowdJson(t)) |> Option.getWithDefault("null")},\"shapes\":[${Scenes.shapesOf(f#shapes) |> Vector.map(shapeJson) |> Vector.join(",")}]}"

    /// 比べる相手の素材の表（public/assets/manifest.json）の Fox の bounds。
    // WhyNot: 狐の glb を読んで量らない — この dump は画面なしの desktop で流すので素材を読む道（LoadProgress）が無い。読んだ形の広がりから作る大きさと間隔が同じかは、frame 60 の絵を比べる相手と並べて確かめた。
    def foxExtent(): Scenes.Extent =
        { min = (-12.592718124389648, -0.12174476683139801, -88.09500122070312), max = (12.592718124389648, 78.90718841552734, 66.62486267089844) }

    def crowdJson(t: Float64, c: Scenes.Crowd): String =
        "{\"count\":${c#count},\"scale\":${c#scale},\"position\":${numbers(c#position)},\"yaw\":${numbers(c#yaw)},\"phase\":${numbers(c#phase)}," +
        "\"weight\":${numbers(Vector.range(0, c#count) |> Vector.map(Scenes.runWeightAt(c, t)))}}"

    def strings(v: Vector[String]): String = "[${v |> Vector.map(x -> "\"${x}\"") |> Vector.join(",")}]"

    /// HUD の時刻 t の値（欄の名前は比べる相手の HudSpec と同じ）。
    def hudJson(t: Float64, h: Scenes.Hud): String =
        let plates = Vector.range(0, h#units#count) |> Vector.map(Scenes.nameplateAt(h, t));
        let texts = Vector.range(0, Scenes.dynamicTextCount()) |> Vector.map(Scenes.dynamicTextAt(t));
        let panels = h#panels |> List.map(p -> { let (r, g, b, a) = p#color; numbers(Vector#{p#x, p#y, p#w, p#h, r, g, b, a}) }) |> List.join(",");
        "{\"panels\":[${panels}],\"icons\":{\"x\":${numbers(h#icons#x)},\"y\":${numbers(h#icons#y)},\"cell\":${ints(h#icons#cell)}}," +
        "\"nameplates\":{\"x\":${numbers(plates |> Vector.map(p -> p#x))},\"y\":${numbers(plates |> Vector.map(p -> p#y))},\"health\":${numbers(plates |> Vector.map(p -> p#health))}," +
        "\"cell\":${ints(h#units#cell)},\"label\":${strings(h#labels)}}," +
        "\"dynamicText\":{\"x\":${numbers(texts |> Vector.map(x -> { let (a, _, _) = x; a }))},\"y\":${numbers(texts |> Vector.map(x -> { let (_, b, _) = x; b }))},\"text\":${strings(texts |> Vector.map(x -> { let (_, _, c) = x; c }))}}}"

    def shapeJson(s: Geometry.Shape): String =
        "{\"name\":\"${s#name}\",\"positions\":${numbers(s#positions)},\"normals\":${numbers(s#normals)},\"uvs\":${numbers(s#uvs)},\"indices\":${ints(s#indices)}}"

    pub def write(): Unit \ IO =
        cases() |> List.forEach(c -> { let (scenario, level, t) = c; println(jsonOf(scenario, level, t)) })
}
