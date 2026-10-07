// FxDoc — fx.json（閉形式パーティクル）を Spec（pure data）へ読み取るパース層。
// 粒の実体はどこにも保存せず、絵は Fx.sample が (Spec, seed, t) から毎回計算する
// （spawn も update も free も無い）。エラーはノードのパス付き（例: `at emitters[0].speed: ...`）
// で返す — UiDoc と同じ流儀。

pub mod FxDoc {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JString}
    use Util.Json.JsonError
    use DocJson.PathTag.Root

    // ========================================================================
    // 型（pure data）
    // ========================================================================

    /// 正規化寿命 u（0 = 生まれた瞬間, 1 = 消える瞬間）→ 倍率、のカーブ。
    /// レコードラベルの from/to は Flix の予約語なので内部名は fromV/toV。
    /// （中身がレコードだと Eq を derive できないため、テストは形ごとの値で確かめる）
    pub enum CurveSpec {
        /// いつでも 1.0（変化なし）。
        case Constant
        /// fromV から toV へまっすぐ変わる。
        case Linear({ fromV = Float64, toV = Float64 })
        /// u^power — ゆっくり始まって加速しながら 0 → 1。
        case EaseIn({ power = Float64 })
        /// (1-u)^power — 1 から始まり、速く出てだんだん弱まって 0 へ。
        case EaseOut({ power = Float64 })
        /// u = at で山（1.0）になる三角形（0 → 1 → 0）。ふくらんで縮む粒に。
        case Peak({ at = Float64 })
        /// 寿命あたり rate 回、1 から最大 amount ぶん暗くチラつく（決定論の疑似乱数）。
        case Flicker({ rate = Float64, amount = Float64 })
        /// 寿命あたり rate 回、1 と minV の間を正弦でなめらかに明滅する（u=0 は 1 から始まる）。
        /// flicker のガタつきと違い、蛍・信号灯のような「ふわっ」とした点滅に。
        /// JSON キーの min は Float64.min との紛れを避けて内部名は minV。
        case Pulse({ rate = Float64, minV = Float64 })
    }

    /// 粒の形。circle は直径 size の円、box は一辺 size の正方形。
    /// glow は直径 size の「縁がふわっと消える円」— 煙・光の玉のように、
    /// 円の輪郭を見せたくない粒に使う。
    /// streak はその時刻の速度の向きに伸びた筋（太さ = size・長さ = size + 速さ × stretch）—
    /// 雨・火花・流星のような「動きの跡が見える」粒に使う。
    pub enum Shape with Eq {
        case Circle
        case Box
        case Glow
        case Streak
    }

    /// 位置の正弦揺らぎ。粒はまっすぐ飛ぶ式しか持たないので、蛍のような「その場でゆらゆら」の
    /// 有界運動はこれが無いと作れない。amp が 0 なら足し算ごと省かれ、既存の絵は 1 ビットも動かない。
    pub type alias Wobble = {
        amp = Vec2.Vec2,   // 揺れ幅 px（軸ごと・0 で揺れない）
        freq = Vec2.Vec2,  // 揺れの速さ Hz（1 秒あたりの往復回数・軸ごと）
        vary = Float64     // 粒ごとの位相ばらつき 0..1（0 = 全粒そろって揺れる・1 = 1 周ぶん散る）
    }

    /// ばらつき付きの量。粒ごとに base × (1 ± vary) の範囲で決まり、
    /// over が寿命に沿った倍率を掛ける。
    pub type alias Scalar = { base = Float64, vary = Float64, over = CurveSpec }

    /// 射出方向の配り方。Random = 粒ごとに乱数で扇の中から引く（煙・火花）。
    /// Even = 粒の番号 i で扇を等分する（衝撃の輪・花火のように、粒が均等に並ぶ形）。
    pub enum DirMode with Eq {
        case Random
        case Even
    }

    /// 粒の生まれ方。Burst = 全粒が t=0 で同時に生まれて寿命で消える（爆発・木くず）。
    /// Loop = 各粒が寿命を終えるたびに生まれ直す（位相は粒ごとにずれる — 煙・雪・舞う葉の
    /// ような「出続ける」効果。周期 = 各粒の寿命）。どちらも t の純関数（保存しない）。
    pub enum Mode with Eq {
        case Burst
        case Loop
    }

    /// 粒の群れ 1 種類ぶんの宣言。既定は burst（全粒が t=0 で同時に生まれる）。
    pub type alias Emitter = {
        name = String,                              // 粒ごとの乱数の系統を分ける識別子
        count = Int32,                              // 粒の数
        mode = Mode,                                // 生まれ方（burst / loop）
        shape = Shape,                              // 粒の形
        size = Float64,                             // 粒の大きさ px（円は直径・箱は一辺）
        color = List[Color],                        // 寿命に沿った色グラデ（1 色以上）
        life = { base = Float64, vary = Float64 },  // 粒の寿命 秒
        speed = Scalar,                             // 初速 px/s（over が減速カーブ）
        dir = { base = Float64, spread = Float64, mode = DirMode }, // 射出方向 度（0 = 真上・時計回り）
        turn = { base = Float64, spread = Float64,  // 粒の傾き 回転数（1 周 = 1.0）
                 spin = Float64, spinSpread = Float64 }, // 回る速さ 回転数/秒
        spawnArea = { w = Float64, h = Float64 },   // 発生源の広がり px（原点中心の矩形・0 で点。JSON キーは "spawn"）
        accel = Vec2.Vec2,                          // 重力/風 px/s²（+y = 画面下向き・閉形式で積分）
        wobble = Wobble,                            // 位置の正弦揺らぎ（既定 amp 0 = 揺れない）
        stretch = Float64,                          // streak の尾の長さ 秒（長さ = size + 速さ × これ。shape が streak のときだけ効く）
        seed = Int32,                               // 決定的シードの上乗せ（同名 emitter を並べて別の絵にする）
        sizeOver = CurveSpec,                       // 大きさの倍率カーブ
        alphaOver = CurveSpec,                      // 透明度の倍率カーブ
        blend = DrawCmd.BlendMode,                  // 重ね方（add = 加算・multiply = 乗算）
        zIndex = Int32                              // 描画順
    }

    /// fx ドキュメント全体。duration を過ぎた時刻の sample は空になる。
    pub type alias Spec = {
        name = String,
        duration = Float64,
        note = Option[String],
        emitters = List[Emitter]
    }

    /// 何も出さない空の Spec。「まだ読み込めていない」「効果なし」の置き場に使う —
    /// Fx.sample は常に空を返し、duration 0 なので Fx.expire は即回収する。
    /// parse は duration > 0・emitters 1 個以上を要求する（空文書を弾く検査は正しい）ので、
    /// 空の値はここが手で作る。
    pub def empty(): Spec =
        { name = "empty", duration = 0.0, note = None, emitters = Nil }

    // ========================================================================
    // parse（純粋）
    // ========================================================================

    /// ドキュメント（version + name + duration + emitters）を Spec へ読み取る。
    /// 色は実色（"#rrggbb" 等）のみ — テーマの色キー（"@名前"）を使うときは parseWith。
    pub def parse(json: Json): Result[JsonError, Spec] =
        parseWith(Map.empty(), json)

    /// パレット付きの parse。emitter の color に "@名前" と書くと palette から解決する
    /// （ui.json の色方言と同一 — UiDoc.colorOf に一本化）。テーマ切替は「palette を
    /// 差し替えて parse し直す」だけ（Spec は pure data なので作り直しが安い）。
    pub def parseWith(palette: Map[String, Color], json: Json): Result[JsonError, Spec] =
        match json {
            case JObject(top) => forM (
                _v       <- DocJson.checkVersion("fx document", top);
                name     <- (DocJson.getAtKey(Root, "name", top): Result[JsonError, String]);
                duration <- DocJson.numAt("duration", top);
                _dur     <- require(duration > 0.0, "(top)", "duration must be > 0 (got: ${duration})");
                note     <- (DocJson.getAtKeyOpt(Root, "note", top): Result[JsonError, Option[String]]);
                emitters <- parseEmitters(palette, top)
            ) yield ({ name = name, duration = duration, note = note, emitters = emitters }: Spec)
            case _ => Err(DocJson.jsonError(Root, Set#{"FxDoc must be a JSON object with 'name', 'duration', 'emitters'"}))
        }

    def parseEmitters(palette: Map[String, Color], top: Map[String, Json]): Result[JsonError, List[Emitter]] =
        match Map.get("emitters", top) {
            case Some(JArray(arr)) =>
                if (Vector.isEmpty(arr))
                    Err(DocJson.jsonError(Root, Set#{"emitters must have at least 1 entry"}))
                else
                    Result.traverse(entry -> {
                        let (i, json) = entry;
                        forM (
                            m       <- DocJson.atNode("emitters[${i}]", DocJson.asObject("emitter", json));
                            emitter <- parseEmitter(palette, "emitters[${i}]", m)
                        ) yield emitter
                    }, List.zipWithIndex(Vector.toList(arr)))
            case _ => Err(DocJson.jsonError(Root, Set#{"'emitters' is required and must be an array"}))
        }

    /// 1 emitter を読む。エラーは "emitters[i]"（サブオブジェクトは "emitters[i].speed" 等）でタグする。
    def parseEmitter(palette: Map[String, Color], path: String, m: Map[String, Json]): Result[JsonError, Emitter] =
        forM (
            name      <- DocJson.atNode(path, (DocJson.getAtKey(Root, "name", m): Result[JsonError, String]));
            count     <- DocJson.atNode(path, (DocJson.getAtKey(Root, "count", m): Result[JsonError, Int32]));
            _cnt      <- require(count >= 1, path, "count must be >= 1 (got: ${count})");
            mode      <- parseMode(path, m);
            shape     <- parseShape(path, m);
            size      <- DocJson.atNode(path, DocJson.numAt("size", m));
            _size     <- require(size > 0.0, path, "size must be > 0 (got: ${size})");
            color     <- parseColors(palette, path, m);
            life      <- parseLife("${path}.life", m);
            speed     <- parseSpeed("${path}.speed", m);
            dir       <- parseDir("${path}.dir", m);
            turn      <- parseTurn("${path}.turn", m);
            spawnArea <- parseSpawn("${path}.spawn", m);
            accel     <- parseAccel("${path}.accel", m);
            wobble    <- parseWobble("${path}.wobble", m);
            stretch   <- parseStretch(path, m);
            seedOpt   <- DocJson.atNode(path, (DocJson.getAtKeyOpt(Root, "seed", m): Result[JsonError, Option[Int32]]));
            sizeOver  <- parseCurveAt("${path}.sizeOver", "sizeOver", m);
            alphaOver <- parseCurveAt("${path}.alphaOver", "alphaOver", m);
            blend     <- parseBlend(path, m);
            zIndexOpt <- DocJson.atNode(path, (DocJson.getAtKeyOpt(Root, "zIndex", m): Result[JsonError, Option[Int32]]))
        ) yield ({
            name = name, count = count, mode = mode, shape = shape, size = size, color = color,
            life = life, speed = speed, dir = dir, turn = turn,
            spawnArea = spawnArea, accel = accel, wobble = wobble, stretch = stretch,
            seed = Option.getWithDefault(0, seedOpt),
            sizeOver = sizeOver, alphaOver = alphaOver, blend = blend,
            zIndex = Option.getWithDefault(0, zIndexOpt)
        }: Emitter)

    /// "mode": "burst"（省略時）| "loop"。loop は粒が寿命ごとに生まれ直す（周期 = 寿命）。
    def parseMode(path: String, m: Map[String, Json]): Result[JsonError, Mode] =
        match (DocJson.getAtKeyOpt(Root, "mode", m): Result[JsonError, Option[String]]) {
            case Err(e)            => DocJson.atNode(path, Err(e))
            case Ok(None)          => Ok(Mode.Burst)
            case Ok(Some("burst")) => Ok(Mode.Burst)
            case Ok(Some("loop"))  => Ok(Mode.Loop)
            case Ok(Some(unknown)) =>
                DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{"mode must be burst|loop (got: ${unknown})"})))
        }

    /// "spawn": {"w": px, "h": px}（発生源の広がり・省略時は点 = {0, 0}）。
    def parseSpawn(path: String, m: Map[String, Json]): Result[JsonError, { w = Float64, h = Float64 }] =
        match (DocJson.getAtKeyOpt(Root, "spawn", m): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)       => DocJson.atNode(path, Err(e))
            case Ok(None)     => Ok({ w = 0.0, h = 0.0 })
            case Ok(Some(sm)) => forM (
                w  <- DocJson.atNode(path, DocJson.numOr("w", 0.0, sm));
                h  <- DocJson.atNode(path, DocJson.numOr("h", 0.0, sm));
                _w <- require(w >= 0.0 and h >= 0.0, path, "spawn w/h must be >= 0 (got: ${w}, ${h})")
            ) yield { w = w, h = h }
        }

    /// "accel": {"x": px/s², "y": px/s²}（重力/風・省略時は {0, 0}）。+y は画面下向き —
    /// 重力は y を正に、風は x に。位置には閉形式（½at²）で効く。
    def parseAccel(path: String, m: Map[String, Json]): Result[JsonError, Vec2.Vec2] =
        match (DocJson.getAtKeyOpt(Root, "accel", m): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)       => DocJson.atNode(path, Err(e))
            case Ok(None)     => Ok(Vec2.zero())
            case Ok(Some(am)) => forM (
                x <- DocJson.atNode(path, DocJson.numOr("x", 0.0, am));
                y <- DocJson.atNode(path, DocJson.numOr("y", 0.0, am))
            ) yield ({ x = x, y = y }: Vec2.Vec2)
        }

    /// "wobble": {"amp": {"x","y"} px, "freq": {"x","y"} Hz, "vary": 0..1}（省略時は揺れない）。
    /// 位置に正弦のオフセットを足す — 蛍・湯気のような「その場でゆらゆら」の有界運動を作る。
    def parseWobble(path: String, m: Map[String, Json]): Result[JsonError, Wobble] =
        match (DocJson.getAtKeyOpt(Root, "wobble", m): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)       => DocJson.atNode(path, Err(e))
            case Ok(None)     => Ok({ amp = Vec2.zero(), freq = Vec2.zero(), vary = 0.0 })
            case Ok(Some(wm)) => forM (
                amp  <- parseXYOr(path, "amp", wm);
                freq <- parseXYOr(path, "freq", wm);
                vary <- DocJson.atNode(path, DocJson.numOr("vary", 0.0, wm));
                _amp <- require(amp#x >= 0.0 and amp#y >= 0.0, path,
                                "wobble amp x/y must be >= 0 (got: ${amp#x}, ${amp#y})");
                _frq <- require(freq#x >= 0.0 and freq#y >= 0.0, path,
                                "wobble freq x/y must be >= 0 (got: ${freq#x}, ${freq#y})");
                _vry <- requireVary(path, vary)
            ) yield ({ amp = amp, freq = freq, vary = vary }: Wobble)
        }

    /// key の {"x": 数, "y": 数}（キー丸ごと・x/y の個別、どちらの省略も 0）。
    def parseXYOr(path: String, key: String, m: Map[String, Json]): Result[JsonError, Vec2.Vec2] =
        match (DocJson.getAtKeyOpt(Root, key, m): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)       => DocJson.atNode(path, Err(e))
            case Ok(None)     => Ok(Vec2.zero())
            case Ok(Some(xm)) => forM (
                x <- DocJson.atNode(path, DocJson.numOr("x", 0.0, xm));
                y <- DocJson.atNode(path, DocJson.numOr("y", 0.0, xm))
            ) yield ({ x = x, y = y }: Vec2.Vec2)
        }

    /// "stretch": streak の尾の長さ 秒。省略時 0.05 — 速さ 200px/s で尾が 10px になる、
    /// 雨・火花にそのまま使える見え方（0 だと尾が消えて streak を選んだ意味が無くなる）。
    def parseStretch(path: String, m: Map[String, Json]): Result[JsonError, Float64] =
        forM (
            v  <- DocJson.atNode(path, DocJson.numOr("stretch", 0.05, m));
            _v <- require(v >= 0.0, path, "stretch must be >= 0 (got: ${v})")
        ) yield v

    /// 条件が成り立たなければ path 付きで断る（値の下限・範囲の検査に使う）。
    def require(ok: Bool, path: String, msg: String): Result[JsonError, Unit] =
        if (ok) Ok(())
        else DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{msg})))

    def parseShape(path: String, m: Map[String, Json]): Result[JsonError, Shape] =
        match (DocJson.getAtKeyOpt(Root, "shape", m): Result[JsonError, Option[String]]) {
            case Err(e)              => DocJson.atNode(path, Err(e))
            case Ok(None)            => Ok(Shape.Circle)
            case Ok(Some("circle"))  => Ok(Shape.Circle)
            case Ok(Some("box"))     => Ok(Shape.Box)
            case Ok(Some("glow"))    => Ok(Shape.Glow)
            case Ok(Some("streak"))  => Ok(Shape.Streak)
            case Ok(Some(unknown))   =>
                DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{"shape must be circle|box|glow|streak (got: ${unknown})"})))
        }

    def parseBlend(path: String, m: Map[String, Json]): Result[JsonError, DrawCmd.BlendMode] =
        match (DocJson.getAtKeyOpt(Root, "blend", m): Result[JsonError, Option[String]]) {
            case Err(e)             => DocJson.atNode(path, Err(e))
            case Ok(None)           => Ok(DrawCmd.BlendMode.Normal)
            case Ok(Some("normal")) => Ok(DrawCmd.BlendMode.Normal)
            case Ok(Some("add"))    => Ok(DrawCmd.BlendMode.Add)
            case Ok(Some("multiply")) => Ok(DrawCmd.BlendMode.Multiply)
            case Ok(Some(unknown))  =>
                DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{"blend must be normal|add|multiply (got: ${unknown})"})))
        }

    /// "color": [<色>, ...]（1 色以上）。色表記は ui.json と同一（UiDoc.colorOf に一本化）。
    /// palette に有る名前は "@名前" で参照できる（テーマの色キー — parseWith 経由のみ）。
    def parseColors(palette: Map[String, Color], path: String, m: Map[String, Json]): Result[JsonError, List[Color]] =
        match Map.get("color", m) {
            case Some(JArray(arr)) =>
                if (Vector.isEmpty(arr))
                    DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{"color must have at least 1 entry"})))
                else
                    DocJson.atNode(path,
                        Result.traverse(c -> UiDoc.colorOf(palette, "color", c), Vector.toList(arr)))
            case Some(_) => DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{"color must be an array of colors"})))
            case None    => DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{"'color' is required"})))
        }

    /// "life": {"base": 秒, "vary": 0..1}（必須。vary 省略時 0）。
    def parseLife(path: String, m: Map[String, Json]): Result[JsonError, { base = Float64, vary = Float64 }] =
        match (DocJson.getAtKeyOpt(Root, "life", m): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)       => DocJson.atNode(path, Err(e))
            case Ok(None)     => DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{"'life' is required ({\"base\": seconds})"})))
            case Ok(Some(lm)) => forM (
                base  <- DocJson.atNode(path, DocJson.numAt("base", lm));
                vary  <- DocJson.atNode(path, DocJson.numOr("vary", 0.0, lm));
                _base <- require(base > 0.0, path, "base must be > 0 (got: ${base})");
                _vary <- requireVary(path, vary)
            ) yield { base = base, vary = vary }
        }

    /// "speed": {"base": px/s, "vary": 0..1, "over": <カーブ>}（省略時は動かない粒）。
    /// over に flicker は使えない — 位置 = 速度の積分が閉形式にならないため、パース時に断る。
    /// pulse も使えない — 明滅は明るさ・大きさの語彙で、速度に混ぜると意味が濁る。
    def parseSpeed(path: String, m: Map[String, Json]): Result[JsonError, Scalar] =
        match (DocJson.getAtKeyOpt(Root, "speed", m): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)       => DocJson.atNode(path, Err(e))
            case Ok(None)     => Ok({ base = 0.0, vary = 0.0, over = CurveSpec.Constant })
            case Ok(Some(sm)) => forM (
                base  <- DocJson.atNode(path, DocJson.numAt("base", sm));
                vary  <- DocJson.atNode(path, DocJson.numOr("vary", 0.0, sm));
                _vary <- requireVary(path, vary);
                over  <- parseCurveAt(path, "over", sm);
                _int  <- require(not isFlicker(over), path, "speed.over does not support flicker (position needs a closed-form integral)");
                _pls  <- require(not isPulse(over), path, "speed.over does not support pulse (pulse is for alphaOver/sizeOver)")
            ) yield { base = base, vary = vary, over = over }
        }

    def isFlicker(curve: CurveSpec): Bool =
        match curve { case CurveSpec.Flicker(_) => true case _ => false }

    def isPulse(curve: CurveSpec): Bool =
        match curve { case CurveSpec.Pulse(_) => true case _ => false }

    def requireVary(path: String, vary: Float64): Result[JsonError, Unit] =
        require(vary >= 0.0 and vary <= 1.0, path, "vary must be within 0..1 (got: ${vary})")

    /// "dir": {"base": 度, "spread": 度, "mode": "random"|"even"}（省略時は真上・広がりなし・乱数）。
    def parseDir(path: String, m: Map[String, Json]): Result[JsonError, { base = Float64, spread = Float64, mode = DirMode }] =
        match (DocJson.getAtKeyOpt(Root, "dir", m): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)       => DocJson.atNode(path, Err(e))
            case Ok(None)     => Ok({ base = 0.0, spread = 0.0, mode = DirMode.Random })
            case Ok(Some(dm)) => forM (
                base   <- DocJson.atNode(path, DocJson.numOr("base", 0.0, dm));
                spread <- DocJson.atNode(path, DocJson.numOr("spread", 0.0, dm));
                mode   <- parseDirMode(path, dm)
            ) yield { base = base, spread = spread, mode = mode }
        }

    /// "dir.mode": "random"（省略時）| "even"。even は粒の番号で扇を等分する。
    def parseDirMode(path: String, dm: Map[String, Json]): Result[JsonError, DirMode] =
        match (DocJson.getAtKeyOpt(Root, "mode", dm): Result[JsonError, Option[String]]) {
            case Err(e)             => DocJson.atNode(path, Err(e))
            case Ok(None)           => Ok(DirMode.Random)
            case Ok(Some("random")) => Ok(DirMode.Random)
            case Ok(Some("even"))   => Ok(DirMode.Even)
            case Ok(Some(unknown))  =>
                DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{"dir.mode must be random|even (got: ${unknown})"})))
        }

    /// "turn": {"base": 回転数, "spread": 回転数, "spin": 回転数/秒, "spinSpread": 回転数/秒}
    /// （省略時はすべて 0 = 回らない）。単位は回転数 — 1 周が 1.0。
    def parseTurn(path: String, m: Map[String, Json]): Result[JsonError, { base = Float64, spread = Float64, spin = Float64, spinSpread = Float64 }] =
        match (DocJson.getAtKeyOpt(Root, "turn", m): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)       => DocJson.atNode(path, Err(e))
            case Ok(None)     => Ok({ base = 0.0, spread = 0.0, spin = 0.0, spinSpread = 0.0 })
            case Ok(Some(tm)) => forM (
                base       <- DocJson.atNode(path, DocJson.numOr("base", 0.0, tm));
                spread     <- DocJson.atNode(path, DocJson.numOr("spread", 0.0, tm));
                spin       <- DocJson.atNode(path, DocJson.numOr("spin", 0.0, tm));
                spinSpread <- DocJson.atNode(path, DocJson.numOr("spinSpread", 0.0, tm));
                _s         <- require(spread >= 0.0 and spinSpread >= 0.0, path,
                                      "turn spread/spinSpread must be >= 0 (got: ${spread}, ${spinSpread})")
            ) yield { base = base, spread = spread, spin = spin, spinSpread = spinSpread }
        }

    /// key のカーブ（省略時 constant）。{"kind": "..."} の 7 形 + fadeOut 別名。
    def parseCurveAt(path: String, key: String, m: Map[String, Json]): Result[JsonError, CurveSpec] =
        match Map.get(key, m) {
            case None              => Ok(CurveSpec.Constant)
            case Some(JObject(cm)) => DocJson.atNode(path, parseCurveObj(cm))
            case Some(_)           =>
                DocJson.atNode(path, Err(DocJson.jsonError(Root, Set#{"${key} must be an object {\"kind\": ...}"})))
        }

    def parseCurveObj(cm: Map[String, Json]): Result[JsonError, CurveSpec] =
        forM (
            kind  <- (DocJson.getAtKey(Root, "kind", cm): Result[JsonError, String]);
            curve <- parseCurveKind(kind, cm)
        ) yield curve

    def parseCurveKind(kind: String, cm: Map[String, Json]): Result[JsonError, CurveSpec] =
        match kind {
            case "constant" => Ok(CurveSpec.Constant)
            case "linear"   => forM (
                fromV <- DocJson.numAt("from", cm);
                toV   <- DocJson.numAt("to", cm)
            ) yield CurveSpec.Linear({ fromV = fromV, toV = toV })
            case "fadeOut"  => Ok(CurveSpec.Linear({ fromV = 1.0, toV = 0.0 }))
            case "easeIn"   => DocJson.numOr("power", 2.0, cm) |> Result.map(p -> CurveSpec.EaseIn({ power = p }))
            case "easeOut"  => DocJson.numOr("power", 2.0, cm) |> Result.map(p -> CurveSpec.EaseOut({ power = p }))
            case "peak"     => DocJson.numAt("at", cm) |> Result.flatMap(at ->
                if (at < 0.0 or at > 1.0)
                    Err(DocJson.jsonError(Root, Set#{"peak 'at' must be within 0..1 (got: ${at})"}))
                else Ok(CurveSpec.Peak({ at = at })))
            case "flicker"  => forM (
                rate   <- DocJson.numAt("rate", cm);
                amount <- DocJson.numOr("amount", 1.0, cm)
            ) yield CurveSpec.Flicker({ rate = rate, amount = amount })
            case "pulse"    => forM (
                rate <- DocJson.numAt("rate", cm);
                minV <- DocJson.numOr("min", 0.0, cm);
                _min <- if (minV < 0.0 or minV > 1.0)
                            Err(DocJson.jsonError(Root, Set#{"pulse 'min' must be within 0..1 (got: ${minV})"}))
                        else Ok(())
            ) yield CurveSpec.Pulse({ rate = rate, minV = minV })
            case unknown    => Err(DocJson.jsonError(Root,
                Set#{"kind must be constant|linear|fadeOut|easeIn|easeOut|peak|flicker|pulse (got: ${unknown})"}))
        }
}
