package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testEvent() Event {
	return Event{
		Event:     "switch_required",
		Reason:    "critical service \"kv\" 3/3 endpoints unreachable",
		From:      Endpoint{Role: "primary", Conn: "couchbase://10.0.1.5", Label: "10.0.1.5"},
		To:        Endpoint{Role: "secondary", Conn: "couchbase://10.1.1.5", Label: "10.1.1.5", Status: "UP"},
		Actuators: []string{"webhook"},
	}
}

// fixedNow keeps sent_at deterministic in tests.
func fixedNow() time.Time { return time.Date(2026, 8, 19, 10, 31, 2, 0, time.UTC) }

func TestNotifyPostsSignedPayload(t *testing.T) {
	type capture struct {
		method, path, auth, token, ctype string
		body                             Event
	}
	var got capture
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got.method, got.path = r.Method, r.URL.Path
		got.ctype = r.Header.Get("Content-Type")
		got.token = r.Header.Get("PRIVATE-TOKEN")
		if u, p, ok := r.BasicAuth(); ok {
			got.auth = u + ":" + p
		}
		if err := json.NewDecoder(r.Body).Decode(&got.body); err != nil {
			t.Errorf("decode body: %v", err)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	h := &HTTP{
		URL: srv.URL + "/hook", User: "obs", Pass: "s3cret",
		Headers: []Header{{Key: "PRIVATE-TOKEN", Value: "glpat-xyz"}},
		Client:  srv.Client(), Now: fixedNow,
	}
	if err := h.Notify(context.Background(), testEvent()); err != nil {
		t.Fatalf("Notify: %v", err)
	}
	if got.method != http.MethodPost || got.path != "/hook" {
		t.Errorf("request = %s %s, want POST /hook", got.method, got.path)
	}
	if got.ctype != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got.ctype)
	}
	if got.auth != "obs:s3cret" {
		t.Errorf("basic auth = %q, want obs:s3cret", got.auth)
	}
	if got.token != "glpat-xyz" {
		t.Errorf("PRIVATE-TOKEN = %q, want glpat-xyz", got.token)
	}
	if got.body.Attempt != 1 {
		t.Errorf("attempt = %d, want 1", got.body.Attempt)
	}
	if got.body.SentAt != "2026-08-19T10:31:02Z" {
		t.Errorf("sent_at = %q, want the injected clock value", got.body.SentAt)
	}
	if got.body.To.Conn != "couchbase://10.1.1.5" {
		t.Errorf("to.conn = %q, want the secondary connstring", got.body.To.Conn)
	}
}

func TestNotifyNoAuthWhenUserEmpty(t *testing.T) {
	sawAuth := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _, sawAuth = r.BasicAuth()
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	h := &HTTP{URL: srv.URL, Client: srv.Client(), Now: fixedNow}
	if err := h.Notify(context.Background(), testEvent()); err != nil {
		t.Fatalf("Notify: %v", err)
	}
	if sawAuth {
		t.Error("request carried basic auth even though no user was configured")
	}
}

// noBackoff keeps retry tests instant.
func noBackoff(int) time.Duration { return 0 }

func TestNotifyRetryClasses(t *testing.T) {
	cases := []struct {
		name         string
		statuses     []int // status returned per attempt
		wantAttempts int
		wantErr      bool
	}{
		{"500 then 204 succeeds on the retry", []int{500, 204}, 2, false},
		{"429 is retried", []int{429, 200}, 2, false},
		{"persistent 502 exhausts the attempts", []int{502, 502, 502}, 3, true},
		{"401 is not retried", []int{401}, 1, true},
		{"404 is not retried", []int{404}, 1, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			attempts := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body Event
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Errorf("decode body: %v", err)
				}
				if body.Attempt != attempts+1 {
					t.Errorf("payload attempt = %d on request %d, want them to match", body.Attempt, attempts+1)
				}
				status := tc.statuses[min(attempts, len(tc.statuses)-1)]
				attempts++
				w.WriteHeader(status)
			}))
			defer srv.Close()

			h := &HTTP{URL: srv.URL, Client: srv.Client(), Retries: 2, Backoff: noBackoff, Now: fixedNow}
			err := h.Notify(context.Background(), testEvent())
			if tc.wantErr && err == nil {
				t.Error("Notify = nil error, want an error so the switch does not latch")
			}
			if !tc.wantErr && err != nil {
				t.Errorf("Notify: %v", err)
			}
			if attempts != tc.wantAttempts {
				t.Errorf("server saw %d attempts, want %d", attempts, tc.wantAttempts)
			}
		})
	}
}

func TestNotifyRetriesTransportError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := srv.URL
	srv.Close() // nothing is listening now: every attempt is a transport error

	h := &HTTP{URL: url, Retries: 1, Backoff: noBackoff, Now: fixedNow}
	if err := h.Notify(context.Background(), testEvent()); err == nil {
		t.Fatal("Notify against a closed server = nil error, want an error")
	}
}

// A transport failure returns a *url.Error whose Error() embeds the FULL request
// URL, query string included. The named use case posts to a GitLab trigger of the
// form .../trigger/pipeline?token=<TOKEN>, and a regional outage produces a
// transport failure every tick, so that token must never reach the log store nor
// the returned error.
func TestNotifyTransportErrorHidesQueryString(t *testing.T) {
	var buf bytes.Buffer
	h := &HTTP{
		URL:     "http://127.0.0.1:1/hook?token=SUPERSECRET123", // nothing listens on port 1
		Retries: 0, Backoff: noBackoff, Now: fixedNow,
		Log: slog.New(slog.NewTextHandler(&buf, nil)),
	}
	err := h.Notify(context.Background(), testEvent())
	if err == nil {
		t.Fatal("Notify against a dead port = nil error, want an error")
	}
	if strings.Contains(err.Error(), "SUPERSECRET123") {
		t.Errorf("returned error leaks the query-string token: %q", err.Error())
	}
	if strings.Contains(buf.String(), "SUPERSECRET123") {
		t.Errorf("log output leaks the query-string token: %q", buf.String())
	}
}

// A URL that fails to parse also returns a *url.Error whose Error() embeds the
// FULL raw URL, query string included (net/url wraps the parse failure before
// http.NewRequestWithContext ever sees it). A control byte in the URL is enough
// to make parsing fail while leaving the query string, and any secret token in
// it, fully intact in the error text.
func TestNotifyMalformedURLHidesQueryString(t *testing.T) {
	var buf bytes.Buffer
	h := &HTTP{
		URL:     "http://127.0.0.1:1/hook?token=SUPERSECRET456\x7f", // \x7f: invalid control character
		Retries: 0, Backoff: noBackoff, Now: fixedNow,
		Log: slog.New(slog.NewTextHandler(&buf, nil)),
	}
	err := h.Notify(context.Background(), testEvent())
	if err == nil {
		t.Fatal("Notify with a malformed URL = nil error, want an error")
	}
	if strings.Contains(err.Error(), "SUPERSECRET456") {
		t.Errorf("returned error leaks the query-string token: %q", err.Error())
	}
	if strings.Contains(buf.String(), "SUPERSECRET456") {
		t.Errorf("log output leaks the query-string token: %q", buf.String())
	}
}

func TestNotifyDryRunSendsNothing(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	h := &HTTP{URL: srv.URL, Client: srv.Client(), DryRun: true, Now: fixedNow}
	if err := h.Notify(context.Background(), testEvent()); err != nil {
		t.Fatalf("dry-run Notify = %v, want nil so the switch still latches", err)
	}
	if called {
		t.Error("dry run issued a real request; it would have fired the customer pipeline")
	}
}

func TestNotifyNegativeRetriesStillMakesOneAttempt(t *testing.T) {
	attempts := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	h := &HTTP{URL: srv.URL, Client: srv.Client(), Retries: -1, Backoff: noBackoff, Now: fixedNow}
	if err := h.Notify(context.Background(), testEvent()); err != nil {
		t.Fatalf("Notify: %v", err)
	}
	if attempts != 1 {
		t.Errorf("server saw %d attempts, want exactly 1", attempts)
	}

	closedURL := srv.URL
	srv.Close() // nothing is listening now: the single attempt is a transport error

	hClosed := &HTTP{URL: closedURL, Retries: -1, Backoff: noBackoff, Now: fixedNow}
	if err := hClosed.Notify(context.Background(), testEvent()); err == nil {
		t.Error("Notify against a closed server with Retries: -1 = nil error, want an error so the switch does not latch")
	}
}
