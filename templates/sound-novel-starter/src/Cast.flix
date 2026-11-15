// Cast — 立ち絵と小物の層（純粋）: シナリオの <<show>> / <<hide>> / <<move>> の引数から作る意味、出す・替える・消すの重ね方、セーブに残す形、置き場所と描き方。
// 絵は 2D の透過画像（project.json の textures「cast_<名前>_<表情>」）を、2 つの画素の間をなめらかにつなぐシェーダーの面で貼る。
// 出し入れと位置の名前の替えはクロスフェード。位置のずれ・大きさ・濃さ・傾きは Stage の actor.<名>.* の鍵（PropertyTween）が持ち、ここは描く時に読むだけ。
// 描くのは字より必ず奥（背景に付く絵は背景のすぐ上・ほかは world の層・小物は頁の幕がある間だけ幕の上。置き分けは View）。
// 色は背景の時間帯から掛ける（Light）。
mod Cast {
    use fge::{Clock, Curve, JsonCodec, Num, Rect2, Render, ShaderDoc, Sort, Sway}
    use fge::ShaderDoc.{Field, Out, Shade, TexChan}
    use CastDoc.Kind
    use Util.Json.Json

    /// 出ている 1 人（か小物 1 つ）の形: 名前・表情・位置の名前。
    pub type alias Figure = { name = String, face = String, slot = String }

    /// 下に敷いた形と、その濃さ（敷いた時に見えていた濃さのまま変えない）。
    pub type alias Under = { figure = Figure, alpha = Float64 }

    /// 出ている物。now = 今の形、before = 同じ位置で表情を替えている間だけ下に敷く前の形、startedAt / seconds = 重ね始めた物語の時刻と長さ。
    pub type alias Shown = { kind = Kind, now = Figure, before = Option[Under], startedAt = Clock.Time[Stage.Story], seconds = Float64 }

    /// 消えていく物（消した・同じ位置に別の物が来た・位置を替えた前の位置）。alpha = 消え始めた時に見えていた濃さ（そこから 0 へ）。
    /// startedAt が先の時刻なら、その時刻まではその濃さのまま残る（<<move 名 to=…>> が端の外へ着いた時に消す）。
    pub type alias Leaving = { kind = Kind, figure = Figure, alpha = Float64, startedAt = Clock.Time[Stage.Story], seconds = Float64 }

    /// 層。shown = 出ている物（出した順。描く時は Doc の layer で並べ直す）、leaving = 消えていく物。
    pub type alias Layer = { shown = List[Shown], leaving = List[Leaving] }

    /// セーブ・バックログに残す形（重ねの途中は持たず、終わりの形だけ）。cast = 人物、props = 小物（どちらも出した順）。
    pub type alias Mark = { cast = List[Figure], props = List[Figure] }

    /// 省いた語。face / slot が真なら、その物がもう出ていれば今の表情 / 位置のまま（出ていなければ Figure に入れた Doc の既定）。
    pub type alias Keep = { face = Bool, slot = Bool }

    /// 出す時の意味。exclusive = figure の位置が 1 つしか立てない位置か。
    pub type alias ShowCue = { kind = Kind, figure = Figure, keep = Keep, seconds = Float64, exclusive = Bool }

    /// 消す時の意味。name が None なら全部。delay 秒の後から seconds 秒で消す。
    pub type alias HideCue = { name = Option[String], seconds = Float64, delay = Float64 }

    /// コマンド 1 つの意味。Show = 出す・表情や位置を替える、Hide = 消す。
    pub enum Cue {
        case Show(ShowCue)
        case Hide(HideCue)
    }

    pub def empty(): Layer = { shown = Nil, leaving = Nil }

    // ── コマンドの引数から意味を作る（引数の読み方は Commands の show・hide・move） ──

    /// 名前の種類（cast にあれば人物・props にあれば小物）。どちらにも無ければ None。
    def kindOf(doc: CastDoc.Doc, name: String): Option[Kind] =
        if (Option.nonEmpty(CastDoc.entryOf(Kind.Character, name, doc))) Some(Kind.Character)
        else if (Option.nonEmpty(CastDoc.entryOf(Kind.Prop, name, doc))) Some(Kind.Prop)
        else None

    /// 名前の Doc の項目（人物か小物。どちらにも無ければ None）。
    pub def entryOf(doc: CastDoc.Doc, name: String): Option[CastDoc.Entry] =
        kindOf(doc, name) |> Option.flatMap(kind -> CastDoc.entryOf(kind, name, doc))

    /// 出す・表情や位置を替える。face / slot / seconds を省くと、出ている形のまま（出ていなければ Doc の face・slot）・Doc の fadeSeconds。
    /// 名前・表情・位置が Doc に無ければ Err（無い名前で舞台を消さない）。
    pub def showCue(doc: CastDoc.Doc, name: String, face: Option[String], slot: Option[String], seconds: Option[Float64]): Result[String, Cue] =
        let d = CastDoc.rec(doc);
        let entryOfKind = kind -> CastDoc.entryOf(kind, name, doc) |> Option.map(entry -> (kind, entry));
        match kindOf(doc, name) |> Option.flatMap(entryOfKind) {
            case None => Err("知らない人物か小物 '${name}'")
            case Some((kind, entry)) =>
                if (face |> Option.exists(f -> not List.memberOf(f, entry#faces))) Err("'${name}' に無い表情 '${Option.getWithDefault("", face)}'")
                else if (slot |> Option.exists(s -> not Map.memberOf(s, d#slots))) Err("知らない位置 '${Option.getWithDefault("", slot)}'")
                else {
                    let figure = { name = name, face = Option.getWithDefault(entry#face, face), slot = Option.getWithDefault(entry#slot, slot) };
                    Ok(Cue.Show({ kind = kind, figure = figure, keep = { face = Option.isEmpty(face), slot = Option.isEmpty(slot) },
                                  seconds = secondsOr(d, seconds), exclusive = Map.get(figure#slot, d#slots) |> Option.exists(s -> s#exclusive) }))
                }
        }

    /// その人（か小物）を delay 秒の後から消す。
    pub def hideCue(doc: CastDoc.Doc, name: String, seconds: Option[Float64], delay: Float64): Result[String, Cue] =
        kindOf(doc, name) |> Option.map(_ -> Cue.Hide({ name = Some(name), seconds = secondsOr(CastDoc.rec(doc), seconds), delay = delay }))
            |> Option.toOk("知らない人物か小物 '${name}'")

    /// 人物と小物を全部消す。
    pub def hideAllCues(doc: CastDoc.Doc, seconds: Option[Float64]): List[Cue] =
        Cue.Hide({ name = None, seconds = secondsOr(CastDoc.rec(doc), seconds), delay = 0.0 }) :: Nil

    /// 位置 slot に出ている物を全部消す。
    pub def hideAtCues(doc: CastDoc.Doc, slot: String, seconds: Option[Float64], layer: Layer): List[Cue] =
        let s = secondsOr(CastDoc.rec(doc), seconds);
        layer#shown |> List.filter(x -> x#now#slot == slot) |> List.map(x -> Cue.Hide({ name = Some(x#now#name), seconds = s, delay = 0.0 }))

    /// cues が消す物の名前（今の層で出ている物のうち）。
    pub def hiddenNamesOf(cues: List[Cue], layer: Layer): List[String] =
        let named = cues |> List.filterMap(cue -> match cue {
            case Cue.Hide(c) => Some(c#name)
            case Cue.Show(_) => None
        });
        let picked = named |> List.filterMap(n -> n) |> List.toSet;
        if (List.exists(Option.isEmpty, named)) shownNames(layer)
        else shownNames(layer) |> List.filter(name -> Set.memberOf(name, picked))

    def secondsOr(d: CastDoc.Rec, seconds: Option[Float64]): Float64 = Float64.max(0.0, Option.getWithDefault(d#fadeSeconds, seconds))

    // ── 層に反映する ──

    /// コマンド 1 つを層に反映する（now = 物語の時計の今）。そのついでに、消え終わった物と、重ね終わった前の形を落とす。
    pub def apply(now: Clock.Time[Stage.Story], cue: Cue, layer: Layer): Layer =
        let pruned = prune(now, layer);
        match cue {
            case Cue.Show(c) => showFigure(now, c, pruned)
            case Cue.Hide(c) => hideWhere(now, c, pruned)
        }

    /// 省いた語を、出ている形（current）から埋めた形。
    pub def resolve(current: Option[Figure], figure: Figure, keep: Keep): Figure =
        let kept = (wanted, pick) -> if (wanted) current |> Option.map(pick) else None;
        { face = kept(keep#face, f -> f#face) |> Option.getWithDefault(figure#face),
          slot = kept(keep#slot, f -> f#slot) |> Option.getWithDefault(figure#slot) | figure }

    /// コマンドが出す形（出ている物がいればその形から埋める）。
    pub def targetOf(cue: Cue, layer: Layer): Option[(Kind, Figure)] = match cue {
        case Cue.Show(c) => Some((c#kind, resolve(currentOf(c#figure#name, layer), c#figure, c#keep)))
        case Cue.Hide(_) => None
    }

    /// 名前の物が出ていれば、その今の形（消えていく途中の物は出ていない）。
    pub def currentOf(name: String, layer: Layer): Option[Figure] =
        layer#shown |> List.find(s -> s#now#name == name) |> Option.map(s -> s#now)

    /// 名前の物が出ているか。
    pub def isShown(name: String, layer: Layer): Bool = Option.nonEmpty(currentOf(name, layer))

    /// 出ている物の名前（出した順）。
    pub def shownNames(layer: Layer): List[String] = layer#shown |> List.map(s -> s#now#name)

    pub def sameFigure(a: Figure, b: Figure): Bool = a#name == b#name and a#face == b#face and a#slot == b#slot

    def entering(kind: Kind, now: Clock.Time[Stage.Story], figure: Figure, seconds: Float64): Shown =
        { kind = kind, now = figure, before = None, startedAt = now, seconds = seconds }

    /// 今の形の濃さ（出てくる途中なら 0 と 1 の間）。
    def nowAlphaOf(now: Clock.Time[Stage.Story], shown: Shown): Float64 = easedOf(progressOf(now, shown#startedAt, shown#seconds))

    /// いちばん濃く見えている形とその濃さ（表情を替えている途中なら、まだ下の形の方が濃いことがある）。
    def visibleOf(now: Clock.Time[Stage.Story], shown: Shown): Under =
        let top = { figure = shown#now, alpha = nowAlphaOf(now, shown) };
        match shown#before {
            case Some(under) if under#alpha > top#alpha => under
            case _                                      => top
        }

    /// 消えていく物にする。見えている濃さから 0 へ消す（出てくる途中で消しても一度濃くしない）。
    /// 表情を替えている途中なら、下に敷いた形もその濃さから消す。秒も delay も 0 ならその場で消すので残さない。
    def leave(now: Clock.Time[Stage.Story], seconds: Float64, delay: Float64, shown: Shown): List[Leaving] =
        let startsAt = Clock.after(Float64.max(0.0, delay), now);
        let going = (under: Under) -> { kind = shown#kind, figure = under#figure, alpha = under#alpha, startedAt = startsAt, seconds = seconds };
        let top = { figure = shown#now, alpha = nowAlphaOf(now, shown) };
        if (seconds <= 0.0 and delay <= 0.0) Nil
        else List.map(going, (shown#before |> Option.toList) ::: (top :: Nil)) |> List.filter(l -> l#alpha > 0.0)

    /// 同じ位置で表情を替える: 見えている形を、見えている濃さのまま下に敷き、新しい形を上から重ねる
    /// （前の形を濃さ 1 で敷くと、出てくる途中に替えた時に急に濃くなる）。形が同じなら何もしない。
    def recast(now: Clock.Time[Stage.Story], figure: Figure, seconds: Float64, shown: Shown): Shown =
        if (sameFigure(shown#now, figure)) shown else { now = figure, before = Some(visibleOf(now, shown)), startedAt = now, seconds = seconds | shown }

    /// 出す: 出ていて位置が同じなら重ねて替え、そうでなければ前の位置の形（と、1 つしか立てない位置に出ている物）を消して新しく出す。
    def showFigure(now: Clock.Time[Stage.Story], c: ShowCue, layer: Layer): Layer =
        let current = layer#shown |> List.find(s -> s#now#name == c#figure#name);
        let target = resolve(current |> Option.map(s -> s#now), c#figure, c#keep);
        if (current |> Option.exists(s -> s#now#slot == target#slot))
            { shown = layer#shown |> List.map(s -> if (s#now#name == target#name) recast(now, target, c#seconds, s) else s) | layer }
        else {
            let (out, kept) = List.partition(s -> s#now#name == target#name or (c#exclusive and s#now#slot == target#slot), layer#shown);
            { shown = List.append(kept, entering(c#kind, now, target, c#seconds) :: Nil),
              leaving = List.append(layer#leaving, out |> List.flatMap(leave(now, c#seconds, 0.0))) | layer }
        }

    def hideWhere(now: Clock.Time[Stage.Story], c: HideCue, layer: Layer): Layer =
        let (out, kept) = List.partition(s -> c#name |> Option.forAll(n -> s#now#name == n), layer#shown);
        { shown = kept, leaving = List.append(layer#leaving, out |> List.flatMap(leave(now, c#seconds, c#delay))) | layer }

    /// 消え終わった物と、重ね終わった前の形を落とす。
    def prune(now: Clock.Time[Stage.Story], layer: Layer): Layer =
        let settledBefore = (s: Shown) -> if (progressOf(now, s#startedAt, s#seconds) >= 1.0) { before = None | s } else s;
        { shown = layer#shown |> List.map(settledBefore),
          leaving = layer#leaving |> List.filter(l -> progressOf(now, l#startedAt, l#seconds) < 1.0) }

    /// 重ねの途中を終わりの形にする（セーブから戻った時・素材を待つ黒の間・描き出しで場面を作る時）。
    pub def settle(layer: Layer): Layer =
        { shown = layer#shown |> List.map(s -> { before = None, startedAt = Clock.never() | s }), leaving = Nil }

    // ── セーブに残す形 ──

    pub def markOf(layer: Layer): Mark =
        let of = kind -> layer#shown |> List.filter(s -> s#kind == kind) |> List.map(s -> s#now);
        { cast = of(Kind.Character), props = of(Kind.Prop) }

    /// 残した形から、重ね終わった層を作る（人物 → 小物の順）。
    pub def layerOf(mark: Mark): Layer =
        let shown = (kind, figure) -> { kind = kind, now = figure, before = None, startedAt = Clock.never(), seconds = 0.0 };
        { shown = List.append(mark#cast |> List.map(f -> shown(Kind.Character, f)), mark#props |> List.map(f -> shown(Kind.Prop, f))), leaving = Nil }

    def figureToJson(f: Figure): Json =
        Json.JObject(Map#{ "name" => Json.JString(f#name), "face" => Json.JString(f#face), "slot" => Json.JString(f#slot) })

    def figureFrom(json: Json): Option[Figure] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { name = JsonCodec.stringOr("name", "", obj), face = JsonCodec.stringOr("face", "", obj), slot = JsonCodec.stringOr("slot", "", obj) })

    /// セーブの枠の "cast" に書く値: { "characters": [形…], "props": [形…] }。
    pub def markToJson(mark: Mark): Json =
        Json.JObject(Map#{ "characters" => JsonCodec.encodeList(figureToJson, mark#cast), "props" => JsonCodec.encodeList(figureToJson, mark#props) })

    /// セーブの枠の "cast" の値から読む。小物が 1 つだけの "prop"（形か null）の枠も読む。欄が無い・読めない古いセーブは空（fail-open）。
    pub def markFromJson(json: Option[Json]): Mark =
        let obj = json |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
        let listOf = key -> Map.get(key, obj) |> Option.flatMap(JsonCodec.decodeList(figureFrom));
        let single = Map.get("prop", obj) |> Option.flatMap(figureFrom) |> Option.toList;
        { cast = listOf("characters") |> Option.getWithDefault(Nil), props = listOf("props") |> Option.getWithDefault(single) }

    // ── 使う絵の名前 ──

    pub def textureOf(figure: Figure): String = CastDoc.textureOf(figure#name, figure#face)

    /// 層に出ている物のテクスチャの名前（素材を待つ時に見る）。
    pub def textures(layer: Layer): List[String] = layer#shown |> List.map(s -> textureOf(s#now))

    // ── 重ねの進み ──

    /// 重ねの進み（0〜1。始まる前は 0・始まっていて秒が 0 なら 1）。
    def progressOf(now: Clock.Time[Stage.Story], startedAt: Clock.Time[Stage.Story], seconds: Float64): Float64 =
        let since = Clock.since(startedAt, now);
        if (since < 0.0) 0.0 else if (seconds <= 0.0) 1.0 else Float64.min(1.0, since / seconds)

    /// 進みを、出だしと終わりがゆっくりの濃さにする（0 → 0・1 → 1）。
    def easedOf(progress: Float64): Float64 = 0.5 + Curve.sine(0.5, Num.pi(), Num.pi() * -0.5, progress)

    /// 消えていく物の今の濃さ。
    def leavingAlphaOf(now: Clock.Time[Stage.Story], l: Leaving): Float64 = l#alpha * (1.0 - easedOf(progressOf(now, l#startedAt, l#seconds)))

    /// 人物がどれだけ出ているか（0〜1）: 見えている人物の濃さの最大。縦の頁の覆いを薄くする量に使う。背景に付く絵は数えない。
    pub def presenceOf(now: Clock.Time[Stage.Story], doc: CastDoc.Doc, layer: Layer): Float64 =
        let counts = (kind, name) -> kind == Kind.Character and not (entryOf(doc, name) |> Option.exists(CastDoc.isAttachedToBackdrop));
        let shown = layer#shown |> List.filter(s -> counts(s#kind, s#now#name)) |> List.map(s -> visibleOf(now, s)#alpha);
        let going = layer#leaving |> List.filter(l -> counts(l#kind, l#figure#name)) |> List.map(leavingAlphaOf(now));
        List.append(shown, going) |> List.foldLeft(Float64.max, 0.0)

    // ── 置き場所と描き方 ──

    /// 描く元: Doc・並べ方の組（画面の大きさと縦か横か）・2 本の時計の今・まだ届いていない絵の名前・背景の時間帯から掛ける色・
    /// 舞台の名前の付いた値（actor.<名>.* を読む）・今の背景の写真の名前（背景に付く絵のずれを引く）。
    pub type alias Env = {
        doc = CastDoc.Doc,
        fit = Layout.Fit,
        storyNow = Clock.Time[Stage.Story],
        realNow = Clock.Time[Clock.Real],
        missing = Set[String],
        light = Light,
        props = PropertyTween.Table[Stage.Story],
        photo = Option[String]
    }

    /// 置き場所からのずれ: dx / dy = 画面の幅と高さに対する割合、scale = 足元を据えて掛ける倍率、alpha = 濃さに掛ける倍率、degrees = 真ん中を軸に時計回りに傾ける角度、
    /// jitter = その絵だけの揺れ（px）。
    pub type alias Transform = { dx = Float64, dy = Float64, scale = Float64, alpha = Float64, degrees = Float64, jitter = { x = Float64, y = Float64 } }

    /// ずらさない形。
    pub def identity(): Transform = { dx = 0.0, dy = 0.0, scale = 1.0, alpha = 1.0, degrees = 0.0, jitter = { x = 0.0, y = 0.0 } }

    /// 絵に掛ける色 1 つ。key = 時間帯の名前（シェーダーの名前に入れる）、r / g / b = 色ごとの倍率（明るさ込み）、saturation = 彩度。
    pub type alias Tone = { key = String, r = Float64, g = Float64, b = Float64, saturation = Float64 }

    /// 背景の切り替えに合わせて previous から current へ、progress（0〜1）でなめらかに替える。
    pub type alias Light = { previous = Tone, current = Tone, progress = Float64 }

    /// 掛けない色（絵のまま）。
    pub def plainTone(): Tone = { key = "plain", r = 1.0, g = 1.0, b = 1.0, saturation = 1.0 }

    /// 時間帯 key の cast の欄から作る色。
    pub def toneOf(key: String, g: BackdropDoc.CastGrade): Tone =
        { key = key, r = g#tint#r * g#exposure, g = g#tint#g * g#exposure, b = g#tint#b * g#exposure, saturation = g#saturation }

    /// 切り替えずに 1 つの色を掛け続ける。
    pub def steadyLight(tone: Tone): Light = { previous = tone, current = tone, progress = 1.0 }

    /// 位置の一覧（縦の画面は portraitSlots）。
    def slotsOf(env: Env): Map[String, CastDoc.Slot] =
        if (Layout.isPortrait(env#fit)) CastDoc.rec(env#doc)#portraitSlots else CastDoc.rec(env#doc)#slots

    /// 置き場の矩形: 足元を bottom、中心を x に合わせ、高さは画面の高さ × height × scale。画面からはみ出す分は縮める
    /// （サムネで切り抜きが効かないシェーダーの面なので、画面の中に収めておく）。
    pub def rectOf(fit: Layout.Fit, slot: CastDoc.Slot, entry: CastDoc.Entry): Rect2.Rect2 =
        let size = Layout.size(fit);
        let h = Float64.max(0.0, slot#height * size#y * entry#scale);
        let w = h * Float64.max(0.0, entry#aspect);
        let cx = Float64.max(0.0, Float64.min(size#x, slot#x * size#x));
        let foot = Float64.max(0.0, Float64.min(size#y, slot#bottom * size#y));
        let fits = (room, need) -> if (need <= 0.0) 1.0 else room / need;
        let k = Float64.min(1.0, Float64.min(fits(foot, h), Float64.min(fits(2.0 * cx, w), fits(2.0 * (size#x - cx), w))));
        { position = { x = cx - w * k / 2.0, y = foot - h * k }, size = { x = w * k, y = h * k } }

    /// 置き場の矩形 r を t でずらした矩形（大きさは足元の真ん中を据えて掛ける。傾きは描く時に掛ける）。
    pub def movedRect(fit: Layout.Fit, t: Transform, r: Rect2.Rect2): Rect2.Rect2 =
        let size = Layout.size(fit);
        let k = Float64.max(0.0, t#scale);
        let footX = r#position#x + r#size#x / 2.0 + t#dx * size#x + t#jitter#x;
        let footY = r#position#y + r#size#y + t#dy * size#y + t#jitter#y;
        { position = { x = footX - r#size#x * k / 2.0, y = footY - r#size#y * k }, size = { x = r#size#x * k, y = r#size#y * k } }

    /// 名前の物の今のずれ（舞台の actor.<名>.* と、背景に付く絵なら今の写真の横のずれ）。
    def transformOf(env: Env, name: String, entry: CastDoc.Entry): Transform =
        let t = Stage.actorTransformAt(env#storyNow, name, env#props);
        { dx = t#dx + CastDoc.attachShiftOf(env#photo, entry#attach) | t }

    /// 透過画像を読む面（2 つの画素の間をなめらかにつないで読む。縁の透明な画素の色は art/cast/prepare.py が縁の色で埋めてある）。
    /// 色: l = 明るさ、c1 = l + 彩度 × (c − l)、c2 = c1 × 倍率。彩度と倍率は previous から current へ、面の t（切り替えの進み）でつなぐ。
    /// turned なら、面を傾けた絵の外接する矩形にし、Param の turn_a〜turn_d（tiltParamsOf）で読む座標を回して、絵の外は透かす。
    // WhyNot: Render.sprite で貼らない — 2D の絵は格子に乗せる前提で、縮めると画素を飛ばして読み、輪郭がぎざぎざになる。
    // WhyNot: 進みを Const で埋め込まない — Spec が毎フレーム変わると、実機はシェーダーを組み直し続ける（t で渡せば時間帯の組ごとに 1 本）。
    // WhyNot: 傾きを Field.Rotate で書かない — 回す量が Const なので、傾きが動く間ずっと Spec が替わる。Render.turned も Shader の面は傾けない。
    def pictureSpec(texture: String, light: Light, turned: Bool): ShaderDoc.Spec =
        let k = v -> Field.Const(v);
        let bin = (op, a, b) -> Field.Bin({ op = op, a = a, b = b });
        let param = name -> Field.Param({ name = name });
        let centered = axis -> bin(ShaderDoc.BinOp.Sub, Field.Uv({ axis = axis }), k(0.5));
        let along = (pa, pb) -> bin(ShaderDoc.BinOp.Add, k(0.5), bin(ShaderDoc.BinOp.Add, bin(ShaderDoc.BinOp.Mul, centered(ShaderDoc.Axis.U), param(pa)),
                                                                                         bin(ShaderDoc.BinOp.Mul, centered(ShaderDoc.Axis.V), param(pb))));
        let shifted = of -> if (turned) Field.Shift({ dx = bin(ShaderDoc.BinOp.Sub, Field.Ref("tu"), Field.Uv({ axis = ShaderDoc.Axis.U })),
                                                      dy = bin(ShaderDoc.BinOp.Sub, Field.Ref("tv"), Field.Uv({ axis = ShaderDoc.Axis.V })), of = of }) else of;
        let read = chan -> Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = shifted(Field.Tex({ name = texture, chan = chan })) });
        let inside = name -> bin(ShaderDoc.BinOp.Mul, bin(ShaderDoc.BinOp.Step, k(0.0), Field.Ref(name)), bin(ShaderDoc.BinOp.Step, Field.Ref(name), k(1.0)));
        let alpha = if (turned) bin(ShaderDoc.BinOp.Mul, read(TexChan.A), bin(ShaderDoc.BinOp.Mul, inside("tu"), inside("tv"))) else read(TexChan.A);
        let steady = light#previous#key == light#current#key;
        let between = (a, b) -> if (steady or a == b) k(b) else bin(ShaderDoc.BinOp.Add, k(a), bin(ShaderDoc.BinOp.Mul, k(b - a), Field.Ref("p")));
        let luma = bin(ShaderDoc.BinOp.Add, bin(ShaderDoc.BinOp.Add, bin(ShaderDoc.BinOp.Mul, k(0.299), Field.Ref("r")), bin(ShaderDoc.BinOp.Mul, k(0.587), Field.Ref("g"))),
                       bin(ShaderDoc.BinOp.Mul, k(0.114), Field.Ref("b")));
        let channel = (name, gain) -> {
            let c1 = bin(ShaderDoc.BinOp.Add, Field.Ref("l"), bin(ShaderDoc.BinOp.Mul, between(light#previous#saturation, light#current#saturation), bin(ShaderDoc.BinOp.Sub, Field.Ref(name), Field.Ref("l"))));
            bin(ShaderDoc.BinOp.Mul, c1, gain)
        };
        let suffix = if (not steady) "_${light#previous#key}_${light#current#key}"
                     else if (light#current#key == plainTone()#key) ""
                     else "_${light#current#key}";
        let tilt = if (turned) ("tu", along("turn_a", "turn_b")) :: ("tv", along("turn_c", "turn_d")) :: Nil else Nil;
        { name = "picture_${texture}${suffix}${if (turned) "_turned" else ""}", cycleRate = 0.0,
          bindings = tilt ::: (("r", read(TexChan.R)) :: ("g", read(TexChan.G)) :: ("b", read(TexChan.B)) :: ("l", luma) ::
                     ("p", Field.Un({ op = ShaderDoc.UnOp.Sat, of = Field.Time({ scale = 1.0, offset = k(0.0) }) })) :: Nil),
          out = Out.Fill({ shade = Shade.Rgb({ r = channel("r", between(light#previous#r, light#current#r)),
                                               g = channel("g", between(light#previous#g, light#current#g)),
                                               b = channel("b", between(light#previous#b, light#current#b)) }),
                           alpha = alpha }) }

    /// 矩形 r を真ん中を軸に degrees 傾けた絵の、外接する矩形と、その矩形の uv から絵の uv を読む係数（turn_a〜turn_d）。
    /// 絵の u = 0.5 + (u' − 0.5)·a + (v' − 0.5)·b・v = 0.5 + (u' − 0.5)·c + (v' − 0.5)·d（u' v' は外接する矩形の uv）。
    pub def tiltOf(degrees: Float64, r: Rect2.Rect2): (Rect2.Rect2, Map[String, Float64]) =
        let rad = degrees * Num.pi() / 180.0;
        let (c, s) = (Num.cos(rad), Num.sin(rad));
        let (w, h) = (r#size#x, r#size#y);
        let bw = Float64.abs(w * c) + Float64.abs(h * s);
        let bh = Float64.abs(w * s) + Float64.abs(h * c);
        let center = { x = r#position#x + w / 2.0, y = r#position#y + h / 2.0 };
        let per = (n, d) -> if (d <= 0.0) 0.0 else n / d;
        ({ position = { x = center#x - bw / 2.0, y = center#y - bh / 2.0 }, size = { x = bw, y = bh } },
         Map#{ "turn_a" => per(bw * c, w), "turn_b" => per(bh * s, w), "turn_c" => per(0.0 - bw * s, h), "turn_d" => per(bh * c, h) })

    /// 1 つの形を濃さ alpha で描く。知らない名前・位置・表情と、まだ届いていない絵は描かない。
    // WhyNot: Doc の faces に無い表情を貼りに行かない — 未登録のテクスチャは GL では黒（0 番）が貼られ、黒い四角が出る。
    /// 息の揺れは足元を据えたまま高さを僅かに伸び縮みさせる（上下に動かすと足元の下に隙間が覗く）。
    def figureItem(env: Env, figure: Figure, alpha: Float64, z: Int32): List[Render.PlacedItem] =
        let texture = textureOf(figure);
        match placementOf(env, figure) {
            case Some((_, r, t)) if alpha * t#alpha > 0.0 and not Set.memberOf(texture, env#missing) =>
                let size = Layout.size(env#fit);
                let breath = CastDoc.rec(env#doc)#sway * size#y * Sway.wave(Clock.secondsOf(env#realNow), r#position#x / Float64.max(1.0, size#x), 1.6);
                let grow = if (r#size#y <= 0.0) 0.0 else breath / r#size#y;
                let swayed = { position = { x = r#position#x - r#size#x * grow / 2.0, y = r#position#y - breath },
                               size = { x = r#size#x * (1.0 + grow), y = r#size#y + breath } };
                let faded = Render.overItem(Render.fade(alpha * t#alpha));
                if (t#degrees == 0.0) faded(Render.shaderFill(pictureSpec(texture, env#light, false), swayed, env#light#progress, z)) :: Nil
                else {
                    let (box, params) = tiltOf(t#degrees, swayed);
                    faded(Render.shaderFill(pictureSpec(texture, env#light, true), box, env#light#progress, z) |> Render.withShaderParams(params)) :: Nil
                }
            case _ => Nil
        }

    /// Doc の項目と、ずらした後の置き場の矩形と、ずれ（知らない名前・位置・表情なら None）。
    def placementOf(env: Env, figure: Figure): Option[(CastDoc.Entry, Rect2.Rect2, Transform)] =
        forM (entry <- entryOf(env#doc, figure#name) |> Option.filter(e -> List.memberOf(figure#face, e#faces));
              slot <- Map.get(figure#slot, slotsOf(env)))
        yield {
            let t = transformOf(env, figure#name, entry);
            (entry, movedRect(env#fit, t, rectOf(env#fit, slot, entry)), t)
        }

    /// 出ている人物と小物の置き場（消えていく物と、描かない物 = 知らない名前・まだ届いていない絵は除く）。label = Doc の人に見せる名前。
    pub def placedOf(env: Env, layer: Layer): List[{ kind = Kind, figure = Figure, label = String, rect = Rect2.Rect2 }] =
        layer#shown |> List.filter(s -> not Set.memberOf(textureOf(s#now), env#missing))
              |> List.filterMap(s -> placementOf(env, s#now)
                     |> Option.map(match (entry, r, _) -> { kind = s#kind, figure = s#now, label = entry#label, rect = r }))

    /// 出ている物 1 つ: 同じ位置で表情を替えている間は、前の形を敷いた時の濃さで下に残し、今の形を上から濃くする（途中で背景が透けない）。
    def shownItems(env: Env, shown: Shown, z: Int32): List[Render.PlacedItem] =
        let a = nowAlphaOf(env#storyNow, shown);
        let under = shown#before |> Option.map(b -> figureItem(env, b#figure, b#alpha, z)) |> Option.getWithDefault(Nil);
        List.append(under, figureItem(env, shown#now, a, z))

    /// 層の全部を z に描く（重ね順の小さい物から。同じ重ね順なら消えていく物 → 出ている物）。
    pub def items(env: Env, layer: Layer, z: Int32): List[Render.PlacedItem] = groupsWhere(env, (_, _) -> true, layer, z) |> List.flatMap(snd)

    /// 層のうち keep（列と Doc の項目）が真の物だけを、絵 1 つずつ (Doc の layer, z に描いた物) にして重ね順に並べる
    /// （同じ重ね順なら消えていく物 → 出ている物、それぞれ出した順）。Doc に無い名前は描かない。
    pub def groupsWhere(env: Env, keep: (Kind, CastDoc.Entry) -> Bool, layer: Layer, z: Int32): List[(Int32, List[Render.PlacedItem])] =
        let layerOf = (kind, name) -> entryOf(env#doc, name) |> Option.filter(e -> keep(kind, e)) |> Option.map(e -> e#layer);
        let going = layer#leaving |> List.filterMap(l -> layerOf(l#kind, l#figure#name)
            |> Option.map(n -> ((n, 0), (n, figureItem(env, l#figure, leavingAlphaOf(env#storyNow, l), z)))));
        let shown = layer#shown |> List.filterMap(s -> layerOf(s#kind, s#now#name) |> Option.map(n -> ((n, 1), (n, shownItems(env, s, z)))));
        List.append(going, shown) |> Sort.sortStableBy(fst) |> List.map(snd)
}
