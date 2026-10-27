// BackdropDoc — novel.backdrops.json（背景の写真と時間帯の色）の宣言ドキュメント層。
// シナリオの <<bg 写真 時間帯 秒>> の「写真」と「時間帯」の名前はここの鍵。写真はどれも昼に撮った実写で、
// 夕暮れや夜は時間帯の色（Grade）でシェーダーが作る（同じ駅の写真が、夕方にも朝にもなる）。
// 色の作り方（ぼかし → 彩度 → 露出と色味 → 空の光 → 四隅を落とす）は Backdrop.specOf（コード）、数はここ。
// fail-open — 読めない欄は既定のまま・知らない写真や時間帯は Stage が知らせて前の背景のまま続ける。
mod BackdropDoc {
    use fge::{Color, DocJson, JsonCodec}
    use Util.Json.Json

    /// 写真 1 枚。texture = project.json の textures の名前、label = セーブの栞に出す場所の名前。
    pub type alias Photo = { texture = String, label = String }

    /// 時間帯の色。blur = ぼかしの半径（画面の幅に対する割合）、taps = ぼかしで読む点の数（1〜64）、
    /// saturation = 彩度（0 = 白黒・1 = 写真のまま）、exposure = 明るさの倍率、tint = 色ごとの倍率（夕方は赤を残し青を絞る）、
    /// lift = 暗い所に足す色（夜の青み・朝のかすみ）、sky = 画面の上から差す光の色、skyStrength = その強さ、
    /// skyReach = 光が届く深さ（画面の高さの割合）、vignette = 四隅を落とす強さ（0〜1）、
    /// focusPull = 切り替えの頭で余分にぼかす量（1 = 倍の半径から合わせる）。
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
        focusPull = Float64
    }

    pub type alias Rec = {
        version = Int32,
        photos = Map[String, Photo],
        grades = Map[String, Grade]
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.backdrops.json"

    /// 写真も時間帯も無い既定（Doc が読めない時は背景を出さず、地の色の上で読む）。
    pub def defaults(): Doc = Doc.Doc({ version = 1, photos = Map.empty(), grades = Map.empty() })

    /// 時間帯の欄の既定（欄が欠けた時に使う。写真のまま薄くぼかした色）。
    pub def plainGrade(): Grade =
        { blur = 0.006, taps = 24, saturation = 1.0, exposure = 1.0,
          tint = { r = 1.0, g = 1.0, b = 1.0 }, lift = { r = 0.0, g = 0.0, b = 0.0 },
          sky = { r = 1.0, g = 1.0, b = 1.0 }, skyStrength = 0.0, skyReach = 0.5, vignette = 0.3, focusPull = 0.6 }

    pub def photoOf(name: String, doc: Doc): Option[Photo] = Map.get(name, rec(doc)#photos)

    pub def gradeOf(name: String, doc: Doc): Option[Grade] = Map.get(name, rec(doc)#grades)

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        Doc.Doc({ version = JsonCodec.intOr("version", 1, root),
                  photos = Map.get("photos", root) |> Option.flatMap(JsonCodec.decodeStringMap(photoFromJson))
                      |> Option.getWithDefault(Map.empty()),
                  grades = Map.get("grades", root) |> Option.flatMap(JsonCodec.decodeStringMap(gradeFromJson))
                      |> Option.getWithDefault(Map.empty()) })

    def photoFromJson(json: Json): Option[Photo] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { texture = JsonCodec.stringOr("texture", "", obj), label = JsonCodec.stringOr("label", "", obj) })

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
              focusPull = num("focusPull", d#focusPull) }
        })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
