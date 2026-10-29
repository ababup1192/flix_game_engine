# 正面の敵のドット絵（大型の敵・ボス）の手の形

`assets/rpg.monsters.sprite.json` の敵を描く・直すときの決まり。調べた出典から技法だけを取り出した（画素の複製はしない）。

## 決まり

1. **骨格を先に決める。** 背骨の線（鼻先→首→肩→腰→尾の先）と、四肢の関節（肩→ひじ→手首、腰→ひざ→足首）を点で置いてから肉を付ける。楕円を貼り合わせると、胴と首や四肢の付け根が切れて、カエルやカメのような塊に見える。
2. **肉は骨に沿って太さを変えて付ける。** 首は胴より細く、肩と腰で盛り上がり、尾は根元から先へ細くする。肩と腰がふくらむ所が、四足の「生き物らしさ」を作る。
3. **前後は重なりで見せる。** 奥の脚→尾→胴→背中の飾り→首と頭→手前の脚の順に描く。手前の腕は太く大きく、奥の腕は細く短く、一部を胴で隠す（正面〜斜めの遠近）。
4. **トカゲは脚を横に張り出す。** ひじとひざが胴の外へ出て、手首から下は地面へ下りる。脚を胴の真下へまっすぐ立てると、哺乳類か机に見える。
5. **陰は光源から決める。** 光は左上から当てる。光に向く面を明るく、反対側を暗くする。輪郭に沿って一様に暗くする「pillow shading（まくらの陰）」は、光がどこから来るか読めないので使わない。
6. **陰は大きな塊で置き、細かい点を散らさない。** 32px で 3 段、64px を超えたら 4〜5 段が目安。FC では 1 組 3 色なので、3 段に墨を足して 4 段として使う。
7. **外形は墨で太く、内側の線は細く色で引く。** 外側の輪郭だけを墨にし、内側の境目は隣の色を 1 段落とした色にする（selective outline の考え方）。墨は、口の中や脚の付け根の重なりのように、光の届かない所に限る。
8. **溝・すき間は真っ黒にしない。** 光が少し回り込むので、その面の暗い段で描く。
9. **うろこや毛は、陰の塊の縁を刻んで出す。** 全面に模様を均等に打たない。光の当たる背中に、背骨の向きにそろえた小さな弧を少しだけ置く。
10. **見せ場は 1〜2 か所に絞る。** 目（大きく丸い目は親しみやすい・細い目は怖い）と、光る部位（口の中・水晶）。いちばん明るい色はそこにだけ使う。
11. **FC のボスは BG のタイルで描かれていた。** 動かすのは書き換えるタイルの少ない部分（色の段を回す・口や目だけを替える）にする。体全体を毎コマ描き替えない。

## 出典

- Slynyrd Pixelblog 57（騎士・モンスター・城。大きな塊から細かい塊へ・塊を散らさない）: https://www.slynyrd.com/blog/2025/7/28/pixelblog-57-knights-monsters-amp-castles
- Pixel tutorial: Bloodbane skeleton（骨格を先に・筋肉を少ない塊に・丸い部位の明るい点と周りの暗さ）: https://itch.io/t/1836238/pixel-tutorial-bloodbane-skeleton
- Pixel tutorial: Tortoise（光源からの陰・溝を真っ黒にしない・selout・奥の部位は細く暗く）: https://itch.io/t/2087708/pixel-tutorial-tortoise
- Pixel tutorial: Selective outlines（輪郭を隣の色の 1 段下にする）: https://itch.io/t/2422252/pixel-tutorial-selective-outlines
- Pixel tutorial: Yeti（陰の塊の縁を刻んで質感にする）: https://itch.io/t/1977247/pixel-tutorial-yeti-final-fantasy-14
- pixnote: Shading & Lighting（pillow shading を避ける・大きさごとの段の数・影の色相をずらす）: https://pixnote.net/en/learn/shading
- Mega Cat Studios: Blending Tiles for Animated NES Bosses（FC のボスは BG のタイルで描かれ、書き換えられるタイルが少ない）: https://megacatstudios.com/blogs/retro-development/blending-tiles-for-animated-nes-bosses
- Tuxemon Design Guide（敵の絵に selective outline を使い、アンチエイリアスを足しすぎない）: https://wiki.tuxemon.org/Design_Guide
