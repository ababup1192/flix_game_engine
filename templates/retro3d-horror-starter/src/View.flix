// View — 描く元と World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
// 3D の場面（SchoolView）を App の view で描き、HUD（App.withHudView）に部屋の名前・紙のマップ（MapView）・終了の確認の窓を重ねる。
// 場面は 2 枚重ねる: 校舎の場面（z 0）→ アイテム画面の間だけ黒の半透明の幕（z 1）→ 目の前の物だけの場面（z 2・ItemsView）。
// HUD は 3D の霧と暗さの外なので、字はいつも読める。
//
// 層の並び（奥 → 手前）と、絵の下限の 5 性質の受け持ち:
//   1. 校舎（SchoolView）… 頂点の色にベイクした部屋の明るさと木目のテクスチャ＝面に階調と質感／霧で奥を闇へ沈める＝層が分かれる／PS1 風の色の段とディザ・頂点のがたつき。
//   2. 人物と小物（CastView・ItemsView）… 灯りの下に立つ低ポリの人の形＝主役が背景から分離・形が物として読める／待ちの揺れと歩く頭の上下＝時間が流れる。
//   3. 暗い幕と目の前の物（アイテム画面の間だけ）… 校舎を落として持ち物だけを前へ出す＝層が分かれる。
//   4. テレビのにじみ（Game.withCrt の後がけ）… 走査線と横のにじみで 3D の場面全体を一枚の画面にまとめる。
//   5. HUD … 部屋の名前・字幕（タイプライターで字が出る＝時間が流れる）・紙の地図・終了の確認の窓。
// 押せる物の当たりは絵と同じ木に ZStack.hit で積む（promptLayers）。描く compose と押した物を選ぶ
// SortingLayer.pickFrom（Controls）が同じ木を読むので、当たりの表を別に書かない。
mod View {
    use fge::{App, Camera3d, Color, Display, GameEngine, Num, RawDraw, Render, Scene3d, SortingLayer, TextDraw, UiTypewriter, Vec2, ZStack}
    use ZOrder.Layer

    /// 3D の場面に要る値を写す（View の中で World を読むのは入口とここだけ）。2 枚目の場面の物も一緒に組む。
    def inputOf(res: Res.Res, w: World.World): (SchoolView.In, List[Scene3d.Instance3d]) =
        let pov = World.povOf(res, w);
        let floors = School.visibleFloors(res#layout, pov#feet);
        let people = CastView.instancesOf({ t = w#t, cast = res#cast, people = res#people, floors = floors, layout = res#layout, attention = w#attention, player = pov#feet });
        let base = { t = w#t, pov = pov, floors = floors, here = Layout.floorIndexAt(pov#feet#y, res#layout),
                     look = Res.lookOf(res), school = res#school, layout = res#layout, people = people, props = Nil,
                     peopleTextures = res#people |> Map.valuesOf |> List.flatMap(m -> m#textures) };
        let inventory = World.inventoryOf(res, w);
        let shown = World.itemsScreenOf(w) |> Option.flatMap(i -> List.nth(i#cursor, inventory) |> Option.map(item -> (item, i#started)));
        let items = { t = w#t, items = res#items, layout = res#layout, props = res#assets#props, doors = res#doors,
                      taken = World.takenOf(w), unlocked = World.unlockedOf(w), pickup = World.pickupOf(w), shown = shown,
                      eye = pov#eye, yaw = pov#yaw, forward = Camera3d.forward(SchoolView.cameraOf(base)) };
        ({ props = ItemsView.sceneInstances(items) | base }, ItemsView.overlayInstances(items))

    /// 全部の階の動かない物の集まりを先に作る時の、校舎の場面（App.withPreload3d の scenes。描く時と同じ光と psx の版）。
    pub def preloadScenes(res: Res.Res, w: World.World): List[Scene3d.Scene3dCmd] = SchoolView.sceneOf(fst(inputOf(res, w))) :: Nil

    /// 3D の場面: 校舎の場面と、目の前の物があればその場面（アイテム画面の間は間に暗い幕）。
    pub def frame(_ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        let (v, overlay) = inputOf(res, w);
        let curtain = if (World.isItemsOpen(w)) curtainOf(ItemsDoc.rec(res#items)#screens#curtain) :: Nil else Nil;
        let front = if (List.isEmpty(overlay)) Nil else Render.scene3d(Vec2.zero(), SchoolView.overlayOf(v, overlay)) :: Nil;
        List.flatten((Render.scene3d(Vec2.zero(), SchoolView.sceneOf(v)) :: Nil) :: curtain :: front :: Nil)

    /// 校舎の場面を暗く落とす黒の幕（2 枚の場面の間の z 1）。
    def curtainOf(alpha: Float64): Render.PlacedItem =
        { at = Vec2.zero(), item = RawDraw.box({ x = World.width(), y = World.height() }, Color.rgb(0.0, 0.0, 0.0), 1) |> Render.fade(alpha) }

    /// HUD に要る値。caption = 出ている部屋の名前と濃さ（RoomCaption）・size = 字幕の字の大きさ・text = 字の色・map = 開いている紙のマップ・quit = 終了の確認。
    /// mark = 目の前の物の印の字（「Space: 話す」「Space: 拾う」「Space: 調べる」）・dialogue = 字幕（台詞・「〇〇を手に入れた。」・「鍵がかかっている。」の全文と、見えている字数）。
    /// items = アイテム画面（開いている間だけ）。
    /// subtitle = 会話の字幕の見た目（光の Doc）・controls = 隅の操作方法（行・出具合・置き方。出ていなければ None）。
    pub type alias Hud = { caption = Option[(String, Float64)], size = Float64, text = Color, map = Option[MapView.In], prompt = Prompt,
                           mark = Option[String], dialogue = Option[(String, Int32)], subtitle = LookDoc.Subtitle, controls = Option[ControlsHint], items = Option[ItemsHud] }

    /// アイテム画面の HUD。title = 一覧の見出し・names = 持ち物の名前（拾った順）・cursor = 選んでいる番号・text = 選んだ物の説明文・empty = 何も無い時の字。
    pub type alias ItemsHud = { title = String, names = List[String], cursor = Int32, text = String, empty = String }

    /// 隅の操作方法。lines = 出す行・level = 出具合（0〜1）・hint = 置く隅と濃さ（歩きの Doc）。
    pub type alias ControlsHint = { lines = List[String], level = Float64, hint = WalkDoc.Hint }

    /// 終了の確認の窓に要る値。
    pub type alias Prompt = { asking = Bool, text = String, color = Color }

    pub def promptOf(res: Res.Res, w: World.World): Prompt =
        { asking = World.isAskingQuit(w), text = Res.walkOf(res)#quitPrompt, color = Res.lookOf(res)#hudText }

    def hudOf(ctx: App.ViewCtx, res: Res.Res, w: World.World): Hud =
        let atlas = ctx#atlas;
        let feet = World.feetOf(w);
        let map = World.mapFloorOf(w) |> Option.map(n ->
            { t = w#t, sheet = PaperMap.sheetOf(res#layout, res#mapFrame, n, World.visitedOf(w)), floors = res#layout#floors |> List.map(f -> f#index),
              here = Layout.floorIndexAt(feet#y, res#layout), you = PaperMap.toPaper(res#mapFrame, feet), atlas = atlas });
        let shown = w#caption#shown |> Option.filter(_ -> w#caption#alpha > 0.0) |> Option.map(name -> (name, w#caption#alpha));
        let talk = World.talkOf(w) |> Option.map(tk -> (tk#reveal#text, UiTypewriter.visibleCount(tk#reveal)));
        let said = (text: String) -> (text, String.length(text));
        let dialogue = firstOf(talk :: (gotTextOf(res, World.pickupOf(w), w#t) |> Option.map(said))
                               :: (noticeTextOf(res, World.noticeOf(w) |> Option.filter(_ -> not World.isItemsOpen(w)), w#t) |> Option.map(said)) :: Nil);
        let items = World.itemsScreenOf(w) |> Option.map(itemsHudOf(res, World.inventoryOf(res, w)));
        let texts = ItemsDoc.rec(res#items)#texts;
        let mark = firstOf((World.talkTargetOf(res, w) |> Option.map(_ -> CastDoc.rec(res#cast)#talkHint))
                           :: (World.pickupTargetOf(res, w) |> Option.map(_ -> texts#pickHint))
                           :: (World.doorTargetOf(res, w) |> Option.map(_ -> texts#doorHint)) :: Nil);
        { caption = if (Option.nonEmpty(map) or Option.nonEmpty(dialogue) or Option.nonEmpty(items) or not Res.walkOf(res)#captionOn) None else shown, size = Res.walkOf(res)#captionSize, text = Res.lookOf(res)#hudText,
          map = map, prompt = promptOf(res, w), mark = mark, dialogue = dialogue,
          subtitle = Res.lookOf(res)#subtitle, controls = controlsOf(ctx#display#pointer, res, World.controlsHintOf(w)), items = items }

    /// 並びの最初の Some。
    def firstOf(xs: List[Option[a]]): Option[a] = xs |> List.flatMap(Option.toList) |> List.head

    /// 拾う演出の字幕「〇〇を手に入れた。」（物が目の前に着いてから演出の終わりまで）。
    def gotTextOf(res: Res.Res, pickup: Option[World.PickupRec], t: Float64): Option[String] =
        let d = ItemsDoc.rec(res#items);
        pickup |> Option.filter(p -> t - p#started >= d#pickup#flySec)
            |> Option.flatMap(p -> Items.itemAt(res#items, p#pickup)) |> Option.map(item -> ItemsDoc.fill(d#texts#got, item#name))

    /// 出している一言（出してから noticeSec の間だけ）。
    def noticeTextOf(res: Res.Res, notice: Option[World.Notice], t: Float64): Option[String] =
        let sec = ItemsDoc.rec(res#items)#screens#noticeSec;
        notice |> Option.filter(n -> t - n#started < sec) |> Option.map(n -> n#text)

    /// アイテム画面の HUD の値。
    def itemsHudOf(res: Res.Res, inventory: List[ItemsDoc.Item], i: World.ItemsRec): ItemsHud =
        let texts = ItemsDoc.rec(res#items)#texts;
        { title = texts#listTitle, names = inventory |> List.map(item -> item#name), cursor = i#cursor,
          text = List.nth(i#cursor, inventory) |> Option.map(item -> item#text) |> Option.getWithDefault(""), empty = texts#empty }

    /// 隅の操作方法の中身。指で触った後はスマホの行（歩きの Doc）、ほかはキー割り当ての今のキーから作った行。
    def controlsOf(pointer: Display.PointerKind, res: Res.Res, level: Float64): Option[ControlsHint] =
        let hint = Res.walkOf(res)#hint;
        let lines = if (pointer == Display.PointerKind.Touch) hint#touchLines else controlsLines(res#keys);
        if (level <= 0.0) None else Some({ lines = lines, level = level, hint = hint })

    /// キー割り当てから作る操作方法の行（移動・向き・見上げ・走る・調べる・持ち物・地図）。どの操作も先頭のキーを見せる。
    def controlsLines(keys: KeysDoc.Doc): List[String] =
        let k = KeysDoc.rec(keys);
        let first = (ks: List[GameEngine.Key]) -> List.head(ks) |> Option.map(keyLabel) |> Option.getWithDefault("");
        ("移動　" + first(k#forward) + first(k#strafeLeft) + first(k#back) + first(k#strafeRight))
            :: ("向き　マウス / " + first(k#turnLeft) + first(k#turnRight))
            :: ("見上げ　" + first(k#lookUp) + " / " + first(k#lookDown))
            :: ("走る　" + first(k#dash))
            :: ("調べる　" + first(k#talk))
            :: ("持ち物　" + first(k#items))
            :: ("地図　" + first(k#map))
            :: Nil

    /// 画面に出すキーの名前（矢印は記号・左右の Shift などは左右を書かない・数字は数字だけ）。
    def keyLabel(key: GameEngine.Key): String = match key {
        case GameEngine.Key.Up         => "↑"
        case GameEngine.Key.Down       => "↓"
        case GameEngine.Key.Left       => "←"
        case GameEngine.Key.Right      => "→"
        case GameEngine.Key.LeftShift  => "Shift"
        case GameEngine.Key.RightShift => "Shift"
        case GameEngine.Key.LeftCtrl   => "Ctrl"
        case GameEngine.Key.RightCtrl  => "Ctrl"
        case GameEngine.Key.LeftAlt    => "Alt"
        case GameEngine.Key.RightAlt   => "Alt"
        case other                     => String.stripPrefix(substr = "Digit", "${other}") |> Option.getWithDefault("${other}")
    }

    /// HUD（部屋の名前と終了の確認の窓）。
    pub def hud(ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        let h = hudOf(ctx, res, w);
        SortingLayer.compose(ctx, (Layer.Caption, ZStack.leaf(List.append(caption(ctx, h), perfLines(ctx, w#perf))))
            :: (Layer.Dialogue, ZStack.leaf(List.append(talkMark(ctx, h), subtitle(ctx, h))))
            :: (Layer.Map, ZStack.leaf(h#map |> Option.map(MapView.items) |> Option.getWithDefault(Nil)))
            :: (Layer.Hint, ZStack.leaf(if (Option.nonEmpty(h#items)) Nil else h#controls |> Option.map(controlsBox(ctx, h#text, h#subtitle)) |> Option.getWithDefault(Nil)))
            :: (Layer.Items, ZStack.leaf(h#items |> Option.map(itemsScreen(ctx, h)) |> Option.getWithDefault(Nil)))
            :: promptLayers(ctx, h#prompt))

    /// 画面の下の部屋の名前（RoomCaption が選んだ部屋・出る消えるの濃さつき）。字は大きく、四方へ 1 px ずらした濃い紺の字を下に敷いて縁取る
    /// （霧と懐中電灯の明るい所の上でも字の形が読める）。
    // WhyNot: 縁取りの字を半透明の帯だけで済ませない — 字を 2 倍にすると帯の端が字に近づき、明るい床の上で字の縁が溶けた。
    def caption(ctx: App.ViewCtx, h: Hud): List[Render.PlacedItem] = match h#caption {
        case None => Nil
        case Some((text, alpha)) =>
            let center = { x = World.width() / 2.0, y = World.height() - 10.0 - h#size / 2.0 };
            let edge = Color.rgb(0.01, 0.01, 0.04);
            let label = (dx: Float64, dy: Float64, color: Color, z: Int32) ->
                TextDraw.centeredAt({ text = text, atlas = ctx#atlas, size = h#size, color = color, z = z, center = { x = center#x + dx, y = center#y + dy } })
                    |> Render.overItem(Render.fade(alpha));
            List.append(
                ((-1.0, 0.0) :: (1.0, 0.0) :: (0.0, -1.0) :: (0.0, 1.0) :: Nil) |> List.map(d -> label(fst(d), snd(d), edge, 0)),
                label(0.0, 0.0, h#text, 1) :: Nil)
    }

    def edgeColor(): Color = Color.rgb(0.01, 0.01, 0.04)

    /// 目の前の物の印（「話す」「拾う」「調べる」）: 話しかけられる相手・拾える物・鍵の戸の方を向いている間、画面の真ん中の少し下に、字幕より小さく出す。
    /// 後ろに枠線の無い黒い半透明の角丸の箱を敷く（明るい壁の前でも読める）。会話の字幕には箱を敷かない。
    // WhyNot: 部屋の名前と同じ Caption の層に置かない — 画面なしの描き出しでは、Caption の層の箱が 3D の場面の奥に回って見えなかった。
    def talkMark(ctx: App.ViewCtx, h: Hud): List[Render.PlacedItem] =
        match h#mark {
            case Some(text) if Option.isEmpty(h#dialogue) and Option.isEmpty(h#items) =>
                let st = h#subtitle;
                let center = { x = World.width() / 2.0, y = World.height() / 2.0 + 30.0 };
                let measured = TextDraw.size(text, ctx#atlas, st#hintSize);
                let size = { x = measured#x + 2.0 * st#hintPad, y = measured#y + 2.0 * st#hintPad };
                let box = if (st#hintBox <= 0.0) Nil
                          else { at = { x = center#x - size#x / 2.0, y = center#y - size#y / 2.0 },
                                 item = RawDraw.box(size, Color.rgb(0.0, 0.0, 0.0), 1) |> Render.rounded(2.0) |> Render.fade(st#hintBox) } :: Nil;
                List.append(box, TextDraw.centeredAt({ text = text, atlas = ctx#atlas, size = st#hintSize, color = h#text, z = 2, center = center })
                                     |> Render.overItem(Render.fade(st#hintAlpha)) :: Nil)
            case _ => Nil
        }

    /// 隅の操作方法: 「話す」の印と同じ流儀（枠線の無い黒い半透明の角丸の箱・印と同じ字の大きさと濃さ）で並べる。
    /// 行は最初の全角の空白で操作の名前とキーに分け、キーの列を揃える。濃さは印の濃さに Doc の alpha と出具合を掛ける。
    def controlsBox(ctx: App.ViewCtx, color: Color, st: LookDoc.Subtitle, c: ControlsHint): List[Render.PlacedItem] =
        let lineH = st#hintSize + 3.0;
        let measure = text -> TextDraw.width(text, ctx#atlas, st#hintSize);
        let cells = c#lines |> List.map(splitLabel);
        let labelW = cells |> List.map(cell -> measure(fst(cell))) |> List.maximum |> Option.getWithDefault(0.0);
        let keysW = cells |> List.map(cell -> measure(snd(cell))) |> List.maximum |> Option.getWithDefault(0.0);
        let gap = if (keysW > 0.0) st#hintSize * 0.75 else 0.0;
        let widest = labelW + gap + keysW;
        let size = { x = widest + 2.0 * st#hintPad, y = lineH * Int32.toFloat64(List.length(c#lines)) - 3.0 + 2.0 * st#hintPad };
        let m = c#hint#margin;
        let left = match c#hint#corner {
            case WalkDoc.Corner.TopLeft    => true
            case WalkDoc.Corner.BottomLeft => true
            case _                         => false
        };
        let top = match c#hint#corner {
            case WalkDoc.Corner.TopLeft  => true
            case WalkDoc.Corner.TopRight => true
            case _                       => false
        };
        let at = { x = if (left) m else World.width() - m - size#x, y = if (top) m else World.height() - m - size#y };
        let strength = c#hint#alpha * c#level;
        let box = if (st#hintBox <= 0.0) Nil
                  else { at = at, item = RawDraw.box(size, Color.rgb(0.0, 0.0, 0.0), 1) |> Render.rounded(2.0) |> Render.fade(st#hintBox * strength) } :: Nil;
        let cellAt = (text: String, x: Float64, i: Int32) ->
            TextDraw.centeredAt({ text = text, atlas = ctx#atlas, size = st#hintSize, color = color, z = 2,
                                  center = { x = x + measure(text) / 2.0, y = at#y + st#hintPad + st#hintSize / 2.0 + lineH * Int32.toFloat64(i) } })
                |> Render.overItem(Render.fade(st#hintAlpha * strength));
        let rows = cells |> List.mapWithIndex((i, cell) ->
            cellAt(fst(cell), at#x + st#hintPad, i) :: cellAt(snd(cell), at#x + st#hintPad + labelW + gap, i) :: Nil) |> List.flatten;
        List.append(box, rows)

    /// 行を最初の全角の空白で (操作の名前, キー) に分ける（空白が無ければ全部を名前に）。
    def splitLabel(line: String): (String, String) = match String.splitOn(substr = "　", line) {
        case label :: rest => (label, String.intercalate("　", rest))
        case Nil           => (line, "")
    }

    /// 会話の字幕: 画面の下の真ん中に白い字を最大 2 行（映画の字幕の形・話し手の名前と枠は出さない）。折り返す所は全文で決め
    /// （SubtitleWrap）、文字送りの途中でも行の高さを動かさない。字は 3D の絵（320×240）で描かず、HUD として窓の画素でなめらかに描く。
    // WhyNot: 枠の箱と話し手の名前を出さない — ノベルゲームの窓に見える（人の注文）。3D ゲームの台詞は字幕の形が普通。
    def subtitle(ctx: App.ViewCtx, h: Hud): List[Render.PlacedItem] = match h#dialogue {
        case None => Nil
        case Some((full, shown)) =>
            let st = h#subtitle;
            let all = wrapped(st, full);
            let k = List.length(all);
            let bottomY = World.height() - st#bottom - st#size / 2.0;
            SubtitleWrap.revealed(all, shown) |> List.zipWithIndex |> List.flatMap(e -> {
                let (i, text) = e;
                subtitleLine(ctx, st, text, { x = World.width() / 2.0, y = bottomY - Int32.toFloat64(k - 1 - i) * (st#size + st#lineGap) })
            })
    }

    /// 字幕の行: 書いた改行で分けてから、それぞれを字数で折り返す。
    def wrapped(st: LookDoc.Subtitle, full: String): List[String] =
        String.splitOn(substr = "\n", full) |> List.flatMap(SubtitleWrap.linesOf(Num.floorInt(st#maxChars)))

    /// アイテム画面: 左上に見出しと持ち物の名前の一覧（選んでいる物は白く・ほかは薄く）、下に選んだ物の説明文（字幕と同じ字）。
    /// 真ん中の回る物は 2 枚目の場面（View.frame）。
    def itemsScreen(ctx: App.ViewCtx, h: Hud, it: ItemsHud): List[Render.PlacedItem] =
        let st = h#subtitle;
        let left = 14.0;
        let row = st#hintSize + 6.0;
        let label = (text: String, y: Float64, size: Float64, alpha: Float64) ->
            TextDraw.centeredAt({ text = text, atlas = ctx#atlas, size = size, color = h#text, z = 2,
                                  center = { x = left + TextDraw.width(text, ctx#atlas, size) / 2.0, y = y } }) |> Render.overItem(Render.fade(alpha));
        let names = if (List.isEmpty(it#names)) label(it#empty, 20.0 + row * 1.5, st#hintSize, 0.6) :: Nil
                    else it#names |> List.mapWithIndex((i, name) -> label(name, 20.0 + row * (1.5 + Int32.toFloat64(i)), st#hintSize + 1.0, if (i == it#cursor) 1.0 else 0.45));
        let lines = wrapped(st, it#text);
        let k = List.length(lines);
        let bottomY = World.height() - st#bottom - st#size / 2.0;
        let body = lines |> List.zipWithIndex |> List.flatMap(e -> {
            let (i, text) = e;
            subtitleLine(ctx, st, text, { x = World.width() / 2.0, y = bottomY - Int32.toFloat64(k - 1 - i) * (st#size + st#lineGap) })
        });
        List.flatten((label(it#title, 20.0, st#hintSize, 0.7) :: names) :: body :: Nil)

    /// 字幕の 1 行。奥から: 字の幅の薄い帯（band が 0 なら敷かない）・右下の柔らかい影・細い縁取り・
    /// 赤と青を 1 窓 px ずつ左右にずらした色のにじみ・白い字・字に掛かる細い走査線。にじみと走査線は読みやすさを落とさない薄さ（光の Doc）。
    def subtitleLine(ctx: App.ViewCtx, st: LookDoc.Subtitle, body: String, center: Vec2.Vec2): List[Render.PlacedItem] =
        let half = 0.5;
        let w = TextDraw.width(body, ctx#atlas, st#size);
        let label = (dx: Float64, dy: Float64, color: Color, alpha: Float64, z: Int32) ->
            TextDraw.centeredAt({ text = body, atlas = ctx#atlas, size = st#size, color = color, z = z, center = { x = center#x + dx, y = center#y + dy } })
                |> Render.overItem(Render.fade(alpha));
        let band = if (st#band <= 0.0) Nil
                   else { at = { x = center#x - w / 2.0 - 6.0, y = center#y - st#size / 2.0 - 3.0 },
                          item = RawDraw.box({ x = w + 12.0, y = st#size + 6.0 }, Color.rgb(0.0, 0.0, 0.02), 0) |> Render.fade(st#band) } :: Nil;
        let outline = ((0.0 - half, 0.0) :: (half, 0.0) :: (0.0, 0.0 - half) :: (0.0, half) :: Nil)
            |> List.map(d -> label(fst(d), snd(d), edgeColor(), st#outline, 2));
        let rows = Float64.ceil(st#size + 2.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let scan = if (st#scanline <= 0.0) Nil
                   else List.range(0, rows) |> List.map(i -> { at = { x = center#x - w / 2.0 - 1.0, y = center#y - st#size / 2.0 - 1.0 + Int32.toFloat64(i) },
                                                              item = RawDraw.box({ x = w + 2.0, y = half }, Color.rgb(0.0, 0.0, 0.0), 7) |> Render.fade(st#scanline) });
        List.flatten(band :: (label(1.0, 1.0, edgeColor(), st#shadow, 1) :: Nil) :: outline
                     :: (label(0.0 - half, 0.0, Color.rgb(1.0, 0.25, 0.25), st#chroma, 3) :: label(half, 0.0, Color.rgb(0.3, 0.45, 1.0), st#chroma, 4) :: Nil)
                     :: (label(0.0, 0.0, Color.rgb(1.0, 1.0, 0.98), 1.0, 5) :: Nil) :: scan :: Nil)

    /// 重さの表示（F3）: 左上に fps・CPU と GPU の ms・3D の置いた数と描いた数と draw call・draw call が分かれた理由。
    def perfLines(ctx: App.ViewCtx, perf: Option[World.Perf]): List[Render.PlacedItem] = match perf {
        case None    => Nil
        case Some(p) =>
            let lines = PerfText.linesOf(p, ctx#diagnostics);
            { at = Vec2.zero(), item = RawDraw.box({ x = World.width(), y = 12.0 * Int32.toFloat64(List.length(lines)) + 2.0 }, Color.rgb(0.0, 0.0, 0.0), 0) |> Render.fade(0.6) } ::
            (lines |> List.mapWithIndex((i, text) -> { at = { x = 2.0, y = 1.0 + 12.0 * Int32.toFloat64(i) }, item = Render.textTinted(text, ctx#atlas, 10.0, Color.rgb(0.6, 1.0, 0.6), 1) }))
    }

    // ── 終了の確認の窓（Layer.Prompt） ──

    /// 層ごとの木（絵と押せる物の当たり）。Controls.tapAt も同じ木から押した物を選ぶ。
    pub def promptLayers(ctx: App.ViewCtx, p: Prompt): List[(Layer, ZStack.Tree[Layer, World.Press])] =
        (Layer.Prompt, quitPrompt(ctx, p)) :: Nil

    /// Esc か閉じるボタンで出る確認。場面を薄く沈める幕・窓・文言。窓の中を押すと QuitYes・外を押すと QuitNo。
    def quitPrompt(ctx: App.ViewCtx, p: Prompt): ZStack.Tree[Layer, World.Press] =
        if (not p#asking) ZStack.leaf(Nil)
        else {
            let screen = { x = World.width(), y = World.height() };
            let box = { x = screen#x * 0.8, y = 32.0 };
            let at = { x = (screen#x - box#x) / 2.0, y = (screen#y - box#y) / 2.0 };
            let shade = Color.rgb(0.02, 0.025, 0.06);
            let window =
                { at = Vec2.zero(), item = RawDraw.box(screen, shade, 0) |> Render.fade(0.6) }
                    :: { at = at, item = RawDraw.box(box, Color.lighten(shade, 0.06), 1) }
                    :: TextDraw.centeredAt({ text = p#text, atlas = ctx#atlas, size = 10.0, color = p#color, z = 2,
                                             center = { x = screen#x / 2.0, y = screen#y / 2.0 } })
                    :: Nil;
            ZStack.blocking(Some(World.Press.QuitNo),
                ZStack.of(ZStack.leaf(window) :: ZStack.hit(World.Press.QuitYes, { position = at, size = box }) :: Nil))
        }
}
