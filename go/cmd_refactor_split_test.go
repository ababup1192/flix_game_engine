package main

import (
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
