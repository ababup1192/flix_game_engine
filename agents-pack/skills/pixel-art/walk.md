# 歩き

Key poses: contact, passing, and their mirrors.
1. Contact - Front leg extended forward, back leg extended back, body at lowest point
2. Passing - Legs cross under body, body at highest point (1-pixel vertical bob)
3. Contact mirrored - Opposite leg forward

- Maintain consistent volume across all frames - the character should not grow or shrink
- Add 1-pixel vertical bob on passing frames; the head moves with the body
- Arms swing opposite to legs
- 0 と 2 は必ず形を変える（ずらしただけのコマは歩いて見えない）。
- 頭頂と足元の行を 4 方向で同じにする。

英文の 7 行は AbsolutelySkilled の pixel-art-sprites（Walk cycle の節・commit 24b943b）から引いた。MIT License, Copyright (c) 2026 AbsolutelySkilled。
「the head moves with the body」だけ足した（頭が上下しないというダメ出しを止めるため）。
