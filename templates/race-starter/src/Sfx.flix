// Sfx — World から「いま鳴らす音」を導く純関数。再生そのものは App が引き受けるので、
// ここは音の名前（と続く音なら音量・高さ）を返すだけ
// （だからテストで「何が鳴るか」を具体値のまま固定できる）。
// 音量・高さ・長さのつまみは SfxTuneDoc、波形のデザインは src/render/SfxRender.flix。
//
// 口は 2 つ: events が一発で鳴り切る音（当たった・取った・場面が変わった）、
// hums が鳴り続ける音（エンジンの唸り・滑っている間の擦れ）。
mod Sfx {

    /// このフレームで鳴らす音の名前（project.json の sounds に載る名前）。
    /// 同じ音は 1 フレームに 1 回へまとめる（滑り出しのフレームで擦れ音が二重に乗らない）。
    pub def events(worlds: { before = World.World, after = World.World }): List[String] =
        List.append(phaseSounds(worlds#before, worlds#after),
                    racingSounds(worlds#before, worlds#after))
            |> List.distinct

    /// 場面の変わり目の音。決定（開始・仕切り直し）とゴールの明暗。
    def phaseSounds(before: World.World, after: World.World): List[String] =
        match (before#phase, after#phase) {
            case (World.Phase.Title, World.Phase.Racing) => "start" :: Nil
            case (World.Phase.Racing, World.Phase.Win)   => "win" :: Nil
            case (World.Phase.Racing, World.Phase.Lose)  => "lose" :: Nil
            case (World.Phase.Win, World.Phase.Title)    => "start" :: Nil
            case (World.Phase.Lose, World.Phase.Title)   => "start" :: Nil
            case _                                       => Nil
        }

    /// 走行中の出来事の音。走っているフレームだけ見る —— ゴール後の凍った World から
    /// 導くと、最後の 1 フレームの事実が毎フレーム鳴り続ける。
    def racingSounds(before: World.World, after: World.World): List[String] =
        if (after#phase != World.Phase.Racing) Nil
        else {
            let crashed = before#spinLeft <= 0.0 and after#spinLeft > 0.0;
            List.flatten(
                (if (crashed) "crash" :: Nil else Nil) ::
                driftSounds(crashed, before, after) ::
                (if (before#nitroLeft <= 0.0 and after#nitroLeft > 0.0) "nitro" :: Nil else Nil) ::
                (if (before#bumpLeft <= 0.0 and after#bumpLeft > 0.0) "bump" :: Nil else Nil) ::
                (if (Set.size(after#taken) > Set.size(before#taken)) "item" :: Nil else Nil) ::
                (if (passedCount(after) > passedCount(before)) "overtake" :: Nil else Nil) ::
                (if (after#lap > before#lap) "lap" :: Nil else Nil) :: Nil)
        }

    /// ドリフトの終わりの音。滑っている間の擦れは hums が受け持つので、ここは離したフレームだけ。
    /// クラッシュしたフレームの食いつきは鳴らさない（潰れた音の上に軽い音を重ねない）。
    def driftSounds(crashed: Bool, before: World.World, after: World.World): List[String] =
        if (before#drifting and not after#drifting and not crashed) "grip" :: Nil
        else Nil

    // ── 鳴り続ける音 ──

    /// このフレームで鳴り続けていてほしい音。宣言が続く間だけ鳴り、消えたフレームで止まる
    /// （App.withSustained の規約）。走っていない場面は 1 本も宣言しないので、
    /// タイトルとゴール画面は静かになる。
    pub def hums(w: World.World): List[App.Sustain] =
        if (w#phase != World.Phase.Racing) Nil
        else engineHum(w) ::: skidHum(w) ::: railHum(w)

    /// エンジンの唸り。速さで高さが上がる — 数字を読まなくても、いま伸びているのか
    /// 頭打ちなのかが耳で分かる。スピン中は駆動が切れるので低く落として音量も落とす。
    def engineHum(w: World.World): List[App.Sustain] =
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
        { name = "engine",
          volume = Num.clamp01(volume),
          pitch = Float64.max(0.1, pitch) } :: Nil

    /// 滑っている間の擦れ。ニトロゲージが貯まっているほど濃く出す — 危険な走りが
    /// 溜まっていることを、絵（火花）と同じ強さで耳にも返す。
    def skidHum(w: World.World): List[App.Sustain] =
        if (not w#drifting) Nil
        else {
            let k = SfxTuneDoc.rec(w#sfxtune)#skid;
            { name = "skid",
              volume = Num.clamp01(k#volume * (0.6 + 0.4 * Num.clamp01(w#nitro))),
              pitch = Float64.max(0.1, k#pitch) } :: Nil
        }

    /// ガードレールを擦っている間の金属の擦れ。壁に当たった一発の音を鳴らさないのは、
    /// 壁は「当たる物」ではなく「押し付けたまま曲がる物」だから — 触れている長さが
    /// そのまま音の長さになると、擦り付けて曲がっている実感が出る。
    def railHum(w: World.World): List[App.Sustain] =
        if (not World.scraping(w)) Nil
        else {
            let k = SfxTuneDoc.rec(w#sfxtune)#scrape;
            { name = "scrape",
              volume = Num.clamp01(k#volume),
              pitch = Float64.max(0.1, k#pitch) } :: Nil
        }

    /// もう抜いたライバルの数（増えたフレームが「1 台抜いた」）。
    def passedCount(w: World.World): Int32 =
        w#rivals |> List.count(r -> r#passed)
}
