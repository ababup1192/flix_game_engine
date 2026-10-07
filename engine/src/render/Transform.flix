/// 2D の位置・回転・スケール・せん断をまとめた値部品。
/// 描画型はこれを埋め込んで座標変換を共有するので、型ごとに変換ロジックを書かずに済む。
/// 利用例: スプライトを移動・回転させる / 図形を指定した点の方へ向ける。
///
/// position … 位置
/// rotation … 回転（ラジアン）
/// scale    … 拡大率
/// skew     … せん断（ラジアン）。対象を平行四辺形のように歪ませる
pub type alias Transform = {
    position = Vec2.Vec2,
    rotation = Float64,
    scale = Vec2.Vec2,
    skew = Float64
}

pub mod Transform {

    /// 変換なしの初期値（原点・無回転・等倍・せん断なし）。
    pub def identity(): Transform =
        { position = Vec2.zero(), rotation = 0.0, scale = Vec2.one(), skew = 0.0 }

    // ── アクセサ / 更新 ──

    /// 位置を取得する
    pub def getPosition(t: Transform): Vec2.Vec2 = t#position

    /// 位置を設定する
    pub def setPosition(position: Vec2.Vec2, t: Transform): Transform =
        { position = position | t }

    /// 回転（ラジアン）を取得する
    pub def getRotation(t: Transform): Float64 = t#rotation

    /// 回転（ラジアン）を設定する
    pub def setRotation(rotation: Float64, t: Transform): Transform =
        { rotation = rotation | t }

    /// スケールを取得する
    pub def getScale(t: Transform): Vec2.Vec2 = t#scale

    /// スケールを設定する
    pub def setScale(scale: Vec2.Vec2, t: Transform): Transform =
        { scale = scale | t }

    // ── 派生操作 ──

    /// ローカル座標系でオフセット分だけ移動する
    pub def translate(offset: Vec2.Vec2, t: Transform): Transform =
        setPosition(Vec2.add(t#position, offset), t)

    /// 現在の回転に加算する（ラジアン）
    pub def rotate(radians: Float64, t: Transform): Transform =
        setRotation(t#rotation + radians, t)

    /// 現在のスケールにベクトルを乗算する
    pub def applyScale(ratio: Vec2.Vec2, t: Transform): Transform =
        setScale({x = t#scale#x * ratio#x, y = t#scale#y * ratio#y}, t)

    /// 指定した点への角度（ラジアン）を返す
    pub def getAngleTo(point: Vec2.Vec2, t: Transform): Float64 =
        Vec2.sub(point, t#position) |> Vec2.angle

    /// 指定した点の方を向くように回転する
    pub def lookAt(point: Vec2.Vec2, t: Transform): Transform =
        setRotation(getAngleTo(point, t), t)
}
