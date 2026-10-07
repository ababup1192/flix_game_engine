// HitDoc — 当たりの形の宣言（hitbox.json）を読む codec。形の型（Hit.HitShape）は幾何側が持ち、
// ここは JSON との往復だけ。間違いはキーと位置付き（hit.player[0] など）で loud に断る。

pub mod HitDoc {
    use Hit.HitShape
    use Util.Json.Json
    use Util.Json.JsonError
    use DocJson.PathTag.Root

    /// 名前 → 形の列。hitbox.json の "hit" と同じ形。
    pub type alias Sheet = Map[String, List[HitShape]]

    /// 形の種類の一覧。parse の unknown エラーが同じ表を見る。
    pub def shapeKinds(): List[String] =
        "circle" :: "box" :: Nil

    /// sheet の欠け（必須キーが無い・どのキーでも形が 0 個）を列挙する（空なら欠けなし）。
    /// 必須キーの表はゲームが渡す — エンジンはドメインのキー名を知らない。
    pub def gaps(required: List[String], sheet: Sheet): List[String] =
        let missing = required |> List.filterMap(key -> gapOf(key, sheet));
        let emptyExtras = sheet
            |> Map.toList
            |> List.filterMap(entry -> {
                let (key, shapes) = entry;
                if (List.isEmpty(shapes) and not List.memberOf(key, required))
                    Some("hitbox.json: hit '${key}' must have at least 1 shape")
                else None
            });
        List.append(missing, emptyExtras)

    /// キー 1 個の欠けの理由（無ければ None）。形 0 個は「当たらないゲーム」を黙って作るので欠け扱い。
    def gapOf(key: String, sheet: Sheet): Option[String] =
        match Map.get(key, sheet) {
            case None      => Some("hitbox.json: hit '${key}' is required")
            case Some(Nil) => Some("hitbox.json: hit '${key}' must have at least 1 shape")
            case Some(_)   => None
        }

    /// リロードの適用: 読めて欠けも無いときだけ差し替え、壊れていれば今の sheet を守る。
    pub def reloaded(required: List[String], loaded: Result[JsonError, Sheet], current: Sheet): Sheet =
        loaded
            |> Result.toOption
            |> Option.filter(sheet -> List.isEmpty(gaps(required, sheet)))
            |> Option.getWithDefault(current)

    /// キーの形を引く。無ければ空 = 何にも当たらない（欠けは gaps が起動時に報せる）。
    pub def shapesOf(key: String, sheet: Sheet): List[HitShape] =
        Map.getWithDefault(key, Nil, sheet)

    // ── parse（純粋） ──

    /// hitbox.json 全体を Sheet にする（version 確認 + "hit" の名前 → 形の列）。
    pub def parse(json: Json): Result[JsonError, Sheet] =
        forM (
            top   <- DocJson.asObject("hitbox", json);
            _v    <- DocJson.checkVersion("hitbox", top);
            sheet <- DocJson.sheetAt("hit", parseShape, top)
        ) yield sheet

    /// 形 1 個を読む。"shape" で種類を選び、寸法は種類ごとに読む。
    def parseShape(json: Json): Result[JsonError, HitShape] =
        forM (
            m     <- DocJson.asObject("shape", json);
            kind  <- (DocJson.getAtKey(Root, "shape", m): Result[JsonError, String]);
            shape <- parseKind(kind, m)
        ) yield shape

    /// 種類ごとの寸法読み。知らない種類は known の一覧付きで断る。
    def parseKind(kind: String, m: Map[String, Json]): Result[JsonError, HitShape] =
        match kind {
            case "circle" => forM (
                dx <- DocJson.numAt("dx", m); dy <- DocJson.numAt("dy", m);
                r  <- positiveAt("r", m)
            ) yield HitShape.CircleH({ dx = dx, dy = dy, r = r })
            case "box" => forM (
                dx <- DocJson.numAt("dx", m); dy <- DocJson.numAt("dy", m);
                w  <- positiveAt("w", m); h <- positiveAt("h", m)
            ) yield HitShape.BoxH({ dx = dx, dy = dy, w = w, h = h })
            case unknown =>
                Err(DocJson.jsonError(Root, Set#{
                    "unknown shape '${unknown}' (known: ${String.intercalate(", ", shapeKinds())})"}))
        }

    /// key の数値（0 より大きいこと）。負・ゼロの寸法は判定が黙って縮む・消えるので断る。
    def positiveAt(key: String, m: Map[String, Json]): Result[JsonError, Float64] =
        DocJson.numAt(key, m) |> Result.flatMap(v ->
            if (v > 0.0) Ok(v)
            else Err(DocJson.jsonError(Root, Set#{"${key} must be positive (got ${v})"})))

    // ── load（IO はここだけ） ──

    /// path を読んで Sheet にする。読めない・崩れているときは位置付きの Err。
    pub def load(path: String): Result[JsonError, Sheet] \ Fs.FileRead =
        DocJson.readJson(path) |> Result.flatMap(json -> parse(json))

    /// 起動時用: 読めない・必須キーの欠落は bug! で起動を止めて loud に知らせる。
    pub def loadOrBug(path: String, required: List[String]): Sheet \ Fs.FileRead =
        match load(path) {
            case Ok(sheet) => checkGaps(required, sheet)
            case Err(e)    => bug!("hitbox: ${DocJson.describe(e)}")
        }

    /// 欠けが無ければそのまま返し、有れば bug! で止める。
    def checkGaps(required: List[String], sheet: Sheet): Sheet =
        match gaps(required, sheet) {
            case Nil  => sheet
            case msgs => bug!("hitbox: ${String.intercalate(" / ", msgs)}")
        }
}
