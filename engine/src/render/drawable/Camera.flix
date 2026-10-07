/// ※ これは Drawable 経路（view = None で renderCommands を自前で組むゲーム。fe_rogue が実例）
/// のカメラ部品。PlacedItem 経路（withView のゲーム）は App.withCamera / withZoom + CameraRig が
/// 同じ役割を担うので、そちらでは使わない。
///
/// 描画をどの位置・どのズームで画面に映すかを決める 2D カメラ。
/// `transform` の position が「画面中央に映すワールド座標」、`zoom` が寄り引きの倍率。
/// これ 1 つで world → screen のビュー変換（`getViewTransform`）を作れるので、
/// 描画側はカメラ視点の座標に描ける。
/// 利用例: プレイヤーを画面中央に置く / マップを 0.32 倍に引いて広く見せる。
///
/// 追従（スムージング・ドラッグ余白・スクロール制限）はカメラ自身の責務ではなく、
/// position を毎フレーム動かす利用側の処理が担う（Bevy の follow system と同じ分担）。
pub enum Camera {
    case Camera({
        transform = Transform,   // position = 画面中央に映すワールド座標。回転・スケール・せん断
        zoom = Vec2.Vec2         // 寄り引き倍率。大きいほど寄る（0.32 で引き）
    })
}

pub mod Camera {

    /// 指定位置を画面中央に映すカメラを作る（zoom = (1, 1) 等倍）。
    pub def make(position: Vec2.Vec2): Camera =
        Camera.Camera({
            transform = { position = position, rotation = 0.0, scale = {x = 1.0, y = 1.0}, skew = 0.0 },
            zoom = {x = 1.0, y = 1.0}
        })

    /// 埋め込んだ Transform 部品を取り出す
    pub def transform(camera: Camera): Transform =
        let Camera.Camera(r) = camera;
        r#transform

    /// Transform 部品に関数を適用して差し替える
    pub def mapTransform(f: Transform -> Transform \ ef, camera: Camera): Camera \ ef =
        let Camera.Camera(r) = camera;
        Camera.Camera({transform = f(r#transform) | r})

    /// ズーム倍率を取得する
    pub def getZoom(camera: Camera): Vec2.Vec2 =
        let Camera.Camera(r) = camera;
        r#zoom

    /// ズーム倍率を設定する
    pub def setZoom(zoom: Vec2.Vec2, camera: Camera): Camera =
        let Camera.Camera(r) = camera;
        Camera.Camera({zoom = zoom | r})

    /// カメラから ViewTransform（world → screen 変換）を作る。
    /// `center` を画面中央に映す。描画時に各描画物の worldPos を `Projection.applyToWorldPos`
    /// に通すとカメラ視点の screen 座標へ移せる。画面固定レイヤの描画物には適用しない。
    pub def getViewTransform(camera: Camera, center: Vec2.Vec2,
                              viewport: {viewportWidth = Float64, viewportHeight = Float64}): Projection.ViewTransform =
        let Camera.Camera(r) = camera;
        Projection.viewTransform(r#zoom, center, viewport)
}
