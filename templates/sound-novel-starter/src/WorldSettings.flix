// WorldSettings — 設定の画面の規則（純粋）。
// 行の形は World.Setting の case が決める: Slider = スライダー（範囲は novel.kind.json の *Slider）、Pair = 2 つから選ぶ、
// Reset = 押すと確認のウィンドウ。値は Saves.Config に入り、セーブデータと一緒に残る。カーソルの行は Panel.Settings が持つ。
mod WorldSettings {
    use fge::{Emit}

    /// 画面の並び（左の列に Layout.leftColumnRows 行: 文章、残りは右の列: 音と画面）。
    pub def settings(): List[World.Setting] =
        World.Setting.Slider(World.Slider.TextSpeed) :: World.Setting.Slider(World.Slider.AutoWait) ::
        World.Setting.Pair(World.Pair.SkipScope) :: World.Setting.Pair(World.Pair.AfterChoice) :: World.Setting.Pair(World.Pair.Display) ::
        World.Setting.Slider(World.Slider.MasterVolume) :: World.Setting.Slider(World.Slider.AmbienceVolume) ::
        World.Setting.Slider(World.Slider.SeVolume) :: World.Setting.Slider(World.Slider.WindowAlpha) :: World.Setting.Reset :: Nil

    /// 設定の画面を開く（カーソルは先頭の行）。
    pub def openSettings(w: World.World): World.World \ Emit[World.Event] =
        World.openPanel(World.Panel.Settings(World.Setting.Slider(World.Slider.TextSpeed)), w)

    /// カーソルの行（設定の画面が開いていなければ None）。
    pub def cursorOf(w: World.World): Option[World.Setting] = match w#panel {
        case World.Panel.Settings(setting) => Some(setting)
        case _                             => None
    }

    /// カーソルの行を delta 行ぶん動かす（端で回り込む）。
    pub def moveSetting(delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        match cursorOf(w) {
            case Some(setting) =>
                let rows = settings();
                let at = rows |> List.zipWithIndex |> List.find(match (_, s) -> s == setting) |> Option.map(fst) |> Option.getWithDefault(0);
                match List.nth(Int32.modulo(at + delta, List.length(rows)), rows) {
                    case Some(next) => Emit.emit(World.Event.Moved); { panel = World.Panel.Settings(next) | w }
                    case None       => w
                }
            case None => w
        }

    /// カーソルの行を setting へ（マウスが乗った行。同じなら音を出さない）。
    pub def pointSetting(setting: World.Setting, w: World.World): World.World \ Emit[World.Event] =
        match cursorOf(w) {
            case Some(at) if at != setting => Emit.emit(World.Event.Moved); { panel = World.Panel.Settings(setting) | w }
            case _                         => w
        }

    /// スライダーの範囲と 1 押しの量（novel.kind.json）。
    pub def rangeOf(slider: World.Slider, kind: KindDoc.Doc): KindDoc.Slider =
        let k = KindDoc.rec(kind);
        match slider {
            case World.Slider.TextSpeed      => k#cpsSlider
            case World.Slider.AutoWait       => k#autoWaitSlider
            case World.Slider.MasterVolume   => k#masterVolumeSlider
            case World.Slider.AmbienceVolume => k#ambienceVolumeSlider
            case World.Slider.SeVolume       => k#seVolumeSlider
            case World.Slider.WindowAlpha    => k#windowAlphaSlider
        }

    /// 2 つから選ぶ行の、左と右の言葉。
    pub def pairLabels(pair: World.Pair): (StoryDoc.Label, StoryDoc.Label) = match pair {
        case World.Pair.SkipScope   => (StoryDoc.Label.SkipReadOnly, StoryDoc.Label.SkipEverything)
        case World.Pair.AfterChoice => (StoryDoc.Label.StopSkip, StoryDoc.Label.KeepSkip)
        case World.Pair.Display     => (StoryDoc.Label.WindowMode, StoryDoc.Label.FullscreenMode)
    }

    /// スライダーの今の値。
    pub def levelOf(slider: World.Slider, c: Saves.Config): Float64 =
        match slider {
            case World.Slider.TextSpeed      => c#cps
            case World.Slider.AutoWait       => c#autoWait
            case World.Slider.MasterVolume   => c#masterVolume
            case World.Slider.AmbienceVolume => c#ambienceVolume
            case World.Slider.SeVolume       => c#seVolume
            case World.Slider.WindowAlpha    => c#windowAlpha
        }

    /// 2 つから選ぶ行の、今選んでいる側。
    pub def sideOf(pair: World.Pair, c: Saves.Config): Layout.Side =
        let right = match pair {
            case World.Pair.SkipScope   => c#skipScope == Saves.SkipScope.Everything
            case World.Pair.AfterChoice => c#afterChoice == Saves.AfterChoice.KeepSkip
            case World.Pair.Display     => c#display == Saves.Display.Fullscreen
        };
        if (right) Layout.Side.Right else Layout.Side.Left

    /// スライダーの値を v にする（範囲の端で止める。スライダーの帯をクリックした所の値・←→ の 1 押し）。
    pub def withLevel(slider: World.Slider, v: Float64, w: World.World): World.World \ Emit[World.Event] =
        let range = rangeOf(slider, w#docs#kind);
        let clamped = Float64.max(range#min, Float64.min(range#max, v));
        let c = World.configOf(w);
        let next = match slider {
            case World.Slider.TextSpeed      => { cps = clamped | c }
            case World.Slider.AutoWait       => { autoWait = clamped | c }
            case World.Slider.MasterVolume   => { masterVolume = clamped | c }
            case World.Slider.AmbienceVolume => { ambienceVolume = clamped | c }
            case World.Slider.SeVolume       => { seVolume = clamped | c }
            case World.Slider.WindowAlpha    => { windowAlpha = clamped | c }
        };
        if (clamped == levelOf(slider, c)) w
        else { Emit.emit(World.Event.Moved); World.withSaves(Saves.withConfig(next, w#saves), w) }

    /// 2 つから選ぶ行を side の側にする。
    pub def withSide(pair: World.Pair, side: Layout.Side, w: World.World): World.World \ Emit[World.Event] =
        let right = side == Layout.Side.Right;
        let c = World.configOf(w);
        let next = match pair {
            case World.Pair.SkipScope   => { skipScope = if (right) Saves.SkipScope.Everything else Saves.SkipScope.ReadOnly | c }
            case World.Pair.AfterChoice => { afterChoice = if (right) Saves.AfterChoice.KeepSkip else Saves.AfterChoice.StopSkip | c }
            case World.Pair.Display     => { display = if (right) Saves.Display.Fullscreen else Saves.Display.Window | c }
        };
        if (side == sideOf(pair, c)) w
        else { Emit.emit(World.Event.Moved); World.withSaves(Saves.withConfig(next, w#saves), w) }

    /// 行の値を delta 段ぶん動かす（スライダーは 1 押しの量ずつ、2 つから選ぶ行は delta の向きの側へ）。
    pub def adjust(setting: World.Setting, delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        match setting {
            case World.Setting.Slider(slider) =>
                withLevel(slider, levelOf(slider, World.configOf(w)) + Int32.toFloat64(delta) * rangeOf(slider, w#docs#kind)#step, w)
            case World.Setting.Pair(pair) => withSide(pair, if (delta > 0) Layout.Side.Right else Layout.Side.Left, w)
            case World.Setting.Reset      => w
        }

    /// 決定で行を押す（2 つから選ぶ行は反対側へ、「初期設定に戻す」は確認のウィンドウ）。
    pub def activate(setting: World.Setting, w: World.World): World.World \ Emit[World.Event] =
        match setting {
            case World.Setting.Pair(pair) =>
                withSide(pair, if (sideOf(pair, World.configOf(w)) == Layout.Side.Left) Layout.Side.Right else Layout.Side.Left, w)
            case World.Setting.Reset     => World.askFor(World.Ask.Reset, w)
            case World.Setting.Slider(_) => w
        }

    /// 設定を novel.kind.json の既定へ戻す（確認のウィンドウの「はい」）。
    pub def reset(w: World.World): World.World \ Emit[World.Event] =
        Emit.emit(World.Event.Moved);
        World.notice(StoryDoc.Label.ResetDone, World.withSaves(Saves.withConfig(Saves.defaultConfig(w#docs#kind), w#saves), w))

    /// フルスクリーンにしたいか（Game の App.withFullscreen）。
    pub def isFullscreen(w: World.World): Bool = World.configOf(w)#display == Saves.Display.Fullscreen
}
