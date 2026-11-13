// Cast — 立ち絵と小物の層（純粋）: シナリオの <<char>> / <<item>> の読み方、出す・替える・消すの重ね方、セーブに残す形、置き場所と描き方。
// 絵は 2D の透過画像（project.json の textures「cast_<名前>_<表情>」）を、2 つの画素の間をなめらかにつなぐシェーダーの面で貼る。
// 位置の替えはクロスフェードだけで、すべらせない。描くのは world の層（View.frame）で、字の地より必ず奥。
mod Cast {
    use fge::{Clock, Curve, JsonCodec, Num, Rect2, Render, ShaderDoc, Sway, Yarn}
    use fge::ShaderDoc.{Field, Out, Shade, TexChan}
    use CastDoc.Kind
    use Util.Json.Json

    /// 出ている 1 人（か小物 1 つ）の形: 名前・表情・位置の名前。
    pub type alias Figure = { name = String, face = String, slot = String }

    /// 下に敷いた形と、その濃さ（敷いた時に見えていた濃さのまま変えない）。
    pub type alias Under = { figure = Figure, alpha = Float64 }

    /// 出ている物。now = 今の形、before = 同じ位置で表情を替えている間だけ下に敷く前の形、startedAt / seconds = 重ね始めた物語の時刻と長さ。
    pub type alias Shown = { now = Figure, before = Option[Under], startedAt = Clock.Time[Stage.Story], seconds = Float64 }

    /// 消えていく物（消した・同じ位置に別の人が来た・位置を替えた前の位置）。alpha = 消え始めた時に見えていた濃さ（そこから 0 へ）。
    pub type alias Leaving = { kind = Kind, figure = Figure, alpha = Float64, startedAt = Clock.Time[Stage.Story], seconds = Float64 }

    /// 層。cast = 出ている人物（後ろほど手前）、prop = 出ている小物（人物より手前）、leaving = 消えていく物。
    pub type alias Layer = { cast = List[Shown], prop = Option[Shown], leaving = List[Leaving] }

    /// セーブ・バックログに残す形（重ねの途中は持たず、終わりの形だけ）。
    pub type alias Mark = { cast = List[Figure], prop = Option[Figure] }

    /// 省いた語。face / slot が真なら、その人がもう出ていれば今の表情 / 位置のまま（出ていなければ Figure に入れた Doc の既定）。
    pub type alias Keep = { face = Bool, slot = Bool }

    /// コマンド 1 つの意味。Show = 出す・表情や位置を替える（秒）、Hide = 消す（名前が None ならその列を全部）。
    pub enum Cue {
        case Show(Kind, Figure, Keep, Float64)
        case Hide(Kind, Option[String], Float64)
    }

    pub def empty(): Layer = { cast = Nil, prop = None, leaving = Nil }

    // ── シナリオのコマンドを読む ──

    /// <<char 名前 [表情] [位置] [秒]>> / <<char 名前 off [秒]>> / <<char off [秒]>> と、同じ形の <<item>> を読む。
    /// 名前の後ろの語は、位置の名前 → その人の表情の名前 → 数（秒）の順に読み、どれでもなければ Err。
    pub def cueOf(doc: CastDoc.Doc, command: Yarn.Command): Result[String, Cue] =
        let at = " (${Yarn.sourceText(command#source)})";
        let kind = if (command#name == "item") Kind.Prop else Kind.Character;
        let d = CastDoc.rec(doc);
        match command#args {
            case Nil                => Err("<<${command#name}>> の名前が無い${at}")
            case "off" :: rest      => secondsOf(d#fadeSeconds, rest, at) |> Result.map(s -> Cue.Hide(kind, None, s))
            case name :: "off" :: rest => secondsOf(d#fadeSeconds, rest, at) |> Result.map(s -> Cue.Hide(kind, Some(name), s))
            case name :: rest       =>
                match CastDoc.entryOf(kind, name, doc) {
                    case None        => Err("知らない${kindWord(kind)} '${name}'${at}")
                    case Some(entry) => showOf(d, kind, name, entry, rest, at)
                }
        }

    def kindWord(kind: Kind): String = match kind {
        case Kind.Character => "人物"
        case Kind.Prop      => "小物"
    }

    /// 残りの語の頭が数なら秒（無ければ fallback・数でなければ Err）。
    def secondsOf(fallback: Float64, words: List[String], at: String): Result[String, Float64] = match words {
        case Nil       => Ok(fallback)
        case word :: _ => Float64.fromString(word) |> Option.map(s -> Float64.max(0.0, s)) |> Option.toOk("秒が数でない '${word}'${at}")
    }

    /// 名前の後ろの語を 1 つずつ読み、出す形にする。
    def showOf(d: CastDoc.Rec, kind: Kind, name: String, entry: CastDoc.Entry, words: List[String], at: String): Result[String, Cue] =
        let start = Ok(({ face = None, slot = None, seconds = d#fadeSeconds }: { face = Option[String], slot = Option[String], seconds = Float64 }));
        let read = words |> List.foldLeft((acc, word) -> acc |> Result.flatMap(got ->
            if (Map.memberOf(word, d#slots)) Ok({ slot = Some(word) | got })
            else if (List.memberOf(word, entry#faces)) Ok({ face = Some(word) | got })
            else Float64.fromString(word) |> Option.map(s -> { seconds = Float64.max(0.0, s) | got })
                     |> Option.toOk("知らない位置か表情 '${word}'（${name}）${at}")), start);
        read |> Result.map(got ->
            Cue.Show(kind, { name = name, face = Option.getWithDefault(entry#face, got#face), slot = Option.getWithDefault(entry#slot, got#slot) },
                     { face = Option.isEmpty(got#face), slot = Option.isEmpty(got#slot) }, got#seconds))

    // ── 層に反映する ──

    /// コマンド 1 つを層に反映する（now = 物語の時計の今）。そのついでに、消え終わった物と、重ね終わった前の形を落とす。
    pub def apply(now: Clock.Time[Stage.Story], cue: Cue, layer: Layer): Layer =
        let pruned = prune(now, layer);
        match cue {
            case Cue.Show(Kind.Character, figure, keep, seconds) => showCharacter(now, figure, keep, seconds, pruned)
            case Cue.Show(Kind.Prop, figure, keep, seconds)      => showProp(now, figure, keep, seconds, pruned)
            case Cue.Hide(Kind.Character, name, seconds)         => hideCharacters(now, name, seconds, pruned)
            case Cue.Hide(Kind.Prop, name, seconds)              => hideProp(now, name, seconds, pruned)
        }

    /// 省いた語を、出ている形（current）から埋めた形。
    pub def resolve(current: Option[Figure], figure: Figure, keep: Keep): Figure =
        let kept = (wanted, pick) -> if (wanted) current |> Option.map(pick) else None;
        { face = kept(keep#face, f -> f#face) |> Option.getWithDefault(figure#face),
          slot = kept(keep#slot, f -> f#slot) |> Option.getWithDefault(figure#slot) | figure }

    /// コマンドが出す形（出ている人がいればその形から埋める）。
    pub def targetOf(cue: Cue, layer: Layer): Option[(Kind, Figure)] = match cue {
        case Cue.Show(kind, figure, keep, _) => Some((kind, resolve(currentOf(kind, figure#name, layer), figure, keep)))
        case Cue.Hide(_, _, _)               => None
    }

    def currentOf(kind: Kind, name: String, layer: Layer): Option[Figure] = match kind {
        case Kind.Character => layer#cast |> List.find(s -> s#now#name == name) |> Option.map(s -> s#now)
        case Kind.Prop      => layer#prop |> Option.filter(s -> s#now#name == name) |> Option.map(s -> s#now)
    }

    pub def sameFigure(a: Figure, b: Figure): Bool = a#name == b#name and a#face == b#face and a#slot == b#slot

    def entering(now: Clock.Time[Stage.Story], figure: Figure, seconds: Float64): Shown =
        { now = figure, before = None, startedAt = now, seconds = seconds }

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
    /// 表情を替えている途中なら、下に敷いた形もその濃さから消す。秒が 0 ならその場で消すので残さない。
    def leave(kind: Kind, now: Clock.Time[Stage.Story], seconds: Float64, shown: Shown): List[Leaving] =
        let going = (under: Under) -> { kind = kind, figure = under#figure, alpha = under#alpha, startedAt = now, seconds = seconds };
        let top = { figure = shown#now, alpha = nowAlphaOf(now, shown) };
        if (seconds <= 0.0) Nil else List.map(going, (shown#before |> Option.toList) ::: (top :: Nil)) |> List.filter(l -> l#alpha > 0.0)

    /// 同じ位置で表情を替える: 見えている形を、見えている濃さのまま下に敷き、新しい形を上から重ねる
    /// （前の形を濃さ 1 で敷くと、出てくる途中に替えた時に急に濃くなる）。形が同じなら何もしない。
    def recast(now: Clock.Time[Stage.Story], figure: Figure, seconds: Float64, shown: Shown): Shown =
        if (sameFigure(shown#now, figure)) shown else { now = figure, before = Some(visibleOf(now, shown)), startedAt = now, seconds = seconds }

    def showCharacter(now: Clock.Time[Stage.Story], figure: Figure, keep: Keep, seconds: Float64, layer: Layer): Layer =
        let current = layer#cast |> List.find(s -> s#now#name == figure#name);
        let target = resolve(current |> Option.map(s -> s#now), figure, keep);
        if (current |> Option.exists(s -> s#now#slot == target#slot))
            { cast = layer#cast |> List.map(s -> if (s#now#name == target#name) recast(now, target, seconds, s) else s) | layer }
        else {
            let (out, kept) = List.partition(s -> s#now#name == target#name or s#now#slot == target#slot, layer#cast);
            { cast = List.append(kept, entering(now, target, seconds) :: Nil),
              leaving = List.append(layer#leaving, out |> List.flatMap(leave(Kind.Character, now, seconds))) | layer }
        }

    def showProp(now: Clock.Time[Stage.Story], figure: Figure, keep: Keep, seconds: Float64, layer: Layer): Layer =
        let current = layer#prop |> Option.filter(s -> s#now#name == figure#name);
        let target = resolve(current |> Option.map(s -> s#now), figure, keep);
        if (current |> Option.exists(s -> s#now#slot == target#slot))
            { prop = layer#prop |> Option.map(recast(now, target, seconds)) | layer }
        else
            { prop = Some(entering(now, target, seconds)),
              leaving = List.append(layer#leaving, layer#prop |> Option.toList |> List.flatMap(leave(Kind.Prop, now, seconds))) | layer }

    def hideCharacters(now: Clock.Time[Stage.Story], name: Option[String], seconds: Float64, layer: Layer): Layer =
        let (out, kept) = List.partition(s -> name |> Option.forAll(n -> s#now#name == n), layer#cast);
        { cast = kept, leaving = List.append(layer#leaving, out |> List.flatMap(leave(Kind.Character, now, seconds))) | layer }

    def hideProp(now: Clock.Time[Stage.Story], name: Option[String], seconds: Float64, layer: Layer): Layer =
        let (out, kept) = layer#prop |> Option.toList |> List.partition(s -> name |> Option.forAll(n -> s#now#name == n));
        { prop = List.head(kept), leaving = List.append(layer#leaving, out |> List.flatMap(leave(Kind.Prop, now, seconds))) | layer }

    /// 消え終わった物と、重ね終わった前の形を落とす。
    def prune(now: Clock.Time[Stage.Story], layer: Layer): Layer =
        let settledBefore = (s: Shown) -> if (progressOf(now, s#startedAt, s#seconds) >= 1.0) { before = None | s } else s;
        { cast = layer#cast |> List.map(settledBefore), prop = layer#prop |> Option.map(settledBefore),
          leaving = layer#leaving |> List.filter(l -> progressOf(now, l#startedAt, l#seconds) < 1.0) }

    /// 重ねの途中を終わりの形にする（セーブから戻った時・素材を待つ黒の間・描き出しで場面を作る時）。
    pub def settle(layer: Layer): Layer =
        let done = (s: Shown) -> { before = None, startedAt = Clock.never() | s };
        { cast = layer#cast |> List.map(done), prop = layer#prop |> Option.map(done), leaving = Nil }

    // ── セーブに残す形 ──

    pub def markOf(layer: Layer): Mark = { cast = layer#cast |> List.map(s -> s#now), prop = layer#prop |> Option.map(s -> s#now) }

    /// 残した形から、重ね終わった層を作る。
    pub def layerOf(mark: Mark): Layer =
        let shown = figure -> { now = figure, before = None, startedAt = Clock.never(), seconds = 0.0 };
        { cast = mark#cast |> List.map(shown), prop = mark#prop |> Option.map(shown), leaving = Nil }

    def figureToJson(f: Figure): Json =
        Json.JObject(Map#{ "name" => Json.JString(f#name), "face" => Json.JString(f#face), "slot" => Json.JString(f#slot) })

    def figureFrom(json: Json): Option[Figure] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { name = JsonCodec.stringOr("name", "", obj), face = JsonCodec.stringOr("face", "", obj), slot = JsonCodec.stringOr("slot", "", obj) })

    /// セーブの枠の "cast" に書く値。
    pub def markToJson(mark: Mark): Json =
        Json.JObject(Map#{ "characters" => JsonCodec.encodeList(figureToJson, mark#cast),
                           "prop" => mark#prop |> Option.map(figureToJson) |> Option.getWithDefault(Json.JNull) })

    /// セーブの枠の "cast" の値から読む。欄が無い・読めない古いセーブは空（fail-open）。
    pub def markFromJson(json: Option[Json]): Mark =
        let obj = json |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
        { cast = Map.get("characters", obj) |> Option.flatMap(JsonCodec.decodeList(figureFrom)) |> Option.getWithDefault(Nil),
          prop = Map.get("prop", obj) |> Option.flatMap(figureFrom) }

    // ── 使う絵の名前 ──

    pub def textureOf(figure: Figure): String = CastDoc.textureOf(figure#name, figure#face)

    /// 層に出ている物のテクスチャの名前（素材を待つ時に見る）。
    pub def textures(layer: Layer): List[String] =
        List.append(layer#cast |> List.map(s -> textureOf(s#now)), layer#prop |> Option.map(s -> textureOf(s#now)) |> Option.toList)

    // ── 重ねの進み ──

    /// 重ねの進み（0〜1。秒が 0 なら 1）。
    def progressOf(now: Clock.Time[Stage.Story], startedAt: Clock.Time[Stage.Story], seconds: Float64): Float64 =
        if (seconds <= 0.0) 1.0 else Float64.max(0.0, Float64.min(1.0, Clock.since(startedAt, now) / seconds))

    /// 進みを、出だしと終わりがゆっくりの濃さにする（0 → 0・1 → 1）。
    def easedOf(progress: Float64): Float64 = 0.5 + Curve.sine(0.5, Num.pi(), Num.pi() * -0.5, progress)

    /// 消えていく物の今の濃さ。
    def leavingAlphaOf(now: Clock.Time[Stage.Story], l: Leaving): Float64 = l#alpha * (1.0 - easedOf(progressOf(now, l#startedAt, l#seconds)))

    /// 人物がどれだけ出ているか（0〜1）: 見えている人物の濃さの最大。縦の頁の覆いを薄くする量に使う。
    pub def presenceOf(now: Clock.Time[Stage.Story], layer: Layer): Float64 =
        let shown = layer#cast |> List.map(s -> visibleOf(now, s)#alpha);
        let going = layer#leaving |> List.filter(l -> l#kind == Kind.Character) |> List.map(leavingAlphaOf(now));
        List.append(shown, going) |> List.foldLeft(Float64.max, 0.0)

    // ── 置き場所と描き方 ──

    /// 描く元: Doc・並べ方の組（画面の大きさと縦か横か）・2 本の時計の今・まだ届いていない絵の名前。
    pub type alias Env = {
        doc = CastDoc.Doc,
        fit = Layout.Fit,
        storyNow = Clock.Time[Stage.Story],
        realNow = Clock.Time[Clock.Real],
        missing = Set[String]
    }

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

    /// 透過画像を読む面（2 つの画素の間をなめらかにつないで読む。縁の透明な画素の色は art/cast/prepare.py が縁の色で埋めてある）。
    // WhyNot: Render.sprite で貼らない — 2D の絵は格子に乗せる前提で、縮めると画素を飛ばして読み、輪郭がぎざぎざになる。
    def pictureSpec(texture: String): ShaderDoc.Spec =
        let read = chan -> Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = Field.Tex({ name = texture, chan = chan }) });
        { name = "picture_${texture}", cycleRate = 0.0, bindings = Nil,
          out = Out.Fill({ shade = Shade.Rgb({ r = read(TexChan.R), g = read(TexChan.G), b = read(TexChan.B) }), alpha = read(TexChan.A) }) }

    /// 1 つの形を濃さ alpha で描く。知らない名前・位置・表情と、まだ届いていない絵は描かない。
    // WhyNot: Doc の faces に無い表情を貼りに行かない — 未登録のテクスチャは GL では黒（0 番）が貼られ、黒い四角が出る。
    /// 息の揺れは足元を据えたまま高さを僅かに伸び縮みさせる（上下に動かすと足元の下に隙間が覗く）。
    def figureItem(env: Env, kind: Kind, figure: Figure, alpha: Float64, z: Int32): List[Render.PlacedItem] =
        let texture = textureOf(figure);
        let found = placementOf(env, kind, figure) |> Option.map(snd);
        if (alpha <= 0.0 or Set.memberOf(texture, env#missing)) Nil
        else found |> Option.map(r -> {
            let size = Layout.size(env#fit);
            let breath = CastDoc.rec(env#doc)#sway * size#y * Sway.wave(Clock.secondsOf(env#realNow), r#position#x / Float64.max(1.0, size#x), 1.6);
            let grow = if (r#size#y <= 0.0) 0.0 else breath / r#size#y;
            let swayed = { position = { x = r#position#x - r#size#x * grow / 2.0, y = r#position#y - breath },
                           size = { x = r#size#x * (1.0 + grow), y = r#size#y + breath } };
            Render.shaderFill(pictureSpec(texture), swayed, 0.0, z) |> Render.overItem(Render.fade(alpha))
        }) |> Option.toList

    /// Doc の項目と置き場の矩形（知らない名前・位置・表情なら None）。
    def placementOf(env: Env, kind: Kind, figure: Figure): Option[(CastDoc.Entry, Rect2.Rect2)] =
        forM (entry <- CastDoc.entryOf(kind, figure#name, env#doc) |> Option.filter(e -> List.memberOf(figure#face, e#faces));
              slot <- Map.get(figure#slot, slotsOf(env)))
        yield (entry, rectOf(env#fit, slot, entry))

    /// 出ている人物と小物の置き場（消えていく物と、描かない物 = 知らない名前・まだ届いていない絵は除く）。label = Doc の人に見せる名前。
    pub def placedOf(env: Env, layer: Layer): List[{ kind = Kind, figure = Figure, label = String, rect = Rect2.Rect2 }] =
        let shown = List.append(layer#cast |> List.map(s -> (Kind.Character, s#now)), layer#prop |> Option.map(s -> (Kind.Prop, s#now)) |> Option.toList);
        shown |> List.filter(match (_, figure) -> not Set.memberOf(textureOf(figure), env#missing))
              |> List.filterMap(match (kind, figure) -> placementOf(env, kind, figure)
                     |> Option.map(match (entry, r) -> { kind = kind, figure = figure, label = entry#label, rect = r }))

    /// 出ている物 1 つ: 同じ位置で表情を替えている間は、前の形を敷いた時の濃さで下に残し、今の形を上から濃くする（途中で背景が透けない）。
    def shownItems(env: Env, kind: Kind, shown: Shown, z: Int32): List[Render.PlacedItem] =
        let a = nowAlphaOf(env#storyNow, shown);
        let under = shown#before |> Option.map(b -> figureItem(env, kind, b#figure, b#alpha, z)) |> Option.getWithDefault(Nil);
        List.append(under, figureItem(env, kind, shown#now, a, z))

    /// 層の全部を z に描く（消えていく物 → 人物 → 小物の順で、後ろほど手前）。
    pub def items(env: Env, layer: Layer, z: Int32): List[Render.PlacedItem] =
        let going = (kind: Kind) -> layer#leaving |> List.filter(l -> l#kind == kind) |> List.flatMap(l ->
            figureItem(env, kind, l#figure, leavingAlphaOf(env#storyNow, l), z));
        List.flatten(going(Kind.Character) :: (layer#cast |> List.flatMap(s -> shownItems(env, Kind.Character, s, z)))
                     :: going(Kind.Prop) :: (layer#prop |> Option.map(s -> shownItems(env, Kind.Prop, s, z)) |> Option.getWithDefault(Nil)) :: Nil)
}
