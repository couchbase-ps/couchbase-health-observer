package main

import "log/slog"

// healthLevel logs the per-tick health line at INFO when the global status
// changed since the last tick, else DEBUG (so a steady cluster does not spam).
func healthLevel(changed bool) slog.Level {
	if changed {
		return slog.LevelInfo
	}
	return slog.LevelDebug
}
