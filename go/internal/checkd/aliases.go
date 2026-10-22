package checkd

// 型の別名が変わった後は常駐を入れ替える (flixlint 0.8.3 の常駐の増分の check の穴の歯止め)。
//
// Flix 0.78 の増分の compile は、別名を引数の型にだけ使うファイルを、別名が変わっても型付けし直さない。そのため
// その def の古い型が残り、新しい形の値を渡す触っていないファイルが「Extra label」で落ちる (素の flix check は通る)。
// 常駐は変わったファイルだけを渡すので、別名の宣言が前の check と違う時は check の前に常駐を止め、起こし直した
// コンパイラで全部を検査させる。flixlint の常駐が別名の変化でキャッシュを捨てる版 (Resident.give) に上げたら外せる。

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

var aliasStart = regexp.MustCompile(`(?m)^[ \t]*(?:pub[ \t]+)?type[ \t]+alias\b`)

// typeAliases は text に書いた型の別名の宣言。1 つは `type alias` から、`=` の後の括弧の外の最初の行末まで。
// 空白の続きは 1 つの空白にする (字下げや改行の位置だけの違いは変化に数えない)。
func typeAliases(text string) []string {
	var out []string
	for _, loc := range aliasStart.FindAllStringIndex(text, -1) {
		i, depth, seenEq := loc[1], 0, false
		for ; i < len(text) && !(text[i] == '\n' && depth == 0 && seenEq); i++ {
			switch text[i] {
			case '(', '[', '{':
				depth++
			case ')', ']', '}':
				depth--
			case '=':
				seenEq = seenEq || depth == 0
			}
		}
		out = append(out, strings.Join(strings.Fields(text[loc[0]:i]), " "))
	}
	return out
}

// aliasesDigest は src/・test/ の .flix の型の別名の宣言の全部の SHA-256 (ファイルの相対パスの順)。
func aliasesDigest(root string) (string, error) {
	files, err := sourceFiles(root)
	if err != nil {
		return "", err
	}
	sort.Strings(files)
	all := sha256.New()
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return "", err
		}
		for _, a := range typeAliases(string(b)) {
			rel, _ := filepath.Rel(root, f)
			all.Write([]byte(filepath.ToSlash(rel) + "\x00" + a + "\x00"))
		}
	}
	return hex.EncodeToString(all.Sum(nil)), nil
}

// aliasesMoved は別名の宣言が前の check の時と違うか (前の記録が無い時も違うと見る)。今の物を記録に残す。
func aliasesMoved(r *hooks.Rules, pkg string) bool {
	now, err := aliasesDigest(pkg)
	if err != nil {
		return false
	}
	path := filepath.Join(stateDir(r, pkg), "aliases")
	before, err := os.ReadFile(path)
	if err == nil && string(before) == now {
		return false
	}
	_ = os.WriteFile(path, []byte(now), 0o644)
	return true
}
