package agenteval

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// preflightTimeout は、お題の前に claude -p を 1 回だけ軽く呼ぶ時の上限。
const preflightTimeout = 90 * time.Second

// loginRe はログインが切れた・鍵が無い時に claude -p が出す字。
var loginRe = regexp.MustCompile(`(?i)oauth|log ?in|expired|authenticat|unauthori[sz]ed|\b401\b|api key|credential`)

// preflight は claude -p を 1 回だけ軽く呼び、動かなければ理由を返す（動けば nil）。
// WhyNot: お題を流し始めてから気づかない — ログインが切れていると全部のお題が数秒で「失敗」になり、
// 表は 0 点の列で埋まって、点が下がったのか道具が動かなかったのか見分けが付かない。
func preflight(claude, model string) error {
	args := []string{"-p", "OK とだけ返してください。", "--output-format", "json", "--max-turns", "1",
		"--disallowedTools", disallowedTools}
	if model != "" {
		args = append(args, "--model", model)
	}
	ctx, cancel := context.WithTimeout(context.Background(), preflightTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, claude, args...)
	cmd.Stdin = nil
	raw, err := cmd.Output()
	var stderr string
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		stderr = string(exitErr.Stderr)
	}
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("claude -p が %d 秒で返らない", int(preflightTimeout.Seconds()))
	}
	var execErr *exec.Error
	if errors.As(err, &execErr) {
		return fmt.Errorf("%s が見つからない（%v）", claude, execErr.Err)
	}
	return preflightProblem(string(raw), stderr, err != nil)
}

// preflightProblem は claude -p の出力（--output-format json）と stderr から、動かなかった理由を組む。
func preflightProblem(stdout, stderr string, failed bool) error {
	var res struct {
		IsError bool   `json:"is_error"`
		Result  string `json:"result"`
		Subtype string `json:"subtype"`
	}
	parsed := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &res) == nil
	if !failed && parsed && !res.IsError {
		return nil
	}
	why := strings.TrimSpace(res.Result)
	if why == "" {
		why = lastLine(strings.TrimSpace(stderr + "\n" + stdout))
	}
	if why == "" {
		why = "理由の字なし"
	}
	if loginRe.MatchString(why + "\n" + stderr) {
		return fmt.Errorf("claude -p のログインが切れている（%s）。ターミナルで claude を開いて /login でログインし直してから、もう一度流す", why)
	}
	return fmt.Errorf("claude -p が動かない（%s）。ターミナルで claude -p \"OK\" を打って確かめてから、もう一度流す", why)
}
