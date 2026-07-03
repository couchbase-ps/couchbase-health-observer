package main

import "testing"

func TestRegionLabel(t *testing.T) {
	cases := map[string]string{
		"couchbase://region-a-srv.region-a.svc":  "region-a",
		"couchbases://region-b-srv.region-b.svc": "region-b",
		"":                                       "none",
	}
	for in, want := range cases {
		if got := regionLabel(in); got != want {
			t.Errorf("regionLabel(%q) = %q, want %q", in, got, want)
		}
	}
}
