package singbox

import (
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"net/netip"
	"strings"

	"github.com/murongruolan/warp-pool/internal/config"
)

type Config struct {
	Log       Log        `json:"log,omitempty"`
	Inbounds  []Inbound  `json:"inbounds"`
	Outbounds []Outbound `json:"outbounds"`
	Endpoints []Endpoint `json:"endpoints,omitempty"`
	Route     Route      `json:"route"`
}

type Log struct {
	Level string `json:"level,omitempty"`
}

type Inbound struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Listen     string `json:"listen"`
	ListenPort int    `json:"listen_port"`
}

type Outbound struct {
	Type string `json:"type"`
	Tag  string `json:"tag"`
}

type Endpoint struct {
	Type           string         `json:"type"`
	Tag            string         `json:"tag"`
	System         bool           `json:"system"`
	Name           string         `json:"name"`
	MTU            int            `json:"mtu,omitempty"`
	Address        []string       `json:"address"`
	PrivateKey     string         `json:"private_key"`
	Peers          []EndpointPeer `json:"peers"`
	DomainStrategy string         `json:"domain_strategy,omitempty"`
}

type EndpointPeer struct {
	Address             string   `json:"address"`
	Port                int      `json:"port"`
	PublicKey           string   `json:"public_key"`
	AllowedIPs          []string `json:"allowed_ips"`
	PersistentKeepalive int      `json:"persistent_keepalive_interval,omitempty"`
}

type Route struct {
	Rules               []RouteRule `json:"rules"`
	AutoDetectInterface bool        `json:"auto_detect_interface,omitempty"`
}

type RouteRule struct {
	Inbound  []string `json:"inbound,omitempty"`
	Outbound string   `json:"outbound"`
}

type Options struct {
	LogLevel string
	MTU      int
}

func Build(cfg config.Config, opts Options) (Config, error) {
	if opts.LogLevel == "" {
		opts.LogLevel = "info"
	}
	if opts.MTU == 0 {
		opts.MTU = 1420
	}

	out := Config{
		Log: Log{Level: opts.LogLevel},
		Outbounds: []Outbound{
			{Type: "direct", Tag: "direct"},
			{Type: "block", Tag: "block"},
		},
		// Let the kernel routing table choose the path. This is important when
		// IPv6 reachability is provided by a separate tunnel on the main server.
		Route: Route{},
	}

	for _, node := range cfg.Nodes {
		inbounds, endpoints, rules, err := buildNode(node, opts)
		if err != nil {
			return Config{}, err
		}
		out.Inbounds = append(out.Inbounds, inbounds...)
		out.Endpoints = append(out.Endpoints, endpoints...)
		out.Route.Rules = append(out.Route.Rules, rules...)
	}

	if len(out.Inbounds) == 0 {
		return Config{}, fmt.Errorf("no nodes configured")
	}
	return out, nil
}

func Marshal(cfg Config) ([]byte, error) {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

func BuildJSON(cfg config.Config, opts Options) ([]byte, error) {
	sb, err := Build(cfg, opts)
	if err != nil {
		return nil, err
	}
	return Marshal(sb)
}

func InboundTag(nodeName string) string {
	return "in-" + stableTagComponent(nodeName, 48)
}

func WarpInboundTag(nodeName string) string {
	return "in-warp-" + stableTagComponent(nodeName, 43)
}

func buildNode(node config.Node, opts Options) ([]Inbound, []Endpoint, []RouteRule, error) {
	if err := validateNode(node); err != nil {
		return nil, nil, nil, err
	}

	directInbound, directEndpoint, directRule, err := buildNodeVariant(nodeVariant{
		Node:          node,
		InboundTag:    InboundTag(node.Name),
		EndpointTag:   "wg-" + stableTagComponent(node.Name, 48),
		ListenPort:    node.LocalPort,
		ClientAddress: node.WGClientAddress,
		PrivateKey:    node.WGClientPrivateKey,
		EndpointName:  DefaultEndpointName(node),
	}, opts)
	if err != nil {
		return nil, nil, nil, err
	}
	inbounds := []Inbound{directInbound}
	endpoints := []Endpoint{directEndpoint}
	rules := []RouteRule{directRule}
	if node.ExitMode == config.ExitModeDual {
		warpInbound, warpEndpoint, warpRule, err := buildNodeVariant(nodeVariant{
			Node:          node,
			InboundTag:    WarpInboundTag(node.Name),
			EndpointTag:   "wg-warp-" + stableTagComponent(node.Name, 43),
			ListenPort:    node.WarpLocalPort,
			ClientAddress: node.WGWarpClientAddress,
			PrivateKey:    node.WGWarpClientPrivateKey,
			EndpointName:  DefaultWarpEndpointName(node),
		}, opts)
		if err != nil {
			return nil, nil, nil, err
		}
		inbounds = append(inbounds, warpInbound)
		endpoints = append(endpoints, warpEndpoint)
		rules = append(rules, warpRule)
	}
	return inbounds, endpoints, rules, nil
}

type nodeVariant struct {
	Node          config.Node
	InboundTag    string
	EndpointTag   string
	ListenPort    int
	ClientAddress string
	PrivateKey    string
	EndpointName  string
}

func buildNodeVariant(variant nodeVariant, opts Options) (Inbound, Endpoint, RouteRule, error) {
	node := variant.Node
	inboundType := node.Proxy
	if inboundType == config.ProxySocks5 {
		inboundType = "socks"
	}

	host, port, err := splitEndpoint(node.Endpoint)
	if err != nil {
		return Inbound{}, Endpoint{}, RouteRule{}, fmt.Errorf("node %s endpoint: %w", node.Name, err)
	}

	inbound := Inbound{
		Type:       inboundType,
		Tag:        variant.InboundTag,
		Listen:     node.BindHost,
		ListenPort: variant.ListenPort,
	}
	addresses := wireGuardEndpointAddresses(variant.ClientAddress, node)
	allowedIPs := []string{"0.0.0.0/0"}
	if hasIPv6Address(addresses) {
		allowedIPs = append(allowedIPs, "::/0")
	}

	endpoint := Endpoint{
		Type:       "wireguard",
		Tag:        variant.EndpointTag,
		System:     false,
		Name:       variant.EndpointName,
		MTU:        opts.MTU,
		Address:    addresses,
		PrivateKey: variant.PrivateKey,
		Peers: []EndpointPeer{
			{
				Address:             host,
				Port:                port,
				PublicKey:           node.WGServerPublicKey,
				AllowedIPs:          allowedIPs,
				PersistentKeepalive: 25,
			},
		},
	}
	rule := RouteRule{
		Inbound:  []string{variant.InboundTag},
		Outbound: variant.EndpointTag,
	}
	return inbound, endpoint, rule, nil
}

func wireGuardEndpointAddresses(clientAddress string, node config.Node) []string {
	addresses := []string{clientAddress}
	switch clientAddress {
	case node.WGWarpClientAddress:
		if strings.TrimSpace(node.WGWarpClientIPv6Address) != "" {
			addresses = append(addresses, node.WGWarpClientIPv6Address)
		}
	default:
		if strings.TrimSpace(node.WGClientIPv6Address) != "" {
			addresses = append(addresses, node.WGClientIPv6Address)
		}
	}
	return addresses
}

func hasIPv6Address(addresses []string) bool {
	for _, address := range addresses {
		if strings.Contains(strings.Split(address, "/")[0], ":") {
			return true
		}
	}
	return false
}

func validateNode(node config.Node) error {
	if node.Name == "" {
		return fmt.Errorf("node name cannot be empty")
	}
	if err := config.ValidateProxy(node.Proxy); err != nil {
		return fmt.Errorf("node %s: %w", node.Name, err)
	}
	if err := config.ValidateBindHost(node.BindHost); err != nil {
		return fmt.Errorf("node %s: %w", node.Name, err)
	}
	if err := config.ValidatePort(node.LocalPort); err != nil {
		return fmt.Errorf("node %s: %w", node.Name, err)
	}
	for _, field := range []struct {
		name  string
		value string
	}{
		{name: "wg_client_address", value: node.WGClientAddress},
		{name: "wg_client_private_key", value: node.WGClientPrivateKey},
		{name: "wg_server_public_key", value: node.WGServerPublicKey},
		{name: "endpoint", value: node.Endpoint},
	} {
		if strings.TrimSpace(field.value) == "" {
			return fmt.Errorf("node %s missing %s; deploy it first", node.Name, field.name)
		}
	}
	if node.ExitMode == config.ExitModeDual {
		if err := config.ValidatePort(node.WarpLocalPort); err != nil {
			return fmt.Errorf("node %s warp local port: %w", node.Name, err)
		}
		if node.WarpLocalPort == node.LocalPort {
			return fmt.Errorf("node %s dual mode requires different direct and warp local ports", node.Name)
		}
		for _, field := range []struct {
			name  string
			value string
		}{
			{name: "wg_warp_client_address", value: node.WGWarpClientAddress},
			{name: "wg_warp_client_private_key", value: node.WGWarpClientPrivateKey},
		} {
			if strings.TrimSpace(field.value) == "" {
				return fmt.Errorf("node %s missing %s; deploy it as dual first", node.Name, field.name)
			}
		}
		if strings.TrimSpace(node.WGClientIPv6Address) != "" && strings.TrimSpace(node.WGWarpClientIPv6Address) == "" {
			return fmt.Errorf("node %s missing wg_warp_client_ipv6_address; redeploy it as dual first", node.Name)
		}
	}
	return nil
}

func splitEndpoint(endpoint string) (string, int, error) {
	parts := strings.LastIndex(endpoint, ":")
	if parts < 0 {
		return "", 0, fmt.Errorf("expected host:port, got %s", endpoint)
	}
	host := endpoint[:parts]
	portText := endpoint[parts+1:]
	port, err := netip.ParseAddrPort("127.0.0.1:" + portText)
	if err != nil {
		return "", 0, fmt.Errorf("invalid endpoint port %q", portText)
	}
	if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
		host = strings.TrimPrefix(strings.TrimSuffix(host, "]"), "[")
	}
	if strings.TrimSpace(host) == "" {
		return "", 0, fmt.Errorf("empty endpoint host")
	}
	return host, int(port.Port()), nil
}

func safeTag(name string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z':
			b.WriteRune(r)
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		return "node"
	}
	return out
}

func stableTagComponent(name string, maxLen int) string {
	base := safeTag(name)
	hash := shortNameHash(name)
	suffix := "-" + hash
	if maxLen <= len(hash) {
		return hash[:maxLen]
	}
	keep := maxLen - len(suffix)
	if keep > 0 && len(base) > keep {
		base = strings.Trim(base[:keep], "-")
	}
	if base == "" {
		return hash
	}
	return base + suffix
}

func shortNameHash(name string) string {
	sum := sha1.Sum([]byte(name))
	return fmt.Sprintf("%x", sum)[:6]
}

func DefaultEndpointName(node config.Node) string {
	if strings.TrimSpace(node.WGLocalDevice) != "" {
		return node.WGLocalDevice
	}
	return "wpc-" + stableTagComponent(node.Name, 11)
}

func DefaultWarpEndpointName(node config.Node) string {
	return "wpcw-" + stableTagComponent(node.Name, 10)
}
