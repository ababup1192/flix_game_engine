// BackdropDoc — novel.backdrops.json（背景の写真と時間帯の色）の宣言ドキュメント層。
// シナリオの <<bg 写真 grade=時間帯 time=秒>> の「写真」と「時間帯」の名前はここの鍵。写真はどれも昼に撮った実写で、
// 夕暮れや夜は時間帯の色（Grade）でシェーダーが作る（同じ駅の写真が、夕方にも朝にもなる）。
// 色の作り方（ぼかし → 彩度 → 露出と色味 → 空の光 → 四隅を落とす）は Backdrop.specOf（コード）、数はここ。
// fail-open — 読めない欄は既定のまま・知らない写真や時間帯は Stage が知らせて前の背景のまま続ける。
mod BackdropDoc {
    use fge::{Color, Curve, DocJson, JsonCodec, Log}
    use Util.Json.Json

    /// 写真 1 枚。texture = project.json の textures の名前、label = セーブの枠に出す場所の名前、
    /// aspect = 絵の横÷縦（書いた写真は画面を覆うように比を保って真ん中で切り抜く。None は 16:9 の写真として画面に合わせて敷く）、
    /// blank = 絵を持たない写真（何も描かず地の色を見せる暗闇。texture は空でよい）。
    pub type alias Photo = { texture = String, label = String, aspect = Option[Float64], blank = Bool }

    /// 背景が無い間（最初の <<bg>> の前・セーブの背景が null の時）に描く背景。最初の <<bg>> はこの背景から重ねる。
    pub type alias Initial = { photo = String, grade = String }

    /// タイトルの背景の動き（写真と時間帯は novel.story.json の titlePhoto・titleGrade）。scale = 画面の真ん中を軸に広げる倍率、
    /// drift = 実時間 t 秒で x = sin(t × rate.x + phase.x) × amp.x（y も同じ）だけ漂う。
    pub type alias Title = { scale = Float64, drift = { amp = { x = Float64, y = Float64 }, rate = { x = Float64, y = Float64 }, phase = { x = Float64, y = Float64 } } }

    /// 時間帯の色。blur = ぼかしの半径（画面の幅に対する割合）、taps = ぼかしで読む点の数（1〜64）、
    /// saturation = 彩度（0 = 白黒・1 = 写真のまま）、exposure = 明るさの倍率、tint = 色ごとの倍率（夕方は赤を残し青を絞る）、
    /// lift = 暗い所に足す色（夜の青み・朝のかすみ）、sky = 画面の上から差す光の色、skyStrength = その強さ、
    /// skyReach = 光が届く深さ（画面の高さの割合）、vignette = 四隅を落とす強さ（0〜1）、
    /// focusPull = 切り替えの頭で余分にぼかす量（1 = 倍の半径から合わせる）、
    /// cast = 立ち絵と小物に掛ける色（無ければ掛けない。人の姿が写った一枚絵の時間帯は、人物も絵の一部なので書かない）。
    pub type alias Grade = {
        blur = Float64,
        taps = Int32,
        saturation = Float64,
        exposure = Float64,
        tint = Color,
        lift = Color,
        sky = Color,
        skyStrength = Float64,
        skyReach = Float64,
        vignette = Float64,
        focusPull = Float64,
        cast = Option[CastGrade]
    }

    /// 立ち絵と小物を背景になじませる色。tint = 色ごとの倍率、exposure = 明るさの倍率、saturation = 彩度（1 = 絵のまま）。
    pub type alias CastGrade = { tint = Color, exposure = Float64, saturation = Float64 }

    /// 背景の切り替えの種類（<<bg … transition=>>）。Fade = 前の写真の上に重ねる・Black = 短く暗転してから映る・Wipe = 左から塗り替える・
    /// Slide = 前の写真を左へ送り新しい写真を右から入れる・Pan = 横へ振ったように流れながら重ねる・Cut = すぐ替わる。
    pub enum Transition with Eq, ToString {
        case Fade
        case Black
        case Wipe
        case Slide
        case Pan
        case Cut
    }

    /// <<bg … transition=>> に書ける名前。
    pub def transitionNames(): List[String] = "fade" :: "black" :: "wipe" :: "slide" :: "pan" :: "cut" :: Nil

    /// 名前の切り替えの種類（知らない名前は None）。
    pub def transitionOf(name: String): Option[Transition] = match name {
        case "fade"  => Some(Transition.Fade)
        case "black" => Some(Transition.Black)
        case "wipe"  => Some(Transition.Wipe)
        case "slide" => Some(Transition.Slide)
        case "pan"   => Some(Transition.Pan)
        case "cut"   => Some(Transition.Cut)
        case _       => None
    }

    /// transition=black の暗転の形。fadeOut = 暗くなる間・hold = 暗いまま止まる間・fadeIn = 明ける間の、<<bg … time=>> の秒に対する割合
    /// （足して 1 でなくてよく、比で分ける）。<<bg … transition=black>> の形。
    pub type alias Blackout = { fadeOut = Float64, hold = Float64, fadeIn = Float64 }

    /// 曲線の名前（Curve.easeTable の名前）の曲線。Doc の曲線の欄（defaultEase・novel.cast.json の fadeEase）と <<…ease=>> が引く。知らない名前は None。
    pub def easeOf(name: String): Option[Curve.Ease] = Curve.easeTable() |> List.find(e -> fst(e) == name) |> Option.map(snd)

    /// 曲線の名前の欄 key（無ければ黙って fallback・知らない名前なら 1 行言って fallback）。docName = 知らせに出す Doc の名前。
    pub def easeIn(docName: String, key: String, fallback: Curve.Ease, obj: Map[String, Json]): Curve.Ease =
        match Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString) |> Option.map(name -> (name, easeOf(name))) {
            case None                => fallback
            case Some((_, Some(e)))  => e
            case Some((name, None))  => Log.fellBackThen("docs", "${docName} の ${key}", ToString.toString(fallback), "知らない曲線の名前 '${name}'（Curve.easeTable の名前）", fallback)
        }

    /// 暗転の形の既定（半分で暗くなりきり、止まらずに明ける）。
    pub def defaultBlackout(): Blackout = { fadeOut = 0.5, hold = 0.0, fadeIn = 0.5 }

    /// 暗転の進み p（0〜1）での暗さ（0 = 見える・1 = 真っ暗）。
    pub def blackoutDarknessOf(b: Blackout, p: Float64): Float64 =
        let total = b#fadeOut + b#hold + b#fadeIn;
        let out = if (total <= 0.0) 0.5 else b#fadeOut / total;
        let held = if (total <= 0.0) 0.0 else b#hold / total;
        if (p < out) p / out
        else if (p < out + held) 1.0
        else if (b#fadeIn <= 0.0) 1.0
        else (1.0 - p) / (1.0 - out - held)

    /// 暗転の進みのどこで写真を替えるか（暗いまま止まる間の真ん中）。
    pub def blackoutSwapAt(b: Blackout): Float64 =
        let total = b#fadeOut + b#hold + b#fadeIn;
        if (total <= 0.0) 0.5 else (b#fadeOut + b#hold * 0.5) / total

    /// defaultTransition = transition= を省いた <<bg>> の切り替え、defaultSeconds / defaultEase = time= / ease= を省いた <<bg>> の秒と進みの曲線、
    /// black = transition=black の暗転の形、initial = 背景が無い間の背景、title = タイトルの背景の動き（無ければ動かさない）、
    /// ground = 写真の下に敷く地の色（blank の写真・black の暗転で見える色。無ければ Backdrop.groundColor）。
    pub type alias Rec = {
        version = Int32,
        defaultTransition = Transition,
        defaultSeconds = Float64,
        defaultEase = Curve.Ease,
        black = Blackout,
        photos = Map[String, Photo],
        grades = Map[String, Grade],
        initial = Option[Initial],
        title = Option[Title],
        ground = Option[Color]
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.backdrops.json"

    /// 写真も時間帯も無い既定（Doc が読めない時は背景を出さず、地の色の上で読む）。
    pub def defaults(): Doc = Doc.Doc({ version = 1, defaultTransition = Transition.Fade, defaultSeconds = 1.0, defaultEase = Curve.Ease.Linear, black = defaultBlackout(), photos = Map.empty(), grades = Map.empty(), initial = None, title = None, ground = None })

    /// 時間帯の欄の既定（欄が欠けた時に使う。写真のまま薄くぼかした色）。
    pub def plainGrade(): Grade =
        { blur = 0.006, taps = 24, saturation = 1.0, exposure = 1.0,
          tint = { r = 1.0, g = 1.0, b = 1.0 }, lift = { r = 0.0, g = 0.0, b = 0.0 },
          sky = { r = 1.0, g = 1.0, b = 1.0 }, skyStrength = 0.0, skyReach = 0.5, vignette = 0.3, focusPull = 0.6, cast = None }

    pub def photoOf(name: String, doc: Doc): Option[Photo] = Map.get(name, rec(doc)#photos)

    /// 写真の名前 → project.json の textures の名前（知らない写真なら None）。
    /// 絵を持たない写真（blank）は None（待つ絵も、描き出しで読む絵も無い）。
    pub def textureOf(name: String, doc: Doc): Option[String] = photoOf(name, doc) |> Option.filter(photo -> not photo#blank) |> Option.map(photo -> photo#texture)

    /// 写真が絵を持たない（blank）か。
    pub def isBlank(name: String, doc: Doc): Bool = photoOf(name, doc) |> Option.exists(photo -> photo#blank)

    pub def gradeOf(name: String, doc: Doc): Option[Grade] = Map.get(name, rec(doc)#grades)

    /// 写真の横÷縦（書いていない・知らない写真は None）。
    pub def aspectOf(name: String, doc: Doc): Option[Float64] = photoOf(name, doc) |> Option.flatMap(photo -> photo#aspect)

    /// 背景が無い間の背景（無ければ None）。
    pub def initialOf(doc: Doc): Option[Initial] = rec(doc)#initial

    /// タイトルの背景の動き（無ければ None）。
    pub def titleOf(doc: Doc): Option[Title] = rec(doc)#title

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        Doc.Doc({ version = JsonCodec.intOr("version", 1, root),
                  defaultTransition = transitionOf(JsonCodec.stringOr("defaultTransition", "fade", root)) |> Option.getWithDefault(Transition.Fade),
                  defaultSeconds = Float64.max(0.0, JsonCodec.floatOr("defaultSeconds", rec(defaults())#defaultSeconds, root)),
                  defaultEase = easeIn(path(), "defaultEase", rec(defaults())#defaultEase, root),
                  black = blackoutFrom(Map.get("black", root)),
                  photos = Map.get("photos", root) |> Option.flatMap(JsonCodec.decodeStringMap(photoFromJson))
                      |> Option.getWithDefault(Map.empty()),
                  grades = Map.get("grades", root) |> Option.flatMap(JsonCodec.decodeStringMap(gradeFromJson))
                      |> Option.getWithDefault(Map.empty()),
                  initial = Map.get("initial", root) |> Option.flatMap(initialFromJson),
                  title = Map.get("title", root) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(titleFromJson),
                  ground = groundIn(root) })

    /// "black": { "fadeOut", "hold", "fadeIn" } を読む（欠けた欄は既定の形の値）。
    def blackoutFrom(json: Option[Json]): Blackout =
        let d = defaultBlackout();
        json |> Option.flatMap(JsonCodec.expectObject)
             |> Option.map(obj -> { fadeOut = Float64.max(0.0, JsonCodec.floatOr("fadeOut", d#fadeOut, obj)), hold = Float64.max(0.0, JsonCodec.floatOr("hold", d#hold, obj)),
                                    fadeIn = Float64.max(0.0, JsonCodec.floatOr("fadeIn", d#fadeIn, obj)) })
             |> Option.getWithDefault(d)

    /// ground の欄（無ければ None。書いてあるのに #rrggbb として読めなければ 1 行言って None = 夜の紺）。
    def groundIn(root: Map[String, Json]): Option[Color] = Map.get("ground", root) |> Option.flatMap(groundOf)

    def groundOf(json: Json): Option[Color] = match JsonCodec.expectString(json) |> Option.flatMap(Color.hex) {
        case Some(color) => Some(color)
        case None        => Log.fellBackThen("backdrops", "${path()} の ground", "夜の紺", "#rrggbb の色として読めない", None)
    }

    /// initial の欄（photo と grade のどちらかが欠けたら無い物とする）。
    def initialFromJson(json: Json): Option[Initial] =
        JsonCodec.expectObject(json) |> Option.flatMap(obj ->
            forM (photo <- Map.get("photo", obj) |> Option.flatMap(JsonCodec.expectString);
                  grade <- Map.get("grade", obj) |> Option.flatMap(JsonCodec.expectString)) yield { photo = photo, grade = grade })

    /// title の欄（欠けた欄は動かない値 = 倍率 1・幅 0）。
    def titleFromJson(obj: Map[String, Json]): Title =
        let drift = Map.get("drift", obj) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
        let pair = key -> Map.get(key, drift) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat))
            |> Option.flatMap(xs -> match xs {
                   case x :: y :: Nil => Some({ x = x, y = y })
                   case _             => None
               }) |> Option.getWithDefault({ x = 0.0, y = 0.0 });
        { scale = JsonCodec.floatOr("scale", 1.0, obj), drift = { amp = pair("amp"), rate = pair("rate"), phase = pair("phase") } }

    def photoFromJson(json: Json): Option[Photo] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { texture = JsonCodec.stringOr("texture", "", obj), label = JsonCodec.stringOr("label", "", obj),
              aspect = Map.get("aspect", obj) |> Option.flatMap(JsonCodec.expectFloat) |> Option.filter(a -> a > 0.0),
              blank = JsonCodec.boolOr("blank", false, obj) })

    def gradeFromJson(json: Json): Option[Grade] =
        JsonCodec.expectObject(json) |> Option.map(obj -> {
            let d = plainGrade();
            let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, obj);
            let color = (key, fallback) -> Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString)
                |> Option.flatMap(Color.hex) |> Option.getWithDefault(fallback);
            let gains = (key, fallback: Color) -> Map.get(key, obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat))
                |> Option.flatMap(xs -> match xs {
                       case r :: g :: b :: Nil => Some({ r = r, g = g, b = b })
                       case _                  => None
                   }) |> Option.getWithDefault(fallback);
            { blur = num("blur", d#blur), taps = JsonCodec.intOr("taps", d#taps, obj),
              saturation = num("saturation", d#saturation), exposure = num("exposure", d#exposure),
              tint = gains("tint", d#tint), lift = gains("lift", d#lift),
              sky = color("sky", d#sky), skyStrength = num("skyStrength", d#skyStrength),
              skyReach = num("skyReach", d#skyReach), vignette = num("vignette", d#vignette),
              focusPull = num("focusPull", d#focusPull),
              cast = Map.get("cast", obj) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(castGradeOf) }
        })

    /// 時間帯の cast の欄（欠けた欄は絵のまま = 倍率 1）。
    def castGradeOf(obj: Map[String, Json]): CastGrade =
        let gains = Map.get("tint", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat))
            |> Option.flatMap(xs -> match xs {
                   case r :: g :: b :: Nil => Some({ r = r, g = g, b = b })
                   case _                  => None
               }) |> Option.getWithDefault({ r = 1.0, g = 1.0, b = 1.0 });
        { tint = gains, exposure = JsonCodec.floatOr("exposure", 1.0, obj), saturation = JsonCodec.floatOr("saturation", 1.0, obj) }

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
