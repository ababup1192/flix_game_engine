# J: 影 MOD・シェーダーパックのライセンスと、技法を学べる出どころ

調査日 2026-11-14。**これは法律の助言ではなく、人が判断するための材料集め**。
確度の印: 【確】= LICENSE などのファイルを自分で開いて確かめた / 【推】= 一次ではあるが部分的、または二次の情報も混ざる / 【不明】= 確かめられない。
ライセンスは版・時期で変わる。各行に「いつの版か」を添える（GitHub の既定枝の 2026-11 時点を指す。枝名は Minecraft の版が `26.x` に進んでいる）。
エンジン自身は MIT（根の LICENSE【確】）。

エンジンの今の描画（docs/scene3d.md・shader-doc.md【確】）: 太陽のカスケード 1 段の影+PCF・スポットの影・点光源/スポット・PBR（metallic/roughness+空/環境マップの映り込み）・lightmap・かすみ・グラデーションの空・MSAA・HDR の Pass・`PostProcess`（AcesFitted/Reinhard のトーンマップ+FXAA）・`blur`/`tex` による Pass 連鎖。
無い物: SSAO・SSR・bloom（部品として）・TAA・体積の光/雲・水・LUT・probe・PCSS・contact shadow・parallax・floodfill の光。

## 1. 影 MOD の側（読み込む土台と最適化）

| 名前 | ライセンス（版） | 言語 | 何をする物 / エンジンの参考 |
|---|---|---|---|
| Iris | LGPL-3.0【確】 https://github.com/IrisShaders/Iris/blob/HEAD/LICENSE （README は「読む・配る・改変は LGPLv3 の条件で自由」。依存の glsl-transformer は AGPL-3.0 で配布に影響しうると README が明記 https://github.com/IrisShaders/Iris#license ） | Java | OptiFine 互換のシェーダーパック読み込み。パスの組み立て・uniform の供給・GLSL の書き換え。**パックの決まりの実装の手本**（gbuffers/shadow/deferred/composite/final の順の作り方） |
| OptiFine | **ソース非公開**・独自の利用条件【推】（optifine.net の license ページは 2026-11 に 404【確】。公式のシェーダー文書 repo https://github.com/sp614x/optifine には LICENSE が無い【確】） | Java | 決まりの元祖。読んで学ぶ対象にしない（下の ShaderDoc で足りる） |
| Sodium | **PolyForm Shield 1.0.0**【確】 https://github.com/CaffeineMC/sodium/blob/dev/LICENSE.md ・README も同じ旨 。0.5.x まで LGPL-3.0 だった【推】（Embeddium が「0.5.8 ベース」で LGPL 継続。LICENSE.md の履歴は 2024-04 に「ライセンス付与の情報を更新」の 1 件だけ確認【確】）。条件の要点: 使う・配る・改変は可だが、**自分の製品と競合する物の提供は許可の目的から外れる**（「無料でも競合は競合」の旨） | Java | 区画（16³）ごとの mesh を別スレッドで作り、頂点を 1 本の大きなバッファに詰めて、まとめて描く。**読んで学ぶ分には良さそうだが、コードは取り込まない**（競合の制限が不明瞭・エンジンは描画エンジンなので競合と見られうる）。技法は本・論文・他の物でも学べる |
| Embeddium | LGPL-3.0【確】（COPYING） https://github.com/embeddedt/embeddium | Java | Sodium 0.5.8 の fork。**LGPL 版の Sodium 系を読みたいならこちら**（取り込むなら LGPL の条件） |
| Indium | Apache-2.0【確】 https://github.com/comp500/Indium/blob/1.21.x/main/LICENSE | Java | Sodium 上の Fabric Rendering API。材質の受け渡しの手本。小さい |
| Canvas Renderer | LGPL-3.0【確】（最終 push 2024-06） https://github.com/vram-guild/canvas | Java | **パイプライン自体を JSON+GLSL で宣言する**描き手（Pass・材質・シェーダーを設定ファイルで組む）。エンジンの「木で組む Pass」と思想が近い。**読む価値が高い** |
| Lithium | LGPL-3.0【確】 https://github.com/CaffeineMC/lithium/blob/develop/LICENSE.md | Java | ゲームロジックの最適化（描画ではない）。対象外 |
| Starlight | LGPL-3.0（LICENSE の先頭【確】・archived） https://github.com/PaperMC/Starlight | Java | 光の伝播（ブロックの光の BFS）の書き直し。floodfill の光の手本。後継の ScalableLux も LGPL-3.0【確】 https://github.com/RelativityMC/ScalableLux |
| C2ME | **混在**: 大半 LGPL-3.0-only、`c2me-opts-accel-opencl/` などは All Rights Reserved【確】 https://github.com/RelativityMC/C2ME-fabric/blob/dev/26.3.0/LICENSE.md | Java | 区画生成の並列化（描画ではない）。対象外 |
| Distant Horizons | LGPL-3.0-only（Modrinth の表示と各ファイルの頭【確】。repo 根には LICENSE.txt（GPLv3 の本文）と LICENSE.LESSER.txt が並ぶ【確】。どちらが効くかの明記は README に無い【不明】） https://gitlab.com/distant-horizons-team/distant-horizons | Java | 遠くを「区画を粗い格子（LOD）にして別の描き手で」描く。ワールドの間引きの手本。**読んで学ぶ。コードは取り込まない方が安全**（LGPL か GPL かの揺れ） |

### シェーダーパックの決まり（パスと uniform）の文書
- **ShaderDoc**（Iris チーム）: LGPL-3.0 以降【確】 https://github.com/IrisShaders/ShaderDoc ・README に目的が「OptiFine の公式文書を写さず、決まりを独立に記す」と書いてある【確】。**この決まりの一番安全な読み物**。passes/・uniforms.md・directives/ がある。最終 push 2024-07。
- OptiFine の公式文書 `shaders.txt`: LICENSE が無く All Rights Reserved 扱いと ShaderDoc は明記【確】。読むのは良いが、写さない・訳さない。
- エンジンへの意味: パックの決まりに合わせる必要はない（ゲームに字を書かせない方針）。**パスの順（shadow → gbuffers → deferred → composite → final）の考え方**を学べば十分。

## 2. シェーダーパック

人気の上位は Modrinth の検索 API（downloads 順・2026-11-14 取得）でライセンスの宣言を拾い、そのうえで各リポジトリの LICENSE を開いた。
「学ぶ」= 読んで技法を自分で書く / 「取り込む」= コードを写す・改変。

| パック（版・時期） | ライセンス | 学ぶ | 取り込む | 主な技法 / 読みやすさ |
|---|---|---|---|---|
| Complementary Reimagined / Unbound（Agreement 1.7） | 独自 "Complementary License Agreement"【確】 https://github.com/ComplementaryDevelopment/ComplementaryReimagined/blob/main/License.txt 。許可の外は All Rights Reserved と明記（2.1）。Modified Pack の再配布は条件つき（名前・見た目の差・同じ契約）。**他の製品へ部品を移す許可は書かれていない** | 可（読む事を縛る文は見当たらない【確】） | **不可**（許可なし） | 影・ブルーム・SSR・雲・TAA など広い。コメントは多い。多くの後続パックがここから借りている |
| Rethinking Voxels（Agreement 1.3） | 上と同系の独自契約【確】 https://github.com/gri573/rethinking-voxels/blob/main/License.txt | 可 | 不可 | voxel を使った光の経路追跡・色つきの光。技法の宝庫だが重い |
| BSL（Modrinth の掲載文）| All Rights Reserved 表示【推】。作者の掲載文は「個人用の改変は可・大きく改変した版の公開は許可が要る・無断の再配布は不可・自作と名乗るのは不可」の旨。ソースの repo は公開されていない【不明】 https://modrinth.com/shader/bsl-shaders | 配布物を読むのは可と読める【推】 | 不可 | 影・体積の光・雲・SSAO・TAA・ブルーム。定番 |
| Sildur's Vibrant（掲載文） | All Rights Reserved 表示【推】。「編集・コードの写し・別名での再配布・自作と名乗る」を禁じる旨 https://modrinth.com/shader/sildurs-vibrant-shaders 。ソース repo は【不明】 | 可【推】 | **不可** | 軽い影・ブルーム・水 |
| Chocapic13 / 派生（LIGHT 等） | 独自の "Sharing and modification rules"。本人の原文は開けず、派生 repo の LICENSE で確認 https://github.com/At87668/LIGHT-Shaders/blob/main/LICENSE 【推】。要点: 改変の共有には題名の決まりと原作者のクレジット、同じ規則の転記が要る。自作と名乗るのは不可 | 可【推】 | 不可（独自の規則に縛られる） | 初期の影 MOD の手本（影の歪ませ・ブルーム・SSAO）。Bliss は "© 2020 Chocapic13. All rights reserved." の 1 行のみ【確】 https://github.com/X0nk/Bliss-Shader/blob/main/LICENSE.md |
| SEUS Renewed / PTGI | 条件は sonicether.com の LICENSE.txt【不明】（開けず。二次では「作者が随時変更できる・使う事が同意」の旨のみ【推】）。Modrinth の uShader（別物の可能性）は ARR 表示 | 【不明】 | 【不明】→不可として扱う | PTGI は voxel+パストレ。歴史的に重要 |
| Photon（sixthsurge）（2021-2025 版） | 独自 "Photon Shaders License Agreement"【確】 https://github.com/sixthsurge/photon/blob/main/LICENSE 。文言: 「Photon のソースを調べ、学んでよい（Examine and learn）」。個人用の改変可。一部の再配布は可だが Modrinth/CurseForge など収益を作者に与える場で、無断の配布は不可、金銭を求めるのも不可 | **可（明記）** | 微妙: 「改変した部分の再配布」は可とあるが、**別の製品への取り込み**は書かれていない【推】→許可を取るのが無難 | 大気の散乱の空・体積の雲・水・SSR・TAA・ブルーム。コード品質が高く評価が高い |
| Solas（Septonious） | 独自（GPL の文を元にした「All Rights Reserved unless otherwise」）【確】 https://github.com/Septonious/Solas-Shader/blob/main/LICENSE 。第 4 節: ソースの一部を別の独自プロジェクトに使うには**作者の明示の許可が要る**（クレジットと収益化の禁止も） | 可【推】（読む事の制限は無い） | **許可が要る** | 色つきの光・体積の雲・オーロラ・水・コースティクス・DoF |
| Super Duper Vanilla（License v1.6, 2024-11） | 独自 FlameRender Studios License【確】 https://github.com/Eldeston/Super-Duper-Vanilla/blob/master/LICENSE 。許可の外は ARR。modpack 同梱と、同じ契約での改変版の再配布は可 | 可【推】 | 不可（別製品への取り込みは許可の外） | 軽い。コードは読みやすい部類【推】 |
| Bliss | ARR 表示【確】（上） | 可【推】 | 不可 | Chocapic13 派生。雲・昼夜 |
| Kappa / Nostalgia / AstraLex / Lux | Modrinth で ARR 表示【推】。Lux は AGREEMENT.txt（ARR 表示）。ソース repo が無い物が多い【不明】 | 【不明】 | 不可 | — |
| **MakeUp - Ultra Fast** | **LGPL-3.0**（GitHub の LICENSE が LGPL-3.0 と判定【確】。Modrinth は LGPL-3.0-or-later 表示）https://github.com/javiergcim/MakeUpUltraFast ・README は「改変・利用の際は出どころのクレジットを」と求める【確】 | **可** | 可（LGPL の条件。エンジンが MIT なので**取り込むと LGPL の波及をどう扱うかを人が決める**。ファイル単位で分けて載せるなら可能性はある【推】） | 影・体積の雲・TAA・水の反射と屈折・モーションブラー・ブルーム。名前のとおり軽さ重視で、**スマホ向けの手本として良い** |
| **Noble（NobleRT）** | **GPL-3.0**【確】 https://github.com/BelmuTM/NobleRT/blob/master/LICENSE.txt （GitHub 上の名は Noble）。README に「無料でオープンソースのまま」とある【確】 | **可** | **不可（実質）**: GPL を取り込むとエンジン全体に波及する | 光のシミュレーション（パストレ系の GI・SSR・大気）。Patreon 版は別。**GPL なので写さず読むだけ** |
| **Ebin Shaders Resurrected** | GitHub は GPL-3.0【確】（LICENSE.md）。Modrinth は AGPL-3.0-only と表示【推】（**食い違い**） https://github.com/jbritain/Ebin-Shaders-Resurrected | 可 | 不可（GPL/AGPL） | 古い Ebin の再実装 |
| **glimmer-shaders** | **MIT**【確】 https://github.com/jbritain/glimmer-shaders/blob/main/LICENSE | **可** | **可**（MIT の著作権表示を残す） | labPBR 1.3 完全対応・無限の海・影（shadow map か lightmap 近似）・SSR/屈折・2D 雲・ブルーム。大気は Hillaire の論文（Shadertoy 経由）、SSR は Noble の参考、影の bias は Complementary から。**出どころの混在に注意**（README の謝辞の部分が元の契約に触れていないか、取り込む前に個別に確認要【推】） |
| **renderpearl** | **MIT**【確】 https://github.com/Luracasmus/renderpearl/blob/main/LICENSE （2026-11 も更新中） | **可** | **可** | 歪ませた影の地図・体積の光・色つきの光リスト・compute 版の FidelityFX CAS など**新しい GL（compute）前提**。文書 DEV.md あり。WebGPU 移行の手本として良い |
| **mellow** | **MIT**（LICENSE の先頭【確】。LICENSE-APACHE も並置 https://codeberg.org/TheCMK/mellow-shader ） | 可 | 可 | ブルーム・風で揺れる葉と水・lightmap ベースの影。小さく読みやすい【推】 |
| Miniature | MIT【確】 https://github.com/mateuskreuch/minecraft-miniature-shader | 可 | 可 | 反射と軽い光。小さい |
| Arc Shader（2023-05 以降停止） | MIT【確】 https://github.com/Null-MC/Arc-Shader | 可 | 可 | PBR・影・文書（wiki）あり |
| Pixel Perfect B / E-LITE / lite-shaders | LGPL-3.0【確】（Pixel Perfect）。E-LITE は GitHub が LGPL-3.0 と表示【推】 | 可 | LGPL の条件 | 軽量 |
| VanillAA | MPL-2.0（Modrinth 表示【推】・2023 停止） | 可 | MPL の条件（ファイル単位） | FXAA/AA |

読み物: **labPBR** の材質の決まり（`_s`: R=滑らかさ・G=F0 と金属の符号・B=多孔/SSS・A=発光、`_n`: RG=法線・B=AO・A=高さ）は shaderLABS の wiki にあり、内容は CC BY-NC-SA 4.0【確】 https://shaderlabs.org/wiki/LabPBR_Material_Standard 。**NC（非営利）+SA（継承）なので文章は写さない・自分の言葉で書く**。古い repo https://github.com/rre36/lab-pbr は MIT【確】（最終 2019-08）。決まりの事実（チャンネルの割り当て）自体を使うのは上の「アイデア」の話。

## 3. ライセンスが自由な別の出どころ

| 出どころ | ライセンス【確】 | 言語 | 手本になる技法 |
|---|---|---|---|
| Godot https://github.com/godotengine/godot/blob/master/LICENSE.txt | MIT | GLSL（`servers/rendering/renderer_rd/shaders/`）。**WGSL ではない** | Forward+/Mobile の描き手・SSAO（ASSAO 系: `effects/ssao*.glsl`）・SSIL・TAA（`taa_resolve.glsl`）・トーンマップ・DoF（bokeh）・SDFGI（`environment/sdfgi_*`）・体積のかすみ（`volumetric_fog*.glsl`）・VoxelGI・空 |
| **Bevy** https://github.com/bevyengine/bevy （LICENSE-APACHE と LICENSE-MIT の二重） | MIT OR Apache-2.0 | **Rust+WESL**（2026-11 の main は `.wgsl` ではなく `.wesl`、WGSL の上位）。**印: このエンジンの移る先の言語に近い** | `bevy_pbr/src/ssao/`（XeGTAO を元にした VBAO）・`ssr/raymarch.wesl`・`atmosphere/`（Bruneton の関数+LUT: 透過・多重散乱・空の見え・aerial view）・`volumetric_fog/`・`bevy_post_process/src/bloom/bloom.wesl`（COD 式の段つきぼかし）・`dof/`・`motion_blur/`・`auto_exposure/`・`bevy_anti_alias/{taa,fxaa,smaa}`・`tonemapping.wesl`（ACES・AgX・Tony McMapface・Blender Filmic・PBR Neutral）・`oit/`・`bevy_solari/`（レイトレ GI）・meshlet |
| three.js https://github.com/mrdoob/three.js/blob/dev/LICENSE | MIT | JS+GLSL（WebGL2。WebGPU/TSL もある） | WebGL2 での SSAO/GTAO/SSR/bloom/TAA/DoF（examples の postprocessing）。**WebGL2 の実装の手本** |
| Babylon.js https://github.com/BabylonJS/Babylon.js/blob/master/license.md | Apache-2.0 | TS+GLSL/WGSL（両方ある**印**） | SSAO2・SSR・volumetric light・DoF・カスケード影・PCSS・glow。WGSL 版も同居 |
| Filament https://github.com/google/filament/blob/main/LICENSE | Apache-2.0 | C++（シェーダー GLSL）。文書が非常に詳しい（PBR・IBL・色空間・トーンマップ） | PBR の式・IBL・SSAO・TAA・bloom・DoF・「Filament マテリアル」の文書。**PBR の文書は一番の教科書** |
| AMD FidelityFX CACAO https://github.com/GPUOpen-Effects/FidelityFX-CACAO/blob/master/license.txt | MIT（最終 2021） | C++/HLSL | 適応型の AO（compute） |
| FidelityFX SSSR https://github.com/GPUOpen-Effects/FidelityFX-SSSR/blob/master/license.txt | MIT（2022） | C/HLSL | 階層 Z の SSR（確率的） |
| FidelityFX SDK https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK | README が「サンプルは MIT」と記す【確】（root の LICENSE は見当たらず docs/license.md【不明】）。FSR2（旧）は MIT 文【確】 https://github.com/GPUOpen-Effects/FidelityFX-FSR2/blob/master/LICENSE.txt | C++/HLSL | FSR・CAS・DoF・bloom・ブラー。**compute 前提** |
| Intel XeGTAO https://github.com/GameTechDev/XeGTAO/blob/master/LICENSE | MIT（archived） | HLSL | GTAO の決定版。Bevy の SSAO の元【確: Bevy の ssao.wesl の頭】 |
| Bruneton の大気の散乱 https://github.com/ebruneton/precomputed_atmospheric_scattering/blob/master/LICENSE | BSD-3-Clause | C++/GLSL | 前計算の大気。Bevy の `bruneton_functions.wesl` が BSD の表示を残して取り込んでいる【確】 |
| Hillaire の UE の空 https://github.com/sebh/UnrealEngineSkyAtmosphere/blob/master/LICENSE | MIT | C++/HLSL | LUT 4 枚で軽い大気（スマホ向き）。glimmer も参照 |
| Khronos glTF-Sample-Viewer https://github.com/KhronosGroup/glTF-Sample-Viewer/blob/main/LICENSE.md | Apache-2.0 | JS/GLSL（WebGL2） | glTF の PBR の標準実装・IBL・清涼塗装・透過 |
| Khronos ToneMapping https://github.com/KhronosGroup/ToneMapping | Apache-2.0（コード）+CC-BY-4.0（文書）の 2 本が LICENSES にある【確】 | GLSL | **PBR Neutral**（色を変えにくい） |
| ACES の近似 | Hill 版は MIT（MJP の BakingLab の ACES.hlsl に明記【確】 https://github.com/TheRealMJP/BakingLab/blob/master/LICENSE は MIT）。Narkowicz 版（エンジンが今使う式）はブログの式【不明: ライセンス表記を確認できず】 | HLSL | 式だけなら自分で書く |
| AgX | Sobotka の repo には LICENSE が無い【確: API で 404】。Bevy は MrLixm の fork から LUT を作り、**LUT の出どころを info.txt に残している**【確】。Tony McMapface は Apache-2.0【確】 https://github.com/h3r2tic/tony-mc-mapface | — | 取り込むなら出どころを人が確認 |
| LearnOpenGL https://github.com/JoeyDeVries/LearnOpenGL/blob/master/LICENSE.md | **コードは CC BY-NC 4.0（非営利のみ）**【確】。画像と動画は CC BY 4.0【確】。文章の条件は About ページから確定できず【不明】 | C++/GLSL | PBR・IBL・SSAO・bloom・deferred・CSM の定番の教科書。**読んで学ぶのは可、コードは写さない（NC）** |
| Luanti（Minetest） https://github.com/luanti-org/luanti | コードは LGPL-2.1 以降（doc/lgpl-2.1.txt あり【確】、README の節は確認できず【推】）。LICENSE.txt の本文は画像・音の CC BY-SA 3.0 の話【確】 | C++/GLSL | ブロック世界の影・水・葉の揺れ（`client/shaders/`）【推】 |
| Veloren https://github.com/veloren/veloren/blob/master/LICENSE | GPL-3.0【確】 | Rust（wgpu。シェーダーは GLSL【推】） | ボクセルの描き方・LOD・雲・水。**GPL なので読むだけ** |
| **Terasology** https://github.com/MovingBlocks/Terasology/blob/develop/LICENSE | Apache-2.0【確】 | **Java（印）** | ボクセルエンジンの構成（描画は OpenGL）。Java の手本として読める。描画技法は古め |
| ClassiCube https://github.com/ClassiCube/ClassiCube/blob/master/license.txt | BSD 系の 3 条文（冒頭【確】） | C | 固定機能に近い軽いボクセル描画。LOD なし・移植性の手本 |
| Craft https://github.com/fogleman/Craft/blob/master/LICENSE.md | MIT | C+GLSL | 最小のボクセル描き（chunk 単位の VBO・空・昼夜）。約 5 千行で読める |

Java か WGSL（に近い物）で書かれた物: **Terasology（Java）、Iris/Sodium/Embeddium/Canvas/DH（Java・読む用）、Bevy（WESL ≒ WGSL）、Babylon.js（WGSL 版あり）**。

## 4. 技法ごとの表

効き目 大/中/小。重さ: 低=スマホ可 / 中=条件つき / 高=PC 向き。土台: Z=深度の読み / N=法線の描き先 / MRT / H=前のコマの絵 / F=浮動小数の描き先 / C=compute。
WebGL2 / WebGPU: ○=できる / △=工夫・制限 / ◎=WebGPU が楽。今ある= docs で確認（【確】）。

| 技法 | 何をする物か | 効き目 | 重さ | 土台 | WebGL2 / WebGPU | 学ぶ出どころ（最良+ライセンス） | エンジンに今 |
|---|---|---|---|---|---|---|---|
| カスケードの影 | 太陽の影を、近くは細かく遠くは粗い複数の地図で描く | 大 | 中 | 影の地図を複数枚 | ○ / ◎（配列テクスチャ） | Bevy `bevy_light`/pbr の影（MIT/Apache）・Godot | **1 段のみ**【確】 |
| やわらかい影 PCF / PCSS | 影の縁を周りの平均でぼかす / 遮る物からの距離で縁の幅を変える | 中 | 低〜中 | 影の地図 | ○ / ○ | Bevy・Babylon.js（Apache・PCSS あり） | PCF のみ【確】 |
| 接した所の影 contact shadow | 画面の深度を短く追って、足元の細かい影を足す | 小〜中 | 低〜中 | Z | ○ / ○ | Bevy / Godot | 無い |
| SSAO / GTAO | 隅や接地の暗さを深度から作る | 大 | 中 | Z+N（+H で時間平均） | ○ / ◎(C) | **XeGTAO（MIT）・Bevy の ssao.wesl（MIT/Apache・WGSL 系）**・Godot ssao.glsl | 無い |
| SSR | 画面の絵を反射に使う | 中 | 高 | Z+N+H | △（ループ上限）/ ◎ | FidelityFX SSSR（MIT）・Bevy ssr（MIT/Apache） | 無い（空の映り込みのみ【確】） |
| 水（波・屈折・コースティクス） | 動く面+深さで色が変わる+底の光の模様 | 大 | 中 | Z（深さ）+F+H | ○ / ○ | **glimmer（MIT）・Solas は読むのみ**・Bevy の water 例 | 無い |
| 大気の散乱の空 | 太陽の位置で空・夕焼けを物理で出す | 大 | 低（LUT 版）〜中 | F の小さい LUT | ○ / ◎(C) | **Hillaire（MIT）・Bruneton（BSD）・Bevy atmosphere** | グラデの空 3 色のみ【確】 |
| 体積の光 god rays | 光の筋（影の地図を視線に沿って積分） | 中〜大 | 中〜高 | 影の地図+Z | ○ / ◎ | renderpearl（MIT）・Bevy volumetric_fog・Godot | 無い |
| 体積の雲 | 3D のノイズを視線で積分 | 大 | 高 | F+（H で時間平均） | △ / ◎ | MakeUp（LGPL）は読む・Photon は読む（明記）・Hillaire/Bevy | 無い |
| 高さつきのかすみ | 距離+高さで色が混ざる | 中 | 低 | Z | ○ / ○ | Filament 文書・Bevy・Godot | 距離のかすみあり【確】 |
| ブルーム | 明るい所をぼかして滲ませる | 大 | 低〜中 | F（HDR）+縮小 Pass | ○ / ○ | **Bevy bloom.wesl（COD 式）・LearnOpenGL の文章（コードは NC）** | 無い。**Pass 連鎖+`blur` で組める下地あり**【確】 |
| トーンマップ | HDR を 0..1 に収める | 大 | 低 | F | ○ / ○ | **Khronos PBR Neutral（Apache）・Bevy tonemapping.wesl（ACES・AgX・Tony・Neutral）**。AgX は出どころを確認、Tony McMapface は Apache | AcesFitted/Reinhard【確】 |
| TAA / FXAA / SMAA | 縁のギザギザをならす（TAA は前のコマも使う） | 大 | 低(FXAA)〜中(TAA) | TAA は H+速度の描き先 | ○ / ○ | Bevy `bevy_anti_alias`・Godot `taa_resolve` | **FXAA+MSAA あり**【確】 |
| 被写界深度 | ピントの外をぼかす | 中 | 中 | Z | ○ / ○ | Bevy dof・Godot bokeh | `Output.Depth`（ピントの Pass）とティルトシフトのぼかしあり【確】 |
| モーションブラー | 動く向きにぼかす | 小〜中 | 中 | 速度の描き先 | △ / ○ | Bevy motion_blur・MakeUp(LGPL) | 無い |
| 色の調整 LUT | 3D のテーブルで色の雰囲気を変える | 中 | 低 | 3D テクスチャ | ○ / ○ | Bevy（LUT を読む tonemapping）・Filament 文書 | 無い（Spec の掛け算で近似可【確】） |
| 照り返しの近似 | 間接光（lightmap・probe・SDFGI・voxel） | 大 | 低(lightmap)〜高(SDFGI) | 種類による | △ / ◎(C) | Godot SDFGI（MIT）・Rethinking Voxels（読むのみ）・MJP BakingLab（MIT） | lightmap あり【確】 |
| 色つき点光源の floodfill | 格子上で光を広げる | 中 | 低〜中 | C か格子テクスチャ | ○ / ◎ | Starlight/ScalableLux（LGPL・読む）・renderpearl（MIT・光リスト） | 無い |
| 葉や草の揺れ | 頂点を時間で揺らす | 小〜中 | 低 | 頂点の段 | ○ / ○ | mellow（MIT）・renderpearl・Bevy の例 | 風の用語は fx にある【推】 |
| parallax occlusion mapping | 高さの絵で凹凸の奥行き | 小〜中 | 中 | 高さの絵 | ○ / ○ | LearnOpenGL（読むのみ）・Filament 文書・Babylon | 無い |
| deferred / forward+ | 光を多数にする描き方 | 中（光が多い場面で大） | 中 | MRT / C | △ / ◎ | Bevy deferred・Godot（Forward+）・Filament | 前進描き（2 光まで【確】） |

## 5. まとめ

### 安全に学べる順
1. **(1) ライセンスが自由で、コードを取り込んでもよい物**（著作権表示などの条件を守る前提）: glimmer-shaders（MIT・混在要確認）・renderpearl（MIT）・mellow（MIT）・Miniature（MIT）・Arc（MIT）／ Godot（MIT）・Bevy（MIT OR Apache-2.0）・three.js（MIT）・Babylon.js（Apache-2.0）・Filament（Apache-2.0）・FidelityFX の CACAO/SSSR/FSR2（MIT）・XeGTAO（MIT）・Bruneton（BSD-3）・Hillaire（MIT）・Khronos ToneMapping/glTF-Sample-Viewer（Apache-2.0）・Terasology・Craft・ClassiCube・BakingLab の ACES（MIT）。
   - LGPL（MakeUp・Embeddium・Pixel Perfect・Starlight 系・Canvas・Iris）は「取り込めるが、エンジンが MIT なので LGPL を人が受け入れるか」を決める必要がある。**コードは取り込まず読んで学ぶのが無難**。
2. **(2) 読んで学ぶのは問題なさそうだが、コードは取り込まない方がよい物**: Complementary・Rethinking Voxels・Photon（学ぶ事は明記）・Solas（取り込みは許可が要る）・SDV・BSL・Sildur's・Chocapic13 系／ GPL 系（Noble・Ebin・Veloren）／ LearnOpenGL のコード（CC BY-NC）／ Sodium（PolyForm Shield）／ Distant Horizons（LGPL か GPL かの揺れ）／ labPBR の文章（CC BY-NC-SA）。
3. **(3) 読む事にも注意が要る物**: OptiFine の公式文書と配布物（ARR・非公開）・SEUS（条件が開けず【不明】）・Kappa/Nostalgia/AstraLex/Lux（ARR 表示・ソース不明）。

### エンジンに入れる順のおすすめ（効き目大・軽い・土台が少ない順）
印 ⚠ = 「ゲームにシェーダーを書かせない」「CPU の描き手と絵をそろえる（make gl-parity）」との折り合いが要る。
1. **トーンマップの追加（PBR Neutral・AgX 風）**: 既に `PostProcess` がある。Khronos ToneMapping（Apache-2.0）の式を `Tonemap` の候補に足す。土台 0。CPU 側も式 1 本で足せる。
2. **ブルーム**: Bevy bloom.wesl（COD 式の段つき）。F の Pass と縮小 Pass が既にある。⚠ CPU 側の段つきぼかしの計算量。
3. **大気の散乱の空**: Hillaire（MIT）または Bevy atmosphere（LUT 4 枚）。今のグラデの空の置き換え候補。⚠ LUT を CPU でも作る必要。
4. **SSAO / GTAO**: XeGTAO（MIT）と Bevy ssao（MIT/Apache）。深度+法線が要る（今は法線を描き先に出していない【推】）。⚠ CPU の描き手でも同じ AO を出すか、AO は GPU のみとして parity の例外にするかを決める。
5. **カスケード影の複数段+PCSS**: Bevy・Godot。今ある影の地図の拡張なので土台は同じ。⚠ 影の parity 表の更新。
6. **TAA**: Bevy `taa.wesl`・Godot。速度の描き先と前コマが要る。FXAA から段階的に。⚠ 静止画の描き出しとは相性が悪い（描き出しは使わない扱いにする）。
7. **高さつきのかすみ・体積のかすみ**: Bevy volumetric_fog・Godot。かすみの木に高さの項を足すだけなら軽い。体積の光は影の地図が要る。
8. **SSR**: FidelityFX SSSR（MIT）・Bevy ssr。H と法線が要り重い。後回しでよい。⚠ CPU 側は実装しないのが現実的。
（水は効き目が大きいが範囲が広い。glimmer（MIT）と Bevy を読んでから別に計画。）

### 取り込む時にやるべき事（材料）
- 取り込んだ物ごとに、**出どころの URL・ライセンス名（SPDX）・版（commit）・取り込んだ日**を記録する（例: `THIRD_PARTY_NOTICES.md` か `NOTICE`）。Bevy は取り込んだファイルの頭に出どころを残している（例: Bruneton の BSD 表示・Khronos の「Apache 2.0 で改変」の注記）【確】。この流儀に合わせられる。
- MIT / BSD / Apache-2.0 は著作権表示と条件文を残す（Apache は改変の注記と、あれば NOTICE の引き継ぎ）。
- **GPL / AGPL（Noble・Ebin・Veloren）は写さない**。LGPL は読んで自分で書く。
- 独自の契約（Complementary・Photon・Solas・SDV など）は、読んで学ぶ以外はしない。Photon の「別製品への取り込み」は契約に書かれていないので、必要なら作者に許可を取る。
- 式・考え方（アイデア）は著作権の対象外という一般論でも、**論文の式を自分の言葉と変数名で書き直し、元のコードの構造・コメント・名前を写さない**。参照元は論文名で記す。
- 「読む」の注意: ShaderDoc の方針（OptiFine の文書を読んで自分の言葉で書く）が実例になる。クリーンルーム的に「読む人」と「書く人」を分けるかは、人が判断する。
- 次の確認項目: Sodium の LICENSE の変更時期の確定・SEUS の LICENSE の原文・Narkowicz ACES の表記・AgX の LICENSE・Distant Horizons の GPL/LGPL の揺れ・LearnOpenGL の文章のライセンス・BSL / Chocapic13 の原文（本人のサイト）は一次で開けていない。
