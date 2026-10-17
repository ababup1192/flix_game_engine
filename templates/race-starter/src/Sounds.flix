// Sounds — World から「いま鳴らす音」を導く。再生そのものは App が引き受けるので、
// ここは型で鳴らす（一発の音は Sfx[Shot]、鳴り続ける音は Loop[Hum]）だけ。
// 一発の音と鳴り続ける音を別の enum にしてあるので、取り違えると型で止まる（E6795）。
// App へ渡すときは eventNames / sustains で名前の列へ写す（テストもこの 2 つで「何が鳴るか」を見る）。
// 音量・高さ・長さのつまみは SfxTuneDoc、波形のデザインは src/render/SfxRender.flix。
mod Sounds {

    use fge::{App, Loop, Num, Sfx}

    /// 一発で鳴り切る音（当たった・取った・場面が変わった）。
    pub enum Shot with Eq {
        case Start
        case Win
        case Lose
        case Crash
        case Grip
        case Nitro
        case Bump
        case Item
        case Overtake
        case Lap
    }

    /// 鳴り続ける音（エンジンの唸り・滑っている間の擦れ・ガードレールの擦れ）。
    pub enum Hum with Eq {
        case Engine
        case Skid
        case Scrape
    }

    /// 一発の音の project.json の sounds の名前。
    pub def shotName(s: Shot): String = match s {
        case Shot.Start    => "start"
        case Shot.Win      => "win"
        case Shot.Lose     => "lose"
        case Shot.Crash    => "crash"
        case Shot.Grip     => "grip"
        case Shot.Nitro    => "nitro"
        case Shot.Bump     => "bump"
        case Shot.Item     => "item"
        case Shot.Overtake => "overtake"
        case Shot.Lap      => "lap"
    }

    /// 鳴り続ける音の project.json の sounds の名前。
    pub def humName(h: Hum): String = match h {
        case Hum.Engine => "engine"
        case Hum.Skid   => "skid"
        case Hum.Scrape => "scrape"
    }

    /// このフレームで鳴らす音の名前（App.withAudio に渡す形）。同じ音は 1 フレームに 1 回へまとまる。
    pub def eventNames(worlds: { before = World.World, after = World.World }): List[String] =
        Sfx.collect(shotName, () -> events(worlds))

    /// このフレームで鳴り続けていてほしい音（App.withSustained に渡す形）。
    pub def sustains(w: World.World): List[App.Sustain] =
        Loop.collect(humName, () -> hums(w))

    /// このフレームの出来事の音を鳴らす。
    def events(worlds: { before = World.World, after = World.World }): Unit \ Sfx[Shot] = {
        phaseSounds(worlds#before, worlds#after);
        racingSounds(worlds#before, worlds#after)
    }

    /// 場面の変わり目の音。決定（開始・仕切り直し）とゴールの明暗。
    def phaseSounds(before: World.World, after: World.World): Unit \ Sfx[Shot] =
        match (before#phase, after#phase) {
            case (World.Phase.Title, World.Phase.Racing) => Sfx.play(Shot.Start)
            case (World.Phase.Racing, World.Phase.Win)   => Sfx.play(Shot.Win)
            case (World.Phase.Racing, World.Phase.Lose)  => Sfx.play(Shot.Lose)
            case (World.Phase.Win, World.Phase.Title)    => Sfx.play(Shot.Start)
            case (World.Phase.Lose, World.Phase.Title)   => Sfx.play(Shot.Start)
            case _                                       => ()
        }

    /// 走行中の出来事の音。走っているフレームだけ見る —— ゴール後の凍った World から
    /// 導くと、最後の 1 フレームの事実が毎フレーム鳴り続ける。
    def racingSounds(before: World.World, after: World.World): Unit \ Sfx[Shot] =
        if (after#phase != World.Phase.Racing) ()
        else {
            let crashed = before#spinLeft <= 0.0 and after#spinLeft > 0.0;
            playIf(crashed, Shot.Crash);
            // ドリフトの終わり。滑っている間の擦れは hums が受け持つので、ここは離したフレームだけ。
            // クラッシュしたフレームの食いつきは鳴らさない（潰れた音の上に軽い音を重ねない）。
            playIf(before#drifting and not after#drifting and not crashed, Shot.Grip);
            playIf(before#nitroLeft <= 0.0 and after#nitroLeft > 0.0, Shot.Nitro);
            playIf(before#bumpLeft <= 0.0 and after#bumpLeft > 0.0, Shot.Bump);
            playIf(Set.size(after#taken) > Set.size(before#taken), Shot.Item);
            playIf(passedCount(after) > passedCount(before), Shot.Overtake);
            playIf(after#lap > before#lap, Shot.Lap)
        }

    /// cond のときだけ鳴らす。
    def playIf(cond: Bool, shot: Shot): Unit \ Sfx[Shot] =
        if (cond) Sfx.play(shot) else ()

    // ── 鳴り続ける音 ──

    /// このフレームで鳴り続けていてほしい音を宣言する。宣言が続く間だけ鳴り、消えたフレームで止まる
    /// （App.withSustained の規約）。走っていない場面は 1 本も宣言しないので、
    /// タイトルとゴール画面は静かになる。
    def hums(w: World.World): Unit \ Loop[Hum] =
        if (w#phase != World.Phase.Racing) ()
        else {
            engineHum(w);
            skidHum(w);
            railHum(w)
        }

    /// エンジンの唸り。速さで高さが上がる — 数字を読まなくても、いま伸びているのか
    /// 頭打ちなのかが耳で分かる。スピン中は駆動が切れるので低く落として音量も落とす。
    def engineHum(w: World.World): Unit \ Loop[Hum] =
        let k = SfxTuneDoc.rec(w#sfxtune)#engine;
        // ニトロ全開を 1.0 に取る（普段の巡航はこの尺の途中 — 上がしろが残るので、
        // 加速したときに唸りがまだ伸びる）。
        let top = Float64.max(1.0, RulesDoc.rec(w#rules)#forwardSpeed * RulesDoc.rec(w#rules)#nitroBoost);
        let ratio = Num.clamp01(w#speed / top);
        let lo = SfxTuneDoc.rec(w#sfxtune)#enginePitchLow;
        let hi = SfxTuneDoc.rec(w#sfxtune)#enginePitchHigh;
        let spun = w#spinLeft > 0.0;
        let pitch = (lo + (hi - lo) * ratio) * k#pitch * (if (spun) 0.55 else 1.0);
        let volume = k#volume * (0.6 + 0.4 * ratio) * (if (spun) 0.5 else 1.0);
        Loop.hold(Hum.Engine, { volume = Num.clamp01(volume), pitch = Float64.max(0.1, pitch) })

    /// 滑っている間の擦れ。ニトロゲージが貯まっているほど濃く出す — 危険な走りが
    /// 溜まっていることを、絵（火花）と同じ強さで耳にも返す。
    def skidHum(w: World.World): Unit \ Loop[Hum] =
        if (not w#drifting) ()
        else {
            let k = SfxTuneDoc.rec(w#sfxtune)#skid;
            Loop.hold(Hum.Skid, { volume = Num.clamp01(k#volume * (0.6 + 0.4 * Num.clamp01(w#nitro))),
                                  pitch = Float64.max(0.1, k#pitch) })
        }

    /// ガードレールを擦っている間の金属の擦れ。壁に当たった一発の音を鳴らさないのは、
    /// 壁は「当たる物」ではなく「押し付けたまま曲がる物」だから — 触れている長さが
    /// そのまま音の長さになると、擦り付けて曲がっている実感が出る。
    def railHum(w: World.World): Unit \ Loop[Hum] =
        if (not World.scraping(w)) ()
        else {
            let k = SfxTuneDoc.rec(w#sfxtune)#scrape;
            Loop.hold(Hum.Scrape, { volume = Num.clamp01(k#volume), pitch = Float64.max(0.1, k#pitch) })
        }

    /// もう抜いたライバルの数（増えたフレームが「1 台抜いた」）。
    def passedCount(w: World.World): Int32 =
        w#rivals |> List.count(r -> r#passed)
}
