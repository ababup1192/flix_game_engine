// Material — デュアルタイル(DualGrid.Tile)に「質感」を着せる層。壁も水もマグマも、
// 塗り1枚+輪郭のフチ(+持ち上げの前面)という同じ1本の経路(place)を通る。
// どの角にどの質感を置くかの表はゲーム側が持ち、ここは1タイルぶんの
// 純粋な組み立てだけ — マップにもテーマにも触れない。
// 「チップ絵を描かず色と質感で地形を作る」3層(DualGrid/Material/Terrain)の
// 初学者向け概念説明は docs/dual-grid.md。

pub mod Material {

    /// 粒の形。Speck = 小さな四角が明滅する(水のきらめき)。
    /// Scales = 下向きの三日月(弧)を整った千鳥格子に敷き、上の弧が下の弧の頭を隠して
    /// 魚の鱗に見せる。隣どうしは色ランプの位相が半周ずれて交互に脈打つ(市松の千鳥)。
    /// 色は3色ランプ(deep→mid→lite)を時刻で回すだけ(図形は動かさない)
    /// = 流れて見える(SNESの色循環)。
    /// Bubble = 円がゆっくり湧いて膨らみ、終端で細いリング+飛沫線に弾ける(マグマの泡)。
    /// Glow = 加算の淡い光の粒がゆっくり明滅する(マグマ自身の照り)。
    pub enum SurfaceShape {
        case Speck
        case Scales
        case Bubble
        case Glow
    }

    /// 表面の粒のパラメータ1式(fx.json の語彙にそろえた命名)。
    /// count = セル毎の粒数(Scales はセル一辺あたりの粒数)、
    /// channel = 座標ハッシュの起点(粒の位置と位相をここから引く)、
    /// twinkleRate = 明滅の速さ(sin の角速度)、
    /// alphaBase/alphaSpan = 濃さの下限と振れ幅、
    /// sizeBase/sizeSpan = 大きさの下限と振れ幅 px(Speck の幅・Glow / Scales の半径)、
    /// period = 1周期の秒数(Bubble。時刻を折り返す閉形式ループの長さ)、
    /// riseSpeed = 上へ湧く速さ px/s(Bubble)、sizeTo = 消える瞬間の半径 px(Bubble)、
    /// blend = 重ね方(泡や光を加算にしたいとき用)。
    /// color/color3/color2 = 色ランプの3色(Scales の deep→mid→lite。色循環はこの
    /// 3色の上を回る。他の形は color/color2 だけ使い color3 は color2 と同値で持つ)。
    pub type alias SurfaceFx = {
        shape = SurfaceShape,
        count = Int32,
        color = Color,
        color2 = Color,
        color3 = Color,
        channel = Int32,
        twinkleRate = Float64,
        alphaBase = Float64,
        alphaSpan = Float64,
        sizeBase = Float64,
        sizeSpan = Float64,
        period = Float64,
        riseSpeed = Float64,
        sizeTo = Float64,
        blend = DrawCmd.BlendMode
    }

    /// 静的なむら1式(深い水の暗がり・マグマの冷えた皮)。時間を持たないので
    /// prebuilt に生成できる — 表面の粒(SurfaceFx)と分けるのはそのため。
    /// 大きさ・濃さ・置き場所は全部座標ハッシュ(保存なしで場所ごとの個性)。
    pub type alias BlotchFx = {
        color = Color,
        channel = Int32,
        alphaBase = Float64,
        alphaSpan = Float64,
        sizeBase = Float64,
        sizeSpan = Float64
    }

    /// 地肌の粒。面の中に細かい点をたくさん置いて、ベタ塗りののっぺりを消す。
    /// sparkle が「たまに光る 3 粒」なのに対し、こちらは「常にある十数粒」— 土や砂の質感。
    /// 面の形（デュアルグリッドが決めた輪郭）の内側にだけ入るので、四角いタイルを重ねる
    /// のと違って縁からはみ出さない。幅 1 マスの道のように「内側」が無い形でも効く。
    /// channel 200 から 4×count ぶんを使う範囲（きらめき・むら・泡のどれとも重ならない）。
    /// 粒は毎フレーム 1 マスに count 個の箱を生むので、広い盤で使うときは静的レイヤーへ
    /// 生成するか count を下げる — 40×30 マス × 16 個で 1 フレーム 19,200 個になる。
    pub def grain(color: Color): SurfaceFx =
        { shape = SurfaceShape.Speck,
          count = 16,
          color = color,
          color2 = color,
          color3 = color,
          channel = 200,
          twinkleRate = 0.0,
          alphaBase = 0.38,
          alphaSpan = 0.30,
          sizeBase = 1.0,
          sizeSpan = 1.0,
          period = 0.0,
          riseSpeed = 0.0,
          sizeTo = 0.0,
          blend = DrawCmd.BlendMode.Normal }

    /// 水のきらめきの設定。粒3個・幅1〜3px・濃さの山0.8 — 個数や幅を固定で絞ると
    /// 画面でほぼ見えなくなるため、粒数と幅にばらつきを持たせて強めにしてある。
    /// channel 71 は泡(84..)や角スタイル(81)と重ならない範囲。
    pub def sparkle(color: Color): SurfaceFx =
        { shape = SurfaceShape.Speck,
          count = 3,
          color = color,
          color2 = color,
          color3 = color,
          channel = 71,
          twinkleRate = 3.0,
          alphaBase = 0.25,
          alphaSpan = 0.55,
          sizeBase = 1.0,
          sizeSpan = 2.0,
          period = 0.0,
          riseSpeed = 0.0,
          sizeTo = 0.0,
          blend = DrawCmd.BlendMode.Normal }

    /// 面の鱗パターン。丸の敷き詰めをやめ、下向きの三日月(弧)を整った千鳥格子に
    /// 敷いて魚の鱗に見せる。弧は1枚だけ(影の弧はやめ、暗さは deep 色へまとめて描画数を半減)。
    /// 色は3色ランプ(tones#deep → tones#mid → tones#lite)を「格子の偶奇で半周 + floor(t*rate)」で
    /// 回すだけ(図形は動かさず色だけ回す = 流れて見える)。隣の弧は位相が半周ずれて交互に
    /// 脈打つ(ハッシュのばらつきはやめ、市松の千鳥に整える)。rate = 色循環の速さ
    /// (マグマは水より遅くして粘りを出す)。count = セル一辺あたりの鱗の数
    /// (2 で 2×2=4 点・弧1枚ずつ = セル4枚に抑える)。
    /// channel 104 はきらめき(71..79)・むら(61..)・泡(84..)・照り(96..)と重ならない範囲。
    pub def scales(tones: { deep = Color, mid = Color, lite = Color }, rate: Float64): SurfaceFx =
        { shape = SurfaceShape.Scales,
          count = 2,
          color = tones#deep,
          color3 = tones#mid,
          color2 = tones#lite,
          channel = 104,
          twinkleRate = rate,
          alphaBase = 0.75,
          alphaSpan = 0.0,
          sizeBase = 3.4,
          sizeSpan = 1.0,
          period = 0.0,
          riseSpeed = 0.0,
          sizeTo = 0.0,
          blend = DrawCmd.BlendMode.Normal }

    /// マグマの泡の設定。泡は疎(セルに 0〜1 個・出現はハッシュで間引く)で一生 1 秒未満。
    /// 膨らむ塗り円 → 終端で細いリング(円周のみ)が急拡大しながら薄れ、放射状の短い飛沫線が
    /// 飛ぶ → 消滅(弾けても丸いままにしない)。count は 1 に絞り、出現もハッシュで間引いて
    /// 密度を抑える。twinkleRate は出現率のしきい(0..1)。
    /// channel 84 はきらめき(71..79)や角スタイル(81)と重ならない範囲。
    pub def bubble(color: Color): SurfaceFx =
        { shape = SurfaceShape.Bubble,
          count = 1,
          color = color,
          color2 = color,
          color3 = color,
          channel = 84,
          twinkleRate = 0.55,
          alphaBase = 0.22,
          alphaSpan = 0.6,
          sizeBase = 0.0,
          sizeSpan = 0.0,
          period = 2.4,
          riseSpeed = 1.5,
          sizeTo = 2.6,
          blend = DrawCmd.BlendMode.Normal }

    /// マグマ自身の照り(加算の淡い橙の光の粒)。セルに1〜2個、ゆっくり明滅する。
    /// 加算にするのは「光を反射している」でなく「自分で光っている」に見せるため。
    pub def glow(color: Color): SurfaceFx =
        { shape = SurfaceShape.Glow,
          count = 2,
          color = color,
          color2 = color,
          color3 = color,
          channel = 96,
          twinkleRate = 0.7,
          alphaBase = 0.1,
          alphaSpan = 0.15,
          sizeBase = 2.4,
          sizeSpan = 1.8,
          period = 0.0,
          riseSpeed = 0.0,
          sizeTo = 0.0,
          blend = DrawCmd.BlendMode.Add }

    /// 静的なむらの設定(色だけ差し替えて水にもマグマにも使う)。セルに1〜2個、
    /// 直径4〜7px の薄い暗色 — 全面一色のベタを有機的に破る係。channel 61 は
    /// 粒(71..)・泡(84..)と重ならない範囲。水とマグマは同じセルに来ないので channel は共用。
    pub def blotch(color: Color): BlotchFx =
        { color = color,
          channel = 61,
          alphaBase = 0.1,
          alphaSpan = 0.08,
          sizeBase = 2.0,
          sizeSpan = 1.5 }

    /// 輪郭フチの色の決め方。Uniform = 全周同じ色(水の岸辺線)。
    /// ByNormal = 外向き法線で選ぶ(壁: 上向き=光の当たる天板 top、下向き=足元の陰 shade、
    /// 横向き=side)。
    pub enum EdgeKind {
        case Uniform(Color)
        case ByNormal({ top = Color, side = Color, shade = Color })
    }

    /// 立体感の決め方。Flat = 持ち上げない(水面)。Lifted = 輪郭を height ぶん持ち上げ、
    /// 南向きの辺に立ち面(front)と根元の締め(shade)を張る(壁)。clipToFloor = 持ち上げた
    /// 分が北隣の床にかぶさるとき、許可矩形で切り落とすか。
    pub enum HeightProfile {
        case Flat
        case Lifted({ height = Float64, front = Color, shade = Color, clipToFloor = Bool })
    }

    /// 質感1式。fill = 塗り、edge/edgeWidth = 輪郭フチ、forceStyle = 角の形の固定
    /// (None = 場所ごとに混ぜる。水は丸固定 — 水面はどのテーマでも角ばらせない)、
    /// jitter = 対角辺の岩肌の揺らぎ、surface = 表面の時間演出の重ね(空 = 演出なし)、
    /// blotch = 静的なむら(prebuilt に生成する)、
    /// mottle = セル別の明度ゆらぎの最大量(0 = なし。耕した畑のパッチワーク —
    /// セル座標ハッシュ×この値ぶん白へ近づける。lighten(fill, hash*mottle) と等価)、
    /// height = 立体感。
    pub type alias Spec = {
        fill = Color,
        edge = EdgeKind,
        edgeWidth = Float64,
        forceStyle = Option[DualGrid.CornerStyle],
        jitter = Float64,
        surface = List[SurfaceFx],
        blotch = Option[BlotchFx],
        mottle = Float64,
        height = HeightProfile
    }

    /// 解決済みタイル1枚に質感を着せる。多角形ごとに 前面 → 塗り → フチの stroke の順で並べる —
    /// 同じ z の重なりは並び順が前後を決めるため、この順は見た目の一部。
    /// 天面は輪郭を丸ごと (0,-h) 平行移動 — 頂点ごとに持ち上げ量を変えると坂に見えるため。
    pub def place(spec: Spec, tile: DualGrid.Tile, origin: Vec2.Vec2,
                  z: { fill = Int32, stroke = Int32 }): List[Render.PlacedItem] =
        let t = tile#size;
        let flags = flagsOfCase(tile#caseIndex);
        let (h, cut) = match spec#height {
            case HeightProfile.Flat      => (0.0, (poly -> poly :: Nil))
            case HeightProfile.Lifted(l) =>
                // 北隣が両方埋まっているなら床に食み込みようがないので、切る手間を省く。
                let clip = if (l#height <= 0.0 or not l#clipToFloor or (flags#tl and flags#tr))
                               (poly -> poly :: Nil)
                           else (poly -> clipAllowed(allowedRects(t, l#height, flags), poly));
                (l#height, clip)
        };
        let liftPts = pts -> pts |> List.map(v -> ({ x = v#x, y = v#y - h }: Vec2.Vec2));
        let placeAt = (color, zIndex, poly) ->
            { at = origin, item = RawDraw.polygon(poly, color, zIndex) };
        List.zip(tile#polys, tile#edges) |> List.flatMap(match (poly, edges) -> {
            // 前面: 南向きの輪郭辺から根元までの立ち面(+根元の締めの細帯)。
            let fronts = match spec#height {
                case HeightProfile.Flat      => Nil
                case HeightProfile.Lifted(l) => edges |> List.flatMap(edge ->
                    if (l#height <= 0.0 or edge#border or edge#normal#y <= 0.25) Nil
                    else List.zip(edge#points, List.drop(1, edge#points))
                        |> List.flatMap(match (a, b) -> List.append(
                            cut({ x = a#x, y = a#y - l#height } ::
                                { x = b#x, y = b#y - l#height } :: b :: a :: Nil)
                                |> List.map(placeAt(l#front, z#fill)),
                            cut(a :: b :: { x = b#x, y = b#y - 1.6 } ::
                                { x = a#x, y = a#y - 1.6 } :: Nil)
                                |> List.map(placeAt(l#shade, z#stroke)))))
            };
            let fills = cut(liftPts(poly)) |> List.map(placeAt(spec#fill, z#fill));
            let strokes = edges |> List.flatMap(edge ->
                if (edge#border) Nil
                else DualGrid.strokeQuads(liftPts(edge#points), edge#normal, spec#edgeWidth)
                    |> List.flatMap(cut)
                    |> List.map(placeAt(edgeColor(spec#edge, edge#normal), z#stroke)));
            List.append(fronts, List.append(fills, strokes))
        })

    /// このセルの上下左右の隣も同じ液体か(岸の判定に使う)。true = 液体(そちらは陸地でない)。
    /// マップは Material の外(Surfaces)が知っているので、この旗で注入する — Material は
    /// マップにもテーマにも触れない縫い目を保つ。四方とも true = 完全な内側のセル。
    pub type alias Edges = { n = Bool, s = Bool, e = Bool, w = Bool }

    /// 四方とも液体(完全な内側)。粒を岸で削らないセルの判定。
    def isInterior(edges: Edges): Bool = edges#n and edges#s and edges#e and edges#w

    /// 表面の時間演出をセル1個ぶん描く(状態なし — 同じ時刻なら同じ絵)。
    /// 重ねの並びはリストの順(同じ z の前後は並び順が決めるため、順も見た目の一部)。
    /// edges = 上下左右の隣が液体か。岸(隣が陸)の側には粒を集めて、液体セルの塗りの
    /// 外(床)へはみ出させない。
    pub def surfaceItems(fxs: List[SurfaceFx], cell: (Int32, Int32), tile: Float64,
                         time: Float64, z: Int32, edges: Edges): List[Render.PlacedItem] =
        fxs |> List.flatMap(fx -> match fx#shape {
            case SurfaceShape.Speck   => speckItems(fx, cell, tile, time, z, edges)
            case SurfaceShape.Scales  => scaleItems(fx, cell, tile, time, z, edges)
            case SurfaceShape.Bubble  => bubbleItems(fx, cell, tile, time, z, edges)
            case SurfaceShape.Glow    => glowItems(fx, cell, tile, time, z, edges)
        })

    /// 静的なむらをセル1個ぶん描く(時間なし — prebuilt に生成する前提)。セルに1〜2個
    /// (2個目は座標ハッシュの偶奇で間引く — 全セル同数だと市松模様の規則に見えるため)。
    /// 置き場所はセルの内側(4..11+半径3.5)に収める — 岸辺線の上に暗いむらが
    /// 乗ると縁が欠けて見えるため。
    pub def blotchItems(fx: BlotchFx, cell: (Int32, Int32), tile: Float64,
                        z: Int32): List[Render.PlacedItem] =
        let (x, y) = cell;
        let px = Int32.toFloat64(x) * tile;
        let py = Int32.toFloat64(y) * tile;
        let count = if (DualGrid.hash(x, y, fx#channel + 8) < 0.5) 2 else 1;
        List.range(0, count) |> List.map(k -> {
            let alpha = fx#alphaBase + fx#alphaSpan * DualGrid.hash(x, y, fx#channel + k);
            let radius = fx#sizeBase + fx#sizeSpan * DualGrid.hash(x, y, fx#channel + 6 + k);
            let center = {
                x = px + 4.0 + Float64.floor(DualGrid.hash(x, y, fx#channel + 2 + k) * 8.0),
                y = py + 4.0 + Float64.floor(DualGrid.hash(x, y, fx#channel + 4 + k) * 8.0) };
            let placed = RawDraw.circleAt(center, radius, fx#color, z);
            { item = placed#item |> Render.fade(alpha) | placed }
        })

    /// きらめく粒(セル座標ハッシュの位置に小さな粒)。粒ごとに位相をずらした sin で
    /// ゆっくり明滅する — 全部が同じタイミングで光ると水でなく信号に見えるため。
    /// sin 自体が周期なので、時刻は折り返さず生のまま入れる。
    /// 幅はハッシュで 1〜3px に散らす — 同じ大きさの粒が並ぶと打った点に見えるため。
    def speckItems(fx: SurfaceFx, cell: (Int32, Int32), tile: Float64,
                   time: Float64, z: Int32, edges: Edges): List[Render.PlacedItem] =
        let (x, y) = cell;
        let px = Int32.toFloat64(x) * tile;
        let py = Int32.toFloat64(y) * tile;
        List.range(0, fx#count) |> List.map(k -> {
            // 粒 1 つに 4 本の乱数を割り当て、粒ごとに 4 本ぶんずらす。
            // 間隔を空けないと「粒 k の縦位置 = 粒 k+2 の横位置」になり、粒が対角に並ぶ。
            let ch = fx#channel + k * 4;
            let twinkle = fx#alphaBase + fx#alphaSpan *
                (0.5 + 0.5 * Vec2.sin(time * fx#twinkleRate
                                      + DualGrid.hash(x, y, ch) * 6.28));
            let w = fx#sizeBase
                + Float64.floor(DualGrid.hash(x, y, ch + 3) * (fx#sizeSpan + 1.0));
            let bx = px + 3.0 + Float64.floor(DualGrid.hash(x, y, ch + 1) * 10.0);
            let by = py + 3.0 + Float64.floor(DualGrid.hash(x, y, ch + 2) * 10.0);
            // box は左上原点なので、幅ぶん見込んで岸の内側へ詰める。
            let (ax, ay) = insetToLiquid(cell, tile, edges, Float64.max(w, 2.0), (bx, by));
            { at = { x = ax, y = ay },
              item = RawDraw.box({ x = w, y = 1.0 }, fx#color, z)
                  |> Render.fade(twinkle)
                  |> blendItem(fx#blend) }
        })

    /// 2色の線分上の混ぜ(0 = a, 1 = b)。色ランプの1区間の補間に使う。
    def toneMix(a: Color, b: Color, t: Float64): Color =
        let tf = Float64.truncateToFloat32(t);
        let f32 = RenderUtil.f32;
        let wide = Float32.toFloat64;
        { r = wide(f32(a#r) + (f32(b#r) - f32(a#r)) * tf),
          g = wide(f32(a#g) + (f32(b#g) - f32(a#g)) * tf),
          b = wide(f32(a#b) + (f32(b#b) - f32(a#b)) * tf) }

    /// 3色ランプ(deep→mid→lite)を位相 phase(0..1 で1周)で回した色。位相を2区間に割り、
    /// 前半は deep→mid、後半は mid→lite を線形補間する — 図形を動かさず色だけ回すことで
    /// 面が流れて見える(SNESのパレット循環)。
    def ramp3(deep: Color, mid: Color, lite: Color, phase: Float64): Color =
        let f = phase - Float64.floor(phase);
        if (f < 0.5) toneMix(deep, mid, f * 2.0)
        else toneMix(mid, lite, (f - 0.5) * 2.0)

    /// 下向きの三日月(弧)を1枚の薄い多角形で作る。外側の弧(半径 radius)を左から右へ、
    /// 内側の弧(半径 radius-width)を右から左へ戻して閉じたストリップにする — 塗り円でなく
    /// スカラップ(鱗)に見せるための開いた弧の近似。中心 center からの相対頂点で返す。
    /// 弧は円の底(t=0.5)を中心に spanT ぶん張る(t=0 が真上・時計回り)。
    def crescent(center: Vec2.Vec2, radius: Float64, width: Float64, spanT: Float64): List[Vec2.Vec2] =
        let segs = 6;
        let lo = 0.5 - spanT / 2.0;
        let hi = 0.5 + spanT / 2.0;
        let at = (r, i) ->
            Vec2.add(center, Vec2.onEllipse({ x = r, y = r },
                lo + (hi - lo) * Int32.toFloat64(i) / Int32.toFloat64(segs)));
        let outer = List.range(0, segs + 1) |> List.map(i -> at(radius, i));
        let inner = List.range(0, segs + 1) |> List.map(i -> at(radius - width, segs - i));
        List.append(outer, inner)

    /// 鱗: セル内 count×count の整った千鳥格子(奇数行を半個ずらした魚の鱗の並び)に、下向きの
    /// 三日月を敷く。三日月は1枚だけ(色ランプで回した弧)— 影の弧はやめ、暗さは deep 色に
    /// まとめて1枚に減らす(1セルの三日月の数を半分にしてフレームあたりの描画数を落とす)。
    /// 色は「(格子番号 gc+gr の偶奇で 0/半周) + 時刻を rate で刻んだ位相」で deep→mid→lite を
    /// 回す(図形は静止・色だけ循環)。ハッシュのばらつきはやめ、隣どうしが逆位相で交互に
    /// 脈打つ整然とした市松の千鳥にする。格子の番号はマップ全体で振る — セルごとに振り直すと
    /// 境界で模様の周期が切れるため。
    /// 岸(edges の隣が陸)の側は格子点をセル中央へ強く寄せ、はみ出す一列は間引く — 液体の
    /// 塗りが岸の丸みで欠ける所に鱗が乗ると床の上に浮いて見えるため。四方が液体の内側の
    /// セルだけフル密度。
    def scaleItems(fx: SurfaceFx, cell: (Int32, Int32), tile: Float64,
                   time: Float64, z: Int32, edges: Edges): List[Render.PlacedItem] =
        let (x, y) = cell;
        let n = Int32.max(1, fx#count);
        let s = tile / Int32.toFloat64(n);
        List.range(0, n) |> List.flatMap(r ->
            List.range(0, n) |> List.flatMap(c -> {
                let gr = y * n + r;
                let gc = x * n + c;
                let shift = if (Int32.modulo(gr, 2) == 0) 0.25 else 0.75;
                // 格子点の中心(揺らぎなし)。岸の側だけ中央へ詰めてはみ出しを防ぐ。
                let baseX = Int32.toFloat64(x) * tile + (Int32.toFloat64(c) + shift) * s;
                let baseY = Int32.toFloat64(y) * tile + (Int32.toFloat64(r) + 0.5) * s;
                let radius = fx#sizeBase + fx#sizeSpan * DualGrid.hash(gc, gr, fx#channel + 2);
                let (cx, cy) = insetToLiquid(cell, tile, edges, radius + 1.0, (baseX, baseY));
                // 色循環: 格子の偶奇で半周ずらし(隣どうし逆位相)、時刻を rate で刻んで進める。
                let parity = if (Int32.modulo(gc + gr, 2) == 0) 0.0 else 0.5;
                let phase = parity
                    + Float64.floor(time * fx#twinkleRate) / 6.0
                    + (time * fx#twinkleRate - Float64.floor(time * fx#twinkleRate)) / 6.0;
                let toneColor = ramp3(fx#color, fx#color3, fx#color2, phase);
                if (droppedAtShore(cell, tile, edges, radius, (cx, cy))) Nil
                else {
                    let liteArc = RawDraw.polygon(
                        crescent({ x = cx, y = cy }, radius, 1.4, 0.34), toneColor, z);
                    { at = Vec2.zero(),
                      item = liteArc |> Render.fade(fx#alphaBase)
                          |> blendItem(fx#blend) } :: Nil
                }
            }))

    /// 岸の側(隣が陸)へはみ出さないよう、粒の中心を液体の内側の範囲へ収める。液体でない
    /// 辺は縁から margin だけ内へ入った線で、液体の辺はセル一杯まで許す。
    def insetToLiquid(cell: (Int32, Int32), tile: Float64, edges: Edges, margin: Float64,
                      p: (Float64, Float64)): (Float64, Float64) =
        let (x, y) = cell;
        let (px, py) = p;
        let x0 = Int32.toFloat64(x) * tile;
        let y0 = Int32.toFloat64(y) * tile;
        let loX = if (edges#w) x0 else x0 + margin;
        let hiX = if (edges#e) x0 + tile else x0 + tile - margin;
        let loY = if (edges#n) y0 else y0 + margin;
        let hiY = if (edges#s) y0 + tile else y0 + tile - margin;
        (Float64.max(loX, Float64.min(hiX, px)),
         Float64.max(loY, Float64.min(hiY, py)))

    /// 岸のセルで、格子点が液体でない辺に半径ぶん近すぎる(=床へはみ出す)なら間引く。
    /// 内側のセルは常に残す — 小さな池が全部岸で鱗が消えて死んで見えるのを避ける。
    def droppedAtShore(cell: (Int32, Int32), tile: Float64, edges: Edges, radius: Float64,
                       p: (Float64, Float64)): Bool =
        if (isInterior(edges)) false
        else {
            let (x, y) = cell;
            let (px, py) = p;
            let localX = px - Int32.toFloat64(x) * tile;
            let localY = py - Int32.toFloat64(y) * tile;
            (not edges#w and localX - radius < 0.0)
                or (not edges#e and localX + radius > tile)
                or (not edges#n and localY - radius < 0.0)
                or (not edges#s and localY + radius > tile)
        }

    /// 円周だけの薄いリング(内外の 12 角形を1枚のストリップ多角形にして塗る)。中心 center。
    /// 塗り円と違い「輪」に見えるのが弾けの主役。頂点は絶対座標(at はゼロ)。
    def ring(center: Vec2.Vec2, radius: Float64, width: Float64, color: Color,
             z: Int32): Render.PlacedItem =
        let segs = 12;
        let at = (rad, i) ->
            Vec2.add(center, Vec2.onEllipse({ x = rad, y = rad },
                Int32.toFloat64(i) / Int32.toFloat64(segs)));
        let outer = List.range(0, segs + 1) |> List.map(i -> at(radius, i));
        let inner = List.range(0, segs + 1) |> List.map(i -> at(radius - width, segs - i));
        { at = Vec2.zero(),
          item = RawDraw.polygon(List.append(outer, inner), color, z) }

    /// 湧いて膨らみ、終端でリング+飛沫に弾けて消える泡。粒の一生は
    /// 「時刻+セル位相を周期で折り返した tMod」だけから決まる閉形式 —
    /// tMod = t' - floor(t' / period) * period (t' = time + 位相)。u = tMod/period が
    /// 0→1 で進む。出現はセルハッシュがしきい(twinkleRate)未満のときだけ = 疎(0〜1個)。
    ///   u 0..0.7   : 塗り円を膨らませ riseSpeed で少し浮上(u/0.7 の割合で成長)。
    ///   u 0.7..0.9 : 塗り円をやめ、細いリングを r*1.3 まで急拡大しつつ薄れ、放射状の
    ///                短い飛沫線を3本飛ばす(弾けても丸いまま、を避ける)。
    ///   u 0.9..1   : 何も描かない(消滅)。
    def bubbleItems(fx: SurfaceFx, cell: (Int32, Int32), tile: Float64,
                    time: Float64, z: Int32, edges: Edges): List[Render.PlacedItem] =
        if (fx#period <= 0.0) Nil
        else {
            let (x, y) = cell;
            let px = Int32.toFloat64(x) * tile;
            let py = Int32.toFloat64(y) * tile;
            List.range(0, fx#count) |> List.flatMap(k -> {
                // 出現の間引き: このセル・この粒がしきいを越えたら泡は湧かない。
                if (DualGrid.hash(x, y, fx#channel + 8 + k) >= fx#twinkleRate) Nil
                else {
                    let shifted = time + DualGrid.hash(x, y, fx#channel + k) * fx#period;
                    let tMod = shifted - Float64.floor(shifted / fx#period) * fx#period;
                    let u = tMod / fx#period;
                    // 弾けのリング半径(sizeTo*1.3)+飛沫線ぶんを見込んで岸の内側へ収める。
                    let (bcx, bcy) = insetToLiquid(cell, tile, edges, fx#sizeTo * 1.3 + 3.0,
                        (px + 3.0 + Float64.floor(DualGrid.hash(x, y, fx#channel + 2 + k) * 10.0),
                         py + 3.0 + Float64.floor(DualGrid.hash(x, y, fx#channel + 4 + k) * 10.0)));
                    let center = { x = bcx, y = bcy - fx#riseSpeed * tMod };
                    if (u < 0.7) {
                        // 膨らむ塗り円。
                        let grow = u / 0.7;
                        let alpha = fx#alphaBase + fx#alphaSpan * grow;
                        let placed = RawDraw.circleAt(center, fx#sizeTo * grow, fx#color, z);
                        ({ item = placed#item
                               |> Render.fade(alpha)
                               |> blendItem(fx#blend) | placed }) :: Nil
                    } else if (u < 0.9) {
                        // 弾け: リング + 飛沫線。
                        let pop = (u - 0.7) / 0.2;
                        let rad = fx#sizeTo * (1.0 + pop * 0.3);
                        let alpha = (fx#alphaBase + fx#alphaSpan) * (1.0 - pop);
                        let ringBase = ring(center, rad, 1.0, fx#color, z);
                        let ringItem = { item = ringBase#item
                                             |> Render.fade(alpha) | ringBase };
                        let a0 = DualGrid.hash(x, y, fx#channel + 6 + k) * 6.283185307179586;
                        let splats = List.range(0, 3) |> List.map(s -> {
                            let ang = a0 + Int32.toFloat64(s) / 3.0 * 6.283185307179586;
                            let dir = { x = Vec2.cos(ang), y = Vec2.sin(ang) };
                            let inner = Vec2.add(center, Vec2.mul(dir, rad));
                            let outer = Vec2.add(center, Vec2.mul(dir, rad + 2.5));
                            let seg = RawDraw.lineSeg(inner, outer, 1.0, fx#color, z);
                            { item = seg#item |> Render.fade(alpha) | seg }
                        });
                        ringItem :: splats
                    } else Nil
                }
            })
        }

    /// 自分で光る粒(加算の淡い光)。セルに1〜2個(2個目はハッシュで間引く)、
    /// 粒ごとに位相をずらした sin でゆっくり明滅する。
    def glowItems(fx: SurfaceFx, cell: (Int32, Int32), tile: Float64,
                  time: Float64, z: Int32, edges: Edges): List[Render.PlacedItem] =
        let (x, y) = cell;
        let px = Int32.toFloat64(x) * tile;
        let py = Int32.toFloat64(y) * tile;
        let count = if (DualGrid.hash(x, y, fx#channel + 8) < 0.5) fx#count
                    else Int32.max(1, fx#count - 1);
        List.range(0, count) |> List.map(k -> {
            let twinkle = fx#alphaBase + fx#alphaSpan *
                (0.5 + 0.5 * Vec2.sin(time * fx#twinkleRate
                                      + DualGrid.hash(x, y, fx#channel + k) * 6.28));
            let radius = fx#sizeBase + fx#sizeSpan * DualGrid.hash(x, y, fx#channel + 6 + k);
            let (gcx, gcy) = insetToLiquid(cell, tile, edges, radius,
                (px + 3.0 + Float64.floor(DualGrid.hash(x, y, fx#channel + 2 + k) * 10.0),
                 py + 3.0 + Float64.floor(DualGrid.hash(x, y, fx#channel + 4 + k) * 10.0)));
            let center = { x = gcx, y = gcy };
            let placed = RawDraw.circleAt(center, radius, fx#color, z);
            { item = placed#item
                  |> Render.fade(twinkle)
                  |> blendItem(fx#blend) | placed }
        })

    /// blend が Normal のときは素通し(既定の重ね方をわざわざ上書きしない)。
    def blendItem(mode: DrawCmd.BlendMode, item: Render.Item): Render.Item =
        match mode {
            case DrawCmd.BlendMode.Normal => item
            case other                    => Render.blended(other, item)
        }

    /// フチの色を決める。ByNormal は外向き法線の y で天板/陰/横を選ぶ。
    def edgeColor(kind: EdgeKind, normal: Vec2.Vec2): Color =
        match kind {
            case EdgeKind.Uniform(color) => color
            case EdgeKind.ByNormal(k)    =>
                if (normal#y < -0.35) k#top
                else if (normal#y > 0.35) k#shade
                else k#side
        }

    /// caseIndex(tl=8, tr=4, bl=2, br=1)から埋まり方の旗へ戻す(許可矩形が北隣を見るため)。
    def flagsOfCase(n: Int32): DualGrid.Corner =
        { tl = Int32.bitwiseAnd(n, 8) != 0,
          tr = Int32.bitwiseAnd(n, 4) != 0,
          bl = Int32.bitwiseAnd(n, 2) != 0,
          br = Int32.bitwiseAnd(n, 1) != 0 }

    // ════════════════════════════════════════════════════════
    // 持ち上げた分の床への食み込みを切る(許可矩形の決め事)
    // ════════════════════════════════════════════════════════

    /// 持ち上げた描画を許す範囲(タイルローカル座標)。下半分の全幅は常に許し、
    /// 上半分は北隣(tl/tr)が埋まっている列だけ許す — 床の列に描くと床とキャラを隠すため。
    def allowedRects(tile: Float64, lift: Float64, flags: DualGrid.Corner): List[Rect2.Rect2] =
        rectSpan(0.0, tile / 2.0, tile, tile + lift) ::
        List.append(
            if (flags#tl) rectSpan(0.0, 0.0 - lift - 1.0, tile / 2.0, tile / 2.0) :: Nil else Nil,
            if (flags#tr) rectSpan(tile / 2.0, 0.0 - lift - 1.0, tile, tile / 2.0) :: Nil else Nil)

    def rectSpan(x0: Float64, y0: Float64, x1: Float64, y1: Float64): Rect2.Rect2 =
        { position = { x = x0, y = y0 }, size = { x = x1 - x0, y = y1 - y0 } }

    /// 許可矩形それぞれとの交差を出す。矩形同士は重ならないので切れ端も重ならない。
    /// 潰れた切れ端(面積ほぼ 0)は捨てる。
    def clipAllowed(rects: List[Rect2.Rect2], poly: List[Vec2.Vec2]): List[List[Vec2.Vec2]] =
        rects |> List.filterMap(rect -> {
            let piece = DualGrid.clipPolyRect(rect, poly);
            if (DualGrid.polygonArea(piece) > 0.01) Some(piece) else None
        })
}
