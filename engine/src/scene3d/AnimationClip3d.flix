// AnimationClip3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// アニメーションクリップ（閉じた型 — make が確かめた物だけ）。ジョイントごと・欄（平行移動 / 回転 / 倍率）ごとのキーフレームの列。
pub mod AnimationClip3d {

    /// キーフレームの間のつなぎ方。Linear = 2 つの値の間をなめらかにつなぐ（回転は球面の上で）・Step = 次のキーフレームまで前の値のまま。
    pub enum Interpolation with Eq {
        case Linear
        case Step
    }

    /// どの欄を動かすか。値の幅は Translation・Scale が 3、Rotation が 4（x, y, z, w）。
    pub enum Path with Eq {
        case Translation
        case Rotation
        case Scale
    }

    /// 1 本の欄。joint = スキンの中の番号・times = キーフレームの秒（増える順）・values = 時刻ごとに幅の数だけ並べた値。
    pub type alias Channel = { joint = Int32, path = Path, times = Vector[Float64], values = Vector[Float64], interpolation = Interpolation }

    /// byJoint = キーフレームのある欄をジョイントの番号ごとに分けた物（make に渡した並びのまま）。
    // WhyNot: sample のたびに分けない — 群れの姿勢で 1 コマに何十回も引かれ、分け直しが補間より重くなる。
    type alias ClipRec = { name = String, byJoint = Map[Int32, List[Channel]], duration = Float64 }

    enum ClipData { case ClipData(ClipRec) }

    pub type alias AnimationClip3d = ClipData

    def recOf(c: AnimationClip3d): ClipRec = let ClipData.ClipData(r) = c; r

    def widthOf(path: Path): Int32 = match path {
        case Path.Rotation => 4
        case _ => 3
    }

    /// 欄の列から作る。times が増える順でない・values の数が times の数 × 幅でない・joint が負の欄は Err。
    /// Rotation の値は長さ 1 に直す。joint がスキンの数を超える欄は sample が捨てる（ここではスキンを知らない）。
    pub def make(name: String, channels: List[Channel]): Result[String, AnimationClip3d] =
        channels
            |> List.map(checkChannel(name))
            |> List.sequence
            |> Result.map(checked -> ClipData.ClipData({
                name = name,
                byJoint = checked
                    |> List.filter(ch -> Vector.length(ch#times) > 0)
                    |> List.foldLeft((m, ch) -> Map.insertWith((_new, old) -> List.append(old, ch :: Nil), ch#joint, ch :: Nil, m), Map.empty()),
                duration = checked |> List.filterMap(ch -> Vector.last(ch#times)) |> List.foldLeft(Float64.max, 0.0)
            }))

    def checkChannel(clipName: String, ch: Channel): Result[String, Channel] =
        let count = Vector.length(ch#times);
        let width = widthOf(ch#path);
        let increasing = Vector.range(1, count) |> Vector.forAll(i -> Vector.get(i - 1, ch#times) < Vector.get(i, ch#times));
        if (ch#joint < 0) Err("AnimationClip3d ${clipName}: joint が負（${ch#joint}）")
        else if (not increasing) Err("AnimationClip3d ${clipName}: joint ${ch#joint} の times が増える順でない")
        else if (Vector.length(ch#values) != count * width)
            Err("AnimationClip3d ${clipName}: joint ${ch#joint} の values が ${Vector.length(ch#values)} 個（${count} × ${width} 個のはず）")
        else if (width == 4) Ok({ values = normalizeRotations(ch#values) | ch })
        else Ok(ch)

    def normalizeRotations(values: Vector[Float64]): Vector[Float64] =
        Vector.range(0, Vector.length(values) / 4) |> Vector.flatMap(k -> {
            let q = Quat.normalized(quatAt(values, k));
            Vector#{ q#x, q#y, q#z, q#w }
        })

    pub def name(c: AnimationClip3d): String = recOf(c)#name

    /// 全部の欄の最後のキーフレームの時刻（欄が無ければ 0）。
    pub def duration(c: AnimationClip3d): Float64 = recOf(c)#duration

    /// 時刻 t（秒）の局所の姿勢（ジョイントの数だけ）。loop が真なら t を duration で回し（duration が 0 なら 0）、偽なら最後のキーフレームで止める。
    /// 最初のキーフレームより前は最初の値。キーフレームの無い欄はレストポーズ。同じジョイントの同じ欄が 2 本あれば後ろの欄。
    pub def sample(skin: Skin3d.Skin3d, clip: AnimationClip3d, t: Float64, loop: Bool): Vector[Skin3d.JointPose] =
        let r = recOf(clip);
        let local = if (not loop) t
                    else if (r#duration <= 0.0) 0.0
                    else t - Float64.floor(t / r#duration) * r#duration;
        Skin3d.restPose(skin) |> Vector.mapWithIndex((i, rest) ->
            Map.get(i, r#byJoint) |> Option.getWithDefault(Nil) |> List.foldLeft((pose, ch) -> applyChannel(local, ch, pose), rest))

    def applyChannel(t: Float64, ch: Channel, pose: Skin3d.JointPose): Skin3d.JointPose =
        let (k, frac) = keyAt(ch#times, t);
        let next = Int32.min(k + 1, Vector.length(ch#times) - 1);
        let mix = match ch#interpolation {
            case Interpolation.Linear => frac
            case Interpolation.Step => 0.0
        };
        match ch#path {
            case Path.Translation => { translation = lerpVec3(vec3At(ch#values, k), vec3At(ch#values, next), mix) | pose }
            case Path.Scale => { scale = lerpVec3(vec3At(ch#values, k), vec3At(ch#values, next), mix) | pose }
            case Path.Rotation => { rotation = Quat.slerp(quatAt(ch#values, k), quatAt(ch#values, next), mix) | pose }
        }

    /// t の直前のキーフレームの番号と、次のキーフレームまでの進み（0〜1）。最初より前は (0, 0)・最後から後は (最後, 0)。
    // WhyNot: 頭から順に探さない — 長いクリップを毎コマ全部のジョイントで引くと、キーフレームの数に比例して重くなる。
    def keyAt(times: Vector[Float64], t: Float64): (Int32, Float64) =
        let last = Vector.length(times) - 1;
        if (t <= Vector.get(0, times)) (0, 0.0)
        else if (t >= Vector.get(last, times)) (last, 0.0)
        else {
            let k = searchKey(times, t, 0, last);
            let t0 = Vector.get(k, times);
            let t1 = Vector.get(k + 1, times);
            (k, (t - t0) / (t1 - t0))
        }

    // times[low] <= t < times[high] を保ったまま狭める。
    def searchKey(times: Vector[Float64], t: Float64, low: Int32, high: Int32): Int32 =
        if (high - low <= 1) low
        else {
            let mid = (low + high) / 2;
            if (Vector.get(mid, times) <= t) searchKey(times, t, mid, high) else searchKey(times, t, low, mid)
        }

    def lerpVec3(a: Vec3.Vec3, b: Vec3.Vec3, t: Float64): Vec3.Vec3 = Vec3.add(a, Vec3.mul(Vec3.sub(b, a), t))

    def vec3At(values: Vector[Float64], k: Int32): Vec3.Vec3 =
        Vec3.v3(Vector.get(k * 3, values), Vector.get(k * 3 + 1, values), Vector.get(k * 3 + 2, values))

    def quatAt(values: Vector[Float64], k: Int32): Quat.Quat =
        { x = Vector.get(k * 4, values), y = Vector.get(k * 4 + 1, values), z = Vector.get(k * 4 + 2, values), w = Vector.get(k * 4 + 3, values) }
}
