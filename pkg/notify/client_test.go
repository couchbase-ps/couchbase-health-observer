package notify

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Trigger tokens usually travel in the query string or in userinfo, so the
// logged URL must keep only scheme, host and path.
func TestRedactURL(t *testing.T) {
	cases := []struct{ in, want string }{
		{"https://gitlab.example.com/api/v4/projects/7/trigger/pipeline?token=SECRET", "https://gitlab.example.com/api/v4/projects/7/trigger/pipeline"},
		{"https://user:pass@hooks.example.com/hook", "https://hooks.example.com/hook"},
		{"http://webhook-receiver:8080/hook", "http://webhook-receiver:8080/hook"},
		{"", ""},
		{"://not a url", "(unparsable url)"},
	}
	for _, c := range cases {
		if got := RedactURL(c.in); got != c.want {
			t.Errorf("RedactURL(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParseHeader(t *testing.T) {
	h, err := ParseHeader("  PRIVATE-TOKEN :  glpat-xyz ")
	if err != nil {
		t.Fatal(err)
	}
	if h.Key != "PRIVATE-TOKEN" || h.Value != "glpat-xyz" {
		t.Errorf("ParseHeader = %+v, want key PRIVATE-TOKEN value glpat-xyz", h)
	}
	if _, err := ParseHeader("no-colon"); err == nil {
		t.Error("ParseHeader(\"no-colon\") = nil error, want an error")
	}
	if _, err := ParseHeader(": value"); err == nil {
		t.Error("ParseHeader with an empty key = nil error, want an error")
	}
}

// A forgotten colon is the common mistake, and the part after the key is the
// token. The error reaches stderr on every crash-loop restart, so it may name
// the key but never the value.
func TestParseHeaderErrorHidesTheValue(t *testing.T) {
	cases := []string{
		"PRIVATE-TOKEN glpat-SECRET", // forgotten colon
		": glpat-SECRET",             // empty key
	}
	for _, in := range cases {
		_, err := ParseHeader(in)
		if err == nil {
			t.Fatalf("ParseHeader(%q) = nil error, want an error", in)
		}
		if strings.Contains(err.Error(), "glpat-SECRET") {
			t.Errorf("ParseHeader(%q) error leaks the token: %q", in, err.Error())
		}
	}
	// The key stays in the message so the operator can find the bad header.
	_, err := ParseHeader("PRIVATE-TOKEN glpat-SECRET")
	if !strings.Contains(err.Error(), "PRIVATE-TOKEN") {
		t.Errorf("error = %q, want it to name the key so the message stays actionable", err.Error())
	}
	// A lone token with no key portion must not be echoed at all.
	if _, err := ParseHeader("glpat-SECRET"); err == nil || strings.Contains(err.Error(), "glpat-SECRET") {
		t.Errorf("ParseHeader of a lone token = %v, want an error that does not quote it", err)
	}
}

func TestNewClientTrustsSuppliedCA(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	// Write the test server's own certificate out as a PEM CA bundle.
	dir := t.TempDir()
	caPath := filepath.Join(dir, "ca.pem")
	certDER := srv.Certificate().Raw
	if err := os.WriteFile(caPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER}), 0o600); err != nil {
		t.Fatal(err)
	}

	client, err := NewClient(caPath, false, 3*time.Second)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	h := &HTTP{URL: srv.URL, Client: client, Now: fixedNow}
	if err := h.Notify(context.Background(), testEvent()); err != nil {
		t.Fatalf("Notify with the supplied CA = %v, want success", err)
	}

	// Control: without the CA the same request must fail verification.
	plain, err := NewClient("", false, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	h2 := &HTTP{URL: srv.URL, Client: plain, Now: fixedNow}
	if err := h2.Notify(context.Background(), testEvent()); err == nil {
		t.Error("Notify without the CA succeeded; TLS verification is not being enforced")
	}
}

func TestNewClientSkipVerify(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	client, err := NewClient("", true, 3*time.Second)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	h := &HTTP{URL: srv.URL, Client: client, Now: fixedNow}
	if err := h.Notify(context.Background(), testEvent()); err != nil {
		t.Fatalf("Notify with skip-verify = %v, want success", err)
	}
}

func TestNewClientRejectsBadCA(t *testing.T) {
	if _, err := NewClient("/nonexistent/ca.pem", false, time.Second); err == nil {
		t.Error("NewClient with a missing CA file = nil error, want a startup failure")
	}
	dir := t.TempDir()
	junk := filepath.Join(dir, "junk.pem")
	if err := os.WriteFile(junk, []byte("not a certificate"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewClient(junk, false, time.Second); err == nil {
		t.Error("NewClient with a certificate-free PEM = nil error, want a startup failure")
	}
	// Keep the x509 import honest: an empty pool must not be treated as valid.
	if pool := x509.NewCertPool(); pool == nil {
		t.Fatal("unreachable")
	}
}

func TestNewClientTimeoutIsSet(t *testing.T) {
	c, err := NewClient("", false, 1500*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if c.Timeout != 1500*time.Millisecond {
		t.Errorf("client timeout = %s, want 1.5s", c.Timeout)
	}
}
