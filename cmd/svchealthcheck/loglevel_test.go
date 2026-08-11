package main

import (
	"log/slog"
	"testing"
)

func TestHealthLevel(t *testing.T) {
	if healthLevel(true) != slog.LevelInfo {
		t.Error("changed status should log at INFO")
	}
	if healthLevel(false) != slog.LevelDebug {
		t.Error("steady status should log at DEBUG")
	}
}
