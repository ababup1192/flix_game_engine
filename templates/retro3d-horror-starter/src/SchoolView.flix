// SchoolView — 夜の校舎を一人称で写す 3D の場面（純粋）。
//
// ── 絵の下限の 5 性質を、どこで満たすか ──
//   面に階調か質感 … 板張りの床・腰板・漆喰の絵（Nearest）と、頂点の色にベイクした月明かりのむら・距離の霧
//   主役が背景から分離 … 窓ぎわの青緑と非常口の緑の溜まりが浮き、部屋の隅と廊下の奥は闇に沈む
//   層が分かれている … 手前（ベイクした明るさの床）・中（壁・机・窓の月明かり）・奥（霧の闇）
//   時間が流れている … 歩くと頭が揺れる・非常口の灯りがわずかにゆらぐ
//   形が物として読める … 低いポリゴンの机・戸口・階段（glb か仮の箱）と、教室や部屋にいる人物（骨つきの glb・idle で揺れる）
// 描くのは 320×240 のまま（Resolution.Design）で、窓へは補間なしで拡げる。
mod SchoolView {
    use fge::{Camera3d, Color, Num, Scene3d, Texture3d, Vec2, Vec3}

    /// 描くのに要る値。部品は World でなくこれを読む（lint/rules.flix の view-no-world）。
    /// floors = 描く階の番号（今の階と上下 1 つ）・here = 今の階。
    /// people = 人物の置いた物（CastView が毎コマ組む骨つきの物）・props = 床の物と鍵の戸（ItemsView が毎コマ組む物）。
    pub type alias In = { t = Float64, pov = World.Pov, floors = List[Int32], here = Int32, look = LookDoc.Rec, school = School.School, layout = Layout.Layout,
                          people = List[Scene3d.Instance3d], props = List[Scene3d.Instance3d], peopleTextures = List[Texture3d.Texture3d] }

    def size(): Vec2.Vec2 = { x = World.width(), y = World.height() }

    /// 1 コマの場面。
    pub def sceneOf(v: In): Scene3d.Scene3dCmd =
        let l = v#look;
        let camera = cameraOf(v);
        { groups = v#floors |> List.filterMap(i -> Map.get(i, v#school#groups)),
          spotLights = if (l#flashlight#intensity > 0.0) flashlight(v, camera) :: Nil else Nil,
          pointLights = lamps(v),
          environment = { ambient = l#ambient, hemisphere = 0.0, toonSteps = 0,
                          fog = Some({ color = l#fog#color, near = l#fog#near, far = l#fog#far }), background = Some(l#fog#color) },
          resolution = Scene3d.Resolution.Design,
          instances = List.append(v#people, v#props),
          textures = List.append(v#school#textures, v#peopleTextures),
          time = v#t
        | Scene3d.scene(camera, size()) } |> Scene3d.withPsx(LookDoc.psxLookOf(l#psx))

    /// 目のカメラ（1 枚目と 2 枚目の場面で同じ物）。
    pub def cameraOf(v: In): Camera3d.Camera3d =
        let l = v#look;
        { near = 0.05, far = l#fog#far + 1.0 | Camera3d.camera(v#pov#eye, v#pov#yaw, v#pov#pitch, l#fovDeg * Num.pi() / 180.0) }

    /// 校舎の上に重ねる 2 枚目の場面（目の前の物だけ）: 同じカメラ・同じ PS1 風の描き方・灯りとかすみなし（環境光は白）・背景は抜く。
    /// 物には置いた部屋の明るさを tint で掛けてあるので、白の環境光で 1 枚目の部屋の明るさにそろう。
    pub def overlayOf(v: In, instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        let base = Scene3d.scene(cameraOf(v), size());
        { environment = { ambient = Color.rgb(1.0, 1.0, 1.0), hemisphere = 0.0, toonSteps = 0, fog = None, background = None },
          resolution = Scene3d.Resolution.Design, instances = instances, textures = v#school#textures, time = v#t, zIndex = base#zIndex + 2
        | base } |> Scene3d.withPsx(LookDoc.psxLookOf(v#look#psx))

    /// 懐中電灯: 目の右下に持ち、前の 5 m 先を照らす。歩くと 1 歩ごとに先が左右と上下に揺れる。
    def flashlight(v: In, camera: Camera3d.Camera3d): Scene3d.SpotLight =
        let f = v#look#flashlight;
        let eye = v#pov#eye;
        let forward = Camera3d.forward(camera);
        let right = Camera3d.right(camera);
        let up = Camera3d.up(camera);
        let phase = v#pov#walked * Num.pi() / 0.7;
        let swayX = f#sway * Num.sin(phase);
        let swayY = f#sway * 0.6 * Num.sin(phase * 2.0);
        let hand = Vec3.add(eye, Vec3.add(Vec3.mul(right, 0.15), Vec3.mul(up, -0.2)));
        let target = Vec3.add(eye, Vec3.add(Vec3.mul(forward, 5.0), Vec3.add(Vec3.mul(right, swayX * 5.0), Vec3.mul(up, swayY * 5.0))));
        let rad = Num.pi() / 180.0;
        { color = f#color, intensity = f#intensity, range = f#range, innerFovY = Some(f#innerDeg * rad)
        | Scene3d.spotLight(hand, target, f#fovDeg * rad) }

    /// 今の階の窓の月明かり（every 個に 1 つ）と、非常口の緑の灯り（わずかにゆらぐ）。8 本を超えた分は描き手が見ている向きで選ぶ。
    def lamps(v: In): List[Scene3d.PointLight] =
        let l = v#look;
        let mine = v#layout#lights |> List.filter(x -> x#floor == v#here);
        let moons = mine |> List.filter(x -> x#kind == Layout.LightKind.Moon)
            |> List.zipWithIndex |> List.filter(e -> Int32.modulo(fst(e), Int32.max(1, l#moon#every)) == 0)
            |> List.map(e -> { color = l#moon#color, intensity = l#moon#intensity | Scene3d.pointLight(snd(e)#pos, l#moon#range) });
        let exits = mine |> List.filter(x -> x#kind == Layout.LightKind.ExitGreen)
            |> List.zipWithIndex |> List.map(e -> {
                let flicker = 0.92 + 0.08 * Num.sin(v#t * 7.3 + Int32.toFloat64(fst(e)) * 2.1) * Num.sin(v#t * 1.9);
                { color = l#exit#color, intensity = l#exit#intensity * flicker | Scene3d.pointLight(snd(e)#pos, l#exit#range) }
            });
        List.append(exits, moons)
}
