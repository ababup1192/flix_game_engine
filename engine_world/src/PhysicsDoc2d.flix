// PhysicsDoc2d — 2D の物理の Doc（physics2d.kind.json）を読む codec。材質の表と World の設定を外に出し、保存すればその場で効かせる。
// 形:
//   { "version": 1,
//     "world": { "gravity": [0, 9.8], "solverSubsteps": 4, "sleepLinearThreshold": 0.01, "sleepAngularThreshold": 0.02 },
//     "materials": { "stone": { "friction": 0.6, "restitution": 0.1, "density": 2.0 } } }
// world の欄も world 自体も省けば既定（PhysicsWorld2d.settings()）。材質の欄は 3 つとも要る。刻みは出さない（App.withFixedStep の 1 か所）。
pub mod PhysicsDoc2d {
    use Util.Json.Json
    use Util.Json.Json.{JObject}
    use Util.Json.JsonError
    use DocJson.PathTag.Root

    /// 読んだ中身: World の設定と、名前 → 材質の表。
    pub type alias PhysicsDoc2d = { settings = PhysicsWorld2d.Settings, materials = Map[String, PhysicsMaterial.PhysicsMaterial] }

    /// Doc が無い時の中身（既定の設定・材質の表は空）。
    pub def default(): PhysicsDoc2d = { settings = PhysicsWorld2d.settings(), materials = Map.empty() }

    /// JSON を中身にする。摩擦・跳ね返りが負・密度が 0 以下・NaN、solverSubsteps が 1 未満は Err（どの欄か付きで）。
    pub def parse(json: Json): Result[JsonError, PhysicsDoc2d] = match json {
        case JObject(top) => forM (
            _v        <- DocJson.checkVersion("physics2d document", top);
            settings  <- parseWorld(top);
            materials <- parseMaterials(top)
        ) yield { settings = settings, materials = materials }
        case _ => Err(DocJson.jsonError(Root, Set#{"physics2d document must be a JSON object"}))
    }

    /// path を読んで中身にする（読めない・崩れている・値が使えない時は Err）。
    pub def load(path: String): Result[JsonError, PhysicsDoc2d] \ Fs.FileRead =
        DocJson.readJson(path) |> Result.flatMap(parse)

    /// path を読んで中身にする。無ければ黙って既定、有るのに読めない・値が使えない時は既定で続けて 1 行言う。
    pub def loadOr(path: String): PhysicsDoc2d \ Fs.FileRead =
        DocJson.loadOr(text -> decodeText(path, text), default(), path)

    def decodeText(path: String, text: String): Option[PhysicsDoc2d] =
        DocJson.parse(text) |> Option.flatMap(json -> match parse(json) {
            case Ok(doc) => Some(doc)
            case Err(e) => Log.warnThen("[PhysicsDoc2d] ${path}: ${DocJson.describe(e)}", None)
        })

    /// 中身を物理の World へ当てる（設定と材質の表。もう居る体にも次の刻みから効く）。
    pub def applyTo(doc: PhysicsDoc2d, w: PhysicsWorld2d.PhysicsWorld2d): PhysicsWorld2d.PhysicsWorld2d =
        w |> PhysicsWorld2d.withSettings(doc#settings) |> PhysicsWorld2d.withMaterials(doc#materials)

    def require(ok: Bool, msg: String): Result[JsonError, Unit] =
        if (ok) Ok(()) else Err(DocJson.jsonError(Root, Set#{msg}))

    def isFinite(x: Float64): Bool = not Float64.isNan(x) and not Float64.isInfinite(x)

    def parseWorld(top: Map[String, Json]): Result[JsonError, PhysicsWorld2d.Settings] =
        let base = PhysicsWorld2d.settings();
        match Map.get("world", top) {
            case None => Ok(base)
            case Some(json) => forM (
                m        <- DocJson.atNode("world", DocJson.asObject("world", json));
                gravity  <- DocJson.atNode("world", parseGravity(base#gravity, m));
                substeps <- DocJson.atNode("world", DocJson.numOr("solverSubsteps", Int32.toFloat64(base#solverSubsteps), m));
                linear   <- DocJson.atNode("world", DocJson.numOr("sleepLinearThreshold", base#sleepLinearThreshold, m));
                angular  <- DocJson.atNode("world", DocJson.numOr("sleepAngularThreshold", base#sleepAngularThreshold, m));
                _s       <- require(substeps >= 1.0 and substeps <= 64.0 and Float64.floor(substeps) == substeps,
                                    "world.solverSubsteps must be a whole number within 1..64 (got: ${substeps})");
                _f       <- require(isFinite(gravity#x) and isFinite(gravity#y) and isFinite(linear) and isFinite(angular),
                                    "world: gravity and sleep thresholds must be finite numbers")
            ) yield { gravity = gravity, solverSubsteps = Float64.tryToInt32(substeps) |> Option.getWithDefault(base#solverSubsteps),
                      sleepLinearThreshold = linear, sleepAngularThreshold = angular }
        }

    def parseGravity(fallback: Vec2.Vec2, m: Map[String, Json]): Result[JsonError, Vec2.Vec2] =
        match (DocJson.getAtKeyOpt(Root, "gravity", m): Result[JsonError, Option[List[Float64]]]) {
            case Err(e) => Err(e)
            case Ok(None) => Ok(fallback)
            case Ok(Some(x :: y :: Nil)) => Ok({ x = x, y = y })
            case Ok(Some(_)) => Err(DocJson.jsonError(Root, Set#{"gravity must be [x, y]"}))
        }

    def parseMaterials(top: Map[String, Json]): Result[JsonError, Map[String, PhysicsMaterial.PhysicsMaterial]] =
        match Map.get("materials", top) {
            case None => Ok(Map.empty())
            case Some(json) => forM (
                m       <- DocJson.atNode("materials", DocJson.asObject("materials", json));
                entries <- Result.traverse(entry -> parseMaterial(fst(entry), snd(entry)), Map.toList(m))
            ) yield List.toMap(entries)
        }

    def parseMaterial(name: String, json: Json): Result[JsonError, (String, PhysicsMaterial.PhysicsMaterial)] =
        let at = "materials.${name}";
        forM (
            m           <- DocJson.atNode(at, DocJson.asObject("material", json));
            friction    <- DocJson.atNode(at, DocJson.numAt("friction", m));
            restitution <- DocJson.atNode(at, DocJson.numAt("restitution", m));
            density     <- DocJson.atNode(at, DocJson.numAt("density", m));
            _ok         <- require(PhysicsMaterial.isValid({ friction = friction, restitution = restitution, density = density }),
                                   "${at}: friction and restitution must be >= 0 and density > 0 (got: ${friction}, ${restitution}, ${density})")
        ) yield (name, { friction = friction, restitution = restitution, density = density })
}
