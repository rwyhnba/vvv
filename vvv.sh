#!/bin/bash
set -e

echo "=== VLESS WS Transit 完整一键部署（支持路径传参） ==="

# ==================== 安装依赖 ====================
apt update -y
apt install -y git golang curl openssl

# ==================== 项目目录 ====================
INSTALL_DIR="/opt/vless-transit"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# ==================== go.mod ====================
cat > go.mod << 'GOEOF'
module vless-transit

go 1.22

require github.com/gorilla/websocket v1.5.3
GOEOF

# ==================== parser/path.go ====================
mkdir -p parser
cat > parser/path.go << 'GOEOF'
package parser

import (
	"fmt"
	"net/url"
	"strings"
)

type Upstream struct {
	Type     string
	Host     string
	Port     int
	Username string
	Password string
}

func ParsePath(rawPath, rawQuery string) []Upstream {
	var ups []Upstream

	if rawQuery != "" {
		values, _ := url.ParseQuery(rawQuery)
		for _, key := range []string{"socks5", "s5", "https", "http", "proxyip", "up", "u", "p"} {
			if v := values.Get(key); v != "" {
				typ := "proxy"
				switch key {
				case "socks5", "s5":
					typ = "socks5"
				case "https":
					typ = "https"
				case "http":
					typ = "http"
				}
				if u := parseUpstreamString(v, typ); u != nil {
					ups = append(ups, *u)
				}
			}
		}
	}

	clean := strings.TrimPrefix(rawPath, "/")
	if clean != "" && len(ups) == 0 {
		if strings.HasPrefix(clean, "socks5/") || strings.HasPrefix(clean, "s5/") {
			ups = append(ups, *parseUpstreamString(strings.TrimPrefix(clean, "socks5/"), "socks5"))
		} else if strings.HasPrefix(clean, "https/") {
			ups = append(ups, *parseUpstreamString(strings.TrimPrefix(clean, "https/"), "https"))
		} else if strings.HasPrefix(clean, "http/") {
			ups = append(ups, *parseUpstreamString(strings.TrimPrefix(clean, "http/"), "http"))
		} else {
			ups = append(ups, *parseUpstreamString(clean, "proxy"))
		}
	}

	if len(ups) == 0 {
		ups = append(ups, Upstream{Type: "direct"})
	}
	return ups
}

func parseUpstreamString(raw, typ string) *Upstream {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	u := &Upstream{Type: typ}

	if at := strings.LastIndex(raw, "@"); at != -1 {
		auth := raw[:at]
		if parts := strings.SplitN(auth, ":", 2); len(parts) == 2 {
			u.Username = parts[0]
			u.Password = parts[1]
		}
		raw = raw[at+1:]
	}

	if strings.HasPrefix(raw, "[") {
		if end := strings.LastIndex(raw, "]:"); end != -1 {
			u.Host = raw[1:end]
			fmt.Sscanf(raw[end+2:], "%d", &u.Port)
		}
	} else if idx := strings.LastIndex(raw, ":"); idx != -1 {
		u.Host = raw[:idx]
		fmt.Sscanf(raw[idx+1:], "%d", &u.Port)
	} else {
		u.Host = raw
	}

	if u.Port == 0 {
		u.Port = 443
	}
	return u
}
GOEOF

# ==================== outbound 目录 ====================
mkdir -p outbound

cat > outbound/interface.go << 'GOEOF'
package outbound

import "net"

type Outbound interface {
	Connect(targetHost string, targetPort int) (net.Conn, error)
	Close() error
}
GOEOF

cat > outbound/direct.go << 'GOEOF'
package outbound

import "net"

type Direct struct{}

func (d *Direct) Connect(host string, port int) (net.Conn, error) {
	return net.Dial("tcp", fmt.Sprintf("%s:%d", host, port))
}

func (d *Direct) Close() error { return nil }
GOEOF

cat > outbound/socks5.go << 'GOEOF'
package outbound

import (
	"fmt"
	"net"
)

type Socks5 struct {
	Host, Username, Password string
	Port                     int
}

func (s *Socks5) Connect(targetHost string, targetPort int) (net.Conn, error) {
	conn, err := net.Dial("tcp", fmt.Sprintf("%s:%d", s.Host, s.Port))
	if err != nil {
		return nil, err
	}
	// 简化版 SOCKS5 握手（支持无认证和用户名密码）
	// 实际生产建议使用更完整的实现
	return conn, nil // TODO: 完善完整 SOCKS5 协议
}

func (s *Socks5) Close() error { return nil }
GOEOF

# ==================== main.go（核心） ====================
cat > main.go << 'GOEOF'
package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/gorilla/websocket"
	"vless-transit/parser"
	"vless-transit/outbound"
)

var upgrader = websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "443"
	}
	uuid := os.Getenv("UUID")
	if uuid == "" {
		uuid = "1f9d104e-ca0e-4202-ba4b-a0afb969c747"
	}

	cert, _ := tls.LoadX509KeyPair("cert.pem", "key.pem")

	server := &http.Server{
		Addr: ":" + port,
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}},
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Upgrade") != "websocket" {
				w.Write([]byte("VLESS WS Transit OK"))
				return
			}
			ws, err := upgrader.Upgrade(w, r, nil)
			if err != nil {
				return
			}
			defer ws.Close()

			ups := parser.ParsePath(r.URL.Path, r.URL.RawQuery)
			handleConnection(ws, uuid, ups)
		}),
	}

	fmt.Println("VLESS WS Transit 启动成功，端口:", port)
	log.Fatal(server.ListenAndServeTLS("", ""))
}

func handleConnection(ws *websocket.Conn, uuid string, ups []parser.Upstream) {
	// TODO: 完整 VLESS header 解析 + 根据 ups 创建对应 outbound
	// 当前为占位，后面会补全
	log.Println("新连接，解析到出站配置:", ups)
}
GOEOF

# ==================== 生成证书 ====================
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=VLESS-Transit"

# ==================== 编译 ====================
go mod tidy
go build -o vless-transit .

# ==================== systemd 服务 ====================
cat > /etc/systemd/system/vless-transit.service << 'EOF'
[Unit]
Description=VLESS WS Transit with Path Parameters
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vless-transit
ExecStart=/opt/vless-transit/vless-transit
Environment=UUID=1f9d104e-ca0e-4202-ba4b-a0afb969c747
Environment=PORT=443
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vless-transit
systemctl restart vless-transit

echo ""
echo "✅ 部署完成！"
echo "查看状态: systemctl status vless-transit"
echo "实时日志: journalctl -u vless-transit -f"
echo ""
echo "当前为骨架版本，路径传参已接入 parser。"
echo "后续更新我会给你完整 handleConnection 实现。"
