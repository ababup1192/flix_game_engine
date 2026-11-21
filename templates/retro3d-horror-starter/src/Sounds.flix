// Sounds — 夜の校舎の音（どの音をいつ鳴らすか。純粋）。音の中身は make sfx が assets/sfx/ に書く
// （どれも src/render/SfxRender.flix の合成音）。曲（BGM）は鳴らさない。
// 起きた音は前後の World から名前を導き、続く音（空気と時計）は今の World から宣言する。
mod Sounds {
    use fge::{App, AudioMixer, Hash01, Num, Vec3}

    /// 足音の種類の数（step_0..）。
    def stepKinds(): Int32 = 6

    /// 風をときどき重ねる間（秒）。この長さの区切りごとに 1 回、区切りの中の決まった（番号から引いた）時刻に鳴らす。
    def windEvery(): Float64 = 45.0

    /// 起きた音: 紙のマップを開いた・閉じた（紙）・1 歩進んだ（足音 6 種を順に）・初めての部屋に入った（部屋の種類で戸の音を替える）・
    /// ときどきの風・物を拾った（紙）・鍵の戸を開けた（教室の引き戸）・鍵がかかっていた（古い戸）。1 歩の長さは walk.kind.json の stride（走っている間は dashStride）。
    pub def events(res: Res.Res, before: World.World, after: World.World): List[String] =
        let stepsOf = (w: World.World) -> Float64.floor(World.stepsOf(w)) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let n = stepsOf(after);
        let paper = if (World.isMapOpen(before) != World.isMapOpen(after)) "paper" :: Nil else Nil;
        let foot = if (n <= stepsOf(before)) Nil else "step_${Int32.toString(Int32.modulo(n, stepKinds()))}" :: Nil;
        let entered = Set.difference(World.visitedOf(after), World.visitedOf(before)) |> Set.toList |> List.head;
        let door = entered |> Option.flatMap(key -> doorOf(res, key)) |> Option.toList;
        List.flatten(paper :: foot :: door :: windAt(before#t, after#t) :: itemsEvents(before, after) :: Nil)

    /// 持ち物と鍵の戸の音: 拾った・戸を開けた（錠と教室の引き戸）・開けずに一言が出た（鍵がかかっている。戸を揺らす音）。
    def itemsEvents(before: World.World, after: World.World): List[String] =
        let picked = if (List.length(World.takenOf(after)) > List.length(World.takenOf(before))) "pickup" :: Nil else Nil;
        let opened = Map.size(World.unlockedOf(after)) > Map.size(World.unlockedOf(before));
        let startedOf = (w: World.World) -> World.noticeOf(w) |> Option.map(n -> n#started);
        let noticed = Option.nonEmpty(World.noticeOf(after)) and startedOf(after) != startedOf(before);
        let door = if (opened) "door_unlock" :: "door_classroom" :: Nil else if (noticed) "door_rattle" :: Nil else Nil;
        List.append(picked, door)

    /// 部屋の戸の音: 普通の教室と特別教室（昇降口を除く）は教室の引き戸、ほか（昇降口・職員室・宿直室・便所・物置）は古い戸。
    /// 鍵のかかった部屋は鳴らさない（開けた時に鳴らしてある）。
    def doorOf(res: Res.Res, key: String): Option[String] =
        let room = res#layout#floors |> List.flatMap(f -> f#rooms |> List.map(r -> (PaperMap.roomKey(f#index, r#id), r))) |> List.find(e -> fst(e) == key) |> Option.map(snd);
        let classroom = room |> Option.exists(r -> r#kind == "classroom" or (r#kind == "special" and r#id != "entrance"));
        if (room |> Option.exists(r -> Items.isLockedRoom(res#items, r#id))) None
        else if (classroom) Some("door_classroom") else Some("door_old")

    /// 風: 時刻 before から after の間に、その区切りの風の時刻が入っていれば鳴らす。
    def windAt(before: Float64, after: Float64): List[String] =
        let k = Float64.floor(after / windEvery()) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let at = Int32.toFloat64(k) * windEvery() + windEvery() * (0.15 + 0.7 * Hash01.at(k, 17));
        if (before < at and at <= after) "wind" :: Nil else Nil

    /// 続く音: 静まり返った教室の空気（輪）をいつも流し、同じ階の壁の時計に近いほど振り子の音を大きく（Doc の clockFalloff）。
    /// 大きさの上限は mixer のバス（sound.kind.json の ambience・clock）。
    pub def hums(res: Res.Res, w: World.World): List[App.Sustain] =
        let feet = World.feetOf(w);
        let near = res#layout#props |> List.filter(p -> String.startsWith(prefix = "wall_clock", p#prop) and Float64.abs(p#pos#y - feet#y - 2.4) < 1.6)
            |> List.map(p -> distance(p#pos, feet)) |> List.minimum;
        let clock = near |> Option.map(gainAt(Res.soundOf(res)#clockFalloff)) |> Option.filter(v -> v > 0.0)
            |> Option.map(v -> { name = "clock", volume = v, pitch = 1.0 }) |> Option.toList;
        { name = "amb_quiet", volume = 1.0, pitch = 1.0 } :: clock

    /// 距離 d m での聞こえ方（0〜1）: near までは 1・far で 0・間は (1 − 進み具合) の curve 乗。
    pub def gainAt(f: SoundDoc.Falloff, d: Float64): Float64 =
        if (d <= f#near) 1.0
        else if (d >= f#far or f#far <= f#near) 0.0
        else Float64.pow(base = Num.clamp01(1.0 - (d - f#near) / (f#far - f#near)), Float64.max(0.01, f#curve))

    /// 音の通り道: 音の種類ごとのバス（step・amb・wind・door・clock・paper）に Doc の大きさを置き（足音は走っている間 dashStep）、
    /// 戸は最後に鳴らした戸口（World の doorAt）から・風は同じ階のいちばん近い窓（配置の表の月明かり）からの距離で小さくする。
    /// 左右の振り分けは付けない（engine の音に左右を振る口が無い）。
    pub def mixer(res: Res.Res, w: World.World): AudioMixer.Mixer =
        let d = Res.soundOf(res);
        let feet = World.feetOf(w);
        let door = w#doorAt |> Option.map(at -> gainAt(d#doorFalloff, distance(at, feet))) |> Option.getWithDefault(1.0);
        let wind = nearestWindow(res, feet) |> Option.map(gainAt(d#windFalloff)) |> Option.getWithDefault(0.0);
        let bus = (name, volume) -> { name = name, volume = volume, lowpassGainHF = 1.0 };
        let route = (name, prefix) -> { bus = name, prefixes = prefix :: Nil };
        let pickup = { bus = "paper", prefixes = "pickup" :: Nil };
        let step = if (World.isDashing(w)) d#dashStep else d#step;
        { buses = bus("step", step) :: bus("amb", d#ambience) :: bus("wind", d#wind * wind) :: bus("door", d#door * door)
                  :: bus("clock", d#clock) :: bus("paper", d#paper) :: Nil,
          routes = route("step", "step") :: route("amb", "amb") :: route("wind", "wind") :: route("door", "door")
                  :: route("clock", "clock") :: route("paper", "paper") :: pickup :: Nil,
          defaultBus = "step" | AudioMixer.defaults() }

    /// 足元の階のいちばん近い窓（配置の表の月明かり。窓の内側に置いてある）までの水平の距離。
    def nearestWindow(res: Res.Res, feet: Vec3.Vec3): Option[Float64] =
        let here = Layout.floorIndexAt(feet#y, res#layout);
        res#layout#lights |> List.filter(l -> l#kind == Layout.LightKind.Moon and l#floor == here)
            |> List.map(l -> distance(l#pos, feet)) |> List.minimum

    def distance(a: Vec3.Vec3, b: Vec3.Vec3): Float64 =
        Num.sqrt((a#x - b#x) * (a#x - b#x) + (a#z - b#z) * (a#z - b#z))
}
