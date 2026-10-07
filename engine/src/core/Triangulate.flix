/// Triangulate — 単純多角形（自己交差しない・凹あり可）を三角形の列に分割する耳切り法。
/// GL の塗り（GL_TRIANGLES）と SoftRaster（スキャンライン）の絵を一致させるための芯:
/// ファン分割は凸専用で、星のような凹多角形では凹みを跨いで塗ってしまう。
/// 純粋関数なので、面積保存（分割前後で面積が変わらない）をテストで釘打ちできる。
/// 計算量は O(n²)。ゲームの多角形は数十頂点なので毎フレームでも問題にならない。
pub mod Triangulate {

    /// 多角形を三角形に分割する。3頂点未満は空。凸なら n−2 枚（ファンと同じ枚数）。
    /// 数値退化（重なった頂点など）で耳が一周見つからないときは、残りをファンで閉じて
    /// 必ず停止する（クラッシュや無限ループより「多少の描き崩れ」を選ぶ）。
    /// 凸多角形は先頭からのファンで分割する — 凸なら耳判定（各頂点で残り全点の内包チェック）を
    /// 回さずに正しく割れるので O(n²) が O(n) に落ちる。四角形・箱・影四角形・多くの壁タイルは
    /// 凸なので、画面に多角形が数千枚出る場面（暗い洞窟の影）ではここが効く。凹（星形など）は
    /// ファンが凹みを跨いで塗るため従来の耳切りに回す。
    pub def triangles(points: List[Vec2.Vec2]): List[(Vec2.Vec2, Vec2.Vec2, Vec2.Vec2)] =
        if (List.length(points) < 3) Nil
        else {
            // 向きを正規化: 符号付き面積が正（この式では反時計回り）に揃えて耳判定の符号を固定する。
            let oriented = if (signedArea(points) < 0.0) List.reverse(points) else points;
            if (isConvex(oriented)) fan(oriented) else clip(oriented, Nil, 0)
        }

    /// 反時計回りに正規化済みの多角形が凸か。全ての連続する3点の曲がりが左回り（外積>=0）なら凸。
    /// ちょうど0（一直線）は凸に含める — ファンでは退化三角形（面積0）になり塗りに影響しない。
    /// 少しの負まで許すのは、隣り合う辺がほぼ一直線のときの丸め誤差で凹と誤判定しないため。
    /// Vector や添字の列を作らないのは、毎フレーム多角形ごとに呼ばれる入口で、
    /// 判定 1 回のための一時確保が多角形の数だけ積み上がるため（1 巡の再帰で同じ角を見る）。
    def isConvex(ps: List[Vec2.Vec2]): Bool =
        match ps {
            case p0 :: p1 :: rest => convexFrom(p0, p1, p0, p1, rest)
            case _                => true
        }

    /// 隣り合う 3 点 (a, b, c) の角を先頭から 1 巡見る。first0 / first1 は列の先頭 2 点で、
    /// 末尾まで来たら (末尾−1, 末尾, first0) と (末尾, first0, first1) の巻き戻りの 2 角を見る
    /// （添字の modulo で一周するのと同じ角の集合）。
    def convexFrom(first0: Vec2.Vec2, first1: Vec2.Vec2, a: Vec2.Vec2, b: Vec2.Vec2,
                   rest: List[Vec2.Vec2]): Bool =
        match rest {
            case c :: more =>
                if (leftTurn(a, b, c)) convexFrom(first0, first1, b, c, more) else false
            case Nil       => leftTurn(a, b, first0) and leftTurn(b, first0, first1)
        }

    /// 曲がりが左回り（一直線と丸め誤差ぶんの負まで含む）か。
    def leftTurn(a: Vec2.Vec2, b: Vec2.Vec2, c: Vec2.Vec2): Bool =
        cross(a, b, c) >= -0.000000001

    /// 耳切り本体。先頭3点 (a, b, c) が耳なら b を落として三角形を積み、
    /// 耳でなければ列を1つ回して次の候補を見る。guard が一周ぶん回ったら退化とみなす。
    def clip(ps: List[Vec2.Vec2], acc: List[(Vec2.Vec2, Vec2.Vec2, Vec2.Vec2)],
             guard: Int32): List[(Vec2.Vec2, Vec2.Vec2, Vec2.Vec2)] =
        match ps {
            case a :: b :: c :: Nil => List.reverse((a, b, c) :: acc)
            case a :: b :: c :: rest =>
                if (guard > List.length(ps))
                    List.append(List.reverse(acc), fan(ps))
                else if (isEar(a, b, c, rest))
                    clip(a :: c :: rest, (a, b, c) :: acc, 0)
                else
                    clip(List.append(b :: c :: rest, a :: Nil), acc, guard + 1)
            case _ => List.reverse(acc)
        }

    /// (a,b,c) が耳か: 角が凸（外積 > 0）で、残りの頂点がどれも三角形の中に入っていない。
    def isEar(a: Vec2.Vec2, b: Vec2.Vec2, c: Vec2.Vec2, rest: List[Vec2.Vec2]): Bool =
        cross(a, b, c) > 0.000000001 and not List.exists(p -> inTriangle(a, b, c, p), rest)

    /// 退化時の逃げ道: 先頭からのファン分割（凸なら正しい・凹なら従来と同じ描き崩れ）。
    def fan(ps: List[Vec2.Vec2]): List[(Vec2.Vec2, Vec2.Vec2, Vec2.Vec2)] =
        match ps {
            case p0 :: p1 :: rest =>
                let (tris, _last) = List.foldLeft((acc0, p) -> {
                    let (ts, prev) = acc0;
                    ((p0, prev, p) :: ts, p)
                }, (Nil, p1), rest);
                List.reverse(tris)
            case _ => Nil
        }

    /// 符号付き面積（靴ひも公式）。正なら run が使う向き。
    pub def signedArea(points: List[Vec2.Vec2]): Float64 =
        match points {
            case p0 :: rest =>
                let (sum, last) = List.foldLeft((acc0, p) -> {
                    let (s, prev) = acc0;
                    (s + (prev#x * p#y - p#x * prev#y), p)
                }, (0.0, p0), rest);
                (sum + (last#x * p0#y - p0#x * last#y)) / 2.0
            case Nil => 0.0
        }

    /// (b−a)×(c−a) の z 成分。正なら正規化後の向きで凸角。
    def cross(a: Vec2.Vec2, b: Vec2.Vec2, c: Vec2.Vec2): Float64 =
        (b#x - a#x) * (c#y - a#y) - (b#y - a#y) * (c#x - a#x)

    /// p が三角形 (a,b,c) の内側（境界は外扱い）にあるか。3辺との外積の符号が揃えば内側。
    def inTriangle(a: Vec2.Vec2, b: Vec2.Vec2, c: Vec2.Vec2, p: Vec2.Vec2): Bool =
        let d1 = cross(a, b, p);
        let d2 = cross(b, c, p);
        let d3 = cross(c, a, p);
        (d1 > 0.0 and d2 > 0.0 and d3 > 0.0) or (d1 < 0.0 and d2 < 0.0 and d3 < 0.0)
}
