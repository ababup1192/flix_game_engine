// SceneDump — Scenes が作った場面の値を 1 場面 1 行の JSON で標準出力へ出す（比べる相手の場面と harness/compare-scenes.ts で比べる）。
// 出す場面の組は cases（harness/compare-scenes.ts の CASES と同じ並び）。
mod SceneDump {

    /// (場面, 段, 時刻) の組。
    pub def cases(): List[(Scenes.Scenario, Int32, Float64)] =
        (Scenes.Scenario.K1, 1, 0.0) :: (Scenes.Scenario.K1, 1, 1.25) ::
        (Scenes.Scenario.K2, 500, 0.0) :: (Scenes.Scenario.K2, 500, 1.25) :: (Scenes.Scenario.K2, 4000, 0.7) :: Nil

    def numbers(v: Vector[Float64]): String = "[${v |> Vector.map(Float64.toString) |> Vector.join(",")}]"

    def ints(v: Vector[Int32]): String = "[${v |> Vector.map(Int32.toString) |> Vector.join(",")}]"

    def v3(v: Scenes.V3): String = { let (x, y, z) = v; numbers(Vector#{x, y, z}) }

    def quats(spin: Scenes.Spin, t: Float64, count: Int32): Vector[Float64] =
        Vector.range(0, count) |> Vector.flatMap(i -> { let (x, y, z, w) = Scenes.quatAt(spin, t, i); Vector#{x, y, z, w} })

    /// 場面 1 つの JSON（欄の名前は比べる相手の FieldScene と同じ）。
    pub def jsonOf(scenario: Scenes.Scenario, level: Int32, t: Float64): String =
        let f = Scenes.build(scenario, level);
        let materials = f#materials |> Vector.map(m -> "{\"color\":${v3(m#color)},\"roughness\":${m#roughness},\"metalness\":${m#metalness}}") |> Vector.join(",");
        let groups = match f#groups {
            case None    => "null"
            case Some(g) => "{\"count\":${g#count},\"parent\":${ints(g#parent)},\"position\":${numbers(g#position)},\"quat\":${numbers(quats(g#spin, t * g#timeScale, g#count))}}"
        };
        "{\"scenario\":\"${String.toLowerCase(ToString.toString(scenario))}\",\"level\":${level},\"t\":${t}," +
        "\"camera\":{\"position\":${v3(f#camera#position)},\"target\":${v3(f#camera#target)},\"fovY\":${f#camera#fovY}}," +
        "\"sun\":{\"direction\":${v3(f#sun#direction)},\"color\":${v3(f#sun#color)},\"intensity\":${f#sun#intensity}}," +
        "\"count\":${f#count},\"geom\":${ints(f#geom)},\"material\":${ints(f#material)},\"position\":${numbers(f#position)}," +
        "\"scale\":${numbers(f#scale)},\"quat\":${numbers(quats(f#spin, t, f#count))},\"materials\":[${materials}],\"groups\":${groups}," +
        "\"worldColumns\":${numbers(Vector.range(0, f#count) |> Vector.flatMap(i -> Scenes.worldColumns(f, t, i)))}," +
        "\"shapes\":[${Geometry.fieldShapes() |> Vector.map(shapeJson) |> Vector.join(",")}]}"

    def shapeJson(s: Geometry.Shape): String =
        "{\"name\":\"${s#name}\",\"positions\":${numbers(s#positions)},\"normals\":${numbers(s#normals)},\"uvs\":${numbers(s#uvs)},\"indices\":${ints(s#indices)}}"

    pub def write(): Unit \ IO =
        cases() |> List.forEach(c -> { let (scenario, level, t) = c; println(jsonOf(scenario, level, t)) })
}
