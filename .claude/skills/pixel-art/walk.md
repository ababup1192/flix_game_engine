# 歩き

Key poses: contact, passing, and their mirrors.
1. Contact - Front leg extended forward, back leg extended back, body at lowest point
2. Passing - Legs cross under body, body at highest point (1-pixel vertical bob)
3. Contact mirrored - Opposite leg forward

- Maintain consistent volume across all frames - the character should not grow or shrink
- Add 1-pixel vertical bob on passing frames; the head moves with the body
- Arms swing opposite to legs
- 2 つの Contact（左足前と右足前）は必ず形を変える（ずらしただけのコマは歩いて見えない）。
- 頭頂と足元の行を 4 方向で同じにする。

英文の 7 行は AbsolutelySkilled の pixel-art-sprites の「Build a walk cycle animation」の節から引いた
（https://github.com/maddhruv/absolute/blob/24b943bdc6bb600905ca15cc09e78bf31b8c32f9/skills/pixel-art-sprites/SKILL.md）。

> MIT License. Copyright (c) 2026 AbsolutelySkilled.
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
「the head moves with the body」だけ足した（頭が上下しないというダメ出しを止めるため）。
