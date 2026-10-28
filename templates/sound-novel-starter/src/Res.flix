// Res — 描く元の束: 起動時に読む Doc と台本。読むだけで、Doc の読み直しの時だけ替わる。
// 遊びの状態は World が持ち、App の w は Resources.With[Res, World] の組（Game.app）。
// Res は World を使わない（使う向きは World → Res だけ）。
mod Res {
    use fge::{AudioMixer, Yarn}

    /// 描く元の束（Main・描き出し・テストが Controls.loadRes で同じ形に読む）。
    /// story = 字と名前・kind = 遊びの数・theme = 色・backdrops = 背景の写真・credits = クレジットの行・
    /// keys = キーの割り当て・mixer = 音のバス・dialogue = シナリオの木。
    pub type alias Res = {
        story = StoryDoc.Doc,
        kind = KindDoc.Doc,
        theme = ThemeDoc.Doc,
        backdrops = BackdropDoc.Doc,
        credits = CreditsDoc.Doc,
        keys = KeysDoc.Doc,
        mixer = AudioMixer.Mixer,
        dialogue = Yarn.Program
    }

    // ── Doc の差し替え（保存即反映。Controls.docTable の reload） ──

    pub def withStory(story: StoryDoc.Doc, res: Res): Res = { story = story | res }

    pub def withKind(kind: KindDoc.Doc, res: Res): Res = { kind = kind | res }

    pub def withTheme(theme: ThemeDoc.Doc, res: Res): Res = { theme = theme | res }

    pub def withBackdrops(backdrops: BackdropDoc.Doc, res: Res): Res = { backdrops = backdrops | res }

    pub def withCredits(credits: CreditsDoc.Doc, res: Res): Res = { credits = credits | res }

    pub def withKeys(keys: KeysDoc.Doc, res: Res): Res = { keys = keys | res }

    pub def withMixer(mixer: AudioMixer.Mixer, res: Res): Res = { mixer = mixer | res }

    /// シナリオの木を差し替える（読んでいる所を新しい木へ収め直すのは WorldRead.settleDialogue）。
    pub def withDialogue(dialogue: Yarn.Program, res: Res): Res = { dialogue = dialogue | res }
}
