# 3D の 1 コマを軽くする E1〜E3（設計 rev1・レビュー 90 点・実装済み）

実装の結果: E1 は書斎で 1 コマ 42 回の putJoints のうち書くのは 1 回（skinBend は期待どおり A・B・A・B の 4 回）。E2 は直す物が無かった
（書斎の影の地図は 1 コマ 1 枚で、Color の Pass だけ）。E3 は eqMaterial を足して eqEmission を消した。eqMaterial は spec が同じ参照で、
emission も両方無いか同じ参照の時だけ参照で抜ける。gl-parity の 2 体の行は、既にある skinBend（最後のジョイントだけ違う 2 体・片方は材質・影）で足りた。

rev0 → rev1: レビュー 78 点。eqEmission の取り違えを eqMaterial で直す・E3 の理由付けを正典の順の本当の形に直す・
TexSize と Sampler のテスト・E1 の書くかの判断を純関数にし、骨つき 2 体と影の gl-parity の行を足す・E2 は呼び手ごとに数える。

fps3d_lab の書斎が約 80fps・礼拝堂が約 140fps。計測役の JFR で見えた 3 か所を直す。絵は 1 画素も変えない。

## E1 骨の行列の UBO（render_gl/src/Render3d.flix の putJoints）

今: 骨つきの部品を 1 つ描くたびに、同じ 1 本の UBO を glBufferSubData で頭から書き直す。前のドローがまだその UBO を読んでいる間に
書くので、ドライバが GPU を待つ（JFR で putJoints のサンプルの 97% が glBufferSubData の native）。書斎の番兵は 14 部品 × 4 回描く。

直し方:
- SkinnedPrograms に「最後に UBO へ書いた中身」（Float32 の Array）を持つ。putJoints は書く中身を作り、純関数 `needsUpload(前, 今)`
  （長さが違うか、どれか 1 つでもビットが違えば真。Float32 をビットで比べ、-0.0 と +0.0 も NaN も中身どおりに扱う）が偽なら書かずに
  glBindBufferBase だけする。同じ pose の部品が続く間・同じ pose を別の Pass で描く間は 1 回も書かない（書斎で 56 回 → 1 コマ 1 回）。
- 書く時は、createJointsBuffer と同じ glBufferData(maxJoints × 64, null, DYNAMIC_DRAW) でバッファを作り直してから（orphan）
  glBufferSubData で頭から書く。前のドローが読む古い中身はドライバが別に持つので待たない。詰めない後ろは中身が決まらないが、
  skinningOf がジョイントの数より後ろを読まないことを保証している。1 コマに違う pose が N 体あれば N 回 orphan する。
- WhyNot: 大きな UBO の別の場所へ書いて glBindBufferRange で指す形（ring）にしない — 1 コマの pose の数を先に数える道が要り、
  オフセットを GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT にそろえる。今の困りごと（同じ pose を何度も書く）は比べるだけで消え、
  体の数だけの orphan はドライバの得意な形。
- binding 1 を使うのは putJoints と bindJointsBlock だけで、材質の骨つきの版も同じ binding・同じ UBO。State は GL の文脈ごとに 1 つ
  （GlOffscreen も別の State）なので、控えが他の文脈と混ざらない。文脈を作り直すと skinnedRef ごと作り直し、控えも空から始まる。
- 確かめ: needsUpload の unit test（同じ・1 要素違い・長さ違い・-0.0 と +0.0）。gl-parity に「pose の違う骨つきの物 2 体 + 影を落とすスポット」の
  行を足す（影の地図で A・B、塗りで A の順に描くので、比べの漏れで A を書き損ねると絵が変わる）。書いた回数を一時的に数えて報告する。

## E2 Output が Depth の場面で影の地図を描かない

調べた結果、今も描いていない: `Render3d.shadowCasterOf` が `Output.Depth(_) => None` を返し、`renderShadows` は影の地図を描かない。
計測役の言う「shadow 2 枚」は、1 コマに `RenderPaint.prepareScenes` が 2 回（paintFrame と paintTarget）Color の場面で走る形などが候補。
E1 を入れた後に、renderShadowMap の回数を呼び手（paintFrame / paintTarget）と ordinal ごとに一時的に数えて報告する。直す物が無ければ何もしない。

## E3 Spec の比べ（engine/src/ShaderGen.flix の eqSpecTree）

今: eqSpecTree は比べるたびに両方の Spec の texNames（木を全部たどって並べ、重複を除く）と、名前 → 番号の Map を作り、それから
2 つの木をそろえてたどる。毎コマ作り直した Spec は参照の一致で抜けられないので、材質と 2D の面の数だけこれを払う（JFR で 18〜22%）。

直し方:
- 番号の Map を先に作らず、2 つの木をそろえてたどりながら「a の名前 → b の名前」と「b → a」の対応を作る。名前を持つ 3 つの位置
  （Tex・TexBlur・TexSize。どれも eqField の中で eqTexName を通る）に来たら、どちらの名前も初めてなら対応を足し、どちらかが既にあれば対応が合うかを見る。
  TexSize の位置でも対応を取る（Tex と同じ名前の TexSize は texNames で 1 本にまとまるので、外すとずれる）。
- 同じ答えになる理由: texNames / texReads は「Tex・TexBlur を (名前, 補間) の初出順に重複なしで並べ、その後ろに Tex・TexBlur に出ない TexSize の名前を足し、
  名前で重複を除く」並び。この並びは「どの位置の名前どうしが同じか」と位置の形（case・Sampler の補間）だけで決まる。形が同じ 2 つの木で、
  全部の位置を通して崩れない 1 対 1 の対応 φ があれば texNames(b) = φ(texNames(a)) で、各位置の番号がそろう。逆に、1 つの Spec の中で
  名前 → 番号は 1 対 1 なので、番号がそろえば対応は崩れない。たどる子は eqField と foldFieldScoped で全部一致している（レビューで確かめた）。
- 先に「名前がそのまま同じ」で比べ（名前の比べ `==`）、真ならそこで終わる。名前がそのまま同じなら対応は恒等で崩れない。偽の時だけ対応を作ってもう一度比べる
  （Pass の中で読みを別名へ書き換えた面だけが 2 回払う）。どちらが得かは JFR で確かめ、得でなければ近道を外す。
- 対応は小さな連想の並び（名前は数個）を region の中の Ref に持ち、eqField などの内側の比べは `(String, String) -> Bool \ ef` を受け取る形にする。
- **eqEmission の取り違えを直す**: compile3d は emission の uTexN の番号を `materialTexReads(spec, emission)`（spec の texReads の後ろに emission にだけ
  出る名前を足した並び）で決める。今の sameMaterial は eqSpec と eqEmission（名前を比べない）を別々に呼ぶので、spec が "a" を読み emission が "a" を読む材質と、
  emission が "g" を読む材質を同じと答え、後者が前者の program（"a" を読む）を使い回す。
  → `ShaderGen.eqMaterial(specA, emA, specB, emB)`（pub を 1 つ足す）で、spec の木と emission の木を同じ対応で続けてたどる。sameMaterial をこれに替える。
  eqEmission は呼び手が無くなるので消す（pub が 1 つ減る。移行メモに書く）。
- WhyNot: Spec に中身の鍵（hash）を持たせない — eqSpec の WhyNot（衝突しないことを証明できない）と同じ理由。pub の型も変わる。
- WhyNot: 材質の側に texNames を控えるだけにしない — 来た方の texNames は毎回作るので、費用は半分しか減らない。

テスト: engine/test/TestShaderGenEqSpec.flix（全 case・全フィールドを pin）が今のまま緑。足す物:
- 今の実装（texNames と Map で番号を比べる）を test の側に写し、各 fixture に「1 対 1 で名前を付け替えた物」（真）と「2 つの名前を 1 つに潰した物」（偽）を作って、
  新しい eqSpec と写した旧実装の答えが同じ
- TexSize だけで読む名前（後ろに回る）と、Tex と同じ名前の TexSize（まとまる）の組・同じ名前を Nearest と Sampler(Linear) で読む Spec・
  同じ名前を bindings と out の両方で読む Spec
- eqMaterial: spec "a" + emission Tex("a") と spec "a" + emission Tex("g") は偽・emission の名前を spec と一緒に付け替えた物は真

## 確かめ方
- gl-parity の A 行が全部 0 px・骨の行（skinBend・skinNormal・足す 2 体と影の行）一致・two_joints の場面（bench か test の物）一致・emission がテクスチャを読む材質の行（あれば）
- テンプレートの描き出しのバイト一致・engine / .layers のテスト緑
- fps3d_lab の書斎と礼拝堂の frame-stats（600 コマ平均・DEBUG で /start room・chapel）の前後
