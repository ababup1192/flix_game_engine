# 音（効果音・鳴り続ける音・BGM・ミキサー・合成）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| 効果音を鳴らしたい | App.withAudio（前後 World の差分から鳴らす名前の List を返す。詳しくは [audio.md](../audio.md)。実例: `templates/game-starter/src/Main.flix`） |
| 鳴り続ける音を出したい（走行音・風・雨・炎・足音のループ） | App.withSustained（World から「鳴り続けていてほしい音」を宣言。音量と高さを毎フレーム与える。詳しくは [audio.md](../audio.md)。実例: `templates/race-starter/src/Sfx.flix`） |
| BGM を流す・止める・音量やループを変える | AudioStreamPlayer（play / stop / setVolume / setLooping。詳しくは [audio.md](../audio.md)） |
| 曲の頭（イントロ）を 1 回だけ鳴らし、後ろの輪だけを回す | WAV のループ点（SfxSynth.renderLooped で smpl チャンクを書く・実機と AudioMixdown.mixdownLooped が読む。[audio.md](../audio.md) の「ループ点」） |
| BGM をだんだん出す・消す・入れ替える（音量カーブ） | AudioFade |
| 音をバス（曲・効果音・UI・声）に分けて音量を決めたい・効果音の間だけ BGM を下げたい（ダッキング）・高い音を削って籠もらせたい（ローパス）・同じ音の細かい連打を間引きたい・場面ごとの聞こえ方を切り替えたい（スナップショット） | App.withMixer + AudioMixer（mixer.json は AudioMixerDoc。詳しくは [audio.md](../audio.md)） |
| 実機と同じ規則で混ぜた音を WAV に書き出したい（動画の音・聞き比べ） | AudioMixdown（コマごとの withAudio / withSustained / withMixer の結果から波形を作る） |
| 効果音の素材を録音なしで作りたい（波形合成） | SfxSynth（engine_tools。詳しくは [audio.md](../audio.md)。実例: `templates/race-starter/src/render/SfxRender.flix`） |

## モジュール 1 行紹介

- **AudioFade** — 進行度 t から音量をひとつ決める（フェードイン・アウト・クロスフェード）。
- **AudioMixer** — 音の通り道。バス・振り分け・ダッキング・ローパス・クールダウン・スナップショットを State を持ち回す純関数で決める（App.withMixer と AudioMixdown が同じ step を呼ぶ）。
- **AudioMixerDoc** — mixer.json の fail-open 読み込み（schema は docs/mixer.schema.json）。
- **AudioMixdown** — AudioMixer を通した音を、ウィンドウ無しで 1 本の波形へ書き出す（実機と同じ規則: 1 つの名前は同時に 1 本・鳴り直すと頭から・ループ点のある曲は mixdownLooped で頭を 1 回だけ鳴らす）。
