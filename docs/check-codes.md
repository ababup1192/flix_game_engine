# 検査の code の表

bin/fge check codes --md が go/internal/checkres の表から書き出す（手で直さない）。
1 件の形・status（pass/near/fail）・score・next・終了コードの決まりは docs/check-results.md。
near の帯は bin/lint-rules/checkfmt.json の near（code ごと。無ければ nearRatio）。

| code | level | metric | unit | want | 基準の出どころ | 説明 |
|---|---|---|---|---|---|---|
| `doc-refs.caller` | gate | stale_callers | count | <= | doc-refs.json callersLimitFile | .flix のコメント（/// と //）の「名前 が呼ぶ・から呼ぶ・が読む・が使う・が組む・が受け取る・で受け取る」（doc に書いた呼び手。関数を移すと古くなる）。上限で数える |
| `doc-refs.file` | gate | missing_files | count | <= | doc-refs.json pathSkipPrefixes | 文書が指すパス（src/…flix・docs/…md など / を含む物）が無い |
| `doc-refs.line` | gate | missing_lines | count | <= | doc-refs.json | 文書の path:行 の行がそのファイルの行数を超える |
| `doc-refs.name` | gate | missing_names | count | <= | doc-refs.json sources・spansIndex | 文書の ` ` と表が指す Mod.name が src・test の宣言に無い（頭のモジュールがこのリポの物だけ） |
| `px.anim.area` | lint | area_drift | ratio | <= | anim.json maxAreaDrift | 1 コマ目に対する面積のずれ |
| `px.anim.bob` | lint | bob_px | px | <= | anim.json maxBob | 頭の上下動 |
| `px.anim.ground` | lint | float_px | px | <= | anim.json footTolerance | 足が地面から浮く |
| `px.anim.loop` | lint | swap_share | ratio | <= | anim.json maxPopShare | 最後 → 最初のコマで入れ替わる割合（輪が閉じない） |
| `px.anim.pop` | lint | swap_share | ratio | <= | anim.json maxPopShare | 隣のコマでシルエットが入れ替わる割合 |
| `px.black-outline` | advice | edge_colors | count | >= | px.json blackOutlineMaxSize | 小さい絵の外の縁が 1 色の最暗のまま一周 |
| `px.decl.fidelity-over` | advice | machine_fidelity | fidelity | <= | checkset-design §9.2 | 機種の fidelity が門の画風より細かい（門の画風から外れる） |
| `px.decl.fidelity-unknown` | advice | fidelity_known | bool | == | checkset-design §9.2 | 塗りの細かさ fidelity が門にも機種にも無い |
| `px.decl.kind-mismatch` | advice | kind_agrees | bool | == | checkset-design §2 | 宣言した kind と推した kind が違う（kind_why で理由を書けば出ない） |
| `px.decl.kind-missing` | advice | kind_declared | bool | == | checkset-design §2 | sprite に kind が無い（推した kind で回した・fix は set kind） |
| `px.decl.kind-unknown` | advice | kind_inferred | bool | == | checkset-design §2 | kind を推せない（prop で回した） |
| `px.decl.lint-sprite-unknown` | advice | rule_known | bool | == | checkset-design §4 | lint-sprite の対象外に知らない規則名（効いていない） |
| `px.decl.material-missing` | advice | material_declared | bool | == | px.json materialMinPx | character・prop・background の大きな部品に material が無い（無い物は none） |
| `px.exempt-overuse` | advice | exempt_px_per_frame | px | <= | px.json exemptPerFrameMax | op の Exempt で外した画素のコマあたりの数 |
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
| `px.glow.core` | advice | core_share | ratio | <= | px.json glowCoreMaxShare（依頼主の決定 案 C） | emissive の部品の芯（最明色）がコマに占める割合 |
| `px.glow.dim` | advice | emissive_minus_rest_L | L | >= | px.json emissiveMinGap | emissive の部品の平均の明るさ − まわりの平均（光らない物の emissive） |
| `px.ground-contrast` | lint | edge_ground_dL | L | >= | px.json groundContrastMin | 外周と地の色の明るさ（Oklab の L）の差の平均 |
| `px.ground-contrast.chroma` | advice | bright_ground_chroma | C | <= | px.json groundBrightL・groundBrightChromaMax | 明るい地（L ≥ groundBrightL）の彩度（Oklch の C） |
| `px.ground-contrast.highlight` | advice | highlight_minus_ground_L | L | >= | value-structure §4 | 地が絵の最明色より暗い（絵の最明色の L − 地の L） |
| `px.highlight-reserve.area` | advice | brightest_share | ratio | <= | px.json highlightMaxShare | 最明色が描いた画素に占める割合（ハイライト専用） |
| `px.highlight-reserve.inside` | advice | brightest_inside_share | ratio | <= | px.json highlightInsideMax | 最明色の画素のうち面の中（四方が同じ色）にある割合 |
| `px.light-dir` | advice | bright_toward_light | dot | >= |  | 明るい段の重心の向きと光の向きの内積（負なら光と反対） |
| `px.margin` | advice | touching_sides | count | <= |  | 動く絵が格子の左・右・上の縁に触れる |
| `px.outer-aa` | advice | outer_aa_px | px | <= | px.json outerAAMax | 透明に接する外周の段の角の中間色の 1px（全域で避ける） |
| `px.pillow` | advice | lit_dark_edge_dL | L | >= | px.json pillowSideGap | 縁を一様に暗くした陰（光の側と影の側の縁の明るさの差） |
| `px.ramp-chroma.bright` | advice | bright_s | S | <= | px.json rampBrightV・rampBrightSMax | 明るい段（HSV の V ≥ rampBrightV）の S の最大（高明度 × 高彩度） |
| `px.ramp-chroma.peak` | advice | peak_offset | steps | <= | px.json rampChromaPeakSlack | 彩度の一番高い段の真ん中からのずれ（山の形） |
| `px.ramp-hue.flat` | advice | hue_total | deg | >= | px.json rampHueMinTotal | ランプが暗 → 明で回る色相の合計（平板） |
| `px.ramp-hue.step` | advice | max_hue_step | deg | <= | px.json rampHueMaxStep | ランプの隣の段の色相の差の最大 |
| `px.ramp-hue.turn` | advice | hue_turns | count | <= |  | ランプの色相の回る向きが変わる回数 |
| `px.ramp-order` | lint | step_dL | L | >= | px.json rampMinGap | ランプの隣の段の明るさの差（暗 → 明に単調） |
| `px.run-monotone` | lint | turns | count | <= |  | 曲線の段の長さが増減する（3-2-1 は良い・1-2-1-2 は不可） |
| `px.seam.x` | lint | edge_dL | L | <= | px.json seamRatio | タイルの左右の端の差（内側の差の seamRatio 倍か、内側の一番強い線まで） |
| `px.seam.y` | lint | edge_dL | L | <= | px.json seamRatio | タイルの上下の端の差 |
| `px.sprite.banding` | lint・advice | ring_px | px | <= | px.json bandingRingMin | 輪郭の内側 1px の縁取りだけに使う色（輪をほぼ一周する時だけ lint） |
| `px.sprite.connect` | lint | blobs | count | <= | sprite.json minConnectCells | 絵が離れた塊に分かれている（塊の数） |
| `px.sprite.corner` | advice | double_corner_px | px | <= |  | 1px の線の L 字の角に 2 重に乗った画素 |
| `px.sprite.jaggy` | lint | jaggy_spots | px | <= | sprite.json jaggyMinCount | 輪郭のがたつき（段の長さが乱れた所の数） |
| `px.sprite.legend-char` | gate | bad_legend_chars | count | <= | pxlib.LegendCharProblem（依頼主の決定 2026-10-18） | legend の印に右から左へ書く字・幅が 1 でない字・結合文字（bin/fge px relegend で振り直す） |
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
| `px.tile-variant-edge` | advice | edge_diff_px | px | <= | px.json tileVariantEdge | タイルの変種の縁が元の種のコマと違う画素 |
| `px.value-blobs.count` | advice | value_masses | count | range | px.json valueBlobsMin・valueBlobsMax・valueBlobsMinShare | 明るさ 3 段の大きな塊の数（明暗の骨格） |
| `px.value-blobs.cover` | advice | mass_cover | ratio | >= | px.json valueBlobsCoverMin | 大きな塊が描いた画素を覆う割合 |
| `px.value-sep` | lint | part_dL | L | >= | px.json valueSepMin か contrast の min | contrast で測った部品と相手の明るさの差 |
| `refactor.add-field` | lint | construction_left | count | <= | 0（欄の組が同じ別の型の組み立ては fix） | record の型 alias に欄を足し、組み立てる式にも値を足した後に、人へ回した数 |
| `refactor.change-case-shape` | lint | case_sites_left | count | <= | 0（case を関数として渡す所・消す欄を使う本体は fix。fix があれば書かない） | enum の case の欄を足した・消した後に、宣言と形の合わない作る所・当てる所として人へ回した数 |
| `refactor.change-signature` | lint | call_sites_left | count | <= | 0（関数として渡す所・2 回使う引数に式が渡る所・消える引数を使う本体は fix。fix があれば書かない） | def の引数の並びを替えた後に、新しい並びで呼べない所として人へ回した数 |
| `refactor.expand-wildcard` | lint | catch_all_left | count | <= | 0（書き出せない腕は fix） | enum への match の `case _` を残りの case に書き出した後に、人へ回した腕の数 |
| `refactor.extract-function` | lint | extract_left | count | <= | 0（型の変数・局所の def・書けない型・効果のある式を引数に渡す所は fix） | 選んだ式（と --all で同じ形の式）を新しい def に出して呼び出しへ替えた後に、人へ回した数 |
| `refactor.extract-type-alias` | lint | record_type_left | count | <= | 0（本体がちょうどその組の別の alias は fix） | 閉じた record の型に名前を付けて type alias を置き、同じ欄の組を型に書いた所を名前へ替えた後に、人へ回した数 |
| `refactor.field-sites` | lint | field_sites | count | <= | --max（欄の歯止めは --outside <口の mod> --max 0） | record の欄の直の読み書きの数（受け手の型 alias で絞る） |
| `refactor.field-to-accessor` | lint | field_sites_left | count | <= | 0（受け手の型が決まらない・読めない式・型の違う口は fix） | record の欄の直の読み書きを口（読み・書き）へ替えた後に、人へ回した数 |
| `refactor.fix-construction` | lint | construction_left | count | <= | 0（欄の組が同じ別の型の組み立ては fix） | record を組み立てる式の欄を型に合わせた（足した・消した）後に、人へ回した数 |
| `refactor.make-private` | lint | private_left | count | <= | 0（外の使い手がいる・どこからも参照されない・名前が入口のファイル（Makefile・json など）に出る・ライブラリの def は fix） | 外の mod から使われない pub の def から pub を外した後に、人へ回した数 |
| `refactor.match-sites` | lint | match_sites | count | <= | --max（無ければ一覧だけ） | enum（か case）への match の数。--catch-all なら `_`・変数の腕を持つ物だけ |
| `refactor.move` | lint | move_sites_left | count | <= | 0（元の mod の非 pub の物を使う・移す非 pub の物を外が使う・読めない use は fix。fix があれば書かない） | def・型 alias を別の mod へ移した後に、新しい mod を指せない所として人へ回した数 |
| `refactor.refs` | lint | refs | count | <= | --max（無ければ一覧だけ） | def・enum・case の参照の数（宣言は数えない） |
| `refactor.remove-dead` | lint | dead_left | count | <= | 0（決められない def は fix） | テストからだけ・どこからも参照されない pub の def を消した後に、人へ回した数 |
| `refactor.remove-field` | lint | construction_left | count | <= | 0（直の読み書きが残れば止める・欄の組が同じ別の型の組み立ては fix） | record の型から欄を消し、組み立てからも消した後に、人へ回した数（止めた時は残っている直の読み書きの数） |
| `refactor.remove-param` | lint | call_sites_left | count | <= | 0（本体が使う引数・関数として渡す所は fix。fix があれば書かない） | def の使っていない引数を宣言と呼ぶ所から消した後に、人へ回した数 |
| `refactor.remove-use` | lint | unused_use_left | count | <= | 0（同じ行に別の物がある・名前が見つからない use は fix） | 使っていない use・import（flixlint の unused-use と同じ判定）を消した後に、人へ回した数 |
| `refactor.rewrite` | lint | rewrite_left | count | <= | 0（穴の式が書かれた所に無い・型紙の外にコメントがある所は fix） | 型紙（Flix の式の形と穴）に当たる式を別の式へ書き替えた後に、人へ回した数 |
| `refactor.unused` | lint | unused | count | <= | --max（無ければ一覧だけ） | 外から使われない pub の def（参照 0・テストからだけ・同じ mod の中だけ）と、使っていない use の数 |
| `refactor.usages` | lint | usages | count | <= | --max（無ければ一覧だけ） | def・enum・case・型 alias・record の欄の使われ所の数（呼び出し・参照・読み・書き・組み立て・パターン・型の注記・use） |
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
| `state-shape.bool-fields` | gate | bool_fields | count | <= | state-shape.json boolFieldMin・state-shape.local.json boolFieldLimits | 状態の record の Bool の欄の数（今の数までは歯止めの表で許し、増えたら止める） |
| `state-shape.catch-all` | gate | catch_all_arms | count | <= | state-shape.local.json stateEnums | 名指しした状態の enum への match の `case _ =>`（case を足しても型検査が知らせない） |
| `state-shape.option-bool` | gate | option_bool | count | <= | state-shape.local.json exempt | Option[Bool]（3 つの状態を名前の無い型で持つ） |
| `state-shape.view-effect` | gate | concrete_effects | count | <= | state-shape.json viewFiles | View の def が決まった効果（IO など）を持つ |
| `tickets.cause` | advice | tickets_caused | count | <= | tickets.json causeMax | 1 つの直し（コミット・チケット）が生んだチケットの数 |
| `tickets.filled` | advice | filled_ratio | ratio | >= | tickets.json filledMin | 閉じたチケットのうち regressedBy が unknown でない割合 |
| `tickets.regressed` | advice | regressed_ratio | ratio | <= | tickets.json regressedMax | regressedBy の埋まったチケットのうち、前の直しが生んだ割合 |
