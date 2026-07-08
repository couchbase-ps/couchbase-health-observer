package main

import (
	"crypto/x509"
	"fmt"
	"log"
	"os"

	"github.com/couchbase/gocb/v2"
)

// buildSecurityConfig turns the two TLS flags into a gocb.SecurityConfig for
// couchbases:// connections. If both are set, skip-verify wins and the cert is
// ignored (with a warning). Returns an error if certPath is set but unreadable
// or contains no certificates, so startup fails fast rather than silently
// falling back to the system trust store.
func buildSecurityConfig(certPath string, skipVerify bool) (gocb.SecurityConfig, error) {
	if skipVerify {
		if certPath != "" {
			log.Printf("warning: --tls-skip-verify set; ignoring --tls-cert-path=%q", certPath)
		}
		return gocb.SecurityConfig{TLSSkipVerify: true}, nil
	}
	if certPath == "" {
		return gocb.SecurityConfig{}, nil
	}
	pemBytes, err := os.ReadFile(certPath)
	if err != nil {
		return gocb.SecurityConfig{}, fmt.Errorf("read tls cert %q: %w", certPath, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pemBytes) {
		return gocb.SecurityConfig{}, fmt.Errorf("tls cert %q: no certificates found in PEM", certPath)
	}
	return gocb.SecurityConfig{TLSRootCAs: pool}, nil
}
