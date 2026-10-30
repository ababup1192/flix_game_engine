// CameraRig — 「world のどこを・どれだけズームして映すか」を描画物の列に掛ける小さな道具箱。
// カメラは状態でなく毎フレーム導出する値なので、変換の保存や復元は要らない。
// 使い方: 映す中心は centerOn（zoom 込みの一発適用）、見える範囲は visibleRect、
// マウスの逆変換は toWorldPos。追従は followDelta、端で止めるのは clampCenter、
// 揺れは World に trauma / fxClock を持たせて addTrauma・tick・shakeOffset で導く。
// 逆引きの対: 一人称・疑似 3D の透視投影は Persp（別物）、ここは 2D の見下ろし・横視点。
pub mod CameraRig {

    // ── 中央映し（world 座標 ⇄ 画面座標。zoom は常に引数で受ける・等倍は 1.0 を渡す）──

    /// zoom の下限。これ未満（0・負・NaN 含む）は safeZoom がここへ丸める。
    pub def minZoom(): Float64 = 0.01

    /// zoom の上限。これ超過（Infinity 含む）は safeZoom がここへ丸める。
    pub def maxZoom(): Float64 = 1000.0

    /// zoom の防波堤: minZoom〜maxZoom の外（0 以下・NaN・Infinity・過大値）を範囲内へ丸める。
    /// 0 除算（visibleRect の design/zoom）・負値の鏡映・Infinity×0 の NaN 化を入口でまとめて防ぐ。
    /// zoom を受けるこのモジュールの関数はすべて内側でこれを通すので、呼び側の事前検査は不要。
    pub def safeZoom(z: Float64): Float64 =
        if (z >= minZoom() and z <= maxZoom()) z
        else if (z > maxZoom()) maxZoom()
        else minZoom()

    /// center を画面中央に zoom 倍（大きいほど寄る・等倍は 1.0）で映す:
    /// screen = (world − center) × zoom + design/2。置き場所だけでなく各 item の大きさも
    /// zoom 倍する（Render.scaled）ので、寄れば大きく・引けば小さく見える
    /// （範囲外の倍率は safeZoom が丸める）。HUD 等の画面固定物には掛けない。
    pub def centerOn(center: Vec2.Vec2, zoom: {zoom = Float64}, design: {design = Vec2.Vec2},
                     items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        let z = safeZoom(zoom#zoom);
        // 式は toScreenPos と同一。item ごとに safeZoom と design/2 を引き直させないため、
        // ループの外で 1 回だけ求めて展開して掛ける。
        let half = Vec2.div(design#design, 2.0);
        List.map(placed ->
            { at = Vec2.add(Vec2.mul(Vec2.sub(placed#at, center), z), half),
              item = Render.scaled(z, placed#item) }, items)

    /// world 座標 → 画面座標（centerOn が各 item の置き場所に使う式そのもの）:
    /// screen = (world − center) × zoom + design/2。item の列でなく点 1 つを写したいとき
    /// （物の目録を書く・当たりの矩形を画面で測る）に呼ぶ。toWorldPos がこの逆。
    pub def toScreenPos(center: Vec2.Vec2, zoom: {zoom = Float64}, design: {design = Vec2.Vec2},
                        world: {world = Vec2.Vec2}): Vec2.Vec2 =
        Vec2.add(Vec2.mul(Vec2.sub(world#world, center), safeZoom(zoom#zoom)),
                 Vec2.div(design#design, 2.0))

    /// center を中央に映したとき画面に見える world 範囲（大きさ design/zoom —
    /// 寄るほど狭く・引くほど広い）。背景タイルの敷き詰めなど「見える分だけ組む」計算に。
    pub def visibleRect(center: Vec2.Vec2, zoom: {zoom = Float64}, design: {design = Vec2.Vec2}): Rect2.Rect2 =
        let seen = Vec2.div(design#design, safeZoom(zoom#zoom));
        { position = Vec2.sub(center, Vec2.div(seen, 2.0)), size = seen }

    /// 画面座標 → world 座標（centerOn の逆変換）: world = (screen − design/2) / zoom + center。
    /// マウスで world の物を選ぶときに。往復不変条件: centerOn で screen へ移した点を
    /// これに通すと元の world 座標へ戻る（浮動小数の丸め内で）。
    pub def toWorldPos(center: Vec2.Vec2, zoom: {zoom = Float64}, design: {design = Vec2.Vec2},
                       screen: {screen = Vec2.Vec2}): Vec2.Vec2 =
        let z = safeZoom(zoom#zoom);
        Vec2.add(Vec2.div(Vec2.sub(screen#screen, Vec2.div(design#design, 2.0)), z), center)

    /// camera の center を「見えている範囲（seen = design/zoom）が bounds の内側に収まる」位置へ
    /// 収める（Godot の Camera2D limits 相当）。軸ごとに bounds が seen より狭ければ
    /// bounds の中央に固定する。App.withCameraBounds がこれを毎フレーム適用する。
    pub def clampCenter(bounds: {bounds = Rect2.Rect2}, seen: {seen = Vec2.Vec2},
                        center: Vec2.Vec2): Vec2.Vec2 =
        { x = clampCenterAxis(bounds#bounds#position#x, bounds#bounds#size#x, seen#seen#x, center#x),
          y = clampCenterAxis(bounds#bounds#position#y, bounds#bounds#size#y, seen#seen#y, center#y) }

    /// 1軸ぶんの clampCenter: 視界が bounds より広ければ中央固定、収まるなら
    /// 「視界の端が bounds を出ない」範囲へ center を収める。
    def clampCenterAxis(lo: Float64, size: Float64, seen: Float64, c: Float64): Float64 =
        if (seen >= size) lo + size / 2.0
        else clampAxis(lo + seen / 2.0, lo + size - seen / 2.0, c)

    /// 視差レイヤの見かけの camera 中心: 画面中央と本来の center を factor で混ぜる。
    /// factor = 1.0 で主レイヤと同速（同じ景色）、0.0 で画面に貼り付く（無限遠）。
    /// 遠景 0.2〜0.5・近景 1.5 のように使う。zoom は全レイヤ共通に掛かる。
    pub def parallaxCenter(factor: Float64, center: Vec2.Vec2, design: {design = Vec2.Vec2}): Vec2.Vec2 =
        let mid = Vec2.div(design#design, 2.0);
        Vec2.add(mid, Vec2.mul(Vec2.sub(center, mid), factor))

    // ── 追従（不感帯 + 寄せ率 + クランプ）──

    /// 追従の仕様: 不感帯の幅と寄せ率（1 秒あたり）。
    pub type alias Follow = { deadzone = Float64, k = Float64 }

    /// target が current±deadzone の不感帯を出たぶん × min(1, k×dt) の移動量。
    /// current は「いま画面が見ている中心」— 呼び手が自分の座標系で計算して渡し、返る移動量を自分で足す。
    pub def followDelta(spec: Follow, dt: Float64, target: Float64, current: Float64): Float64 =
        let offset = target - current;
        let over =
            if (offset > spec#deadzone) offset - spec#deadzone
            else if (offset < -spec#deadzone) offset + spec#deadzone
            else 0.0;
        over * Float64.min(1.0, spec#k * dt)

    /// lo..hi へ収める（hi < lo なら lo）。カメラをレベルの内側に留めるのに使う。
    pub def clampAxis(lo: Float64, hi: Float64, x: Float64): Float64 =
        Float64.max(lo, Float64.min(x, hi))

    // ── 画面シェイク（trauma 方式）──

    /// シェイクの調整値。maxOffset は trauma 満タン（1.0）のときの揺れ幅（px）、
    /// freq は揺れの速さ（ノイズの格子点が 1 秒に進む数）、decayPerSecond は trauma の
    /// 1 秒あたりの減衰量。
    pub type alias ShakeSpec = { maxOffset = Float64, freq = Float64, decayPerSecond = Float64 }

    /// 揺れを積む: trauma に amount を加算する（上限 1.0）。減衰（tick）より速く積めば蓄積し、
    /// 単発では出ない大揺れが連打で現れる。trauma フィールドを持つ record ならそのまま渡せる。
    pub def addTrauma(amount: Float64, state: { trauma = Float64 | r }): { trauma = Float64 | r } =
        { trauma = Float64.min(1.0, state#trauma + amount) | state }

    /// 揺れの経年: trauma を減衰させ（下限 0.0）、通し時計 fxClock を進める。毎フレーム 1 回 dt を渡す。
    pub def tick(dt: Float64, spec: ShakeSpec, state: { trauma = Float64, fxClock = Float64 | r }): { trauma = Float64, fxClock = Float64 | r } =
        { trauma = Float64.max(0.0, state#trauma - spec#decayPerSecond * dt),
          fxClock = state#fxClock + dt | state }

    /// trauma からの揺れ幅（px）: trauma² × maxOffset。二乗なので単発の小さな trauma は
    /// ほとんど揺れず、蓄積すると急に効く。
    pub def shakeStrength(trauma: Float64, maxOffset: {maxOffset = Float64}): Float64 =
        if (trauma <= 0.0) 0.0
        else trauma * trauma * maxOffset#maxOffset

    /// シェイクのオフセット（px）: 揺れ幅（shakeStrength）× 滑らかノイズ [-1, 1]。
    /// fxClock は常に進む時計（ノイズの位相）。trauma が 0 なら揺れない。
    pub def shakeOffset(spec: ShakeSpec, state: { trauma = Float64, fxClock = Float64 | r }): Vec2.Vec2 =
        let strength = shakeStrength(state#trauma, maxOffset = spec#maxOffset);
        if (strength <= 0.0) Vec2.zero()
        else {
            let t = state#fxClock * spec#freq;
            { x = strength * smoothNoise(t, 0),
              y = strength * smoothNoise(t, 1) }
        }

    /// 滑らかな 1D ノイズ [-1, 1]: 整数の格子点に Hash01 の値を置き、間を quintic フェード
    /// （6t⁵-15t⁴+10t³）で補間する。格子点でちょうど Hash01 に一致し、間は連続に繋がるので、
    /// カメラが飛び回らず滑らかに揺れる。channel で x/y の系列を分ける。
    pub def smoothNoise(t: Float64, channel: Int32): Float64 =
        let i = Float64.floor(t);
        let frac = t - i;
        let fade = frac * frac * frac * (frac * (frac * 6.0 - 15.0) + 10.0);
        let idx = Num.floorInt(i);
        let a = 2.0 * Hash01.at(idx, channel) - 1.0;
        let b = 2.0 * Hash01.at(idx + 1, channel) - 1.0;
        a + (b - a) * fade
}
