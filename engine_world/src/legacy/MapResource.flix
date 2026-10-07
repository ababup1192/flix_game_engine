// MapResource — 旧世代（Resource 方言）のタイルマップ層。新しく作るゲームは Material / TerrainDoc / DualGrid を使う。
// タイルマップの Resource 群。マップ実体 `Level` と素材 `Material` を分けて持ち、
// 同じ間取りを別 Material に差し替えて複数テーマで再生できる (`Level` は `materialId` で参照)。
// 自動壁は decorTiles (床) のセルから動的に決まる: 床が無く 8 近傍に床があるセルを壁として扱う。
pub mod MapResource {

    /// Level の中身。フィールドの集合はここに集約し、enum 経由で持ち回す。
    /// - `manualTiles` は Walls 層由来 (自動壁の上書き、衝突は持たない)
    /// - `decorTiles`  は Floor 層由来 (床、=通行可、=自動壁の判定源)
    /// - `editorPalette` は IDE エディタ専用の Palette 設定 (Sheet 名 / cellSize / margin)。
    ///   ゲームランタイム (MapLoader 等) は無視する。Map ごとに別の設定を持たせるため。
    /// - `intGrid` は AutoRule マッチング用の整数グリッド (width × height, 行優先)。
    ///   0=空, 1=床, 2=自動壁。decorTiles + 自動壁判定から load 時に再生成される派生データ。
    ///   保存時に省略可 (load 時に再構築されるため)。将来 3=水, 4=溶岩 等を予約。
    /// LDtk は Walls と Floor が別 tileset を使う構成のため、層を分けて保持する。
    pub type alias LevelData = {
        tileSize      = Int32,
        width         = Int32,
        height        = Int32,
        materialId    = String,
        manualTiles   = List[ManualTile],
        decorTiles    = List[ManualTile],
        entities      = List[Entity],
        editorPalette = Option[EditorPalette],
        intGrid       = Vector[Int32]
    }

    /// IDE Maps タブの Palette 設定 (Floor / Walls 各層)。
    /// `.map.json` 内に書かれることで Map 切替時に復元される。
    pub type alias EditorPalette = {
        floor = EditorLayerPalette,
        walls = EditorLayerPalette
    }

    /// 1 レイヤー分の Palette 設定。
    pub type alias EditorLayerPalette = {
        textureName = Option[String],
        cellW       = Int32,
        cellH       = Int32,
        marginX     = Int32,
        marginY     = Int32
    }

    /// `Saveable[Level]` を実装可能にするための単一 case ラッパ。
    pub enum Level {
        case Level(LevelData)
    }

    /// `Level` から内部の record を取り出す。
    pub def levelData(l: Level): LevelData =
        let Level.Level(d) = l; d

    /// 描画タイル 1 枚の記述。autotile の上書きにも、autotile 無しの素描画にも使う。
    /// `srcX` / `srcY` は tileset PNG 上のピクセル位置 (LDtk の autoLayerTiles.src 由来)。
    /// tileset の spacing / margin を持つテクスチャでも正確に復元できるようピクセル単位で保存する。
    /// flipH / flipV は LDtk 由来のタイル flip を保持。JSON では false の場合に出力しない。
    pub type alias ManualTile = {
        x     = Int32,
        y     = Int32,
        srcX  = Int32,
        srcY  = Int32,
        flipH = Bool,
        flipV = Bool
    }

    pub type alias Entity = {
        identifier = String,
        x          = Int32,
        y          = Int32,
        fields     = Map[String, FieldValue]
    }

    /// Entity の custom field 値。文字列 / 整数 / Bool の 3 種類だけ MVP で扱う。
    /// JSON は単一キー判別 (`{"string":...}` / `{"int":...}` / `{"bool":...}`)。
    pub enum FieldValue with Eq, ToString {
        case StringV(String)
        case IntV(Int32)
        case BoolV(Bool)
    }

    /// Material の中身。
    ///   tileSize : tileset PNG 上の 1 タイルの px (正方形前提)
    ///   autoRules: ldtk 風の AutoRule リスト。各セルの周辺パターンマッチで出力タイルを決める
    /// タイルの切り抜きサイズ / マージン / Palette ズームは IDE 側 Walls Palette と共有する。
    pub type alias MaterialData = {
        tileset      = String,
        tileSize     = Int32,
        wallMap      = Map[String, (Int32, Int32)],
        floorPalette = List[(Int32, Int32)],
        decorPalette = List[(Int32, Int32)],
        autoRules    = List[AutoRule]
    }

    /// AutoRule の pattern セル 1 個の値。LDtk の 5 値セマンティクスに揃える。
    ///   Unspecified : マッチ条件なし (中央 = 出力位置もこれ)
    ///   Anything    : IntGrid 値 != 0 を要求 (何か存在する)
    ///   Nothing     : IntGrid 値 == 0 を要求 (空セル限定)
    ///   Value(n)    : IntGrid 値 == n を要求
    ///   NotValue(n) : IntGrid 値 != n を要求
    pub enum PatternCell with Eq, ToString {
        case Unspecified
        case Anything
        case Nothing
        case Value(Int32)
        case NotValue(Int32)
    }

    /// AutoRule: パターンマッチで wallMap の上に重ねる装飾タイルを決める。
    ///   size    : 3 or 5
    ///   pattern : size * size 要素 (行優先)、各セルは PatternCell
    ///   srcX/Y  : 出力タイルの tileset 上の座標 (中央セル位置に配置)
    pub type alias AutoRule = {
        name    = String,
        size    = Int32,
        pattern = Vector[PatternCell],
        srcX    = Int32,
        srcY    = Int32
    }

    /// `Saveable[Material]` を実装可能にするための単一 case ラッパ。
    pub enum Material {
        case Material(MaterialData)
    }

    /// `Material` から内部の record を取り出す。
    pub def materialData(m: Material): MaterialData =
        let Material.Material(d) = m; d

    /// "TRBL" 4-bit 文字列キーの完全集合 (フォールバック用)。
    pub def wallMapKeys(): List[String] =
        "0000" :: "0001" :: "0010" :: "0011" ::
        "0100" :: "0101" :: "0110" :: "0111" ::
        "1000" :: "1001" :: "1010" :: "1011" ::
        "1100" :: "1101" :: "1110" :: "1111" :: Nil

    /// PatternCell と intGrid 値 1 個の整合性を判定する。
    pub def patternCellMatches(cell: PatternCell, intGridValue: Int32): Bool =
        match cell {
            case PatternCell.Unspecified => true
            case PatternCell.Anything    => intGridValue != 0i32
            case PatternCell.Nothing     => intGridValue == 0i32
            case PatternCell.Value(n)    => intGridValue == n
            case PatternCell.NotValue(n) => intGridValue != n
        }

    /// rule#pattern をセル `(col, row)` を中央として intGrid と照合する。
    /// 長さが size*size より短い場合は不足分を Unspecified として扱う。
    /// 境界外は intGridAt が 0 を返すため Nothing マッチに一致する。
    pub def ruleMatches(intGrid: Vector[Int32], width: Int32, height: Int32,
                          col: Int32, row: Int32, rule: AutoRule): Bool =
        let size = rule#size;
        let half = size / 2;
        let n = size * size;
        List.range(0, n)
            |> List.forAll(idx -> {
                let pc = Int32.remainder(idx, size);
                let pr = idx / size;
                let cc = col + pc - half;
                let cr = row + pr - half;
                let cellVal = intGridAt(intGrid, width, height, cc, cr);
                let want = match Vector.nth(idx, rule#pattern) {
                    case Some(v) => v
                    case None    => PatternCell.Unspecified
                };
                patternCellMatches(want, cellVal)
            })

    /// intGrid の `(col, row)` 値を返す。境界外は 0 (空セル扱い)。
    pub def intGridAt(intGrid: Vector[Int32], width: Int32, height: Int32,
                        col: Int32, row: Int32): Int32 =
        if (col < 0 or col >= width or row < 0 or row >= height) 0i32
        else match Vector.nth(row * width + col, intGrid) {
            case Some(v) => v
            case None    => 0i32
        }
}

// ════════════════════════════════════════════════════════════════════════
// Saveable instance — round-trip JSON
// ════════════════════════════════════════════════════════════════════════

instance Saveable[MapResource.Level] {
    pub def toJson(value: MapResource.Level): Util.Json.Json =
        MapResourceCodec.encodeLevel(value)

    pub def fromJson(element: Util.Json.Json): Option[MapResource.Level] =
        MapResourceCodec.decodeLevel(element)
}

instance Saveable[MapResource.Material] {
    pub def toJson(value: MapResource.Material): Util.Json.Json =
        MapResourceCodec.encodeMaterial(value)

    pub def fromJson(element: Util.Json.Json): Option[MapResource.Material] =
        MapResourceCodec.decodeMaterial(element)
}

instance Saveable[MapResource.FieldValue] {
    pub def toJson(value: MapResource.FieldValue): Util.Json.Json =
        MapResourceCodec.encodeFieldValue(value)

    pub def fromJson(element: Util.Json.Json): Option[MapResource.FieldValue] =
        MapResourceCodec.decodeFieldValue(element)
}

/// MapResource の JSON エンコード／デコード本体。
/// 外部からは `Saveable[...]` 経由でしか触らない想定。
mod MapResourceCodec {
    import java.math.{BigDecimal => JBigDecimal}

    use Util.Json.Json
    use Util.Json.Json.{JObject, JString, JNumber, JBool, JArray}
    use MapResource.{Level, LevelData, ManualTile, Entity, FieldValue, Material, MaterialData, EditorPalette, EditorLayerPalette, AutoRule, PatternCell}

    // ── Level ──

    pub def encodeLevel(l: Level): Json =
        let d = MapResource.levelData(l);
        let base = Map#{
            "tileSize"    => JNumber(intToBd(d#tileSize)),
            "width"       => JNumber(intToBd(d#width)),
            "height"      => JNumber(intToBd(d#height)),
            "materialId"  => JString(d#materialId),
            "manualTiles" => JArray(d#manualTiles |> List.map(encodeManualTile) |> List.toVector),
            "entities"    => JArray(d#entities    |> List.map(encodeEntity)     |> List.toVector)
        };
        // decorTiles は空なら省略 (後方互換: 既存 .map.json に decorTiles キーが無くても decode 可)
        let withDecor = if (List.isEmpty(d#decorTiles)) base
                        else Map.insert("decorTiles",
                            JArray(d#decorTiles |> List.map(encodeManualTile) |> List.toVector),
                            base);
        // editorPalette は None なら省略
        let withEditor = match d#editorPalette {
            case None    => withDecor
            case Some(p) => Map.insert("editorPalette", encodeEditorPalette(p), withDecor)
        };
        // intGrid は load 時に再構築されるため、保存は省略 (毎回 decorTiles から再生成)
        JObject(withEditor)

    pub def decodeLevel(element: Json): Option[Level] =
        forM (
            obj           <- expectObject(element);
            tileSizeJ     <- Map.get("tileSize",    obj);
            widthJ        <- Map.get("width",       obj);
            heightJ       <- Map.get("height",      obj);
            materialIdJ   <- Map.get("materialId",  obj);
            manualTilesJ  <- Map.get("manualTiles", obj);
            entitiesJ     <- Map.get("entities",    obj);
            tileSize      <- expectInt(tileSizeJ);
            width         <- expectInt(widthJ);
            height        <- expectInt(heightJ);
            materialId    <- expectString(materialIdJ);
            manualTiles   <- decodeList(decodeManualTile, manualTilesJ);
            entities      <- decodeList(decodeEntity,     entitiesJ);
            // decorTiles は省略可能 (デフォルト Nil)
            decorTiles    <- match Map.get("decorTiles", obj) {
                case None     => Some((Nil: List[ManualTile]))
                case Some(dj) => decodeList(decodeManualTile, dj)
            }
            // 旧 wallMask キーがあっても無視 (前方互換)
        ) yield {
            // editorPalette は省略可能 (デフォルト None)
            let editorPalette = match Map.get("editorPalette", obj) {
                case None    => None
                case Some(e) => decodeEditorPalette(e)
            };
            Level.Level(({
                tileSize      = tileSize,
                width         = width,
                height        = height,
                materialId    = materialId,
                manualTiles   = manualTiles,
                decorTiles    = decorTiles,
                entities      = entities,
                editorPalette = editorPalette,
                intGrid       = (Vector#{}: Vector[Int32])
            }: LevelData))
        }

    // ── EditorPalette ──

    def encodeEditorPalette(p: EditorPalette): Json =
        JObject(Map#{
            "floor" => encodeEditorLayerPalette(p#floor),
            "walls" => encodeEditorLayerPalette(p#walls)
        })

    def decodeEditorPalette(element: Json): Option[EditorPalette] =
        forM (
            obj   <- expectObject(element);
            floorJ <- Map.get("floor", obj);
            wallsJ <- Map.get("walls", obj);
            floor  <- decodeEditorLayerPalette(floorJ);
            walls  <- decodeEditorLayerPalette(wallsJ)
        ) yield ({floor = floor, walls = walls}: EditorPalette)

    def encodeEditorLayerPalette(lp: EditorLayerPalette): Json = {
        let base = Map#{
            "cellW"   => JNumber(intToBd(lp#cellW)),
            "cellH"   => JNumber(intToBd(lp#cellH)),
            "marginX" => JNumber(intToBd(lp#marginX)),
            "marginY" => JNumber(intToBd(lp#marginY))
        };
        let withTex = match lp#textureName {
            case None    => base
            case Some(n) => Map.insert("textureName", JString(n), base)
        };
        JObject(withTex)
    }

    def decodeEditorLayerPalette(element: Json): Option[EditorLayerPalette] =
        forM (
            obj   <- expectObject(element);
            cellWJ <- Map.get("cellW", obj);
            cellHJ <- Map.get("cellH", obj);
            cellW  <- expectInt(cellWJ);
            cellH  <- expectInt(cellHJ)
        ) yield {
            let marginX = match Map.get("marginX", obj) {
                case Some(j) => match expectInt(j) { case Some(v) => v case None => 0 }
                case None    => 0
            };
            let marginY = match Map.get("marginY", obj) {
                case Some(j) => match expectInt(j) { case Some(v) => v case None => 0 }
                case None    => 0
            };
            let textureName = match Map.get("textureName", obj) {
                case Some(JString(s)) => Some(s)
                case _                   => None
            };
            ({textureName = textureName, cellW = cellW, cellH = cellH,
              marginX = marginX, marginY = marginY}: EditorLayerPalette)
        }

    // ── ManualTile ──

    def encodeManualTile(t: ManualTile): Json =
        let base = Map#{
            "x"    => JNumber(intToBd(t#x)),
            "y"    => JNumber(intToBd(t#y)),
            "srcX" => JNumber(intToBd(t#srcX)),
            "srcY" => JNumber(intToBd(t#srcY))
        };
        let withH = if (t#flipH) Map.insert("flipH", JBool(true), base) else base;
        let withV = if (t#flipV) Map.insert("flipV", JBool(true), withH) else withH;
        JObject(withV)

    def decodeManualTile(element: Json): Option[ManualTile] =
        forM (
            obj   <- expectObject(element);
            xJ    <- Map.get("x",    obj);
            yJ    <- Map.get("y",    obj);
            sxJ   <- Map.get("srcX", obj);
            syJ   <- Map.get("srcY", obj);
            x     <- expectInt(xJ);
            y     <- expectInt(yJ);
            srcX  <- expectInt(sxJ);
            srcY  <- expectInt(syJ)
        ) yield {
            let flipH = match Map.get("flipH", obj) {
                case Some(JBool(b)) => b
                case _                 => false
            };
            let flipV = match Map.get("flipV", obj) {
                case Some(JBool(b)) => b
                case _                 => false
            };
            ({x = x, y = y, srcX = srcX, srcY = srcY, flipH = flipH, flipV = flipV}: ManualTile)
        }

    // ── Entity ──

    def encodeEntity(e: Entity): Json =
        JObject(Map#{
            "identifier" => JString(e#identifier),
            "x"          => JNumber(intToBd(e#x)),
            "y"          => JNumber(intToBd(e#y)),
            "fields"     => encodeFieldsMap(e#fields)
        })

    def decodeEntity(element: Json): Option[Entity] =
        forM (
            obj          <- expectObject(element);
            identifierJ  <- Map.get("identifier", obj);
            xJ           <- Map.get("x",          obj);
            yJ           <- Map.get("y",          obj);
            fieldsJ      <- Map.get("fields",     obj);
            identifier   <- expectString(identifierJ);
            x            <- expectInt(xJ);
            y            <- expectInt(yJ);
            fields       <- decodeFieldsMap(fieldsJ)
        ) yield ({identifier = identifier, x = x, y = y, fields = fields}: Entity)

    def encodeFieldsMap(m: Map[String, FieldValue]): Json =
        let inner = m
            |> Map.foldLeftWithKey((acc, name, v) ->
                Map.insert(name, encodeFieldValue(v), acc),
                Map.empty());
        JObject(inner)

    def decodeFieldsMap(element: Json): Option[Map[String, FieldValue]] =
        forM (
            obj <- expectObject(element);
            res <- Map.foldLeftWithKey((acc, name, json) ->
                       Option.flatMap(soFar ->
                           decodeFieldValue(json) |> Option.map(v -> Map.insert(name, v, soFar)),
                           acc),
                       Some(Map.empty()),
                       obj)
        ) yield res

    // ── FieldValue ──

    pub def encodeFieldValue(v: FieldValue): Json = match v {
        case FieldValue.StringV(s) => JObject(Map#{"string" => JString(s)})
        case FieldValue.IntV(i)    => JObject(Map#{"int"    => JNumber(intToBd(i))})
        case FieldValue.BoolV(b)   => JObject(Map#{"bool"   => JBool(b)})
    }

    pub def decodeFieldValue(element: Json): Option[FieldValue] =
        forM (
            obj  <- expectObject(element);
            pair <- singleEntry(obj);
            fv   <- match pair {
                case ("string", JString(s)) => Some(FieldValue.StringV(s))
                case ("int",    j)             => expectInt(j)  |> Option.map(FieldValue.IntV)
                case ("bool",   JBool(b))   => Some(FieldValue.BoolV(b))
                case _                         => None
            }
        ) yield fv

    // ── Material ──

    pub def encodeMaterial(m: Material): Json =
        let d = MapResource.materialData(m);
        let base = Map#{
            "tileset"      => JString(d#tileset),
            "tileSize"     => JNumber(intToBd(d#tileSize)),
            "wallMap"      => encodeWallMap(d#wallMap),
            "floorPalette" => encodeCoordList(d#floorPalette),
            "decorPalette" => encodeCoordList(d#decorPalette)
        };
        let withRules = if (List.isEmpty(d#autoRules)) base
                        else Map.insert("autoRules",
                            JArray(d#autoRules |> List.map(encodeAutoRule) |> List.toVector),
                            base);
        JObject(withRules)

    pub def decodeMaterial(element: Json): Option[Material] =
        forM (
            obj            <- expectObject(element);
            tilesetJ       <- Map.get("tileset",      obj);
            tileSizeJ      <- Map.get("tileSize",     obj);
            wallMapJ       <- Map.get("wallMap",      obj);
            floorJ         <- Map.get("floorPalette", obj);
            decorJ         <- Map.get("decorPalette", obj);
            tileset        <- expectString(tilesetJ);
            tileSize       <- expectInt(tileSizeJ);
            wallMap        <- decodeWallMap(wallMapJ);
            floorPalette   <- decodeCoordList(floorJ);
            decorPalette   <- decodeCoordList(decorJ);
            // autoRules は省略可 (デフォルト Nil)
            autoRules      <- match Map.get("autoRules", obj) {
                case None     => Some((Nil: List[AutoRule]))
                case Some(rj) => decodeList(decodeAutoRule, rj)
            }
        ) yield Material.Material(({
            tileset      = tileset,
            tileSize     = tileSize,
            wallMap      = wallMap,
            floorPalette = floorPalette,
            decorPalette = decorPalette,
            autoRules    = autoRules
        }: MaterialData))

    // ── AutoRule ──

    /// pattern セル値の JSON 表現 (LDtk と数値は揃えるが互換目的ではない):
    ///   Unspecified → 0
    ///   Anything    → 1000001
    ///   Nothing     → -1000001
    ///   Value(n)    → n  (n >= 1)
    ///   NotValue(n) → -n (n >= 1)
    def anythingMagic(): Int32 = 1000001i32
    def nothingMagic(): Int32 = -1000001i32

    /// AutoRule JSON のバージョン。v フィールドが無い、または v<2 の JSON は pattern の値域が
    /// {-1, 0, 1, 2} (-1=装飾中央, 0=任意, 1=床, 2=壁) なので、decode 時に `2` を NotValue(1)、
    /// `-1` を Unspecified に読み替える。v>=2 は 5 値 ADT (Unspecified/Anything/Nothing/Value/
    /// NotValue) をそのままマッピングした値。
    def currentAutoRuleVersion(): Int32 = 2i32

    def encodePatternCell(c: PatternCell): Int32 = match c {
        case PatternCell.Unspecified => 0i32
        case PatternCell.Anything    => anythingMagic()
        case PatternCell.Nothing     => nothingMagic()
        case PatternCell.Value(n)    => n
        case PatternCell.NotValue(n) => -n
    }

    /// `version` が None または 2 未満の JSON では `2` を NotValue(1)、`-1` を Unspecified に
    /// 読み替える。2 以上では magic number ベースの素直なマッピングになる。
    def decodePatternCell(version: Option[Int32], n: Int32): PatternCell =
        let isLegacy = match version {
            case None    => true
            case Some(v) => v < 2i32
        };
        if (n == 0i32) PatternCell.Unspecified
        else if (n == anythingMagic()) PatternCell.Anything
        else if (n == nothingMagic()) PatternCell.Nothing
        else if (isLegacy and n == -1i32) PatternCell.Unspecified  // 旧: 装飾中央
        else if (isLegacy and n == 2i32)  PatternCell.NotValue(1i32) // 旧: 壁 = !=1
        else if (n >= 1i32) PatternCell.Value(n)
        else PatternCell.NotValue(-n)

    def encodeAutoRule(r: AutoRule): Json =
        JObject(Map#{
            "name"    => JString(r#name),
            "size"    => JNumber(intToBd(r#size)),
            "v"       => JNumber(intToBd(currentAutoRuleVersion())),
            "pattern" => JArray(r#pattern
                |> Vector.map(c -> JNumber(intToBd(encodePatternCell(c))))),
            "srcX"    => JNumber(intToBd(r#srcX)),
            "srcY"    => JNumber(intToBd(r#srcY))
        })

    /// AutoRule の正規 size。すべてのルールはこれに揃える。
    /// size=3 の JSON は decode 時に 5×5 へ padding して読み込む。
    def canonicalAutoRuleSize(): Int32 = 5i32

    // 旧フォーマットに含まれていた "chance" キーは無視する (存在しても decode は成功)。
    def decodeAutoRule(element: Json): Option[AutoRule] =
        forM (
            obj      <- expectObject(element);
            nameJ    <- Map.get("name", obj);
            sizeJ    <- Map.get("size", obj);
            patternJ <- Map.get("pattern", obj);
            srcXJ    <- Map.get("srcX", obj);
            srcYJ    <- Map.get("srcY", obj);
            name     <- expectString(nameJ);
            size     <- expectInt(sizeJ);
            srcX     <- expectInt(srcXJ);
            srcY     <- expectInt(srcYJ);
            version  <- Some(match Map.get("v", obj) {
                case Some(vJ) => expectInt(vJ)
                case None     => (None: Option[Int32])
            });
            rawPattern <- decodePatternVector(version, size, patternJ)
        ) yield {
            let target = canonicalAutoRuleSize();
            let normalized = if (size == target) rawPattern
                             else padPatternToSize(rawPattern, size, target);
            ({
                name = name, size = target, pattern = normalized,
                srcX = srcX, srcY = srcY
            }: AutoRule)
        }

    /// oldSize×oldSize の pattern を newSize×newSize に拡張する (newSize >= oldSize)。
    /// 中央寄せ、外周は Unspecified でパディング。中央セルの値は
    /// 座標マッピングで自然に運ばれる (oldSize の中央が newSize の中央へ)。
    def padPatternToSize(oldPattern: Vector[PatternCell], oldSize: Int32,
                          newSize: Int32): Vector[PatternCell] = {
        let n = newSize * newSize;
        let offset = (newSize - oldSize) / 2i32;
        let u = PatternCell.Unspecified;
        List.range(0, n)
            |> List.map(idx -> {
                let r = idx / newSize;
                let c = Int32.remainder(idx, newSize);
                let oldR = r - offset;
                let oldC = c - offset;
                if (oldR < 0i32 or oldR >= oldSize or oldC < 0i32 or oldC >= oldSize)
                    u
                else match Vector.nth(oldR * oldSize + oldC, oldPattern) {
                    case Some(v) => v
                    case None    => u
                }
            })
            |> List.toVector
    }

    /// pattern 配列を decode する。中央セルも周辺セルと同じく値（マッチ条件）を保持する。
    /// `-1` (v<2 での装飾中央) は decodePatternCell 側で Unspecified に読み替わる。
    def decodePatternVector(version: Option[Int32], _size: Int32,
                              element: Json): Option[Vector[PatternCell]] = match element {
        case JArray(items) =>
            decodePatternCellsFrom(version, Vector.toList(items), Nil)
                |> Option.map(List.toVector)
        case _ => None
    }

    def decodePatternCellsFrom(version: Option[Int32],
                                 items: List[Json],
                                 acc: List[PatternCell]): Option[List[PatternCell]] = match items {
        case Nil       => Some(List.reverse(acc))
        case x :: rest =>
            match expectInt(x) {
                case None    => None
                case Some(n) =>
                    let cell = decodePatternCell(version, n);
                    decodePatternCellsFrom(version, rest, cell :: acc)
            }
    }

    def encodeWallMap(m: Map[String, (Int32, Int32)]): Json =
        let inner = m
            |> Map.foldLeftWithKey((acc, key, coord) ->
                Map.insert(key, encodeCoord(coord), acc),
                Map.empty());
        JObject(inner)

    def decodeWallMap(element: Json): Option[Map[String, (Int32, Int32)]] =
        forM (
            obj <- expectObject(element);
            res <- Map.foldLeftWithKey((acc, key, json) ->
                       Option.flatMap(soFar ->
                           decodeCoord(json) |> Option.map(c -> Map.insert(key, c, soFar)),
                           acc),
                       Some(Map.empty()),
                       obj)
        ) yield res

    def encodeCoord(coord: (Int32, Int32)): Json =
        let (col, row) = coord;
        JArray(Vector#{JNumber(intToBd(col)), JNumber(intToBd(row))})

    def decodeCoord(element: Json): Option[(Int32, Int32)] = match element {
        case JArray(items) =>
            match Vector.toList(items) {
                case j1 :: j2 :: Nil =>
                    forM (
                        col <- expectInt(j1);
                        row <- expectInt(j2)
                    ) yield (col, row)
                case _ => None
            }
        case _ => None
    }

    def encodeCoordList(coords: List[(Int32, Int32)]): Json =
        JArray(coords |> List.map(encodeCoord) |> List.toVector)

    def decodeCoordList(element: Json): Option[List[(Int32, Int32)]] =
        decodeList(decodeCoord, element)

    // ── ヘルパー ──

    /// JArray を `decode` で 1 要素ずつデコードし List にまとめる。
    /// 失敗要素があれば全体 None。
    def decodeList(decode: Json -> Option[a], element: Json): Option[List[a]] =
        match element {
            case JArray(items) =>
                List.foldRight(item -> acc ->
                    Option.flatMap(soFar ->
                        decode(item) |> Option.map(x -> x :: soFar),
                        acc),
                    Some(Nil), Vector.toList(items))
            case _ => None
        }

    def singleEntry(map: Map[String, Json]): Option[(String, Json)] =
        match Map.toList(map) {
            case head :: Nil => Some(head)
            case _           => None
        }

    def expectObject(element: Json): Option[Map[String, Json]] =
        match element {
            case JObject(map) => Some(map)
            case _               => None
        }

    def expectString(element: Json): Option[String] =
        match element {
            case JString(text) => Some(text)
            case _                => None
        }

    def expectInt(element: Json): Option[Int32] = match element {
        case JNumber(bd) => BigDecimal.tryToFloat64(bd) |> Option.flatMap(Float64.tryToInt32)
        case _              => None
    }

    /// Int32 → BigDecimal。trailing zero を取り除いて `100` (not `100.0`) で書き出す。
    /// `Resource.flix` の同名 helper と同じ実装。
    def intToBd(value: Int32): BigDecimal =
        unsafe IO {
            let stripped = JBigDecimal.valueOf(Int32.toFloat64(value)).stripTrailingZeros();
            if (stripped.scale() < 0) stripped.setScale(0) else stripped
        }
}
