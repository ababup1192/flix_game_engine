# 公式の testplan から抜き出した部分集合

`../official/` は Yarn Spinner の公式リポ（YarnSpinnerTool/YarnSpinner の `Tests/TestCases`・
c5215f86dd5a6761aecbdc9f60f6a6108f91f919・MIT License は `../official/LICENSE.md`）の写し。
変数・`<<if>>`・`{式}` などを含むので、どれも `bin/fge yarn check` が行番号つきで断る（`go/internal/yarn` のテスト）。

ここの `<名前>.yarn` と `<名前>.testplan` は、公式の同じ名前のファイルから部分集合に収まる所だけを
そのまま抜き出した物（並びと字は公式のまま。抜いた所の testplan の行も抜く）。
`<名前>.yarn.json` は `bin/fge yarn build <名前>.yarn --no-vocab --out <名前>.yarn.json` で書いた木で、
engine_world の TestYarnOfficial が YarnRunner で流して testplan の出来事の列と照らす。
書き直したら Go のテスト（TestSubsetJsonIsFresh）がずれを止める。
