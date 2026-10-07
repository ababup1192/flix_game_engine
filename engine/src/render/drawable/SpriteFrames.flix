/// アニメーション素材集 — 名前つきのパラパラ漫画をまとめて持つリソース。
///
/// ※ これは Drawable 経路の部品。PlacedItem 経路（withView のゲーム）は engine_world の
/// Anim モジュールが同じ役割を担うので、そちらでは使わない。
///
/// AnimatedSprite2D が `spriteFrames` フィールドで参照する素材置き場。各アニメーションは
/// 独自の loop / speed (FPS) と、フレーム（テクスチャ + 表示時間倍率）の列を持つ。
/// 「歩き」「攻撃」など複数のアニメを 1 か所に登録して名前で呼び出せる。
/// 利用例: idle / walk / attack を登録し、状況に応じて切り替える。
pub enum SpriteFrames {
    case SpriteFrames(Map[String, SpriteFrames.Animation])
}

pub mod SpriteFrames {

    /// 1 フレームの定義
    /// duration はそのアニメーションの基本フレーム時間 (1/speed) に対する倍率。
    /// 1.0 = 通常、2.0 = 2 倍長く表示。
    /// `regionRect` はテクスチャ内の切り出し矩形（ピクセル単位）。None ならテクスチャ全体
    /// を表示する。スプライトシートを 1 枚のテクスチャに収めて各フレームを切り出すとき
    /// に使う。`region` は Flix 予約語なので Sprite に合わせて `regionRect` 命名。
    pub type alias Frame = {
        texture = String,                      // 表示するテクスチャ名
        regionRect = Option[Rect2.Rect2],      // 切り出し矩形（None ならテクスチャ全体）
        duration = Float64                     // フレーム時間倍率（デフォルト 1.0）
    }

    /// 1 アニメーションの定義
    pub type alias Animation = {
        loop = Bool,           // 終端でループするか（false なら最終フレームで停止）
        speed = Float64,       // このアニメーションの基本 FPS
        frames = List[Frame]   // 表示順のフレーム列
    }

    /// 空の SpriteFrames を生成する
    pub def empty(): SpriteFrames =
        SpriteFrames.SpriteFrames(Map.empty())

    /// アニメーションを追加する（同名なら上書き）
    pub def addAnimation(name: String, animation: Animation,
                          spriteFrames: SpriteFrames): SpriteFrames =
        let SpriteFrames.SpriteFrames(map) = spriteFrames;
        SpriteFrames.SpriteFrames(Map.insert(name, animation, map))

    /// 指定したアニメーションを取得する
    pub def getAnimation(name: String, spriteFrames: SpriteFrames): Option[Animation] =
        let SpriteFrames.SpriteFrames(map) = spriteFrames;
        Map.get(name, map)

    /// アニメーション名の一覧を返す
    pub def animationNames(spriteFrames: SpriteFrames): List[String] =
        let SpriteFrames.SpriteFrames(map) = spriteFrames;
        Map.keysOf(map) |> Set.toList

    /// 指定アニメ・フレーム index のテクスチャ名を返す（範囲外なら None）
    pub def frameTexture(name: String, frame: Int32,
                         spriteFrames: SpriteFrames): Option[String] =
        forM (
            anim <- getAnimation(name, spriteFrames);
            f    <- List.nth(frame, anim#frames)
        ) yield f#texture

    /// 指定アニメ・フレーム index の regionRect（切り出し矩形）を返す。
    /// アニメ未定義・frame 範囲外・regionRect 未指定はすべて None。
    pub def frameRegion(name: String, frame: Int32,
                         spriteFrames: SpriteFrames): Option[Rect2.Rect2] =
        forM (
            anim <- getAnimation(name, spriteFrames);
            f    <- List.nth(frame, anim#frames);
            rect <- f#regionRect
        ) yield rect
}
