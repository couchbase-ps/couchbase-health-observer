package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"time"

	"github.com/couchbaselabs/couchbase-health-observer/pkg/obslog"
)

// HTTP POSTs the switch request. It is safe to reuse across ticks; each Notify
// builds its own request.
type HTTP struct {
	URL     string
	User    string // empty -> no basic auth
	Pass    string
	Headers []Header
	Client  *http.Client                    // nil -> http.DefaultClient
	Retries int                             // extra attempts after the first
	Backoff func(attempt int) time.Duration // nil -> DefaultBackoff
	DryRun  bool
	Now     func() time.Time // nil -> time.Now
	Log     *slog.Logger     // nil -> slog.Default()
}

// DefaultBackoff waits 1s after the first failure, 2s after the second.
func DefaultBackoff(attempt int) time.Duration { return time.Duration(attempt) * time.Second }

func (h *HTTP) client() *http.Client {
	if h.Client != nil {
		return h.Client
	}
	return http.DefaultClient
}

func (h *HTTP) now() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now()
}

func (h *HTTP) log() *slog.Logger {
	if h.Log != nil {
		return h.Log
	}
	return slog.Default()
}

func (h *HTTP) backoff(attempt int) time.Duration {
	if h.Backoff != nil {
		return h.Backoff(attempt)
	}
	return DefaultBackoff(attempt)
}

// retryable reports whether another attempt could plausibly succeed. Transport
// errors, 5xx and 429 are retried. Any other 4xx is a configuration error (bad
// credentials, wrong path) and retrying it only burns the tick budget, which the
// liveness heartbeat depends on.
func retryable(status int, err error) bool {
	if err != nil || status == 0 { // transport failure: nothing was answered
		return true
	}
	return status >= 500 || status == http.StatusTooManyRequests
}

func (h *HTTP) Notify(ctx context.Context, e Event) error {
	url := RedactURL(h.URL)
	if h.DryRun {
		h.log().Info("webhook_dry_run", "url", url, "from", e.From.Label, "to", e.To.Label)
		return nil
	}
	attempts := h.Retries + 1
	if attempts < 1 {
		attempts = 1
	}
	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		status, err := h.post(ctx, e, attempt)
		if err == nil {
			h.log().Info("webhook_called", "url", url, "status", status, "attempt", attempt)
			return nil
		}
		lastErr = err
		if !retryable(status, nil) || attempt == attempts {
			h.log().Error("webhook_failed", "url", url, "attempts", attempt, "err", err.Error())
			return lastErr
		}
		wait := h.backoff(attempt)
		h.log().Warn("webhook_retry", "url", url, "attempt", attempt, "attempts", attempts, "err", err.Error(), "wait", wait)
		select {
		case <-ctx.Done():
			h.log().Error("webhook_failed", "url", url, "attempts", attempt, "err", ctx.Err().Error())
			return ctx.Err()
		case <-time.After(wait):
		}
	}
	return lastErr
}

// post performs one attempt. It returns the HTTP status (0 when the request
// never completed) plus an error for anything that is not a 2xx.
func (h *HTTP) post(ctx context.Context, e Event, attempt int) (int, error) {
	e.Attempt = attempt
	e.SentAt = h.now().UTC().Format(time.RFC3339)
	body, err := json.Marshal(e)
	if err != nil {
		return 0, fmt.Errorf("marshal webhook payload: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.URL, bytes.NewReader(body))
	if err != nil {
		// A malformed h.URL fails inside net/url before the request is ever built,
		// and that failure also comes back as a *url.Error embedding the FULL raw
		// URL, query string included, so unwrap and redact here too.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return 0, fmt.Errorf("build webhook request to %s: %w", RedactURL(h.URL), err)
	}
	req.Header.Set("Content-Type", "application/json")
	for _, hdr := range h.Headers {
		req.Header.Set(hdr.Key, hdr.Value)
	}
	if h.User != "" {
		req.SetBasicAuth(h.User, h.Pass)
	}
	h.log().Log(ctx, obslog.LevelTrace, "webhook_body", "url", RedactURL(h.URL), "body", string(body))
	resp, err := h.client().Do(req)
	if err != nil {
		// *url.Error embeds the FULL request URL, query string included, and this
		// message is logged. Trigger tokens live in that query string, so unwrap
		// it and name the target with the redacted URL instead.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return 0, fmt.Errorf("webhook post to %s: %w", RedactURL(h.URL), err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return resp.StatusCode, fmt.Errorf("webhook post: unexpected status %d", resp.StatusCode)
	}
	return resp.StatusCode, nil
}
