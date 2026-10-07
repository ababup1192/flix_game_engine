// Render — 「何をどう見せたいか」だけ書いた Item を、描画部が食べられる形に変換する。
// スプライトもテキストも箱も円も多角形も、同じ { at = 置き場所, item = Item } の語彙で並べられる。
// 形の材料（箱・円・多角形の図形プリミティブ）は RawDraw。View では完成品の部品
// （PxSprite・Material・Scatter・shader.json 等）を使い、稀な属性（角丸・半透明・枠・縞）は
// パイプ修飾で重ねる。
// 注意: 置き場所は持たず呼び側が渡す。テキストの実寸計算は engine の純粋関数を使う。

pub mod Render {

    // ── render component（位置を持たない・ノードでない）──

    /// 傾き（rotation）の単位は「回転数」— 1 周 = 1.0・正で時計回り。ラジアンへの変換は
    /// 描画命令を作る出口で 1 回だけ行う（rotated / ui.json の poly と同じ数え方）。
    /// 回す軸は種類ごとに 1 つ: Box と Sprite は自分の中心、Text は置き場所。
    /// 集まりを丸ごと傾けるときは turnedAll を使う（軸の違いはそこが吸収する）。
    pub enum Item {
        /// texture は handle 相当（String）。regionRect=None で全テクスチャ。UV は射影が計算。
        /// （`region` は Flix 予約語なので engine と同じ `regionRect`）
        /// maskPolys は多角形の型抜き（空 = 抜かない。masked で付ける）。頂点は表示クアッドの
        /// ローカル座標（design px・原点 = クアッドの左上・回転前）— rotation・反転は
        /// クアッドと同じ変換が掛かるので、形は 1 回定義すれば回転は rotation に任せられる。
        case Sprite({ texture = String, tint = Color, alpha = Float64,
                      scale = Vec2.Vec2, rotation = Float64, centered = Bool,
                      flipH = Bool, flipV = Bool, regionRect = Option[Rect2.Rect2], zIndex = Int32,
                      blend = DrawCmd.BlendMode, maskPolys = List[List[Vec2.Vec2]] })
        /// wrapWidth = Some(w) で、w (design px) を超える字を次の行へ折り返す。None は折らない。
        case Text({ text = String, fontAtlas = FontAtlas, fontSize = Float64, tint = Color,
                    rotation = Float64, zIndex = Int32, wrapWidth = Option[Float64] })
        case Box({ size = Vec2.Vec2, color = Color, alpha = Float64, rotation = Float64,
                   style = Option[GameEngine.BoxStyle], zIndex = Int32, blend = DrawCmd.BlendMode })
        /// 単色の単純多角形（自己交差しなければ凹でもよい。塗りは描画側が耳切りで三角形化）。
        /// 頂点は置き場所からの相対座標（draw が置き場所を全頂点に加算する）。
        /// grad = Some(色列) で頂点ごとの色になり面の中で滑らかに混ざる（gradPolygon / vgrad で作る。
        /// 扇割りのため凸の形で使う）。None = color 一色。
        case Poly({ vertices = List[Vec2.Vec2], color = Color, alpha = Float64, zIndex = Int32,
                    blend = DrawCmd.BlendMode, grad = Option[List[DrawCmd.VertexTint]] })
        /// rect（スクリーン空間・design px）で inner を切り抜く。入れ子は交差。
        /// App + withCamera 経路では中身にはカメラが掛かるが、clip 矩形は常にスクリーン固定 —
        /// PiP やパネル内スクロール用（world に追従する clip 矩形は v1 対象外）。
        case Clipped({ rect = Rect2.Rect2, inner = Item })
        /// 宣言シェーダーで矩形 rect を塗る面（水面など）。GL 経路では eff Shader が本物の
        /// シェーダーで描き、GL の無い経路（SoftRaster / F8 注釈）では代表色のベタ塗りに落ちる。
        /// rect はスクリーン空間 px（uv=0..1 がこの矩形）、t は world#time（uTime に渡す）。
        /// mask = この面を切り抜く多角形の列（rect 左上からの相対座標）。空なら矩形そのまま。
        /// 非空なら GL でステンシルへ書き込んで「多角形の内側だけ」塗る（丸い池形など任意形に抜く）。
        case Shader({ rect = Rect2.Rect2, spec = ShaderDoc.Spec, t = Float64,
                      mask = List[List[Vec2.Vec2]], zIndex = Int32, blend = DrawCmd.BlendMode })
    }

    /// 置き場所つきの描画物。View はこの列を組み、draw が描画命令へ変換する。
    pub type alias PlacedItem = { at = Vec2.Vec2, item = Item }

    // ── smart constructor（Drawable/BoxStyle をゲームから隠す）──

    def white(): Color = {r = 1.0, g = 1.0, b = 1.0}

    /// 全テクスチャ・等倍・中心原点のスプライト（最頻ケース）。反転が要るときは spriteFlipped。
    pub def sprite(texture: String, zIndex: Int32): Item =
        Item.Sprite({ texture = texture, tint = white(), alpha = 1.0,
                            scale = {x = 1.0, y = 1.0}, rotation = 0.0, centered = true,
                            flipH = false, flipV = false, regionRect = None, zIndex = zIndex,
                            blend = DrawCmd.BlendMode.Normal, maskPolys = Nil })

    /// 反転付きスプライト。同型の Bool 2 つは取り違えやすいので名前で渡す。
    pub def spriteFlipped(texture: String, zIndex: Int32,
                          flip: { flipH = Bool, flipV = Bool }): Item =
        Item.Sprite({ texture = texture, tint = white(), alpha = 1.0,
                            scale = {x = 1.0, y = 1.0}, rotation = 0.0, centered = true,
                            flipH = flip#flipH, flipV = flip#flipV, regionRect = None, zIndex = zIndex,
                            blend = DrawCmd.BlendMode.Normal, maskPolys = Nil })

    pub def text(content: String, fontAtlas: FontAtlas, fontSize: Float64, zIndex: Int32): Item =
        Item.Text({ text = content, fontAtlas = fontAtlas, fontSize = fontSize, tint = white(),
                    rotation = 0.0, zIndex = zIndex, wrapWidth = None })

    /// 着色テキスト。disabled のグレー表示やカーソル色、見出しの強調色などに使う。
    pub def textTinted(content: String, fontAtlas: FontAtlas, fontSize: Float64, tint: Color, zIndex: Int32): Item =
        Item.Text({ text = content, fontAtlas = fontAtlas, fontSize = fontSize, tint = tint,
                    rotation = 0.0, zIndex = zIndex, wrapWidth = None })

    /// 折り返し付きの着色テキスト。wrapWidth（design px）を超える字は次の行へ送られる。
    /// fontSize と wrapWidth は同じ Float64 で取り違えやすいのでレコードで名前渡しにする。
    pub def textWrapped(content: String, fontAtlas: FontAtlas,
                        look: { fontSize = Float64, wrapWidth = Float64, tint = Color, zIndex = Int32 }): Item =
        Item.Text({ text = content, fontAtlas = fontAtlas, fontSize = look#fontSize, tint = look#tint,
                    rotation = 0.0, zIndex = look#zIndex, wrapWidth = Some(look#wrapWidth) })

    /// 中心 center に置いた、縁がふわっと消える円の列（ソフトな光の玉）。
    /// look#alpha は中心の濃さ 0..1、look#blend は重ね方（光り物は Add が定番）。
    /// 減衰は RadialGlow（グローの描き出し）と同じ smoothstep カーブに合わせてある —
    /// 生成したハロと絵の系統が揃う。テクスチャに頼らないのは、fx.json（閉形式
    /// パーティクル）が「アセット不要・どの描画部でも同じ絵」を守るため。
    pub def glowAt(center: Vec2.Vec2, radius: Float64, color: Color,
                   look: { alpha = Float64, blend = DrawCmd.BlendMode },
                   zIndex: Int32): List[PlacedItem] =
        if (radius <= 0.0 or look#alpha <= 0.0) Nil
        else {
            // 輪の数は半径に応じて増やす（1px 未満の輪は意味がないため半径 px を上限の目安に、
            // 大きな玉でも継ぎ目が見えない 24 で頭打ち・小さな粒でも形が保てる下限 4）。
            let rings = Int32.min(24, Int32.max(4, ceilI(radius)));
            let n = Int32.toFloat64(rings);
            // 外側の輪から順に「その輪まで重なった濃さ」が減衰カーブに乗るように積む。
            // 同色・同ブレンドの重なりは順序に依らないので、輪の並び順は見た目に影響しない。
            List.range(0, rings) |> List.filterMap(k -> {
                let kf = Int32.toFloat64(k);
                let ringRadius = radius * (1.0 - kf / n);
                // 輪 k が受け持つ範囲の中央の距離（0=中心, 1=縁）で目標の濃さを決める。
                let target = c -> look#alpha * smoothFalloff(1.0 - (c + 0.5) / n);
                let before = if (k == 0) 0.0 else target(kf - 1.0);
                let goal = target(kf);
                // Add は足し算で濃さが積もる。Normal / Multiply は「上に重ねるほど
                // 残りの薄さが縮む」ので、差分を残り分で割って 1 枚ぶんの alpha に戻す。
                let ringAlpha = match look#blend {
                    case DrawCmd.BlendMode.Add => goal - before
                    case _                     =>
                        if (before >= 0.9999) 0.0 else (goal - before) / (1.0 - before)
                };
                if (ringAlpha <= 0.0) None
                else Some(ringAt(center, ringRadius, color, zIndex)
                    |> (placed -> { item = placed#item
                                        |> fade(ringAlpha)
                                        |> blended(look#blend) | placed }))
            })
        }

    /// glowAt が積む輪 1 枚（中心置きの単色円）。円の図形プリミティブは RawDraw の領分だが、
    /// 依存方向を RawDraw→Render の一方向に保つため、ここは自前で組む。
    def ringAt(center: Vec2.Vec2, radius: Float64, color: Color, zIndex: Int32): PlacedItem =
        { at = { x = center#x - radius, y = center#y - radius },
          item = Item.Box({ size = { x = radius * 2.0, y = radius * 2.0 }, color = color,
                            alpha = 1.0, rotation = 0.0, style = Some(solidStyle()),
                            zIndex = zIndex, blend = DrawCmd.BlendMode.Normal })
                 |> rounded(radius) }

    /// 中心 0 → 縁 1 の距離を濃さ倍率に写す減衰（RadialGlow.smoothstepCurve と同じ式）。
    /// engine_world は engine_tools（RadialGlow の住処）に依存できないため、式だけ揃える。
    def smoothFalloff(t: Float64): Float64 =
        let x = Float64.max(0.0, Float64.min(1.0, 1.0 - t));
        x * x * (3.0 - 2.0 * x)

    /// 切り上げの Int32（輪の数の見積もり用。非負前提）。
    def ceilI(x: Float64): Int32 =
        Float64.ceil(x) |> Float64.tryToInt32 |> Option.getWithDefault(16)

    /// 中心 at に置いた放射状の明かり 1 枚（松明・スポットライト・光だまり）。
    /// 組み込みの放射テクスチャ（RadialBuiltin）を Add で重ねるので、ゲーム側の
    /// アセット・配線は要らない。radius は見た目の半径 px、strength は中心の濃さ 0..1。
    /// glowAt（同心円の輪を積む）と違い 1 枚ものなので、大半径でも継ぎ目が出ず部品数も増えない。
    /// 定石: 光マップのレンダーターゲット（App.withPasses）へ Add で灯りを集め、それを
    /// blended(Multiply) で本編に掛けると「暗闇に灯りだけが浮かぶ」絵になる。
    pub def lightAt(spec: { at = Vec2.Vec2, radius = Float64, color = Color,
                            strength = Float64, z = Int32 }): PlacedItem =
        { at = spec#at,
          item = sprite(RadialBuiltin.lightName(), spec#z)
              |> tinted(spec#color)
              |> fade(spec#strength)
              |> scaled(builtinRadialScale(spec#radius))
              |> blended(DrawCmd.BlendMode.Add) }

    /// 中心 at に置いた放射状の翳り 1 枚（vignette・足元の影だまり・画面の隅を沈める）。
    /// lightAt の Multiply 版: 中心ほど暗く、縁は素通しで背景になじむ。
    /// strength は中心の暗さ 0..1（1 で中心が真っ黒）。暗くできるのは自分より
    /// 奥（小さい zIndex）だけ — 沈めたい物は z 未満に置くこと。
    pub def darkAt(spec: { at = Vec2.Vec2, radius = Float64, strength = Float64,
                           z = Int32 }): PlacedItem =
        { at = spec#at,
          item = sprite(RadialBuiltin.darkName(), spec#z)
              |> fade(spec#strength)
              |> scaled(builtinRadialScale(spec#radius))
              |> blended(DrawCmd.BlendMode.Multiply) }

    /// 「見た目半径 = radius」になる組み込み放射テクスチャの拡大率。
    /// 描画の四角の大きさは「テクスチャ実寸 × scale」なので、直径 2×radius から逆算する。
    def builtinRadialScale(radius: Float64): Float64 =
        radius * 2.0 / Int32.toFloat64(RadialBuiltin.size())

    /// 宣言シェーダーで矩形 rect を塗る面（PlacedItem）。at に rect の左上を入れる —
    /// 描画は at を置き場所に使うので、withCamera 下では at がカメラ変換を受けて面が追従する
    /// （カメラ無しなら at は rect#position のままで画面固定）。t は uTime に渡す秒（world#time など）。
    /// GL 経路では eff Shader が本物のシェーダーで描き、GL の無い経路では代表色ベタ塗りに落ちる。
    pub def shaderFill(spec: ShaderDoc.Spec, rect: Rect2.Rect2, t: Float64, zIndex: Int32): PlacedItem =
        { at = rect#position,
          item = Item.Shader({ rect = rect, spec = spec, t = t, mask = Nil, zIndex = zIndex,
                               blend = DrawCmd.BlendMode.Normal }) }

    /// 宣言シェーダーで rect を塗り、maskPolys（ワールド座標の多角形の列）の内側だけに抜く面。
    /// 丸い池のような任意の形に水面を切り抜くのに使う（GL 経路がステンシルで抜く）。
    /// maskPolys は shaderFill と同じワールド座標で渡す — 内部で rect 左上からの相対に直して
    /// 持つので、withCamera の平行移動・ズームが rect と一緒に mask にも掛かる（形がずれない）。
    pub def shaderFillMasked(spec: ShaderDoc.Spec, rect: Rect2.Rect2,
                             maskPolys: List[List[Vec2.Vec2]], t: Float64, zIndex: Int32): PlacedItem =
        let rel = maskPolys |> List.map(poly ->
            poly |> List.map(v -> Vec2.sub(v, rect#position)));
        { at = rect#position,
          item = Item.Shader({ rect = rect, spec = spec, t = t, mask = rel, zIndex = zIndex,
                               blend = DrawCmd.BlendMode.Normal }) }

    /// pass（レンダーターゲット）を、全面でない面（横長のストリップなど）から等倍で読むための dy 場。
    /// 面の uv.v（0..1）を pass の縦の区間（design px の top / height）の texV へ写す。
    /// passH は pass 全体の高さ（design px。App の pass は design 解像度なので普通は画面の高さ）。
    /// flipV = true で上下鏡像（水面の映り込みなど）。
    /// Shift の dy は「読み先 texV − 面の v」の差分なので、写像 texV = (top + height×v)/passH
    /// を v の 1 次式にまとめた係数で返す — 呼び側が同じ導出を定数の手計算で持つと、
    /// ストリップの位置替えのたびに写像が割れるため。
    /// 例: Field.Shift({ dx = Field.Const(0.0), dy = Render.passStripDy(strip, passH, false),
    ///                   of = Field.Tex({ name = "screen", chan = chan }) })
    pub def passStripDy(strip: { top = Float64, height = Float64 }, passH: Float64, flipV: Bool): ShaderDoc.Field =
        let texVAt0 = if (flipV) (strip#top + strip#height) / passH else strip#top / passH;
        let texVSlope = if (flipV) -(strip#height) / passH else strip#height / passH;
        ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Add,
            a = ShaderDoc.Field.Const(texVAt0),
            b = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul,
                a = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.V }),
                b = ShaderDoc.Field.Const(texVSlope - 1.0) }) })

    /// 頂点色つきの凸多角形。各頂点に色と濃さを与えると、面の中で滑らかに混ざる
    /// （空・水面・光の帯のグラデを 1 部品で描く — 1px の細い面を積む必要はない）。
    /// 頂点は置き場所からの相対座標。描画側が扇割りで三角形化するため凸の形で使うこと
    /// — 凹ませたい形は凸に割って並べる。
    pub def gradPolygon(vertices: List[DrawCmd.GradVertex], zIndex: Int32): Item =
        Item.Poly({ vertices = List.map(v -> v#pos, vertices),
                    color = vertices |> List.head |> Option.map(v -> v#color)
                                     |> Option.getWithDefault(white()),
                    alpha = 1.0, zIndex = zIndex, blend = DrawCmd.BlendMode.Normal,
                    grad = Some(List.map(v -> ({ color = v#color, alpha = v#alpha }: DrawCmd.VertexTint),
                                         vertices)) })

    /// 上下 2 色の縦グラデ矩形（左上原点・サイズ指定）。空や夕暮れの背景の定番形。
    /// 濃さも変えたいとき（上へ消える光の帯など）は gradPolygon で頂点ごとに渡す。
    pub def vgrad(size: Vec2.Vec2, colors: { top = Color, bottom = Color }, zIndex: Int32): Item =
        gradPolygon(
            { pos = { x = 0.0, y = 0.0 },       color = colors#top,    alpha = 1.0 } ::
            { pos = { x = size#x, y = 0.0 },    color = colors#top,    alpha = 1.0 } ::
            { pos = { x = size#x, y = size#y }, color = colors#bottom, alpha = 1.0 } ::
            { pos = { x = 0.0, y = size#y },    color = colors#bottom, alpha = 1.0 } :: Nil,
            zIndex)

    // ── 図形の語彙（box / circle / polygon / ngon / star …）は RawDraw へ ──
    // 図形プリミティブは「材料」であり View で直接並べる物ではないため、置き場を分けてある。

    /// item を pos（左上）に置く純糖衣 — `{ at = pos, item = item }` と同じ値。
    /// item を最後に受けるので、修飾パイプの末尾にそのまま載る:
    /// `… |> Render.fade(0.6) |> Render.at(pos)`。
    /// 中心置きの図形はこれではなく RawDraw の At 族（boxAt / circleAt / ngonAt …）を使う —
    /// 中心→左上の換算と Poly のガード（atCenter）を迂回しないため。
    pub def at(pos: Vec2.Vec2, item: Item): PlacedItem =
        { at = pos, item = item }

    /// 飾り終えた「左上原点の item」（box / circle / text）を中心 center に置く
    /// （size はその item の見た目の大きさ。中心→左上の換算をここが済ませる）。
    /// Poly は受け付けず loud に落とす — 頂点が原点中心なので `{ at = center, item = … }` が
    /// そのまま中心置きであり、ここを通すと黙って半サイズずれる事故になるため。
    /// ガードは Clipped を剥がした葉で判定する（clip 矩形に包んでもすり抜けさせない）。
    pub def atCenter(center: Vec2.Vec2, size: Vec2.Vec2, item: Item): PlacedItem =
        match leafOf(item) {
            case Item.Poly(_) =>
                bug!("Render.atCenter: Poly は at がそのまま中心 — { at = center, item = … } と書く")
            case _ =>
                { at = { x = center#x - size#x / 2.0, y = center#y - size#y / 2.0 }, item = item }
        }

    /// Clipped を剥がした芯の item（ガード判定用 — clip 矩形は見ない）。
    def leafOf(item: Item): Item =
        match item {
            case Item.Clipped(c) => leafOf(c#inner)
            case leaf            => leaf
        }

    def solidStyle(): GameEngine.BoxStyle =
        DrawCmd.defaultStyle(white())

    // ── clip（スクリーン空間の切り抜き矩形）──

    /// item を rect（スクリーン空間・design px）で切り抜く。clip 矩形の外のピクセルは描かれない。
    /// 入れ子は交差。修飾（fade / scaled 等）は clip 矩形をスキップして中身に効く。
    /// 端のちらつきを避けるため rect は整数 design px で作ること。
    pub def clipped(rect: Rect2.Rect2, item: Item): Item =
        Item.Clipped({ rect = rect, inner = item })

    /// 置き場所つきの列をまとめて切り抜く近道（PiP・パネル内スクロールの出口で使う）。
    pub def clippedAll(rect: Rect2.Rect2, items: List[PlacedItem]): List[PlacedItem] =
        items |> List.map(p -> { item = clipped(rect, p#item) | p })

    // ── 修飾（稀な属性はパイプで重ねる。効かない種類の item は素通し）──

    /// 修飾を Clipped の clip 矩形越しに葉へ届ける。clip 矩形（rect）には触れない —
    /// 「clip は最後の見た目、修飾は中身」という一方向の重なりを保つ。
    def onLeaf(f: Item -> Item, item: Item): Item =
        match item {
            case Item.Clipped(c) => Item.Clipped({ inner = onLeaf(f, c#inner) | c })
            case leaf            => f(leaf)
        }

    /// 角を丸める（Box に効く）。
    pub def rounded(radius: Float64, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Box(b) =>
                Item.Box({ style = Some(DrawCmd.withCornerRadius(radius, styleOf(b#style))) | b })
            case other => other
        }, item)

    /// 透明度（alpha）を指定した値にする（Sprite / Box / Poly に効く。Text は tint が濃度を兼ねる）。
    pub def fade(alpha: Float64, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Sprite(s) => Item.Sprite({ alpha = alpha | s })
            case Item.Box(b)    => Item.Box({ alpha = alpha | b })
            case Item.Poly(p)   => Item.Poly({ alpha = alpha | p })
            case other                => other
        }, item)

    /// 置き場所はそのままに、中身（Item）だけ入れ替える。`fade` や `rounded` のような
    /// 「Item を受けて Item を返す」修飾を、置き場所つきの物へ掛ける口。
    /// 修飾ごとに PlacedItem 版を増やさなくて済む。
    pub def overItem(f: Item -> Item \ ef, placed: PlacedItem): PlacedItem \ ef =
        { item = f(placed#item) | placed }

    /// 組み上がった列を丸ごと薄くする（`fade` の列版）。覆い・淡い層・消えていく残像に使う。
    pub def fadeAll(alpha: Float64, items: List[PlacedItem]): List[PlacedItem] =
        items |> List.map(placed -> overItem(fade(alpha), placed))

    /// ピクセルの重ね方を変える（Sprite / Box / Poly に効く。Text は文字の可読性が第一で対象外）。
    /// Add = 明るく足す（グロー・炎・魔法）、Multiply = 暗く沈める（影・暗くするオーバーレイ）。
    /// どちらも「自分より奥（小さい zIndex）に描かれた物」に効く — オーバーレイで暗くしたい物は
    /// オーバーレイより小さい z に置くこと。同じ zIndex 同士では draw の並べ順が奥/手前を決める
    /// （安定ソートは同順位を入力順のまま保つため、先に並べた物ほど奥＝ blend が効く側になる）。
    pub def blended(mode: DrawCmd.BlendMode, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Sprite(s) => Item.Sprite({ blend = mode | s })
            case Item.Box(b)    => Item.Box({ blend = mode | b })
            case Item.Poly(p)   => Item.Poly({ blend = mode | p })
            case Item.Shader(s) => Item.Shader({ blend = mode | s })
            case other          => other
        }, item)

    /// 重なり順（zIndex）を delta だけずらす。組み上がった絵の相対的な前後関係は保ったまま、
    /// 集まり全体を別の層へ持ち上げる／沈める。
    /// 見下ろし画面の Y ソート（足元の高さで前後を決める）は Depth がこれを使って作る。
    pub def zShifted(delta: Int32, item: Item): Item =
        zMapped(z -> z + delta, item)

    /// 重なり順（zIndex）を関数 f で写す（zShifted の一般形）。
    /// 足し算で書けない写し（HUD の範囲への clamp 付き持ち上げ等）はこちらを使う。
    pub def zMapped(f: Int32 -> Int32, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Sprite(s) => Item.Sprite({ zIndex = f(s#zIndex) | s })
            case Item.Text(x)   => Item.Text({ zIndex = f(x#zIndex) | x })
            case Item.Box(b)    => Item.Box({ zIndex = f(b#zIndex) | b })
            case Item.Poly(p)   => Item.Poly({ zIndex = f(p#zIndex) | p })
            case Item.Shader(s) => Item.Shader({ zIndex = f(s#zIndex) | s })
            case other          => other
        }, item)

    /// 置き場所つきの列を丸ごと delta だけずらす（zShifted の列版）。
    pub def zShiftedAll(delta: Int32, items: List[PlacedItem]): List[PlacedItem] =
        items |> List.map(placed -> { item = zShifted(delta, placed#item) | placed })

    /// 組み上がった列を丸ごと d だけ動かす（zShiftedAll の位置版）。
    /// 部品を 0 起点で組んでから最後に置き場所を与える書き方（盤の原点へ動かす・
    /// UI の枠の中へ入れる・粒を発生源へ運ぶ）がこれで 1 行になる。
    /// 中身（大きさ・頂点・z）には触らない — 動かすのは置き場所と、Clipped の clip 矩形。
    /// clip 矩形の規約: 平行移動と一様 scale は clip 矩形も追随・回転だけ据え置き（clip 矩形 = 画面平行の不変条件）。
    /// clip 矩形を置き去りにすると「中身だけ clip 矩形の外へ歩いて消える」— clip 矩形ごと動くのが組の意図。
    pub def movedAll(d: Vec2.Vec2, items: List[PlacedItem]): List[PlacedItem] =
        items |> List.map(placed ->
            { at = Vec2.add(d, placed#at),
              item = placed#item |> overClipRects(r ->
                  { position = Vec2.add(d, r#position), size = r#size }) })

    /// 組み上がった列を、pivot（画面座標）を不動点に factor 倍へ伸縮する（ズーム演出・
    /// 拡大プレビュー用）。at を pivot からの距離ごと伸縮し、中身は scaled に任せる —
    /// Box の style の太さ・Text の fontSize・Sprite の maskPolys の追随はそこが持つ。
    /// Clipped の clip 矩形も一緒に伸縮する（clip 矩形の規約: 平行移動と一様 scale は clip 矩形も追随・
    /// 回転だけ据え置き — movedAll と同じ）。
    /// 倍率は一様（Float64 1 つ）だけ受ける — 非等方だと回転済みの物や円が歪み、
    /// 「見た目を保ったまま大きさだけ変える」決まりが守れないため、型で締め出す。
    pub def scaledAllAround(factor: Float64, pivot: Vec2.Vec2, items: List[PlacedItem]): List[PlacedItem] =
        let stretch = v -> Vec2.add(pivot, Vec2.mul(Vec2.sub(v, pivot), factor));
        items |> List.map(placed ->
            { at = stretch(placed#at),
              item = placed#item
                  |> scaled(factor)
                  |> overClipRects(r ->
                      { position = stretch(r#position), size = Vec2.mul(r#size, factor) }) })

    /// Clipped の clip 矩形（入れ子は全段）だけを f で写す。葉（中身）には触らない —
    /// onLeaf の裏面で、「clip 矩形 = 画面平行」の規約を守る変換（平行移動・一様 scale）専用。
    def overClipRects(f: Rect2.Rect2 -> Rect2.Rect2, item: Item): Item =
        match item {
            case Item.Clipped(c) => Item.Clipped({ rect = f(c#rect), inner = overClipRects(f, c#inner) })
            case leaf            => leaf
        }

    /// 置き場所と頂点を step px の升目に載せる（ドット絵の升目に合わせて角を落とす）。
    /// なめらかな多角形をドット絵と同じ画面に置くと、そこだけ画素の階段が無くて浮くので揃える。
    /// step = 1.0 で 1 画素、2.0 なら 2 画素ぶんの粗さ。静的な絵（1 度だけ生成する層）向けで、
    /// 毎フレーム掛ける物ではない。
    ///
    /// 動かすのは位置だけで、大きさ（箱の size・絵の scale）は触らない — 大きさを丸めると
    /// 敷き詰めた面に隙間や重なりが出るため。半端な大きさの物を升目に載せたいなら、
    /// 呼ぶ側が整数の大きさで作ること。
    pub def snapped(step: Float64, item: Item): Item =
        if (not Float64.isFinite(step) or step <= 0.0) item
        else onLeaf(leaf -> match leaf {
            case Item.Poly(p) => Item.Poly({ vertices = List.map(snapVec(step), p#vertices) | p })
            case other        => other
        }, item)

    /// snapped の列版（置き場所も升目に載せる）。
    pub def snappedAll(step: Float64, items: List[PlacedItem]): List[PlacedItem] =
        if (not Float64.isFinite(step) or step <= 0.0) items
        else items |> List.map(p ->
            { at = snapVec(step, p#at), item = snapped(step, p#item) })

    def snapVec(step: Float64, v: Vec2.Vec2): Vec2.Vec2 =
        { x = Float64.round(v#x / step) * step, y = Float64.round(v#y / step) * step }

    /// 絵の色を差し替える（Sprite だけに効く。白 = 元の絵のまま）。同じ 1 枚の絵を、
    /// 色だけ変えて使い回すための関数 — 木や草を 1 本ずつわずかに違う色にすると、
    /// 並んでも単調にならない。
    ///
    /// 掛け算ではなく差し替えなので、すでに色が乗っている絵に重ねても足し合わさらない。
    /// 箱や多角形は素通し（色を持つ場所が別なので、ここでは触らない）。
    pub def tinted(color: Color, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Sprite(sp) => Item.Sprite({ tint = color | sp })
            case other           => other
        }, item)

    /// tinted の列版。
    pub def tintedAll(color: Color, items: List[PlacedItem]): List[PlacedItem] =
        items |> List.map(p -> { item = tinted(color, p#item) | p })

    /// 絵を多角形で型抜きする（Sprite にだけ効く。空 = 抜かない）。ガラス片・ちぎれた紙のような
    /// 「矩形でない切り出し」を、黒い覆いの偽装なしで一級にする口。
    /// polys の頂点は表示クアッドのローカル座標（design px・原点 = クアッドの左上・回転前）。
    /// rotation・反転はクアッドと同じ変換が掛かる — 破片の形は 1 回定義すれば、
    /// 回転は従来どおり turned / rotation に任せられる。
    /// 縁は AA なしの硬い縁（GL: ステンシル / SoftRaster: Java2D clip — docs/backend-parity.md）。
    /// GL では型抜き 1 体ごとに run の一括 draw から単発 draw に落ちる — 何百枚も撒く層には使わない。
    pub def masked(polys: List[List[Vec2.Vec2]], item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Sprite(s) => Item.Sprite({ maskPolys = polys | s })
            case other          => other
        }, item)

    /// 飾りの無い箱（角丸・枠線・縞・市松・回転がどれも無い単色）を、同じ形の多角形へ直す。
    /// 静的レイヤー（1 度だけ GPU に生成する層）は多角形だけを生成の対象にするので、箱で組んだ絵を
    /// そこへ載せたいときの入口。飾りのある箱・箱以外はそのまま返す（生成されずに動的側へ残る）。
    pub def boxAsPoly(item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Box(b) =>
                if (Float64.abs(b#rotation) > 0.000001 or not plainStyle(b#style)) leaf
                else Item.Poly({ vertices = { x = 0.0, y = 0.0 } :: { x = b#size#x, y = 0.0 }
                                     :: { x = b#size#x, y = b#size#y } :: { x = 0.0, y = b#size#y } :: Nil,
                                 color = b#color, alpha = b#alpha, zIndex = b#zIndex,
                                 blend = b#blend, grad = None })
            case other => other
        }, item)

    /// boxAsPoly の列版。
    pub def boxesAsPolys(items: List[PlacedItem]): List[PlacedItem] =
        items |> List.map(p -> { item = boxAsPoly(p#item) | p })

    /// その箱が「ただの単色の矩形」か（角丸・枠線・縞・市松がどれも無い）。
    def plainStyle(style: Option[GameEngine.BoxStyle]): Bool =
        match style {
            case None    => true
            case Some(s) =>
                let DrawCmd.BoxStyle.BoxStyle(rad, bw, _br, _bg, _bb, ba,
                                              _sr, _sg, _sb, sa, _sw, _sp, _sd,
                                              _kr, _kg, _kb, ka, _kc) = s;
                Float64.abs(rad) < 0.000001
                    and Float64.abs(bw) < 0.000001
                    and ba == 0.0
                    and sa == 0.0
                    and ka == 0.0
        }

    /// 頂点列を左右に鏡映する（縦軸で x を反転・2 回で元に戻る）。polygon や Bezier の
    /// 輪郭・背骨に渡す前に使う。鏡映は頂点の上でだけ提供する（Text のような
    /// 鏡映できない物に flip を書くと型が合わない = 落ちる代わりにコンパイルで止まる）。
    pub def flipH(vertices: List[Vec2.Vec2]): List[Vec2.Vec2] =
        List.map(v -> { x = -1.0 * v#x, y = v#y }, vertices)

    /// 頂点列を上下に鏡映する（横軸で y を反転・2 回で元に戻る）。使い方は flipH と同じ。
    pub def flipV(vertices: List[Vec2.Vec2]): List[Vec2.Vec2] =
        List.map(v -> { x = v#x, y = -1.0 * v#y }, vertices)

    /// 頂点列を原点周りに t（1 周 = 1.0・正で時計回り = 画面の見た目どおり）回す。
    /// 回転の軸は「頂点をどこを原点に組むか」で決める（他エンジンの pivot と同じ考え方）:
    /// 原点中心の形なら中心回転、lineQuad の根元を原点に置けば時計の針になる。
    pub def rotated(t: Float64, vertices: List[Vec2.Vec2]): List[Vec2.Vec2] =
        let c = Vec2.cos(Vec2.tau() * t);
        let s = Vec2.sin(Vec2.tau() * t);
        List.map(v -> { x = v#x * c - v#y * s, y = v#x * s + v#y * c }, vertices)

    /// 任意の点 pivot 周りに回す（蝶番・ドア用の近道。pivot へ移して回して戻すのと同じ）。
    pub def rotatedAround(t: Float64, pivot: Vec2.Vec2, vertices: List[Vec2.Vec2]): List[Vec2.Vec2] =
        vertices
            |> List.map(v -> Vec2.sub(v, pivot))
            |> rotated(t)
            |> List.map(v -> Vec2.add(v, pivot))

    /// 1 点を pivot 周りに t 回す（rotatedAround の 1 点版）。
    def rotAbout(t: Float64, pivot: Vec2.Vec2, p: Vec2.Vec2): Vec2.Vec2 =
        rotatedAround(t, pivot, p :: Nil) |> List.head |> Option.getWithDefault(p)

    /// item を自分の軸で t（1 周 = 1.0）傾ける。軸は Box / Sprite が自分の中心、Text が置き場所、
    /// Poly が頂点の原点（＝置き場所）。Shader の面は傾かない — uv の向きが面と一緒に回ると
    /// 模様の意味が変わってしまうので、模様を回したいときは spec 側の Rotate を使う。
    pub def turned(t: Float64, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Sprite(s) => Item.Sprite({ rotation = s#rotation + t | s })
            case Item.Box(b)    => Item.Box({ rotation = b#rotation + t | b })
            case Item.Text(x)   => Item.Text({ rotation = x#rotation + t | x })
            case Item.Poly(p)   => Item.Poly({ vertices = rotated(t, p#vertices) | p })
            case other          => other
        }, item)

    /// 置き場所つきの列を、pivot（画面座標）のまわりに丸ごと t 傾ける。カード 1 枚のように
    /// 複数部品で 1 つの物を作っているとき、これを通せば全体が 1 枚の板のように傾く
    /// （各部品を自分の軸で回しつつ、置き場所も pivot のまわりを回る）。
    /// 注意: clip 矩形（clipped）の枠は傾かない — 中身だけが回る。centered=false のスプライトは
    /// 中心位置がここでは分からないため左上を軸に回る（既定の centered=true ならズレない）。
    pub def turnedAll(t: Float64, pivot: Vec2.Vec2, items: List[PlacedItem]): List[PlacedItem] =
        items |> List.map(placed -> {
            let anchor = anchorOf(placed);
            let shift = Vec2.sub(rotAbout(t, pivot, anchor), anchor);
            { at = Vec2.add(placed#at, shift), item = turned(t, placed#item) }
        })

    /// 置き場所つきの列を、pivot（画面座標）のまわりに t（1 周 = 1.0）回す純関数。
    /// at を pivot まわりに公転させ、中身は自分の軸で t 自転する: Sprite / Box / Text は
    /// rotation に t を加算、Poly は頂点を自前回転（絶対座標で組んだ lineSeg / polygon が
    /// そのまま正しく回る）、Clipped は中身だけ回して clip 矩形は据え置き（clip 矩形が画面に平行という決まりを保つ）。
    /// Shader の面は非対応 — そのまま返す（uv の向きが面と回ると模様の意味が変わるため。
    /// 模様を回したいときは spec 側の Rotate を使う）。
    /// turnedAll と違い anchor（Box の中心）を見ない素朴な at 公転 — Box を「1 枚の板」として
    /// 回したいときは turnedAll、破片に細物（ハイライトの Poly など）を追随させるのはこちら。
    pub def rotatedAroundAll(t: Float64, pivot: Vec2.Vec2, items: List[PlacedItem]): List[PlacedItem] =
        items |> List.map(placed -> match leafOf(placed#item) {
            case Item.Shader(_) => placed
            case _              => { at = rotAbout(t, pivot, placed#at), item = turned(t, placed#item) }
        })

    /// その item が「自分の軸で回るときの中心」（画面座標）。turnedAll はこの点を pivot の
    /// まわりに動かすことで、部品の自転と公転を噛み合わせる。
    def anchorOf(placed: PlacedItem): Vec2.Vec2 =
        match leafOf(placed#item) {
            case Item.Box(b) => Vec2.add(placed#at, Vec2.div(b#size, 2.0))
            case _           => placed#at
        }

    /// 枠線を付ける（Box に効く）。
    pub def outline(color: Color, width: Float64, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Box(b) =>
                Item.Box({ style = Some(DrawCmd.withBorder(color, width, 1.0, styleOf(b#style))) | b })
            case other => other
        }, item)

    /// 濃さつきの枠線を付ける（Box に効く）。outline は枠が常に不透明 — 中身を邪魔しない
    /// 薄い枠（ホバー枠・ガイド線）はこちらで alpha を渡す。同型の引数の取り違えを防ぐため
    /// 名前つきで渡す。
    pub def outlineA(border: { color = Color, alpha = Float64, width = Float64 }, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Box(b) =>
                Item.Box({ style = Some(DrawCmd.withBorder(border#color, border#width, border#alpha,
                                                           styleOf(b#style))) | b })
            case other => other
        }, item)

    /// 縞模様を敷く（Box に効く）。dir は 0 = 斜め 45° / 1 = 横縞 / 2 = 縦縞。
    pub def striped(stripe: { color = Color, alpha = Float64, width = Float64, period = Float64, dir = Int32 },
                    item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Box(b) =>
                Item.Box({ style = Some(DrawCmd.withStripe(stripe#color, stripe#alpha, stripe#width,
                                                           stripe#period, stripe#dir,
                                                           styleOf(b#style))) | b })
            case other => other
        }, item)

    /// 市松のタイルを重ねる（Box に効く）。PC-98 の網ディザ風。
    pub def checker(c: { color = Color, alpha = Float64, cell = Float64 }, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Box(b) =>
                Item.Box({ style = Some(DrawCmd.withChecker(c#color, c#alpha, c#cell,
                                                            styleOf(b#style))) | b })
            case other => other
        }, item)

    /// 大きさ系の属性を factor 倍する（全種類の item に効く）。camera の zoom 適用の芯:
    /// Box は size と style の太さ、Sprite は scale、Text は fontSize、Poly は頂点を、
    /// それぞれ一様に伸縮する。置き場所（at）は持たないので呼び側が伸縮する。
    /// 注意: これ単体では置き場所はそのままで中身だけ伸びる = Box は左上を軸に右下へ育ち、
    /// circleAt / boxAt が済ませた中心→左上の換算も崩れる。単に物を大きく見せたいときは
    /// これではなく boxAt のサイズや sprite の scale を変えること。正しく見えるのは、at にも
    /// 同じ倍率を掛ける camera 経路（CameraRig.centerOn）だけ。
    pub def scaled(factor: Float64, item: Item): Item =
        // 等倍は恒等 — zoom 1.0 の camera 経路で全 item を作り直さない。
        if (factor == 1.0) item else
        onLeaf(leaf -> match leaf {
            case Item.Sprite(s) =>
                // maskPolys はクアッドのローカル px なので、クアッドと一緒に伸縮しないと
                // 型抜きの形だけ置き去りになる（Shader の mask と同じ扱い）。
                Item.Sprite({ scale = { x = s#scale#x * factor, y = s#scale#y * factor },
                              maskPolys = s#maskPolys |> List.map(poly ->
                                  poly |> List.map(v -> Vec2.mul(v, factor))) | s })
            case Item.Text(t)   => Item.Text({ fontSize = t#fontSize * factor,
                                               wrapWidth = Option.map(w -> w * factor, t#wrapWidth) | t })
            case Item.Box(b)    =>
                let style1 = b#style |> Option.map(s -> DrawCmd.scalePx(factor, s));
                Item.Box({ size = { x = b#size#x * factor, y = b#size#y * factor }, style = style1 | b })
            case Item.Poly(p)   => Item.Poly({ vertices = List.map(v -> Vec2.mul(v, factor), p#vertices) | p })
            case Item.Shader(s) =>
                Item.Shader({ rect = { position = Vec2.mul(s#rect#position, factor),
                                       size = Vec2.mul(s#rect#size, factor) },
                              mask = s#mask |> List.map(poly ->
                                  poly |> List.map(v -> Vec2.mul(v, factor))) | s })
            case Item.Clipped(_) => bug!("Render.scaled: onLeaf が Clipped を剥がすのでここには届かない")
        }, item)

    /// zIndex を delta だけ持ち上げる（全種類の item に効く）。組み上がった item の列を
    /// まとめて別の z-index の範囲へ移すとき（UI レイヤーの合流など）に使う。
    pub def raiseZ(delta: Int32, item: Item): Item =
        onLeaf(leaf -> match leaf {
            case Item.Sprite(s) => Item.Sprite({ zIndex = s#zIndex + delta | s })
            case Item.Text(t)   => Item.Text({ zIndex = t#zIndex + delta | t })
            case Item.Box(b)    => Item.Box({ zIndex = b#zIndex + delta | b })
            case Item.Poly(p)   => Item.Poly({ zIndex = p#zIndex + delta | p })
            case Item.Shader(s) => Item.Shader({ zIndex = s#zIndex + delta | s })
            case Item.Clipped(_) => bug!("Render.raiseZ: onLeaf が Clipped を剥がすのでここには届かない")
        }, item)

    /// 修飾の土台になる style（無ければ solid）。
    def styleOf(style: Option[GameEngine.BoxStyle]): GameEngine.BoxStyle =
        Option.getWithDefault(solidStyle(), style)

    // ── レンダーターゲット（描いた結果を読み返せる描き込み先。Pass に描いて blit で貼る）──

    /// 本編より先にレンダーターゲットへ描く 1 枚ぶんの宣言（App.withPasses で列を渡す）。
    /// name はそのままテクスチャ名になり、本編から Render.sprite(name, z) で貼れる。
    /// ターゲットの寸法は常に design 解像度（投影が design 前提で固定されているため —
    /// 別寸法のターゲットは投影の差し替えごと将来の拡張）。clear は開くたびの前の中身の始末
    /// （RenderTarget.LoadOp: Keep = 残す（残像）・Clear = その色の不透明・
    /// ClearTransparent = 透明。明部だけ描くターゲットは ClearTransparent にすると
    /// Normal 合成でも下の絵が生きる）。
    /// items の中の Shader 面は M1 では描かれない（中身は sprites/box/text/多角形のみ）。
    /// ターゲットの標本は最近傍（NEAREST）を保証する — 縮小→再拡大のピクセライズ/モザイクは
    /// これに依存してよい。補間を変える拡張は opt-in にする（黙って既定を変えない）。
    pub type alias Pass = {
        name = String,
        clear = RenderTarget.LoadOp,
        items = List[PlacedItem]
    }

    /// レンダーターゲット（Pass の name）を design 全面へ等倍で貼る（中心置き）。ターゲットは
    /// 常に design 解像度なので等倍 = 全面ぴったり。blend / alpha / tint は
    /// overItem + blended / fade / tinted で後がけする。
    pub def blit(name: String, design: Vec2.Vec2, z: Int32): PlacedItem =
        { at = { x = design#x / 2.0, y = design#y / 2.0 }, item = sprite(name, z) }

    /// レンダーターゲット name の一部 src（ターゲット上の px 矩形）を、at を中心に size の
    /// 四角へ伸縮して貼る。描画の四角の大きさは「テクスチャ実寸 × scale」なので
    /// scale = size / ターゲットの寸（ターゲットは常に design 解像度）。
    /// 反転圧縮・パネルへの縮小・モザイク拡大が全部この 1 本で書ける。
    /// blend / alpha / tint / 反転は overItem + blended / fade / tinted 等で後がけする。
    pub def blitRegion(spec: { name = String, design = Vec2.Vec2, src = Rect2.Rect2,
                               at = Vec2.Vec2, size = Vec2.Vec2, z = Int32 }): PlacedItem =
        { at = spec#at,
          item = Item.Sprite({ texture = spec#name, tint = white(), alpha = 1.0,
              scale = { x = spec#size#x / spec#design#x, y = spec#size#y / spec#design#y },
              rotation = 0.0, centered = true, flipH = false, flipV = false,
              regionRect = Some(spec#src), zIndex = spec#z,
              blend = DrawCmd.BlendMode.Normal, maskPolys = Nil }) }

    /// Pass 1 枚を描き出し側の宣言（engine_tools の HeadlessRender.PassSpec と同形のレコード）へ
    /// 詰め替える。items は withoutShaders で外してから下ろす — ターゲットの中の
    /// Shader 面は GL が描かないので、代表色ベタ塗りを混ぜると実機とズレる。この決まりを
    /// 呼び側ごとに書かせない（書き忘れた側だけズレる）ための 1 本。
    /// textureInfoOf は region 付き sprite の UV 解決口（region を使わない pass なら
    /// `_ -> None` でよい）。
    pub def passSpecOf(textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef, p: Pass):
            { name = String, clear = RenderTarget.LoadOp,
              drawables = List[GameEngine.Drawable],
              polygons = List[GameEngine.PolygonRenderCmd] } \ ef =
        let (ds, ps) = drawWith(textureInfoOf, withoutShaders(p#items));
        { name = p#name, clear = p#clear, drawables = ds, polygons = ps }

    // ── extract / 射影（lib が Drawable を1回だけ組む）──

    /// draw list 全体を描画命令へ（zIndex 順は render_gl が stable sort する）。
    /// Sprite / Text / Box は Drawable、Poly は置き場所を頂点に織り込んだ PolygonRenderCmd になる —
    /// 呼び側は 1 本のリストを組むだけで、2 系統への振り分けはここで終わる。
    pub def draw(items: List[PlacedItem]): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]) =
        drawInto((item, pos) -> toDrawables(item, pos), items)

    /// `draw` の atlas 注入版。Sprite の region UV を textureInfoOf で解決しつつ、
    /// Poly も PolygonRenderCmd へ振り分ける（draw と同じ 2 列を返す）。
    /// region 付き sprite と Poly が同じ列に混ざる UI（UiRender）の描画口。
    pub def drawWith(textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef,
                     items: List[PlacedItem]): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]) \ ef =
        drawInto((item, pos) -> toDrawablesAtlas(textureInfoOf, item, pos), items)

    /// そのフレームに描く字の集合の指紋（テクスチャ名と文の codepoint を織り込んだ Int64）。
    /// 「前フレームと同じ字を描くか」を安く見分ける鍵。文字列の集合そのものを組んで
    /// 毎フレーム比較する形にしないのは、比較のほうが missingGlyphs 本体と同じだけ
    /// 掛かって本末転倒になるため。
    /// 文は Java の 32bit hash 経由でなく codepoint を直接多項式へ fold する — 32bit hash を
    /// 素材にすると、文どうしがその 32bit で衝突した時点で 64bit 指紋も丸ごと潰れるため。
    pub def glyphFingerprint(items: List[PlacedItem]): Int64 =
        items |> List.foldLeft((acc, placed) -> {
            let (leaf, _clip) = unwrapClip(placed#item, None);
            match leaf {
                case Item.Text(t) =>
                    let withTexture = acc * 1099511628211i64 + Int32.toInt64(Hash.hash(t#fontAtlas#textureName));
                    t#text |> String.toList |> List.foldLeft((inner, ch) -> {
                        let cp = TextLayout.charToCodePoint(ch);
                        inner * 1099511628211i64 + Int32.toInt64(cp)
                    }, withTexture)
                case _ => acc
            }
        }, -3750763034362895579i64)

    /// 描く物のうち、フォントのアトラスにまだ無い字を「テクスチャ名 → 字」で集める。
    /// 起動時に用意するのは「ソースとアセットに書いてある字」なので、実行中に計算で作った字や
    /// プレイヤーが入れた名前はここに出てくる。渡した先（描画部）が作って足す。
    /// たいていは空なので、毎フレーム呼んでよい。
    pub def missingGlyphs(items: List[PlacedItem]): Map[String, Set[Int32]] =
        items |> List.foldLeft((acc, placed) -> {
            let (leaf, _clip) = unwrapClip(placed#item, None);
            match leaf {
                case Item.Text(t) =>
                    let atlas = t#fontAtlas;
                    let missing = t#text |> String.toList |> List.filterMap(ch -> {
                        let cp = TextLayout.charToCodePoint(ch);
                        // 改行は字ではない（レイアウトの区切り）。
                        if (cp == 10 or Map.memberOf(cp, atlas#glyphs)) None else Some(cp)
                    });
                    if (List.isEmpty(missing)) acc
                    else {
                        let had = Map.get(atlas#textureName, acc) |> Option.getWithDefault(Set.empty());
                        Map.insert(atlas#textureName, Set.union(had, List.toSet(missing)), acc)
                    }
                case _ => acc
            }
        }, Map.empty())

    /// Shader 面だけを取り出して eff Shader が食える描画依頼へ変換する（GL 経路専用）。
    /// programOf は Spec → コンパイル済みプログラムのハンドル（バックエンドが用意）。
    /// Clipped に包まれた Shader も剥がして拾う。GL の無い経路（F8/SoftRaster）は
    /// これを呼ばず draw の代表色ベタ塗りに任せる。
    pub def drawShaders(programOf: ShaderDoc.Spec -> GpuHandle.ShaderProgram \ ef,
                        items: List[PlacedItem]): List[ShaderEffect.ShaderRenderCmd] \ ef =
        items |> List.filterMap(placed -> {
            let (leaf, _clip) = unwrapClip(placed#item, None);
            match leaf {
                case Item.Shader(s) =>
                    // 位置は placed#at（カメラの平行移動＋ズームを済ませた点）、大きさは
                    // scaled 済みの rect#size から取る — HUD/画面固定（カメラ無しなら at は
                    // rect#position のまま）は不変で、withCamera 下だけワールドの矩形が追従する。
                    // mask も同じ理屈で rect 左上相対 + at にして画面座標にする（rect と同じ
                    // カメラ変換に乗るので形がずれない）。
                    Some({ program = programOf(s#spec),
                           texNames = ShaderDoc.texNames(s#spec),
                           rect = { position = placed#at, size = s#rect#size },
                           mask = s#mask |> List.map(poly ->
                               poly |> List.map(v -> Vec2.add(placed#at, v))),
                           time = s#t, zIndex = s#zIndex, blend = s#blend })
                case _ => None
            }
        })

    /// GL の無い経路（描き出し / SoftRaster）が ShaderEval で面を描くための純データ。
    /// drawShaders（GL 用・program ハンドル入り）の headless 版 — バックエンドに依らない値だけ持つ。
    pub type alias ShaderSurface = {
        rect = Rect2.Rect2, spec = ShaderDoc.Spec, time = Float64,
        mask = List[List[Vec2.Vec2]], zIndex = Int32, blend = DrawCmd.BlendMode }

    /// Shader 面を純データ（ShaderSurface）で取り出す（描き出し / SoftRaster 用）。
    /// 座標の扱いは drawShaders と同一: 位置は placed#at、mask は rect 左上相対 + at。
    /// これを SoftRaster の surfaces に渡すと、draw の代表色ベタ塗りの代わりに
    /// ShaderEval の画素評価で描ける（draw 側からは withoutShaders で外して二重にしない）。
    pub def shaderSurfaces(items: List[PlacedItem]): List[ShaderSurface] =
        items |> List.filterMap(placed -> {
            let (leaf, _clip) = unwrapClip(placed#item, None);
            match leaf {
                case Item.Shader(s) =>
                    Some({ rect = { position = placed#at, size = s#rect#size },
                           spec = s#spec, time = s#t,
                           mask = s#mask |> List.map(poly ->
                               poly |> List.map(v -> Vec2.add(placed#at, v))),
                           zIndex = s#zIndex, blend = s#blend })
                case _ => None
            }
        })

    /// Shader 面を除いた PlacedItem 列（GL 経路で draw に渡す前に外す — 本物のシェーダーは
    /// drawShaders + eff Shader が別チャンネルで描くので、draw の代表色ベタ塗りと二重にしない）。
    pub def withoutShaders(items: List[PlacedItem]): List[PlacedItem] =
        items |> List.filter(placed -> {
            let (leaf, _clip) = unwrapClip(placed#item, None);
            match leaf {
                case Item.Shader(_) => false
                case _              => true
            }
        })

    /// draw / drawWith の共通トラバーサル。Clipped を剥がして有効な clip 矩形（入れ子は交差）を決め、
    /// 葉を Drawable / PolygonRenderCmd へ振り分けてから clip 矩形を刻む。振り分けの分岐を 1 本に
    /// しておかないと、Clipped の扱いが 2 経路で割れる。
    /// 2 列は 1 回の走査で同時に積む。列ごとに走査を分けると、描く物 1 個につき
    /// Clipped の剥がしと葉の振り分けが 2 度ずつ走る（物量の多い画面では、その 2 度目が
    /// そのままフレーム時間に乗る）。積むのは逆順の cons で、最後に一度ずつ戻す。
    def drawInto(toDs: (Item, Vec2.Vec2) -> List[GameEngine.Drawable] \ ef,
                 items: List[PlacedItem]): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]) \ ef =
        let (dsRev, psRev) = items |> List.foldLeft((acc, placed) -> {
            let (ds, ps) = acc;
            let (leaf, clip) = unwrapClip(placed#item, None);
            // clip 矩形が無いときは刻まない。作りたての Drawable / 描画命令は clip = None なので、
            // ここで None を書き直すと、同じ値を入れ直すためだけにフィールドの
            // 抜き差しが描く物の数だけ走る（clip 矩形を使う画面はごく一部）。
            match (leaf, clip) {
                case (Item.Poly(p), None)    => (ds, polyCmd(placed#at, p) :: ps)
                case (Item.Poly(p), Some(_)) => (ds, { clip = clip | polyCmd(placed#at, p) } :: ps)
                case (other, None)           =>
                    (toDs(other, placed#at)
                        |> List.foldLeft((rest, d) -> d :: rest, ds), ps)
                case (other, Some(_))        =>
                    (toDs(other, placed#at)
                        |> List.foldLeft((rest, d) -> DrawCmd.withClip(clip, d) :: rest, ds), ps)
            }
        }, ((Nil, Nil): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd])));
        (List.reverse(dsRev), List.reverse(psRev))

    /// Clipped を剥がし、(芯の item, 有効な clip 矩形) を返す。入れ子の clip 矩形は交差する。
    def unwrapClip(item: Item, clip: Option[Rect2.Rect2]): (Item, Option[Rect2.Rect2]) =
        match item {
            case Item.Clipped(c) =>
                let merged = match clip {
                    case None    => Some(c#rect)
                    case Some(r) => Some(Rect2.intersect(r, c#rect))
                };
                unwrapClip(c#inner, merged)
            case leaf => (leaf, clip)
        }

    /// Poly を置き場所 pos の描画命令へ（全頂点に pos を加算）。
    def polyCmd(pos: Vec2.Vec2,
                p: { vertices = List[Vec2.Vec2], color = Color, alpha = Float64, zIndex = Int32,
                     blend = DrawCmd.BlendMode, grad = Option[List[DrawCmd.VertexTint]] }): GameEngine.PolygonRenderCmd =
        { vertices = List.map(v -> Vec2.add(v, pos), p#vertices),
          color = p#color, alpha = p#alpha, zIndex = p#zIndex, clip = None, blend = p#blend,
          grad = p#grad }

    /// World 由来 Drawable 群に camera のズーム倍率を適用する（位置は `Projection.applyToWorldPos` で
    /// screenPos を出した後の共通後処理）。render-from-World の各オーバーレイ（ユニット / 背景 / 範囲表示 /
    /// フォグ等）が共有する camera 適用 spine。Drawable の scale は sprite の拡大率・box の px サイズを表し、
    /// どちらも zoom で乗算するのが正しい camera 適用。
    pub def applyCameraScale(transform: Projection.ViewTransform,
                             ds: List[GameEngine.Drawable]): List[GameEngine.Drawable] =
        // mask はクアッドのローカル px なので zoom で一緒に伸ばす（伸ばさないと型抜きの形だけ
        // 等倍のまま置き去りになる）。空（＝大半）のときは mask を触らない。
        List.map(d -> {
            let DrawCmd.Drawable.Drawable(_tex, _px, _py, sx, sy, _rot,
                                          _cr, _cg, _cb, _a, _cen,
                                          _uox, _uoy, _usx, _usy, _z,
                                          _style, _clip, _blend, mask) = d;
            let zoomed: Vec2.Vec2 = {x = sx * transform#scale#x, y = sy * transform#scale#y};
            if (List.isEmpty(mask))
                DrawCmd.withScale(zoomed, d)
            else
                DrawCmd.withScaleAndMask(zoomed,
                    mask |> List.map(poly -> poly |> List.map(v ->
                        ({ x = v#x * transform#scale#x, y = v#y * transform#scale#y }: Vec2.Vec2))), d)
        }, ds)

    /// 1 アイテム → 複数 Drawable（ボタン等は呼び側で複数アイテムにする）。
    /// Clipped は中身を変換してから clip 矩形を刻む（入れ子は交差 — draw を通さない直呼びでも clip が効く）。
    pub def toDrawables(item: Item, pos: Vec2.Vec2): List[GameEngine.Drawable] =
        match item {
            case Item.Sprite(s) =>
                spriteDrawable(s#texture, s#tint, s#alpha, s#scale, s#rotation,
                               s#centered, s#flipH, s#flipV, s#regionRect, s#zIndex, s#blend,
                               s#maskPolys, pos) :: Nil
            case Item.Text(t) =>
                textDrawables(t#text, t#fontAtlas, t#fontSize, t#tint, t#rotation, t#zIndex, t#wrapWidth, pos)
            case Item.Box(b) =>
                boxDrawable(b#size, b#color, b#alpha, b#rotation, b#style, b#zIndex, b#blend, pos) :: Nil
            case Item.Poly(_) =>
                bug!("Render.toDrawables: Poly は Drawable にならない（draw が PolygonRenderCmd へ振り分ける）")
            case Item.Shader(s) =>
                // GL の無い経路（SoftRaster / F8 注釈）向けの代表色ベタ塗り。本物のシェーダーは
                // eff Shader が別チャンネルで描くので、ここは「面がそこにある」ことだけ残す。
                boxDrawable(s#rect#size, ShaderDoc.representativeColor(s#spec), 1.0, 0.0, None,
                            s#zIndex, s#blend, s#rect#position) :: Nil
            case Item.Clipped(c) =>
                toDrawables(c#inner, pos)
                    |> List.map(d -> DrawCmd.withClip(mergeClip(c#rect, DrawCmd.clipOf(d)), d))
        }

    /// clip 矩形 rect を既存の clip と重ねる（両方あれば交差）。
    def mergeClip(rect: Rect2.Rect2, existing: Option[Rect2.Rect2]): Option[Rect2.Rect2] =
        match existing {
            case None    => Some(rect)
            case Some(r) => Some(Rect2.intersect(rect, r))
        }

    /// region atlas 対応の射影（drawWith が使う）。textureSize を引いて UV を計算する
    /// （uvOffset = regionPos/texSize, uvScale = regionSize/texSize）。
    /// 非 region スプライト・text・box は pure 経路と同一。
    def toDrawablesAtlas(textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef,
                         item: Item, pos: Vec2.Vec2): List[GameEngine.Drawable] \ ef =
        match item {
            case Item.Sprite(s) =>
                let (uvOff, uvScl) = match s#regionRect {
                    case None       => ({x = 0.0, y = 0.0}, {x = 1.0, y = 1.0})
                    case Some(rect) => match textureInfoOf(s#texture) {
                        case Some(ti) => ({x = rect#position#x / ti#width, y = rect#position#y / ti#height},
                                          {x = rect#size#x / ti#width, y = rect#size#y / ti#height})
                        case None     => ({x = 0.0, y = 0.0}, {x = 1.0, y = 1.0})
                    }
                };
                DrawCmd.fromParts(
                   s#texture, pos,
                   {x = s#scale#x * flipSign(s#flipH), y = s#scale#y * flipSign(s#flipV)},
                   radiansOf(s#rotation), s#tint, s#alpha, s#centered,
                   uvOff, uvScl, s#zIndex, None,
                   None, s#blend, s#maskPolys) :: Nil
            case other => toDrawables(other, pos)
        }

    // flip は base scale に符号を“乗算”（engine spriteToDrawable と同じ）。centered は素通し。
    // region=Some は textureSize(\Game) が要るので今回未対応＝loud に落とす（部分関数を残さない）。
    def spriteDrawable(texture: String, tint: Color, alpha: Float64, scale: Vec2.Vec2,
                       rotation: Float64, centered: Bool, flipH: Bool, flipV: Bool,
                       regionRect: Option[Rect2.Rect2], zIndex: Int32, blend: DrawCmd.BlendMode,
                       maskPolys: List[List[Vec2.Vec2]], pos: Vec2.Vec2): GameEngine.Drawable =
        match regionRect {
            case Some(_) => bug!("Render: region atlas not supported yet (pass regionRect=None)")
            case None    =>
                DrawCmd.fromParts(
                  texture,
                  pos,
                  {x = scale#x * flipSign(flipH), y = scale#y * flipSign(flipV)},
                  radiansOf(rotation),
                  tint,
                  alpha,
                  centered,
                  {x = 0.0, y = 0.0},
                  {x = 1.0, y = 1.0},
                  zIndex,
                  None,
                  None,
                  blend,
                  maskPolys)
        }

    def flipSign(b: Bool): Float64 = if (b) -1.0 else 1.0

    /// 回転数（1 周 = 1.0）→ 描画命令のラジアン。単位の境目はここ 1 か所だけ。
    def radiansOf(turns: Float64): Float64 = Vec2.tau() * turns

    def textDrawables(content: String, fontAtlas: FontAtlas, fontSize: Float64,
                      tint: Color, rotation: Float64, zIndex: Int32,
                      wrapWidth: Option[Float64], pos: Vec2.Vec2): List[GameEngine.Drawable] =
        // engine の public 純粋射影に委譲。文字色（SDF 描画では color がそのまま文字色）と
        // zIndex は Text の visual に 1 回だけ書き込む — 出来上がった列を withTintAndZIndex で
        // map し直すと、文字 1 字につき捨てる Drawable が 1 個ずつ増えるため。
        let ds = Text.toDrawables(
            Text.make(content, fontAtlas, fontSize)
                |> Text.setWrapWidth(wrapWidth)
                |> Text.mapVisual(v -> v |> Visual.setColor(tint) |> Visual.setZIndex(zIndex)),
            pos);
        if (rotation == 0.0) ds
        else ds |> List.map(turnGlyph(rotation, fontAtlas#textureSize, pos))

    /// 文字 1 つぶんの四角を、文字列の置き場所 pivot のまわりに回して置き直す。
    /// 描画側は四角を自分の中心で回すので、中心を公転させたうえで同じ角度を持たせると
    /// 文字列全体が 1 枚の板のように回る。グリフの四角の大きさは
    /// scale × アトラス辺長（Text.toDrawables がそう組んでいる）。
    def turnGlyph(t: Float64, textureSize: Float64, pivot: Vec2.Vec2,
                  d: GameEngine.Drawable): GameEngine.Drawable =
        let DrawCmd.Drawable.Drawable(_tex, px, py, sx, sy, _rot,
                                      _cr, _cg, _cb, _a, _cen,
                                      _uox, _uoy, _usx, _usy, _z,
                                      _style, _clip, _blend, _mask) = d;
        let size = { x = sx * textureSize, y = sy * textureSize };
        let half = Vec2.div(size, 2.0);
        let moved = rotAbout(t, pivot, Vec2.add({x = px, y = py}, half));
        DrawCmd.withPositionAndRotation(Vec2.sub(moved, half), radiansOf(t), d)

    def boxDrawable(size: Vec2.Vec2, color: Color, alpha: Float64, rotation: Float64,
                    style: Option[GameEngine.BoxStyle], zIndex: Int32, blend: DrawCmd.BlendMode,
                    pos: Vec2.Vec2): GameEngine.Drawable =
        // texture=""・centered=false・position=左上・scale=ピクセルサイズ・style=Some で単色塗り。
        DrawCmd.fromParts(
          "",
          pos,
          size,
          radiansOf(rotation),
          color,
          alpha,
          false,
          {x = 0.0, y = 0.0},
          {x = 1.0, y = 1.0},
          zIndex,
          style,
          None,
          blend,
          Nil)
}
