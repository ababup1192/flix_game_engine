package hooks

// hook-art-edit — 絵に関わるファイルを書いた直後に走る検査。
//
// 絵の下限はモデルの判断に任せると飛ばされるので、機械の側から必ず声を出す。
// exit 2 で stderr が Claude に返る（作業自体は止めない）。同じ検査は
// bin/fge palette / bin/fge ui-overflow --strict / bin/fge view / sprite / anim でも走らせられる。
// 絵を描く View（描画の呼び出しが多い .flix）を書いたら、セッションに 1 回だけ
// 絵の決まり（.claude/rules/drawing.md）を指す 1 行も返す。

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Lint は 1 本の検査の呼び方（precommit と同じ形）。
type Lint func(out, errOut *strings.Builder, args []string) int

// RunArtEdit は書かれたファイルだけを見る（apply_patch なら含まれるファイル全部）。
func RunArtEdit(errOut io.Writer, root string, in io.Reader, lints map[string]Lint) int {
	payload, ok := ReadPayload(in)
	if !ok {
		return 0
	}
	r, err := LoadRules(root)
	if err != nil {
		fmt.Fprintf(errOut, "# hook-art-edit: %v\n", err)
		return 2
	}
	var msgs []string
	for _, path := range payload.EditedPaths(r) {
		target := absolutize(payload, root, path)
		if !isFile(target) {
			continue
		}
		m, abort := r.artChecks(errOut, target, lints)
		if abort {
			return 2
		}
		msgs = append(msgs, m...)
		if line := r.artRemind(payload.SessionID(), target, os.TempDir()); line != "" {
			msgs = append(msgs, line)
		}
	}
	if len(msgs) == 0 {
		return 0
	}
	fmt.Fprintln(errOut, strings.Join(msgs, "\n\n"))
	return 2
}

// artChecks は 1 ファイルに当たる検査を走らせ、失敗の文面を返す。abort は規約の誤り。
func (r *Rules) artChecks(errOut io.Writer, target string, lints map[string]Lint) ([]string, bool) {
	var msgs []string
	for _, c := range r.ArtEdit.Checks {
		// WhyNot: 名前で絞らずファイル名の末尾だけ見るのは、描画の少ないファイルを
		// 落とすのが検査側 (view の下限本数) の仕事で、入口が二重に絞ると
		// どちらが黙らせたのか追えなくなるため。
		if !strings.HasSuffix(target, c.Suffix) {
			continue
		}
		lint, known := lints[c.Sub]
		if !known {
			fmt.Fprintf(errOut, "# hook-art-edit: 知らない検査です: %s\n", c.Sub)
			return nil, true
		}
		var out, errBody strings.Builder
		args := make([]string, 0, len(c.Args))
		for _, a := range c.Args {
			args = append(args, strings.ReplaceAll(a, "{file}", target))
		}
		if lint(&out, &errBody, args) == 0 {
			continue
		}
		body := strings.TrimSpace(out.String() + errBody.String())
		if c.Prefix == "" {
			msgs = append(msgs, body)
			continue
		}
		msgs = append(msgs, c.Prefix+"\n\n"+body)
	}
	return msgs, false
}

// artRemind は、絵を描く View を書いたときだけ、セッションに 1 回 Message を返す。
// 印は markerDir/<markerPrefix><セッションの指紋>。セッション ID が無いときは毎回返す。
// WhyNot: 毎回返さないのは、z や UI の直しで同じ View を何度も書くたびに
// 同じ 1 行が積もるため。読んだかどうかは見えないので、1 回指したら任せる。
func (r *Rules) artRemind(session, target, markerDir string) string {
	rm := r.ArtEdit.Remind
	if !strings.HasSuffix(target, rm.Suffix) {
		return ""
	}
	re, err := regexp.Compile(rm.Pattern)
	if err != nil {
		return "# hook-art-edit: artEdit.remind.pattern が正規表現として壊れています: " + err.Error()
	}
	data, err := os.ReadFile(target)
	if err != nil || len(re.FindAllIndex(data, rm.MinHits)) < rm.MinHits {
		return ""
	}
	if session == "" {
		return rm.Message
	}
	sum := sha1.Sum([]byte(session))
	marker := filepath.Join(markerDir, rm.MarkerPrefix+hex.EncodeToString(sum[:8]))
	if isFile(marker) {
		return ""
	}
	if f, err := os.OpenFile(marker, os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
		f.Close()
	}
	return rm.Message
}
