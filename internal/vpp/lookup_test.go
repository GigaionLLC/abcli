package vpp

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLookupNames(t *testing.T) {
	var gotIDs string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotIDs = r.URL.Query().Get("id")
		_, _ = w.Write([]byte(`{"resultCount":2,"results":[
			{"trackId":409183694,"trackName":"Keynote"},
			{"trackId":361309726,"trackName":"Adobe Reader"}]}`))
	}))
	defer srv.Close()

	names, err := NewLookup(srv.URL).Names([]string{"409183694", "361309726", "999"})
	if err != nil {
		t.Fatal(err)
	}
	if gotIDs != "409183694,361309726,999" {
		t.Errorf("id param = %q", gotIDs)
	}
	if names["409183694"] != "Keynote" || names["361309726"] != "Adobe Reader" {
		t.Errorf("resolved names = %v", names)
	}
	if _, ok := names["999"]; ok {
		t.Errorf("unresolvable id should be absent, got %v", names["999"])
	}
}

func TestLookupBatches(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		_, _ = w.Write([]byte(`{"resultCount":0,"results":[]}`))
	}))
	defer srv.Close()

	ids := make([]string, 320) // > 2 batches of 150
	for i := range ids {
		ids[i] = "x"
	}
	if _, err := NewLookup(srv.URL).Names(ids); err != nil {
		t.Fatal(err)
	}
	if calls != 3 {
		t.Errorf("expected 3 batched calls for 320 ids, got %d", calls)
	}
}

func TestLookupErrorIsNonFatal(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	// A failed lookup returns the (empty) partial map + an error; callers ignore it.
	names, err := NewLookup(srv.URL).Names([]string{"1"})
	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("want a 500 error, got %v", err)
	}
	if len(names) != 0 {
		t.Errorf("want empty names, got %v", names)
	}
}
