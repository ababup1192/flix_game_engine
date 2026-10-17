# 完全ループ GIF の作法

## 描き出す

- 配管: `HeadlessRender.renderGif(cfg, frames, stride, toCmds, name)`。シェーダ面を使う場合は
  チャンネルが無いので `SoftRaster.renderToImageWith` + `Filmstrip.renderFrame` +
  `GifEncoder.encode` を手組みする（シェーダ面つきは `HeadlessRender.renderGifWith`）
- ループを閉じる: 周期項はループ長の整数倍周期だけ / 降下・スクロールはラップ幅の
  整数倍 / フラッシュ・揺れはループ境界で振幅 0
- 尺は 4〜6 秒に一番動きのある瞬間を 1 つ（20 秒を全部描き出さない）
- 実績: 72 コマ・15fps・720×405 で 2〜4MB。グラデを細い面で積むと 1 コマ十数秒に
  なる（scale を落とすか部品を減らす）
- 決定性: 同じ入力なら GIF がバイト一致する（実測済み）— 動きのスナップショット比較に使える

## 配る時は WebP に変換する

- **GIF のサイズは解像度でほぼ縮まない — 効くのはコマ数**。ドット絵は 1 画素ごとの
  ノイズが情報量の本体で、整数倍拡大した分の同色画素は LZW が縮めてしまう
  （720×405 と 480×270 が同じバイト数になった実測あり）
- **アニメ WebP は lossless で GIF の 1/3〜1/4**（実測 2.8〜4.2 倍圧縮）。
  しかもドット絵では **lossless の方が lossy より小さい**（限られた色数のため）。
  `<img src="...">` でそのまま animated 再生される
- 変換（ffmpeg は devbox に入っている。リポのルートから呼ぶこと）:
  `devbox run -- ffmpeg -y -i in.gif -c:v libwebp_anim -lossless 1 -loop 0 out.webp`
- 検証: ffprobe は animated WebP を読めない。`grep -a -o ANMF x.webp | wc -l` で
  コマ数を数え、ヘッダに `VP8X` と `ANIM` があることを見る
