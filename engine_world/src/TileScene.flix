/// タイル層の宣言（App.withTileLayers が受け取る値）と、その CPU 投影。
///
/// GPU 経路（インスタンシング・全タイル 1 draw call）はエンジンが面倒を見るが、
/// ヘッドレス描き出し（SoftRaster）と F8 停止中の凍結画面はタイルチャンネルを持たない。
/// そこでは toItems の CPU 投影（regionRect 付き Sprite の列）で同じ絵を出す。
/// 両経路が同じ Spec から派生するので、絵柄の正は 1 箇所に保たれる。
///
/// zIndex は動的な絵と同じ z 空間で解釈される — キャラより大きい zIndex を与えれば、
/// キャラを隠す屋根・庇もタイル層で置ける。同じ zIndex ではタイル層が奥に描かれる。
/// key は静的な中身を決める入力を 1 文字列にまとめたキャッシュキー（マップ id 等。変わると
/// エンジンが GPU バッファを作り直す）。watchFile / reloadOn の読み直しでも自動で作り直される
/// ので、Doc の世代番号を key へ混ぜ込む必要はない。tiles の px は origin からの
/// 相対位置（world 座標）。camera はエンジンが掛ける。
/// tiles がサンク（Unit -> List）なのは、宣言は毎フレーム評価されるため —
/// 中身のリストは key が変わった作り直しの時だけ組めばよく、毎フレーム数千レコードを
/// 作り直すとそれだけでフレーム予算を食う。
pub type alias TileLayerSpec = {
    key = String,
    tileSet = Tileset,
    tiles = Unit -> List[TileData],
    origin = Vec2.Vec2,
    zIndex = Int32
}

pub mod TileScene {

    /// Spec を regionRect 付き Sprite の PlacedItem 列に写す（world 座標のまま）。
    /// ヘッドレス描き出し・F8 停止画面・スナップショットテストが GPU 抜きで同じ絵を得るための投影。
    /// 走行中の毎フレームには使わない — タイル数ぶんの動的 item を数えてしまう。
    pub def toItems(spec: TileLayerSpec): List[Render.PlacedItem] =
        let atlas = spec#tileSet#atlasSource;
        let ts = atlas#tileSize;
        // Sprite の表示寸法はテクスチャ全寸 × scale なので、1 タイル ts px になるよう割り戻す。
        let scale = if (atlas#texWidth <= 0.0 or atlas#texHeight <= 0.0) Vec2.zero()
                    else ({ x = ts / atlas#texWidth, y = ts / atlas#texHeight }: Vec2.Vec2);
        let tilesOf = spec#tiles;
        tilesOf() |> List.map(tile ->
            { at = Vec2.add(spec#origin, tile#px),
              item = Render.Item.Sprite({
                  texture = atlas#textureName,
                  tint = tile#tint,
                  alpha = tile#alpha,
                  scale = scale,
                  rotation = 0.0, centered = false,
                  flipH = tile#flipH, flipV = tile#flipV,
                  regionRect = Some({ position = { x = tile#srcX, y = tile#srcY },
                                      size = { x = ts, y = ts } }),
                  zIndex = spec#zIndex,
                  blend = DrawCmd.BlendMode.Normal, maskPolys = Nil }) })
}
