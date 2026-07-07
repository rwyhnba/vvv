#!/bin/bash

# ==========================================
# 脚本名称: VLESS 动态出站中转一键部署脚本
# 系统支持: Debian / Ubuntu / CentOS (amd64/arm64)
# 安全性: Systemd 独立进程守护，支持后台开机自启
# ==========================================

export LANG=en_US.UTF-8

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本。${PLAIN}"
    exit 1
fi

# 架构检测
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        GO_ARCH="amd64"
        CF_ARCH="amd64"
        ;;
    aarch64)
        GO_ARCH="arm64"
        CF_ARCH="arm64"
        ;;
    *)
        echo -e "${RED}暂不支持此系统架构: ${ARCH}${PLAIN}"
        exit 1
        ;;
esac

# 基础系统环境检测与安装
install_base_deps() {
    echo -e "${YELLOW}正在检测并安装基础依赖...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y
        apt-get install -y curl wget tar git build-essential uuid-runtime sudo
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget tar git gcc make util-linux sudo
    else
        echo -e "${RED}未检测到受支持的包管理器 (APT/YUM)。${PLAIN}"
        exit 1
    fi
}

# Go 语言环境配置
install_go() {
    if command -v go >/dev/null 2>&1; then
        echo -e "${GREEN}检测到 Go 语言环境已存在，跳过安装。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}正在自动获取并安装最新的 Go 编译器...${PLAIN}"
    # 尝试获取最新版本，若失败则回退至 1.22.5
    GO_VER=$(curl -s https://go.dev/VERSION?m=text | head -n 1)
    if [ -z "$GO_VER" ]; then
        GO_VER="go1.22.5"
    fi

    wget -O /tmp/go.tar.gz "https://go.dev/dl/${GO_VER}.linux-${GO_ARCH}.tar.gz"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Go 下载失败，请检查网络连接。${PLAIN}"
        exit 1
    fi

    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz

    # 写入环境变量
    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi
    export PATH=$PATH:/usr/local/go/bin
    echo -e "${GREEN}Go 编译环境部署完毕: $(go version)${PLAIN}"
}

# 动态写入并编译 Go 源码
build_vless_relay() {
    BUILD_DIR="/tmp/vless-relay-build"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR" || exit

    echo -e "${YELLOW}正在生成 Go 语言核心中转源码...${PLAIN}"

    cat << 'EOF' > main.go
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
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
	Command  byte // 1: TCP, 2: UDP
	Port     uint16
	AddrType byte // 1: IPv4, 2: Domain, 3: IPv6
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
			log.Printf("WebSocket upgrade error: %v", err)
			return
		}
		defer wsConn.Close()

		dialer, err := selectOutboundDialer(r.URL)
		if err != nil {
			log.Printf("Select outbound dialer error: %v", err)
			return
		}

		handleVlessSession(wsConn, uuidBytes, dialer)
	})

	log.Printf("VLESS 中转服务正在启动，监听端口: :%s，设定 UUID: %s", *portFlag, *uuidFlag)
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
		log.Printf("VLESS header parse error: %v", err)
		return
	}

	if header.Command != 1 {
		log.Println("Unsupported command: only TCP relay is implemented in this build")
		return
	}

	targetAddr := net.JoinHostPort(header.Address, strconv.Itoa(int(header.Port)))
	remoteConn, err := dialer.Dial("tcp", targetAddr)
	if err != nil {
		log.Printf("Dial target %s failed: %v", targetAddr, err)
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

	// Remote -> WebSocket
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

	// WebSocket -> Remote
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
			return nil, errors.New("UUID verification failed")
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
			return nil, errors.New("invalid IPv4 address length")
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
			return nil, errors.New("invalid IPv6 address length")
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
		return nil, fmt.Errorf("HTTP CONNECT tunnel failed with status: %s", resp.Status)
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
EOF

    echo -e "${YELLOW}正在编译并打包程序...${PLAIN}"
    export PATH=$PATH:/usr/local/go/bin
    go mod init vless-relay 2>/dev/null
    go get github.com/gorilla/websocket
    go get golang.org/x/net/proxy
    go mod tidy
    go build -ldflags="-s -w" -o vless-relay main.go

    if [ ! -f "vless-relay" ]; then
        echo -e "${RED}编译失败，请检查编译日志。${PLAIN}"
        exit 1
    fi

    mv vless-relay /usr/local/bin/vless-relay
    chmod +x /usr/local/bin/vless-relay
    cd / && rm -rf "$BUILD_DIR"
    echo -e "${GREEN}中转服务端编译并安装成功。${PLAIN}"
}

# 部署并配置 Systemd 守护进程
configure_systemd() {
    echo -e "${YELLOW}配置守护进程自启...${PLAIN}"

    # 生成默认配置
    read -p "请输入您希望中转监听的端口 (默认 8080): " LIST_PORT
    [ -z "$LIST_PORT" ] && LIST_PORT="8080"

    read -p "请输入您的 VLESS UUID (留空将自动生成一个 UUID): " INPUT_UUID
    if [ -z "$INPUT_UUID" ]; then
        if command -v uuidgen >/dev/null 2>&1; then
            INPUT_UUID=$(uuidgen)
        elif [ -f /proc/sys/kernel/random/uuid ]; then
            INPUT_UUID=$(cat /proc/sys/kernel/random/uuid)
        else
            INPUT_UUID="1f9d104e-ca0e-4202-ba4b-a0afb969c747"
        fi
    fi

    # 写入 systemd 服务
    cat << EOF > /etc/systemd/system/vless-relay.service
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
EOF

    systemctl daemon-reload
    systemctl enable vless-relay.service
    systemctl restart vless-relay.service

    echo -e "${GREEN}守护进程配置成功，并已拉起服务运行。${PLAIN}"
    echo -e "${YELLOW}当前配置信息：${PLAIN}"
    echo -e "  监听端口: ${GREEN}${LIST_PORT}${PLAIN}"
    echo -e "  VLESS UUID: ${GREEN}${INPUT_UUID}${PLAIN}"
}

# 自动安装 Cloudflare Tunnel 客户端
install_cloudflared() {
    echo -e "${YELLOW}是否安装 Cloudflare Tunnel 客户端 (用于联动 Argo 进行内网穿透与优化防封)? (y/n)${PLAIN}"
    read -p "请输入选择 (默认 n): " CHOICE
    if [[ "$CHOICE" == "y" || "$CHOICE" == "Y" ]]; then
        echo -e "${YELLOW}正在安装 cloudflared...${PLAIN}"
        wget -q -O /tmp/cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb"
        if [ -f /tmp/cloudflared.deb ]; then
            dpkg -i /tmp/cloudflared.deb 2>/dev/null || apt-get install -f -y
            rm -f /tmp/cloudflared.deb
        else
            # CentOS / RHEL 回退到下载二进制
            wget -q -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
            chmod +x /usr/local/bin/cloudflared
        fi
        echo -e "${GREEN}cloudflared 客户端安装成功。${PLAIN}"
        echo -e "${YELLOW}您可以随时运行以下命令来绑定并启动 Argo 隧道：${PLAIN}"
        echo -e "  1. 执行 ${GREEN}sudo cloudflared tunnel login${PLAIN} 绑定您的账户。"
        echo -e "  2. 执行 ${GREEN}sudo cloudflared tunnel create <您的隧道名字>${PLAIN} 创建隧道。"
    fi
}

# 卸载功能
uninstall_service() {
    echo -e "${RED}警告：您正在执行卸载操作，该操作将完全清除程序和守护进程。${PLAIN}"
    read -p "确定要卸载吗? (y/n, 默认 n): " UN_CHOICE
    if [[ "$UN_CHOICE" == "y" || "$UN_CHOICE" == "Y" ]]; then
        systemctl stop vless-relay.service 2>/dev/null
        systemctl disable vless-relay.service 2>/dev/null
        rm -f /etc/systemd/system/vless-relay.service
        systemctl daemon-reload
        rm -f /usr/local/bin/vless-relay
        echo -e "${GREEN}卸载完成。${PLAIN}"
    else
        echo -e "${YELLOW}已取消卸载。${PLAIN}"
    fi
}

# 主菜单
show_menu() {
    clear
    echo -e "==========================================="
    echo -e "      VLESS 动态出站中转一键部署脚本         "
    echo -e "==========================================="
    echo -e "  1. 完整编译安装 (Go构建 + 进程守护)"
    echo -e "  2. 重启 VLESS 中转服务"
    echo -e "  3. 停止 VLESS 中转服务"
    echo -e "  4. 查看中转服务运行日志"
    echo -e "  5. 卸载中转服务"
    echo -e "  0. 退出脚本"
    echo -e "==========================================="
    read -p "请输入选项: " MENU_ID
    case "$MENU_ID" in
        1)
            install_base_deps
            install_go
            build_vless_relay
            configure_systemd
            install_cloudflared
            ;;
        2)
            systemctl restart vless-relay.service
            echo -e "${GREEN}服务已重启。${PLAIN}"
            ;;
        3)
            systemctl stop vless-relay.service
            echo -e "${YELLOW}服务已停止。${PLAIN}"
            ;;
        4)
            journalctl -u vless-relay.service -n 50 -f
            ;;
        5)
            uninstall_service
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项!${PLAIN}"
            ;;
    esac
}

show_menu
