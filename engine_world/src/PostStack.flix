// PostStack — 画面全体の後がけ（奥行きのぼかし・ブルーム・色の仕上げ・ビネット・露出・トーンマップ・FXAA）を値の束 1 つで言う口
// （Unity の Post-processing Stack・Godot の Environment・Bevy の camera の Bloom / Tonemapping と同じ役目）。
// ゲームは「どの効果をどの値で」を言い、順・Pass・描き先の大きさと形式・Spec はここが決める。中身は Render.Pass と ShaderDoc の面に展開する純粋な関数で、
// 描き手（GL・WebGPU・CPU）は触らない。式の部品（トーンマップの曲線・FXAA・luma）が要る時だけ PostProcess を使う。
//
// 掛かる順（Blender の Color Management の順）: 奥行きのぼかし → ブルーム → 色の仕上げ → ビネット → 露出 → view transform → FXAA。
// 掛ける範囲は View が返す絵の全部（App.withPostStack）。HUD（App.withHudView）とデバッグの重ねには掛からない —
// トーンマップもぼかしも掛けたくない UI（会話の窓・メニュー・字幕）は HUD に置く。
//
// 使い方: `App.withPostStack(w -> PostStack.preset(PostStack.Preset.DuskOutdoor) |> PostStack.withExposure(-0.3))`。
// Doc から読むなら `PostStack.loadOr(PostStack.preset(PostStack.Preset.Neutral), "assets/post.json")`（schema は engine の docs/post.schema.json）。
// App を通さない描き方（自前の Pass の並び・描き出し）は build が計画と画面へ置く面を返す。
pub mod PostStack {

    use Util.Json.JsonError

    // ── 効果ごとの欄 ──

    /// ブルーム（明るい所をにじませて足す）。threshold = にじみ始める明るさ（1 を超える所が光る所）・smoothness = threshold から
    /// にじみ切るまでの幅・size = にじみの半径（画面の高さを 1 とした長さ）・strength = 足す強さ。
    pub type alias Bloom = { threshold = Float64, smoothness = Float64, size = Float64, strength = Float64 }

    /// 画面の縁を暗くする。画面の真ん中 center（0..1）から inner〜outer の距離（縦横比を直し、高さ = 1）で、1 から 1 − strength へ落ちる。
    pub type alias Vignette = { strength = Float64, inner = Float64, outer = Float64, center = Vec2.Vec2 }

    /// 色の仕上げ（Blender の compositor の Color Balance（Lift / Gamma / Gain）と Hue/Saturation/Value の Saturation）。
    /// どれも 1 が「何もしない」。lift は暗い所・gamma は中間・gain は明るい所を色ごとに持ち上げる。saturation は掛け算（0 = 灰色）。
    pub type alias ColorGrade = { lift = Color, gamma = Color, gain = Color, saturation = Float64 }

    /// 曲線（View Transform）。名前と曲線は Blender の Color Management に合わせる（Standard は曲線なし）。
    /// AcesNarkowicz は今までのゲームの見え方との互換（Narkowicz 2015 の ACES の近似を whitePoint で 1 にそろえ、曲線の後に
    /// 0..1 の色の彩度を saturationAfter だけ足す。0 = そのまま）。
    pub enum ViewTransform {
        case Standard
        case AcesNarkowicz({ whitePoint = Float64, saturationAfter = Float64 })
    }

    /// 奥行きのぼかし。ぼかしに使う奥行きの絵は、View が返す絵の中の 3D の場面から PostStack が作る（ゲームが場面を 2 回組まない）。
    /// Physical = カメラのぼけ（Blender の Camera → Depth of Field。focusDistance は m・fStop は F 値・センサーの高さ 24 mm・
    /// 長さの単位は Scene3d.withUnitsPerMeter）。
    /// DepthBand = ピントの奥行き focusDistance（場面の長さ）を中心に ±range の帯を見て、帯の中の割合 band までくっきり・
    /// band + soft でぼかし切る（模型を近くから撮ったような見え方）。blur はぼかしの半径（画面の高さ = 1）。
    pub enum DepthOfField {
        case Physical({ focusDistance = Float64, fStop = Float64 })
        case DepthBand({ focusDistance = Float64, range = Float64, band = Float64, soft = Float64, blur = Float64 })
    }

    /// 重さと細かさの段。読む点の数と描き先の大きさだけを変え、値の意味は変えない。
    /// Auto = 画面の区分から（スマホは Low・ほかは Medium。画面なしの描き出しは Medium）。Fixed は読む点の数と縮みを言い切る形。
    pub enum Quality {
        case Auto
        case Low
        case Medium
        case High
        case Fixed({ bloomTaps = Int32, bloomScale = Float64, blurTaps = Int32 })
    }

    /// 場面の Pass の縁のならし（MSAA）。WebGPU は 1 か 4 しか持たない。
    pub enum Msaa with Eq, ToString {
        case Off
        case X4
    }

    /// 自分の Spec を挟む所。BeforeBloom = 場面の値（1 を超える）を読んで場面の値を書く・AfterViewTransform = 表示の値（0..1）を読んで書く。
    pub enum CustomAt with Eq, ToString {
        case BeforeBloom
        case AfterViewTransform
    }

    /// 自分の Spec の読む物の宣言（SceneDepth があれば PostStack が奥行きの絵の Pass を足す）。名前は sceneName()・depthName()・postName() か Pass の名前で読む。
    pub enum Read with Eq, ToString {
        case SceneColor
        case SceneDepth
        case Pass(String)
    }

    /// 自分の Spec の Pass 1 枚。name は Pass の名前（ps_ で始めない）・scale は描き先の倍率（窓の画素 = 1）。
    /// BeforeBloom の Pass が並ぶと、後の効果は最後の Pass の絵を場面として読む。AfterViewTransform の Pass も同じで、画面へは最後の Pass を置く。
    pub type alias CustomPass = { name = String, at = CustomAt, spec = ShaderDoc.Spec, reads = List[Read], scale = Float64 }

    /// 途中の絵を画面へ出す（make render で 1 枚見る用）。Final = 仕上がり・Scene = 露出と曲線の前の場面の値・Bloom = ブルームの絵・Depth = 奥行きの絵。
    pub enum DebugView with Eq, ToString {
        case Final
        case Scene
        case Bloom
        case Depth
    }

    /// 見た目の名前から引く出発点（docs/art-ref/visual-dict/reference-3d.md の行の名前と同じ）。値は PostStack.preset。
    pub enum Preset with Eq, ToString {
        case Neutral
        case DuskOutdoor
        case NightOutdoor
        case SunnyCity
        case EveningBeach
        case Cave
        case NightCorridor
        case TorchRoom
    }

    /// 組み方の問題（build が返す。実機は 1 回だけ知らせ、描き出しの lint は止める）。
    pub enum Issue with Eq, ToString {
        /// 奥行きのぼかしがあるのに、View が返す絵に 3D の場面が無い（ぼかしは掛けない）。
        case NoScene3d
        /// 3D の場面が 2 つ以上ある（奥行きの絵は一番大きい場面から作る）。payload は場面の数。
        case SeveralScenes(Int32)
        /// 自分の Spec の Pass の名前が ps_ で始まる（PostStack の Pass と混ざるので描かない）。
        case ReservedPassName(String)
    }

    // ── 値の束 ──

    /// 全部の欄。外から作らせない（preset から始めて with* で替える・load で Doc から読む）。
    // WhyNot: 組んだ Spec を中に持たない — Stack はゲームが毎コマ組み直す値で、持っても次のコマには残らない。
    // 調整の数のうち毎コマ動かしたい物（露出・強さ）は Param で渡し、Spec を同じ形に保つ（描き手は形が同じ間 program を作り直さない）。
    enum StackData {
        case StackData({ exposure = Float64, viewTransform = ViewTransform, bloom = Option[Bloom], colorGrade = Option[ColorGrade],
                         vignette = Option[Vignette], depthOfField = Option[DepthOfField], fxaa = Bool, custom = List[CustomPass],
                         quality = Quality, msaa = Msaa, debugView = DebugView })
    }

    /// 後がけの値の束（Godot の Environment・Unity の Volume のように、効果ごとの欄を持つ値 1 つ）。
    pub type alias Stack = StackData

    type alias Fields = { exposure = Float64, viewTransform = ViewTransform, bloom = Option[Bloom], colorGrade = Option[ColorGrade],
                          vignette = Option[Vignette], depthOfField = Option[DepthOfField], fxaa = Bool, custom = List[CustomPass],
                          quality = Quality, msaa = Msaa, debugView = DebugView }

    def fieldsOf(s: Stack): Fields = match s { case StackData.StackData(f) => f }

    def neutralFields(): Fields =
        { exposure = 0.0, viewTransform = ViewTransform.Standard, bloom = None, colorGrade = None, vignette = None,
          depthOfField = None, fxaa = false, custom = Nil, quality = Quality.Auto, msaa = Msaa.Off, debugView = DebugView.Final }

    def aces(saturation: Float64): ViewTransform = ViewTransform.AcesNarkowicz({ whitePoint = 4.0, saturationAfter = saturation })

    def presetVignette(strength: Float64): Option[Vignette] = Some({ strength = strength, inner = 0.35, outer = 1.05, center = { x = 0.5, y = 0.5 } })

    /// 見た目の名前の出発点。Neutral は「Standard・露出 0・ほかは無し」。
    pub def preset(p: Preset): Stack =
        let n = neutralFields();
        let bloom = (threshold, strength) -> Some({ threshold = threshold, smoothness = 0.5, size = 0.04, strength = strength });
        StackData.StackData(match p {
            case Preset.Neutral       => n
            case Preset.DuskOutdoor   => { viewTransform = aces(0.06), bloom = bloom(0.95, 0.6), vignette = presetVignette(0.3), fxaa = true | n }
            case Preset.NightOutdoor  => { exposure = -0.2, viewTransform = aces(0.0), bloom = bloom(0.8, 0.9), vignette = presetVignette(0.4), fxaa = true | n }
            case Preset.SunnyCity     => { viewTransform = aces(0.1), bloom = bloom(1.4, 0.3), vignette = presetVignette(0.18), fxaa = true | n }
            case Preset.EveningBeach  => { viewTransform = aces(0.08), bloom = bloom(1.0, 0.5), vignette = presetVignette(0.25), fxaa = true | n }
            case Preset.Cave          => { exposure = -0.3, viewTransform = aces(-0.05), bloom = bloom(0.7, 0.8), vignette = presetVignette(0.5), fxaa = true | n }
            case Preset.NightCorridor => { exposure = -0.2, viewTransform = aces(0.0), bloom = bloom(0.75, 1.0), vignette = presetVignette(0.45), fxaa = true | n }
            case Preset.TorchRoom     => { viewTransform = aces(0.05), bloom = bloom(0.9, 0.8), vignette = presetVignette(0.4), fxaa = true | n }
        })

    def mapFields(f: Fields -> Fields, s: Stack): Stack = StackData.StackData(f(fieldsOf(s)))

    /// 露出（stop の数。線形の値に 2^stops を掛ける。Blender の Color Management → Exposure）。ブルームと色の仕上げの後に掛かる。
    pub def withExposure(stops: Float64, s: Stack): Stack = mapFields(f -> { exposure = stops | f }, s)

    pub def withViewTransform(v: ViewTransform, s: Stack): Stack = mapFields(f -> { viewTransform = v | f }, s)

    /// None で外す（with* はどれも効果の欄を丸ごと替える。Doc の上書きは欄ごとに混ぜる — load の doc）。
    pub def withBloom(b: Option[Bloom], s: Stack): Stack = mapFields(f -> { bloom = b | f }, s)

    pub def withColorGrade(c: Option[ColorGrade], s: Stack): Stack = mapFields(f -> { colorGrade = c | f }, s)

    pub def withVignette(v: Option[Vignette], s: Stack): Stack = mapFields(f -> { vignette = v | f }, s)

    pub def withDepthOfField(d: Option[DepthOfField], s: Stack): Stack = mapFields(f -> { depthOfField = d | f }, s)

    pub def withFxaa(on: Bool, s: Stack): Stack = mapFields(f -> { fxaa = on | f }, s)

    /// 自分の Spec の Pass の列（前の列を丸ごと替える）。
    pub def withCustom(c: List[CustomPass], s: Stack): Stack = mapFields(f -> { custom = c | f }, s)

    pub def withQuality(q: Quality, s: Stack): Stack = mapFields(f -> { quality = q | f }, s)

    pub def withMsaa(m: Msaa, s: Stack): Stack = mapFields(f -> { msaa = m | f }, s)

    pub def withDebugView(v: DebugView, s: Stack): Stack = mapFields(f -> { debugView = v | f }, s)

    // ── 読む口（Doc の値を確かめる・テストする） ──

    pub def exposureOf(s: Stack): Float64 = fieldsOf(s)#exposure

    pub def viewTransformOf(s: Stack): ViewTransform = fieldsOf(s)#viewTransform

    pub def bloomOf(s: Stack): Option[Bloom] = fieldsOf(s)#bloom

    pub def colorGradeOf(s: Stack): Option[ColorGrade] = fieldsOf(s)#colorGrade

    pub def vignetteOf(s: Stack): Option[Vignette] = fieldsOf(s)#vignette

    pub def depthOfFieldOf(s: Stack): Option[DepthOfField] = fieldsOf(s)#depthOfField

    pub def isFxaa(s: Stack): Bool = fieldsOf(s)#fxaa

    pub def qualityOf(s: Stack): Quality = fieldsOf(s)#quality

    pub def msaaOf(s: Stack): Msaa = fieldsOf(s)#msaa

    // ── Pass の名前（自分の Spec が Field.Tex で読む） ──

    /// 場面（View が返す絵）を描いた Pass。BeforeBloom の自分の Spec はこれを読む。
    pub def sceneName(): String = "ps_scene"

    /// 奥行きの絵（DepthBand は ±range の帯を 0..1・Physical は目からの距離を camera の far で割った値。r に入る）。
    pub def depthName(): String = "ps_depth"

    /// 曲線を掛けた後の表示の値の Pass。AfterViewTransform の自分の Spec はこれを読む。
    pub def postName(): String = "ps_post"

    /// PostStack の Pass の名前の頭（ゲームの Pass はこれで始めない）。
    pub def reservedPrefix(): String = "ps_"

    // ── Doc ──

    /// post.json（schema は engine の docs/post.schema.json）を読む。preset が出発点で、書いた欄だけが上書き
    /// （効果の欄は欄ごとに混ぜる・kind を持つ欄は kind が同じ時だけ混ぜ、違えば丸ごと替える・null はその効果を外す）。
    pub def load(path: String): Result[JsonError, Stack] \ Fs.FileRead =
        PostStack.Internal.Doc.load(path)

    /// load の、読めない・壊れている時に fallback で続ける形（1 行知らせる。ファイルが無いのは正常系で黙る）。
    pub def loadOr(fallback: Stack, path: String): Stack \ Fs.FileRead =
        PostStack.Internal.Doc.loadOr(fallback, path)

    /// JSON の字から読む（load の中身・テストと Studio の保存即反映の口）。
    pub def parse(text: String): Result[JsonError, Stack] =
        PostStack.Internal.Doc.parse(text)

    // ── 組む ──

    /// build に渡す物。size = 画面（design）の大きさ・clear = 場面の Pass を消す色・world = 後がけを掛ける絵（View が返す物）。
    pub type alias BuildInput = { size = Vec2.Vec2, clear = Color, world = List[Render.PlacedItem] }

    /// 先に描く Pass の計画・world の代わりに画面へ置く面 1 枚・組み方の問題。
    /// 計画は自分の Pass の計画の後ろに足す（Render.mergePassPlans）。
    pub def build(input: BuildInput, s: Stack): { plan = Render.PassPlan, present = Render.PlacedItem, issues = List[Issue] } =
        PostStack.Internal.Passes.build(input, fieldsOf(s))

    /// Auto を画面の区分で決めた Stack（スマホは Low・ほかは Medium）。App.withPostStack は描く前にこれを通す。
    pub def resolveQuality(sizeClass: Display.SizeClass, s: Stack): Stack = match fieldsOf(s)#quality {
        case Quality.Auto => withQuality(if (sizeClass == Display.SizeClass.Small) Quality.Low else Quality.Medium, s)
        case _            => s
    }

    /// 問題 1 件の知らせの字。
    pub def issueText(issue: Issue): String = match issue {
        case Issue.NoScene3d          => "奥行きのぼかしがあるのに、View の絵に 3D の場面が無い — ぼかさない"
        case Issue.SeveralScenes(n)   => "3D の場面が ${n} 個ある — 奥行きの絵は一番大きい場面から作る"
        case Issue.ReservedPassName(n) => "自分の Pass '${n}' が ps_ で始まる — 描かない（ps_ は PostStack の Pass）"
    }
}
