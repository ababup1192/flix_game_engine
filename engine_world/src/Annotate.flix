// Annotate — 一時停止中に画面を矩形で囲み、「どこに何が描かれていたか」を書き出す debug 小物
// （矩形注釈・保存トースト・fps 表示）の純粋な芯。マウス読み・ファイル書きは呼び側（App/effect）が担う。
// 座標には画面座標（マウスの生値）とデザイン座標（ゲームの絵の座標）の 2 つがあり、
// ズーム・パンは見え方にしか効かない。注釈に残す矩形は常にデザイン座標なので、拡大して囲っても記録位置は等倍と同じ。

pub mod Annotate {
    import java.lang.Math

    // ── 状態と入力 ──

    /// 一時停止中の見え方。zoom はデザイン中央を焦点にした一様拡大、pan はその後の平行移動。
    pub type alias View = {
        zoom = Float64,      // 拡大率（1.0 = 等倍）
        pan = Vec2.Vec2,     // 画面座標での平行移動量
        design = Vec2.Vec2   // デザイン解像度（拡大の焦点 = この中央）
    }

    /// アノテーションモードの全状態。App のループが毎フレーム持ち回す。
    pub type alias State = {
        paused = Bool,                     // 時間停止中か
        frame = Int64,                     // システムを適用した回数（注釈に残すフレーム番号）
        zoom = Float64,                    // 現在の拡大率
        pan = Vec2.Vec2,                   // 現在の平行移動量（画面座標）
        dragStart = Option[Vec2.Vec2],     // 矩形ドラッグの始点（デザイン座標で確定済み）
        prevLeftDown = Bool,               // 前フレームの左ボタン（押した瞬間・離した瞬間の検出用）
        prevPanActive = Bool,              // 前フレームにパン操作中だったか
        prevMouse = Vec2.Vec2,             // 前フレームのカーソル位置（パンの移動量計算用）
        toast = Option[{ message = String, framesLeft = Int32 }],  // 保存完了メッセージ（残り表示フレーム数つき）
        scrub = Int32,                     // 何フレーム前を表示しているか（0 = 停止した瞬間）
        scrubHold = Int32,                 // ←→ を押し続けているフレーム数（長押しの連続送り判定用）
        scrubShow = Int32,                 // スクラブ位置表示の残りフレーム数（操作が止まると数え減って消える）
        fpsAvg = Float64                   // 直近フレームの dt の指数移動平均（0.0 = まだ計測していない）
    }

    /// 一時停止中の 1 フレームぶんのマウスと画面の状態。App が effect で読んで渡す。
    pub type alias MouseInput = {
        cursor = Vec2.Vec2,    // カーソル位置（画面座標）
        leftDown = Bool,       // 左ボタンが押されているか
        middleDown = Bool,     // 中ボタンが押されているか
        spaceDown = Bool,      // Space キーが押されているか（Space + 左ドラッグ = パン）
        scroll = Float64,      // このフレームのホイール量（上 = 正）
        design = Vec2.Vec2     // デザイン解像度
    }

    /// 起動直後の状態（等倍・停止していない・ドラッグしていない）。
    pub def initial(): State =
        { paused = false, frame = 0i64, zoom = 1.0, pan = Vec2.zero(),
          dragStart = None, prevLeftDown = false, prevPanActive = false,
          prevMouse = Vec2.zero(), toast = None, scrub = 0, scrubHold = 0, scrubShow = 0,
          fpsAvg = 0.0 }

    /// 状態から見え方を組む。
    pub def viewOf(design: Vec2.Vec2, state: State): View =
        { zoom = state#zoom, pan = state#pan, design = design }

    /// 一時停止を抜けるときに見え方とドラッグを等倍へ戻す（frame は保つ）。
    pub def resetView(state: State): State =
        { paused = false, zoom = 1.0, pan = Vec2.zero(), dragStart = None,
          prevLeftDown = false, prevPanActive = false, toast = None,
          scrub = 0, scrubHold = 0, scrubShow = 0 | state }

    // ── 時間スクラブ（停止中に ← → で少し前の瞬間へ戻る）──

    /// 長押しをこのフレーム数を超えてから連続送りにする（それまでは 1 押し = 1 フレーム）。
    def scrubRepeatDelay(): Int32 = 18

    /// 停止中の ← → で「何フレーム前を見るか」を進める。押した瞬間は 1 フレームずつ、
    /// 押しっぱなしは少し待ってから毎フレーム送り（キーリピート相当）。
    /// ← = 過去へ、→ = 現在へ。0（停止した瞬間）と履歴の端でそれ以上は動かない。
    /// 位置表示は操作中だけ点き、手を離すと約 3 秒（180 フレーム）で消える。
    pub def scrubStep(keys: { back = Bool, backEdge = Bool, fwd = Bool, fwdEdge = Bool },
                      historyLen: Int32, state: State): State =
        let holding = keys#back or keys#fwd;
        let hold = if (holding) state#scrubHold + 1 else 0;
        let repeating = hold > scrubRepeatDelay();
        let delta =
            if (keys#backEdge or (keys#back and repeating)) 1
            else if (keys#fwdEdge or (keys#fwd and repeating)) -1
            else 0;
        let scrub = Int32.max(0, Int32.min(historyLen - 1, state#scrub + delta));
        let show = if (holding) 180 else Int32.max(0, state#scrubShow - 1);
        { scrub = scrub, scrubHold = hold, scrubShow = show | state }

    /// スクラブ位置の表示（「<< 42/300」= 300 フレームの履歴のうち 42 フレーム前を見ている）。
    /// 画面左下に固定で置く。呼び側は見え方の適用後に重ねる。
    pub def scrubIndicatorItems(fontAtlas: FontAtlas, fontSize: Float64, design: Vec2.Vec2,
                                scrub: Int32, historyLen: Int32): List[Render.PlacedItem] =
        let message = "<< ${scrub}/${historyLen - 1}";
        let size = badgeSize(fontAtlas, fontSize, message);
        badge(fontAtlas, fontSize, { x = 4.0, y = design#y - size#y - 4.0 }, message)

    // ── デバッグ小物の共通の見た目（黒地のパネル + 白文字）──

    def badgeFontSize(): Float64 = 8.0

    def badgePad(): Float64 = 3.0

    /// パネル全体（pad 込み）の大きさ。右寄せ・下寄せの位置計算に使う。
    def badgeSize(fontAtlas: FontAtlas, fontSize: Float64, message: String): Vec2.Vec2 =
        let size = Text.measure(Text.make(message, fontAtlas, fontSize));
        { x = size#x + badgePad() * 2.0, y = size#y + badgePad() * 2.0 }

    /// 黒地 alpha 0.7 のパネルに白文字を載せる。topLeft はパネルの左上（デザイン座標）。
    /// z はエンジンデバッグの範囲（ZBand.debugBase）— HUD の範囲より手前で、ゲームのどの絵にも
    /// 隠されない（デバッグ中の表示は常に読めるように）。
    def badge(fontAtlas: FontAtlas, fontSize: Float64, topLeft: Vec2.Vec2,
              message: String): List[Render.PlacedItem] =
        { at = topLeft,
          item = RawDraw.box(badgeSize(fontAtlas, fontSize, message),
                            { r = 0.0, g = 0.0, b = 0.0 },
                            ZBand.debugBase() + 1) |> Render.fade(0.7) }
        :: { at = { x = topLeft#x + badgePad(), y = topLeft#y + badgePad() },
             item = Render.text(message, fontAtlas, fontSize, ZBand.debugBase() + 2) }
        :: Nil

    // ── 保存完了メッセージ（トースト）──

    /// 保存完了メッセージを表示し始める（60fps で約 4 秒）。
    pub def showToast(message: String, state: State): State =
        { toast = Some({ message = message, framesLeft = 240 }) | state }

    /// メッセージの残り表示フレームを 1 減らし、尽きたら消す。
    pub def tickToast(state: State): State =
        { toast = state#toast |> Option.flatMap(t ->
            if (t#framesLeft <= 1) None else Some({ framesLeft = t#framesLeft - 1 | t })) | state }

    /// 保存完了メッセージの絵。画面左上に固定で置く。
    /// ズーム・パンの影響を受けないよう、呼び側は見え方の適用後にこれを重ねる。
    pub def toastItems(fontAtlas: FontAtlas, fontSize: Float64, message: String): List[Render.PlacedItem] =
        badge(fontAtlas, fontSize, { x = 4.0, y = 4.0 }, message)

    // ── fps 計測（直近の dt の指数移動平均）──

    /// 平滑化の強さ（新しい dt を毎フレーム 5% ずつ混ぜる ≈ 60fps なら約 1 秒で追従）。
    def fpsSmoothing(): Float64 = 0.05

    /// このフレームの dt を平均へ混ぜる。最初の 1 回は dt をそのまま採用する
    /// （0 から混ぜ始めると平均が実態に追いつくまで fps が数十倍に化けるため）。
    pub def recordDt(dt: Float64, state: State): State =
        let avg = if (state#fpsAvg <= 0.0) dt
                  else state#fpsAvg + (dt - state#fpsAvg) * fpsSmoothing();
        { fpsAvg = avg | state }

    /// 平均 dt から fps を出す（未計測なら 0）。表示用なので整数へ丸める。
    pub def fpsOf(state: State): Int32 =
        if (state#fpsAvg <= 0.0) 0
        else Float64.tryToInt32(1.0 / state#fpsAvg + 0.5) |> Option.getWithDefault(0)

    /// fps の絵。画面右上に固定で置く。
    /// ズーム・パンの影響を受けないよう、呼び側は見え方の適用後にこれを重ねる。
    /// fontSize は呼び側が決める。ドット絵のフォントは生成した大きさの等倍でしかくっきりせず、
    /// どの大きさが合うかはどのフォントで出すかを知っている呼び側にしか分からない。
    pub def fpsItems(fontAtlas: FontAtlas, fontSize: Float64, design: Vec2.Vec2,
                     fps: Int32): List[Render.PlacedItem] =
        let message = "fps ${fps}";
        let size = badgeSize(fontAtlas, fontSize, message);
        badge(fontAtlas, fontSize, { x = design#x - size#x - 4.0, y = 4.0 }, message)

    /// パネルの字の大きさの既定。実機のデバッグ表示は組み込みフォントの等倍で出すので、
    /// これを使うのは見本を生成する側（feature_lab の gallery）だけ。
    pub def defaultBadgeFontSize(): Float64 = badgeFontSize()

    // ── 座標変換（不変条件: toDesign(view, toScreen(view, p)) == p）──

    /// デザイン座標 → 画面座標。デザイン中央 c を焦点に zoom 倍し、pan だけずらす。
    pub def toScreen(view: View, p: Vec2.Vec2): Vec2.Vec2 =
        let c = Vec2.div(view#design, 2.0);
        Vec2.add(Vec2.add(Vec2.mul(Vec2.sub(p, c), view#zoom), c), view#pan)

    /// 画面座標 → デザイン座標（toScreen の逆写像）。
    /// 注釈の矩形はこれで求めるので、どれだけ拡大していても記録座標は変わらない。
    pub def toDesign(view: View, p: Vec2.Vec2): Vec2.Vec2 =
        let c = Vec2.div(view#design, 2.0);
        Vec2.add(Vec2.div(Vec2.sub(Vec2.sub(p, view#pan), c), view#zoom), c)

    /// カーソル位置を動かさずに拡大率を変える（虫眼鏡の中心が指先に付いてくる）。
    /// delta 1 につき 1.25 倍。拡大率は 1.0〜8.0 に収める。
    pub def zoomAt(cursor: Vec2.Vec2, delta: Float64, view: View): { zoom = Float64, pan = Vec2.Vec2 } =
        let factor = unchecked_cast(Math.pow(1.25, delta) as _ \ {});
        let newZoom = Float64.max(1.0, Float64.min(8.0, view#zoom * factor));
        // カーソル直下のデザイン座標が拡大後も同じ画面位置に来るよう pan を解き直す
        let anchor = toDesign(view, cursor);
        let c = Vec2.div(view#design, 2.0);
        let newPan = Vec2.sub(Vec2.sub(cursor, c), Vec2.mul(Vec2.sub(anchor, c), newZoom));
        { zoom = newZoom, pan = clampPan(newZoom, view#design, newPan) }

    /// pan を「デザイン領域が画面からはみ出さない」範囲に収める。
    /// 許容範囲は拡大率に比例して広がり、等倍では (0, 0) に潰れる —— だから
    /// 拡大中にどれだけ動き回っても、縮小し切れば必ず元の見え方に戻る。
    pub def clampPan(zoom: Float64, design: Vec2.Vec2, pan: Vec2.Vec2): Vec2.Vec2 =
        let c = Vec2.div(design, 2.0);
        let limitX = c#x * (zoom - 1.0);
        let limitY = c#y * (zoom - 1.0);
        { x = Float64.max(0.0 - limitX, Float64.min(limitX, pan#x)),
          y = Float64.max(0.0 - limitY, Float64.min(limitY, pan#y)) }

    // ── 1 フレームぶんの操作判断 ──

    /// 一時停止中のマウス操作をひとつ進める。戻り値は (次の状態, 確定した注釈矩形)。
    /// 矩形はデザイン座標。幅と高さがともに 2.0 未満のドラッグはクリック扱いで捨てる。
    /// パン操作（中ボタン or Space + 左）中は矩形ドラッグを始めない。
    pub def step(input: MouseInput, state: State): (State, Option[Rect2.Rect2]) =
        // 1. ホイールで拡大率と pan を更新（カーソル固定点ズーム）
        let view0 = viewOf(input#design, state);
        let zoomed = if (input#scroll != 0.0) zoomAt(input#cursor, input#scroll, view0)
                     else { zoom = state#zoom, pan = state#pan };
        // 2. パン: 操作が続いている間だけカーソルの移動量を pan へ足し込む
        //    （はみ出し防止のクランプ付き。等倍では pan は常に 0 に戻る）
        let panActive = input#middleDown or (input#spaceDown and input#leftDown);
        let pannedPan = if (panActive and state#prevPanActive)
                            Vec2.add(zoomed#pan, Vec2.sub(input#cursor, state#prevMouse))
                        else zoomed#pan;
        let view = { zoom = zoomed#zoom,
                     pan = clampPan(zoomed#zoom, input#design, pannedPan),
                     design = input#design };
        let cursorDesign = toDesign(view, input#cursor);
        // 3. 左ボタンの押した瞬間 / 離した瞬間で矩形ドラッグを進める
        let pressedEdge = input#leftDown and not state#prevLeftDown;
        let releasedEdge = not input#leftDown and state#prevLeftDown;
        let (nextDrag, emitted) = match (state#dragStart, pressedEdge, releasedEdge) {
            case (None, true, _) if not panActive => (Some(cursorDesign), None)
            case (Some(start), _, true)           => (None, acceptRect(start, cursorDesign))
            case (drag, _, _)                     => (drag, None)
        };
        let next = { zoom = view#zoom, pan = view#pan, dragStart = nextDrag,
                     prevLeftDown = input#leftDown, prevPanActive = panActive,
                     prevMouse = input#cursor | state };
        (next, emitted)

    /// ドラッグの両端から注釈矩形を作る。小さすぎる矩形（誤クリック）は捨てる。
    def acceptRect(a: Vec2.Vec2, b: Vec2.Vec2): Option[Rect2.Rect2] =
        let rect = normRect(a, b);
        if (rect#size#x >= 2.0 and rect#size#y >= 2.0) Some(rect) else None

    /// 2 点からどちら向きのドラッグでも同じ「左上 + 幅高さ」の矩形を作る。
    pub def normRect(a: Vec2.Vec2, b: Vec2.Vec2): Rect2.Rect2 =
        { position = { x = Float64.min(a#x, b#x), y = Float64.min(a#y, b#y) },
          size     = { x = Float64.abs(a#x - b#x), y = Float64.abs(a#y - b#y) } }

    /// 2 つの矩形が重なっているか（辺が触れているだけでも重なり扱い）。
    pub def rectIntersects(a: Rect2.Rect2, b: Rect2.Rect2): Bool =
        let ae = Rect2.end(a);
        let be = Rect2.end(b);
        a#position#x <= be#x and b#position#x <= ae#x and
        a#position#y <= be#y and b#position#y <= ae#y

    // ── 矩形に重なる描画物の列挙 ──

    /// 矩形に重なっていた描画物 1 件の記述。注釈 JSON にそのまま載る。
    pub type alias Hit = {
        kind = String,           // "sprite" | "text" | "box" | "poly"
        name = String,           // テクスチャ名 / テキスト内容（box・poly は空）
        position = Vec2.Vec2,    // 位置（デザイン座標）
        zIndex = Int32,          // 重なり順
        aabb = Rect2.Rect2       // この描画物を覆う矩形（デザイン座標）
    }

    /// 注釈矩形に重なる描画物を列挙する。テクスチャの寸法は sizeOf で引く
    /// （実行時は Game.getTextureInfo、テストでは固定の表を渡せる）。
    pub def hits(sizeOf: String -> Option[GameEngine.TextureInfo] \ ef,
                 rect: Rect2.Rect2, items: List[Render.PlacedItem]): List[Hit] \ ef =
        items |> List.filterMap(placed -> {
            let aabb = itemAabb(sizeOf, placed);
            if (rectIntersects(rect, aabb)) Some(hitOf(placed, aabb)) else None
        })

    /// 描画物 1 件を覆う矩形（デザイン座標）。回転は無視した外形の近似。
    /// 寸法の分からない Sprite は位置だけの点（サイズ 0）として扱う。
    pub def itemAabb(sizeOf: String -> Option[GameEngine.TextureInfo] \ ef,
                     placed: Render.PlacedItem): Rect2.Rect2 \ ef =
        let pos = placed#at;
        match placed#item {
            case Render.Item.Sprite(s) =>
                let base = match s#regionRect {
                    case Some(r) => r#size
                    case None    => match sizeOf(s#texture) {
                        case Some(info) => { x = info#width, y = info#height }
                        case None       => Vec2.zero()
                    }
                };
                let size = { x = base#x * Float64.abs(s#scale#x), y = base#y * Float64.abs(s#scale#y) };
                // centered な sprite は位置が中心なので、左上へ半分ずらす
                let topLeft = if (s#centered) Vec2.sub(pos, Vec2.div(size, 2.0)) else pos;
                { position = topLeft, size = size }
            case Render.Item.Text(t) =>
                { position = pos, size = Text.measure(Text.make(t#text, t#fontAtlas, t#fontSize)) }
            case Render.Item.Box(b) =>
                { position = pos, size = b#size }
            case Render.Item.Poly(p) =>
                vertexAabb(pos, p#vertices)
            case Render.Item.Shader(s) =>
                // シェーダー面の外形は塗る矩形そのもの（rect が位置とサイズを持つ）。
                s#rect
            case Render.Item.Clipped(c) =>
                // clip 矩形の外は描かれないので、外形も clip 矩形と交差させる — 完全に切り取られて
                // 見えない物が注釈やヒット一覧に載る嘘を作らない(交差が空なら負サイズ)。
                Rect2.intersect(c#rect, itemAabb(sizeOf, { at = pos, item = c#inner }))
        }

    /// 多角形の頂点列（位置からの相対座標）を覆う矩形。頂点が無ければ位置の点。
    def vertexAabb(pos: Vec2.Vec2, vertices: List[Vec2.Vec2]): Rect2.Rect2 =
        match vertices {
            case Nil => { position = pos, size = Vec2.zero() }
            case v :: rest =>
                let lo = List.foldLeft((acc, p) -> { x = Float64.min(acc#x, p#x), y = Float64.min(acc#y, p#y) }, v, rest);
                let hi = List.foldLeft((acc, p) -> { x = Float64.max(acc#x, p#x), y = Float64.max(acc#y, p#y) }, v, rest);
                { position = Vec2.add(pos, lo), size = Vec2.sub(hi, lo) }
        }

    /// 描画命令（Drawable）の列から矩形に重なる物を列挙する。view を持たず生の描画チャンネルを
    /// 登録するゲーム向け。texture が空の Drawable は単色の箱（scale が px サイズ）、
    /// それ以外はスプライト（scale は倍率・region 表示ぶんは uvScale で縮む）として外形を出す。
    pub def hitsFromDrawables(sizeOf: String -> Option[GameEngine.TextureInfo] \ ef,
                              rect: Rect2.Rect2, ds: List[GameEngine.Drawable]): List[Hit] \ ef =
        ds |> List.filterMap(dd -> {
            let d = DrawCmd.toSpec(dd);
            let aabb = drawableAabb(sizeOf, d);
            if (rectIntersects(rect, aabb))
                Some({ kind = if (d#texture == "") "box" else "sprite",
                       name = d#texture, position = d#position, zIndex = d#zIndex, aabb = aabb })
            else None
        })

    /// Drawable 1 件を覆う矩形（デザイン座標）。回転は無視した外形の近似。
    def drawableAabb(sizeOf: String -> Option[GameEngine.TextureInfo] \ ef,
                     d: DrawCmd.DrawableSpec): Rect2.Rect2 \ ef =
        let base = if (d#texture == "") { x = 1.0, y = 1.0 }
                   else match sizeOf(d#texture) {
                       case Some(info) => { x = info#width * d#uvScale#x, y = info#height * d#uvScale#y }
                       case None       => Vec2.zero()
                   };
        let size = { x = base#x * Float64.abs(d#scale#x), y = base#y * Float64.abs(d#scale#y) };
        let topLeft = if (d#centered) Vec2.sub(d#position, Vec2.div(size, 2.0)) else d#position;
        let aabb = { position = topLeft, size = size };
        // clip 矩形の外は描かれない — 外形も clip 矩形と交差させる(itemAabb の Clipped と同じ理由)。
        match d#clip {
            case None    => aabb
            case Some(r) => Rect2.intersect(r, aabb)
        }

    /// 描画物 1 件を Hit の形へ。
    def hitOf(placed: Render.PlacedItem, aabb: Rect2.Rect2): Hit =
        let pos = placed#at;
        match placed#item {
            case Render.Item.Sprite(s) =>
                { kind = "sprite", name = s#texture, position = pos, zIndex = s#zIndex, aabb = aabb }
            case Render.Item.Text(t) =>
                { kind = "text", name = t#text, position = pos, zIndex = t#zIndex, aabb = aabb }
            case Render.Item.Box(b) =>
                { kind = "box", name = "", position = pos, zIndex = b#zIndex, aabb = aabb }
            case Render.Item.Poly(p) =>
                { kind = "poly", name = "", position = pos, zIndex = p#zIndex, aabb = aabb }
            case Render.Item.Shader(s) =>
                { kind = "shader", name = s#spec#name, position = pos, zIndex = s#zIndex, aabb = aabb }
            case Render.Item.Clipped(c) =>
                // Hit の種類・名前・z は clip 矩形ではなく中身のもの。
                hitOf({ at = pos, item = c#inner }, aabb)
        }

    // ── 成果物の本文（文字列の組み立て）──

    /// annotation.json の本文。デザイン座標の矩形と、重なっていた描画物の一覧を機械可読に残す。
    pub def annotationJson(meta: { frame = Int64, design = Vec2.Vec2, rect = Rect2.Rect2 },
                           hitList: List[Hit]): String =
        use Util.Json.Json.{JObject, JString, JNumber, JArray};
        let obj = JObject(Map#{
            "version" => JNumber(JsonCodec.intToBd(1)),
            "frame"   => JNumber(JsonCodec.floatToBd(Int64.toFloat64(meta#frame))),
            "design"  => JObject(Map#{
                "w" => JNumber(JsonCodec.floatToBd(meta#design#x)),
                "h" => JNumber(JsonCodec.floatToBd(meta#design#y))
            }),
            "rect"    => rectJson(meta#rect),
            "hits"    => JArray(List.map(h -> hitJson(h), hitList) |> List.toVector)
        });
        Util.Json.toPrettyString(2, obj)

    def rectJson(rect: Rect2.Rect2): Util.Json.Json =
        use Util.Json.Json.{JObject, JNumber};
        JObject(Map#{
            "x" => JNumber(JsonCodec.floatToBd(rect#position#x)),
            "y" => JNumber(JsonCodec.floatToBd(rect#position#y)),
            "w" => JNumber(JsonCodec.floatToBd(rect#size#x)),
            "h" => JNumber(JsonCodec.floatToBd(rect#size#y))
        })

    def hitJson(hit: Hit): Util.Json.Json =
        use Util.Json.Json.{JObject, JString, JNumber};
        JObject(Map#{
            "kind"   => JString(hit#kind),
            "name"   => JString(hit#name),
            "x"      => JNumber(JsonCodec.floatToBd(hit#position#x)),
            "y"      => JNumber(JsonCodec.floatToBd(hit#position#y)),
            "zIndex" => JNumber(JsonCodec.intToBd(hit#zIndex)),
            "aabb"   => rectJson(hit#aabb)
        })

    /// README.md に挟む人間向けの要約（囲った場所と、そこに描かれていた物）。
    pub def readmeBody(meta: { frame = Int64, rect = Rect2.Rect2 }, hitList: List[Hit]): String =
        let hitLines = match hitList {
            case Nil => "- （なし）"
            case _   => hitList |> List.map(h -> hitLine(h)) |> String.intercalate("\n")
        };
        "## 囲った場所\n\n"
        + "- フレーム: ${meta#frame}\n"
        + "- 矩形: x=${meta#rect#position#x}, y=${meta#rect#position#y}, "
        + "w=${meta#rect#size#x}, h=${meta#rect#size#y}（デザイン座標）\n\n"
        + "## 矩形内の描画物\n\n"
        + hitLines

    def hitLine(hit: Hit): String =
        let label = if (hit#name == "") hit#kind else "${hit#kind} `${hit#name}`";
        "- ${label} (x=${hit#position#x}, y=${hit#position#y}, z=${hit#zIndex})"

    // ── 一時停止中の表示 ──

    /// ドラッグ中の矩形オーバーレイ（薄い塗り + 枠線）。デザイン座標の列に混ぜて描く。
    /// zIndex はエンジンデバッグの範囲（ZBand.debugBase）— ゲームのどの絵にも隠されない。
    pub def overlayItems(dragStart: Vec2.Vec2, cursorDesign: Vec2.Vec2): List[Render.PlacedItem] =
        let rect = normRect(dragStart, cursorDesign);
        let red = { r = 1.0, g = 0.25, b = 0.25 };
        { at = rect#position,
          item = RawDraw.box(rect#size, red, ZBand.debugBase())
              |> Render.fade(0.25)
              |> Render.outline(red, 1.0) } :: Nil

    /// 描画命令の列へ見え方（ズーム・パン）を適用する。位置は toScreen、大きさは zoom 倍。
    /// 角丸・枠線幅など px 単位の飾り（BoxStyle）も一緒に zoom 倍する —— これを忘れると
    /// 角丸ボックスで描いた円が拡大時に四角へ化ける。
    pub def applyInspect(view: View, ds: List[GameEngine.Drawable]): List[GameEngine.Drawable] =
        if (isIdentity(view)) ds
        else ds |> List.map(dd -> {
            let d = DrawCmd.toSpec(dd);
            DrawCmd.make({ position = toScreen(view, d#position),
                           scale = Vec2.mul(d#scale, view#zoom),
                           style = Option.map(st -> scaleStyle(view#zoom, st), d#style),
                           // clip 矩形も一緒に写す — 忘れると中身だけ動いて、切り口が
                           // スクリーンに置き去りになる(ズームすると見当違いに切れる)。
                           clip = Option.map(r -> inspectRect(view, r), d#clip) | d })
        })

    /// 矩形へ見え方を適用する(位置は toScreen、大きさは zoom 倍。軸平行なので厳密に写る)。
    def inspectRect(view: View, r: Rect2.Rect2): Rect2.Rect2 =
        { position = toScreen(view, r#position),
          size = { x = r#size#x * view#zoom, y = r#size#y * view#zoom } }

    /// BoxStyle の px 単位フィールドを zoom 倍する（対象フィールドの表は DrawCmd.scalePx が持つ）。
    def scaleStyle(zoom: Float64, style: GameEngine.BoxStyle): GameEngine.BoxStyle =
        DrawCmd.scalePx(zoom, style)

    /// 多角形の描画命令へ見え方を適用する（頂点は画面 px の絶対座標なので各頂点を写す）。
    pub def applyInspectPoly(view: View, ps: List[GameEngine.PolygonRenderCmd]): List[GameEngine.PolygonRenderCmd] =
        if (isIdentity(view)) ps
        else ps |> List.map(p -> { vertices = List.map(v -> toScreen(view, v), p#vertices),
                                   clip = Option.map(r -> inspectRect(view, r), p#clip) | p })

    /// タイルマップの描画命令へ見え方を適用する（位置は toScreen、タイル倍率は zoom 倍）。
    pub def applyInspectTiles(view: View, ts: List[GameEngine.TileMapRenderCmd]): List[GameEngine.TileMapRenderCmd] =
        if (isIdentity(view)) ts
        else ts |> List.map(t -> { position = toScreen(view, t#position),
                                   tileScale = Vec2.mul(t#tileScale, view#zoom) | t })

    /// 等倍・ずらし無し（変換しても何も変わらない）か。
    def isIdentity(view: View): Bool =
        view#zoom == 1.0 and view#pan#x == 0.0 and view#pan#y == 0.0
}
