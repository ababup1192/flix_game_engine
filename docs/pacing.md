# 演出の間（ま）の目安

演出の長さ・待ち・溜めを決めるときの出発点。最後は遊んで決める。
カットインや WARNING の長さそのものを数値で示した一次資料は無いので、人の知覚・UI・映像・音の研究から借りた値を使う。

## まず守る 5 つ

1. **何も起きない待ちは 1 秒まで。** 超えるなら、拍ごとに何か動かすか、飛ばせる入力を受ける（Nielsen の 1 秒の限界）。10 秒を超えるなら進み具合を見せる。
2. **窓の出入り（会話・確認・ボタン）は、開く 200〜300ms・閉じる方を短く。** 400ms を超えるともたつき、500ms で重く感じる（NN/g・Material）。全画面の転換は UI として見るなら 375ms まで。
3. **溜め・予備動作は 15F（0.25 秒）を単位に。** 実機は予備動作の分だけ長くなるので、描き出しで実測する（桜井政博）。
4. **音と絵は、音が先 15ms〜音が後 45ms に収める。** ずれるなら音を遅らせる側へ。音が先に来るずれのほうが気づかれやすい（ATSC）。気づく境目は音が先 45ms・後 125ms（ITU-R BT.1359）。
5. **押してから反応が出るまで 100ms 以内。**（Nielsen の 0.1 秒）

## 目安の表

| 項目 | 目安 | 出典 |
|---|---|---|
| 押してから反応 | 100ms 以内 | Nielsen・NN/g |
| 窓が開く | 200〜300ms | NN/g・Material |
| 窓が閉じる | 195〜250ms | NN/g・Material |
| もたつきの境目 | 400ms 超・500ms で重い | NN/g・Material |
| 全画面の転換（UI） | 375ms まで | Material |
| 何も起きない待ち | 1 秒まで | Nielsen |
| 注意が続く限界 | 10 秒 | Nielsen |
| 溜めの単位 | 15F（0.25 秒） | 桜井政博 |
| ヒットストップ | 1 発 10〜20ms（60fps で 1F） | Nuclear Throne の分析 |
| 音と絵のずれ | 音が先 15ms〜後 45ms | ATSC |
| 拍に合っている幅 | ±16.7ms（1F） | 音ゲーの判定（非公式） |
| 字送り | 4〜11 字/秒 | 字幕の決まり・黙読の平均（原典未確認） |
| 1 枚の台詞の表示 | 6.5 秒まで | 字幕の決まり（原典未確認） |

## 曲に乗る演出への読み替え

- 曲に乗る演出（Timeline の表）は拍と小節で書き、ms の目安を拍に直して丸める。曲に乗らない UI の出入りは ms のまま。
- 拍の長さ = 60 ÷ BPM 秒。例: 175 BPM なら 1 拍 ≈ 343ms・半拍 ≈ 171ms・1 小節（4 拍）≈ 1.37 秒、1 秒 ≈ 3 拍。
- 15F の溜めは、だいたい半拍〜1 拍に丸める。

## 機械で確かめられる物

- 音と絵のずれ: Timeline の表で、音の時刻と対になる絵の頭の差が幅に入るか。
- 窓の出入りの長さ: 100〜400ms に収まるか（500ms 以上は警告）。
- 入力の効かない待ち: 1 秒を超えないか。超えるなら動く物か飛ばす口があるか。
- 字送り: 台詞の字数 ÷ 表示秒が 4〜11 字/秒か、1 枚が 6.5 秒以内か。
- 拍への吸着: 演出の頭が拍の格子から 1F 以内か。

## 出典

- Nielsen「Response Times: 3 Important Limits」 https://www.nngroup.com/articles/response-times-3-important-limits/
- NN/g「Executing UX Animations: Duration」 https://www.nngroup.com/articles/animation-duration/
- Material Design「Duration & easing」 https://m1.material.io/motion/duration-easing.html
- Audio-to-video synchronization（ITU-R BT.1359・ATSC・EBU） https://en.wikipedia.org/wiki/Audio-to-video_synchronization
- 桜井政博のコラム（ファミ通 2019） https://www.famitsu.com/news/201904/24175091.html
- Nuclear Throne の手応えの分析 https://infovore.org/?p=5275
- Etani ら 2018（グルーヴは 100〜120 BPM で最も強い） https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2018.00462/full
