package obslog

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	cases := map[string]slog.Level{
		"trace": LevelTrace, "debug": slog.LevelDebug, "info": slog.LevelInfo,
		"WARN": slog.LevelWarn, "error": slog.LevelError,
	}
	for in, want := range cases {
		got, err := Parse(in)
		if err != nil || got != want {
			t.Errorf("Parse(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	if _, err := Parse("bogus"); err == nil {
		t.Error("Parse(bogus) should error")
	}
}

func TestNewLabelsTrace(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf, LevelTrace)
	l.Log(nil, LevelTrace, "probe", "ok", true)
	if !strings.Contains(buf.String(), "level=TRACE") {
		t.Errorf("want level=TRACE, got %q", buf.String())
	}
	if !strings.Contains(buf.String(), "msg=probe") {
		t.Errorf("want msg=probe, got %q", buf.String())
	}
}

func TestNewGatesBelowLevel(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf, slog.LevelInfo)
	l.Debug("hidden")
	if buf.Len() != 0 {
		t.Errorf("debug should be gated at info level, got %q", buf.String())
	}
}
