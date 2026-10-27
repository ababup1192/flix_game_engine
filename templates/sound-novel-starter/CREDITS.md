# 素材の出典とライセンス

このテンプレートの背景の写真とフォントは、自由に使える許諾の物を使っています。
ゲームの中のクレジット（タイトル画面の「クレジット」と、物語を読み終えた後）にも同じ表記を流します（`assets/novel.credits.json`）。
写真を差し替えたら、ここと `assets/novel.credits.json` の両方を書き直してください。

## 背景の写真（Wikimedia Commons）

どれも 16:9 に切り抜き、960×540 に縮めて `assets/bg/` に置いています。ゲームの中ではさらに、
シェーダーでぼかし、時間帯の色（夕暮れ・夜・朝）に色を変えて表示します（`src/Backdrop.flix`）。

| ファイル | 元の写真 | 作者 | ライセンス |
|---|---|---|---|
| `assets/bg/station.jpg` | [Onuma Quasi-National Park - Onuma544.jpg](https://commons.wikimedia.org/wiki/File:Onuma_Quasi-National_Park_-_Onuma544.jpg) | lumoplank | [CC0 1.0](http://creativecommons.org/publicdomain/zero/1.0/deed.en) |
| `assets/bg/paddy.jpg` | [Japanese Summer (14646910072).jpg](https://commons.wikimedia.org/wiki/File:Japanese_Summer_(14646910072).jpg) | Tagosaku | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0) |
| `assets/bg/lane.jpg` | [滝の下 古民家 - panoramio.jpg](https://commons.wikimedia.org/wiki/File:%E6%BB%9D%E3%81%AE%E4%B8%8B_%E5%8F%A4%E6%B0%91%E5%AE%B6_-_panoramio.jpg) | 田村淳 | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0) |
| `assets/bg/engawa.jpg` | [Shikokumura19s3200.jpg](https://commons.wikimedia.org/wiki/File:Shikokumura19s3200.jpg) | 663highland | [CC BY 2.5](https://creativecommons.org/licenses/by/2.5) |
| `assets/bg/river.jpg` | [中世木川と田んぼ.jpg](https://commons.wikimedia.org/wiki/File:%E4%B8%AD%E4%B8%96%E6%9C%A8%E5%B7%9D%E3%81%A8%E7%94%B0%E3%82%93%E3%81%BC.jpg) | Spedi-sit | [CC0 1.0](http://creativecommons.org/publicdomain/zero/1.0/deed.en) |

## フォント

- **しっぽり明朝**（`assets/ShipporiMincho-Regular.subset.ttf`）— Copyright 2021 The Shippori Mincho Project Authors
  （https://github.com/fontdasu/ShipporiMincho）。[SIL Open Font License 1.1](assets/OFL.txt)。
  JIS 第 1 水準の漢字・かな・英数と、シナリオに出てくる字だけを残した部分集合（サブセット）です。
  第 2 水準の字をシナリオに足した時は、元のフォントから字を足して作り直してください（作り直すまで、その字は表示されません）。

## 音

効果音と環境音は `art/sfx.snd.star` から `bin/fge snd build` で合成した物です（外部の素材は使っていません）。
