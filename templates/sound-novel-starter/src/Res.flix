// Res — 描く元の束: 起動時に読む Doc と台本。読むだけで、Doc の読み直しの時だけ替わる。
// 遊びの状態は World が持ち、App の w は Resources.With[Res, World] の組（Game.app）。
// Res は World を使わない（使う向きは World → Res だけ）。
mod Res {
    use fge::{AudioMixer, Yarn}

    /// 描く元の束（Main・描き出し・テストが Controls.loadRes で同じ形に読む）。
    /// story = 字と名前・kind = 遊びの数・theme = 色・backdrops = 背景の写真・credits = クレジットの行・
    /// keys = キーの割り当て・smallScreen = 小さい画面（スマホ）の時の字と押せる物の大きさ・
    /// portrait = 縦の画面（縦の design で起動した時）の字と押せる物の大きさ・cast = 立ち絵と小物（位置・一覧・出入りの秒）・shots = 描き出しの場面・mixer = 音のバス・
    /// mixerExtras = 名前付きの音量と効果音の後に送れない秒（novel.mixer.json のテンプレートの欄）・soundSeconds = 鳴り続けない音の長さ（秒。SoundLength）・
    /// effects = 粒の演出の表・prompts = 入力の案内（払い・タップで選ぶ選択肢）・dialogue = シナリオの木・
    /// missing = ブラウザ版で後回しにした絵と音のうち、まだ届いていない物の名前（textures / sounds の name。デスクトップ・描き出し・テストは空）・
    /// scriptEdits = 始まりの引数（edit.<行>）で当てたシナリオの直し（ふだんは空）・
    /// commandArgs = シナリオのコマンドを表で読んだ結果・nodesBySource = .yarn の「ファイル:行」→ その行を持つノード
    /// （どちらも dialogue と一緒に作り直す。withDialogue）・game = このゲームだけの描く元（GameRes。テンプレートは中身を見ない）・
    /// commands = 読み進める時に当てる命令の表（テンプレートの Commands.all とゲームの GameCommands.all。テストが命令を差す）。
    pub type alias Res = {
        story = StoryDoc.Doc,
        kind = KindDoc.Doc,
        theme = ThemeDoc.Doc,
        backdrops = BackdropDoc.Doc,
        credits = CreditsDoc.Doc,
        keys = KeysDoc.Doc,
        smallScreen = SmallScreenDoc.Doc,
        portrait = PortraitDoc.Doc,
        cast = CastDoc.Doc,
        shots = ShotsDoc.Doc,
        mixer = AudioMixer.Mixer,
        mixerExtras = MixerDoc.Doc,
        soundSeconds = Map[String, Float64],
        effects = EffectsDoc.Doc,
        prompts = PromptsDoc.Doc,
        dialogue = Yarn.Program,
        commandArgs = Commands.ArgsTable,
        nodesBySource = Map[String, String],
        missing = Set[String],
        scriptEdits = ScriptEdits.Applied,
        game = GameRes.Data,
        commands = Commands.Table
    }

    // ── Doc の差し替え（保存即反映。Controls.docTable の reload） ──

    pub def withStory(story: StoryDoc.Doc, res: Res): Res = { story = story | res }

    pub def withKind(kind: KindDoc.Doc, res: Res): Res = { kind = kind | res }

    pub def withTheme(theme: ThemeDoc.Doc, res: Res): Res = { theme = theme | res }

    pub def withBackdrops(backdrops: BackdropDoc.Doc, res: Res): Res = { backdrops = backdrops | res }

    pub def withCredits(credits: CreditsDoc.Doc, res: Res): Res = { credits = credits | res }

    pub def withKeys(keys: KeysDoc.Doc, res: Res): Res = { keys = keys | res }

    pub def withSmallScreen(smallScreen: SmallScreenDoc.Doc, res: Res): Res = { smallScreen = smallScreen | res }

    pub def withPortrait(portrait: PortraitDoc.Doc, res: Res): Res = { portrait = portrait | res }

    pub def withCast(cast: CastDoc.Doc, res: Res): Res = { cast = cast | res }

    pub def withShots(shots: ShotsDoc.Doc, res: Res): Res = { shots = shots | res }

    pub def withMixer(mixer: AudioMixer.Mixer, res: Res): Res = { mixer = mixer | res }

    pub def withMixerExtras(extras: MixerDoc.Doc, res: Res): Res = { mixerExtras = extras | res }

    pub def withSoundSeconds(seconds: Map[String, Float64], res: Res): Res = { soundSeconds = seconds | res }

    pub def withEffects(effects: EffectsDoc.Doc, res: Res): Res = { effects = effects | res }

    pub def withPrompts(prompts: PromptsDoc.Doc, res: Res): Res = { prompts = prompts | res }

    /// このゲームだけの描く元を差し替える（GameRes.docRows の読み直し・GameBoot の素材の読み込み）。
    pub def withGame(game: GameRes.Data, res: Res): Res = { game = game | res }

    /// まだ届いていない絵と音の名前を差し替える（Game.withAssetLoading が届くたびに写す）。
    pub def withMissing(missing: Set[String], res: Res): Res = { missing = missing | res }

    /// シナリオの直しを差し替える（Starts の talk が引数から作る）。
    pub def withScriptEdits(edits: ScriptEdits.Applied, res: Res): Res = { scriptEdits = edits | res }

    /// シナリオの木を差し替える（読んでいる所を新しい木へ収め直すのは WorldRead.settleDialogue）。
    pub def withDialogue(dialogue: Yarn.Program, res: Res): Res = { dialogue = dialogue, commandArgs = Commands.argsTableOf(dialogue), nodesBySource = Talk.nodesBySource(dialogue) | res }
}
