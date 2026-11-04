MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## 同梱物 / Bundled assets

`engine/src/render2d/BootFontData.flix` は起動画面のためにソースへ埋め込んだ生成物で、
次の 2 つを素にしています（`make boot-font` で作り直せます）。

- **起動用フォント**: PixelMplus（PixelMplus10-Regular.ttf）の ASCII を 10px の
  1bit ビットマップに変換した物。PixelMplus は M+ FONT LICENSE のもとで配布されています。
  M+ FONT LICENSE は再配布・改変・埋め込みを許諾しています。
- **起動用ロゴ**: 本リポジトリの `docs/brand/flix_ge_icon.png` を 64×64・16 色に落とした物。
