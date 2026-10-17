package prunetools

// prunetools — 役目を終えた道具を、配った先のゲームから消す。
//
//	fge prune-stale-tools --game DIR [--dry-run]
//
// sync-agents の copyDirs と違って bin/ は丸ごと配り元の物ではない (ゲームが自分の
// 道具を置く場所でもある) ので、ここは名指しの一覧だけを見る。一度きりの後始末で、
// 恒久の配布規約ではないので agents-pack/manifest.json には載せない。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// StaleTools は役目を終えた道具の置き場 (ゲームのリポからの相対パス)。
//
// WhyNot: manifest から引かないのは、engine 側から道具を消した時点で manifest からも
// 消えて、消すべき名前が分からなくなるため (この道具の出番はまさにその後)。
// 写し漏れは TestStaleToolsCoverManifest が見張る。
//
// WhyNot: 今の manifest に載っていた物だけでなく、engine がこれまでに消した道具を
// 全部並べるのは、配った後に捨てた道具がゲーム側に取り残されるため (lint-composition.py が
// 実際にそうなっていた)。名前が余分にあっても、ゲームに無ければ何も起きない。
var StaleTools = []string{
	"bin/lint-composition.py",
	"bin/lint-loop.py",
	"bin/lint-f32.py",
	"bin/lint-fallback.py",
	"bin/sil-png.py",
	"bin/check-api-index.py",
	"bin/check-api-released.py",
	"bin/check-refs.py",
	"bin/check-render-budget.py",
	"bin/gen-api-digest.py",
	"bin/gen-rules.py",
	"bin/sync-agents.py",
	"bin/verify-win-checkd.py",
	"bin/carve/adopt.py",
	"bin/carve/carve.py",
	"bin/carve/gifs.py",
	"bin/carve/png_read.py",
	"bin/carve/render.py",
	"bin/carve/sheet.py",
	"bin/lint-view.py",
	"bin/lint-style.py",
	"bin/lint-palette.py",
	"bin/lint-sprite.py",
	"bin/lint-anim.py",
	"bin/lint-audio.py",
	"bin/lint-images.py",
	"bin/lint-ui-overflow.py",
	"bin/lint-jargon.py",
	"bin/img-digest.py",
	"bin/status.py",
	"bin/precommit.py",
	"bin/explain-error",
	"bin/checkd",
	".claude/hooks/after-flix-edit.py",
	".claude/hooks/after-flix-work.py",
	".claude/hooks/after-flix-touch.py",
	".claude/hooks/session-diet.py",
}

// staleHookCalls は .claude/settings.json に残っている古い呼び口と、その言い換え先。
//
// WhyNot: settings.json を写し直さず書き換えるのは、あれが copyIfAbsent (すでに有れば
// 上書きしない) で配られるため。ゲームが足したフックまで消えてしまう。
//
// WhyNot: 道具を消す前に書き換えるのは、指す先だけ消えるとフックが黙って死ぬため。
// 型検査が走らなくなっても、エラーは出ずに「何も起きない」形になる。
var staleHookCalls = [][2]string{
	{`python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/after-flix-touch.py\"`, `\"$CLAUDE_PROJECT_DIR/bin/fge\" hook-flix-touch`},
	{`python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/after-flix-work.py\"`, `\"$CLAUDE_PROJECT_DIR/bin/fge\" hook-flix-work`},
	{`python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/after-flix-edit.py\"`, `\"$CLAUDE_PROJECT_DIR/bin/fge\" hook-flix-edit`},
	// .codex/hooks.json は $CLAUDE_PROJECT_DIR を使わず、ゲームの根からの相対パスで呼ぶ。
	{`python3 .claude/hooks/after-flix-touch.py`, `bin/fge hook-flix-touch`},
	{`python3 .claude/hooks/after-flix-work.py`, `bin/fge hook-flix-work`},
	{`python3 .claude/hooks/after-flix-edit.py`, `bin/fge hook-flix-edit`},
}

// HookFiles はフックの呼び出しを書いた、ゲームの中の設定ファイル（どれも copyIfAbsent で配る）。
// .codex/hooks.json は settings.json と同じ形（hooks → イベント → matcher・hooks の組）。
var HookFiles = []string{".claude/settings.json", ".codex/hooks.json"}

// RemovedHooksKey はゲームが意図して外したフックの印を書く、設定ファイルの最上位のキー。
// 値は command の一部の文字列の並び。当たる物は AddMissingHooks が足し直さない。
const RemovedHooksKey = "fgeRemovedHooks"

// retiredHookCalls は settings.json から呼び出しごと外すフック（口は廃止して何もしない）。
// WhyNot: 何もしない口へ書き換えて残さないのは、matcher "*" で全ツールのたびにプロセスを
// 起こし続け、いつか口を消した日にゲームのフックが毎回エラーになるため。
var retiredHookCalls = []string{"session-diet.py", "hook-session-diet"}

const usage = "使い方: fge prune-stale-tools --game /path/to/game [--dry-run]"

// Run は掃除を走らせて終了コードを返す。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	game := ""
	dryRun := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--dry-run":
			dryRun = true
		case a == "--game":
			if i+1 >= len(args) {
				fmt.Fprintln(errOut, "error: --game にはゲームのフォルダを渡してください")
				return 2, nil
			}
			game = args[i+1]
			i++
		case strings.HasPrefix(a, "--game="):
			game = strings.TrimPrefix(a, "--game=")
		default:
			fmt.Fprintf(errOut, "error: 知らない引数です: %s\n%s\n", a, usage)
			return 2, nil
		}
	}
	if game == "" {
		fmt.Fprintf(errOut, "error: GAME を指定してください\n%s\n", usage)
		return 1, nil
	}
	if info, err := os.Stat(game); err != nil || !info.IsDir() {
		fmt.Fprintf(errOut, "error: ゲームのフォルダが見つかりません: %s\n", game)
		return 1, nil
	}

	var kept, targets []string
	for _, rel := range StaleTools {
		// WhyNot: engine 側にまだある道具を消さないのは、消す順番を間違えると
		// 「engine は配るのにゲームには無い」ゲームだけが取り残されるため。
		if isFile(filepath.Join(root, filepath.FromSlash(rel))) {
			kept = append(kept, rel)
			continue
		}
		if isFile(filepath.Join(game, filepath.FromSlash(rel))) {
			targets = append(targets, rel)
		}
	}

	for _, rel := range HookFiles {
		fixed, err := rewriteHookCalls(filepath.Join(game, filepath.FromSlash(rel)), dryRun)
		if err != nil {
			return 2, err
		}
		if fixed > 0 {
			verb := "書き換えました"
			if dryRun {
				verb = "書き換えます"
			}
			fmt.Fprintf(out, "[prune-stale-tools] %s のフックの呼び口 %d 件を %s\n", rel, fixed, verb)
		}
	}

	if len(kept) > 0 {
		fmt.Fprintf(out, "[prune-stale-tools] engine にまだあるので残します: %d 件 (%s)\n",
			len(kept), strings.Join(kept, " "))
	}
	if len(targets) == 0 {
		fmt.Fprintln(out, "[prune-stale-tools] 消す物はありません")
		return 0, nil
	}
	for _, rel := range targets {
		fmt.Fprintf(out, "[prune-stale-tools] 消す: %s\n", rel)
	}
	if dryRun {
		fmt.Fprintln(out, "[prune-stale-tools] 素振りなので消していません (--dry-run を外すと消します)")
		return 0, nil
	}
	for _, rel := range targets {
		if err := os.Remove(filepath.Join(game, filepath.FromSlash(rel))); err != nil {
			return 2, err
		}
	}
	for _, rel := range targets {
		// WhyNot: 中身が残っていれば失敗する os.Remove を使うのは、空になった
		// bin/carve/ や .claude/hooks/ だけを畳みたいため。中身のある置き場は触らない。
		_ = os.Remove(filepath.Dir(filepath.Join(game, filepath.FromSlash(rel))))
	}
	fmt.Fprintf(out, "[prune-stale-tools] %d 件消しました\n", len(targets))
	return 0, nil
}

// RewriteHookCalls は sync-agents が配るたびに呼ぶ口。HookFiles（settings.json・.codex/hooks.json）の古い呼び口を
// 今の口へ書き換え、廃止したフックを外して、直した数を返す。
// WhyNot: prune-stale-tools（一度きり・手で流す）だけに置かないのは、流し忘れたゲームに
// 廃止したフック（hook-session-diet・matcher "*"）が毎回のツール呼び出しで残り続けたため。
func RewriteHookCalls(path string) (int, error) { return rewriteHookCalls(path, false) }

// rewriteHookCalls は settings.json の古い呼び口を今の口へ書き換え、直した数を返す。
func rewriteHookCalls(path string, dryRun bool) (int, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	text := string(raw)
	fixed := 0
	for _, pair := range staleHookCalls {
		n := strings.Count(text, pair[0])
		if n == 0 {
			continue
		}
		fixed += n
		text = strings.ReplaceAll(text, pair[0], pair[1])
	}
	text, removed, err := dropRetiredHooks(text)
	if err != nil {
		err = fmt.Errorf("%s: %w", path, err)
		return 0, err
	}
	fixed += removed
	if fixed == 0 || dryRun {
		return fixed, nil
	}
	return fixed, os.WriteFile(path, []byte(text), 0o644)
}

// dropRetiredHooks は retiredHookCalls を呼ぶフックを外し、外した数を返す。
// 外したせいで空になったグループとイベントも畳む。
// WhyNot: 当たりが無いときに JSON を組み直さないのは、組み直すとキーの並びが
// 変わり、関係のない差分がゲーム側に出るため。
func dropRetiredHooks(text string) (string, int, error) {
	hit := false
	for _, c := range retiredHookCalls {
		hit = hit || strings.Contains(text, c)
	}
	if !hit {
		return text, 0, nil
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(text), &doc); err != nil {
		return text, 0, fmt.Errorf("JSON として読めません: %v", err)
	}
	events, _ := doc["hooks"].(map[string]any)
	removed := 0
	for name, v := range events {
		groups, _ := v.([]any)
		var keptGroups []any
		for _, g := range groups {
			group, ok := g.(map[string]any)
			if !ok {
				keptGroups = append(keptGroups, g)
				continue
			}
			hooks, _ := group["hooks"].([]any)
			var keptHooks []any
			for _, h := range hooks {
				cmd, _ := h.(map[string]any)["command"].(string)
				if isRetired(cmd) {
					removed++
					continue
				}
				keptHooks = append(keptHooks, h)
			}
			if len(keptHooks) == 0 && len(hooks) > 0 {
				continue
			}
			group["hooks"] = keptHooks
			keptGroups = append(keptGroups, group)
		}
		if len(keptGroups) == 0 {
			delete(events, name)
		} else {
			events[name] = keptGroups
		}
	}
	if removed == 0 {
		return text, 0, nil
	}
	var buf strings.Builder
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return text, 0, err
	}
	return buf.String(), removed, nil
}

func isRetired(cmd string) bool {
	for _, c := range retiredHookCalls {
		if strings.Contains(cmd, c) {
			return true
		}
	}
	return false
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// AddMissingHooks は配る側の settings.json（pack）にあってゲームの settings.json に無いフックの
// 呼び出しを、同じイベント・同じ matcher のグループへ足し、足した数を返す。
// WhyNot: settings.json を写し直さないのは copyIfAbsent（ゲームが足したフックを守る）のため。
// その代わり、engine が新しく配線したフック（例: hook-art-edit）が既存のゲームに届かなかった。
// 呼び出しの文字列がゲームのどこかにあれば足さない（ゲームが別の matcher へ移した物を二重にしない）。
func AddMissingHooks(gamePath, packPath string) (int, error) {
	raw, err := os.ReadFile(gamePath)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	packRaw, err := os.ReadFile(packPath)
	if err != nil {
		return 0, err
	}
	var game, pack map[string]any
	// 読めない settings.json は足さずに飛ばす（配る物はほかにもあるので、ここで配りを止めない）。
	if json.Unmarshal(raw, &game) != nil || json.Unmarshal(packRaw, &pack) != nil {
		return 0, nil
	}
	text := string(raw)
	removedMarks, _ := game[RemovedHooksKey].([]any)
	gameEvents, _ := game["hooks"].(map[string]any)
	if gameEvents == nil {
		gameEvents = map[string]any{}
	}
	packEvents, _ := pack["hooks"].(map[string]any)
	added := 0
	for name, v := range packEvents {
		groups, _ := v.([]any)
		for _, g := range groups {
			group, _ := g.(map[string]any)
			matcher, _ := group["matcher"].(string)
			hooks, _ := group["hooks"].([]any)
			packCmds := map[string]bool{}
			for _, h := range hooks {
				if c, _ := h.(map[string]any)["command"].(string); c != "" {
					packCmds[c] = true
				}
			}
			for _, h := range hooks {
				cmd, _ := h.(map[string]any)["command"].(string)
				if cmd == "" || isMarkedRemoved(cmd, removedMarks) {
					continue
				}
				if strings.Contains(text, jsonEscaped(cmd)) {
					added += widenMatcher(gameEvents, name, cmd, matcher, packCmds)
					continue
				}
				addHook(gameEvents, name, matcher, h)
				added++
			}
		}
	}
	if added == 0 {
		return 0, nil
	}
	game["hooks"] = gameEvents
	// WhyNot: 当たりが無いときは書き直さない（上の return）。組み直すとキーの並びが
	// 変わり、関係のない差分がゲーム側に出るため。当たった時だけ並びが変わるのは受け入れる。
	var buf strings.Builder
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(game); err != nil {
		return 0, err
	}
	return added, os.WriteFile(gamePath, []byte(buf.String()), 0o644)
}

// jsonEscaped は文字列を JSON の中に書いたときの形（両端の引用符を除く）にする。
// WhyNot: json.Marshal を使わないのは、既定で & < > を \u0026 などへ逃がし、
// 手で書いた settings.json の "&&" と食い違って毎回足し直してしまうため。
func jsonEscaped(s string) string {
	var buf strings.Builder
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s)
	b := strings.TrimSuffix(buf.String(), "\n")
	return b[1 : len(b)-1]
}

// isMarkedRemoved は cmd がゲームの外した印（RemovedHooksKey）のどれかを含むか。
func isMarkedRemoved(cmd string, marks []any) bool {
	for _, m := range marks {
		if s, _ := m.(string); s != "" && strings.Contains(cmd, s) {
			return true
		}
	}
	return false
}

// widenMatcher は、cmd を持つゲームのグループの matcher が配る側の matcher の一部の道具名しか
// 持たないとき（"Edit|Write" と "Edit|Write|apply_patch"）、配る側の matcher に広げて 1 を返す。
// WhyNot: 呼び出しの文字列だけで「もうある」と見ると、engine が道具名を足しても既にある
// ゲームに届かなかった（Codex は編集を apply_patch・シェルを Bash で呼ぶ。0.35.38 で実機で確かめた）。
// 配る側に無い道具名を持つ matcher（ゲームが選んだ物）と、ゲームが足したフックの混ざるグループは触らない。
func widenMatcher(events map[string]any, name, cmd, packMatcher string, packCmds map[string]bool) int {
	if packMatcher == "" {
		return 0
	}
	want := map[string]bool{}
	for _, t := range strings.Split(packMatcher, "|") {
		want[t] = true
	}
	groups, _ := events[name].([]any)
	for _, g := range groups {
		group, ok := g.(map[string]any)
		if !ok {
			continue
		}
		hooks, _ := group["hooks"].([]any)
		has, allPack := false, true
		for _, h := range hooks {
			c, _ := h.(map[string]any)["command"].(string)
			has = has || c == cmd
			allPack = allPack && packCmds[c]
		}
		m, _ := group["matcher"].(string)
		if !has || m == "" || m == packMatcher {
			continue
		}
		parts := strings.Split(m, "|")
		subset := len(parts) < len(want)
		for _, t := range parts {
			if !want[t] {
				subset = false
			}
		}
		if subset && allPack {
			group["matcher"] = packMatcher
			return 1
		}
	}
	return 0
}

// addHook は events[name] の中の matcher が同じグループへ hook を足す（無ければグループを作る）。
func addHook(events map[string]any, name, matcher string, hook any) {
	groups, _ := events[name].([]any)
	for _, g := range groups {
		group, ok := g.(map[string]any)
		if !ok {
			continue
		}
		if m, _ := group["matcher"].(string); m == matcher {
			hooks, _ := group["hooks"].([]any)
			group["hooks"] = append(hooks, hook)
			return
		}
	}
	group := map[string]any{"hooks": []any{hook}}
	if matcher != "" {
		group["matcher"] = matcher
	}
	events[name] = append(groups, group)
}
