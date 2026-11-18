// PostStack — 画面全体の後がけ（奥行きのぼかし・ブルーム・色の仕上げ・ビネット・露出・トーンマップ・FXAA）を値の束 1 つで言う口
// （Unity の Post-processing Stack・Godot の Environment・Bevy の camera の Bloom / Tonemapping と同じ役目）。
// ゲームは「どの効果をどの値で」を言い、順・Pass・描き先の大きさと形式・Spec はここが決める。中身は Render.Pass と ShaderDoc の面に展開する純粋な関数で、
// 描き手（GL・WebGPU・CPU）は触らない。式の部品（トーンマップの曲線・FXAA・luma）が要る時だけ PostProcess を使う。
//
// 掛かる順（Blender の Color Management の順。霧と歪みはその前で、場面の絵そのものを描き替える）: 高さの霧 → 画面の歪み → 奥行きのぼかし → ブルーム → 色の仕上げ → ビネット → 露出 → view transform → FXAA。
// Standard と KhronosNeutral は場面の値を線形へ戻してから掛ける（Blender と同じ線形の値の上の式。曲線の門は engine_world/test の TestPostStackBlender）。
// 掛ける範囲は View が返す絵の全部（App.withPostStack）。HUD（App.withHudView）とデバッグの重ねには掛からない —
// トーンマップもぼかしも掛けたくない UI（会話の窓・メニュー・字幕）は HUD に置く。
//
// 使い方: `App.withPostStack(w -> PostStack.preset(PostStack.Preset.DuskOutdoor) |> PostStack.withExposure(-0.3))`。
// Doc から読むなら読み込みの時に 1 回 `PostStack.loadOr(PostStack.preset(PostStack.Preset.Neutral), "assets/post.json")`（schema は engine の docs/post.schema.json）
// を Resources に置き、withPostStack の関数はそれを返す（毎コマ読まない）。
// App を通さない描き方（自前の Pass の並び・描き出し）は build が計画と画面へ置く面を返す。
pub mod PostStack {

    use Util.Json.JsonError

    // ── 効果ごとの欄 ──

    /// ブルーム（明るい所をにじませて足す）。threshold = にじみ始める明るさ（1 を超える所が光る所）・smoothness = threshold から
    /// にじみ切るまでの幅・size = にじみの半径（画面の高さを 1 とした長さ）・strength = 足す強さ。
    pub type alias Bloom = { threshold = Float64, smoothness = Float64, size = Float64, strength = Float64 }

    /// 画面の縁を暗くする。画面の真ん中 center（0..1）から inner〜outer の距離（縦横比を直し、高さ = 1）で、1 から 1 − strength へ落ちる。
    pub type alias Vignette = { strength = Float64, inner = Float64, outer = Float64, center = Vec2.Vec2 }

    /// 色の仕上げ（Blender の compositor の Color Balance（Lift / Gamma / Gain）と Hue/Saturation/Value の Saturation の式を写した物。Blender の絵とは未比較）。
    /// どれも 1 が「何もしない」。lift は暗い所・gamma は中間・gain は明るい所を色ごとに持ち上げる。saturation は掛け算（0 = 灰色）。
    /// 線形の値を前提にした式なので、AcesNarkowicz（画面の値のまま掛ける互換の道）と組むと Blender の式とは意味がずれる。
    pub type alias ColorGrade = { lift = Color, gamma = Color, gain = Color, saturation = Float64 }

    /// 曲線（View Transform）。名前と曲線は Blender の Color Management に合わせる。Standard と KhronosNeutral は、場面の値を読む所で
    /// 線形へ戻し（描き手の Pass は画面の値を持つ）、ブルーム・色の仕上げ・ビネット・露出を線形の値に掛けてから曲線と sRGB の曲線で表示の値にする
    /// （Standard = 曲線なしで 1 で切る・KhronosNeutral = Khronos PBR Neutral・AgX = AgX の Base）。
    /// AcesNarkowicz は今までのゲームの見え方との互換で、画面の値のまま掛ける（Narkowicz 2015 の ACES の近似を whitePoint で 1 にそろえ、曲線の後に
    /// 0..1 の色の彩度を saturationAfter だけ足す。0 = そのまま。Blender に無い曲線）。
    pub enum ViewTransform {
        case Standard
        case KhronosNeutral
        /// AgX（Look は Base だけ）。Blender の AgX と同じ考え方の式（Rec.2020 で色を少し内へ寄せ、明るさを log2 で 16.5 stop に詰め、
        /// S 字の曲線を掛けてから外へ戻す）を自前で組んだ物。Blender の絵との近さは engine_world/test の TestPostStackBlender。
        case AgX
        case AcesNarkowicz({ whitePoint = Float64, saturationAfter = Float64 })
    }

    /// 奥行きのぼかし。ぼかしに使う奥行きの絵は、View が返す絵の中の 3D の場面から PostStack が作る（ゲームが場面を 2 回組まない）。
    /// Physical = カメラのぼけ（Blender の Camera → Depth of Field。focusDistance は m・fStop は F 値・センサーの高さ 24 mm・
    /// 長さの単位は Scene3d.withUnitsPerMeter）。
    /// DepthBand = ピントの奥行き focusDistance（場面の長さ）を中心に ±range の帯を見て、帯の中の割合 band までくっきり・
    /// band + soft でぼかし切る（模型を近くから撮ったような見え方）。blur はぼかしの半径（画面の高さ = 1）。
    /// 奥行きは目からの距離（カメラの向きの奥行きではない）。毎コマ動かしてよいのは Physical の focusDistance と fStop（Param で渡る）と
    /// DepthBand の focusDistance（奥行きの絵の切り出し）。DepthBand の band・soft・blur を毎コマ動かすと描き手が program を作り直す。
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

    /// 画面の歪み（Distortion）を掛ける範囲。
    /// Full = 画面全体・BottomBand = 画面の上から top（0..1）で 0、top + soft で 1（下ほど強い。地面から立つ陽炎）・
    /// Texture = 名前の絵（project.json の絵か Pass）の r（0..1）を重みにする（画面いっぱいに引き伸ばして読む。無い名前は 0 で歪まない）。
    pub enum DistortionMask {
        case Full
        case BottomBand({ top = Float64, soft = Float64 })
        case Texture(String)
    }

    /// 画面の歪み（熱のゆらぎ・水の中・魔法）。時間で流れる揺らぎの模様（向きと長さの違う波を重ねた物）で、場面の絵を読む位置をずらす。
    /// Unreal・Unity HDRP の Distortion（屈折で読む位置をずらす物）と同じ系統で、Unity の Lens Distortion（樽型の歪み）とは別物。
    /// strength = ずらす最大の量（design の px・x と y 別）・noiseSize = 揺らぎの粒の大きさ（design の px・一番長い波の半分の長さ）・
    /// speed = 模様が流れる速さ（design の px / 秒・y は下が +。陽炎は上へ流すので負）・mask = 掛ける範囲。
    /// 流れの時刻は withTime で渡す（渡さなければ 0 で止まった模様）。
    /// 毎コマ動かしてよいのは strength と時刻（Param で渡る）。noiseSize・mask を毎コマ動かすと描き手が program を作り直す。
    /// noiseSize ≤ 0 か strength が x・y とも 0 なら Pass を足さない（無いのと同じ絵）。
    pub type alias Distortion = { strength = Vec2.Vec2, noiseSize = Float64, speed = Vec2.Vec2, mask = DistortionMask }

    /// 霧のむら（ゆっくり流れる濃い所と薄い所）。size = むらの大きさ（場面の長さ）・amount = 濃さを揺らす割合（0..1）・
    /// speed = 流れる速さ（場面の長さ / 秒・x と z）。
    pub type alias FogNoise = { size = Float64, amount = Float64, speed = Vec2.Vec2 }

    /// 高さの霧（地面の近くほど濃く、遠いほど濃くなる霧）。Unreal の Exponential Height Fog と同じ式で、名前もそろえた。
    /// color = 霧の色（sRGB の 0..1）・density = 高さ baseHeight での濃さ（場面の長さ 1 あたり）・heightFalloff = 高さが 1 上がるごとに濃さが e^−heightFalloff 倍になる量・
    /// startDistance = 目からこの距離までは霧を積まない・maxOpacity = 霧の濃さの上限（0..1。1 で遠くは霧の色だけになる）・noise = むら（None で無し）・
    /// lightGlow = 点光源のまわりの霧が明るくなる強さ（0 で無し。街灯のにじみ）。長さはどれも Scene3d の場面の長さ（m で考えるなら Scene3d.withUnitsPerMeter の倍率を掛ける）。
    /// 3D の場面の奥行きの絵から積むので、View の絵に 3D の場面が無ければ掛からない（Issue.NoScene3d）。View の中の 2D の絵は、その下の 3D の奥行きで霧が掛かる（字の窓は HUD に置く）。
    /// 毎コマ動かしてよいのは color・density・heightFalloff・startDistance・maxOpacity・noise.amount・lightGlow（Param で渡る）。noise.size を動かすと描き手が program を作り直す。
    /// 灯りは目に近い 8 つまで（Scene3d の pointLights から）。半透明の物は奥行きの絵に入らないので、その奥の面の霧が掛かる。
    pub type alias HeightFog = { color = Color, density = Float64, baseHeight = Float64, heightFalloff = Float64, startDistance = Float64,
                                 maxOpacity = Float64, noise = Option[FogNoise], lightGlow = Float64 }

    /// 場面の Pass の縁のならし（MSAA）。WebGPU は 1 か 4 しか持たない。
    pub enum Msaa with Eq, ToString {
        case Off
        case X4
    }

    /// 自分の Spec を挟む所。BeforeBloom = 場面の Pass の値（描き手が書いた画面の値・1 を超える）を読んで同じ形の値を書く（線形へ戻すのはこの後）・
    /// AfterViewTransform = 表示の値（0..1）を読んで書く。
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

    // ── 効果ごとの既定値（`{ strength = 0.9 | PostStack.bloom() }` の形で替える。post.json で効果の欄を書いた時の出発点も同じ値） ──

    /// threshold 1・smoothness 0.5・size 0.04・strength 0.6 のブルーム。
    pub def bloom(): Bloom = { threshold = 1.0, smoothness = 0.5, size = 0.04, strength = 0.6 }

    /// strength 0.3・inner 0.35・outer 1.05・画面の真ん中のビネット。
    pub def vignette(): Vignette = { strength = 0.3, inner = 0.35, outer = 1.05, center = { x = 0.5, y = 0.5 } }

    /// 何もしない色の仕上げ（lift・gamma・gain・saturation がどれも 1）。
    pub def colorGrade(): ColorGrade =
        { lift = Color.rgb(1.0, 1.0, 1.0), gamma = Color.rgb(1.0, 1.0, 1.0), gain = Color.rgb(1.0, 1.0, 1.0), saturation = 1.0 }

    /// 画面全体を上へ流れる揺らぎで歪める（strength (2, 1)・noiseSize 24・speed (0, −20)・mask Full）。
    pub def distortion(): Distortion = { strength = { x = 2.0, y = 1.0 }, noiseSize = 24.0, speed = { x = 0.0, y = -20.0 }, mask = DistortionMask.Full }

    /// size 8・amount 0.4・speed (0.5, 0.2) の霧のむら。
    pub def fogNoise(): FogNoise = { size = 8.0, amount = 0.4, speed = { x = 0.5, y = 0.2 } }

    /// 青みの灰色・density 0.02・heightFalloff 0.2・むらと灯りのにじみ無しの高さの霧。
    pub def heightFog(): HeightFog =
        { color = Color.rgb(0.62, 0.66, 0.74), density = 0.02, baseHeight = 0.0, heightFalloff = 0.2, startDistance = 0.0, maxOpacity = 1.0,
          noise = None, lightGlow = 0.0 }

    // ── 値の束 ──

    /// 全部の欄。外から作らせない（preset から始めて with* で替える・load で Doc から読む）。
    // WhyNot: 組んだ Spec を中に持たない — Stack は withPostStack の関数が毎コマ返す値で、同じ Stack を使い回すゲームでも build が毎コマ Spec を組む。
    // 描き手は Spec を中身で比べ、形が同じ間は program を作り直さない。毎コマ動かしたい数（露出・強さ・Physical のピント）は Param で渡して形を保つ。
    // 中身の比べの重さ（wasm の CPU）は測っていない。重ければ App の側で構造の鍵で引く控えを持つ。
    enum StackData {
        case StackData(Fields)
    }

    /// 後がけの値の束（Godot の Environment・Unity の Volume のように、効果ごとの欄を持つ値 1 つ）。
    pub type alias Stack = StackData

    type alias Fields = { exposure = Float64, viewTransform = ViewTransform, bloom = Option[Bloom], colorGrade = Option[ColorGrade],
                          vignette = Option[Vignette], depthOfField = Option[DepthOfField], fxaa = Bool, custom = List[CustomPass],
                          quality = Quality, msaa = Msaa, debugView = DebugView, background = Option[Color],
                          distortion = Option[Distortion], time = Float64, heightFog = Option[HeightFog] }

    def fieldsOf(s: Stack): Fields = match s { case StackData.StackData(f) => f }

    def neutralFields(): Fields =
        { exposure = 0.0, viewTransform = ViewTransform.Standard, bloom = None, colorGrade = None, vignette = None,
          depthOfField = None, fxaa = false, custom = Nil, quality = Quality.Auto, msaa = Msaa.Off, debugView = DebugView.Final,
          background = None, distortion = None, time = 0.0, heightFog = None }

    def presetVignette(strength: Float64): Option[Vignette] = Some({ strength = strength, inner = 0.35, outer = 1.05, center = { x = 0.5, y = 0.5 } })

    /// 見た目の名前の出発点。Neutral は「Standard・露出 0・ほかは無し」。
    /// 曲線は AgX（Blender の既定の view transform）。露出・ブルーム・ビネット・彩度は reference-3d.md の場面の行の値を、線形の値に掛ける前提で置いた物
    /// （画面の値のまま掛けていた頃の露出 −0.6 の打ち消しは要らない）。人の目で Blender の絵と並べて決め直す前の値。
    pub def preset(p: Preset): Stack =
        let n = neutralFields();
        let agx = (exposure: Float64) -> { exposure = exposure, viewTransform = ViewTransform.AgX, fxaa = true | n };
        let presetBloom = (threshold, smoothness, size, strength) -> Some({ threshold = threshold, smoothness = smoothness, size = size, strength = strength });
        let saturated = (k: Float64) -> Some({ lift = Color.rgb(1.0, 1.0, 1.0), gamma = Color.rgb(1.0, 1.0, 1.0), gain = Color.rgb(1.0, 1.0, 1.0), saturation = k });
        StackData.StackData(match p {
            case Preset.Neutral       => n
            case Preset.DuskOutdoor   => { bloom = presetBloom(0.95, 0.7, 0.045, 0.9), vignette = presetVignette(0.34) | agx(0.0) }
            case Preset.NightOutdoor  => { bloom = presetBloom(0.9, 0.7, 0.045, 0.95), vignette = presetVignette(0.42) | agx(-0.15) }
            case Preset.SunnyCity     => { bloom = presetBloom(1.0, 0.6, 0.03, 0.25), vignette = presetVignette(0.18), colorGrade = saturated(1.12) | agx(0.0) }
            case Preset.EveningBeach  => { bloom = presetBloom(0.85, 0.5, 0.05, 0.6), vignette = presetVignette(0.25) | agx(0.0) }
            case Preset.Cave          => { bloom = presetBloom(0.9, 0.6, 0.035, 0.45), vignette = presetVignette(0.45), colorGrade = saturated(1.18) | agx(0.1) }
            case Preset.NightCorridor => { bloom = presetBloom(2.0, 0.6, 0.04, 0.4), vignette = presetVignette(0.35) | agx(-0.3) }
            case Preset.TorchRoom     => { bloom = presetBloom(1.0, 0.6, 0.05, 0.8), vignette = presetVignette(0.45), colorGrade = saturated(1.1) | agx(0.0) }
        })

    /// preset の全部（宣言の順）。
    pub def presets(): List[Preset] =
        Preset.Neutral :: Preset.DuskOutdoor :: Preset.NightOutdoor :: Preset.SunnyCity :: Preset.EveningBeach
            :: Preset.Cave :: Preset.NightCorridor :: Preset.TorchRoom :: Nil

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

    /// 場面の Pass を消す色（View が描かない所の色。App.withPostStack の道で使う・build は BuildInput#clear）。
    /// 言わなければ画面の地の色（実機は project.json の clearColor）。
    pub def withBackground(c: Color, s: Stack): Stack = mapFields(f -> { background = Some(c) | f }, s)

    pub def withDistortion(d: Option[Distortion], s: Stack): Stack = mapFields(f -> { distortion = d | f }, s)

    pub def withHeightFog(h: Option[HeightFog], s: Stack): Stack = mapFields(f -> { heightFog = h | f }, s)

    /// 時間で動く後がけ（Distortion と HeightFog のむら）の時刻。陽炎と霧は遊びの時計（ポーズで止まる）を渡す。描き出しとテストは決まった時刻を渡す。
    // WhyNot: App が自分の時刻を配らない — App は遊びの時計と実時間のどちらで流すかを知らない（docs/clock.md）。
    pub def withTime(t: Clock.Time[c], s: Stack): Stack = mapFields(f -> { time = Clock.secondsOf(t) | f }, s)

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

    pub def debugViewOf(s: Stack): DebugView = fieldsOf(s)#debugView

    pub def customOf(s: Stack): List[CustomPass] = fieldsOf(s)#custom

    pub def backgroundOf(s: Stack): Option[Color] = fieldsOf(s)#background

    pub def distortionOf(s: Stack): Option[Distortion] = fieldsOf(s)#distortion

    pub def heightFogOf(s: Stack): Option[HeightFog] = fieldsOf(s)#heightFog

    /// withTime の秒。
    pub def timeOf(s: Stack): Float64 = fieldsOf(s)#time

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
