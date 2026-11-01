// ShaderDoc — 面（矩形）を GPU シェーダーで塗るための「宣言データ」。
// 生の GLSL を書かず、少数の部品（値の場・色・出力）を組み合わせて水面のような
// 連続した見た目を作る。ここでは部品の型（Spec）と、それを GLSL 文字列へ変換する
// codegen（ShaderGen）、CPU で同じ式を評価する検証用の評価器（ShaderEval）を持つ。
// 実際に GPU で走らせる仕事はバックエンド（render_gl）が担う。
// 利用例: 水面の網目（Worley F2−F1）を時間で揺らしながら塗る / 位置に応じたグラデを塗る。
//
// 語彙は「値の場（スカラー）」→「色」→「出力」の三段。任意 GLSL は書けない — 語彙の合成だけが
// GLSL になる。座標変換（Scaled/Warp）は inner の場が見る uv を差し替える形で表す。
// 時間は uTime uniform として codegen が差し込む（Scroll / cycleRate がこれに掛かる）。

pub mod ShaderDoc {

    /// 位置 (u,v) のどちらの軸を読むか。
    pub enum Axis with Eq, ToString {
        case U
        case V
    }

    /// 3D の world の軸（左手系。X = 東・Y = 上・Z = 北。Scene3d と同じ約束）。World / Normal の成分。
    pub enum Axis3 with Eq, ToString {
        case X
        case Y
        case Z
    }

    /// Worley（セルノイズ）の出力の選び方。F2mF1 が網目（水面の目地）。
    pub enum WorleyOut with Eq, ToString {
        case F1     // 一番近いセル点までの距離（斑点）
        case F2     // 二番目に近い点までの距離
        case F2mF1  // F2 − F1（セル境界＝網目）
    }

    /// Tex がテクスチャのどのチャンネルを読むか。既定は R（明るさ・マスクの慣習）。
    pub enum TexChan with Eq, ToString {
        case R case G case B case A
    }

    /// tex / blur がテクスチャを読むときの補間（wgpu の FilterMode・Unity の Point/Linear と同じ 2 択）。
    /// Nearest = 補間なし（既定・ドット絵を崩さない）、Linear = 隣のテクセルとなめらかにつなぐ（GL の GL_LINEAR と同じ点と重み）。
    pub enum FilterMode with Eq, ToString {
        case Nearest
        case Linear
    }

    /// 2 つの場を合わせる素の計算。混ぜる意図（0..1 の重み）は Blend を使い、これは生の値の合成。
    pub enum BinOp with Eq, ToString {
        case Add  case Sub  case Mul      // 足す・引く・掛ける
        case Min  case Max                // 小さい方・大きい方
        case Step                         // b が a 以上なら 1、そうでなければ 0
        case Div                          // a を b で割る。b が 0 なら 0（無限大・NaN の画素で潰れないように）
    }

    /// 1 つの場に掛ける素の関数。
    pub enum UnOp with Eq, ToString {
        case Neg case Abs case Fract case Floor
        case Sin case Cos
        case Sat        // 0..1 に丸める
        case OneMinus   // 1 から引く（反転）
        case Sqrt       // 平方根。負の数は 0 として扱う（NaN の画素を出さない）
    }

    /// 値の場（スカラー・0..1 目安）。GPU では 1 個の float、CPU では Float64 になる。
    /// Scaled / Warp は「inner が見る座標」を変える座標変換ノード（uv を差し替える）。
    pub enum Field {
        /// どこでも同じ値。
        case Const(Float64)
        /// 位置 (u,v) の指定軸（0..1）。
        case Uv({ axis = Axis })
        /// セルノイズ。out=F2mF1 で網目。seed で模様が変わる。
        case Worley({ scale = Float64, seed = Int32, out = WorleyOut })
        /// 雲状ノイズ（オクターブを重ねた value noise・octaves は小さめに）。
        case Fbm({ octaves = Int32, scale = Float64, seed = Int32 })
        /// 周期つきの雲状ノイズ（Fbm のタイル版）。格子点を period.x × period.y マスで
        /// 折り返すので、読む座標が period マスぶん進むと同じ値に戻る（スクロールで流しても
        /// 継ぎ目が出ない）。Fbm はこの折り返しが無く、流すとループが閉じない。
        /// period は正の整数マス数を推奨（uv 0..1 に scale = period を合わせると 1 枚で 1 周期）。
        case FbmTile({ octaves = Int32, scale = Float64, period = Vec2.Vec2, seed = Int32 })
        /// lo..hi の間でなめらかに 0→1（それ以外は 0 か 1 にクランプ）。
        case Smoothstep({ lo = Float64, hi = Float64, of = Field })
        /// inner の場を、uv を factor 倍 + 時刻スクロールした座標で読む
        /// （scroll は uv に uTime*scroll を足す・タイル密度と流れを与える）。
        case Scaled({ factor = Float64, scroll = Vec2.Vec2, of = Field })
        /// ドメインワープ。inner を、fbm で amount だけ揺らした座標で読む（網目をうねらせる）。
        case Warp({ amount = Float64, scale = Float64, seed = Int32, of = Field })
        /// 定数比 t で 2 つの場を混ぜる（線形補間）。
        case Mix({ a = Field, b = Field, t = Float64 })
        /// 場 by（0..1）で 2 つの場を混ぜる（by=0 で a・1 で b）。
        case Blend({ a = Field, b = Field, by = Field })
        /// 丸マスク。uv 空間で中心 (cx,cy) から radius 以内は 1、radius→radius+feather で
        /// なめらかに 0（縁が soft に消える）。矩形の描画枠の中を丸い池型に抜く alpha に使う。
        case Disk({ cx = Float64, cy = Float64, radius = Float64, feather = Float64 })
        /// 中心距離場。uv 空間で (cx,cy) からの距離そのもの（中心 0・中心 (0.5,0.5) なら
        /// 四隅で約 0.707）。Smoothstep と組んでビネット（縁が滑らかに沈む暗がり）を作る素材 —
        /// Disk が「radius で 1→0 に落ちるマスク」なのに対し、これは生の距離を返すので
        /// 呼び側がカーブを自由に絞れる。
        case Radial({ cx = Float64, cy = Float64 })
        /// アスペクト補正つきの中心距離場。Radial は uv 空間の距離なので非正方形の rect では
        /// 円が楕円に歪む — aspect = 矩形の幅 ÷ 高さ を渡すと、u 方向の距離を aspect 倍して
        /// px で見た真円になる（距離は「rect の高さ = 1」の単位・aspect = 1 で Radial と同じ）。
        case RadialAspect({ cx = Float64, cy = Float64, aspect = Float64 })
        /// 値を steps 段階の階段に量子化する（ポスタライズ）。滑らかなノイズやグラデが
        /// ドット絵調の階段になる。steps が 1 未満なら 1 として扱う。
        case Quantize({ of = Field, steps = Int32 })
        /// 規則的に敷き詰めた丸い距離場（乱数でなく規則配置な点が Worley と違う）。
        /// scale = 細かさ、stagger = 行ごとの横ずらし（0 = 格子・0.5 = 半分ずらし）。
        case Scales({ scale = Float64, stagger = Float64 })
        /// まばらに明滅する横線（セルごとに違う位相で現れて消える）。scale = 間隔、
        /// rate = 明滅の速さ、density = 光るセルの割合（0..1・小さいほどまばら）、seed = 配置。
        case Glints({ scale = Float64, rate = Float64, density = Float64, seed = Int32 })
        /// 横方向に波打つ縞。freq = 縞の密度、amp = うねりの強さ、speed = 流れる速さ、
        /// seed = 位相。出力は縞のサイン (0..1)。Smoothstep で山を絞れば細い波線になる。
        case Ripples({ freq = Float64, amp = Float64, speed = Float64, seed = Int32 })
        /// 一瞬だけ光って消える点（毎回光る場所を選び直すので同じ所で繰り返さない）。
        /// scale = 間隔、rate = 瞬きの速さ（小さいほどたまに）、density = 一度に光る割合（0..1）、
        /// seed = 配置。Glints の横線と違い点で光る。
        case Sparkle({ scale = Float64, rate = Float64, density = Float64, seed = Int32 })
        /// 2 つの場 a,b を op で合わせる（足す・掛ける・大きい方…）。生の値の合成。
        /// 混ぜる意図（0..1 の重みで補間）は Blend の方が暴れなくて安全。
        case Bin({ op = BinOp, a = Field, b = Field })
        /// セルごとに違う乱数（0〜1）。scale = マス目の細かさ、seed = 模様の種。
        /// bucket は「時間などで乱数を選び直す」時に足す座標オフセット（None なら足さない）。
        case Hash1({ scale = Float64, seed = Int32, bucket = Option[Field] })
        /// セルごとに違う乱数の 2 成分（x か y を comp で選ぶ・0〜1）。
        /// scale/seed/bucket は Hash1 と同じ意味。ずらした点を置く時などに 2 成分いる。
        case Hash2({ scale = Float64, seed = Int32, comp = Axis, bucket = Option[Field] })
        /// 場 of に op（sin・絶対値・反転…）を 1 つ掛ける。
        case Un({ op = UnOp, of = Field })
        /// of を p 乗して尖らせる（山を細くする）。負にならないよう 0 で下切りしてから累乗する。
        /// p が負なら、底を negPowFloor() で下切りし、答えを negPowCeil() で上切りする（1/x などの逆数）。
        case Pow({ of = Field, p = Float64 })
        /// 今の時刻（秒）を scale 倍して offset の場を足す。動きの元。
        /// offset を Const にすれば「時刻 × scale + 定数」の素直な時間項になる。
        case Time({ scale = Float64, offset = Field })
        /// 模様をマス目（tiles.x × tiles.y 個）に敷いて、各マスの中を 0..1 の座標で読み直す。
        /// of は「1 マス内の場」で、fract(uv*tiles) を uv として読む（同じ模様がタイル状に繰り返す）。
        case Tiling({ tiles = Vec2.Vec2, of = Field })
        /// 読む座標を cells 分割の粗い格子に丸めてから of を読む（絵をドット絵の粒に落とす）。
        /// 1 マスの中はどこを見ても同じ値になるので、なめらかなノイズやグラデが
        /// 「補間なしで引き伸ばした低解像度の絵」と同じ角ばった塊になる。
        /// cells は軸ごとの分割数（120×68 のような非正方も可）。1 未満は 1 として扱う。
        /// Quantize が「値」を階段にするのに対し、こちらは「座標」を階段にする（迷彩でなく塊が出る）。
        case Snap({ cells = Vec2.Vec2, of = Field })
        /// 中心 (cx,cy) のまわりに座標を回して of を読む（水に溶いた絵の具を混ぜる渦）。
        /// 中心に近いほど速く回る（差動回転 strength/距離）ので、絵の具が渦を巻いて混ざる。
        /// rate は時間あたりの全体回転（uTime に掛かる）。Warp と同じく「読む座標を差し替える」変換。
        case Swirl({ cx = Float64, cy = Float64, strength = Float64, rate = Float64, of = Field })
        /// 中心 (cx,cy) から見た「角度」を 0..1 で返す（1 周で 0→1）。Radial（距離）と対で極座標をなす。
        /// これ一つで放射状の縞・花びら（sin(angle*枚数)）・螺旋（angle+radial）などが組み合わせで作れる。
        case Angle({ cx = Float64, cy = Float64 })
        /// 中心 (cx,cy) のまわりに座標を「均一に」回して of を読む（Swirl の差動でない版）。
        /// turns = 回す量（1.0 で 1 周）、rate = 時間あたりの回転（uTime に掛かる）。座標差し替え変換。
        case Rotate({ cx = Float64, cy = Float64, turns = Float64, rate = Float64, of = Field })
        /// 名前を付けて使い回す場（shared に定義したものを参照する）。
        /// 同じ計算を何度も書かずに一度だけ書いて名前で呼べる。
        /// 値は「面の基準 uv で 1 回だけ」評価される — 座標変換（Scaled/Warp/Shift…）の
        /// 内側に置いても変換後の座標では読み直さない（GL が main 先頭で 1 回計算する挙動が正）。
        case Ref(String)
        /// 名前つきテクスチャ（pass のレンダーターゲットや普通のテクスチャ）を今の uv で
        /// 標本して chan のチャンネル（0..1）を返す。標本は補間なし（NEAREST）・端は
        /// 張り付き（CLAMP）。Shift や Warp と組むと「前フレームの絵を歪めて読む」が書ける。
        case Tex({ name = String, chan = TexChan })
        /// 読む座標を (dx, dy) だけずらして of を読む。dx/dy は「外側の uv」で評価する
        /// （ずらし量自体は、ずらす前の位置で決まる — GL の式の組み方と同じ）。
        case Shift({ dx = Field, dy = Field, of = Field })
        /// 名前つきテクスチャを今の uv のまわりで taps 回読み、平均した chan（0..1）を返す（ぼかし）。
        /// 読む点は半径 radius（uv の単位・x と y 別。横長の面で丸くぼかすなら x = y × 縦÷横）の円の中に
        /// 黄金角でむらなく撒く（レンズのぼけに近い、縁の柔らかい円形のぼかし）。amount は半径に掛ける場で、
        /// 0 でぼかさず 1 で radius いっぱい（時間の場を入れるとピントが寄る・外れる演出になる）。
        /// 1 点ずつの標本は Tex と同じ NEAREST + CLAMP。taps は 1..64 に丸める。
        /// rgb を全部ぼかす時は r・g・b の 3 本に書く（場は 1 チャンネルなので、読む数は taps × 3 になる）。
        case TexBlur({ name = String, chan = TexChan, radius = Vec2.Vec2, taps = Int32, amount = Field })
        /// of の中の tex / blur を filter の補間で読む（Unity Shader Graph の Sampler State 節）。入れ子なら内側が勝つ。
        /// use（shared）の中までは届かない — use は基準 uv で 1 回だけ評価する決まりと同じで、shared の側に自分の sampler を書く。
        case Sampler({ filter = FilterMode, of = Field })
        /// 面を置く時に渡す数（Unity の Material.SetFloat・Godot の shader parameter と同じ「名前で渡す uniform」）。
        /// 値は Render.withShaderParams で面ごとに渡す。渡されなかった名前は 0（知らせは Render.drawShaders と
        /// Render.shaderSurfaces の側で、GL と描き出しのどちらでも出る）。名前は英数字と '_'（paramNameOk）。
        /// WhyNot: 毎フレーム変わる数を Const に入れない — Spec が変わり、実機は GLSL を作り直す。
        case Param({ name = String })
        /// 3D のメッシュに塗る時の、画素の world の点の axis の成分（Scene3d の材質だけが値を持つ）。
        /// Scaled・Tiling・Shift などの uv の変換を受けない — 内側に置いても、いつも画素の world の値。
        /// 2D の面（Item.Shader）では 0。Uv を読む場（Fbm・Worley…）を world の上で読むなら atWorld で包む。
        case World({ axis = Axis3 })
        /// 3D のメッシュに塗る時の、画素の外向きの単位の法線の axis の成分（-1..1）。uv の変換を受けない。
        /// 2D の面では 0。
        case Normal({ axis = Axis3 })
    }

    /// 面の色（rgb）。
    pub enum Shade {
        /// 単色。
        case Solid(Color)
        /// 2 色を field（0..1）で補間する。cycleRate>0 なら時間で位相が回る（パレット循環）。
        case Ramp({ lo = Color, hi = Color, field = Field })
        /// 3 色以上をなめらかに変える（黒殻→橙→黄白など）。stops = (位置 0..1, 色) を位置の小さい順に
        /// 並べた区切り。field（0..1）が位置のどこにいるかで、隣り合う色をなめらかに混ぜていく。
        /// 2 色 Ramp では「黒い締まりと明るい芯」を同時に出せないが、これなら間に色を挟める。
        case Gradient({ stops = List[(Float64, Color)], field = Field })
        /// コサインパレット（Inigo Quilez 方式）。col = a + b·cos(2π(c·field + d))。
        /// a=中心色・b=振れ幅・c=各色の周期・d=各色の位相。滑らかに循環する色が作れて、
        /// d を少しずらすだけで全体の配色が変わる（ステージごとの色替えに向く）。cycleRate>0 で位相が時間で回る。
        case Cosine({ a = Color, b = Color, c = Color, d = Color, field = Field })
        /// 3 つの場をそのまま r/g/b にする（Tex×3 でテクスチャの色を素通しするのが主用途）。
        /// cycleRate は掛からない — 3 本の場に別々の三角波を掛けると色が別々に呼吸して
        /// 意図が読めなくなるため（位相を回したい絵は Ramp/Gradient/Cosine の 1 本場で作る）。
        case Rgb({ r = Field, g = Field, b = Field })
    }

    /// 面の出力（このピクセルの最終色とアルファ）。
    pub enum Out {
        /// 面全体を shade で塗る（alpha は場で決める）。
        case Fill({ shade = Shade, alpha = Field })
    }

    /// シェーダー面 1 枚ぶんの宣言（theme.json の materials[i].surface に対応する予定）。
    /// cycleRate = パレット循環の速さ（Ramp の位相 uniform に掛かる。0 で静止）。
    /// bindings = 名前付きで使い回す場の置き場（前から順に定義・後の場は前の名前を Ref できる）。
    ///   空リストなら GLSL は何も増えない（既存 Spec は bindings = Nil）。
    pub type alias Spec = {
        name = String,
        cycleRate = Float64,
        bindings = List[(String, Field)],
        out = Out
    }

    /// 動作確認用の最小 Spec: 時間で lo↔hi を行き来する横グラデ（Uv U + 位相回し）。
    /// codegen と GPU 配管を端から端まで通すための「一番危なくない絵」。
    pub def demoSurface(): Spec =
        { name = "demo",
          cycleRate = 0.5,
          bindings = Nil,
          out = Out.Fill({
              shade = Shade.Ramp({ lo = { r = 0.15, g = 0.35, b = 0.55 },
                                   hi = { r = 0.55, g = 0.85, b = 0.95 },
                                   field = Field.Uv({ axis = Axis.U }) }),
              alpha = Field.Const(1.0) }) }

    /// 水のリアル版: Worley F2−F1 の網目（目地）を、ドメインワープでうねらせ、
    /// 時刻スクロールで流し、低彩度ティール→淡シアン白の 2 色パレットで塗る。
    /// パレットは cycleRate で位相が回る（時間で色が呼吸する）。
    ///   veins = Worley(F2mF1) を Warp でうねらせる
    ///   line  = Smoothstep(0, 0.06, veins) で細い目地に絞る
    ///   pool  = Warp(Disk) で真円を崩した不定形の丸マスク（縁がゆらぐ水たまり）
    pub def waterVeins(): Spec =
        let veins =
            Field.Warp({ amount = 0.08, scale = 4.0, seed = 7,
                of = Field.Scaled({ factor = 5.0, scroll = { x = 0.11, y = 0.07 },
                    of = Field.Worley({ scale = 1.0, seed = 42, out = WorleyOut.F2mF1 }) }) });
        let line = Field.Smoothstep({ lo = 0.0, hi = 0.06, of = veins });
        let pool = Field.Warp({ amount = 0.06, scale = 3.0, seed = 11,
                    of = Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.42, feather = 0.12 }) });
        { name = "water_veins",
          cycleRate = 0.25,
          bindings = Nil,
          out = Out.Fill({
              shade = Shade.Ramp({ lo = { r = 0.35, g = 0.55, b = 0.60 },
                                   hi = { r = 0.80, g = 0.95, b = 0.98 },
                                   field = line }),
              alpha = pool }) }

    /// マグマの正典 Spec（水と同じ骨格を熱いパレットで組み替えた対の素材）。
    /// 冷えた岩盤のひび割れ = Worley(F2mF1) を Warp でうねらせ（重い対流）、岩肌のムラ = Fbm を
    /// Blend で混ぜて割れ目以外ものっぺりさせない。割れ目を太めの光る筋（Smoothstep hi 大）にして
    /// 黒い殻→橙→黄白の Ramp で「割れ目が明るく光る」向きに塗る。cycleRate で発光が脈打つ。
    /// alpha は Disk で丸い溶岩溜まりにする（水の丸池と対で見せられる）。
    pub def lavaVeins(): Spec =
        let cracks =
            Field.Warp({ amount = 0.14, scale = 3.0, seed = 3,
                of = Field.Scaled({ factor = 5.0, scroll = { x = 0.01, y = 0.008 },
                    of = Field.Worley({ scale = 1.0, seed = 17, out = WorleyOut.F2mF1 }) }) });
        // 割れ目を太めの光る筋に絞りつつ、岩肌のムラ(Fbm)を薄く混ぜてのっぺりを崩す。
        let mottle = Field.Fbm({ octaves = 3, scale = 4.0, seed = 23 });
        let glow = Field.Blend({ a = Field.Smoothstep({ lo = 0.0, hi = 0.12, of = cracks }),
                                 b = mottle, by = Field.Const(0.25) });
        let pool = Field.Warp({ amount = 0.06, scale = 3.0, seed = 29,
                    of = Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.42, feather = 0.12 }) });
        { name = "lava",
          cycleRate = 0.35,
          bindings = Nil,
          out = Out.Fill({
              shade = Shade.Ramp({ lo = { r = 0.10, g = 0.04, b = 0.02 },
                                   hi = { r = 1.0,  g = 0.88, b = 0.54 },
                                   field = glow }),
              alpha = pool }) }

    /// この Spec を塗ったときの「代表色」（F8 注釈・SoftRaster など GLSL を走らせられない
    /// 経路のベタ塗り用）。網目までは写せないが「そこに面がある」ことは絵に残る。
    /// lo/hi の中点を返す（Solid はその色そのもの）。
    pub def representativeColor(spec: Spec): Color =
        match spec#out {
            case Out.Fill(f) => shadeColor(f#shade)
        }

    def shadeColor(shade: Shade): Color =
        match shade {
            case Shade.Solid(c) => c
            case Shade.Ramp(r)  =>
                { r = wide((f32(r#lo#r) + f32(r#hi#r)) / 2.0f32),
                  g = wide((f32(r#lo#g) + f32(r#hi#g)) / 2.0f32),
                  b = wide((f32(r#lo#b) + f32(r#hi#b)) / 2.0f32) }
            case Shade.Gradient(g) =>
                // field を評価せず、真ん中（f=0.5）の位置で stops を混ぜた色を返す。
                gradientColorAt(0.5, g#stops)
            case Shade.Cosine(cs) =>
                // GLSL を走らせない代表色は中心色 a（実際に巡回する色は GL でのみ出る）。
                cs#a
            case Shade.Rgb(_) =>
                // 場を評価しない代表色は中間灰 — テクスチャの中身はここでは読めない
                // （Cosine が a を返すのと同じ妥協）。
                { r = 0.5, g = 0.5, b = 0.5 }
        }

    /// 係数 f（0..1）で stops を混ぜた色。先頭色から始めて、隣り合う区切りごとに
    /// smoothstep(前の位置, 次の位置, f) の重みで次の色へ近づけていく（GPU/CPU 同じ数式）。
    def gradientColorAt(f: Float64, stops: List[(Float64, Color)]): Color =
        match stops {
            case Nil => { r = 0.0, g = 0.0, b = 0.0 }
            case (_, c0) :: rest =>
                let (col, _) = List.foldLeft((acc, sc) -> {
                    let (curCol, prevPos) = acc;
                    let (pos, col) = sc;
                    let w = smoothstepF(prevPos, pos, f);
                    (mixColorF(curCol, col, w), pos)
                }, (c0, firstPos(stops)), rest);
                col
        }

    def firstPos(stops: List[(Float64, Color)]): Float64 =
        match stops {
            case (p, _) :: _ => p
            case Nil         => 0.0
        }

    def mixColorF(a: Color, b: Color, t: Float64): Color =
        let tf = Float64.clampToFloat32(min = 0.0f32, max = 1.0f32, t);
        { r = wide(f32(a#r) + (f32(b#r) - f32(a#r)) * tf),
          g = wide(f32(a#g) + (f32(b#g) - f32(a#g)) * tf),
          b = wide(f32(a#b) + (f32(b#b) - f32(a#b)) * tf) }

    def f32(v: Float64): Float32 = RenderUtil.f32(v)

    def wide(v: Float32): Float64 = Float32.toFloat64(v)

    /// 場の木を前置順（親 → 子）で 1 本ずつ f に渡して畳み込む汎用の走査。
    /// Ref 集め（ShaderJson）と Tex 名集め（texNames）がこれに乗る — ノードを増やすときは
    /// ここへ 1 case 足せば全部の走査が追随する（走査を何本も別々に持たない）。
    pub def foldField(f: (a, Field) -> a, acc: a, field: Field): a =
        foldFieldScoped((a1, _, fl) -> f(a1, fl), FilterMode.Nearest, acc, field)

    /// foldField の、各節に「その節の tex / blur が読む補間」（Sampler の内側なら その filter）も渡す形。
    pub def foldFieldScoped(f: (a, FilterMode, Field) -> a, filter: FilterMode, acc: a, field: Field): a =
        let acc1 = f(acc, filter, field);
        let foldField = (_f, a0, child) -> foldFieldScoped(f, filter, a0, child);
        match field {
            case Field.Const(_)        => acc1
            case Field.Uv(_)           => acc1
            case Field.Worley(_)       => acc1
            case Field.Fbm(_)          => acc1
            case Field.FbmTile(_)      => acc1
            case Field.Smoothstep(s)   => foldField(f, acc1, s#of)
            case Field.Scaled(s)       => foldField(f, acc1, s#of)
            case Field.Warp(wp)        => foldField(f, acc1, wp#of)
            case Field.Mix(m)          => foldField(f, foldField(f, acc1, m#a), m#b)
            case Field.Blend(bl)       => foldField(f, foldField(f, foldField(f, acc1, bl#a), bl#b), bl#by)
            case Field.Disk(_)         => acc1
            case Field.Radial(_)       => acc1
            case Field.RadialAspect(_) => acc1
            case Field.Quantize(q)     => foldField(f, acc1, q#of)
            case Field.Scales(_)       => acc1
            case Field.Glints(_)       => acc1
            case Field.Ripples(_)      => acc1
            case Field.Sparkle(_)      => acc1
            case Field.Bin(bn)         => foldField(f, foldField(f, acc1, bn#a), bn#b)
            case Field.Hash1(h)        => match h#bucket {
                case None    => acc1
                case Some(b) => foldField(f, acc1, b)
            }
            case Field.Hash2(h)        => match h#bucket {
                case None    => acc1
                case Some(b) => foldField(f, acc1, b)
            }
            case Field.Un(un)          => foldField(f, acc1, un#of)
            case Field.Pow(pw)         => foldField(f, acc1, pw#of)
            case Field.Time(tm)        => foldField(f, acc1, tm#offset)
            case Field.Tiling(tl)      => foldField(f, acc1, tl#of)
            case Field.Snap(sn)        => foldField(f, acc1, sn#of)
            case Field.Swirl(sw)       => foldField(f, acc1, sw#of)
            case Field.Angle(_)        => acc1
            case Field.Rotate(rt)      => foldField(f, acc1, rt#of)
            case Field.Ref(_)          => acc1
            case Field.Tex(_)          => acc1
            case Field.Shift(sh)       => foldField(f, foldField(f, foldField(f, acc1, sh#dx), sh#dy), sh#of)
            case Field.TexBlur(bl)     => foldField(f, acc1, bl#amount)
            case Field.Sampler(sm)     => foldFieldScoped(f, sm#filter, acc1, sm#of)
            case Field.Param(_)        => acc1
            case Field.World(_)        => acc1
            case Field.Normal(_)       => acc1
        }

    /// Spec の tex / blur が読むテクスチャ名を f で書き換える（形は変えない）。
    /// Pass の中の読みを別名（history・見つからない名前）へ替えるのに使う（Render.resolvePassReads）。
    pub def renameTex(f: String -> String, spec: Spec): Spec =
        mapSpecFields(rewriteField(node -> match node {
            case Field.Tex(tx)     => Field.Tex({ name = f(tx#name) | tx })
            case Field.TexBlur(bl) => Field.TexBlur({ name = f(bl#name) | bl })
            case other             => other
        }), spec)

    /// Spec の全部の場（bindings・色・alpha）に g を掛ける（形は変えない）。
    def mapSpecFields(g: Field -> Field, spec: Spec): Spec =
        let (shade, alpha) = match spec#out {
            case Out.Fill(fill) => (mapShadeFields(g, fill#shade), g(fill#alpha))
        };
        { bindings = List.map(nf -> { let (n, fld) = nf; (n, g(fld)) }, spec#bindings),
          out = Out.Fill({ shade = shade, alpha = alpha }) | spec }

    /// 色の全部の場に g を掛ける（形は変えない）。
    def mapShadeFields(g: Field -> Field, shade: Shade): Shade =
        match shade {
            case Shade.Solid(c)     => Shade.Solid(c)
            case Shade.Ramp(r)      => Shade.Ramp({ field = g(r#field) | r })
            case Shade.Gradient(gr) => Shade.Gradient({ field = g(gr#field) | gr })
            case Shade.Cosine(cs)   => Shade.Cosine({ field = g(cs#field) | cs })
            case Shade.Rgb(c)       => Shade.Rgb({ r = g(c#r), g = g(c#g), b = g(c#b) })
        }

    /// 場の木を下から作り直し、各節に node を掛ける（子を先に作り直してから、その節に node）。
    def rewriteField(node: Field -> Field): Field -> Field = field ->
        let go = rewriteField(node);
        let rebuilt = match field {
            case Field.Const(_)        => field
            case Field.Uv(_)           => field
            case Field.Worley(_)       => field
            case Field.Fbm(_)          => field
            case Field.FbmTile(_)      => field
            case Field.Smoothstep(s)   => Field.Smoothstep({ of = go(s#of) | s })
            case Field.Scaled(s)       => Field.Scaled({ of = go(s#of) | s })
            case Field.Warp(wp)        => Field.Warp({ of = go(wp#of) | wp })
            case Field.Mix(m)          => Field.Mix({ a = go(m#a), b = go(m#b) | m })
            case Field.Blend(bl)       => Field.Blend({ a = go(bl#a), b = go(bl#b), by = go(bl#by) })
            case Field.Disk(_)         => field
            case Field.Radial(_)       => field
            case Field.RadialAspect(_) => field
            case Field.Quantize(q)     => Field.Quantize({ of = go(q#of) | q })
            case Field.Scales(_)       => field
            case Field.Glints(_)       => field
            case Field.Ripples(_)      => field
            case Field.Sparkle(_)      => field
            case Field.Bin(bn)         => Field.Bin({ a = go(bn#a), b = go(bn#b) | bn })
            case Field.Hash1(h)        => Field.Hash1({ bucket = Option.map(go, h#bucket) | h })
            case Field.Hash2(h)        => Field.Hash2({ bucket = Option.map(go, h#bucket) | h })
            case Field.Un(un)          => Field.Un({ of = go(un#of) | un })
            case Field.Pow(pw)         => Field.Pow({ of = go(pw#of) | pw })
            case Field.Time(tm)        => Field.Time({ offset = go(tm#offset) | tm })
            case Field.Tiling(tl)      => Field.Tiling({ of = go(tl#of) | tl })
            case Field.Snap(sn)        => Field.Snap({ of = go(sn#of) | sn })
            case Field.Swirl(sw)       => Field.Swirl({ of = go(sw#of) | sw })
            case Field.Angle(_)        => field
            case Field.Rotate(rt)      => Field.Rotate({ of = go(rt#of) | rt })
            case Field.Ref(_)          => field
            case Field.Tex(_)          => field
            case Field.Shift(sh)       => Field.Shift({ dx = go(sh#dx), dy = go(sh#dy), of = go(sh#of) })
            case Field.TexBlur(bl)     => Field.TexBlur({ amount = go(bl#amount) | bl })
            case Field.Sampler(sm)     => Field.Sampler({ of = go(sm#of) | sm })
            case Field.Param(_)        => field
            case Field.World(_)        => field
            case Field.Normal(_)       => field
        };
        node(rebuilt)

    /// Spec の場を「bindings（前から）→ 色 → alpha」の順に並べる。texNames と、場を全部見る走査はこの並びを使う。
    pub def fieldsOf(spec: Spec): List[Field] =
        let outFields = match spec#out {
            case Out.Fill(f) => List.append(shadeFieldsOf(f#shade), f#alpha :: Nil)
        };
        List.append(List.map(snd, spec#bindings), outFields)

    /// 色の場を並べる（Rgb は r → g → b）。
    def shadeFieldsOf(shade: Shade): List[Field] =
        match shade {
            case Shade.Solid(_)    => Nil
            case Shade.Ramp(r)     => r#field :: Nil
            case Shade.Gradient(g) => g#field :: Nil
            case Shade.Cosine(cs)  => cs#field :: Nil
            case Shade.Rgb(c)      => c#r :: c#g :: c#b :: Nil
        }

    /// Spec が読むテクスチャ名を「bindings（前から）→ 色 → alpha」の初出順・重複なしで列挙する。
    /// この並びが正典 — GLSL の uniform 番号・GL の sampler unit 番号・描画依頼の texNames が
    /// 全部この関数の並びを使うので、3 者がずれない。
    pub def texNames(spec: Spec): List[String] =
        List.foldLeft((acc, field) -> foldField((names, f) -> match f {
            case Field.Tex(tx) => if (List.memberOf(tx#name, names)) names else tx#name :: names
            case Field.TexBlur(bl) => if (List.memberOf(bl#name, names)) names else bl#name :: names
            case _             => names
        }, acc, field), Nil, fieldsOf(spec)) |> List.reverse

    /// Spec が読む (テクスチャ名, 補間) の組を「bindings（前から）→ 色 → alpha」の初出順・重複なしで列挙する。
    /// GLSL の uniform 番号・GL の sampler unit 番号・描画依頼の texReads が全部この並びを使う。sampler を使わない Spec では
    /// texNames と同じ並びに Nearest を添えた物になる（今ある Spec の GLSL を変えない）。
    pub def texReads(spec: Spec): List[(String, FilterMode)] =
        List.foldLeft((acc, field) -> foldFieldScoped((reads, filter, f) -> match f {
            case Field.Tex(tx)     => if (List.memberOf((tx#name, filter), reads)) reads else (tx#name, filter) :: reads
            case Field.TexBlur(bl) => if (List.memberOf((bl#name, filter), reads)) reads else (bl#name, filter) :: reads
            case _                 => reads
        }, FilterMode.Nearest, acc, field), Nil, fieldsOf(spec)) |> List.reverse

    /// Spec が読む Param の名前を「bindings（前から）→ 色 → alpha」の初出順・重複なしで列挙する。
    /// この並びが正典 — GLSL の uniform 番号（uParam0…）と、描画依頼・描き出しが渡す値の並びが全部これを使う。
    pub def paramNames(spec: Spec): List[String] = paramNamesIn(fieldsOf(spec))

    /// fields の順に、Param の名前を初出順・重複なしで。
    def paramNamesIn(fields: List[Field]): List[String] =
        List.foldLeft((acc, field) -> foldField((names, f) -> match f {
            case Field.Param(pm) => if (List.memberOf(pm#name, names)) names else pm#name :: names
            case _               => names
        }, acc, field), Nil, fields) |> List.reverse

    /// Param の名前に使える字か（英数字と '_'・1 字以上）。JSON の読みが確かめる。
    pub def paramNameOk(name: String): Bool =
        not String.isEmpty(name) and String.forAll(c -> Char.isLetterOrDigit(c) or c == '_', name)

    /// 面に渡された値の表から、Spec の Param の値を正典順に並べる（表に無い名前は 0）。
    pub def paramValues(spec: Spec, params: Map[String, Float64]): List[Float64] =
        paramNames(spec) |> List.map(n -> Map.getWithDefault(n, 0.0, params))

    /// Spec の Param を、値の表の値の Const に置き換える（表に無い名前は 0）。
    /// 描き出し（CPU）はこれを通した Spec を評価する — Const と同じ道で読むので、DrawHash の鍵にも値が入る
    /// （ShaderJson.toJson が値を書く）。GL は Spec を置き換えず uniform で渡す（値が変わっても program を作り直さない）。
    pub def bindParams(params: Map[String, Float64], spec: Spec): Spec =
        if (List.isEmpty(paramNames(spec))) spec
        else mapSpecFields(rewriteField(node -> match node {
            case Field.Param(pm) => Field.Const(Map.getWithDefault(pm#name, 0.0, params))
            case other           => other
        }), spec)

        /// 面に渡された値の表に無い Param の名前（知らせる物）。
    pub def missingParams(spec: Spec, params: Map[String, Float64]): List[String] =
        paramNames(spec) |> List.filter(n -> not Map.memberOf(n, params))

    /// この節が、子の場を自分の uv と違う uv で読むなら、その子（shift の dx・dy は今の uv で読むので入らない）。
    /// 場を足したらここへも 1 case 足す（wildcard を置かないのは、uv を曲げる場を足した時に黙らせないため）。
    pub def remappedChild(field: Field): Option[Field] =
        match field {
            case Field.Scaled(s)       => Some(s#of)
            case Field.Warp(wp)        => Some(wp#of)
            case Field.Tiling(tl)      => Some(tl#of)
            case Field.Snap(sn)        => Some(sn#of)
            case Field.Swirl(sw)       => Some(sw#of)
            case Field.Rotate(rt)      => Some(rt#of)
            case Field.Shift(sh)       => Some(sh#of)
            case Field.Const(_)        => None
            case Field.Uv(_)           => None
            case Field.Worley(_)       => None
            case Field.Fbm(_)          => None
            case Field.FbmTile(_)      => None
            case Field.Smoothstep(_)   => None
            case Field.Mix(_)          => None
            case Field.Blend(_)        => None
            case Field.Disk(_)         => None
            case Field.Radial(_)       => None
            case Field.RadialAspect(_) => None
            case Field.Quantize(_)     => None
            case Field.Scales(_)       => None
            case Field.Glints(_)       => None
            case Field.Ripples(_)      => None
            case Field.Sparkle(_)      => None
            case Field.Bin(_)          => None
            case Field.Hash1(_)        => None
            case Field.Hash2(_)        => None
            case Field.Un(_)           => None
            case Field.Pow(_)          => None
            case Field.Time(_)         => None
            case Field.Angle(_)        => None
            case Field.Ref(_)          => None
            case Field.Tex(_)          => None
            case Field.TexBlur(_)      => None
            case Field.Sampler(_)      => None
            case Field.Param(_)        => None
            case Field.World(_)        => None
            case Field.Normal(_)       => None
        }

    /// 負の指数の pow の底の下限（GLSL と CPU が同じ値を読む）。
    pub def negPowFloor(): Float64 = 0.000001

    /// 負の指数の pow の答えの上限。
    /// WhyNot: 上切りしないと、底が小さく指数が -7 以下の所で GPU（float32）は inf、CPU（float64）は有限になって割れる。
    pub def negPowCeil(): Float64 = 1000000.0

    /// taps を 1..64 に丸める（GLSL のループの上限と CPU の評価で同じ数を読む）。
    pub def blurTaps(taps: Int32): Int32 = Int32.max(1, Int32.min(64, taps))

    /// Spec がぼかし（TexBlur）を使うか（GLSL の sg_blur を宣言するか）。
    pub def usesBlur(spec: Spec): Bool =
        fieldsOf(spec) |> List.exists(field -> foldField((found, f) -> match f {
            case Field.TexBlur(_) => true
            case _                => found
        }, false, field))

    /// Spec が割り算（BinOp.Div）を使うか（GLSL の sg_div を宣言するか）。
    pub def usesDiv(spec: Spec): Bool =
        fieldsOf(spec) |> List.exists(field -> foldField((found, f) -> match f {
            case Field.Bin(bn) => found or bn#op == BinOp.Div
            case _             => found
        }, false, field))

    /// ベクトルの長さ。成分を並べて渡す（2 つなら xy、3 つなら xyz）。空なら 0。
    pub def lengthOf(parts: List[Field]): Field =
        let sum = parts
            |> List.map(p -> Field.Bin({ op = BinOp.Mul, a = p, b = p }))
            |> List.reduceLeft((a, b) -> Field.Bin({ op = BinOp.Add, a = a, b = b }))
            |> Option.getWithDefault(Field.Const(0.0));
        Field.Un({ op = UnOp.Sqrt, of = sum })

    /// 長さ 1 にそろえた成分。長さ 0 のベクトルは 0 のまま（Div の 0 割りの決まり）。
    /// WhyNot: 長さの式を成分ごとに複製する — 共通の式をまとめる仕組みが無い。重いなら長さを
    /// bindings に置いて Field.Ref で引く。
    pub def normalized(parts: List[Field]): List[Field] =
        let len = lengthOf(parts);
        parts |> List.map(p -> Field.Bin({ op = BinOp.Div, a = p, b = len }))

    // ── 3D の材質（Scene3d.Material3d）──

    /// field を、world の 2 軸 plane = (u に写す軸, v に写す軸) を uv として読ませる（Fbm・Worley など uv を読む場を
    /// 3D のメッシュの表面に貼る）。Shift のずらし量を「world − 今の uv」にするので、外側の uv が何でも world の値で読む。
    /// field の中の Ref（shared）は world を読まない — shared は面の基準 uv で 1 回だけ評価する決まりなので、
    /// atWorld は shared の定義の側に書く（`("rock", atWorld((Axis3.X, Axis3.Z), fbm))` の形）。
    /// WhyNot: World を uv の代わりに読む専用の場を足さない — Fbm・Worley・Hash… の全部に「どの座標を読むか」を
    /// 持たせることになる。uv を差し替える仕組み（Shift）がすでにある。
    pub def atWorld(plane: (Axis3, Axis3), field: Field): Field =
        let (onU, onV) = plane;
        Field.Shift({
            dx = Field.Bin({ op = BinOp.Sub, a = Field.World({ axis = onU }), b = Field.Uv({ axis = Axis.U }) }),
            dy = Field.Bin({ op = BinOp.Sub, a = Field.World({ axis = onV }), b = Field.Uv({ axis = Axis.V }) }),
            of = field })

    /// Spec が World か Normal を読むか（2D の面に置くと 0 になるので知らせる物）。
    pub def usesWorld3d(spec: Spec): Bool =
        fieldsOf(spec) |> List.exists(field -> foldField((found, f) -> match f {
            case Field.World(_)  => true
            case Field.Normal(_) => true
            case _               => found
        }, false, field))

    /// 材質（Spec と自分で光る色 emission）の中の Param の名前。Spec の paramNames の後ろに、emission にだけ出てくる名前を
    /// 初出順で足す。この並びが 3D の GLSL の uniform 番号（uParam0…）の正典（ShaderGen.compile3d）。
    pub def materialParamNames(spec: Spec, emission: Option[Shade]): List[String] =
        paramNamesIn(List.append(fieldsOf(spec), Option.getWithDefault(Nil, Option.map(shadeFieldsOf, emission))))

    /// 材質に渡された値の表から、materialParamNames の順に値を並べる（表に無い名前は 0）。
    pub def materialParamValues(spec: Spec, emission: Option[Shade], params: Map[String, Float64]): List[Float64] =
        materialParamNames(spec, emission) |> List.map(n -> Map.getWithDefault(n, 0.0, params))

    /// 色の Param を値の表の値の Const に置き換える（bindParams の色の版。emission を CPU で評価する前に通す）。
    pub def bindShadeParams(params: Map[String, Float64], shade: Shade): Shade =
        mapShadeFields(rewriteField(node -> match node {
            case Field.Param(pm) => Field.Const(Map.getWithDefault(pm#name, 0.0, params))
            case other           => other
        }), shade)

    /// Spec の tex / blur を 0 の Const に置き換える（3D の材質はテクスチャを読まない）。
    /// WhyNot: 3D の GLSL に tex の sampler を足さない — メッシュの画素に対応する uv が無く（vUv は 0）、
    /// どの点を読むかが決まらない。
    pub def withoutTextures(spec: Spec): Spec =
        if (List.isEmpty(texNames(spec))) spec else mapSpecFields(rewriteField(zeroTex), spec)

    /// 色の tex / blur を 0 の Const に置き換える（withoutTextures の色の版）。
    pub def shadeWithoutTextures(shade: Shade): Shade =
        mapShadeFields(rewriteField(zeroTex), shade)

    def zeroTex(node: Field): Field =
        match node {
            case Field.Tex(_)     => Field.Const(0.0)
            case Field.TexBlur(_) => Field.Const(0.0)
            case other            => other
        }

    def smoothstepF(lo: Float64, hi: Float64, x: Float64): Float64 =
        if (hi - lo == 0.0) (if (x < lo) 0.0 else 1.0)
        else {
            let tt = Float64.max(0.0, Float64.min(1.0, (x - lo) / (hi - lo)));
            tt * tt * (3.0 - 2.0 * tt)
        }
}
