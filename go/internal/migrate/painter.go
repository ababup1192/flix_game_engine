package migrate

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// 比べのコマの PNG を塗る描き手（plans/novel-migrate-scale.md の 11 章）。コマの鍵は描く命令から作るので描き手を含まない。
// 描き手が違う 2 つの記録の画素を比べると、描き手の違い（字の縁・小さな丸の縁・面の ±1）が全部「迷った差」に出るので、
// 記録ごとに描き手の素性（logs/shoot.json の painter）を書き、違えば比べない。

// Paint* は shoot の --paint の値（make の MIGRATE_PAINT）。
const (
	PaintGPU = "gpu"
	PaintCPU = "cpu"
)

// PngPainterEnv は FlowVideo の JVM が読む描き手の環境変数（engine の VideoOut.settingsOf）。
const PngPainterEnv = "FGE_PNG_PAINTER"

// Painter* は logs/shoot.json の painter と frames.json の paintedWith の字。WebGPU は "webgpu <アダプターの名前>"。
const (
	PainterSoft   = "soft"
	painterWebGPU = "webgpu"
)

// isDir は path がフォルダか（fileExists はファイルだけを見る）。
func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// isWebGPUPainter は描き手の素性が WebGPU か。
func isWebGPUPainter(p string) bool { return p == painterWebGPU || strings.HasPrefix(p, painterWebGPU+" ") }

// rebaselineHint は描き手をそろえて基準を撮り直す 1 行。
const rebaselineHint = "前の版のフォルダで make migrate-baseline MIGRATE_OVERWRITE=1 MIGRATE_PAINT=gpu"

// choosePainter は撮る記録の描き手（FlowVideo へ渡す FGE_PNG_PAINTER の値）を決める。
// requested は --paint（空 = 既定）、baseline は基準の描き手（基準が無い・--overwrite の時は hasBaseline が偽）。
// 基準があれば基準と同じ描き手で塗る。頼んだ描き手が基準と違えば problem（撮らずに止める）。
func choosePainter(requested string, hasBaseline bool, baseline string) (value, note, problem string) {
	if !hasBaseline {
		if requested == PaintCPU {
			return PainterSoft, "", ""
		}
		return painterWebGPU, "", ""
	}
	switch {
	case isWebGPUPainter(baseline) && requested == PaintCPU:
		return "", "", "基準は GPU（" + baseline + "）で塗ってあり、CPU で塗った記録とは画素を比べられない。CPU で比べるなら " +
			strings.Replace(rebaselineHint, "MIGRATE_PAINT=gpu", "MIGRATE_PAINT=cpu", 1)
	case isWebGPUPainter(baseline):
		return painterWebGPU, "", ""
	case requested == PaintGPU:
		return "", "", "基準は CPU（SoftRaster）で塗ってあり、GPU で塗った記録とは画素を比べられない。GPU で比べるなら " + rebaselineHint +
			"（前の版の engine が GPU で塗れない時は、CPU のまま比べる）"
	case requested == "":
		return PainterSoft, "基準が CPU（SoftRaster）で塗ってあるので、CPU で塗る", ""
	}
	return PainterSoft, "", ""
}

// recordPainter は記録 root の描き手（logs/shoot.json の painter）。shoot.json はあるが painter の無い記録は CPU で塗っていた版の物。
// shoot.json の無い記録は分からない（空）。
func recordPainter(root string) string {
	data, err := os.ReadFile(filepath.Join(root, "logs", ShootSummaryFile))
	if err != nil {
		return ""
	}
	var s struct {
		Painter *string `json:"painter"`
	}
	if json.Unmarshal(data, &s) != nil {
		return ""
	}
	if s.Painter == nil {
		return PainterSoft
	}
	return *s.Painter
}

// paintedWith は記録 root の下の frames.json のうち、PNG を塗った物（painter が none でない）の描き手の素性の集まり（並べた列）。
// paintedWith の無い frames.json（前の版の VideoOut）は painter の字を使う。
func paintedWith(root string) []string {
	set := map[string]bool{}
	_ = filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || info.Name() != "frames.json" {
			return nil
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return nil
		}
		var f struct {
			Painter     string `json:"painter"`
			PaintedWith string `json:"paintedWith"`
		}
		if json.Unmarshal(data, &f) != nil || f.Painter == "none" || f.Painter == "" {
			return nil
		}
		if f.PaintedWith != "" {
			set[f.PaintedWith] = true
		} else {
			set[f.Painter] = true
		}
		return nil
	})
	out := make([]string, 0, len(set))
	for p := range set {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// shotPainter は撮り終えた記録の描き手と、知らせる事。painted は塗った frames.json の描き手（paintedWith）、
// value は頼んだ描き手、baseline は基準の描き手（鍵が基準と同じで 1 枚も塗らなかった時は基準の PNG を使うので、基準の描き手になる）。
func shotPainter(painted []string, value, baseline string) (painter, note, problem string) {
	switch {
	case len(painted) > 1:
		return "mixed: " + strings.Join(painted, " / "), "", "塗った描き手が混ざった（" + strings.Join(painted, " / ") +
			"）。GPU で塗れなかった仕事がある（ログの [video] の行）。--paint cpu で撮り直す"
	case len(painted) == 1 && isWebGPUPainter(value) && painted[0] == PainterSoft:
		return PainterSoft, "GPU（WebGPU）で塗れず、CPU（SoftRaster）で塗った（ログの [video] の行）", ""
	case len(painted) == 1:
		return painted[0], "", ""
	case baseline != "":
		return baseline, "", ""
	case isWebGPUPainter(value):
		return "", "", ""
	}
	return PainterSoft, "", ""
}

// painterMismatch は基準と新しい撮りの描き手が違う時の知らせ（同じ・分からない時は空）。
func painterMismatch(base, cur string) string {
	if strings.HasPrefix(cur, "mixed: ") || strings.HasPrefix(base, "mixed: ") {
		return fmt.Sprintf("描き手が混ざった記録は画素を比べない（基準: %s・新しい撮り: %s）。%s", base, cur, rebaselineHint)
	}
	if base == "" || cur == "" || base == cur {
		return ""
	}
	hint := rebaselineHint
	if base == PainterSoft {
		hint = "CPU で撮り直す: make migrate-new MIGRATE_PAINT=cpu（GPU で比べるなら " + rebaselineHint + "）"
	}
	return fmt.Sprintf("基準と新しい撮りの描き手が違うので画素を比べない（基準: %s・新しい撮り: %s）。%s", base, cur, hint)
}

// painterKey は描き手 painter で塗ったコマの render-cache の名前（engine の RenderCache.painterKeyOf と同じ式）。
func painterKey(key, painter string) string {
	sum := sha256.Sum256([]byte(key + "\n" + painter))
	return hex.EncodeToString(sum[:])
}

// cachedPNGFor は描き手 painter で塗った鍵 key のコマの render-cache の置き場。CPU は鍵のまま、WebGPU は素性を混ぜた名前。
// アダプターの分からない WebGPU（"webgpu" だけ）と分からない描き手は空（render-cache から写さない）。
func cachedPNGFor(dir, painter, key string) string {
	switch {
	case dir == "" || painter == "" || painter == painterWebGPU || strings.HasPrefix(painter, "mixed: "):
		return ""
	case painter == PainterSoft:
		return cachedPNG(dir, key)
	}
	return cachedPNG(dir, painterKey(key, painter))
}
