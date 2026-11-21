// Layout — 校舎の配置の表（assets/school/layout.json。Blender の書き出しが作る）を、engine の座標の値にする（純粋）。
// 表は glTF の座標（右手系・+Y が上）で書いてある。engine は左手系で、Gltf は glb を読む時に X を反転する。
// glb と同じ所に置くため、表の点も読む時に X を反転する（箱の min と max は X だけ入れ替わる）。
// 表が壊れていれば Err（校舎が組めないので起動の必須入力）。欄が 1 つ欠けた行は、その行だけ捨てる。
mod Layout {
    use fge::{Color, DocJson, JsonCodec, Num, Vec2, Vec3}
    use Util.Json.Json

    /// 軸にそろった箱（engine の座標）。
    pub type alias Box = { min = Vec3.Vec3, max = Vec3.Vec3 }

    /// 部屋の床の範囲（engine の x・z）。
    /// kind = 部屋の種類（classroom・special・corridor・stairs など。書いていなければ "room"）。
    /// shade = 部屋の真ん中のベイクした明るさ（人物のようにベイクできない物に掛ける色。書いていなければ白）。
    pub type alias Room = { id = String, name = String, kind = String, min = Vec2.Vec2, max = Vec2.Vec2, shade = Color }

    /// 階段 1 つ。ramps = 坂ごとの 4 隅（踊り場までの坂・踊り場からの坂）。fromFloor・toFloor = つなぐ階の番号。
    pub type alias Stair = { id = String, fromFloor = Int32, toFloor = Int32, ramps = List[List[Vec3.Vec3]] }

    /// 階 1 つ。y = 床の高さ・glb = 建物の形のファイル（assets/school/ からの名前）。
    pub type alias Floor = { index = Int32, y = Float64, glb = String, rooms = List[Room], colliders = List[Box], stairs = List[Stair] }

    /// 小物 1 つ。yaw = 表の角（ラジアン・glTF の +Y まわり）。
    /// shade = 置いた所のベイクした明るさ（小物の形は部屋の間で使い回すので、置いた所の光は形でなくこの色で掛ける。書いていなければ白）。
    pub type alias Prop = { prop = String, floor = Int32, pos = Vec3.Vec3, yaw = Float64, shade = Color }

    /// 教室のプレート 1 つ。
    pub type alias Sign = { pos = Vec3.Vec3, text = String }

    /// 灯りの種類。
    pub enum LightKind with Eq, ToString {
        case Moon        // 窓の内側の月明かり
        case ExitGreen   // 非常口の緑の灯り
    }

    pub type alias Light = { kind = LightKind, floor = Int32, pos = Vec3.Vec3 }

    /// 始まりの足元と向き（engine のカメラの yaw・ラジアン）。
    pub type alias Start = { pos = Vec3.Vec3, yaw = Float64 }

    /// placeholder = 仮の表（tools/placeholder_layout.py が書いた物。glb が無い前提で箱を絵にする）。
    pub type alias Layout = { placeholder = Bool, floors = List[Floor], props = List[Prop], signs = List[Sign], lights = List[Light], start = Start }

    pub def path(): String = "assets/school/layout.json"

    /// 階の無い表（読めなかった時の受け皿。歩く床も無い）。
    pub def empty(): Layout = { placeholder = true, floors = Nil, props = Nil, signs = Nil, lights = Nil, start = { pos = Vec3.zero(), yaw = 0.0 } }

    /// 表を読む。読めない・形が違えば Err（どの欄かの文つき）。
    pub def load(p: String): Result[String, Layout] \ Fs.FileRead =
        DocJson.readJson(p) |> Result.mapErr(_ -> "${p} を JSON として読めない")
            |> Result.flatMap(json -> JsonCodec.expectObject(json) |> Option.toOk("${p} の一番外が object でない"))
            |> Result.flatMap(fromRoot)

    /// テキストから表へ（テストと読み込みの共通の口）。
    pub def fromJson(text: String): Result[String, Layout] =
        DocJson.parse(text) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("layout.json を JSON の object として読めない")
            |> Result.flatMap(fromRoot)

    def fromRoot(root: Map[String, Json]): Result[String, Layout] =
        let floors = listOf("floors", floorOf, root);
        let start = Map.get("spawn", root) |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(startOf);
        match start {
            case None => Err("layout.json に spawn（pos と yaw）が無い")
            case Some(_) if List.isEmpty(floors) => Err("layout.json に floors が無い")
            case Some(s) =>
                Ok({ placeholder = JsonCodec.boolOr("placeholder", false, root), floors = floors,
                     props = listOf("props", propOf, root), signs = listOf("signs", signOf, root),
                     lights = listOf("lights", lightOf, root), start = s })
        }

    /// 配列の欄を 1 行ずつ読む（読めない行は捨てる）。
    def listOf(key: String, rowOf: Map[String, Json] -> Option[a], obj: Map[String, Json]): List[a] =
        Map.get(key, obj) |> Option.flatMap(JsonCodec.decodeList(Some)) |> Option.getWithDefault(Nil)
            |> List.filterMap(j -> JsonCodec.expectObject(j) |> Option.flatMap(rowOf))

    /// glTF の [x, y, z] → engine の点（X を反転）。
    def pointOf(j: Json): Option[Vec3.Vec3] =
        JsonCodec.decodeList(JsonCodec.expectFloat, j) |> Option.flatMap(xs -> match xs {
            case x :: y :: z :: Nil => Some(Vec3.v3(0.0 - x, y, z))
            case _                  => None
        })

    /// glTF の [x, z] → engine の x・z（X を反転）。
    def planeOf(j: Json): Option[Vec2.Vec2] =
        JsonCodec.decodeList(JsonCodec.expectFloat, j) |> Option.flatMap(xs -> match xs {
            case x :: z :: Nil => Some({ x = 0.0 - x, y = z })
            case _             => None
        })

    def field(key: String, decode: Json -> Option[a], obj: Map[String, Json]): Option[a] =
        Map.get(key, obj) |> Option.flatMap(decode)

    /// X を反転した 2 点を、min と max にそろえた箱にする。
    def boxOf(a: Vec3.Vec3, b: Vec3.Vec3): Box =
        { min = Vec3.v3(Float64.min(a#x, b#x), Float64.min(a#y, b#y), Float64.min(a#z, b#z)),
          max = Vec3.v3(Float64.max(a#x, b#x), Float64.max(a#y, b#y), Float64.max(a#z, b#z)) }

    def colliderOf(obj: Map[String, Json]): Option[Box] =
        forM (a <- field("min", pointOf, obj); b <- field("max", pointOf, obj)) yield boxOf(a, b)

    def roomOf(obj: Map[String, Json]): Option[Room] =
        forM (
            id <- field("id", JsonCodec.expectString, obj);
            a <- field("min", planeOf, obj);
            b <- field("max", planeOf, obj)
        ) yield { id = id, name = JsonCodec.stringOr("name", id, obj), kind = JsonCodec.stringOr("kind", "room", obj),
                  min = { x = Float64.min(a#x, b#x), y = Float64.min(a#y, b#y) }, max = { x = Float64.max(a#x, b#x), y = Float64.max(a#y, b#y) },
                  shade = shadeOf(obj) }

    def stairOf(obj: Map[String, Json]): Option[Stair] =
        let ramps = Map.get("ramp", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.decodeList(pointOf)))
            |> Option.getWithDefault(Nil) |> List.filter(r -> List.length(r) == 4);
        if (List.isEmpty(ramps)) None
        else forM (
            fromFloor <- field("from", JsonCodec.expectInt, obj);
            toFloor <- field("to", JsonCodec.expectInt, obj)
        ) yield { id = JsonCodec.stringOr("id", "stairs", obj), fromFloor = fromFloor, toFloor = toFloor, ramps = ramps }

    def floorOf(obj: Map[String, Json]): Option[Floor] =
        forM (
            index <- field("index", JsonCodec.expectInt, obj);
            y <- field("y", JsonCodec.expectFloat, obj)
        ) yield { index = index, y = y, glb = JsonCodec.stringOr("glb", "school_floor${Int32.toString(index)}.glb", obj),
                  rooms = listOf("rooms", roomOf, obj), colliders = listOf("colliders", colliderOf, obj), stairs = listOf("stairs", stairOf, obj) }

    def propOf(obj: Map[String, Json]): Option[Prop] =
        forM (
            name <- field("prop", JsonCodec.expectString, obj);
            floor <- field("floor", JsonCodec.expectInt, obj);
            pos <- field("pos", pointOf, obj)
        ) yield { prop = name, floor = floor, pos = pos, yaw = degrees(JsonCodec.floatOr("yaw", 0.0, obj)), shade = shadeOf(obj) }

    /// ベイクした明るさ [r, g, b]（0〜1・画面の値）。無い・形が違えば白（光を掛けない）。
    def shadeOf(obj: Map[String, Json]): Color =
        field("shade", JsonCodec.decodeList(JsonCodec.expectFloat), obj) |> Option.flatMap(xs -> match xs {
            case r :: g :: b :: Nil => Some(Color.rgb(r, g, b))
            case _                  => None
        }) |> Option.getWithDefault(Color.rgb(1.0, 1.0, 1.0))

    /// 点が入る部屋（高さに一番近い階の rooms から。廊下と階段も部屋として返る）。
    pub def roomAt(at: Vec3.Vec3, layout: Layout): Option[Room] =
        floorAt(floorIndexAt(at#y, layout), layout)
            |> Option.flatMap(f -> f#rooms |> List.find(r -> r#min#x <= at#x and at#x <= r#max#x and r#min#y <= at#z and at#z <= r#max#y))

    /// 足元の点が入る部屋のベイクした明るさ（どの部屋にも入らなければ白）。
    pub def shadeAt(at: Vec3.Vec3, layout: Layout): Color =
        roomAt(at, layout) |> Option.map(r -> r#shade) |> Option.getWithDefault(Color.rgb(1.0, 1.0, 1.0))

    def signOf(obj: Map[String, Json]): Option[Sign] =
        forM (pos <- field("pos", pointOf, obj); text <- field("text", JsonCodec.expectString, obj)) yield { pos = pos, text = text }

    def lightOf(obj: Map[String, Json]): Option[Light] =
        let kind = match JsonCodec.stringOr("type", "", obj) {
            case "moon"       => Some(LightKind.Moon)
            case "exit_green" => Some(LightKind.ExitGreen)
            case _            => None
        };
        forM (
            k <- kind;
            floor <- field("floor", JsonCodec.expectInt, obj);
            pos <- field("pos", pointOf, obj)
        ) yield { kind = k, floor = floor, pos = pos }

    /// 表の yaw は glTF の +Y まわりの度で、0 が glTF の −Z を向く（右手系なので増えると −X の側へ回る）。
    /// 前の向きは glTF で (−sin, 0, −cos)・X を反転した engine で (sin, 0, −cos)。engine のカメラは (sin ψ, ·, cos ψ) を向くので ψ = π − yaw。
    def startOf(obj: Map[String, Json]): Option[Start] =
        field("pos", pointOf, obj) |> Option.map(pos -> { pos = pos, yaw = Num.pi() - degrees(JsonCodec.floatOr("yaw", 0.0, obj)) })

    def degrees(d: Float64): Float64 = d * Num.pi() / 180.0

    // ── 引く口 ──

    /// 番号 index の階。
    pub def floorAt(index: Int32, l: Layout): Option[Floor] = List.find(f -> f#index == index, l#floors)

    /// 床の板: 薄く（0.35 m 以下）、上の面がその階の床の高さにある箱。建物の外形（L 字なら板が複数）もこれで分かる。
    pub def isSlab(f: Floor, b: Box): Bool =
        b#max#y - b#min#y <= 0.35 and Float64.abs(b#max#y - f#y) < 0.06

    /// 高さ y に一番近い床の階の番号（階段の途中は近い方）。
    pub def floorIndexAt(y: Float64, l: Layout): Int32 =
        l#floors |> List.minimumBy((a, b) -> Float64.abs(a#y - y) <=> Float64.abs(b#y - y))
            |> Option.map(f -> f#index) |> Option.getWithDefault(1)
}
