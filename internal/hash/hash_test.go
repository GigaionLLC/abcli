package hash

import "testing"

func TestRaw(t *testing.T) {
	// SHA-256 of the empty input (known answer).
	if got := Raw(nil); got != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
		t.Errorf("Raw(nil) = %s", got)
	}
	if Raw([]byte("a")) == Raw([]byte("b")) {
		t.Error("distinct inputs hashed to the same value")
	}
	// Deterministic: the same input hashes identically across separate calls.
	first, second := Raw([]byte("determinism")), Raw([]byte("determinism"))
	if first != second {
		t.Error("hash is not deterministic")
	}
}
