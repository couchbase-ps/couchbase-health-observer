package notify

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Header is one extra request header, e.g. GitLab's PRIVATE-TOKEN.
type Header struct{ Key, Value string }

// ParseHeader turns a "Key: Value" flag value into a Header. The value may
// itself contain colons (a URL, for instance), so only the first one splits.
//
// The errors NEVER echo the input: the value is a credential (GitLab's
// PRIVATE-TOKEN, for one) and a rejected header crashes the process, so the
// message repeats on stderr for every crash-loop restart. Only the key portion
// is named, and only when the input clearly has one.
func ParseHeader(s string) (Header, error) {
	key, value, found := strings.Cut(s, ":")
	if !found {
		// A forgotten colon leaves "Key Value": name the first word, drop the rest.
		if fields := strings.Fields(s); len(fields) > 1 {
			return Header{}, fmt.Errorf("header %q is missing the \":\" separator; use \"Key: Value\"", fields[0])
		}
		return Header{}, errors.New("malformed header (value not shown): no \":\" separator; use \"Key: Value\"")
	}
	key = strings.TrimSpace(key)
	if key == "" {
		return Header{}, errors.New("malformed header (value not shown): empty key before the \":\"; use \"Key: Value\"")
	}
	return Header{Key: key, Value: strings.TrimSpace(value)}, nil
}

// RedactURL renders a URL for logs with scheme, host and path only. Userinfo and
// the query string are dropped because trigger tokens commonly live there.
func RedactURL(raw string) string {
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "(unparsable url)"
	}
	return u.Scheme + "://" + u.Host + u.Path
}

// NewClient builds the HTTP client used for webhook delivery. skipVerify wins
// over caPath (with the caller warning about it). A caPath that cannot be read,
// or holds no certificate, is an error so startup fails fast rather than quietly
// falling back to the system trust store. This mirrors buildSecurityConfig for
// the Couchbase connection.
func NewClient(caPath string, skipVerify bool, timeout time.Duration) (*http.Client, error) {
	tlsCfg := &tls.Config{MinVersion: tls.VersionTLS12}
	switch {
	case skipVerify:
		tlsCfg.InsecureSkipVerify = true
	case caPath != "":
		pemBytes, err := os.ReadFile(caPath)
		if err != nil {
			return nil, fmt.Errorf("read webhook ca cert %q: %w", caPath, err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pemBytes) {
			return nil, fmt.Errorf("webhook ca cert %q: no certificates found in PEM", caPath)
		}
		tlsCfg.RootCAs = pool
	}
	return &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{TLSClientConfig: tlsCfg},
	}, nil
}
