/// タイルマップレイヤー — 格子状に並べたタイルの層を 1 枚まとめて描く。
///
/// 大量のタイルを 1 回の描画でまとめて出せるので、床や壁のマップを軽く表示できる。
/// 利用例: ダンジョンの床・壁レイヤーを 1 枚として置く。
///
/// GPU インスタンシング（glDrawArraysInstanced）で全タイルを 1 draw call で描画する。
///
/// tileVaoId / tileCount は tilemap loader が initTileBuffer() で設定する。
/// 初期値 0 = 未初期化（GPU リソース未アップロード）。
pub enum TileLayer {
    case TileLayer({
        transform = Transform,        // 位置・回転・スケール・せん断
        visual = Visual,              // 色変調・可視性・描画順
        tileSet = Tileset,            // タイルセット
        tiles = List[TileData],       // タイル一覧
        collisionCells = List[Vec2.Vec2], // 衝突グリッドセル
        gridSize = {x = Int32, y = Int32},        // マップのグリッド寸法（マス数）
        tileVaoId = GpuHandle.TileVao,    // GPU VAO ハンドル
        tileCount = Int32             // インスタンス数
    })
}

/// 1 タイルの描画情報（tilemap loader が tilemap tile データから生成する）
pub type alias TileData = {
    px    = Vec2.Vec2,
    srcX  = Float64,
    srcY  = Float64,
    flipH = Bool,
    flipV = Bool,
    alpha = Float64,
    tint  = Color
}

pub mod TileLayer {

    /// 色変調なし（白 = テクスチャの色のまま）。tint の既定値として使う。
    /// per-tile の照明（松明の暖色・月光）を乗せるゲームは、マスごとの明度色をここに渡す。
    pub def noTint(): Color = { r = 1.0, g = 1.0, b = 1.0 }

    /// TileLayer を TileMapRenderCmd に変換する（GameEngine.render 内で使用）。
    /// `position` は既にカメラ ViewTransform を適用したスクリーン座標、
    /// `tileScale` は ViewTransform.scale（zoom）。シェーダ側でタイル本体に乗算する
    pub def toRenderCmd(layerScreenPos: Vec2.Vec2, tileScale: Vec2.Vec2,
                         tileMap: TileLayer): GameEngine.TileMapRenderCmd =
        let TileLayer.TileLayer(r) = tileMap;
        let atlas = r#tileSet#atlasSource;
        { textureName = atlas#textureName,
          tileSize    = atlas#tileSize,
          position    = layerScreenPos,
          tileScale   = tileScale,
          color       = r#visual#color,
          zIndex      = r#visual#zIndex,
          tileVaoId   = r#tileVaoId,
          tileCount   = r#tileCount }

    /// デフォルト値で TileLayer を構築するビルドヘルパー
    pub def make(config: { tileSet = Tileset,
                            tiles = List[TileData],
                            collisionCells = List[Vec2.Vec2],
                            gridSize = {x = Int32, y = Int32} }): TileLayer =
        TileLayer.TileLayer({
            transform      = Transform.identity(),
            visual         = Visual.default(),
            tileSet        = config#tileSet,
            tiles          = config#tiles,
            collisionCells = config#collisionCells,
            gridSize       = config#gridSize,
            tileVaoId      = GpuHandle.wrapTileVao(0),
            tileCount      = 0
        })

    /// 埋め込んだ Transform 部品を取り出す
    pub def transform(tileMap: TileLayer): Transform =
        let TileLayer.TileLayer(r) = tileMap;
        r#transform

    /// Transform 部品に関数を適用して差し替える
    pub def mapTransform(f: Transform -> Transform \ ef, tileMap: TileLayer): TileLayer \ ef =
        let TileLayer.TileLayer(r) = tileMap;
        TileLayer.TileLayer({transform = f(r#transform) | r})

    /// 埋め込んだ Visual 部品を取り出す
    pub def visual(tileMap: TileLayer): Visual =
        let TileLayer.TileLayer(r) = tileMap;
        r#visual

    /// Visual 部品に関数を適用して差し替える
    pub def mapVisual(f: Visual -> Visual \ ef, tileMap: TileLayer): TileLayer \ ef =
        let TileLayer.TileLayer(r) = tileMap;
        TileLayer.TileLayer({visual = f(r#visual) | r})

    // ────────────────────────────────────────────────────────
    // タイル座標のクエリ API
    // ────────────────────────────────────────────────────────

    /// タイル 1 マスの一辺（ピクセル）のショートカット（タイル正方形）
    pub def tileSize(tileMap: TileLayer): Float64 =
        let TileLayer.TileLayer(r) = tileMap;
        Tileset.tileSize(r#tileSet)

    /// 使用中のマス範囲を矩形で返す。position は (0,0) 固定、size は gridSize。
    pub def usedRect(tileMap: TileLayer):
            { position = {x = Int32, y = Int32}, size = {x = Int32, y = Int32} } =
        let TileLayer.TileLayer(r) = tileMap;
        { position = Vec2i.zero(), size = r#gridSize }

    /// マス座標 → セル中心のローカルピクセル座標（Grid.cellCenterOf と同じ決まり）。
    /// world 座標が必要な場合は呼び出し側でレイヤーの原点を足し合わせる。
    pub def cellCenterOf(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Vec2.Vec2 =
        let s = tileSize(tileMap);
        let v = Vec2i.toVec2(coords);
        { x = v#x * s + s / 2.0,
          y = v#y * s + s / 2.0 }

    /// 指定マスのソース ID を返す。空セル（範囲外含む）: -1、壁セル: 0
    /// （現状は二値構造 — source は 1 種類のみ）。
    pub def sourceIdAt(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Int32 =
        let TileLayer.TileLayer(r) = tileMap;
        if (not isInBounds(coords, tileMap)) -1
        else
            let target = Vec2i.toVec2(coords);
            if (List.exists(c -> c#x == target#x and c#y == target#y, r#collisionCells))
                0
            else
                -1

    // ── 本プロジェクト固有の便宜 API ──

    /// 範囲チェック: usedRect 内に収まるか
    pub def isInBounds(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Bool =
        let TileLayer.TileLayer(r) = tileMap;
        coords#x >= 0 and coords#x < r#gridSize#x and
        coords#y >= 0 and coords#y < r#gridSize#y

    /// 衝突セルか（sourceIdAt(coords, layer) != -1 の薄いラッパ）
    pub def isWall(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Bool =
        sourceIdAt(coords, tileMap) != -1

    /// 範囲内 かつ 壁でない ⇒ 床
    pub def isFloor(coords: {x = Int32, y = Int32}, tileMap: TileLayer): Bool =
        isInBounds(coords, tileMap) and not isWall(coords, tileMap)

    /// GPU リソースハンドルを設定する（tilemap loader が initTileBuffer の結果を書き込む）
    pub def withGpuResources(tileVaoId: GpuHandle.TileVao, tileCount: Int32,
                              tileMap: TileLayer): TileLayer =
        let TileLayer.TileLayer(r) = tileMap;
        TileLayer.TileLayer({ tileVaoId = tileVaoId, tileCount = tileCount | r })

    /// TileData のリストを GPU インスタンス (TileInstance) のリストに変換する。
    /// UV は texture サイズと flipH/flipV から計算する。
    pub def buildInstances(tiles: List[TileData],
                            tileSet: Tileset,
                            tileSize: Float64): List[GameEngine.TileInstance] =
        let texWidth  = tileSet#atlasSource#texWidth;
        let texHeight = tileSet#atlasSource#texHeight;
        // UV は各 texel の中心 (src + 0.5 .. src + tileSize - 0.5) を結ぶように
        // half-texel inset する。アトラスがタイル間 padding なしで密パックされているため、
        // 境界そのまま (src .. src + tileSize) を UV にすると、シェーダ内補間の浮動小数
        // 誤差で隣接タイルの最初の 1 texel を拾い、タイル境界に細い線として現れる。
        let inset = 0.5;
        List.map(tile -> {
            let uvoX = if (tile#flipH) (tile#srcX + tileSize - inset) / texWidth
                       else            (tile#srcX + inset) / texWidth;
            let uvoY = if (tile#flipV) (tile#srcY + tileSize - inset) / texHeight
                       else            (tile#srcY + inset) / texHeight;
            let uvsX = if (tile#flipH) -((tileSize - 2.0 * inset) / texWidth)
                       else            (tileSize - 2.0 * inset) / texWidth;
            let uvsY = if (tile#flipV) -((tileSize - 2.0 * inset) / texHeight)
                       else            (tileSize - 2.0 * inset) / texHeight;
            ({
                px    = tile#px,
                uvOff = ({x = uvoX, y = uvoY}: Vec2.Vec2),
                uvSc  = ({x = uvsX, y = uvsY}: Vec2.Vec2),
                alpha = tile#alpha,
                tint  = tile#tint
            }: GameEngine.TileInstance)
        }, tiles)
}

