cat << 'EOF' > /tmp/install_vless.sh
#!/bin/bash
export LANG=en_US.UTF-8

G="\e[32m" && R="\e[31m" && Y="\e[33m" && P="\e[0m"

echo -e "${Y}====================================================${P}"
echo -e "       开始执行 VLESS 动态中转一键部署 (IBM Cloud)   "
echo -e "${Y}====================================================${P}"

# 1. 基础依赖安装
echo -e "${Y}[1/5] 正在更新系统源并安装基础构建依赖...${P}"
apt-get update -y && apt-get install -y wget curl tar git build-essential uuid-runtime

# 2. Go 编译器部署
echo -e "${Y}[2/5] 正在下载并配置 Go 1.22.5 编译环境...${P}"
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then GO_ARCH="amd64"; else GO_ARCH="arm64"; fi

wget -O /tmp/go.tar.gz https://go.dev/dl/go1.22.5.linux-${GO_ARCH}.tar.gz
if [ $? -ne 0 ]; then
    echo -e "${R}错误: 下载 Go 语言包失败，请检查 VPS 出站网络状况。${P}"
    exit 1
fi

rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz

export PATH=$PATH:/usr/local/go/bin
if ! grep -q "/usr/local/go/bin" /etc/profile; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
fi

echo -e "      Go 编译器就位: $(go version)"

# 3. 写入源码并执行静态编译
echo -e "${Y}[3/5] 正在写入核心 Go 源码并启动编译...${P}"
BUILD_DIR="/tmp/vless-relay-build"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

cat << 'GOEOF' > main.go
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/gorilla/websocket"
	"golang.org/x/net/proxy"
)

var (
	portFlag = flag.String("port", "8080", "Listen port")
	uuidFlag = flag.String("uuid", "1f9d104e-ca0e-4202-ba4b-a0afb969c747", "VLESS UUID")
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

type VlessHeader struct {
	Version  byte
	Command  byte
	Port     uint16
	AddrType byte
	Address  string
	Payload  []byte
}

func main() {
	flag.Parse()
	uuidBytes := uuidToBytes(*uuidFlag)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if strings.ToLower(r.Header.Get("Upgrade")) != "websocket" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("<h1>VLESS Relay Service is Running</h1>"))
			return
		}

		wsConn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("WS upgrade error: %v", err)
			return
		}
		defer wsConn.Close()

		dialer, err := selectOutboundDialer(r.URL)
		if err != nil {
			log.Printf("Outbound dialer error: %v", err)
			return
		}

		handleVlessSession(wsConn, uuidBytes, dialer)
	})

	log.Printf("VLESS 动态中转启动。监听端口: :%s, 目标 UUID: %s", *portFlag, *uuidFlag)
	if err := http.ListenAndServe(":"+*portFlag, nil); err != nil {
		log.Fatal(err)
	}
}

func selectOutboundDialer(u *url.URL) (proxy.Dialer, error) {
	path := strings.Trim(u.Path, "/")
	parts := strings.Split(path, "/")

	if len(parts) >= 2 {
		scheme := strings.ToLower(parts[0])
		targetProxy := normalizeDashPort(parts[1])

		switch scheme {
		case "socks5", "s5":
			return proxy.SOCKS5("tcp", targetProxy, nil, proxy.Direct)
		case "http", "https":
			return &HTTPConnectDialer{ProxyAddr: targetProxy, Secure: scheme == "https"}, nil
		}
	}

	if s5Query := u.Query().Get("socks5"); s5Query != "" {
		parsedProxy, err := url.Parse(s5Query)
		if err == nil {
			var auth *proxy.Auth
			if parsedProxy.User != nil {
				auth = &proxy.Auth{
					User:     parsedProxy.User.Username(),
					Password: "",
				}
				if p, ok := parsedProxy.User.Password(); ok {
					auth.Password = p
				}
			}
			return proxy.SOCKS5("tcp", parsedProxy.Host, auth, proxy.Direct)
		}
	}

	return proxy.Direct, nil
}

func handleVlessSession(ws *websocket.Conn, uuidBytes []byte, dialer proxy.Dialer) {
	_, firstMsg, err := ws.ReadMessage()
	if err != nil {
		return
	}

	header, err := parseVlessHeader(firstMsg, uuidBytes)
	if err != nil {
		log.Printf("Header error: %v", err)
		return
	}

	if header.Command != 1 {
		log.Println("Unsupported CMD: Only TCP relay is implemented.")
		return
	}

	targetAddr := net.JoinHostPort(header.Address, strconv.Itoa(int(header.Port)))
	remoteConn, err := dialer.Dial("tcp", targetAddr)
	if err != nil {
		log.Printf("Dial to %s failed: %v", targetAddr, err)
		return
	}
	defer remoteConn.Close()

	respHeader := []byte{header.Version, 0}
	wsWriter, err := ws.NextWriter(websocket.BinaryMessage)
	if err != nil {
		return
	}
	wsWriter.Write(respHeader)
	wsWriter.Close()

	if len(header.Payload) > 0 {
		if _, err := remoteConn.Write(header.Payload); err != nil {
			return
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := remoteConn.Read(buf)
			if n > 0 {
				errW := ws.WriteMessage(websocket.BinaryMessage, buf[:n])
				if errW != nil {
					cancel()
					return
				}
			}
			if err != nil {
				cancel()
				return
			}
		}
	}()

	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			default:
				_, msg, err := ws.ReadMessage()
				if err != nil {
					cancel()
					return
				}
				_, errW := remoteConn.Write(msg)
				if errW != nil {
					cancel()
					return
				}
			}
		}
	}()

	<-ctx.Done()
}

func parseVlessHeader(data []byte, uuidBytes []byte) (*VlessHeader, error) {
	if len(data) < 24 {
		return nil, errors.New("data packet is too short")
	}
	version := data[0]
	for i := 0; i < 16; i++ {
		if data[1+i] != uuidBytes[i] {
			return nil, errors.New("UUID verify failed")
		}
	}
	optLen := int(data[17])
	pos := 18 + optLen
	if pos+4 > len(data) {
		return nil, errors.New("incomplete header layout")
	}
	command := data[pos]
	pos++
	port := binary.BigEndian.Uint16(data[pos : pos+2])
	pos += 2
	addrType := data[pos]
	pos++

	var address string
	switch addrType {
	case 1:
		if pos+4 > len(data) {
			return nil, errors.New("invalid IPv4 length")
		}
		address = net.IP(data[pos : pos+4]).String()
		pos += 4
	case 2:
		if pos+1 > len(data) {
			return nil, errors.New("invalid domain length indicator")
		}
		domainLen := int(data[pos])
		pos++
		if pos+domainLen > len(data) {
			return nil, errors.New("domain buffer overflow")
		}
		address = string(data[pos : pos+domainLen])
		pos += domainLen
	case 3:
		if pos+16 > len(data) {
			return nil, errors.New("invalid IPv6 length")
		}
		address = net.IP(data[pos : pos+16]).String()
		pos += 16
	default:
		return nil, fmt.Errorf("unknown address type: %d", addrType)
	}

	return &VlessHeader{
		Version:  version,
		Command:  command,
		Port:     port,
		AddrType: addrType,
		Address:  address,
		Payload:  data[pos:],
	}, nil
}

type HTTPConnectDialer struct {
	ProxyAddr string
	Secure    bool
}

func (d *HTTPConnectDialer) Dial(network, address string) (net.Conn, error) {
	var conn net.Conn
	var err error
	if d.Secure {
		conn, err = tls.Dial("tcp", d.ProxyAddr, &tls.Config{InsecureSkipVerify: true})
	} else {
		conn, err = net.Dial("tcp", d.ProxyAddr)
	}
	if err != nil {
		return nil, err
	}

	req := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: Keep-Alive\r\n\r\n", address, address)
	if _, err := conn.Write([]byte(req)); err != nil {
		conn.Close()
		return nil, err
	}

	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, &http.Request{Method: "CONNECT"})
	if err != nil {
		conn.Close()
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		conn.Close()
		return nil, fmt.Errorf("HTTP CONNECT tunnel failed: %s", resp.Status)
	}

	if br.Buffered() > 0 {
		return &BufferedConn{Conn: conn, Reader: br}, nil
	}
	return conn, nil
}

type BufferedConn struct {
	net.Conn
	Reader *bufio.Reader
}

func (c *BufferedConn) Read(b []byte) (int, error) { return c.Reader.Read(b) }

func uuidToBytes(uuid string) []byte {
	hexStr := strings.ReplaceAll(uuid, "-", "")
	if len(hexStr) != 32 {
		return make([]byte, 16)
	}
	out := make([]byte, 16)
	for i := 0; i < 16; i++ {
		val, err := strconv.ParseUint(hexStr[i*2:i*2+2], 16, 8)
		if err != nil {
			return make([]byte, 16)
		}
		out[i] = byte(val)
	}
	return out
}

func normalizeDashPort(val string) string {
	if !strings.Contains(val, ":") {
		idx := strings.LastIndex(val, "-")
		if idx > 0 {
			return val[:idx] + ":" + val[idx+1:]
		}
	}
	return val
}
GOEOF

# 自动拉取依赖模块并执行生产级编译
go mod init vless-relay 2>/dev/null
go get github.com/gorilla/websocket@v1.5.3
go get golang.org/x/net@v0.27.0
go mod tidy
go build -ldflags="-s -w" -o vless-relay main.go

if [ ! -f "vless-relay" ]; then
    echo -e "${R}错误: 编译程序失败，无法生成二进制。${P}"
    exit 1
fi

mv vless-relay /usr/local/bin/vless-relay
chmod +x /usr/local/bin/vless-relay
cd / && rm -rf "$BUILD_DIR"
echo -e "${G}编译成功，二进制已移至 /usr/local/bin/vless-relay${P}"

# 4. 配置 Systemd 开机自启
echo -e "${Y}[4/5] 正在注册并启动守护进程...${P}"
LIST_PORT="8080"
INPUT_UUID="1f9d104e-ca0e-4202-ba4b-a0afb969c747"

cat << SYSEOF > /etc/systemd/system/vless-relay.service
[Unit]
Description=VLESS Relay Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/vless-relay -port=${LIST_PORT} -uuid=${INPUT_UUID}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SYSEOF

systemctl daemon-reload
systemctl enable vless-relay.service
systemctl restart vless-relay.service

# 5. 延迟 2 秒并执行自动化自检
sleep 2
echo -e "${Y}[5/5] 开始对新部署的服务进行自动化健康审计...${P}"
echo -e "${Y}====================================================${P}"

STATUS=$(systemctl is-active vless-relay.service 2>/dev/null)
if [ "$STATUS" = "active" ]; then
    echo -e "[ ${G}OK${P} ] 进程守护状态: 活跃 (Active)"
else
    echo -e "[ ${R}FAIL${P} ] 进程守护状态: 异常 ($STATUS)"
fi

if ss -tlnp 2>/dev/null | grep -q ":$LIST_PORT "; then
    echo -e "[ ${G}OK${P} ] 端口监听验证: 端口 $LIST_PORT 正在监听"
else
    echo -e "[ ${R}FAIL${P} ] 未检测到端口 $LIST_PORT 监听"
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$LIST_PORT/)
HTML_BODY=$(curl -s http://127.0.0.1:$LIST_PORT/)
if [ "$HTTP_CODE" = "200" ] && [[ "$HTML_BODY" == *"VLESS Relay"* ]]; then
    echo -e "[ ${G}OK${P} ] HTTP 协议存活验证成功"
else
    echo -e "[ ${R}FAIL${P} ] HTTP 验证状态异常"
fi

WS_CODE=$(curl -i -s -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Host: 127.0.0.1" http://127.0.0.1:$LIST_PORT/ | head -n 1 | awk "{print \$2}")
if [ "$WS_CODE" = "101" ]; then
    echo -e "[ ${G}OK${P} ] WebSocket 升级协议握手验证成功 (HTTP 101)"
else
    echo -e "[ ${R}FAIL${P} ] WebSocket 协议测试异常 (响应码: $WS_CODE)"
fi

echo -e "${Y}====================================================${P}"
echo -e "部署及审计完毕！您的 VLESS 中转服务现已后台常驻。"
echo -e "监听端口: ${G}${LIST_PORT}${P} | 设定 UUID: ${G}${INPUT_UUID}${P}"
echo -e "提示: IBM Cloud 用户请在 VPC 安全组中放行 ${Y}${LIST_PORT}${P} 端口的出入站规则 [15]。"
echo -e "${Y}====================================================${P}"

rm -f /tmp/install_vless.sh
EOF
bash /tmp/install_vless.sh
