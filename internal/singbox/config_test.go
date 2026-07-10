package singbox

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/murongruolan/warp-pool/internal/config"
)

func TestBuildConfig(t *testing.T) {
	cfg := config.Default()
	cfg.Nodes = []config.Node{testNode()}

	sb, err := Build(cfg, Options{})
	if err != nil {
		t.Fatalf("build config: %v", err)
	}
	if len(sb.Inbounds) != 1 {
		t.Fatalf("expected one inbound, got %d", len(sb.Inbounds))
	}
	inbound := sb.Inbounds[0]
	if inbound.Type != "mixed" || inbound.Listen != "127.0.0.1" || inbound.ListenPort != 10121 {
		t.Fatalf("unexpected inbound: %#v", inbound)
	}
	if len(sb.Endpoints) != 1 {
		t.Fatalf("expected one endpoint, got %d", len(sb.Endpoints))
	}
	endpoint := sb.Endpoints[0]
	if endpoint.Type != "wireguard" || !strings.HasPrefix(endpoint.Tag, "wg-nat1-") {
		t.Fatalf("unexpected endpoint: %#v", endpoint)
	}
	if endpoint.Peers[0].Address != "203.0.113.1" || endpoint.Peers[0].Port != 51821 {
		t.Fatalf("unexpected peer: %#v", endpoint.Peers[0])
	}
	if endpoint.Peers[0].AllowedIPs[0] != "0.0.0.0/0" {
		t.Fatalf("unexpected allowed ips: %#v", endpoint.Peers[0].AllowedIPs)
	}
	if !strings.HasPrefix(sb.Route.Rules[0].Inbound[0], "in-nat1-") || sb.Route.Rules[0].Outbound != endpoint.Tag {
		t.Fatalf("unexpected route rule: %#v", sb.Route.Rules[0])
	}
	if sb.Route.AutoDetectInterface {
		t.Fatal("auto_detect_interface should stay disabled so kernel policy routing can be used")
	}
}

func TestBuildMapsSocks5Inbound(t *testing.T) {
	cfg := config.Default()
	node := testNode()
	node.Proxy = config.ProxySocks5
	cfg.Nodes = []config.Node{node}

	sb, err := Build(cfg, Options{})
	if err != nil {
		t.Fatalf("build config: %v", err)
	}
	if sb.Inbounds[0].Type != "socks" {
		t.Fatalf("expected socks inbound, got %s", sb.Inbounds[0].Type)
	}
}

func TestBuildUsesLocalEndpointNameFallback(t *testing.T) {
	cfg := config.Default()
	node := testNode()
	node.WGLocalDevice = ""
	node.WGDevice = "wpremote"
	cfg.Nodes = []config.Node{node}

	sb, err := Build(cfg, Options{})
	if err != nil {
		t.Fatalf("build config: %v", err)
	}
	if !strings.HasPrefix(sb.Endpoints[0].Name, "wpc-nat1-") {
		t.Fatalf("unexpected endpoint name: %s", sb.Endpoints[0].Name)
	}
}

func TestBuildDualConfigCreatesTwoInboundsAndEndpoints(t *testing.T) {
	cfg := config.Default()
	node := testNode()
	node.ExitMode = config.ExitModeDual
	node.WarpLocalPort = 10122
	node.WGWarpClientAddress = "10.200.0.3/32"
	node.WGWarpClientPrivateKey = "warp-client-private-key"
	cfg.Nodes = []config.Node{node}

	sb, err := Build(cfg, Options{})
	if err != nil {
		t.Fatalf("build dual config: %v", err)
	}
	if len(sb.Inbounds) != 2 || len(sb.Endpoints) != 2 || len(sb.Route.Rules) != 2 {
		t.Fatalf("expected two inbounds/endpoints/rules, got %d/%d/%d", len(sb.Inbounds), len(sb.Endpoints), len(sb.Route.Rules))
	}
	if sb.Inbounds[0].ListenPort != 10121 || sb.Inbounds[1].ListenPort != 10122 {
		t.Fatalf("unexpected dual listen ports: %#v", sb.Inbounds)
	}
	if sb.Endpoints[0].Address[0] != "10.200.0.2/30" || sb.Endpoints[1].Address[0] != "10.200.0.3/32" {
		t.Fatalf("unexpected dual endpoint addresses: %#v", sb.Endpoints)
	}
}

func TestBuildIPv6WireGuardEndpoint(t *testing.T) {
	cfg := config.Default()
	node := testNode()
	node.Endpoint = "[2001:db8::10]:51821"
	node.WGClientIPv6Address = "fd7a:7761:7270::2/126"
	cfg.Nodes = []config.Node{node}

	sb, err := Build(cfg, Options{})
	if err != nil {
		t.Fatalf("build config: %v", err)
	}
	endpoint := sb.Endpoints[0]
	if endpoint.Peers[0].Address != "2001:db8::10" || endpoint.Peers[0].Port != 51821 {
		t.Fatalf("unexpected ipv6 peer: %#v", endpoint.Peers[0])
	}
	if len(endpoint.Address) != 2 || endpoint.Address[1] != "fd7a:7761:7270::2/126" {
		t.Fatalf("unexpected endpoint addresses: %#v", endpoint.Address)
	}
	if len(endpoint.Peers[0].AllowedIPs) != 2 || endpoint.Peers[0].AllowedIPs[1] != "::/0" {
		t.Fatalf("unexpected allowed ips: %#v", endpoint.Peers[0].AllowedIPs)
	}
}

func TestInboundTag(t *testing.T) {
	if got := InboundTag("US1"); !strings.HasPrefix(got, "in-us1-") {
		t.Fatalf("unexpected inbound tag: %s", got)
	}
}

func TestBuildAvoidsDuplicateTagsForNonASCIINameCollision(t *testing.T) {
	cfg := config.Default()
	a := testNode()
	a.Name = "美国1"
	a.LocalPort = 10121
	b := testNode()
	b.Name = "圣保罗1"
	b.LocalPort = 10122
	cfg.Nodes = []config.Node{a, b}

	sb, err := Build(cfg, Options{})
	if err != nil {
		t.Fatalf("build config: %v", err)
	}
	if sb.Inbounds[0].Tag == sb.Inbounds[1].Tag {
		t.Fatalf("duplicate inbound tags: %s", sb.Inbounds[0].Tag)
	}
	if sb.Endpoints[0].Tag == sb.Endpoints[1].Tag {
		t.Fatalf("duplicate endpoint tags: %s", sb.Endpoints[0].Tag)
	}
}

func TestBuildRejectsMissingWireGuardFields(t *testing.T) {
	cfg := config.Default()
	node := testNode()
	node.WGClientPrivateKey = ""
	cfg.Nodes = []config.Node{node}

	_, err := Build(cfg, Options{})
	if err == nil || !strings.Contains(err.Error(), "wg_client_private_key") {
		t.Fatalf("expected missing private key error, got %v", err)
	}
}

func TestBuildJSON(t *testing.T) {
	cfg := config.Default()
	cfg.Nodes = []config.Node{testNode()}

	data, err := BuildJSON(cfg, Options{})
	if err != nil {
		t.Fatalf("build json: %v", err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("invalid json: %v\n%s", err, data)
	}
	if _, ok := decoded["endpoints"]; !ok {
		t.Fatalf("expected endpoints in config:\n%s", data)
	}
}

func testNode() config.Node {
	return config.Node{
		Name:               "nat1",
		ExitMode:           config.ExitModeDirect,
		Proxy:              config.ProxyMixed,
		BindHost:           "127.0.0.1",
		LocalPort:          10121,
		WGClientAddress:    "10.200.0.2/30",
		WGClientPrivateKey: "client-private-key",
		WGServerPublicKey:  "server-public-key",
		WGLocalDevice:      "wpcnat1",
		Endpoint:           "203.0.113.1:51821",
	}
}
