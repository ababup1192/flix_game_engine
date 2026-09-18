// RulesDoc — race.rules.json（手触りと収支の数値）の宣言ドキュメント層。
// Doc は「調整したい数値の初期値の宣言」まで。走る・曲がる・滑る・抜く・壊れるの規則そのものは
// コード（World）側にある。ここに if 文を書き始めたら Doc の境界を越えている合図。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
//
// 数値は 7 つの関心に分かれる（スキーマの group と同じ並び）:
//   走り / コーナーとドリフト / 障害物 / スリップストリーム / ニトロ / クラッシュ / アイテムと得点
mod RulesDoc {
    use Util.Json.Json

    /// 手触りと収支の数値。いじると何が変わるかは assets/rules.schema.json の label が source of truth。
    pub type alias Rec = {
        version = Int32,
        // ── 走り ──
        forwardSpeed = Float64,        // 前進の速さ（px/秒）
        steerSpeed = Float64,          // ハンドルの効き（px/秒）
        brakeSlow = Float64,           // ブレーキ（↓）中の速度係数（0..1）
        offRoadSlow = Float64,         // 草へはみ出したときの速度係数（0..1）
        yawGain = Float64,             // コーナーでカメラが内側を向く強さ（0 = 向かない）
        skyParallax = Float64,         // 曲がった向きに空・太陽・雲が流れる量（px）
        totalLaps = Int32,             // ゴールに必要な周回数
        // ── コーナーとドリフト ──
        hillSpeedGain = Float64,       // 坂 1 行ぶんの勾配で速度が変わる割合（登りで遅く・下りで速く）
        gripSpeed = Float64,           // これ以下の速度なら膨らまずに曲がれる（px/秒）
        curvePush = Float64,           // カーブの急さ×超過速度に掛かる横押しの強さ
        driftTurnBoost = Float64,      // ドリフト中の舵角倍率
        driftSlide = Float64,          // ドリフト中に外へ流れ続ける速さ（px/秒）
        // ── 障害物（ガードレール。ゲートの隙間とバーの寸法・周期は PropsDoc — 置き場と一緒に触る値） ──
        railTouch = Float64,           // 道の端からここまで寄ると壁を擦る（px）
        railScrapeSlow = Float64,      // 壁を擦っている間の速度係数（0..1）
        nitroChargeRail = Float64,     // 壁を擦っている 1 秒あたりのゲージ加算
        // ── スリップストリーム ──
        slipBoost = Float64,           // 前走車の真後ろにいる間の速度倍率
        slipRange = Float64,           // 範囲の長さ（前走車の後ろ何 px まで効くか）
        slipWidth = Float64,           // 範囲の幅（左右のずれの許し px）
        // ── ニトロ ──
        nitroChargeDrift = Float64,    // ドリフト 1 秒あたりのゲージ加算（満タン = 1.0）
        nitroChargeSlip = Float64,     // スリップ維持 1 秒あたりのゲージ加算
        nitroChargeNearMiss = Float64, // 障害物すれすれ 1 回のゲージ加算
        nitroBoost = Float64,          // 発動中の速度倍率
        nitroDuration = Float64,       // 発動時間（秒）
        nitroSteerPenalty = Float64,   // 発動中の操舵倍率（0..1・重くなる）
        // ── クラッシュ ──
        spinDuration = Float64,        // スピン（操作不能）の長さ（秒）
        spinSlow = Float64,            // スピン中の速度係数（0..1）
        spinNitroLoss = Float64,       // スピン時に失うゲージの割合（0..1）
        nearMissDist = Float64,        // 「すれすれ」と判定する障害物との距離（px）
        bumpPush = Float64,            // 車どうしがぶつかったとき横へ弾かれる速さ（px/秒）
        bumpSlow = Float64,            // ぶつかった直後の速度係数（0..1）
        bumpDuration = Float64,        // ぶつかった直後に速度が落ちている長さ（秒）
        // ── アイテムと得点 ──
        itemScoreBonus = Int32,        // 1 位で取ったときのスコア
        itemNitroCharge = Float64,     // 2 位で取ったときのゲージ加算
        itemBoostLow = Float64,        // 3 位以下で取ったときの即時ブースト倍率
        itemBoostDuration = Float64,   // 即時ブーストの長さ（秒）
        scorePerPass = Int32,          // ライバルを 1 台抜くたびの得点
        finishBonus = Int32            // 1 位ゴールの追加得点
    }

    // 型検査が record を展開しないため、World が持つ公開の型は enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/race.rules.json"

    /// コード側の既定値（assets/race.rules.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          forwardSpeed = 118.0,
          steerSpeed = 127.0,
          brakeSlow = 0.72,
          offRoadSlow = 0.45,
          yawGain = 0.35,
          skyParallax = 10.0,
          totalLaps = 3,
          hillSpeedGain = 0.05,
          gripSpeed = 101.0,
          curvePush = 7.0,
          driftTurnBoost = 1.7,
          driftSlide = 36.0,
          railTouch = 7.0,
          railScrapeSlow = 0.58,
          nitroChargeRail = 0.30,
          slipBoost = 1.35,
          slipRange = 56.0,
          slipWidth = 26.0,
          nitroChargeDrift = 0.45,
          nitroChargeSlip = 0.20,
          nitroChargeNearMiss = 0.25,
          nitroBoost = 2.0,
          nitroDuration = 1.4,
          nitroSteerPenalty = 0.5,
          spinDuration = 1.0,
          spinSlow = 0.3,
          spinNitroLoss = 0.5,
          nearMissDist = 14.0,
          bumpPush = 236.0,
          bumpSlow = 0.82,
          bumpDuration = 0.35,
          itemScoreBonus = 200,
          itemNitroCharge = 0.3,
          itemBoostLow = 1.5,
          itemBoostDuration = 0.8,
          scorePerPass = 300,
          finishBonus = 1000 })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          forwardSpeed = JsonCodec.floatOr("forwardSpeed", d#forwardSpeed, root),
          steerSpeed = JsonCodec.floatOr("steerSpeed", d#steerSpeed, root),
          brakeSlow = JsonCodec.floatOr("brakeSlow", d#brakeSlow, root),
          offRoadSlow = JsonCodec.floatOr("offRoadSlow", d#offRoadSlow, root),
          yawGain = JsonCodec.floatOr("yawGain", d#yawGain, root),
          skyParallax = JsonCodec.floatOr("skyParallax", d#skyParallax, root),
          totalLaps = JsonCodec.intOr("totalLaps", d#totalLaps, root),
          hillSpeedGain = JsonCodec.floatOr("hillSpeedGain", d#hillSpeedGain, root),
          gripSpeed = JsonCodec.floatOr("gripSpeed", d#gripSpeed, root),
          curvePush = JsonCodec.floatOr("curvePush", d#curvePush, root),
          driftTurnBoost = JsonCodec.floatOr("driftTurnBoost", d#driftTurnBoost, root),
          driftSlide = JsonCodec.floatOr("driftSlide", d#driftSlide, root),
          railTouch = JsonCodec.floatOr("railTouch", d#railTouch, root),
          railScrapeSlow = JsonCodec.floatOr("railScrapeSlow", d#railScrapeSlow, root),
          nitroChargeRail = JsonCodec.floatOr("nitroChargeRail", d#nitroChargeRail, root),
          slipBoost = JsonCodec.floatOr("slipBoost", d#slipBoost, root),
          slipRange = JsonCodec.floatOr("slipRange", d#slipRange, root),
          slipWidth = JsonCodec.floatOr("slipWidth", d#slipWidth, root),
          nitroChargeDrift = JsonCodec.floatOr("nitroChargeDrift", d#nitroChargeDrift, root),
          nitroChargeSlip = JsonCodec.floatOr("nitroChargeSlip", d#nitroChargeSlip, root),
          nitroChargeNearMiss = JsonCodec.floatOr("nitroChargeNearMiss", d#nitroChargeNearMiss, root),
          nitroBoost = JsonCodec.floatOr("nitroBoost", d#nitroBoost, root),
          nitroDuration = JsonCodec.floatOr("nitroDuration", d#nitroDuration, root),
          nitroSteerPenalty = JsonCodec.floatOr("nitroSteerPenalty", d#nitroSteerPenalty, root),
          spinDuration = JsonCodec.floatOr("spinDuration", d#spinDuration, root),
          spinSlow = JsonCodec.floatOr("spinSlow", d#spinSlow, root),
          spinNitroLoss = JsonCodec.floatOr("spinNitroLoss", d#spinNitroLoss, root),
          nearMissDist = JsonCodec.floatOr("nearMissDist", d#nearMissDist, root),
          bumpPush = JsonCodec.floatOr("bumpPush", d#bumpPush, root),
          bumpSlow = JsonCodec.floatOr("bumpSlow", d#bumpSlow, root),
          bumpDuration = JsonCodec.floatOr("bumpDuration", d#bumpDuration, root),
          itemScoreBonus = JsonCodec.intOr("itemScoreBonus", d#itemScoreBonus, root),
          itemNitroCharge = JsonCodec.floatOr("itemNitroCharge", d#itemNitroCharge, root),
          itemBoostLow = JsonCodec.floatOr("itemBoostLow", d#itemBoostLow, root),
          itemBoostDuration = JsonCodec.floatOr("itemBoostDuration", d#itemBoostDuration, root),
          scorePerPass = JsonCodec.intOr("scorePerPass", d#scorePerPass, root),
          finishBonus = JsonCodec.intOr("finishBonus", d#finishBonus, root) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
