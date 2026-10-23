package dist

import (
	_ "embed"
	"fmt"
	"strings"
	"text/template"
)

//go:embed launch.sh
var launchTemplate string

//go:embed run.bat
var batTemplate string

// JRESpec は取ってくる JRE の 1 版。Root は Temurin の頭のフォルダの下で JRE の根になる所（macOS は Contents/Home）。
type JRESpec struct {
	Version string
	URL     string
	SHA256  string
	Root    string
}

// genFile は組み立てで作るファイル（起動・案内）。
type genFile struct {
	rel  string
	body string
	mode int64
}

// meta は起動と案内に差し込む値。
type meta struct {
	Name    string
	Title   string
	Version string
}

// Target は 1 つの OS の配り方。共通の組み立ては Build が持ち、ここには差だけを置く。
type Target struct {
	Key    string
	Arch   string
	Format string // "tar.gz" か "zip"
	JRE    JRESpec
	// root は game/ と jre/ を置くフォルダ（配布物の頭のフォルダからの相対・空なら頭そのもの）。
	root  func(m meta) string
	java  string
	files func(m meta) ([]genFile, error)
}

// JRE の版は 3 つの OS でそろえる。上げる時は Adoptium の API（api.adoptium.net/v3/assets/version/...）の
// binaries[].package の link と checksum を写す。
// WhyNot: latest を引かない — 同じ engine の版で作った配布物の中身が日によって変わり、実機で起きた事を手元で再現できない。
const jreVersion = "21.0.12.1+1"

const jreBase = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/"

// Targets は配れる OS。キーは fge dist の引数。
var Targets = map[string]Target{
	"linux": {
		Key: "linux", Arch: "x64", Format: "tar.gz",
		JRE: JRESpec{Version: jreVersion, URL: jreBase + "OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz",
			SHA256: "2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500"},
		root: func(meta) string { return "" },
		java: "bin/java",
		files: func(m meta) ([]genFile, error) {
			sh, err := render(launchTemplate, launchVars{
				Game: m.Name, OSLabel: "Linux x64・Steam Deck", Linux: true, ToRoot: ".",
				DataLabel: "~/.local/share/" + m.Name + "/", DataDefault: "${XDG_DATA_HOME:-$HOME/.local/share}/$game",
				CacheDefault: "${XDG_CACHE_HOME:-$HOME/.cache}/$game",
			})
			if err != nil {
				return nil, err
			}
			return []genFile{{"run.sh", sh, 0o755}, {"README.txt", readmeLinux(m), 0o644}}, nil
		},
	},
	"macos": {
		Key: "macos", Arch: "arm64", Format: "zip",
		JRE: JRESpec{Version: jreVersion, URL: jreBase + "OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz",
			SHA256: "dec50fc6f9fcd4fe3ae8cabf5a5fa68f6afc48841f7698e468e9aa5d54beed84", Root: "Contents/Home"},
		root: func(m meta) string { return m.Name + ".app/Contents/Resources" },
		java: "bin/java",
		files: func(m meta) ([]genFile, error) {
			// GLFW はメインスレッドで動く必要があり、-XstartOnFirstThread が無いとゲームが自分を起動し直す。
			sh, err := render(launchTemplate, launchVars{
				Game: m.Name, OSLabel: "macOS Apple Silicon", ToRoot: "../Resources",
				DataLabel: "~/Library/Application Support/" + m.Name + "/", DataDefault: "$HOME/Library/Application Support/$game",
				CacheDefault: "$HOME/Library/Caches/$game",
				JavaFlags:    "-XstartOnFirstThread -Xdock:name=" + shellQuote(m.Title) + " ",
			})
			if err != nil {
				return nil, err
			}
			app := m.Name + ".app/Contents/"
			return []genFile{
				{app + "MacOS/" + m.Name, sh, 0o755},
				{app + "Info.plist", infoPlist(m), 0o644},
				{"README.txt", readmeMacOS(m), 0o644},
			}, nil
		},
	},
	"windows": {
		Key: "windows", Arch: "x64", Format: "zip",
		JRE: JRESpec{Version: jreVersion, URL: jreBase + "OpenJDK21U-jre_x64_windows_hotspot_21.0.12.1_1.zip",
			SHA256: "d35f31e712f0fcf6ac5a093edc90204fbff22f720ba3950bd09d331d5e621636"},
		root: func(meta) string { return "" },
		java: "bin/java.exe",
		files: func(m meta) ([]genFile, error) {
			bat, err := render(batTemplate, launchVars{Game: m.Name})
			if err != nil {
				return nil, err
			}
			// WhyNot: LF のまま置かない — cmd は LF だけの .bat で goto や括弧の中の行を読み違える。
			return []genFile{
				{"run.bat", toCRLF(bat), 0o755},
				{"README.txt", toCRLF(readmeWindows(m)), 0o644},
			}, nil
		},
	},
}

// TargetKeys は Targets を決まった順に並べる。
var TargetKeys = []string{"linux", "macos", "windows"}

type launchVars struct {
	Game, OSLabel, ToRoot, DataLabel, DataDefault, CacheDefault, JavaFlags string
	Linux                                                                  bool
}

func render(tmpl string, v launchVars) (string, error) {
	t, err := template.New("launch").Option("missingkey=error").Parse(tmpl)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	if err := t.Execute(&b, v); err != nil {
		return "", err
	}
	return b.String(), nil
}

func toCRLF(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\n", "\r\n")
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;").Replace(s)
}

func infoPlist(m meta) string {
	id := "dev.flixge." + strings.ReplaceAll(m.Name, "_", "-")
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>%s</string>
	<key>CFBundleIdentifier</key><string>%s</string>
	<key>CFBundleName</key><string>%s</string>
	<key>CFBundleDisplayName</key><string>%s</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleGetInfoString</key><string>%s</string>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
	<key>LSArchitecturePriority</key><array><string>arm64</string></array>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
`, xmlEscape(m.Name), xmlEscape(id), xmlEscape(m.Name), xmlEscape(m.Title), xmlEscape(m.Version))
}

func readmeLinux(m meta) string {
	return m.Title + "（" + m.Name + " " + m.Version + `）— Linux x64・Steam Deck 用

起動:   ./run.sh
セーブ: ~/.local/share/` + m.Name + `/saves/
ログ:   ~/.local/share/` + m.Name + `/logs/run.log（1 つ前は run.prev.log）

Steam Deck:
  1. デスクトップモードで、このフォルダを ~/Games/ などに解く
     （tar xzf で解く。zip や FAT の USB を通すと実行権限が落ちる → chmod +x run.sh jre/bin/*）
  2. Steam を開き「ゲーム」→「ゲーム以外の物をマイライブラリに追加」→「参照」で run.sh を選ぶ
  3. ゲームモードに戻り、ライブラリの「ゲーム以外」から起動する

環境変数: FGE_WAYLAND=1（Wayland で開く）・FGE_JAVA_OPTS（java の旗）・FGE_DATA_DIR（セーブの置き場）
`
}

func readmeMacOS(m meta) string {
	return m.Title + "（" + m.Name + " " + m.Version + `）— macOS（Apple Silicon）用

起動:   ` + m.Name + `.app を「アプリケーション」へ移してダブルクリック
セーブ: ~/Library/Application Support/` + m.Name + `/saves/
ログ:   ~/Library/Application Support/` + m.Name + `/logs/run.log

署名していないので、初回は macOS が止めます:
  1. ダブルクリック →「開けません」のダイアログを「完了」で閉じる
  2. システム設定 →「プライバシーとセキュリティ」→ 下の方の「このまま開く」→ パスワード
  3. もう一度ダブルクリック →「開く」
  端末で済ませるなら: xattr -dr com.apple.quarantine /Applications/` + m.Name + `.app
`
}

func readmeWindows(m meta) string {
	// WhyNot: BOM を付けずに置かない — 古いメモ帳は BOM の無い UTF-8 を Shift_JIS と読んで字が化ける。
	return "\ufeff" + m.Title + "（" + m.Name + " " + m.Version + `）— Windows x64 用

起動:   zip を「すべて展開」してから run.bat をダブルクリック（zip の中から直に開くと動かない）
        コンソールは最小化で開き、数秒でゲームのウィンドウが出ます
セーブ: %LOCALAPPDATA%\` + m.Name + `\saves\
ログ:   %LOCALAPPDATA%\` + m.Name + `\logs\run.log

署名していないので、初回は「Windows によって PC が保護されました」と出ることがあります:
「詳細情報」→「実行」で開きます。
`
}
