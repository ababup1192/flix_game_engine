// RenderLint — 描画データの幾何破綻を機械検出する純関数リンタ（ゲーム非依存）。
//
// 「画像を描き出す過程のレイアウトを、人間が PNG を見て被りを見つける前に、幾何データで検出する」ための
// 検査器。入力は構造レコード（要素の bbox 列・親子関係・画面寸法）だけで、ゲーム固有の型を一切
// import しない汎用パーツ。ゲーム側の World/UI 状態を Input へ橋渡しするのは呼び出し側の責務。
//
// ルールは 3 本（精度重視・偽陽性を出さない側を選ぶ。閾値はすべて定数化して報告に載せる）:
//   R1 text×text 交差 : 可視テキスト同士の bbox が重なる（同一シーン内・z-index の範囲問わず。文字が別の文字に
//                       被るのは常に不具合）。粒度は「1 テキスト要素 = 1 run」（スナップショットの色・z 集約は
//                       別ラベルまで融合するのでリンタでは使わず、要素単位で見る）。
//   R2 親はみ出し     : テキスト要素の bbox が、階層上の直近の box 祖先（パネル）の rect からはみ出す。
//   R3 画面外/超過    : 可視要素の bbox が design 画面を大きく超える。
//
// 検出した違反は Finding。抑制タグ（allow）に該当する rule は suppressed=true を立てて返す
// （黙殺せず「抑制済み」として別掲するため。呼び側が suppressed で振り分ける）。
pub mod RenderLint {

    /// 要素の描画種別（リンタ内の分類。ゲームの widget 名とは独立）。
    pub enum Kind with Eq {
        case Text
        case Box
        case Sprite
        case Poly
    }

    /// 軸並行の外接矩形（design px・左上原点）。
    pub type alias Rect = { minX = Float64, minY = Float64, maxX = Float64, maxY = Float64 }

    /// 検査対象の 1 要素。
    /// `path`: 名前パス（報告の識別子）。`kind`: 種別。`z`: 重なり順（報告用）。
    /// `bbox`: 実際に描かれる外接矩形。`ancestors`: 直近の親から root までの祖先名パス列
    ///   （nearest-first）。R2 が「直近の box 祖先」を引くのに使う。
    pub type alias Element = {
        path = String,
        kind = Kind,
        z = Int32,
        bbox = Rect,
        ancestors = List[String]
    }

    /// 1 シーンぶんの検査入力。
    /// `allow`: 抑制する rule 名（"R1"/"R2"/"R3"）。カタログの `lint-allow:Rx` タグ由来。
    pub type alias Input = {
        sceneName = String,
        screenW   = Float64,
        screenH   = Float64,
        elements  = List[Element],
        allow     = List[String]
    }

    /// 検出 1 件。`suppressed` が true なら allow で抑制済み（fail させず別掲する）。
    pub type alias Finding = {
        rule       = String,
        sceneName  = String,
        path       = String,
        detail     = String,
        severity   = String,
        suppressed = Bool
    }

    // ── 閾値（すべて定数。報告文にも埋め込む）──

    /// R1: この px を超えて**両軸で**重なったときだけ交差とみなす。
    /// text の bbox は measure（実寸）で、フォントの行間（leading）ぶん実グリフより縦にわずかに大きい。
    /// 縦積みの隣接行（ログの 3 行・戦闘予報の攻/防 2 行・レベルアップの隣接ステータス行）は測定箱が
    /// 最大 1.0px だけ食い合うが実グリフは衝突しない。一方、実際のラベル被り（要素が丸ごとずれて別の
    /// ブロックへ食い込む）は 1.5px 以上重なる（レベルアップ footer を旧 y=66 へ戻すと本文列と 1.50px
    /// 交差する = 実バグ）。両者の谷間 1.25px を閾値に置き、leading ノイズは通し実被りだけ拾う
    /// （偽陽性を出さない側を選ぶ）。
    pub def textOverlapEpsilon(): Float64 = 1.25

    /// R2: 角丸・枠線の内側食い込みは誤差として許す上限（これを超えるはみ出しだけ報告）。
    pub def panelOverflowEpsilon(): Float64 = 1.0

    /// R3: 画面外へこの px を超えて出たときだけ報告する（端に接する HUD の誤検出を避ける）。
    pub def screenMarginPx(): Float64 = 2.0

    // ════════════════════════════════════════════════════════
    // エントリポイント
    // ════════════════════════════════════════════════════════

    /// 全ルールを走らせ、抑制フラグを立てた Finding 列を返す（宣言順 R1→R2→R3）。
    pub def check(input: Input): List[Finding] =
        let raw = List.append(checkR1(input), List.append(checkR2(input), checkR3(input)));
        List.map(f -> markSuppressed(input#allow, f), raw)

    /// allow に rule が含まれれば suppressed=true にする。
    def markSuppressed(allow: List[String], f: Finding): Finding =
        if (List.memberOf(f#rule, allow)) {suppressed = true | f} else f

    // ════════════════════════════════════════════════════════
    // R1 — text × text 交差
    // ════════════════════════════════════════════════════════

    /// 可視テキスト要素の全ペアを外接矩形で突き合わせ、両軸で重なるペアを報告する。
    def checkR1(input: Input): List[Finding] =
        let texts = input#elements |> List.filter(e -> e#kind == Kind.Text and nonDegenerate(e#bbox));
        pairsOf(texts)
            |> List.filterMap(pair -> {
                let (a, b) = pair;
                let ov = overlap(a#bbox, b#bbox);
                if (ov#x > textOverlapEpsilon() and ov#y > textOverlapEpsilon())
                    Some(({rule = "R1", sceneName = input#sceneName, path = "${a#path} × ${b#path}",
                           detail = "テキストが重なる: '${a#path}' (z=${a#z}) と '${b#path}' (z=${b#z}) が "
                               + "${fmt(ov#x)}×${fmt(ov#y)}px 交差 [閾値 ${fmt(textOverlapEpsilon())}px]",
                           severity = "error", suppressed = false}: Finding))
                else None
            })

    // ════════════════════════════════════════════════════════
    // R2 — テキストの親（直近の box 祖先）はみ出し
    // ════════════════════════════════════════════════════════

    /// 各テキストについて、祖先を nearest-first に辿り最初に見つかる box のパネル rect を親とみなし、
    /// その外へ panelOverflowEpsilon を超えて出ていれば報告する。box 祖先が無いテキストは対象外
    /// （パネルとテキストが兄弟配置の UI では R2 は成立しない — R1 が被りを拾う）。
    def checkR2(input: Input): List[Finding] =
        let boxBy = boxByPath(input#elements);
        input#elements
            |> List.filter(e -> e#kind == Kind.Text and nonDegenerate(e#bbox))
            |> List.filterMap(t -> nearestBox(t#ancestors, boxBy) |> Option.flatMap(pair -> {
                let (boxPath, boxRect) = pair;
                let over = overflowOutside(t#bbox, boxRect);
                if (over#amount > panelOverflowEpsilon())
                    Some(({rule = "R2", sceneName = input#sceneName, path = t#path,
                           detail = "テキスト '${t#path}' がパネル '${boxPath}' から ${over#side}方向へ "
                               + "${fmt(over#amount)}px はみ出し [閾値 ${fmt(panelOverflowEpsilon())}px]",
                           severity = "error", suppressed = false}: Finding))
                else None
            }))

    /// path→box rect の対応表（box 要素だけ）。
    def boxByPath(elements: List[Element]): Map[String, Rect] =
        elements
            |> List.filter(e -> e#kind == Kind.Box)
            |> List.foldLeft((acc, e) -> Map.insert(e#path, e#bbox, acc), Map.empty())

    /// 祖先パス列（nearest-first）から最初に box 表に載るものを返す。
    def nearestBox(ancestors: List[String], boxBy: Map[String, Rect]): Option[(String, Rect)] =
        match ancestors {
            case Nil        => None
            case p :: rest  => match Map.get(p, boxBy) {
                case Some(r) => Some((p, r))
                case None    => nearestBox(rest, boxBy)
            }
        }

    // ════════════════════════════════════════════════════════
    // R3 — 画面外/超過
    // ════════════════════════════════════════════════════════

    /// 可視要素の bbox が design 画面 (0,0)-(W,H) を screenMarginPx 超えて出ていれば報告する。
    def checkR3(input: Input): List[Finding] =
        let screen = {minX = 0.0, minY = 0.0, maxX = input#screenW, maxY = input#screenH};
        input#elements
            |> List.filter(e -> nonDegenerate(e#bbox))
            |> List.filterMap(e -> {
                let over = overflowOutside(e#bbox, screen);
                if (over#amount > screenMarginPx())
                    Some(({rule = "R3", sceneName = input#sceneName, path = e#path,
                           detail = "${kindLabel(e#kind)} '${e#path}' が画面(${fmt(input#screenW)}×"
                               + "${fmt(input#screenH)})の${over#side}外へ ${fmt(over#amount)}px 超過 "
                               + "[閾値 ${fmt(screenMarginPx())}px]",
                           severity = "warn", suppressed = false}: Finding))
                else None
            })

    // ════════════════════════════════════════════════════════
    // 幾何ヘルパ（純粋）
    // ════════════════════════════════════════════════════════

    /// bbox が実面積を持つ（潰れていない）か。空テキスト等の 0 面積を検査から外す。
    def nonDegenerate(r: Rect): Bool = r#maxX - r#minX > 0.01 and r#maxY - r#minY > 0.01

    /// 2 矩形の各軸の重なり幅（負なら離れている）。
    def overlap(a: Rect, b: Rect): {x = Float64, y = Float64} =
        {x = Float64.min(a#maxX, b#maxX) - Float64.max(a#minX, b#minX),
         y = Float64.min(a#maxY, b#maxY) - Float64.max(a#minY, b#minY)}

    /// inner が outer の外へどれだけ出ているか（最大辺の量と方向）。0 なら内包。
    def overflowOutside(inner: Rect, outer: Rect): {amount = Float64, side = String} =
        let left   = outer#minX - inner#minX; // >0: 左へはみ出し
        let right  = inner#maxX - outer#maxX;
        let top    = outer#minY - inner#minY;
        let bottom = inner#maxY - outer#maxY;
        let cands = ("左", left) :: ("右", right) :: ("上", top) :: ("下", bottom) :: Nil;
        List.foldLeft((best, c) -> {
            let (side, amt) = c;
            if (amt > best#amount) {amount = amt, side = side} else best
        }, {amount = 0.0, side = "-"}, cands)

    /// 全ペア（i<j・順不同 1 回ずつ）。
    def pairsOf(xs: List[a]): List[(a, a)] =
        match xs {
            case Nil       => Nil
            case h :: rest => List.append(List.map(y -> (h, y), rest), pairsOf(rest))
        }

    def kindLabel(k: Kind): String = match k {
        case Kind.Text   => "テキスト"
        case Kind.Box    => "ボックス"
        case Kind.Sprite => "スプライト"
        case Kind.Poly   => "ポリゴン"
    }

    /// Float64 を小数2桁固定に（報告文の数値ノイズを抑える）。
    def fmt(x: Float64): String =
        let neg = x < 0.0;
        let a = Float64.abs(x);
        let scaled = Float64.tryToInt32(a * 100.0 + 0.5) |> Option.getWithDefault(0i32);
        let ip = scaled / 100i32;
        let fp = scaled - ip * 100i32;
        let body = if (fp < 10i32) "${ip}.0${fp}" else "${ip}.${fp}";
        if (neg and scaled != 0i32) "-${body}" else body
}
