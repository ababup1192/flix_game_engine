// ExploreDoc — 昼の町を歩き回る場面のつまみ（assets/explore.json）とキーの割り当て（assets/explore.keys.json）を読む。
// 無い・壊れた欄は既定値で続ける。
mod ExploreDoc {
    use fge::{DocJson, InputMap, JsonCodec, Log}
    use fge::GameEngine.Key
    use Util.Json.Json

    /// 描き方の重さのつまみ（スマホで落とす手）。shadowMapSize = 太陽の影の地図の一辺の画素（0 で影なし）・
    /// depthOfField = 手前と奥のぼけ・post = 画面全体の後がけ。
    pub type alias Quality = { shadowMapSize = Int32, depthOfField = Bool, post = Bool }

    /// 曲とクレジット。sound = project.json の sounds の名前（無ければ鳴らさず、クレジットも出さない）・volume = 音量（0〜1）・
    /// credit = クレジットの行・creditFrom・creditSec = 始めてから出し始める秒と、出しておく秒・fadeSec = 出る・消える秒。
    pub type alias Music = { sound = String, volume = Float64, credit = List[String], creditFrom = Float64, creditSec = Float64, fadeSec = Float64 }

    /// つまみ。map・look・plan = 地図・見た目・隊列のシナリオ（party と歩きのコマ・息遣い・足元の画面の高さ）の Doc・
    /// start・startFace = 先頭が立つマスと向き・speed = 歩く速さ（m/秒・スティックは倒した量を掛ける）・walkFrameSec = 歩きのコマを替える秒・radius = 先頭の円の半径（m）・
    /// spacing = 隊列の間（m）・aheadMeters・aheadRate = 歩く向きへ先を見せる長さ（m）と、そこへ寄る速さ（/秒・止まると同じ速さで戻る）・
    /// heightLagK = カメラの高さが足元の高さを遅れて追う速さ（/秒）・walkZoom = カメラの引き（足元の点からの距離の倍率）・
    /// seenHeight・hideReach = 建物の北で、足元からこの高さの点が隠れるマスを塞ぐ（塞ぐのは北へ hideReach 行まで）・
    /// passDecor = 通れる広場のにぎやかしの絵・quality = 描き方の重さの既定・music = 曲とクレジット。
    pub type alias Rec = { map = String, look = String, plan = String, start = (Int32, Int32), startFace = Route.Dir, speed = Float64, walkFrameSec = Float64,
                           radius = Float64, spacing = Float64, aheadMeters = Float64, aheadRate = Float64, heightLagK = Float64,
                           walkZoom = Float64, seenHeight = Float64, hideReach = Int32, passDecor = Set[String], quality = Quality,
                           music = Music }

    pub def path(): String = "assets/explore.json"

    pub def defaults(): Rec =
        { map = "assets/town_final.map.json", look = "assets/town.json", plan = "assets/buildup_center.json", start = (13, 54),
          startFace = Route.Dir.North, speed = 4.85, walkFrameSec = 0.24, radius = 0.3, spacing = 1.0, aheadMeters = 0.0, aheadRate = 2.0, heightLagK = 12.0,
          walkZoom = 1.35, seenHeight = 0.9, hideReach = 8, passDecor = Set#{"sprites/pigeon.png", "sprites/balloon.png"},
          quality = { shadowMapSize = 4096, depthOfField = true, post = true },
          music = { sound = "firmament3_loop", volume = 0.35, credit = Nil, creditFrom = 1.5, creditSec = 8.0, fadeSec = 0.8 } }

    /// path の Doc を読む。無ければ何も知らせずに既定値・読めなければ 1 行言って既定値。
    pub def loadOr(p: String): Rec \ Fs.FileRead =
        match DocJson.readJson(p) {
            case Ok(json) => JsonCodec.expectObject(json) |> Option.map(decode) |> Option.getWithDefault(defaults())
            case Err(e)   => Log.fellBackThen("hd2d_town", p, "ExploreDoc.defaults", DocJson.describe(e), defaults())
        }

    def decode(m: Map[String, Json]): Rec =
        let d = defaults();
        let num = (key: String, fallback: Float64) -> JsonCodec.floatOr(key, fallback, m);
        let ints = Map.get("start", m) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat)) |> Option.getWithDefault(Nil)
            |> List.map(v -> Float64.round(v) |> Float64.tryToInt32 |> Option.getWithDefault(0));
        let start = match ints {
            case c :: r :: _ => (c, r)
            case _           => d#start
        };
        let q = Map.get("quality", m) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
        let mu = Map.get("music", m) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
        { map = JsonCodec.stringOr("map", d#map, m), look = JsonCodec.stringOr("look", d#look, m), plan = JsonCodec.stringOr("plan", d#plan, m),
          start = start, startFace = Route.dirOfLetter(JsonCodec.stringOr("startFace", "n", m)),
          speed = num("speed", d#speed), walkFrameSec = num("walkFrameSec", d#walkFrameSec), radius = num("radius", d#radius), spacing = num("spacing", d#spacing),
          aheadMeters = num("aheadMeters", d#aheadMeters), aheadRate = num("aheadRate", d#aheadRate), heightLagK = num("heightLagK", d#heightLagK),
          walkZoom = num("walkZoom", d#walkZoom), seenHeight = num("seenHeight", d#seenHeight), hideReach = JsonCodec.intOr("hideReach", d#hideReach, m),
          passDecor = Map.get("passDecor", m) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.map(List.toSet)
              |> Option.getWithDefault(d#passDecor),
          quality = { shadowMapSize = JsonCodec.intOr("shadowMapSize", d#quality#shadowMapSize, q),
                      depthOfField = JsonCodec.boolOr("depthOfField", d#quality#depthOfField, q),
                      post = JsonCodec.boolOr("post", d#quality#post, q) },
          music = { sound = JsonCodec.stringOr("sound", d#music#sound, mu), volume = JsonCodec.floatOr("volume", d#music#volume, mu),
                    credit = Map.get("credit", mu) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.getWithDefault(d#music#credit),
                    creditFrom = JsonCodec.floatOr("creditFrom", d#music#creditFrom, mu), creditSec = JsonCodec.floatOr("creditSec", d#music#creditSec, mu),
                    fadeSec = JsonCodec.floatOr("fadeSec", d#music#fadeSec, mu) } }

    /// project.json の sounds に名前 name の音があるか（曲のファイルは git に入れず、書き出しの時だけ足すので、無い時は鳴らさない）。
    pub def isSoundDeclared(name: String): Bool \ Fs.FileRead =
        DocJson.readJson("project.json") |> Result.toOption |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(Map.get("sounds"))
            |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.map(o -> JsonCodec.stringOr("name", "", o))))
            |> Option.map(List.memberOf(name)) |> Option.getWithDefault(false)

    /// 描き方の重さを、つまみの表 knobs（実機は環境変数・ブラウザは頁の URL の query）で差し替える。
    /// shadow = 影の地図の一辺（0 で影なし）・dof = 0 / 1・post = 0 / 1。知らない値は既定のまま。
    pub def qualityWith(knobs: Map[String, String], q: Quality): Quality =
        let flag = (key: String, fallback: Bool) -> match Map.get(key, knobs) {
            case Some("0") => false
            case Some("1") => true
            case _         => fallback
        };
        { shadowMapSize = Map.get("shadow", knobs) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(q#shadowMapSize),
          depthOfField = flag("dof", q#depthOfField), post = flag("post", q#post) }

    /// 操作ごとのキーの列（1 つの操作に複数キー・矢印と WASD）。
    pub type alias Keys = { left = List[Key], right = List[Key], up = List[Key], down = List[Key] }

    pub def keysPath(): String = "assets/explore.keys.json"

    pub def defaultKeys(): Keys =
        { left = Key.Left :: Key.A :: Nil, right = Key.Right :: Key.D :: Nil, up = Key.Up :: Key.W :: Nil, down = Key.Down :: Key.S :: Nil }

    /// path のキーの割り当てを読む（読めない・欄が空なら、その操作だけ既定）。
    pub def loadKeys(p: String): Keys \ Fs.FileRead =
        DocJson.loadOr(text -> DocJson.decodeObject(keysOf, text), defaultKeys(), p)

    def keysOf(root: Map[String, Json]): Keys =
        let d = defaultKeys();
        { left = keysOr("left", d#left, root), right = keysOr("right", d#right, root), up = keysOr("up", d#up, root), down = keysOr("down", d#down, root) }

    def keysOr(field: String, fallback: List[Key], root: Map[String, Json]): List[Key] =
        Map.get(field, root)
            |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString))
            |> Option.map(InputMap.keysOf)
            |> Option.flatMap(keys -> if (List.isEmpty(keys)) None else Some(keys))
            |> Option.getWithDefault(fallback)
}
