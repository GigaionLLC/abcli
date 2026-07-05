// Package state is the committed sync baseline (gitops/state/sync-state.json) —
// the last-synced snapshot that makes the 3-way (git ↔ baseline ↔ ABM) diff possible.
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Entry is the last-synced state of one config.
type Entry struct {
	ABMID           string `json:"abm_id"`
	Hash            string `json:"hash"`
	UpdatedDateTime string `json:"updatedDateTime"`
}

// State maps config name → last-synced Entry.
type State struct {
	Configs map[string]Entry `json:"configs"`
}

// Load reads the committed baseline from path; a missing file yields an empty State.
func Load(path string) (*State, error) {
	s := &State{Configs: map[string]Entry{}}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, s); err != nil {
		return nil, err
	}
	if s.Configs == nil {
		s.Configs = map[string]Entry{}
	}
	return s, nil
}

// Save writes the baseline to path (creating parent dirs), pretty-printed.
func (s *State) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}
