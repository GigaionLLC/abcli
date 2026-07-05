package ab

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"math/big"
	"testing"
	"time"
)

func TestSignES256_Verifies(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte("eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0")
	sigB64, err := signES256(key, msg)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := base64.RawURLEncoding.DecodeString(sigB64)
	if err != nil {
		t.Fatalf("signature not base64url: %v", err)
	}
	if len(raw) != 64 {
		t.Fatalf("ES256 sig length = %d, want 64 (raw R||S)", len(raw))
	}
	r := new(big.Int).SetBytes(raw[:32])
	s := new(big.Int).SetBytes(raw[32:])
	sum := sha256.Sum256(msg)
	if !ecdsa.Verify(&key.PublicKey, sum[:], r, s) {
		t.Error("signature did not verify against the public key")
	}
}

func TestBackoff(t *testing.T) {
	if got := backoff("2", 0); got != 2*time.Second {
		t.Errorf("Retry-After honored: got %v, want 2s", got)
	}
	if got := backoff("", 3); got != 8*time.Second {
		t.Errorf("exponential: got %v, want 8s", got)
	}
	if got := backoff("", 20); got != 30*time.Second {
		t.Errorf("cap: got %v, want 30s", got)
	}
}
