package actuator

import "testing"

func TestParseRefs(t *testing.T) {
	cases := []struct {
		name      string
		list      string
		defaultNS string
		want      []Ref
	}{
		{"bare name uses default namespace", "cb-conn", "default",
			[]Ref{{Namespace: "default", Name: "cb-conn"}}},
		{"qualified entry keeps its own namespace", "payments/cb-conn", "default",
			[]Ref{{Namespace: "payments", Name: "cb-conn"}}},
		{"mixed list", "cb-conn,orders/cb-conn", "default",
			[]Ref{{Namespace: "default", Name: "cb-conn"}, {Namespace: "orders", Name: "cb-conn"}}},
		{"whitespace tolerated", " payments/api , orders/web ", "default",
			[]Ref{{Namespace: "payments", Name: "api"}, {Namespace: "orders", Name: "web"}}},
		{"empty entries dropped", "cb-conn,,", "default",
			[]Ref{{Namespace: "default", Name: "cb-conn"}}},
		{"duplicates deduped in order", "a/x,b/y,a/x", "default",
			[]Ref{{Namespace: "a", Name: "x"}, {Namespace: "b", Name: "y"}}},
		{"empty list is no refs", "", "default", nil},
		{"dotted name is a name, not a namespace", "app.config", "default",
			[]Ref{{Namespace: "default", Name: "app.config"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseRefs(tc.list, tc.defaultNS)
			if err != nil {
				t.Fatalf("ParseRefs(%q) error: %v", tc.list, err)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("ParseRefs(%q) = %v, want %v", tc.list, got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("ParseRefs(%q)[%d] = %v, want %v", tc.list, i, got[i], tc.want[i])
				}
			}
		})
	}
}

func TestParseRefsErrors(t *testing.T) {
	cases := []struct{ name, list, defaultNS string }{
		{"missing name", "payments/", "default"},
		{"missing namespace", "/cb-conn", "default"},
		{"too many separators", "a/b/c", "default"},
		{"bare name with no default namespace", "cb-conn", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := ParseRefs(tc.list, tc.defaultNS); err == nil {
				t.Fatalf("ParseRefs(%q, %q) = nil error, want an error", tc.list, tc.defaultNS)
			}
		})
	}
}

// TestUnpairedNamespaces covers the config error that is otherwise silent: a
// Deployment target in a namespace with no ConfigMap target rolls once, gets
// stamped, and is skipped on every later call, while the ConfigMap it reads is
// never patched (a pod only reads ConfigMaps in its own namespace).
func TestUnpairedNamespaces(t *testing.T) {
	cases := []struct {
		name        string
		configMaps  []Ref
		deployments []Ref
		want        []string
	}{
		{"fully paired", []Ref{{Namespace: "default", Name: "cb-conn"}, {Namespace: "app-b", Name: "cb-conn"}},
			[]Ref{{Namespace: "default", Name: "mock-app"}, {Namespace: "app-b", Name: "mock-app-b"}}, nil},
		{"deployment namespace has no configmap", []Ref{{Namespace: "default", Name: "cb-conn"}},
			[]Ref{{Namespace: "default", Name: "mock-app"}, {Namespace: "app-b", Name: "mock-app-b"}},
			[]string{"app-b"}},
		{"sorted and deduped", []Ref{{Namespace: "default", Name: "cb-conn"}},
			[]Ref{{Namespace: "zeta", Name: "a"}, {Namespace: "alpha", Name: "b"}, {Namespace: "zeta", Name: "c"}},
			[]string{"alpha", "zeta"}},
		{"no deployments", []Ref{{Namespace: "default", Name: "cb-conn"}}, nil, nil},
		{"no targets at all", nil, nil, nil},
		{"no configmaps: every deployment namespace is unpaired", nil,
			[]Ref{{Namespace: "default", Name: "mock-app"}}, []string{"default"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := UnpairedNamespaces(tc.configMaps, tc.deployments)
			if len(got) != len(tc.want) {
				t.Fatalf("UnpairedNamespaces = %v, want %v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("UnpairedNamespaces = %v, want %v", got, tc.want)
				}
			}
		})
	}
}

func TestRefString(t *testing.T) {
	if got := (Ref{Namespace: "payments", Name: "cb-conn"}).String(); got != "payments/cb-conn" {
		t.Fatalf("Ref.String() = %q, want payments/cb-conn", got)
	}
}

// TestParseRefsRequired covers the non-empty variant used for the connstring
// ConfigMap list, which can never be empty: with no ConfigMap to patch the
// actuation can never converge.
func TestParseRefsRequired(t *testing.T) {
	if _, err := ParseRefsRequired("", "default"); err == nil {
		t.Error("ParseRefsRequired(\"\") = nil error, want an error")
	}
	if _, err := ParseRefsRequired(" , ", "default"); err == nil {
		t.Error("ParseRefsRequired(\" , \") = nil error, want an error")
	}
	got, err := ParseRefsRequired("cb-conn,app-b/cb-conn", "default")
	if err != nil {
		t.Fatalf("ParseRefsRequired error: %v", err)
	}
	want := []Ref{{Namespace: "default", Name: "cb-conn"}, {Namespace: "app-b", Name: "cb-conn"}}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("ParseRefsRequired = %v, want %v", got, want)
	}
}
