package launcher

import "testing"

func TestParseAssignmentsReadsQuotedValues(t *testing.T) {
	got := parseAssignments([]byte("FLIXLINT_DIR='/a/b'\nFLIXLINT_SHIM='/c.jar'\n\nnoise\nPATH='/j/bin:/usr/bin'\n"))
	if got["FLIXLINT_DIR"] != "/a/b" || got["FLIXLINT_SHIM"] != "/c.jar" || got["PATH"] != "/j/bin:/usr/bin" {
		t.Fatalf("%v", got)
	}
}

func TestParseAssignmentsSkipsLinesWithoutEquals(t *testing.T) {
	if got := parseAssignments([]byte("noise\n")); len(got) != 0 {
		t.Fatalf("%v", got)
	}
}
