// Package hash is the drift signal. Apple stores CUSTOM_SETTING XML byte-for-byte
// (verified live 2026-07-04: GET round-trip identical), so a raw SHA-256 is exact.
package hash

import (
	"crypto/sha256"
	"encoding/hex"
)

// Raw returns the hex-encoded SHA-256 of b — the exact drift signal for a
// byte-for-byte-stored profile.
func Raw(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}
