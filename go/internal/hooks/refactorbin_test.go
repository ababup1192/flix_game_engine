package hooks

import "path/filepath"

// WhyNot: テストの間だけ project の bin/fge を起こすのは、テストの実行ファイル自身は refactor を持たず、
// 答えを決めた偽の bin/fge をゲームの形の中に置いて確かめるため。
func init() {
	refactorBin = func(project string) (string, error) { return filepath.Join(project, "bin", "fge"), nil }
}
