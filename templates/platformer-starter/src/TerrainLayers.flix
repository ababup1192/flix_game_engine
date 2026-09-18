// TerrainLayers — 地形の静的な絵(前景タイル・洞窟の背後壁)を GPU タイル層
// (App.withTileLayers)へ載せるための記述と変換。terra_like で実証した形の縮小版。
//
// 「1 マスに何をどの順で貼るか」の権威は cellGroups の 1 箇所だけ:
//   - specs はそれを TileData に組み、per-tile tint に LightGrid の明度色を渡す
//     (洞窟の松明の暖色が 1 draw call のまま 1 マスごとに乗る)。
//   - View.tileItems(描き出し・全動的経路)は同じ記述を PlacedItem に解釈する。
// 面は固定サイズ・松明も静的なので、key はステージとアトラスの世代だけ —
// 層の作り直しは面の切替と Doc 読み直しの時にしか起きない。
mod TerrainLayers {

    /// 1 枚のクアッド(スプライト名 + コマ名)。
    pub type alias Quad = { sprite = String, frame = String }

    /// 同じ z にまとまる 1 群。fallback = どのコマも絵に解決しない時の仮色の板
    /// (None = 何も出さない — 重ねが無いだけで穴は開かない)。
    pub type alias Group = { z = Int32, fallback = Option[Color], quads = List[Quad] }

    /// 1 マスの静的クアッド記述。
    ///   # = 土(上が空気なら草の top コマ)/ X = 石 / = 一方通行の板 /
    ///   その他の通れるマス = 洞窟なら背後壁。
    /// 動く床・消える床・バネ・コイン等の「動く物」はここに載せない(View の動的側)。
    pub def cellGroups(w: World.World, x: Int32, y: Int32): List[Group] =
        let st = w#stage;
        let ch = Stage.charAt(st, x, y);
        if (ch == '#') solidGroups(st, x, y, "dirt") :: Nil
        else if (ch == 'X') solidGroups(st, x, y, "stone") :: Nil
        else if (ch == '=')
            ({ z = View.zFore(), fallback = Some(Theme.resolve(w#theme, "plank")),
               quads = { sprite = "oneway", frame = "plank" } :: Nil }: Group)
                :: wallGroups(w, x, y)
        else wallGroups(w, x, y)

    /// 硬いマス: 地のコマ(上辺が空気なら top 変種・でなければ fill 変種)+ 露出辺の縁。
    def solidGroups(st: Stage.Stage, x: Int32, y: Int32, mat: String): Group =
        let airAbove = not Stage.solidAt(st, x, y - 1);
        let base = if (airAbove) "top_v${variant(x, y)}" else "fill_v${variant(x, y)}";
        let edges =
            (if (not Stage.solidAt(st, x + 1, y)) { sprite = mat, frame = "edge_r" } :: Nil else Nil)
            ::: (if (not Stage.solidAt(st, x - 1, y)) { sprite = mat, frame = "edge_l" } :: Nil else Nil)
            ::: (if (not Stage.solidAt(st, x, y + 1)) { sprite = mat, frame = "edge_b" } :: Nil else Nil);
        { z = View.zFore(),
          fallback = Some(placeholderOf(mat)),
          quads = { sprite = mat, frame = base } :: edges }

    /// 洞窟の背後壁(通れるマスの奥に見える面)。
    def wallGroups(w: World.World, x: Int32, y: Int32): List[Group] =
        if (not Stage.wallAt(w#stage, x, y)) Nil
        else ({ z = View.zWall(),
                fallback = Some(Theme.resolve(w#theme, "wallCaveDark")),
                quads = { sprite = "wall", frame = "fill_v${variant(x, y)}" } :: Nil }: Group)
            :: Nil

    /// fill の 3 変種(座標で散らす — 隣と同じ顔が並ばない)。
    def variant(x: Int32, y: Int32): Int32 = Int32.modulo(x * 7 + y * 13, 3)

    /// 絵が無いときの仮色(素材の気分だけ合わせる)。
    pub def placeholderOf(mat: String): Color =
        if (mat == "stone") Color.rgb8(122, 126, 140) else Color.rgb8(107, 91, 62)

    // ── GPU 層 ──

    /// 実機の GPU タイル層 2 枚(背後壁 z=zWall / 前景 z=zFore)。App.withTileLayers に渡す。
    /// tiles はサンク — 毎フレーム評価されるのは key の比較だけで、リスト構築は
    /// key(面・アトラスの世代)が変わった作り直しの時にしか走らない。
    pub def specs(w: World.World): List[TileLayerSpec] =
        let side = Int32.toFloat64(w#atlas#side);
        let set: Tileset = { atlasSource = {
            textureName = World.atlasName(),
            texWidth = side, texHeight = side, tileSize = Physics.tileSize(),
            marginX = 0.0, marginY = 0.0, spacingX = 0.0, spacingY = 0.0 } };
        let key = "ps:${w#stageIx}:${w#atlasGen}";
        specOf(w, set, "wall:${key}", View.zWall())
            :: specOf(w, set, "fore:${key}", View.zFore()) :: Nil

    def specOf(w: World.World, set: Tileset, key: String, z: Int32): TileLayerSpec =
        { key = key, tileSet = set, origin = Vec2.zero(), zIndex = z,
          tiles = _ -> layerTiles(w, z) }

    /// z の層に乗る全 TileData(面全体 — 固定サイズなので出し惜しみしない)。
    pub def layerTiles(w: World.World, z: Int32): List[TileData] =
        let st = Stage.rec(w#stage);
        forM (y <- List.range(0, st#height);
              x <- List.range(0, st#width);
              g <- cellGroups(w, x, y) |> List.filter(g -> g#z == z);
              q <- g#quads;
              td <- tileOf(w, x, y, q) |> Option.toList)
            yield td

    /// このクアッドは GPU 層に乗るか(乗る = 動的側は描かない)。
    /// 乗れるのは 16×16 ちょうどにアトラスへ切れるコマだけ。
    pub def ridesLayer(w: World.World, q: Quad): Bool =
        not Option.isEmpty(squareSrcOf(w, q))

    def tileOf(w: World.World, x: Int32, y: Int32, q: Quad): Option[TileData] =
        squareSrcOf(w, q) |> Option.map(pos -> {
            let ts = Physics.tileSize();
            ({ px = { x = Int32.toFloat64(x) * ts, y = Int32.toFloat64(y) * ts },
               srcX = pos#x, srcY = pos#y,
               flipH = false, flipV = false, alpha = 1.0,
               tint = LightGrid.toColor(
                   LightGrid.brightnessAt(w#stage, w#light, x, y)) }: TileData)
        })

    /// コマが 16×16 ちょうどにアトラスへ切れているか(anchor 0,0 の前提)。
    def squareSrcOf(w: World.World, q: Quad): Option[Vec2.Vec2] =
        match PxSpriteAtlas.regionOf(w#atlas, q#sprite, q#frame) {
            case Some(rect) =>
                let ts = Physics.tileSize();
                if (rect#size#x == ts and rect#size#y == ts) Some(rect#position) else None
            case None => None
        }
}
