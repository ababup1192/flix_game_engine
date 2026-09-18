// MotionDoc — player.motion.json(歩き・ジャンプ・ゆるしの手触り)の宣言ドキュメント層。
// ジャンプは重力でなく「頂点の高さ(タイル数)と頂点までの秒」で指定する —
// 重力と初速はコード(Physics)が閉じた式で導くので、数値の意味が失われない。
// コヨーテ・先行入力・落下強化などの「ゆるし」も全部ここのノブ。
// カメラの追従もここに置く — 「歩きが速いから先読みを伸ばす」のように
// 身体の数値と**同時に**触るもので、読み直したい時が同じだから。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod MotionDoc {
    use Util.Json.Json

    /// プレイヤーの動きのノブ一式。速さは px/秒、加速は px/秒²、高さはタイル数、間は秒。
    pub type alias Rec = {
        version = Int32,
        walkSpeed = Float64,       // 歩きの最高速 px/s
        accel = Float64,           // 入力方向への加速 px/s²
        decel = Float64,           // 入力なしの減速(摩擦)px/s²
        dashMult = Float64,        // B ダッシュ中の最高速 = walkSpeed × これ
        jumpHeightTiles = Float64, // 長押しジャンプの頂点の高さ(タイル数)
        jumpTapTiles = Float64,    // タップ(すぐ離す)ジャンプの頂点の高さ(タイル数)
        timeToApex = Float64,      // 頂点に届くまでの秒
        maxFallSpeed = Float64,    // 落下の最高速 px/s
        fallGravityMult = Float64, // 下降中に重力へ掛ける倍率(山の右側を詰める)
        coyoteTime = Float64,      // 崖を離れてもまだ跳べる秒
        jumpBufferTime = Float64,  // 着地前のジャンプ入力を取り置く秒
        cornerNudgePx = Float64,   // 頭の角がこの px 以下のかすりなら滑らせて通す
        springTiles = Float64,     // バネで跳ぶ頂点の高さ(タイル数)
        stompBounceTiles = Float64,// 踏みつけバウンドの高さ(押しっぱなしはバネ扱い)
        hitstopSec = Float64,      // 踏みつけの瞬間に世界を止める秒
        invulnSec = Float64,       // 被弾後の無敵秒
        wallJump = Bool,           // 拡張課題: 壁ジャンプの開放(既定 off)
        blinkPeriod = Float64,     // 消える床: 1 周期の秒
        blinkOnSec = Float64,      // 消える床: 周期のうち硬い秒
        platformAmpTiles = Float64,// 動く床: 横の振れ幅(タイル数)
        platformPeriodSec = Float64,// 動く床: 1 往復の秒
        camLeadPx = Float64,       // カメラ: 向いている方へ先読みする px
        camLiftPx = Float64,       // カメラ: 主役より上を見る px(足元より先が見える)
        camDeadzoneX = Float64,    // カメラ: 横の不感帯 px(この中は動かない)
        camFollowKX = Float64,     // カメラ: 横の追い付きの速さ(大きいほど張り付く)
        camDeadzoneY = Float64,    // カメラ: 縦の不感帯 px(広いほどジャンプで揺れない)
        camFollowKY = Float64      // カメラ: 縦の追い付きの速さ
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/player.motion.json"

    /// コード側の既定値(assets/player.motion.json と同じ値から出発する)。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          walkSpeed = 150.0, accel = 1400.0, decel = 1800.0, dashMult = 1.75,
          jumpHeightTiles = 4.4, jumpTapTiles = 1.6, timeToApex = 0.38,
          maxFallSpeed = 540.0, fallGravityMult = 1.6,
          coyoteTime = 0.08, jumpBufferTime = 0.10, cornerNudgePx = 4.0,
          springTiles = 9.0, stompBounceTiles = 3.0,
          hitstopSec = 0.05, invulnSec = 1.2,
          wallJump = false,
          blinkPeriod = 2.4, blinkOnSec = 1.5,
          platformAmpTiles = 2.5, platformPeriodSec = 3.2,
          camLeadPx = 40.0, camLiftPx = 16.0,
          camDeadzoneX = 8.0, camFollowKX = 6.0,
          camDeadzoneY = 40.0, camFollowKY = 4.0 })

    /// テキストから Doc へ(fail-open)。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version          = JsonCodec.intOr("version", d#version, root),
          walkSpeed        = JsonCodec.floatOr("walkSpeed", d#walkSpeed, root),
          accel            = JsonCodec.floatOr("accel", d#accel, root),
          decel            = JsonCodec.floatOr("decel", d#decel, root),
          dashMult         = JsonCodec.floatOr("dashMult", d#dashMult, root),
          jumpHeightTiles  = JsonCodec.floatOr("jumpHeightTiles", d#jumpHeightTiles, root),
          jumpTapTiles     = JsonCodec.floatOr("jumpTapTiles", d#jumpTapTiles, root),
          timeToApex       = JsonCodec.floatOr("timeToApex", d#timeToApex, root),
          maxFallSpeed     = JsonCodec.floatOr("maxFallSpeed", d#maxFallSpeed, root),
          fallGravityMult  = JsonCodec.floatOr("fallGravityMult", d#fallGravityMult, root),
          coyoteTime       = JsonCodec.floatOr("coyoteTime", d#coyoteTime, root),
          jumpBufferTime   = JsonCodec.floatOr("jumpBufferTime", d#jumpBufferTime, root),
          cornerNudgePx    = JsonCodec.floatOr("cornerNudgePx", d#cornerNudgePx, root),
          springTiles      = JsonCodec.floatOr("springTiles", d#springTiles, root),
          stompBounceTiles = JsonCodec.floatOr("stompBounceTiles", d#stompBounceTiles, root),
          hitstopSec       = JsonCodec.floatOr("hitstopSec", d#hitstopSec, root),
          invulnSec        = JsonCodec.floatOr("invulnSec", d#invulnSec, root),
          wallJump         = JsonCodec.boolOr("wallJump", d#wallJump, root),
          blinkPeriod      = JsonCodec.floatOr("blinkPeriod", d#blinkPeriod, root),
          blinkOnSec       = JsonCodec.floatOr("blinkOnSec", d#blinkOnSec, root),
          platformAmpTiles = JsonCodec.floatOr("platformAmpTiles", d#platformAmpTiles, root),
          platformPeriodSec = JsonCodec.floatOr("platformPeriodSec", d#platformPeriodSec, root),
          camLeadPx        = JsonCodec.floatOr("camLeadPx", d#camLeadPx, root),
          camLiftPx        = JsonCodec.floatOr("camLiftPx", d#camLiftPx, root),
          camDeadzoneX     = JsonCodec.floatOr("camDeadzoneX", d#camDeadzoneX, root),
          camFollowKX      = JsonCodec.floatOr("camFollowKX", d#camFollowKX, root),
          camDeadzoneY     = JsonCodec.floatOr("camDeadzoneY", d#camDeadzoneY, root),
          camFollowKY      = JsonCodec.floatOr("camFollowKY", d#camFollowKY, root) })

    /// path の Doc を読む。読めない・壊れているときは defaults(fail-open)。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
