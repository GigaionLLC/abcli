package cli

import (
	"testing"
	"time"
)

func TestParseSince(t *testing.T) {
	if d, err := parseSince("7d"); err != nil || d != 7*24*time.Hour {
		t.Errorf("7d → %v, %v", d, err)
	}
	if d, err := parseSince("24h"); err != nil || d != 24*time.Hour {
		t.Errorf("24h → %v, %v", d, err)
	}
	if _, err := parseSince("nonsense"); err == nil {
		t.Error("expected an error for a bad --since value")
	}
}

func TestExitError(t *testing.T) {
	if (ExitError{Code: 3}).Error() == "" {
		t.Error("ExitError.Error() should be non-empty")
	}
}
