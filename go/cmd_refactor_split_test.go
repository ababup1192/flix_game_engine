package main

import (
	"os"
	"reflect"
	"testing"
)

func TestSplitCommandLineKeepsQuotedSpaces(t *testing.T) {
	got, err := splitCommandLine(`java -jar "C:/Program Files/flix.jar" check`)
	want := []string{"java", "-jar", "C:/Program Files/flix.jar", "check"}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("%q %v", got, err)
	}
}

func TestSplitCommandLineRefusesShellSyntax(t *testing.T) {
	for _, line := range []string{"make check && make test", "make check > log", "make $X", "a | b", `"open`} {
		if _, err := splitCommandLine(line); err == nil {
			t.Errorf("%q を受けた", line)
		}
	}
}

func TestSplitCommandLineKeepsBackslashPaths(t *testing.T) {
	got, err := splitCommandLine(`bin\fge check`)
	if err != nil || !reflect.DeepEqual(got, []string{`bin\fge`, "check"}) {
		t.Fatalf("%q %v", got, err)
	}
}

func TestVerifyBinFgeRunsThisFgeGo(t *testing.T) {
	self, _ := os.Executable()
	got := resolveVerifyArgv([]string{"bin/fge", "check"}, false, true)
	if !reflect.DeepEqual(got, []string{self, "check"}) {
		t.Fatalf("%q", got)
	}
}

func TestVerifyBinFgeInTheEngineRootRunsMake(t *testing.T) {
	got := resolveVerifyArgv([]string{"bin/fge", "test"}, true, true)
	if !reflect.DeepEqual(got, []string{"make", "test"}) {
		t.Fatalf("%q", got)
	}
}

func TestVerifyBinFgeInTheEngineRootWithoutMakeRunsThisFgeGo(t *testing.T) {
	self, _ := os.Executable()
	got := resolveVerifyArgv([]string{`bin\fge`, "check"}, true, false)
	if !reflect.DeepEqual(got, []string{self, "check"}) {
		t.Fatalf("%q", got)
	}
}

func TestVerifyBinFgeCheckGoesToTheResident(t *testing.T) {
	self, _ := os.Executable()
	if !isCheckVerify([]string{self, "check"}) || isCheckVerify([]string{self, "test"}) {
		t.Fatal("check だけを常駐の道へ回していない")
	}
}
