// CastView — 校舎にいる人物を 3D の場面に置く（純粋）。骨つきの glb なので staticGroup に入れず、毎コマ instances に置く。
// 姿勢は idle を人物ごとに時刻をずらして流す。話している相手（と話し終えて戻る途中の相手）は体ごとプレイヤーへ回し、残りを首（neck と head）で回す（Cast.facingOf）。
// 話している間は台詞の行ごとに身振りのアニメを idle に混ぜる（Cast.gestureOf）。
// WhyNot: 首を向けるのに turn_head の動きを流さない — glb の turn_head は首を決まった片側へ回すだけで、プレイヤーのいる側へ向けられない。
//   idle の姿勢の首の回転に、プレイヤーの向きの角を足す。
mod CastView {
    use fge::{AnimationClip3d, Mat4, Model3d, Num, Pose3d, Quat, Scene3d, Skin3d, Vec3}

    /// 描くのに要る値。attention = 最後に話しかけた相手の記録（話していなくても、戻り切るまで使う）・player = プレイヤーの足元。
    pub type alias In = { t = Float64, cast = CastDoc.Doc, people = Map[String, Model3d.Model3d], floors = List[Int32], layout = Layout.Layout,
                          attention = Option[Cast.Attention], player = Vec3.Vec3 }

    /// 描く階にいる人物の、置いた物の列。
    pub def instancesOf(v: In): List[Scene3d.Instance3d] =
        CastDoc.rec(v#cast)#members |> List.zipWithIndex |> List.filter(e -> List.memberOf(Layout.floorIndexAt(snd(e)#feet#y, v#layout), v#floors))
            |> List.flatMap(e -> {
                let (i, m) = e;
                Map.get(m#model, v#people) |> Option.map(model -> placed(v, i, m, model)) |> Option.getWithDefault(Nil)
            })

    def placed(v: In, i: Int32, m: CastDoc.Member, model: Model3d.Model3d): List[Scene3d.Instance3d] =
        let mine = v#attention |> Option.filter(a -> a#who == m#id);
        let facing = mine |> Option.map(a -> Cast.facingOf(v#cast, m, v#player, v#t, a)) |> Option.getWithDefault({ body = 0.0, head = 0.0 });
        let world = Mat4.mul(Mat4.translate(m#feet), Mat4.rotateY(m#yaw + facing#body));
        // WhyNot: 人物に頂点の色をベイクしない — 骨で動く形はベイクした所から離れる。立っている部屋のベイクした明るさを掛け、暗い部屋で浮かないようにする。
        let parts = Model3d.partInstances(world, model) |> List.map(Scene3d.withTint(Layout.shadeAt(m#feet, v#layout)));
        match model#skin {
            case None       => parts
            case Some(skin) =>
                let idle = idleOf(skin, model, v#t + Int32.toFloat64(i) * 1.37);
                let gesture = mine |> Option.flatMap(a -> Cast.gestureOf(v#cast, m, v#t, a));
                let body = gesture |> Option.map(g -> withGesture(skin, model, CastDoc.rec(v#cast)#gestureFadeSec, g, idle)) |> Option.getWithDefault(idle);
                let pose = Pose3d.compute(skin, withHeadTurn(skin, facing#head, body));
                parts |> List.map(Scene3d.withPose(pose))
        }

    /// 身振りのアニメを idle に混ぜる。頭と終わりの fade 秒で重みを 0 から上げ、0 へ下げる（アニメが無い・終わった後は idle のまま）。
    def withGesture(skin: Skin3d.Skin3d, model: Model3d.Model3d, fade: Float64, g: Cast.Gesture, idle: Vector[Skin3d.JointPose]): Vector[Skin3d.JointPose] =
        match Map.get(g#clip, model#clips) {
            case Some(clip) if g#t < AnimationClip3d.duration(clip) =>
                let f = Float64.max(0.01, fade);
                let w = Num.clamp01(g#t / f) * Num.clamp01((AnimationClip3d.duration(clip) - g#t) / f) * g#weight;
                Pose3d.blend(idle, AnimationClip3d.sample(skin, clip, g#t, false), w)
            case _ => idle
        }

    /// idle の局所の姿勢（idle が無ければ休みの姿勢）。
    def idleOf(skin: Skin3d.Skin3d, model: Model3d.Model3d, t: Float64): Vector[Skin3d.JointPose] =
        Map.get("idle", model#clips) |> Option.map(c -> AnimationClip3d.sample(skin, c, t, true)) |> Option.getWithDefault(Skin3d.restPose(skin))

    /// 首（neck）と頭（head）に、縦の軸まわりの回転を半分ずつ足す。
    // WhyNot: 符号を反転する — glb の骨は glTF の座標で、engine は X を反転して読むので、engine の向きの角は骨の中では逆回りになる。
    def withHeadTurn(skin: Skin3d.Skin3d, angle: Float64, local: Vector[Skin3d.JointPose]): Vector[Skin3d.JointPose] =
        if (angle == 0.0) local
        else {
            let half = 0.0 - angle / 2.0;
            let q = { x = 0.0, y = Num.sin(half / 2.0), z = 0.0, w = Num.cos(half / 2.0) };
            let joints = ("neck" :: "head" :: Nil) |> List.filterMap(name -> Skin3d.jointIndex(skin, name)) |> List.toSet;
            local |> Vector.mapWithIndex((j, p) -> if (Set.memberOf(j, joints)) { rotation = Quat.normalized(mul(p#rotation, q)) | p } else p)
        }

    /// 四元数の積 a × b（b の回転の後に a の回転）。
    def mul(a: Quat.Quat, b: Quat.Quat): Quat.Quat =
        { x = a#w * b#x + a#x * b#w + a#y * b#z - a#z * b#y,
          y = a#w * b#y - a#x * b#z + a#y * b#w + a#z * b#x,
          z = a#w * b#z + a#x * b#y - a#y * b#x + a#z * b#w,
          w = a#w * b#w - a#x * b#x - a#y * b#y - a#z * b#z }
}
