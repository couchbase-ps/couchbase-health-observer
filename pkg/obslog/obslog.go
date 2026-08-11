// Package obslog builds the Observer's slog text logger with a custom TRACE
// level and string level parsing for the --log-level flag.
package obslog

import (
	"fmt"
	"io"
	"log/slog"
	"strings"
)

// LevelTrace is finer than slog's DEBUG; used for per-endpoint ping detail.
const LevelTrace = slog.Level(-8)

// Parse maps a level name to a slog.Level. Case-insensitive.
func Parse(s string) (slog.Level, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "trace":
		return LevelTrace, nil
	case "debug":
		return slog.LevelDebug, nil
	case "info":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return 0, fmt.Errorf("unknown log level %q (want trace|debug|info|warn|error)", s)
	}
}

// New returns a TextHandler logger at the given level. The custom TRACE level
// prints as "TRACE" instead of slog's default "DEBUG-4".
func New(w io.Writer, level slog.Level) *slog.Logger {
	h := slog.NewTextHandler(w, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			if a.Key == slog.LevelKey {
				if lv, ok := a.Value.Any().(slog.Level); ok && lv == LevelTrace {
					a.Value = slog.StringValue("TRACE")
				}
			}
			return a
		},
	})
	return slog.New(h)
}
