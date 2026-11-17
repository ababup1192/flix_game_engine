# 素材の出典とライセンス

このテンプレートの背景・立ち絵・小物は画像生成で作った物、冬の風は効果音ラボの録音、フォントは SIL OFL の物を使っています。
ゲームの中のクレジット（タイトル画面の「クレジット」と、物語を読み終えた後）にも同じ表記を流します（`assets/novel.credits.json`）。
ゲームの中では、画像生成の絵と合成の音はファイルや場面を並べず「画像生成で作りました」「効果音の一部は合成」とだけ書き、
外の素材の作者・曲名・サイト・ライセンスは書きます（下の表はファイルごとの出どころの控えです）。
絵や音を差し替えたら、ここと `assets/novel.credits.json` の両方を書き直してください。

## 背景・一枚絵・立ち絵・小物（画像生成）

どれも画像生成（OpenAI の画像生成）で、このテンプレートのために作った物です。

| ファイル | 中身 | 作り方 |
|---|---|---|
| `assets/bg/slope.jpg` | 冬の集落の坂（冬の坂） | 昼の自然光の実写風に横長で生成した物を、縦の画面に合わせて大事な物を真ん中に 250×540 に切り抜き（縦に生成し直すまでの仮） |
| `assets/bg/desk_room.jpg` | 木机のある部屋（灯の部屋） | 同上 |
| `assets/bg/studio_eaves.jpg` | 工房の軒先 | 同上 |
| `assets/bg/studio.jpg` | 工房の中 | 同上 |
| `assets/bg/still_akari_slope.jpg` | 雪の坂道の灯の後ろ姿（結末の一枚絵） | 同上 |
| `assets/cast/toma_plain.png`・`toma_puzzled.png`・`toma_smile.png` | 冬馬の立ち絵（3 表情） | 透過で生成し、`art/cast/prepare.py` で縮めてふちを埋めた物 |
| `assets/cast/map_plain.png` | 手描きの地図（小物） | 同上 |

背景はゲームの中でさらに、シェーダーでぼかし、時間帯の色（夕方・灯り・夜・朝）に色を変えて表示します（`src/Backdrop.flix`）。
`assets/cast/_sample_plain.png` はテスト用の単色の形（`art/cast/sample.py` が作る）で、物語には出しません。

## フォント

- **しっぽり明朝**（`assets/ShipporiMincho-Regular.subset.ttf`）— Copyright 2021 The Shippori Mincho Project Authors
  （https://github.com/fontdasu/ShipporiMincho）。[SIL Open Font License 1.1](assets/OFL.txt)。
  JIS 第 1 水準の漢字・かな・英数と、シナリオに出てくる字だけを残した部分集合（サブセット）です。
  第 2 水準の字をシナリオに足した時は、元のフォントから字を足して作り直してください（作り直すまで、その字は表示されません）。

## 音

| ファイル | 元の音 | 出典 | 規約 |
|---|---|---|---|
| `assets/sfx/amb_winter_wind.wav` | 「風が吹く1」（30 秒に切り出し、継ぎ目が聞こえないようループにして 22050 Hz のモノラルに書き出し） | [効果音ラボ](https://soundeffect-lab.info/) | [効果音ラボの利用規約](https://soundeffect-lab.info/agreement/)（クレジットは任意。音のファイルの再配布・音を自由に鳴らせる画面は不可） |

返事の音（`ui_*`）は、`art/sfx.snd.star` から `bin/fge snd build` で合成した物です。
