/// 効果音や BGM を論理名で鳴らすオーディオ再生モジュール。
/// 実ファイルのパスではなくサウンドマニフェスト上の名前で指定するので、ゲームロジックは
/// ファイルの場所を知らずに「この音を鳴らす」とだけ書ける。
/// 利用例: BGM をループ再生する / 効果音を音量を指定して鳴らす。
///
/// `GameEngine.Audio` effect 経由で、サウンドマニフェスト (EngineConfig#soundManifest) の
/// 論理名をキーに再生・停止・音量・ループを操作する。
///
/// 使い方:
///   AudioStreamPlayer.play("bgm")
///   AudioStreamPlayer.stop("bgm")
///   AudioStreamPlayer.setVolume("bgm", 0.5)
///   AudioStreamPlayer.setLooping("bgm", true)
///
/// enum 本体は stream / autoplay / loop / volume を保持する値で、`applyAttach` で
/// まとめて反映できる。
pub enum AudioStreamPlayer {
    case AudioStreamPlayer({
        stream   = String,    // サウンドマニフェスト (project.json#sounds) の論理名
        autoplay = Bool,      // scene attach 時に自動再生する
        loop     = Bool,      // 再生時に AL_LOOPING を ON にする
        volume   = Float64    // 音量 (gain), 0.0–1.0
    })
}

pub mod AudioStreamPlayer {

    /// デフォルト値で AudioStreamPlayer を生成する
    pub def make(stream: String): AudioStreamPlayer =
        AudioStreamPlayer.AudioStreamPlayer({
            stream   = stream,
            autoplay = false,
            loop     = false,
            volume   = 1.0
        })

    /// 指定した名前のオーディオを再生する（先頭から再生し直す）
    pub def play(name: String): Unit \ GameEngine.Audio =
        GameEngine.Audio.playAudio(name)

    /// 指定した名前のオーディオを停止する
    pub def stop(name: String): Unit \ GameEngine.Audio =
        GameEngine.Audio.stopAudio(name)

    /// 指定した名前のオーディオの音量（gain）を 0.0〜1.0 で設定する。
    /// 再生中・停止中のいずれでも反映され、次回 play 後も維持される。
    pub def setVolume(name: String, volume: Float64): Unit \ GameEngine.Audio =
        GameEngine.Audio.setVolume(name, volume)

    /// 指定した名前のオーディオの高さ（再生速度）を変える。1.0 = 元のまま・
    /// 2.0 で 1 オクターブ上・0.5 で 1 オクターブ下。鳴っている音にも即座に効く。
    pub def setPitch(name: String, pitch: Float64): Unit \ GameEngine.Audio =
        GameEngine.Audio.setPitch(name, pitch)

    /// 指定した名前のオーディオの loop フラグ (AL_LOOPING) を実行時に切り替える。
    /// 次回 play 後はもちろん、現在再生中の音にも即座に反映される。
    pub def setLooping(name: String, loop: Bool): Unit \ GameEngine.Audio =
        GameEngine.Audio.setLooping(name, loop)

    /// enum が保持する設定を一括反映する。volume → looping → (autoplay なら play) を順に適用する。
    pub def applyAttach(player: AudioStreamPlayer): Unit \ GameEngine.Audio =
        let AudioStreamPlayer.AudioStreamPlayer(r) = player;
        GameEngine.Audio.setVolume(r#stream, r#volume);
        GameEngine.Audio.setLooping(r#stream, r#loop);
        if (r#autoplay) GameEngine.Audio.playAudio(r#stream) else ()

}
