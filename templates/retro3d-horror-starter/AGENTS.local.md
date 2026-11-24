# このゲーム固有の設計原則

（ここに、このゲームだけの原則を書く。共通の作法はエンジン側の AGENTS.core.md が
sync で AGENTS.md に入るので、重複して書かない。書いたら engine 側で
`make sync-agents GAME=<このフォルダ>` を再実行して AGENTS.md に反映する。）

作例は「夜の校舎」: 木造 3 階建ての夜の校舎を一人称で歩き、3 人の人物と話し、鍵を拾って閉じた部屋を開ける。
曲（BGM）は鳴らさず、足音を主役に、空気・時計・戸・風を足音より小さく置く。

## 状態の置き場

- 場面の値は場面の enum（`World.Screen` の case の payload）の中に・Doc と描く元は `Res` に。World の一番上の欄に足していかない。

## この画面の画風

人の注文（人の言葉を写した制約）:
- 夜の学校を徘徊するゲーム。FPS 視点（一人称）。
- 低ポリゴンで、1990 年代後半の家庭用 3D ゲーム機のような、粗いけど怖い画質（参考は薄暗い木造の廊下の画面。既存作品のキャラや形は真似しない）。
- 木造の校舎・3 階建て。音楽室・理科室などの特別教室と、普通の机が並ぶ教室。
- 薄暗い（真っ暗ではなく、廊下の奥が闇に沈み、手前の壁と床の木目が見える程度）。

この上で決めた事:
- 題材は夜の木造校舎（板張りの床・漆喰の壁・腰板）。色は 3 つ: 下地 = 黒に近い霧の色（#030302）/ 主役 = 部屋の明かりに浮かぶ木の飴色（校舎の頂点の色にベイクしてある）/ 差し色 = 非常口の緑（#33ff73）。光 = 月の青白（#9eb3ff）・影 = 霧の黒。
- 320×240 のまま補間なしで拡大し、テクスチャも Nearest。PS1 風の描き方（`Scene3d.withPsx`: 色の段数を落とす・ディザ・頂点のがたつき・テクスチャの歪み）とテレビのにじみ（走査線・色のにじみ）は `assets/night_school.look.json` の psx で調整する。
- やらないこと: なめらかにしない（ブルーム・縁のならし・テクスチャの補間を掛けない。にじみはテレビの横のにじみだけ）。

## どこを直すか（早見表）

| したいこと | 直す所 |
|---|---|
| 暗さ・霧・月明かり・非常口の灯り・PS1 風の強さ・字幕の見た目 | `assets/night_school.look.json` |
| 歩く速さ・走る速さ・1 歩の長さ・マウスの効き | `assets/walk.kind.json` |
| 音の大きさと距離での聞こえ方（足音が主役） | `assets/sound.kind.json` |
| 音そのもの（足音・戸・時計・空気・風・拾う・紙） | `src/render/SfxRender.flix` を直して `bin/fge task sfx`（macOS と Linux は `make sfx` も）（WAV を書き直す） |
| 人物の置き場所・向き・話しかけ方 | `assets/characters.kind.json`（台詞は `assets/talk/night.yarn` を直して `bin/fge yarn build`） |
| 拾える物・鍵のかかった部屋 | `assets/items.kind.json` |
| キーの割り当て | `assets/player.keys.json` |
| 校舎の形・部屋・小物の置き場所 | Blender などで glb と `assets/school/layout.json` を書き出し直して `bin/fge task bundles`（macOS と Linux は `make bundles` も） |

- Doc は保存すると走っているゲームにその場で映る。校舎の glb と layout.json だけは起動し直す。
- ゲームが読むのは束（`assets/school/bundle/*.glb`）。元の glb か `layout.json` を替えたら `bin/fge task bundles`（`bin/fge task bundles-check`（macOS と Linux は `make bundles-check` も） で束が古くないかを見る）。
- 描き出し（`make render` / `render-all`）は CPU で描く。
