package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeCertPEM generates a throwaway self-signed CA cert, writes it to a temp
// PEM file, and returns the path. No fixtures committed.
func writeCertPEM(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "test-ca"},
		NotBefore:             time.Unix(0, 0),
		NotAfter:              time.Unix(1<<31-1, 0),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "ca.pem")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := pem.Encode(f, &pem.Block{Type: "CERTIFICATE", Bytes: der}); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestBuildSecurityConfig(t *testing.T) {
	certPath := writeCertPEM(t)

	t.Run("neither", func(t *testing.T) {
		sec, err := buildSecurityConfig("", false)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if sec.TLSSkipVerify || sec.TLSRootCAs != nil {
			t.Fatalf("expected zero-value SecurityConfig, got %+v", sec)
		}
	})

	t.Run("skip-verify only", func(t *testing.T) {
		sec, err := buildSecurityConfig("", true)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !sec.TLSSkipVerify {
			t.Fatal("expected TLSSkipVerify true")
		}
		if sec.TLSRootCAs != nil {
			t.Fatal("expected nil TLSRootCAs")
		}
	})

	t.Run("cert only", func(t *testing.T) {
		sec, err := buildSecurityConfig(certPath, false)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if sec.TLSRootCAs == nil {
			t.Fatal("expected non-nil TLSRootCAs")
		}
		if sec.TLSSkipVerify {
			t.Fatal("expected TLSSkipVerify false")
		}
	})

	t.Run("both set -> skip-verify wins", func(t *testing.T) {
		sec, err := buildSecurityConfig(certPath, true)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !sec.TLSSkipVerify {
			t.Fatal("expected TLSSkipVerify true")
		}
		if sec.TLSRootCAs != nil {
			t.Fatal("expected cert ignored (nil TLSRootCAs) when skip-verify set")
		}
	})

	t.Run("missing file -> error", func(t *testing.T) {
		if _, err := buildSecurityConfig("/no/such/ca.pem", false); err == nil {
			t.Fatal("expected error for missing cert file")
		}
	})

	t.Run("empty/garbage PEM -> error", func(t *testing.T) {
		bad := filepath.Join(t.TempDir(), "bad.pem")
		if err := os.WriteFile(bad, []byte("not a pem"), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := buildSecurityConfig(bad, false); err == nil {
			t.Fatal("expected error for PEM with no certificates")
		}
	})
}
