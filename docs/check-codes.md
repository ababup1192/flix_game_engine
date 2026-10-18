# 検査の code の表

bin/fge check codes --md が go/internal/checkres の表から書き出す（手で直さない）。
1 件の形・status（pass/near/fail）・score・next・終了コードの決まりは docs/check-results.md。
near の帯は bin/lint-rules/checkfmt.json の near（code ごと。無ければ nearRatio）。

| code | level | metric | unit | want | 基準の出どころ | 説明 |
|---|---|---|---|---|---|---|
| `px.anim.area` | lint | area_drift | ratio | <= | anim.json maxAreaDrift | 1 コマ目に対する面積のずれ |
| `px.anim.bob` | lint | bob_px | px | <= | anim.json maxBob | 頭の上下動 |
| `px.anim.ground` | lint | float_px | px | <= | anim.json footTolerance | 足が地面から浮く |
| `px.anim.loop` | lint | swap_share | ratio | <= | anim.json maxPopShare | 最後 → 最初のコマで入れ替わる割合（輪が閉じない） |
| `px.anim.pop` | lint | swap_share | ratio | <= | anim.json maxPopShare | 隣のコマでシルエットが入れ替わる割合 |
| `px.black-outline` | advice | edge_colors | count | >= | px.json blackOutlineMaxSize | 小さい絵の外の縁が 1 色の最暗のまま一周 |
| `px.flat-run.poly` | advice | run_kinds | count | <= |  | poly の辺の段の長さが 3 種類以上に散る |
| `px.flat-run.repeat` | advice | same_runs | count | <= | px.json flatRunRepeat | 同じ長さの段が続く（直線に読まれる） |
| `px.flat-run.straight` | advice | run_px | px | <= | px.json flatRunStraight・flatRunPer | 曲線の中の長すぎる直線 |
| `px.flicker` | lint | flicker_px | px | <= |  | コマの間で周りが動かないのに色だけ変わる画素 |
| `px.gate.bad-style` | gate | bad_colors | count | <= | <名前>.colorgate.json | 色の門: styles に無い画風 |
| `px.gate.deny` | gate | bad_colors | count | <= | <名前>.colorgate.json | 色の門: どの画風でも使わない色 |
| `px.gate.no-color` | gate | bad_colors | count | <= | <名前>.colorgate.json | 色の門: 色票に無い色の名前 |
| `px.gate.no-entry` | gate | bad_colors | count | <= | <名前>.colorgate.json | 色の門: files に無い冊 |
| `px.gate.outside` | gate | bad_colors | count | <= | <名前>.colorgate.json | 色の門: 画風の色の外 |
| `px.gate.unreadable` | gate | bad_colors | count | <= | <名前>.colorgate.json | 色の門: 読めない冊 |
| `px.ground-contrast` | lint | edge_ground_dL | L | >= | px.json groundContrastMin | 外周と地の色の明るさ（Oklab の L）の差の平均 |
| `px.light-dir` | advice | bright_toward_light | dot | >= |  | 明るい段の重心の向きと光の向きの内積（負なら光と反対） |
| `px.margin` | advice | touching_sides | count | <= |  | 動く絵が格子の左・右・上の縁に触れる |
| `px.pillow` | advice | lit_dark_edge_dL | L | >= | px.json pillowSideGap | 縁を一様に暗くした陰（光の側と影の側の縁の明るさの差） |
| `px.ramp-order` | lint | step_dL | L | >= | px.json rampMinGap | ランプの隣の段の明るさの差（暗 → 明に単調） |
| `px.run-monotone` | lint | turns | count | <= |  | 曲線の段の長さが増減する（3-2-1 は良い・1-2-1-2 は不可） |
| `px.seam.x` | lint | edge_dL | L | <= | px.json seamRatio | タイルの左右の端の差（内側の差の seamRatio 倍か、内側の一番強い線まで） |
| `px.seam.y` | lint | edge_dL | L | <= | px.json seamRatio | タイルの上下の端の差 |
| `px.sprite.banding` | lint・advice | ring_px | px | <= | px.json bandingRingMin | 輪郭の内側 1px の縁取りだけに使う色（輪をほぼ一周する時だけ lint） |
| `px.sprite.connect` | lint | blobs | count | <= | sprite.json minConnectCells | 絵が離れた塊に分かれている（塊の数） |
| `px.sprite.corner` | advice | double_corner_px | px | <= |  | 1px の線の L 字の角に 2 重に乗った画素 |
| `px.sprite.jaggy` | lint | jaggy_spots | px | <= | sprite.json jaggyMinCount | 輪郭のがたつき（段の長さが乱れた所の数） |
| `px.sprite.orphan` | gate・lint | orphan_px | px | <= | sprite.json | 周り 8 方向が透明の 1 画素（タイルは 3×3 に並べて見る） |
| `px.sprite.palette.colors` | lint | colors | count | <= | sprite.json maxColors・maxColorsBig | 1 スプライトの色数が目安を超える |
| `px.sprite.palette.delta-e` | lint | delta_e | ΔE | >= | sprite.json deltaEMin | legend の 2 色が近すぎる |
| `px.sprite.silhouette.sparse` | lint | bbox_fill | ratio | >= | sprite.json silhouetteMinOcc | シルエットが外接箱に対してスカスカ |
| `px.sprite.silhouette.thin` | lint | short_side | px | >= |  | シルエットが細長すぎる（短い辺 2px 以下で長い辺 8px 以上） |
| `px.sprite.structure` | gate | broken | count | <= |  | sprite.json の形の誤り（rows・legend・anchor・空のコマ・同じコマ） |
| `px.style.color` | gate | outside_colors | count | <= | px.json styles.colors・channelLevels | 機種で出せない色 |
| `px.style.colors` | gate | colors | count | <= | px.json styles.maxColors | 1 コマの色数 |
| `px.style.palette` | gate・advice | palettes_needed | count | <= | pxstyle palettes | パレット N 本 × M 色に割り付けられない（下限で言い切れない時は advice） |
| `px.style.size` | gate | size_over | ratio | <= | px.json styles.maxSize | 機種の最大の大きさに対する長い辺の割合 |
| `px.style.tile-colors` | gate | tile_colors | count | <= | px.json styles.maxTileColors | 升目ごとの色数 |
| `px.value-sep` | lint | part_dL | L | >= | px.json valueSepMin か contrast の min | contrast で測った部品と相手の明るさの差 |
| `snd.alias` | advice | third_harmonic_hz | Hz | <= |  | パルスの 3 倍音とナイキスト周波数 |
| `snd.bars` | gate | bar_off | samples | <= | snd.json barTolerance | 輪の長さと tempo の整数小節の差 |
| `snd.breaks` | advice | breaks | count | <= |  | 使った機種の外の手（style が許す物。破った所として残す） |
| `snd.clip` | gate | over_samples | count | <= |  | ±1 を超えた・song の仕上げで切ったサンプル |
| `snd.dc` | lint | mean | amp | <= | snd.json dc | 直流（平均の大きさ） |
| `snd.drone` | gate | held_s | s | <= | snd.json droneSeconds | song の 1 本のチャンネルが打ち直さず高さも変えずに鳴る長さ（離し忘れ） |
| `snd.head` | lint | onset_ms | ms | <= | snd.json headSilenceMs | 鳴り出しの遅れ（ループしない音） |
| `snd.loudness` | lint | integrated | LUFS | range | snd.json loudness | 統合ラウドネス（ループする音は輪の 1 周） |
| `snd.peak` | lint | sample_peak | dBFS | <= | snd.json peakDbfs | サンプルのピーク |
| `snd.seam.level` | gate | seam_level_diff | dB | <= | snd.json seamLevelDb | 継ぎ目の前後 20ms の音量の差 |
| `snd.seam.step` | gate | seam_step | amp | <= | snd.json seamStepRatio | ループの継ぎ目（終わり → 頭）の段差 |
| `snd.style.break` | gate | outside_breaks | count | <= | snd.json styles.breaks | 破ってよい所（breaks）の外の手 |
| `snd.style.duty` | gate | outside_duty | count | <= | snd.json styles.duties | パルスの duty が機種の外 |
| `snd.style.noise-kind` | gate | outside_kind | count | <= | snd.json styles.noiseKinds | 雑音の作り方が機種の外 |
| `snd.style.op` | gate | outside_ops | count | <= | snd.json styles.ops | 機種の外の op |
| `snd.style.voices` | gate | voices | count | <= | snd.json styles.voices | 部品ごとに同時に鳴らす声の数 |
| `snd.tail` | lint | last_sample | amp | <= | snd.json tailClick | 終わりのサンプルの大きさ（0 へ戻らずプツと鳴る） |
| `snd.truepeak` | lint | true_peak | dBTP | <= | snd.json truePeakDbtp | 4 倍に読み直したピーク |
