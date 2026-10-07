// RenderManifest — 生成した 1 枚の「目録」を JSON で書き出す（debug/<名前>.render.json）。
//
// なぜ要るか: PNG からは「この画素の塊が何なのか」が読めない。材質どうしの色が
// 潰れていても、主役が背景に溶けていても、画素を見るだけでは分からない。
// 目録が kind / material / role / layer と下地の色を持てば、そこが数で出る。
//
// もう 1 つの役目は逆算。行ごとに src（配置 Doc の何行目から来たか）と world 座標を
// 持つので、「この岩を右へ 10px」を「place[7].x を 0.62 → 0.66」へ翻訳できる。
// 画面 px から world への戻し方は ViewProjection.toWorldDelta が持つ。
//
// **この目録は「作者の申告」であって「生成した画素の計測」ではない。** だから 1 行の型は
// Entry でも Item でもなく Claim（申告）という名前にしてある。aabb は作者が置いたと
// 言っている矩形で、colors は作者が使ったと言っている色。実際に塗られた画素は数えていない。
// build は unmeasured にこの断りを必ず 1 本足す — 嘘の保証を出さないための行。
//
// 隣の部品: 実行中に矩形で囲んで記録するのは Annotate（Hit）、UI の木の幾何破綻を
// 見つけるのは RenderLint（engine_tools の Element）。ここは world の物 1 つずつの申告を持つ。
pub mod RenderManifest {

    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JString, JNumber}

    /// 画面の中でその物が何をしているか。**語彙はここで閉じる**（intent と違い、
    /// 増えない 4 つ）。"backdrop" と "background" の打ち間違いを型で裁くための enum。
    pub enum Role with Eq, ToString {
        case Subject      // 主役。背景から分離して読めることを測る対象
        case Prop         // 主役の周りの物
        case Backdrop     // 背景の面
        case Effect       // 光・粒・かすみのような重ね物
    }

    /// JSON に出す名前。
    pub def roleKey(r: Role): String = match r {
        case Role.Subject  => "subject"
        case Role.Prop     => "prop"
        case Role.Backdrop => "backdrop"
        case Role.Effect   => "effect"
    }

    /// 目録の 1 行 = 描いた物 1 つについての**作者の申告**。
    ///
    /// | 欄 | 中身 |
    /// |---|---|
    /// | `id` | 画面の中で一意な名前（"rock@0" のように種類 + 連番） |
    /// | `kind` | 何として描いたか（rock / wall / cloud …） |
    /// | `material` | 色の出どころ（場面のパレットの名前）。材質どうしの色の潰れはここで測る |
    /// | `role` | Subject / Prop / Backdrop / Effect。主役と背景の分離はここで測る |
    /// | `layer` | 奥から手前への帯の名前（Depth.Bands の帯名をそのまま書ける） |
    /// | `zIndex` | 重なり順（Annotate.Hit と同じ名前） |
    /// | `at` | world 座標。配置 Doc の数字と同じ単位 |
    /// | `src` | 配置 Doc の出どころ（"alley.scene.json#place[7]"）。**直しの効き目はここで決まる** |
    /// | `aabb` | 画面のどこを占めると言っているか（design px）。**申告であって計測ではない** |
    /// | `colors` | 使ったと言っている色。**申告であって計測ではない** |
    /// | `intent` | 作者が主張していること。検査はここに書いた物だけ動く |
    pub type alias Claim = {
        id = String,
        kind = String,
        material = String,
        role = Role,
        layer = String,
        zIndex = Int32,
        at = ViewProjection.WorldPos,
        src = String,
        aabb = Rect2.Rect2,
        colors = List[Color],
        intent = List[String]
    }

    /// 測れなかった検査と、その理由。黙って落とさないための行。
    pub type alias Unmeasured = { check = String, why = String }

    /// 欠けた欄の落ち先。1 行はこの上に足りる欄だけ載せて組む:
    /// `{ id = "rock@0", kind = "rock", intent = "grounded" :: Nil | RenderManifest.blank() }`
    ///
    /// Annotate が描画物から拾った Hit（実行中の注釈 UI の型）を下敷きにするなら、
    /// 引き継ぐ欄を呼ぶ側が選んで同じ形で書く — どの欄が Hit 由来かがその 1 行で読める:
    /// `{ id = h#name, kind = h#kind, zIndex = h#zIndex, aabb = h#aabb | RenderManifest.blank() }`
    ///
    /// RenderLint（engine_tools）へ流すなら Element も呼ぶ側で組む
    /// （engine_world は engine_tools に依存しないので、変換をここに置けない）:
    /// `{ path = c#id, kind = RenderLint.Kind.Box, z = c#zIndex, ancestors = Nil,
    ///    bbox = { minX = c#aabb#position#x, minY = c#aabb#position#y,
    ///             maxX = c#aabb#position#x + c#aabb#size#x,
    ///             maxY = c#aabb#position#y + c#aabb#size#y } }`
    pub def blank(): Claim =
        { id = "?", kind = "?", material = "?", role = Role.Prop, layer = "mid", zIndex = 0,
          at = ViewProjection.worldPos(0.0, 0.0), src = "?",
          aabb = { position = { x = 0.0, y = 0.0 }, size = { x = 0.0, y = 0.0 } },
          colors = Nil, intent = Nil }

    // ════════════════════════════════════════════════════════
    // intent — 検査は、作者が主張していないことについては鳴らない
    // ════════════════════════════════════════════════════════

    /// intent は「作者が主張していること」の並び。**既定を「全部検査する」から
    /// 「主張したことだけ検査する」へ反転させる**ための仕組み。
    ///
    ///   intent = "grounded" :: Nil  → 接地の検査が動く
    ///   intent = "floating" :: Nil  → 接地の検査は動かない（浮いているのが画風）
    ///   intent = Nil                → 何も動かない。ただし undeclared として数える
    ///
    /// 固定の検査は創作の枷になる（浮いている岩を描きたいとき、接地の検査は邪魔でしかない）。
    /// 「浮いている物に接地の検査を掛けない」が書ける形にしてある。
    ///
    /// 未宣言は**沈黙させない。だが止めもしない**。build が id を並べて "undeclared" に出す
    /// （数だけ出すと、読んだ人がどの行かを自分で数える羽目になる）。
    ///
    /// どの主張がどの検査を呼ぶかは検査側（ゲーム / ツール）が決める。語彙の目安:
    /// grounded / floating（接地）・humanoid / mechanical（人体）・subject（主役の面積と
    /// 明度差）・tiled / organic（格子）・animated（コマ間の飛びとループ）。
    /// **engine はここで語彙を閉じない** — 画風ごとに増えるので、文字列のまま持つ
    /// （閉じている role が enum なのはこの逆）。
    pub def undeclaredIds(claims: List[Claim]): List[String] =
        claims |> List.filterMap(c -> if (List.isEmpty(c#intent)) Some(c#id) else None)

    // ════════════════════════════════════════════════════════
    // 書き出し
    // ════════════════════════════════════════════════════════

    /// 目録 1 枚ぶんの JSON テキスト（末尾に改行付き）。
    /// unmeasured には「aabb と colors は申告であって計測ではない」の 1 行が必ず足される。
    ///
    /// background（下地の色）は design の隣にトップレベルで出す。「主役が背景に溶けた」を
    /// 測るのに要る値なので、パレット（材質名 → 色の表）へ紛れ込ませない — 下地は材質ではない。
    pub def build(meta: { shot = String, projection = ViewProjection.ViewProjection,
                          background = Color },
                  claims: List[Claim], palette: Map[String, Color],
                  unmeasured: List[Unmeasured]): String =
        let vp = meta#projection;
        let design = ViewProjection.designOf(vp);
        let firstPerson = ViewProjection.firstPersonOf(vp);
        let obj = JObject(Map#{
            "version"    => JNumber(JsonCodec.intToBd(1)),
            "shot"       => JString(meta#shot),
            "view"       => JString(ViewProjection.key(ViewProjection.modeOf(vp))),
            "design"     => JObject(Map#{ "w" => num(design#x), "h" => num(design#y) }),
            "background" => JString(Color.toHex(meta#background)),
            "projection" => projectionJson(vp),
            "items"      => JArray(claims |> List.map(claimJson(vp, firstPerson)) |> List.toVector),
            "palette"    => JObject(palette |> Map.map(Color.toHex) |> Map.map(JString)),
            "undeclared" => JArray(undeclaredIds(claims) |> List.map(JString) |> List.toVector),
            "unmeasured" => JArray((declaredNote() :: unmeasured)
                                |> List.map(u -> JObject(Map#{
                                       "check" => JString(u#check),
                                       "why"   => JString(u#why) }))
                                |> List.toVector)
        });
        Util.Json.toPrettyString(2, obj) + "\n"

    /// aabb と colors は作者の申告で、生成した画素を数えた値ではない。
    /// 取り違えると、実装のバグを目録が追認してしまう（同じ色で潰れていても一致する）。
    def declaredNote(): Unmeasured =
        { check = "aabb/colors",
          why = "作者の申告であって計測ではない — 生成した画素は数えていない" }

    // ── 1 行 ──

    def claimJson(vp: ViewProjection.ViewProjection,
                  firstPerson: Option[ViewProjection.FirstPersonSpec]): Claim -> Json = c ->
        let base = Map#{
            "id"       => JString(c#id),
            "kind"     => JString(c#kind),
            "material" => JString(c#material),
            "role"     => JString(roleKey(c#role)),
            "layer"    => JString(c#layer),
            "z"        => JNumber(JsonCodec.intToBd(c#zIndex)),
            "world"    => worldJson(vp, c#at),
            "src"      => JString(c#src),
            "aabb"     => JArray(List#{ num(c#aabb#position#x), num(c#aabb#position#y),
                                        num(c#aabb#size#x), num(c#aabb#size#y) } |> List.toVector),
            "colors"   => JArray(c#colors |> List.map(col -> JString(Color.toHex(col))) |> List.toVector),
            "intent"   => JArray(c#intent |> List.map(JString) |> List.toVector)
        };
        JObject(Map.union(cameraJson(firstPerson, c#at), base))

    /// world の並びは写し方によって長さが変わる（高さの軸を持つのは Quarter と FirstPerson）。
    def worldJson(vp: ViewProjection.ViewProjection, at: ViewProjection.WorldPos): Json =
        if (ViewProjection.usesHeight(ViewProjection.modeOf(vp)))
            JArray(List#{ num(at#x), num(at#y), num(at#h) } |> List.toVector)
        else
            JArray(List#{ num(at#x), num(at#y) } |> List.toVector)

    /// FirstPerson は screen → world が一意に決まらないので、逆変換の代わりに
    /// 「正面から何度ずれて・どれだけ遠く・どれだけ画面に入っているか」を載せる。
    def cameraJson(firstPerson: Option[ViewProjection.FirstPersonSpec],
                   at: ViewProjection.WorldPos): Map[String, Json] =
        match firstPerson {
            case Some(f) => Map#{
                "yaw"      => num(ViewProjection.yawOf(f, at)),
                "distance" => num(ViewProjection.distanceOf(f, at)),
                "visible"  => num(ViewProjection.visibleFraction(f, at, 1.0))
            }
            case None => Map.empty()
        }

    // ── 写し方（視点ごとに形が違ってよい唯一の場所） ──

    def projectionJson(vp: ViewProjection.ViewProjection): Json =
        let kind = JString(ViewProjection.key(ViewProjection.modeOf(vp)));
        match vp {
            case ViewProjection.ViewProjection.SideOf(s)    => flatJson(kind, s)
            case ViewProjection.ViewProjection.TopDownOf(s) => flatJson(kind, s)
            case ViewProjection.ViewProjection.QuarterOf(q) => JObject(Map#{
                "kind"   => kind,
                "tile"   => pair(q#tile#x, q#tile#y),
                "rise"   => num(q#rise),
                "origin" => pair(q#origin#x, q#origin#y)
            })
            case ViewProjection.ViewProjection.FirstPersonOf(f) => JObject(Map#{
                "kind"   => kind,
                "camera" => pair(f#camera#pos#x, f#camera#pos#y),
                "facing" => num(ViewProjection.toDegrees(f#camera#yaw)),
                "focal"  => pair(f#persp#fx, f#persp#fy),
                "center" => pair(f#persp#center#x, f#persp#center#y),
                "near"   => num(f#near)
            })
        }

    def flatJson(kind: Json, s: ViewProjection.FlatSpec): Json = JObject(Map#{
        "kind"      => kind,
        "center"    => pair(s#center#x, s#center#y),
        "pxPerUnit" => num(s#zoom)
    })

    // ── 小物 ──

    def num(v: Float64): Json = JNumber(JsonCodec.floatToBd(Float64.round(v * 1000.0) / 1000.0))

    def pair(a: Float64, b: Float64): Json = JArray(List#{ num(a), num(b) } |> List.toVector)

    /// PNG の隣に置く目録のパス。
    pub def pathOf(outDir: String, name: String): String = "${outDir}/${name}.render.json"

    /// 目録を path へ書き出す。親ディレクトリは作らない（`Fs.WriteFile` の流儀）。
    /// 失敗は握り潰さず呼ぶ側へ返す — 「目録が黙って存在しない」は、この目録が
    /// 防ごうとしている「画素を見ても分からない」そのもの。
    pub def write(path: String, text: String): Result[String, Unit] \ Fs.FileWrite =
        let result = run {
            Fs.WriteFile.write({ str = text }, path)
        } with Fs.WriteFile.runWithFileWrite;
        match result {
            case Ok(_)      => Ok(())
            case Err(error) => Err("render manifest write failed: ${error}")
        }
}
