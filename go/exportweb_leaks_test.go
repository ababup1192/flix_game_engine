package main

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func relativizeString(s string) string {
	out, _ := relativizeFlixSourcePaths([]byte(s))
	return string(out)
}

func TestRelativizeMacWorkFolder(t *testing.T) {
	if got := relativizeString("/Users/a/x/build/web-export/project/src/A.flix"); got != "game/src/A.flix" {
		t.Errorf("mac の作業フォルダ: %q", got)
	}
}

func TestRelativizePrivateVar(t *testing.T) {
	if got := relativizeString("/private/var/folders/zz/T/fge/project/src/A.flix"); got != "game/src/A.flix" {
		t.Errorf("/private/var の作業フォルダ: %q", got)
	}
}

func TestRelativizeWindowsBackslash(t *testing.T) {
	if got := relativizeString(`C:\Users\a\x\project\src\A.flix`); got != "game/src/A.flix" {
		t.Errorf("Windows の \\ の道: %q", got)
	}
}

func TestRelativizeWindowsLowerDriveSlash(t *testing.T) {
	if got := relativizeString("c:/users/a/x/project/src/A.flix"); got != "game/src/A.flix" {
		t.Errorf("小文字のドライブと / の道: %q", got)
	}
}

func TestRelativizeUNCPath(t *testing.T) {
	if got := relativizeString(`\\server\share\x\project\src\A.flix`); got != "game/src/A.flix" {
		t.Errorf("UNC の道: %q", got)
	}
}

func TestRelativizeNFDJapaneseFolder(t *testing.T) {
	// 「ゲーム」の NFD（ケ + 濁点の結合文字）
	nfd := "/Users/a/\u30b1\u3099\u30fc\u30e0/build/web-export/project/src/A.flix"
	if got := relativizeString(nfd); got != "game/src/A.flix" {
		t.Errorf("NFD の名前のフォルダ: %q", got)
	}
}

func TestRelativizeKeepsSubfolderAfterProject(t *testing.T) {
	if got := relativizeString("/w/project/src/scene/TitleScene.flix"); got != "game/src/scene/TitleScene.flix" {
		t.Errorf("project/ の後の段は残す: %q", got)
	}
}

func TestRelativizeTestFolder(t *testing.T) {
	if got := relativizeString("/w/project/test/TestA.flix"); got != "game/test/TestA.flix" {
		t.Errorf("test/ の位置も置き換える: %q", got)
	}
}

func TestRelativizeUsesLastProjectFolder(t *testing.T) {
	if got := relativizeString("/Users/a/project/g/build/web-export/project/src/A.flix"); got != "game/src/A.flix" {
		t.Errorf("最後の project/ の後を残す: %q", got)
	}
}

func TestRelativizeJoinedPositions(t *testing.T) {
	got := relativizeString("/Users/a/x/project/src/TitleScene.flix>flix_game_engine-0.103.0.fpkg:src/engine_world/UiFocusNav.flix")
	if got != "game/src/TitleScene.flix>flix_game_engine-0.103.0.fpkg:src/engine_world/UiFocusNav.flix" {
		t.Errorf("つながった形は各位置を置き換える: %q", got)
	}
}

func TestRelativizeLeavesEnginePosition(t *testing.T) {
	s := "flix_game_engine-0.103.0.fpkg:src/engine_world/App.flix"
	if got := relativizeString(s); got != s {
		t.Errorf("engine の相対の位置は替えない: %q", got)
	}
}

func TestRelativizeLeavesRelativeProjectPath(t *testing.T) {
	s := "project/src/A.flix"
	if got := relativizeString(s); got != s {
		t.Errorf("絶対パスで始まらない物は替えない: %q", got)
	}
}

func TestLeakFinderIgnoresGithubName(t *testing.T) {
	f := newWebLeakFinder("/Users/abab")
	if got := f.find([]byte("\x20github:ababup1192/flix_game_engine\x05abab")); len(got) != 0 {
		t.Errorf("github: の名前は漏れに数えない: %q", got)
	}
}

func TestLeakFinderFindsHomeWithoutLocal(t *testing.T) {
	f := newWebLeakFinder()
	if got := f.find([]byte("\x10/Users/someone/w/A.flix")); len(got) != 1 {
		t.Errorf("手元の道が無くても /Users/<名前>/ は見つける: %q", got)
	}
}

func TestLeakFinderFindsLinuxHome(t *testing.T) {
	f := newWebLeakFinder()
	if got := f.find([]byte("x/home/ci/w/y")); len(got) != 1 {
		t.Errorf("/home/<名前>/ を見つける: %q", got)
	}
}

func TestLeakFinderFindsWindowsHome(t *testing.T) {
	f := newWebLeakFinder()
	if got := f.find([]byte(`x C:\Users\Al\w y`)); len(got) != 1 {
		t.Errorf("C:\\Users\\<名前>\\ を見つける: %q", got)
	}
}

func TestLeakFinderFindsLocalTmpWork(t *testing.T) {
	f := newWebLeakFinder("/tmp/fge-tape-work")
	if got := f.find([]byte("\x09/tmp/fge-tape-work/cache")); len(got) != 1 {
		t.Errorf("名前を含まない作業フォルダは手元の道で見つける: %q", got)
	}
}

func TestLeakFinderFindsLocalBackslashForm(t *testing.T) {
	f := newWebLeakFinder("/srv/build/game")
	if got := f.find([]byte(`\srv\build\game\x`)); len(got) != 1 {
		t.Errorf("手元の道の \\ の形も見つける: %q", got)
	}
}

func TestLeakFinderIgnoresProjectURLBeforeEnginePosition(t *testing.T) {
	f := newWebLeakFinder()
	data := []byte("\x1chttps://example.com/project/\x3eflix_game_engine-0.104.0.fpkg:src/engine_world/App.flix")
	if got := f.find(data); len(got) != 0 {
		t.Errorf("/project/ を含む URL の後に engine の位置が並んでも漏れでない: %q", got)
	}
}

func TestRelativizeKeepsProjectFolderInsideSrc(t *testing.T) {
	if got := relativizeString("/w/project/src/project/A.flix"); got != "game/src/project/A.flix" {
		t.Errorf("src の中の project/ は位置の名前に残す: %q", got)
	}
}

func TestRelativizeCountsPositions(t *testing.T) {
	if _, n := relativizeFlixSourcePaths([]byte("/a/project/src/A.flix>/a/project/src/B.flix")); n != 2 {
		t.Errorf("置き換えた数は 2: %d", n)
	}
}

func TestLeakFinderPassesRelativizedPosition(t *testing.T) {
	f := newWebLeakFinder("/Users/abab", "/Users/abab/Desktop/g")
	if got := f.find([]byte("\x0fgame/src/A.flix>flix_game_engine-0.104.0.fpkg:src/App.flix")); len(got) != 0 {
		t.Errorf("置き換えた後の位置は漏れでない: %q", got)
	}
}

// testClassWith は定数プールに Utf8 の s・それを指す String・Long（2 枠）・Utf8 の "x" を持ち、後ろに tail が続くクラスのバイト列。
func testClassWith(s string, tail []byte) []byte {
	var b bytes.Buffer
	b.Write([]byte{0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 61})
	binary.Write(&b, binary.BigEndian, uint16(6))
	b.WriteByte(1)
	binary.Write(&b, binary.BigEndian, uint16(len(s)))
	b.WriteString(s)
	b.Write([]byte{8, 0, 1})
	b.Write([]byte{5, 0, 0, 0, 0, 0, 0, 0, 7})
	b.Write([]byte{1, 0, 1, 'x'})
	b.Write(tail)
	return b.Bytes()
}

func TestRewriteClassReplacesUtf8AndKeepsRest(t *testing.T) {
	tail := []byte{0, 0x21, 0, 2, 0, 0}
	got, _, _, err := rewriteClassSourcePaths(testClassWith("/Users/a/project/src/A.flix", tail), newWebLeakFinder())
	if err != nil || !bytes.Equal(got, testClassWith("game/src/A.flix", tail)) {
		t.Errorf("Utf8 だけ替わり、Long の後と残りはそのまま: %v %q", err, got)
	}
}

func TestRewriteClassReportsLeakLeft(t *testing.T) {
	_, _, leaks, _ := rewriteClassSourcePaths(testClassWith("/Users/a/notes.txt", nil), newWebLeakFinder())
	if len(leaks) != 1 {
		t.Errorf(".flix でないホームの道は置き換えず漏れとして返す: %q", leaks)
	}
}

func testClassWithTag(tag byte, body []byte) []byte {
	var b bytes.Buffer
	b.Write([]byte{0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 61})
	binary.Write(&b, binary.BigEndian, uint16(3))
	b.WriteByte(tag)
	b.Write(body)
	b.Write([]byte{1, 0, 1, 'x'})
	return b.Bytes()
}

func TestRewriteClassDoubleTakesTwoSlots(t *testing.T) {
	// Double は 2 枠なので、count 3 の定数プールは Double だけで終わり、後ろの Utf8 は残りのバイトとして写る
	data := testClassWithTag(6, []byte{0, 0, 0, 0, 0, 0, 0, 0})
	got, _, _, err := rewriteClassSourcePaths(data, newWebLeakFinder())
	if err != nil || !bytes.Equal(got, data) {
		t.Errorf("Double は 2 枠: %v", err)
	}
}

func TestRewriteClassMethodHandleIsFourBytes(t *testing.T) {
	data := testClassWithTag(15, []byte{1, 0, 1})
	if _, _, _, err := rewriteClassSourcePaths(data, newWebLeakFinder()); err != nil {
		t.Errorf("MethodHandle は 4 バイト: %v", err)
	}
}

func TestRewriteClassInvokeDynamicIsFiveBytes(t *testing.T) {
	data := testClassWithTag(18, []byte{0, 0, 0, 1})
	if _, _, _, err := rewriteClassSourcePaths(data, newWebLeakFinder()); err != nil {
		t.Errorf("InvokeDynamic は 5 バイト: %v", err)
	}
}

func TestRewriteClassUnknownTagIsError(t *testing.T) {
	if _, _, _, err := rewriteClassSourcePaths(testClassWithTag(2, nil), newWebLeakFinder()); err == nil {
		t.Error("知らない定数の種類は誤り")
	}
}

func TestRewriteClassTruncatedIsError(t *testing.T) {
	data := testClassWith("/Users/a/project/src/A.flix", nil)
	if _, _, _, err := rewriteClassSourcePaths(data[:16], newWebLeakFinder()); err == nil {
		t.Error("途中で切れたクラスは誤り")
	}
}

func TestRewriteClassCountsReplaced(t *testing.T) {
	_, n, _, _ := rewriteClassSourcePaths(testClassWith("/Users/a/project/src/A.flix", nil), newWebLeakFinder())
	if n != 1 {
		t.Errorf("置き換えた数は 1: %d", n)
	}
}

func TestRewriteJarCopiesNonClassAsIs(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "in.jar")
	f, _ := os.Create(src)
	zw := zip.NewWriter(f)
	w, _ := zw.Create("META-INF/x.txt")
	w.Write([]byte("/Users/a/project/src/A.flix"))
	zw.Close()
	f.Close()
	dst := filepath.Join(dir, "out.jar")
	if _, err := rewriteJarSourcePaths(src, dst, newWebLeakFinder()); err != nil {
		t.Fatal(err)
	}
	got, _ := readZipEntry(dst, "META-INF/x.txt")
	if string(got) != "/Users/a/project/src/A.flix" {
		t.Errorf("クラスでない物はそのまま写す: %q", got)
	}
}

func TestRewriteJarReportsLeakLeftInClass(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "in.jar")
	f, _ := os.Create(src)
	zw := zip.NewWriter(f)
	w, _ := zw.Create("A.class")
	w.Write(testClassWith("/Users/a/notes.txt", nil))
	zw.Close()
	f.Close()
	res, _ := rewriteJarSourcePaths(src, filepath.Join(dir, "out.jar"), newWebLeakFinder())
	if len(res.Leaks) != 1 {
		t.Errorf("置き換えた後も残るホームの道は 1 件: %q", res.Leaks)
	}
}

func TestRewriteJarReplacesClass(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "in.jar")
	f, _ := os.Create(src)
	zw := zip.NewWriter(f)
	w, _ := zw.Create("A.class")
	w.Write(testClassWith("/Users/a/project/src/A.flix", nil))
	zw.Close()
	f.Close()
	dst := filepath.Join(dir, "out.jar")
	if _, err := rewriteJarSourcePaths(src, dst, newWebLeakFinder()); err != nil {
		t.Fatal(err)
	}
	got, _ := readZipEntry(dst, "A.class")
	if !bytes.Equal(got, testClassWith("game/src/A.flix", nil)) {
		t.Errorf("jar の中のクラスの位置が替わるはず: %q", got)
	}
}

func TestFindWasmLeaksSeparatesNames(t *testing.T) {
	// 型の区画（1）に /Users/ の字、名前の区画（custom "name"）にも 1 つ
	body := []byte("/Users/a/x/")
	wasm := append([]byte("\x00asm\x01\x00\x00\x00"), 1, byte(len(body)))
	wasm = append(wasm, body...)
	name := append([]byte{4, 'n', 'a', 'm', 'e'}, []byte("/home/b/y/")...)
	wasm = append(wasm, 0, byte(len(name)))
	wasm = append(wasm, name...)
	got, err := findWasmLeaks(wasm, newWebLeakFinder())
	if err != nil || len(got.Wasm) != 1 || len(got.Names) != 1 {
		t.Errorf("wasm と names に 1 つずつ: %+v %v", got, err)
	}
}

func TestWebLeakReportHidesStringsByDefault(t *testing.T) {
	line := webLeakReport(map[string][]string{"wasm": {"/Users/secret/"}}, false, false)
	if bytes.Contains([]byte(line), []byte("secret")) {
		t.Errorf("既定では字を出さない: %q", line)
	}
}

func TestWebLeakReportPointsToEngineForSourcePosition(t *testing.T) {
	line := webLeakReport(map[string][]string{"wasm": {"/Users/a/w/project/src/A.flix"}}, false, false)
	if !bytes.Contains([]byte(line), []byte("engine に報告")) {
		t.Errorf(".flix の位置の漏れは engine に報告: %q", line)
	}
}

func TestWebLeakReportPointsToGameForOtherPath(t *testing.T) {
	line := webLeakReport(map[string][]string{"wasm": {"/Users/a/art/bg.png"}}, false, false)
	if !bytes.Contains([]byte(line), []byte("相対の道に直す")) {
		t.Errorf("ほかの絶対パスはゲームの字を直す: %q", line)
	}
}

func TestLeakFinderReturnsTextAfterHit(t *testing.T) {
	got := newWebLeakFinder().find([]byte("\x05/Users/a/art/bg.png\x01"))
	if len(got) != 1 || got[0] != "/Users/a/art/bg.png" {
		t.Errorf("当たりの後ろの字まで返す: %q", got)
	}
}

func TestWebLeakReportShowsStringsWhenAsked(t *testing.T) {
	line := webLeakReport(map[string][]string{"wasm": {"/Users/secret/"}}, true, false)
	if !bytes.Contains([]byte(line), []byte("secret")) {
		t.Errorf("--show-leaks では字を出す: %q", line)
	}
}

func TestParseExportWebArgsReadsShowLeaks(t *testing.T) {
	o, _ := parseExportWebArgs([]string{"game", "--show-leaks"})
	if !o.ShowLeaks {
		t.Error("--show-leaks を読むはず")
	}
}

func TestWebLeakReportAfterJarPointsToEngine(t *testing.T) {
	line := webLeakReport(map[string][]string{"wasm": {"/Users/a/art/bg.png"}}, false, true)
	if !bytes.Contains([]byte(line), []byte("engine に報告")) {
		t.Errorf("wasm の段の漏れは engine に報告: %q", line)
	}
}
