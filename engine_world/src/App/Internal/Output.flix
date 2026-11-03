// App.Internal.Output — 進んだ World から外へ出す物: 音（一発・鳴り続ける音・ミキサー）・マウスの矢印とキャプチャ・ウィンドウ・addOutput の書き出し。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.Output {
    /// 前のフレームの宣言（名前の列）と今のフレームの宣言から、鳴らし始める音・
    /// 鳴らし続ける音・止める音を仕分ける。同じ名前が 2 回宣言されたら先勝ちで 1 本にまとめる
    /// （二重に鳴らすと同じ音源を頭から鳴らし直して途切れる）。
    pub def sustainOps(prev: List[String], next: List[App.Sustain]):
            { start = List[App.Sustain], keep = List[App.Sustain], stop = List[String] } =
        // 重複の判定は Set で、列そのものは逆順に積んで最後に 1 回戻す。宣言の並びは
        // start / keep / stop の順にそのまま出るので、Set の並びで組み直してはいけない。
        let (rev, _) = next |> List.foldLeft((acc, s) -> {
            let (kept, seen) = acc;
            if (Set.memberOf(s#name, seen)) acc else (s :: kept, Set.insert(s#name, seen))
        }, (Nil, Set.empty()));
        let fresh = List.reverse(rev);
        let living = fresh |> List.map(s -> s#name) |> List.toSet;
        let prevNames = List.toSet(prev);
        { start = List.filter(s -> not Set.memberOf(s#name, prevNames), fresh),
          keep  = List.filter(s -> Set.memberOf(s#name, prevNames), fresh),
          stop  = List.filter(n -> not Set.memberOf(n, living), List.distinct(prev)) }

    /// 跳んだ拍の後の出力の鍵: Skip は跳んだ先の鍵を「書いた」ことにし、Write は前に書いた鍵のまま
    /// （次の実機のフレームで鍵が違えば書く）。written が短い所（起動の拍）は "" = まだ何も書いていない。
    pub def keysAfterJump(app: App[w, ef], world: w, written: List[String]): List[String] =
        App.rec(app)#outputs |> List.zipWithIndex |> List.map(entry -> {
            let (index, output) = entry;
            match output#onJump {
                case App.OnJump.Skip  => (output#keyOf)(world)
                case App.OnJump.Write => List.nth(index, written) |> Option.getWithDefault("")
            }
        })

    /// 実機のフレームの後の World で書くべき出力の番号（outputs の順）: 鍵が最後に書いた鍵と違う物。
    pub def dueOutputs(app: App[w, ef], world: w, written: List[String]): List[Int32] =
        App.rec(app)#outputs |> List.zipWithIndex |> List.filterMap(entry -> {
            let (index, output) = entry;
            if (Some((output#keyOf)(world)) == List.nth(index, written)) None else Some(index)
        })

    /// 実機のフレームの後: dueOutputs の出力だけ write を呼び、新しい鍵の列を返す。
    pub def writeOutputs(app: App[w, ef], world: w, written: List[String]): List[String] \ Fs.FileWrite =
        let due = dueOutputs(app, world, written);
        App.rec(app)#outputs |> List.zipWithIndex |> List.map(entry -> {
            let (index, output) = entry;
            if (List.memberOf(index, due)) (output#write)(world) else ();
            (output#keyOf)(world)
        })

    /// withCursor の宣言を当てる（前に当てた物と同じなら何もしない）。返すのは当てた後の状態。
    pub def applyCursor(r: App.Rec[w, ef], world: w, state: App.CursorLook.State): App.CursorLook.State \ GameEngine.Game =
        match r#cursor {
            case None    => state
            case Some(f) =>
                let want = f(world);
                Option.forEach(applyLook, App.CursorLook.cursorChange(want, state));
                App.CursorLook.State.Applied(want)
        }

    /// withMouseCapture の宣言を当てる（前に当てた値と同じなら何もしない）。返すのは当てた後の値（宣言が無ければ applied のまま）。
    pub def applyCapture(r: App.Rec[w, ef], world: w, applied: Option[Bool]): Option[Bool] \ GameEngine.Game =
        match r#mouseCapture {
            case None    => applied
            case Some(f) =>
                let want = f(world);
                Option.forEach(GameEngine.Game.setMouseCaptured, App.CursorLook.captureChange(want, applied));
                Some(want)
        }

    /// withFullscreen の宣言を当てる（setFullscreen は今と同じ値なら何もしないので、毎フレーム渡してよい）。
    pub def applyFullscreen(r: App.Rec[w, ef], world: w): Unit \ GameEngine.Game =
        Option.forEach(f -> GameEngine.Game.setFullscreen(f(world)), r#fullscreen)

    /// 止めた画面の出入りの見た目をウィンドウへ当てる。
    pub def applyHaltLook(look: App.CursorLook.HaltLook): Unit \ GameEngine.Game =
        let App.CursorLook.HaltLook.HaltLook(badge, cursor, capture) = look;
        GameEngine.Game.setDebugBadge(badge == App.CursorLook.Badge.Shown);
        applyLook(cursor);
        if (capture == App.CursorLook.Capture.Release) GameEngine.Game.setMouseCaptured(false) else ()

    def applyLook(look: App.CursorLook.Look): Unit \ GameEngine.Game =
        let App.CursorLook.Look.Look(icon, visibility) = look;
        GameEngine.Game.setCursor(icon);
        match visibility {
            case App.CursorLook.Visibility.Show       => GameEngine.Game.setCursorVisible(true)
            case App.CursorLook.Visibility.Hide       => GameEngine.Game.setCursorVisible(false)
            case App.CursorLook.Visibility.LeaveToApp => ()
        }

    /// 1 フレームの音: ミキサーが無ければ今までどおり名前のまま鳴らし、あればバスを通して鳴らす。
    /// 返すのは次のフレームへ渡す「いま鳴り続けている名前」とミキサーの状態。
    /// uses は一発とループで鳴らした名前の覚え（noteSoundUses）。両方に出た名前は warn で 1 回だけ知らせる。
    pub def applyAudio(r: App.Rec[w, ef], dt: Float64, traced: App.TraceStep[w],
                       prev: List[String], mixState: AudioMixer.State, uses: SoundUses, warn: String -> Unit):
            (List[String], AudioMixer.State, SoundUses) \ (ef + GameEngine.Audio) =
        let plays = traced#sounds;
        let declared = traced#sustained;
        let after = traced#after;
        let (nextUses, clashes) = noteSoundUses(plays, declared |> List.map(s -> s#name), uses);
        let (living, nextMix) = match r#mixer {
            case None          => (playPlain(List.distinct(plays), declared, prev), mixState)
            case Some(mixerOf) => applyMixed(mixerOf(after), dt, plays, declared, prev, mixState)
        };
        let lines = clashes |> List.map(name ->
            "音 ${name} を一発（withAudio）とループ（withSustained）の両方で鳴らしている: " +
            "ループの設定が残って一発が止まらない・ループが途中で切れることがある。ループの方は別の名前にする（例: ${name}_loop）");
        warnedAll(warn, lines, (living, nextMix, nextUses))

    /// lines を 1 行ずつ warn で知らせてから value を返す。
    /// WhyNot: `warn(line);` と書かない —— 純粋な型の呼び出しの値を捨てると、コンパイラが呼び出しごと消す。
    def warnedAll(warn: String -> Unit, lines: List[String], value: a): a =
        match lines {
            case Nil          => value
            case line :: rest => match warn(line) {
                case () => warnedAll(warn, rest, value)
            }
        }

    /// 一発で鳴らした名前とループで鳴らした名前の覚え（ゲームの間ずっと持つ）。
    pub type alias SoundUses = { oneShot = Set[String], looped = Set[String] }

    /// このフレームの一発の音 plays とループの音 looped を覚えに足し、初めて両方に出た名前を返す。
    /// 音の名前に「一発用・ループ用」の型が付くまでのつなぎ（同じ名前を両方で使うと、音源に残った
    /// ループの設定で一発が止まらない・ループが切れる）。
    pub def noteSoundUses(plays: List[String], looped: List[String], uses: SoundUses): (SoundUses, List[String]) =
        let next = { oneShot = Set.union(uses#oneShot, List.toSet(plays)),
                     looped  = Set.union(uses#looped, List.toSet(looped)) };
        let isBoth = (u, name) -> Set.memberOf(name, u#oneShot) and Set.memberOf(name, u#looped);
        let clashes = List.append(plays, looped) |> List.distinct
            |> List.filter(name -> isBoth(next, name) and not isBoth(uses, name));
        (next, clashes)

    /// バスを通して鳴らす。順番: ミキサーを 1 フレーム進める（AudioMixer.step）→ 鳴っている一発の音へ
    /// 今の音量とローパスを流し直す（ダッキングの最中に下がっていく）→ 通った一発の音を鳴らす →
    /// 鳴り続ける音を始める・続ける・止める（宣言の音量 × バスの倍率）。
    def applyMixed(mixer: AudioMixer.Mixer, dt: Float64, plays: List[String], declared: List[App.Sustain],
                       prev: List[String], mixState: AudioMixer.State):
            (List[String], AudioMixer.State) \ GameEngine.Audio =
        let ops = sustainOps(prev, declared);
        let living = List.map(s -> s#name, List.append(ops#start, ops#keep));
        let (allowed, next) = AudioMixer.step(mixer, name -> GameEngine.Audio.audioSeconds(name), dt,
                                              plays, living, mixState);
        let route = name -> {
            GameEngine.Audio.setVolume(name, AudioMixer.gainOf(mixer, next, name));
            GameEngine.Audio.setLowpass(name, AudioMixer.lowpassGainHFOf(mixer, next, name))
        };
        Map.forEach((name, _) -> route(name), next#voices);
        // 止める → ループを外す → 一発の音 → 鳴らし始め の順（止める音と同じ名前の一発の音を
        // 後から止めて消さないため）。
        ops#stop |> List.forEach(name -> GameEngine.Audio.stopAudio(name));
        unloopedOneShots(allowed, living) |> List.forEach(name -> GameEngine.Audio.setLooping(name, false));
        allowed |> List.forEach(name -> GameEngine.Audio.playAudio(name));
        let level = s -> {
            GameEngine.Audio.setVolume(s#name, s#volume * AudioMixer.gainOf(mixer, next, s#name));
            GameEngine.Audio.setPitch(s#name, s#pitch);
            GameEngine.Audio.setLowpass(s#name, AudioMixer.lowpassGainHFOf(mixer, next, s#name))
        };
        ops#start |> List.forEach(s -> {
            GameEngine.Audio.setLooping(s#name, true);
            level(s);
            GameEngine.Audio.playAudio(s#name)
        });
        ops#keep |> List.forEach(level);
        (living, next)

    /// ミキサーの無いときの 1 フレームの音。一発の音は audio の導いた名前（同じ名前が 2 回返っても
    /// 1 回にまとめる — 同フレームの二重再生は同じ音源を頭から鳴らし直して途切れる）、鳴り続ける音は
    /// sustained の宣言。鳴らし始めだけ playAudio を打ち、続いている音には音量と高さだけ流す
    /// （毎フレーム鳴らし直すと頭から再生され、続く音にならない）。順番は applyMixed と同じ
    /// 「止める → ループを外す → 一発の音 → 鳴らし始め」。返すのは次のフレームへ渡す「いま鳴っている名前」。
    def playPlain(plays: List[String], declared: List[App.Sustain], prev: List[String]): List[String] \ GameEngine.Audio =
        let ops = sustainOps(prev, declared);
        let living = List.map(s -> s#name, List.append(ops#start, ops#keep));
        ops#stop |> List.forEach(name -> GameEngine.Audio.stopAudio(name));
        unloopedOneShots(plays, living) |> List.forEach(name -> GameEngine.Audio.setLooping(name, false));
        plays |> List.forEach(name -> GameEngine.Audio.playAudio(name));
        ops#start |> List.forEach(s -> {
            GameEngine.Audio.setLooping(s#name, true);
            GameEngine.Audio.setVolume(s#name, s#volume);
            GameEngine.Audio.setPitch(s#name, s#pitch);
            GameEngine.Audio.playAudio(s#name)
        });
        ops#keep |> List.forEach(s -> {
            GameEngine.Audio.setVolume(s#name, s#volume);
            GameEngine.Audio.setPitch(s#name, s#pitch)
        });
        living

    /// 一発の音（audio）のうち、鳴らす前にループを外す名前。鳴り続ける音（sustained）として
    /// 一度鳴らした名前は音源にループの設定が残るので、同じ名前を一発で鳴らすと止まらなくなる。
    /// いま鳴り続けている名前（living）は外さない — 外すと鳴り続ける側が途中で切れる。
    pub def unloopedOneShots(plays: List[String], living: List[String]): List[String] =
        let alive = List.toSet(living);
        plays |> List.filter(name -> not Set.memberOf(name, alive))
}
