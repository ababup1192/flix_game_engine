// Shadow — 単一光源が壁（凸/凹の頂点列）に落とすハードシャドウの幾何を導く純関数。光そのもの・壁そのものには触れない。
// 遮蔽物は不透明: itemsFor は胴体も影と同じ濃度で沈める（ガラスの壁にしない）。
// 光向き面には擬似シェーディングとして細いフチ（本物の法線ではない）を選択で足せる。
pub mod Shadow {

    /// 遮蔽物 1 個ぶんの頂点列（絶対座標・閉じたポリゴンとして扱う）に対して光が落とす
    /// 影の四角形の列を返す。頂点順は時計回り・反時計回りのどちらでもよい
    /// （Triangulate.signedArea の符号を見て毎回そろえるので、呼び側は向きを気にしなくてよい）。
    /// 辺ごとに「光から見て背を向けている辺か」を内積の符号で判定し、
    /// 背面の辺だけを光の反対方向へ extrudeLength ぶん伸ばして四角形にする。
    /// 光がポリゴンの内側にある・光と辺が一直線という縮退でも、全辺ぶんの四角形を返すだけで
    /// 例外を出さない（背面判定にちょうど0を含めているので必ずどちらかに決まる）。
    /// n=2（閉じていない線分1本）の遮蔽物でも、辺2本（往復）のうち背面側の1本だけが
    /// 影四角形になり正しく1枚返る（薄い壁は多角形にせず線分で渡してよい）。
    pub def shadowQuads(lightAt: Vec2.Vec2, occluder: List[Vec2.Vec2],
                        extrudeLength: Float64): List[List[Vec2.Vec2]] =
        let n = List.length(occluder);
        if (n < 2)
            Nil
        else {
            let sign = if (Triangulate.signedArea(occluder) < 0.0) -1.0 else 1.0;
            let verts = List.toVector(occluder);
            List.range(0, n)
                |> List.filterMap(i -> shadowOfEdge(lightAt,
                    Vector.get(i, verts), Vector.get(Int32.modulo(i + 1, n), verts),
                    sign, extrudeLength))
        }

    /// 辺 (v1, v2) の外向き法線と「辺中点→光」方向の内積を見て、光に背を向けている
    /// （内積<=0。ちょうど0＝光と辺が一直線も背面側として扱う — 光が辺の真横にあるとき
    /// 「影を落とさない」方が、際どい角度で明るい面が影を持つ矛盾より自然なため）辺だけ
    /// 影四角形にする。前面の辺は None。
    def shadowOfEdge(lightAt: Vec2.Vec2, v1: Vec2.Vec2, v2: Vec2.Vec2,
                     sign: Float64, extrudeLength: Float64): Option[List[Vec2.Vec2]] =
        match edgeFacing(lightAt, v1, v2, sign) {
            case Facing.Back => {
                let v1p = extrudeAway(lightAt, v1, extrudeLength);
                let v2p = extrudeAway(lightAt, v2, extrudeLength);
                Some(v1 :: v2 :: v2p :: v1p :: Nil)
            }
            case Facing.Front => None
        }

    /// 辺 (v1, v2) が光に対して背を向けているか正対しているか（shadowOfEdge と rimOfEdge の
    /// 共通判定 — 影四角形とフチのストリップは常に相補な辺の集合になるべきで、判定がずれると
    /// 同じ辺が両方に描かれる／どちらにも描かれない事故になる）。
    enum Facing with Eq {
        case Back
        case Front
    }

    def edgeFacing(lightAt: Vec2.Vec2, v1: Vec2.Vec2, v2: Vec2.Vec2, sign: Float64): Facing =
        let d = Vec2.sub(v2, v1);
        let normal = Vec2.mul({ x = d#y, y = -d#x }, sign);
        let mid = Vec2.mul(Vec2.add(v1, v2), 0.5);
        let towardLight = Vec2.sub(lightAt, mid);
        if (Vec2.dot(normal, towardLight) > 0.0) Facing.Front else Facing.Back

    /// 頂点 v を「光→v」の方向へ length だけ延ばした点（光と v が重なる縮退では
    /// 方向が定まらないので v をそのまま返す＝退化四角形になるが例外は出ない）。
    def extrudeAway(lightAt: Vec2.Vec2, v: Vec2.Vec2, length: Float64): Vec2.Vec2 =
        let dir = Vec2.normalized(Vec2.sub(v, lightAt));
        Vec2.add(v, Vec2.mul(dir, length))

    /// occluder の各辺のうち光に正対する辺（前面＝光向きの面）に沿って、幅 rimWidth の
    /// ストリップの四隅を返す。ストリップはポリゴンの内側（外向き法線と逆側）へ詰める — 外側に出すと
    /// 壁の輪郭からはみ出て光が漏れて見えるため。rimWidth<=0 や n<2 では空を返す。
    /// 戻り値は (ストリップの4頂点, 距離減衰係数0..1) のタプル — 手前の遮蔽物の影に入っている辺や
    /// 光から遠い辺は除外・減光してから返す（他の occluder の影の中で光っては見えないため）。
    pub def rimQuads(lightAt: Vec2.Vec2, occluder: List[Vec2.Vec2], rimWidth: Float64,
                     radius: Float64, allShadowQuads: List[List[Vec2.Vec2]]): List[(List[Vec2.Vec2], Float64)] =
        let n = List.length(occluder);
        if (n < 2 or rimWidth <= 0.0)
            Nil
        else {
            let sign = if (Triangulate.signedArea(occluder) < 0.0) -1.0 else 1.0;
            let verts = List.toVector(occluder);
            List.range(0, n)
                |> List.filterMap(i -> rimOfEdge(lightAt,
                    Vector.get(i, verts), Vector.get(Int32.modulo(i + 1, n), verts),
                    sign, rimWidth, radius, allShadowQuads))
        }

    /// 辺 (v1, v2) が光に正対する（shadowOfEdge の逆）ときだけ、内側へ幅 rimWidth の
    /// ストリップを Quad.strip で作る。Quad.strip の法線は v1->v2 を 90 度反時計回りに回した向きで、
    /// shadowOfEdge が使う外向き法線（sign 込み）とはちょうど逆を向く。よって
    /// 「内側（外向き法線の逆）」は strip 座標では +sign 側になる。
    /// 前面判定のあとさらに、辺の中点が他の影の中なら除外し（遮蔽）、光からの距離で
    /// 減衰係数を出して0以下なら除外する（遠すぎるフチは描かない）。
    def rimOfEdge(lightAt: Vec2.Vec2, v1: Vec2.Vec2, v2: Vec2.Vec2, sign: Float64, rimWidth: Float64,
                 radius: Float64, allShadowQuads: List[List[Vec2.Vec2]]): Option[(List[Vec2.Vec2], Float64)] =
        match edgeFacing(lightAt, v1, v2, sign) {
            case Facing.Back  => None
            case Facing.Front =>
                let mid = Vec2.mul(Vec2.add(v1, v2), 0.5);
                if (rimBlocked(mid, allShadowQuads))
                    None
                else {
                    let falloff = rimFalloff(lightAt, mid, radius);
                    if (falloff <= 0.0)
                        None
                    else
                        Some((Quad.strip(v1, v2, 0.0, sign * rimWidth), falloff))
                }
        }

    /// 辺の中点が、他の遮蔽物が落とす影四角形のいずれかに含まれているか。
    /// 辺の一部だけ影に入っているケースは中点の二値判定で割り切る（ハードシャドウの流儀）。
    def rimBlocked(midpoint: Vec2.Vec2, allShadowQuads: List[List[Vec2.Vec2]]): Bool =
        allShadowQuads |> List.exists(quad -> containsPoint(quad, midpoint))

    /// 光からの距離に応じた減衰係数（radius 以内=1.0、radius〜2*radius で線形に1.0→0.0、
    /// それ以遠=0.0）。他モジュールの値に頼らず Shadow.flix 単体で完結させるための自前の式。
    def rimFalloff(lightAt: Vec2.Vec2, midpoint: Vec2.Vec2, radius: Float64): Float64 =
        let dist = Vec2.distanceTo(lightAt, midpoint);
        if (dist <= radius)
            1.0
        else if (dist >= radius * 2.0)
            0.0
        else
            1.0 - (dist - radius) / radius

    /// 影を無限遠まで伸ばしたとみなせる目安の長さ（design解像度が数百px程度のゲーム向け）。
    /// 実際の値は画面対角線に応じて呼び側（feature_lab 等）が決めてよい。
    pub def infiniteExtrude(): Float64 = 2000.0

    // ── HitShape → 遮蔽ポリゴン ──

    /// 円をN角形近似した頂点列（絶対座標）。segments が大きいほど滑らかだが影四角形も増える。
    pub def occluderOfCircle(center: Vec2.Vec2, radius: Float64, segments: Int32): List[Vec2.Vec2] =
        List.range(0, segments) |> List.map(i ->
            Vec2.add(center, Vec2.onEllipse({ x = radius, y = radius },
                Int32.toFloat64(i) / Int32.toFloat64(segments))))

    /// 矩形の4頂点（絶対座標・中心+幅高さ）。左上→右上→右下→左下の順（画面上で時計回り）。
    pub def occluderOfBox(center: Vec2.Vec2, size: Vec2.Vec2): List[Vec2.Vec2] =
        let hw = size#x / 2.0;
        let hh = size#y / 2.0;
        { x = center#x - hw, y = center#y - hh } ::
        { x = center#x + hw, y = center#y - hh } ::
        { x = center#x + hw, y = center#y + hh } ::
        { x = center#x - hw, y = center#y + hh } ::
        Nil

    /// Hit.HitShape の宣言（持ち主位置からのオフセット）から遮蔽ポリゴンを作る。
    /// 円の分割数は固定（見た目の滑らかさと影四角形の枚数のバランスを取った既定値）。
    pub def occluderOf(pos: Vec2.Vec2, shape: Hit.HitShape): List[Vec2.Vec2] =
        match shape {
            case Hit.HitShape.CircleH(c) =>
                occluderOfCircle({ x = pos#x + c#dx, y = pos#y + c#dy }, c#r, 12)
            case Hit.HitShape.BoxH(b) =>
                occluderOfBox({ x = pos#x + b#dx, y = pos#y + b#dy }, { x = b#w, y = b#h })
        }

    // ── Light との合成 ──

    /// itemsFor の設定。darkness は影の濃さ0..1（1で完全な黒）、z は影のzIndex、
    /// extrudeLength は影を伸ばす長さ（画面対角線より十分大きい値を渡す。infiniteExtrude が目安）。
    /// rimWidth は光向き面に沿って描く照り返しフチの太さ（design px。0.0 でフチ無し=互換）、
    /// rimStrength はその強さ（Add の alpha。defaultRimWidth/defaultRimStrength が既定の目安）。
    pub type alias ShadowConfig = { darkness = Float64, z = Int32, extrudeLength = Float64,
                                    rimWidth = Float64, rimStrength = Float64 }

    /// rimWidth の既定の目安（design px）。壁の輪郭からはみ出さない程度の細さ。
    pub def defaultRimWidth(): Float64 = 2.5

    /// rimStrength の既定の目安（Add の alpha）。フチが白飛びしない程度の強さ。
    pub def defaultRimStrength(): Float64 = 0.5

    /// occluders それぞれについて、(1) 遮蔽物自身の胴体を光と同じ darkness・z の Multiply 黒 Poly、
    /// (2) 背面辺が落とす影四角形、(3) 前面辺（光向き面）に沿ったフチのストリップ（rimWidth>0 のときだけ）
    /// を並べる。遮蔽物は不透明: 胴体も影と同じ濃度で沈めることで、光の反対側の面まで
    /// 透けて見える「ガラスの壁」にしない。
    /// Light.singleLightItems の結果と List.append で好きな順に重ねるのは呼び側の仕事
    /// （穴あきオーバーレイとどちらの上に置くかはシーンの見た目次第のため、ここでは決めない）。
    /// フチのストリップは light#radius を使って距離減衰し、他の遮蔽物の影に入っていれば描かない
    /// （手前の壁に光が遮られているのに奥のフチだけ光る、という矛盾を避けるため）。
    pub def itemsFor(light: Light.Light, occluders: List[List[Vec2.Vec2]],
                     cfg: ShadowConfig): List[Render.PlacedItem] =
        let bodies = occluders |> List.map(occluder -> blackQuad(occluder, cfg#darkness, cfg#z));
        // 全 occluder ぶんの影四角形を1回だけ計算し、影の描画とフチの遮蔽判定(rimBlocked)の
        // 両方で使い回す。自己遮蔽（凹ポリゴンが自分自身のくぼみで影になる）も特別扱いせず
        // この共有集合に自然に含まれる。
        let allShadowQuads = occluders |> List.flatMap(occluder -> shadowQuads(light#at, occluder, cfg#extrudeLength));
        let quads = allShadowQuads |> List.map(quad -> blackQuad(quad, cfg#darkness, cfg#z));
        let rims = if (cfg#rimWidth > 0.0)
                occluders
                    |> List.flatMap(occluder -> rimQuads(light#at, occluder, cfg#rimWidth, light#radius, allShadowQuads))
                    |> List.map(pair -> {
                        let (quad, falloff) = pair;
                        rimQuad(quad, light#color, cfg#rimStrength * falloff, cfg#z)
                    })
            else List.empty();
        List.flatten(bodies :: quads :: rims :: Nil)

    /// 頂点列 quad を Multiply・alpha=darkness の黒 Poly にする（絶対座標のまま at=zero）。
    def blackQuad(quad: List[Vec2.Vec2], darkness: Float64, z: Int32): Render.PlacedItem =
        let black = { r = 0.0, g = 0.0, b = 0.0 };
        { at = Vec2.zero(),
          item = RawDraw.polygon(quad, black, z)
              |> Render.blended(DrawCmd.BlendMode.Multiply)
              |> Render.fade(darkness) }

    /// 頂点列 quad を Add・alpha=strength・light 色の Poly にする（絶対座標のまま at=zero）。
    /// z は胴体・影四角形と同じ値を渡す（フチは胴体の縁の上に重ねて描く飾りのため、
    /// 別の重なり順を持たせる理由がない）。
    def rimQuad(quad: List[Vec2.Vec2], color: Color, strength: Float64, z: Int32): Render.PlacedItem =
        { at = Vec2.zero(),
          item = RawDraw.polygon(quad, color, z)
              |> Render.blended(DrawCmd.BlendMode.Add)
              |> Render.fade(strength) }

    // ── 幾何ユーティリティ（テストの「影が壁を透過しない」検証にも使う） ──

    /// 点 p が凸四角形 quad（4頂点・向きは時計回り/反時計回りのどちらでもよい）の内側にあるか。
    /// shadowQuads が返す四角形は必ず凸なので、4辺との外積の符号がすべて揃えば内側。
    /// 境界は内側に含めない（Hit の「ちょうど接するのは外」の線引きに合わせる）。
    pub def containsPoint(quad: List[Vec2.Vec2], p: Vec2.Vec2): Bool =
        match quad {
            case a :: b :: c :: d :: Nil =>
                let edges = (a, b) :: (b, c) :: (c, d) :: (d, a) :: Nil;
                let signs = edges |> List.map(edge -> {
                    let (e1, e2) = edge;
                    Vec2.cross(Vec2.sub(e2, e1), Vec2.sub(p, e1))
                });
                List.forAll(s -> s > 0.0, signs) or List.forAll(s -> s < 0.0, signs)
            case _ => false
        }
}
