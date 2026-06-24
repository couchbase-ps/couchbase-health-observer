package eksauth

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestEncodeToken(t *testing.T) {
	url := "https://sts.amazonaws.com/?Action=GetCallerIdentity&X-Amz-Signature=abc"
	tok := encodeToken(url)

	if !strings.HasPrefix(tok, tokenPrefix) {
		t.Fatalf("token missing %q prefix: %q", tokenPrefix, tok)
	}
	// the encoding must be URL-safe and unpadded (k8s-aws-v1 requirement)
	if strings.ContainsAny(tok, "+/=") {
		t.Errorf("token must be base64url without padding: %q", tok)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(tok, tokenPrefix))
	if err != nil {
		t.Fatalf("token body not base64url: %v", err)
	}
	if string(decoded) != url {
		t.Errorf("round-trip mismatch: got %q want %q", decoded, url)
	}
}
