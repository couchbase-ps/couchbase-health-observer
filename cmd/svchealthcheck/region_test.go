package main

import "testing"

func TestRegionLabel(t *testing.T) {
	cases := map[string]string{
		"couchbase://region-a-srv.region-a.svc":  "region-a",
		"couchbases://region-b-srv.region-b.svc": "region-b",
		"":                                       "none",
		// Emirates uses IPv4 connstrings: keep the address, don't truncate to "10".
		"couchbase://10.0.1.5":          "10.0.1.5",
		"couchbase://10.0.1.5:11210":    "10.0.1.5",
		"couchbases://10.0.1.5:11207":   "10.0.1.5",
		"couchbase://10.0.1.5,10.0.1.6": "10.0.1.5",
	}
	for in, want := range cases {
		if got := regionLabel(in); got != want {
			t.Errorf("regionLabel(%q) = %q, want %q", in, got, want)
		}
	}
}
