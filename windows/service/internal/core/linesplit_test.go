package core

import (
	"slices"
	"testing"
)

func TestLineSplitterHandlesLFAndCRLF(t *testing.T) {
	var splitter LineSplitter
	if got := splitter.Append([]byte("one\ntwo\r\nthree\n")); !slices.Equal(got, []string{"one", "two", "three"}) {
		t.Errorf("lines = %q", got)
	}
	if rest, ok := splitter.Flush(); ok {
		t.Errorf("unexpected remainder %q", rest)
	}
}

func TestLineSplitterHandlesTerminatorsSplitAcrossAppends(t *testing.T) {
	var splitter LineSplitter
	if got := splitter.Append([]byte("one\r")); len(got) != 0 {
		t.Errorf("premature line %q", got)
	}
	if got := splitter.Append([]byte("\ntwo")); !slices.Equal(got, []string{"one"}) {
		t.Errorf("lines = %q", got)
	}
	if got := splitter.Append([]byte("\n")); !slices.Equal(got, []string{"two"}) {
		t.Errorf("lines = %q", got)
	}
}

func TestLineSplitterKeepsLoneCarriageReturn(t *testing.T) {
	var splitter LineSplitter
	if got := splitter.Append([]byte("one\rtwo\n")); !slices.Equal(got, []string{"one\rtwo"}) {
		t.Errorf("lines = %q", got)
	}
}

func TestLineSplitterReplacesInvalidUTF8(t *testing.T) {
	var splitter LineSplitter
	if got := splitter.Append([]byte{0x66, 0x80, 0x6F, 0x0A}); !slices.Equal(got, []string{"f�o"}) {
		t.Errorf("lines = %q", got)
	}
}

func TestLineSplitterFlushesPartialLineOnce(t *testing.T) {
	var splitter LineSplitter
	if got := splitter.Append([]byte("partial")); len(got) != 0 {
		t.Errorf("premature line %q", got)
	}
	if rest, ok := splitter.Flush(); !ok || rest != "partial" {
		t.Errorf("flush = %q, %v", rest, ok)
	}
	if rest, ok := splitter.Flush(); ok {
		t.Errorf("second flush returned %q", rest)
	}
	// The buffer is usable again after a flush.
	if got := splitter.Append([]byte("next\n")); !slices.Equal(got, []string{"next"}) {
		t.Errorf("lines after flush = %q", got)
	}
}
