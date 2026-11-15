// Stage — 舞台（背景・文章の出し方・名前の付いた値・立ち絵と小物）の状態（純粋）。
// シナリオのコマンドの読み方と、コマンドが舞台をどう変えるかは Commands の表に書く。
// 時間で動く値や名前で替わる値（環境音・パーティクル・揺れ・ゲームが足す game. の値）は props（PropertyTween）に入れる。
// 背景（前の写真を下に敷いて重ねる）と立ち絵（出入りと表情の重ね）は値 1 つで表せないので、自分の形と settle を持つ。
// セーブ・バックログ・「戻る」が持つのは settle した舞台（Snapshot）。
mod Stage {
    use fge::{Clock, JsonCodec, Log, Num}
    use Util.Json.Json

    /// 物語の時計の名前（中身は要らない）。文字送り・<<wait>>・背景の重ね・揺れが使い、画面や確認のウィンドウを開くと止まる。
    pub enum Story

    /// 文章の出し方。Nvl = 画面いっぱいに積む（小説の頁）、Adv = 下のウィンドウに 1 行ずつ。
    pub enum Mode with Eq, ToString {
        case Nvl
        case Adv
    }

    /// 背景 1 枚（写真と時間帯の名前）。
    pub type alias Shot = { photo = String, grade = String }

    /// 舞台。shot = 今の背景、under = 重ねている間だけ下に残す前の背景、fadeFrom / fadeSeconds = 重ね始めた時刻と長さ、
    /// mode = 文章の出し方、pages = 頁をめくった数（WorldRead が <<window clear>>・型の切り替え・NVL で入り切らない時に足す）、
    /// props = 名前の付いた値（ambienceKey・particlesKey・shakeKeyOf・overlay*Key・cameraKey・windowHiddenKey・actorKey と game. の値）、cast = 立ち絵と小物の層。
    pub type alias Stage = {
        shot = Option[Shot],
        under = Option[Shot],
        fadeFrom = Clock.Time[Story],
        fadeSeconds = Float64,
        mode = Mode,
        pages = Int32,
        props = PropertyTween.Table[Story],
        cast = Cast.Layer
    }

    /// 物語を始める前の舞台（背景なし・NVL・音なし）。
    pub def empty(): Stage =
        { shot = None, under = None, fadeFrom = Clock.never(), fadeSeconds = 0.0, mode = Mode.Nvl, pages = 0,
          props = PropertyTween.empty(), cast = Cast.empty() }

    /// 鳴り続ける環境音（project.json の sounds の名前）。
    pub def ambienceKey(): PropertyTween.NameKey = PropertyTween.nameKey("audio.ambience")

    /// 画面のパーティクルの演出の名前（particleNames のどれか）。
    pub def particlesKey(): PropertyTween.NameKey = PropertyTween.nameKey("fx.particles")

    /// 揺らす相手。Screen = world の層（背景・絵・粒・GameView）、Window = 文字の枠と字、Actor(名前) = 名前付きの絵 1 つ。
    pub enum ShakeTarget with Eq {
        case Screen
        case Window
        case Actor(String)
    }

    def shakePrefixOf(target: ShakeTarget): String = match target {
        case ShakeTarget.Screen    => "camera"
        case ShakeTarget.Window    => "window"
        case ShakeTarget.Actor(n)  => "actor.${n}"
    }

    /// 揺れの始まりと長さ（camera.shake・window.shake・actor.<名>.shake）。
    pub def shakeKeyOf(target: ShakeTarget): PropertyTween.TriggerKey = PropertyTween.triggerKey("${shakePrefixOf(target)}.shake")

    /// 揺れ幅（px。camera.shakeAmp・window.shakeAmp・actor.<名>.shakeAmp）。
    pub def shakeAmpKeyOf(target: ShakeTarget): PropertyTween.NumKey = PropertyTween.numKey("${shakePrefixOf(target)}.shakeAmp")

    /// 画面の揺れ。
    pub def shakeKey(): PropertyTween.TriggerKey = shakeKeyOf(ShakeTarget.Screen)

    /// target を now から seconds 秒、幅 px で揺らす。
    pub def withShake(now: Clock.Time[Story], target: ShakeTarget, shake: KindDoc.Shake, stage: Stage): Stage =
        let props = PropertyTween.setNum(shakeAmpKeyOf(target), shake#px, now, 0.0, stage#props);
        { props = PropertyTween.trigger(shakeKeyOf(target), now, 0.0, shake#seconds, props) | stage }

    /// 覆いの濃さ（0〜1）。
    pub def overlayAlphaKey(): PropertyTween.NumKey = PropertyTween.numKey("overlay.alpha")

    /// 覆いの色（black・white・#rrggbb）。
    pub def overlayColorKey(): PropertyTween.NameKey = PropertyTween.nameKey("overlay.color")

    /// 覆いの置き場（stage = world の層の中・screen = 文字の枠より手前）。
    pub def overlayLayerKey(): PropertyTween.NameKey = PropertyTween.nameKey("overlay.layer")

    /// カメラ（world の層だけに掛かる）の数の値。Zoom = 画面の真ん中を軸に掛ける倍率、X / Y = 見る所のずれ（画面の幅と高さに対する割合）。
    pub enum CameraField with Eq, Order {
        case Zoom
        case X
        case Y
    }

    /// カメラの field の鍵（camera.zoom・.x・.y）。
    pub def cameraKey(field: CameraField): PropertyTween.NumKey = match field {
        case CameraField.Zoom => PropertyTween.numKey("camera.zoom")
        case CameraField.X    => PropertyTween.numKey("camera.x")
        case CameraField.Y    => PropertyTween.numKey("camera.y")
    }

    /// カメラの field の既定（寄らない・ずらさない）。
    pub def cameraDefaultOf(field: CameraField): Float64 = match field {
        case CameraField.Zoom => 1.0
        case _                => 0.0
    }

    /// now のカメラの field の値。
    pub def cameraAt(now: Clock.Time[Story], field: CameraField, stage: Stage): Float64 =
        PropertyTween.numAt(now, cameraKey(field), cameraDefaultOf(field), stage#props)

    /// 文字の枠と字を消しているか（1 = 消す・0 = 出す）。<<window off>> が 1 にし、<<window nvl|bottom>> と次の台詞・選択肢が 0 に戻す。
    pub def windowHiddenKey(): PropertyTween.NumKey = PropertyTween.numKey("window.hidden")

    /// 名前付きの絵（立ち絵・小物）1 つの数の値。X / Y = 置き場所からのずれ（画面の幅と高さに対する割合）、Scale = 足元を据えて掛ける倍率、
    /// Alpha = 濃さに掛ける倍率、Rotate = 真ん中を軸に時計回りに傾ける角度（度）。
    pub enum ActorField with Eq, Order, ToString {
        case X
        case Y
        case Scale
        case Alpha
        case Rotate
    }

    /// 全部の ActorField。
    pub def actorFields(): List[ActorField] = ActorField.X :: ActorField.Y :: ActorField.Scale :: ActorField.Alpha :: ActorField.Rotate :: Nil

    /// 名前付きの絵 name の field の鍵（actor.<名>.x・.y・.scale・.alpha・.rotate）。
    pub def actorKey(name: String, field: ActorField): PropertyTween.NumKey =
        let suffix = match field {
            case ActorField.X      => "x"
            case ActorField.Y      => "y"
            case ActorField.Scale  => "scale"
            case ActorField.Alpha  => "alpha"
            case ActorField.Rotate => "rotate"
        };
        PropertyTween.numKey("actor.${name}.${suffix}")

    /// field の既定の値（ずらさない形）。
    pub def actorDefaultOf(field: ActorField): Float64 = match field {
        case ActorField.Scale => 1.0
        case ActorField.Alpha => 1.0
        case _                => 0.0
    }

    /// name の field の、予定が全部済んだ後の値（書いていなければ既定）。
    pub def actorEnd(name: String, field: ActorField, stage: Stage): Float64 =
        PropertyTween.numEnd(actorKey(name, field), actorDefaultOf(field), stage#props)

    /// name の数の値を now から全部既定へ戻す（出ていない絵を出し直す時。前に出した時の <<move>> を持ち越さない）。
    pub def withActorReset(now: Clock.Time[Story], name: String, stage: Stage): Stage =
        { props = actorFields() |> List.foldLeft((t, f) -> PropertyTween.setNum(actorKey(name, f), actorDefaultOf(f), now, 0.0, t), stage#props) | stage }

    /// name の now のずれ（Cast が描く時に読む）。
    pub def actorTransformAt(now: Clock.Time[Story], name: String, props: PropertyTween.Table[Story]): Cast.Transform =
        let at = f -> PropertyTween.numAt(now, actorKey(name, f), actorDefaultOf(f), props);
        let (jx, jy) = shakeOffsetIn(now, ShakeTarget.Actor(name), props);
        { dx = at(ActorField.X), dy = at(ActorField.Y), scale = at(ActorField.Scale), alpha = at(ActorField.Alpha), degrees = at(ActorField.Rotate),
          jitter = { x = jx, y = jy } }

    /// パーティクルの演出の名前（<<fx 名>> に書ける物）。
    pub def particleNames(): List[String] = "fireflies" :: "snow" :: Nil

    /// 背景を shot に替え、seconds かけて前の背景の上に重ねる。
    pub def withBackdrop(now: Clock.Time[Story], shot: Shot, seconds: Float64, stage: Stage): Stage =
        { shot = Some(shot), under = stage#shot, fadeFrom = now, fadeSeconds = Float64.max(0.0, seconds) | stage }

    /// 環境音を now から替える（None で止める）。
    pub def withAmbience(now: Clock.Time[Story], sound: Option[String], stage: Stage): Stage =
        { props = PropertyTween.setName(ambienceKey(), sound, now, 0.0, stage#props) | stage }

    /// パーティクルの演出を now から替える（None で止める）。
    pub def withParticles(now: Clock.Time[Story], name: Option[String], stage: Stage): Stage =
        { props = PropertyTween.setName(particlesKey(), name, now, 0.0, stage#props) | stage }

    /// 文字の枠と字を now から消す・出す。
    pub def withWindowHidden(now: Clock.Time[Story], hidden: Bool, stage: Stage): Stage =
        { props = PropertyTween.setNum(windowHiddenKey(), if (hidden) 1.0 else 0.0, now, 0.0, stage#props) | stage }

    /// 文字の枠と字を消していれば now から出す（消していなければ舞台はそのまま）。
    // WhyNot: 消したまま台詞を出さない — 字の見えない台詞は、押せば進むのに何も読めない画面になる（Ren'Py の window hide も次の台詞で戻る）。
    pub def withWindowShown(now: Clock.Time[Story], stage: Stage): Stage =
        if (PropertyTween.numEnd(windowHiddenKey(), 0.0, stage#props) > 0.0) withWindowHidden(now, false, stage) else stage

    /// now に文字の枠と字を消しているか。
    pub def isWindowHidden(now: Clock.Time[Story], stage: Stage): Bool = PropertyTween.numAt(now, windowHiddenKey(), 0.0, stage#props) >= 1.0

    /// 頁を 1 つめくった数を足す。
    pub def withPageTurned(stage: Stage): Stage = { pages = stage#pages + 1 | stage }

    /// now に鳴っている環境音。
    pub def ambienceOf(now: Clock.Time[Story], stage: Stage): Option[String] = PropertyTween.nameAt(now, ambienceKey(), stage#props)

    /// now のパーティクルの演出。
    pub def particlesOf(now: Clock.Time[Story], stage: Stage): Option[String] = PropertyTween.nameAt(now, particlesKey(), stage#props)

    /// now のパーティクルの演出に替わってからの秒（一度も替えていなければ None）。
    pub def particlesSince(now: Clock.Time[Story], stage: Stage): Option[Float64] = PropertyTween.nameSince(now, particlesKey(), stage#props)

    /// 演出の途中を終わりの形にする（セーブから戻った時・描き出しで場面を作る時）。
    pub def settle(stage: Stage): Stage =
        { under = None, fadeFrom = Clock.never(), props = PropertyTween.settle(stage#props), cast = Cast.settle(stage#cast) | stage }

    /// 背景の重ねの進み（0〜1。秒が 0 なら 1）。
    pub def fadeProgress(now: Clock.Time[Story], stage: Stage): Float64 =
        if (stage#fadeSeconds <= 0.0) 1.0
        else Float64.max(0.0, Float64.min(1.0, Clock.since(stage#fadeFrom, now) / stage#fadeSeconds))

    /// target の now の揺れのずれ（px）。だんだん収まる。
    pub def shakeOffset(now: Clock.Time[Story], target: ShakeTarget, stage: Stage): (Float64, Float64) = shakeOffsetIn(now, target, stage#props)

    def shakeOffsetIn(now: Clock.Time[Story], target: ShakeTarget, props: PropertyTween.Table[Story]): (Float64, Float64) =
        match PropertyTween.triggerSpanAt(now, shakeKeyOf(target), props) {
            case Some((t, seconds)) if seconds > 0.0 =>
                let px = PropertyTween.numAt(now, shakeAmpKeyOf(target), 0.0, props);
                let left = 1.0 - t / seconds;
                (Num.sin(t * 71.0) * px * left, Num.cos(t * 53.0) * px * 0.5 * left)
            case _ => (0.0, 0.0)
        }

    // ── 残す形（Snapshot） ──

    enum SnapshotOf(Stage)

    /// settle した舞台。セーブ・バックログ・「戻る」が持ち、戻した後の舞台をこれで置き換える（途中の動きは持たない）。
    pub type alias Snapshot = SnapshotOf

    pub def snapshotOf(stage: Stage): Snapshot = SnapshotOf.SnapshotOf(settle(stage))

    pub def fromSnapshot(snapshot: Snapshot): Stage = let SnapshotOf.SnapshotOf(stage) = snapshot; stage

    /// セーブの枠の "stage" に書く値: { "bg": { "photo", "grade" } か null, "mode", "pages", "props", "cast" }。
    pub def snapshotToJson(snapshot: Snapshot): Json =
        let stage = fromSnapshot(snapshot);
        let bg = stage#shot |> Option.map(shot -> Json.JObject(Map#{ "photo" => Json.JString(shot#photo), "grade" => Json.JString(shot#grade) }))
            |> Option.getWithDefault(Json.JNull);
        Json.JObject(Map#{ "bg" => bg, "mode" => Json.JString("${stage#mode}"), "pages" => Json.JNumber(JsonCodec.intToBd(stage#pages)),
                           "props" => PropertyTween.toJson(stage#props), "cast" => Cast.markToJson(Cast.markOf(stage#cast)) })

    /// snapshotToJson の形から。読めない欄はその欄の既定（背景なし・NVL・0 頁・値なし・立ち絵なし）で続ける。
    pub def snapshotFromJson(json: Json): Snapshot =
        let obj = JsonCodec.expectObject(json) |> Option.getWithDefault(Map.empty());
        let shot = Map.get("bg", obj) |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(bg ->
            forM (photo <- Map.get("photo", bg) |> Option.flatMap(JsonCodec.expectString);
                  grade <- Map.get("grade", bg) |> Option.flatMap(JsonCodec.expectString)) yield { photo = photo, grade = grade });
        let props = match Map.get("props", obj) |> Option.map(PropertyTween.fromJson) {
            case None          => PropertyTween.empty()
            case Some(Ok(t))   => t
            case Some(Err(why)) => Log.warnThen("[saves] 舞台の値が読めないので値なしで戻す (${why})", PropertyTween.empty())
        };
        makeSnapshot(shot, modeOfText(JsonCodec.stringOr("mode", "", obj)), JsonCodec.intOr("pages", 0, obj), props,
                     Cast.markFromJson(Map.get("cast", obj)))

    /// 残した値から、settle した舞台を組む（セーブの JSON を読む所）。
    pub def makeSnapshot(shot: Option[Shot], mode: Mode, pages: Int32, props: PropertyTween.Table[Story], cast: Cast.Mark): Snapshot =
        snapshotOf({ shot = shot, mode = mode, pages = pages, props = props, cast = Cast.layerOf(cast) | empty() })

    /// セーブに書いた文章の出し方の字（"Adv" のほかは Nvl）。
    pub def modeOfText(text: String): Mode = if (text == "${Mode.Adv}") Mode.Adv else Mode.Nvl
}
