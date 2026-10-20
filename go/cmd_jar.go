package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/jarshare"
	"github.com/ababup1192/flix_game_engine/go/internal/resident"
)

// WhyNot: 「--remote」の字を使い方から消さない — 作り手（jar builder run）は、ゲームの版のエンジンが段 2 の口を持つかを、
// この使い方の字に --remote があるかで見る。
const jarUsage = `使い方（bin/headless-run が呼ぶ。docs/design/prebuilt-jar.md）:
  jar key     --dispatcher=F --flix-jar=J --revision=N [--dir .]                 鍵（64 字）を出す
  jar fetch   --dispatcher=F --flix-jar=J --revision=N [--manifest=M] [--dir .]  段 1（この機械）→ 段 2（ゲームの repo の Release）の順に
                                                                               鍵の jar を探し、確かめて build/headless へ写す。取れた段（1 か 2）を出す・無ければ 1 で終わる
  jar publish --dispatcher=F --flix-jar=J --revision=N [--remote] [--commit=C] [--source-dir=.] [--dir .]
                                                                               build/headless の jar を段 1 へ置く（--remote で段 2 へも上げ、段 2 の古い物を消す）
  jar prune                                                                    段 1 の古い物を消す（最後に使ってから 14 日・全部で 2 GB）
  jar builder run --repo=<ゲームの clone> [--work=W] [--engines=E]  作り手の 1 巡（master が進んでいれば作って段 1・段 2 へ）
  jar builder install|uninstall --repo=<ゲームの clone> [--dry-run]              作り手を launchd に入れる・外す（5 分ごと）
段 1 の置き場は ~/.cache/flix-headless-jar（FGE_JAR_CACHE で変える・off で使わない）。段 2 は FGE_PREBUILT_JAR=off で使わない。`

func init() {
	register("jar",
		"窓なしのゲームの headless.jar を、同じ機械の作業場どうし（段 1）とゲームの repo の Release（段 2）で分け合う (docs/design/prebuilt-jar.md)。jar key|fetch|publish|prune|builder",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			if len(rest) == 0 {
				fmt.Fprintln(errOut, jarUsage)
				return 2
			}
			verb, args := rest[0], rest[1:]
			cache := jarshare.CacheRoot(os.Getenv)
			switch verb {
			case "prune":
				n, err := jarshare.Prune(cache, time.Now())
				if err != nil {
					fmt.Fprintf(errOut, "fge jar prune: %v\n", err)
					return 1
				}
				fmt.Fprintf(out, "[jar] 段 1 から %d 本消した\n", n)
				return 0
			case "builder":
				return jarBuilder(out, errOut, args)
			}
			flags, _ := residentFlags(args)
			dir := flags["--dir"]
			if dir == "" {
				dir = "."
			}
			in, err := jarInputs(verb, dir, flags)
			if err != nil {
				fmt.Fprintf(errOut, "fge jar %s: %v\n", verb, err)
				return 1
			}
			key := jarshare.Key(in)
			switch verb {
			case "key":
				if key == "" {
					fmt.Fprintln(errOut, "fge jar key: 鍵を作れない（元の指紋・入口の束・flix.jar・版のどれかが無い）")
					return 1
				}
				fmt.Fprintln(out, key)
				return 0
			case "fetch":
				return jarFetch(out, errOut, cache, key, in, dir, flags["--manifest"])
			case "publish":
				return jarPublish(errOut, cache, key, in, dir, hasFlag(args, "--remote"), flags["--commit"])
			}
			fmt.Fprintln(errOut, jarUsage)
			return 2
		})
}

// jarFetch は段 1 → 段 2 の順に鍵の jar を探して build/headless へ写し、取れた段を出す。
func jarFetch(out, errOut *strings.Builder, cache, key string, in jarshare.Inputs, dir, manifest string) int {
	// --manifest は headless-run が今取った指紋（無ければここで取る）。取った後の build/headless/jar.manifest に書く。
	if manifest == "" {
		manifest, _ = resident.BuildManifest(dir)
	}
	err := jarshare.Fetch(cache, key, in, dir, manifest)
	if err == nil {
		fmt.Fprintln(out, "1")
		return 0
	}
	fmt.Fprintf(errOut, "fge jar fetch: 段 1: %v\n", err)
	gh, repo, why := remoteOf(dir)
	if why != "" {
		fmt.Fprintf(errOut, "fge jar fetch: 段 2 を使わない: %s\n", why)
		return 1
	}
	if err := jarshare.FetchRemote(context.Background(), gh, repo, cache, key, in); err != nil {
		fmt.Fprintf(errOut, "fge jar fetch: 段 2: %v\n", err)
		return 1
	}
	if err := jarshare.Fetch(cache, key, in, dir, manifest); err != nil {
		fmt.Fprintf(errOut, "fge jar fetch: 段 2 から段 1 へ入れた後: %v\n", err)
		return 1
	}
	fmt.Fprintln(out, "2")
	return 0
}

// jarPublish は段 1 へ置き、remote なら段 2 へも上げて段 2 の古い物を消す。
func jarPublish(errOut *strings.Builder, cache, key string, in jarshare.Inputs, dir string, remote bool, commit string) int {
	if err := jarshare.Publish(cache, key, in, dir); err != nil {
		fmt.Fprintf(errOut, "fge jar publish: %v\n", err)
		return 1
	}
	if !remote {
		return 0
	}
	gh, repo, why := remoteOf(dir)
	if why != "" {
		fmt.Fprintf(errOut, "fge jar publish: 段 2 へ上げない: %s\n", why)
		return 1
	}
	now := time.Now()
	if err := jarshare.PublishRemote(context.Background(), gh, repo, cache, key, commit, now); err != nil {
		fmt.Fprintf(errOut, "fge jar publish: 段 2: %v\n", err)
		return 1
	}
	if _, err := jarshare.PruneRemote(context.Background(), gh, repo, key, now); err != nil {
		fmt.Fprintf(errOut, "fge jar publish: 段 2 の掃除: %v\n", err)
	}
	return 0
}

// remoteOf は段 2 を使う時の gh とゲームの repo。使わない時は訳。
func remoteOf(dir string) (jarshare.GH, string, string) {
	if !jarshare.RemoteEnabled(os.Getenv) {
		return nil, "", jarshare.RemoteEnv + "=off"
	}
	gh, ok := jarshare.FindGH()
	if !ok {
		return nil, "", "gh が無い"
	}
	repo, err := jarshare.RepoOf(dir)
	if err != nil {
		return nil, "", err.Error()
	}
	return gh, repo, ""
}

// jarBuilder は作り手の口（run・install・uninstall）。
func jarBuilder(out, errOut *strings.Builder, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(errOut, jarUsage)
		return 2
	}
	verb := args[0]
	flags, _ := residentFlags(args[1:])
	repo := flags["--repo"]
	if repo == "" {
		fmt.Fprintln(errOut, "fge jar builder: --repo=<ゲームの clone> が要る")
		return 2
	}
	repo, _ = filepath.Abs(repo)
	home, _ := os.UserHomeDir()
	switch verb {
	case "run":
		// --engines は配ったエンジンの置き場を差し替える（段 2 の口のある版がまだ配られていない時の通しの確かめに使う）。
		cfg := jarshare.BuilderConfig{Repo: repo, Work: flags["--work"], Engines: flags["--engines"]}.WithDefaults(home)
		// WhyNot: 行を out に貯めない — launchd は標準出力を記録のファイルへ書くので、作っている間の行をそのまま出す。
		if err := jarshare.RunBuilder(cfg, os.Stdout); err != nil {
			fmt.Fprintf(errOut, "[jar-builder] %v\n", err)
			return 1
		}
		return 0
	case "install", "uninstall":
		return jarBuilderLaunchd(out, errOut, verb, repo, home, hasFlag(args, "--dry-run"))
	}
	fmt.Fprintln(errOut, jarUsage)
	return 2
}

// jarBuilderLaunchd は作り手を launchd に入れる・外す。--dry-run なら plist の字と、流すはずの launchctl を出すだけ。
func jarBuilderLaunchd(out, errOut *strings.Builder, verb, repo, home string, dryRun bool) int {
	label := jarshare.LabelOf(repo)
	plistPath := filepath.Join(home, "Library", "LaunchAgents", label+".plist")
	logPath := filepath.Join(home, ".flix_ge_studio", "prebuilt", filepath.Base(repo), "builder.log")
	domain := fmt.Sprintf("gui/%d", os.Getuid())
	if verb == "uninstall" {
		if dryRun {
			fmt.Fprintf(out, "launchctl bootout %s/%s\nrm %s\n", domain, label, plistPath)
			return 0
		}
		_ = exec.Command("launchctl", "bootout", domain+"/"+label).Run()
		if err := os.Remove(plistPath); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(errOut, "fge jar builder uninstall: %v\n", err)
			return 1
		}
		fmt.Fprintf(out, "[jar-builder] 外した: %s\n", label)
		return 0
	}
	text, err := jarshare.RenderPlist(jarshare.PlistConfig{
		Label: label,
		Fge:   filepath.Join(repoRoot(), "bin", "fge"),
		Repo:  repo,
		Log:   logPath,
		Path:  launchdPath(),
	})
	if err != nil {
		fmt.Fprintf(errOut, "fge jar builder install: %v\n", err)
		return 1
	}
	if dryRun {
		fmt.Fprintf(out, "%s\n---\n%s\nlaunchctl bootstrap %s %s\n", plistPath, text, domain, plistPath)
		return 0
	}
	for _, d := range []string{filepath.Dir(plistPath), filepath.Dir(logPath)} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			fmt.Fprintf(errOut, "fge jar builder install: %v\n", err)
			return 1
		}
	}
	if err := os.WriteFile(plistPath, []byte(text), 0o644); err != nil {
		fmt.Fprintf(errOut, "fge jar builder install: %v\n", err)
		return 1
	}
	if b, err := exec.Command("launchctl", "bootstrap", domain, plistPath).CombinedOutput(); err != nil {
		fmt.Fprintf(errOut, "fge jar builder install: launchctl bootstrap: %v: %s\n", err, strings.TrimSpace(string(b)))
		return 1
	}
	fmt.Fprintf(out, "[jar-builder] 入れた: %s（5 分ごと・記録 %s）\n", label, logPath)
	return 0
}

// jarInputs は鍵に混ぜる物を集める。元の指紋は、fetch と key は今のゲームの根から、publish は jar を作った写し
// （build/headless/proj: 作り始めに写した src・flix.toml・packages.lock）から取る。
//
// WhyNot: publish で根から取らない — 作っている間にゲームの src が保存されていれば、根の src は作った jar の元と違う。
func jarInputs(verb, dir string, flags map[string]string) (jarshare.Inputs, error) {
	dispatcher, err := os.ReadFile(flags["--dispatcher"])
	if err != nil {
		return jarshare.Inputs{}, fmt.Errorf("--dispatcher を読めない: %v", err)
	}
	flixSHA, err := jarshare.FileSHA(flags["--flix-jar"])
	if err != nil {
		return jarshare.Inputs{}, fmt.Errorf("--flix-jar を読めない: %v", err)
	}
	from := dir
	if verb == "publish" {
		from = filepath.Join(dir, "build", "headless", "proj")
	}
	// --source-dir は、作らずに段 1 から取った jar を段 2 へ上げる時に、元の指紋を根から取らせる（写しには src が無い）。
	if flags["--source-dir"] != "" {
		from = filepath.Join(dir, flags["--source-dir"])
	}
	source, err := resident.BuildSourceManifest(from)
	if err != nil {
		return jarshare.Inputs{}, err
	}
	return jarshare.Inputs{Source: source, Dispatcher: string(dispatcher), FlixJarSHA: flixSHA, Revision: flags["--revision"]}, nil
}

// launchdPath は作り手の PATH。今 git・gh・java がいるフォルダと、OS の決まったフォルダだけを並べる。
//
// WhyNot: 今の PATH を丸ごと写さない — 会話ごとの一時のフォルダやエージェントの作業場が入っていて、それが消えると
// 作り手が git も java も引けなくなる。
func launchdPath() string {
	var dirs []string
	seen := map[string]bool{}
	add := func(d string) {
		if d != "" && !seen[d] {
			seen[d] = true
			dirs = append(dirs, d)
		}
	}
	for _, tool := range []string{"git", "gh", "java"} {
		if p, err := exec.LookPath(tool); err == nil {
			// symlink は先を辿る（作業場の .devbox の profile は、作業場を消すと無くなる。先の nix store は残る）。
			if real, err := filepath.EvalSymlinks(p); err == nil {
				p = real
			}
			add(filepath.Dir(p))
		}
	}
	for _, d := range []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"} {
		add(d)
	}
	return strings.Join(dirs, ":")
}
