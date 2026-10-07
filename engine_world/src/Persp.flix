// Persp — 疑似 3D（2.5D）カメラの数学一式。世界の点を「前後 fwd・左右 lat」に分解し、
// fwd で割って（透視除算）画面座標に落とす。一人称ダンジョン・一人称レーサー・
// 背後カメラ STG のような「縦のストリップとビルボードで組む 3D 風」の共通土台。
//
// 扱うのは足元の 2D 線分を上下一様に押し出した縦のストリップと点だけ（任意メッシュ・
// pitch/roll・z バッファは保証しない — この割り切りが 2.5D のスコープ線）。
// 描画順は Painter（距離の遠→近）、壁面の収集は WallFaces、遮蔽は GridRay が受け持つ。
// 焦点距離・霧の係数・色の実体はゲーム側の意見（theme Doc など）で、ここは式だけを持つ。
//
// 利用例（WallFaces・Painter との組み立て）:
//   WallFaces.visibleFaces(solidAt, radius, cam#pos) で見える面を集め、
//   各面の a・b を toCam(cam, ...) でカメラ空間へ、
//   clipSegment(near, camA, camB) で近クリップし、
//   face と Clipped を { face = ..., clip = ... } の対で持ち、視程で filter して、
//   Painter.zOrdered(p -> p#clip#dist, zBase, zStride, ...) で zIndex を振り、
//   stripCorners で四隅を求めて遠→近に描く。
pub mod Persp {

    /// カメラの置き方。pos = 位置（世界座標）、yaw = 向き（ラジアン。
    /// 0 = +x 方向、+ で時計回り — 画面の y が下向きの座標系）。
    pub type alias Camera = { pos = Vec2.Vec2, yaw = Float64 }

    /// カメラ空間の 2D 点。fwd = 視線方向の奥行き、lat = 右向きの横ずれ。
    pub type alias CamPoint = { fwd = Float64, lat = Float64 }

    /// 画面への写し方（消失点 + 焦点距離 = 写し方の意見。画面サイズではない）。
    /// center = 消失点（画面 px）、fx / fy = 水平・垂直の焦点距離（px）。大きいほど狭角（ズーム）。
    /// 歩行の bob・ピッチ近似は center.y をずらすだけで表現できる（地平線が上下する）。
    pub type alias Projection = { center = Vec2.Vec2, fx = Float64, fy = Float64 }

    /// 近クリップ済みの線分。camA / camB = 切った後の端点（カメラ空間）、
    /// t0 / t1 = 元の線分のどの区間が残ったか（0..1。模様を世界に固定するため）、
    /// dist = 切った後の中点までの放射距離（並べ替えと明暗に使う）。
    pub type alias Clipped = {
        camA = CamPoint, camB = CamPoint,
        t0 = Float64, t1 = Float64, dist = Float64
    }

    /// h ストリップ（世界の縦のストリップ）を画面に落とした四隅。topA.x == botA.x を保証する
    /// （同じ端点の上下で x がずれて壁が歪む事故を式の形で防ぐ）。
    pub type alias Corners = {
        topA = Vec2.Vec2, topB = Vec2.Vec2,
        botA = Vec2.Vec2, botB = Vec2.Vec2
    }

    /// 世界の点をカメラ空間へ分解する。fwd = 視線方向の奥行き、lat = 右向きの横ずれ。
    pub def toCam(cam: Camera, p: Vec2.Vec2): CamPoint =
        let d = Vec2.sub(p, cam#pos);
        let fwdDir = { x = Vec2.cos(cam#yaw), y = Vec2.sin(cam#yaw) };
        let latDir = { x = -Vec2.sin(cam#yaw), y = Vec2.cos(cam#yaw) };
        { fwd = Vec2.dot(d, fwdDir), lat = Vec2.dot(d, latDir) }

    /// カメラからの放射距離（陰影・霧・ソートはこれを使う。fwd だけだと
    /// 真横の物が「近いのに遠い」扱いになる）。
    pub def dist(c: CamPoint): Float64 =
        Vec2.sqrt(c#fwd * c#fwd + c#lat * c#lat)

    /// 透視除算（x）。fwd が小さいほど大きく横に開く。
    /// 契約: クリップ済み（fwd > 0）の点にだけ使う — fwd 0 では割れない。
    pub def screenX(proj: Projection, c: CamPoint): Float64 =
        proj#center#x + proj#fx * c#lat / c#fwd

    /// 透視除算（y）。h = ストリップの中の高さ（世界単位。- が上・+ が下。
    /// 例: 高さ 1 の壁なら天井側 -0.5・床側 +0.5）。
    pub def screenY(proj: Projection, h: Float64, c: CamPoint): Float64 =
        proj#center#y + proj#fy * h / c#fwd

    /// 点の投影（クリップ済みの CamPoint → 画面 px）。大きさの換算は sizeAt へ —
    /// 縮尺の感触式（遠近のカーブ）はここにも sizeAt にも無く、ゲーム側が dist から決める。
    pub def projectCam(proj: Projection, h: Float64, c: CamPoint): Vec2.Vec2 =
        { x = screenX(proj, c), y = screenY(proj, h, c) }

    /// 世界単位の長さ worldLen が、奥行き c#fwd でどれだけの px に見えるか
    /// （縦の焦点距離 fy で換算。横で測りたければ呼び手が fx/fy 比を掛ける）。
    /// 換算だけで感触式は持たない — 見た目の縮尺をいじる式は依然ゲーム側の意見。
    /// 契約: クリップ済み（fwd > 0）の点にだけ使う — fwd 0 では割れない。
    pub def sizeAt(proj: Projection, worldLen: Float64, c: CamPoint): Float64 =
        proj#fy * worldLen / c#fwd

    /// 点の投影（世界座標から一息に）。fwd が spec#near 未満（真横〜後方）は None。
    /// spec: near = 近クリップ距離、h = ストリップの中の高さ（screenY と同じ向き）。
    pub def projectPoint(proj: Projection, cam: Camera,
                         spec: { near = Float64, h = Float64 },
                         p: Vec2.Vec2): Option[Vec2.Vec2] =
        let c = toCam(cam, p);
        if (c#fwd < spec#near) None else Some(projectCam(proj, spec#h, c))

    /// CamPoint の線形補間（線分の途中の点もカメラ空間では直線のまま）。
    pub def camLerp(a: CamPoint, b: CamPoint, t: Float64): CamPoint =
        { fwd = a#fwd + (b#fwd - a#fwd) * t, lat = a#lat + (b#lat - a#lat) * t }

    /// 線分の fwd 幅がこれ未満なら「near 面と平行」とみなす退化判定のしきい値。
    def flatSpanEps(): Float64 = 0.000001

    /// 近クリップ。fwd が near 未満の部分（カメラの真横〜後方）を切り落とし、
    /// 残った区間 t0..t1 とカメラ空間の端点・中点距離を返す。全部後方なら None。
    /// 縦のストリップは足元の 2D 線分を切るだけで多角形が切れる — これが 2.5D の旨み。
    pub def clipSegment(near: Float64, camA: CamPoint, camB: CamPoint): Option[Clipped] =
        if (camA#fwd < near and camB#fwd < near) None
        else {
            let span = camB#fwd - camA#fwd;
            let tAt = target -> if (Float64.abs(span) < flatSpanEps()) 0.0 else (target - camA#fwd) / span;
            let t0 = if (camA#fwd < near) tAt(near) else 0.0;
            let t1 = if (camB#fwd < near) tAt(near) else 1.0;
            let clippedA = camLerp(camA, camB, t0);
            let clippedB = camLerp(camA, camB, t1);
            let mid = camLerp(camA, camB, (t0 + t1) / 2.0);
            let midDist = Vec2.sqrt(mid#fwd * mid#fwd + mid#lat * mid#lat);
            Some({ camA = clippedA, camB = clippedB, t0 = t0, t1 = t1, dist = midDist })
        }

    /// 高さの区間（strip#hTop..strip#hBot）を画面の四隅へ。端点ごとに x を 1 回だけ求めるので
    /// topA.x == botA.x（topB.x == botB.x も同様）が式の形で保証される。
    pub def stripCorners(proj: Projection, strip: { hTop = Float64, hBot = Float64 },
                          camA: CamPoint, camB: CamPoint): Corners =
        let xA = screenX(proj, camA);
        let xB = screenX(proj, camB);
        { topA = { x = xA, y = screenY(proj, strip#hTop, camA) },
          botA = { x = xA, y = screenY(proj, strip#hBot, camA) },
          topB = { x = xB, y = screenY(proj, strip#hTop, camB) },
          botB = { x = xB, y = screenY(proj, strip#hBot, camB) } }

    /// 逆投影: 画面の走査線 sy が、高さ h の水平面のどの奥行きに当たるか。
    /// 市松の床・路面のストリップ（mode-7 風）の材料。sy が消失点の高さ（分母 0）に
    /// 近づくほど無限遠へ発散するので、呼び側は地平線より外の行を渡さない。
    pub def depthAtY(proj: Projection, h: Float64, sy: Float64): Float64 =
        proj#fy * h / (sy - proj#center#y)

    /// 距離霧の混合率。spec#base + d * spec#perDist を 0..spec#cap で止める
    /// （cap < 1 なら最遠でも完全には沈まない）。係数はゲームの意見として渡す。
    /// 色は `Color.mix(nearColor, farColor, fogAmount(...))` で混ぜる。
    pub def fogAmount(spec: { base = Float64, perDist = Float64, cap = Float64 },
                      d: Float64): Float64 =
        Num.clamp(0.0, spec#cap, spec#base + d * spec#perDist)
}
