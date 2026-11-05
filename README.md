# docker-motionpro-cufe

在 Docker 容器中运行**中央财经大学(CUFE)的 Array MotionPro VPN 客户端**,容器内提供 SOCKS5 代理;配套 **TUI 管理台**(配置 / 启停 / 日志 / 诊断一体化)与**一键生成的 Clash 全局扩展脚本**,实现:校园网流量自动走 VPN、VPN 掉线自动回退直连、其余流量互不影响。

> 客户端版本: MotionPro Linux build-8383-34,来自 [Array Networks 官方下载页](https://client.arraynetworks.com.cn:8080/en/troubleshooting)。

---

## 目录

- [一、工作原理](#一工作原理)
- [二、环境要求](#二环境要求)
- [三、快速开始](#三快速开始)
- [四、TUI 管理台功能详解](#四tui-管理台功能详解)
- [五、Clash 集成详解](#五clash-集成详解)
- [六、使用代理](#六使用代理)
- [七、日常管理](#七日常管理)
- [八、安全建议](#八安全建议)
- [九、常见问题(FAQ)](#九常见问题faq)
- [十、项目文件说明](#十项目文件说明)
- [十一、声明](#十一声明)

---

## 一、工作原理

### 流量链路

```
Clash(CUFE-AUTO 策略组)
        │  SOCKS5
        ▼
宿主机 127.0.0.1:10801
        │  端口映射
        ▼
容器内 danted(SOCKS5 服务)
        │  出站绑定 tun0
        ▼
MotionPro VPN 隧道
        ▼
校园网 / 教育网资源
```

### 容器内部流程

容器启动后,入口脚本 `docker-entrypoint.sh` 自动完成:

1. 启动 MotionPro 守护进程 `vpnd`;
2. 使用 `.env` 中的账号连接 `VPN_HOST`;
3. 等待状态变为 `VPN Status: connected`;
4. 从日志提取 VPN 下发的 DNS,写入容器 `/etc/resolv.conf`;
5. 启动 `danted`(SOCKS5,出站绑定 `tun0`);
6. 持续监测 VPN 状态,掉线即退出容器,由 `restart: unless-stopped` 自动拉起重连。

### Clash 集成机制

由生成的全局扩展脚本(见[五、Clash 集成详解](#五clash-集成详解))向 Clash 注入:

- `CUFE-SOCKS5` 节点:指向本机 `127.0.0.1:10801`;
- `CUFE-AUTO` 策略组:fallback 类型,**每 10 秒探测**校园网页,VPN 可用走 VPN、不可用自动回退直连、恢复后自动切回;
- DNS 策略:校园域名走校内 DNS(查询随 `CUFE-AUTO` 分流),VPN 入口域名用公共 DNS 防回环;
- 分流规则:回环/局域网/登录页/VPN 入口直连,校园域名与 `10.0.0.0/8` 走 VPN。

---

## 二、环境要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Linux |
| Docker | 20.10+,含 Compose v2 插件 |
| TUN 设备 | `/dev/net/tun` 存在(没有则 `sudo modprobe tun`) |
| 网络 | 能访问 VPN 网关 `vpn6.cufe.edu.cn` |
| 账号 | 校园 VPN 账号密码(通常与信息门户一致) |
| TUI 体验 | `gum`(可选,自动检测;缺失时回退 whiptail / 纯文本) |

---

## 三、快速开始

### 方式一:TUI 管理台(推荐)

```bash
./cufe-tui.sh
```

首次使用按顺序:**新建配置 → 启动 VPN 服务容器 → 校园网资源连通性测试**;要在 Clash 里分流再执行**生成 Clash 全局扩展脚本**。

TUI 会自适应界面框架:安装 [gum](https://github.com/charmbracelet/gum) 后体验最佳(彩色菜单 / 进度条 / 滚动查看器),未安装时自动回退 whiptail 或纯文本,功能完全一致。

### 方式二:纯命令行

```bash
# 1. 配置账号
cp .env.example .env && vim .env

# 2. 启动(首次自动构建/拉取镜像)
docker compose up -d

# 3. 验证
./cufe-tui.sh test
```

`.env` 变量:

| 变量 | 说明 |
|---|---|
| `VPN_HOST` | VPN 网关,默认 `vpn6.cufe.edu.cn` |
| `VPN_USER` | 学号 |
| `VPN_PASSWD` | VPN 密码 |

> 变量名固定使用 `VPN_` 前缀,请勿改成 `USER`、`HOST` 等系统已有环境变量名——Compose 的取值优先级是 shell 环境变量高于 `.env`,重名会导致配置被覆盖、登录失败。值含特殊字符时建议用单引号包裹。

### 方式三:轻量向导 setup.sh

```bash
bash setup.sh    # 交互式菜单:配置 / 启动 / 停止 / 日志 / 测试
```

`setup.sh` 是早期的轻量管理脚本,功能与 TUI 的容器管理部分一致,可按喜好选用。

---

## 四、TUI 管理台功能详解

运行 `./cufe-tui.sh`,菜单标题实时显示 VPN 状态:

| 菜单 | 功能 | 说明 |
|---|---|---|
| 1 | 新建/修改配置 | 无配置时显示「新建配置」;已有配置显示「修改配置」,进入后先展示现有网关/学号/密码并询问是否修改。仅填写学号和密码,单屏完成,写入 `.env`(权限 600)。容器运行中修改后会询问是否立即重启生效 |
| 2 | 启动 VPN 服务容器 | `docker compose up -d` 后等待连接(最长 120 秒,带进度提示),成功后显示代理地址 |
| 3 | 停止 VPN 服务容器 | `docker compose down` |
| 4 | 查看容器日志 | 进入前先展示操作说明(如何停止、如何返回),确认后开始跟随;`Ctrl+C` 停止日志,再按回车返回菜单 |
| 5 | 校园网资源连通性测试 | 一键体检,详见下表 |
| 6 | 生成 Clash 全局扩展脚本 | 自动收集参数生成脚本,保存到 `generated-clash-script.js` 并自动用文本编辑器打开(可用 `$EDITOR` 指定),同时尽力复制到剪贴板;粘贴进 Clash Verge 并重新激活订阅即可生效 |

连通性测试包含的项目:

| 检测项 | 期望结果 |
|---|---|
| 容器状态 / VPN 状态 | Up (healthy) / connected |
| Clash 内核 | 出现 `CUFE-AUTO` 节点(未出现说明脚本未生效) |
| SOCKS5 直测 | 统一身份认证经代理返回 200 |
| TUN 端到端(10 网段) | 校内 Web 服务返回 302 |
| TUN 端到端(域名) | 认证服务返回 200 |
| 局域网豁免 | 家庭网关直连可达 |

TUI 同时支持命令行子命令:

```bash
./cufe-tui.sh config    # 新建/修改配置
./cufe-tui.sh start     # 启动
./cufe-tui.sh stop      # 停止
./cufe-tui.sh logs      # 日志
./cufe-tui.sh test      # 连通性测试
./cufe-tui.sh gen       # 生成 Clash 脚本(写文件 + 剪贴板)
./cufe-tui.sh gen-preview  # 仅打印脚本内容,不写盘
./cufe-tui.sh help      # 帮助
```

---

## 五、Clash 集成详解

### 生成与安装

执行 TUI 菜单 6(或 `./cufe-tui.sh gen`)后:

1. 脚本自动收集参数:SOCKS5 端口、健康检查地址、Wi-Fi 登录页(`net.cufe.edu.cn` → `10.13.13.2`)、VPN 入口域名并通过 DoH 解析其真实 IP(绕过本机可能的 fake-ip DNS);
2. 内容保存到 `generated-clash-script.js` 并自动用文本编辑器打开;
3. 同时尽力复制到剪贴板(需安装 `wl-clipboard` 或 `xclip`,未安装会给出提示);
4. 打开 **Clash Verge → 订阅页 → 全局扩展脚本**,粘贴脚本内容保存,**重新激活订阅**;
5. 用 TUI「连通性测试」验证:内核出现 `CUFE-AUTO` 即生效。

> 生成器只产出文件与剪贴板内容,不会直接修改你的 Clash 配置——是否启用、何时启用完全由你决定。

### 注入的分流规则

| 规则 | 目标 |
|---|---|
| `127.0.0.0/8`、`::1` | DIRECT |
| `net.cufe.edu.cn`、`10.13.13.2`(Wi-Fi 登录页) | DIRECT |
| `vpn6.cufe.edu.cn` 及其入口 IP(VPN 登录流量) | DIRECT |
| `*.cufe.edu.cn` | CUFE-AUTO |
| `10.0.0.0/8`(校园内网) | CUFE-AUTO |
| `172.16.0.0/12`、`192.168.0.0/16`、`fc00::/7` | DIRECT |

`CUFE-AUTO` 为 fallback 组:VPN 节点探测失败时自动切 `CUFE-DIRECT`,恢复后自动切回,全程无需人工干预。

### 备选:订阅级分流

如果不想用全局扩展脚本,也可以把 `clash.example.yaml` 中的 `proxies` / `proxy-groups` / `rules` 三段手动合并进订阅配置,效果相同(该文件还包含更完整的教育网 IP 段清单,可按需摘取)。

---

## 六、使用代理

代理启动后,宿主机 `127.0.0.1:10801` 即为 SOCKS5 代理,出口为校园网。

**本机使用:**

```bash
curl --socks5-hostname 127.0.0.1:10801 https://my.cufe.edu.cn
ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:10801 %h %p' user@校内主机
```

浏览器可用 SwitchyOmega 等插件:类型 `SOCKS5`,服务器 `127.0.0.1`,端口 `10801`。

**局域网设备使用**(默认端口映射绑定所有网卡):其他设备把代理指向 `宿主机内网IP:10801` 即可,需防火墙放行该端口。注意代理无认证,请仅在可信网络共享;不需要共享时把 `docker-compose.yaml` 的端口映射改为 `127.0.0.1:10801:1080`(仅本机可访问)。

**HTTP 代理**:danted 仅支持 SOCKS5。需要 HTTP 代理时可在宿主机加一层转换:

```bash
# 方案一:gost(容器一行命令)
docker run -d --name gost-http --restart=unless-stopped --network host \
    ginuerzh/gost -L "http://:10802" -F "socks5://127.0.0.1:10801"

# 方案二:privoxy
sudo apt install privoxy
echo 'forward-socks5 / 127.0.0.1:10801 .' | sudo tee -a /etc/privoxy/config
echo 'listen-address 0.0.0.0:10802' | sudo tee -a /etc/privoxy/config
sudo systemctl restart privoxy
```

---

## 七、日常管理

| 操作 | TUI | 命令行 |
|---|---|---|
| 配置账号 | 菜单 1 | `./cufe-tui.sh config` |
| 启动 | 菜单 2 | `./cufe-tui.sh start` |
| 停止 | 菜单 3 | `./cufe-tui.sh stop` |
| 日志 | 菜单 4 | `./cufe-tui.sh logs` |
| 连通性测试 | 菜单 5 | `./cufe-tui.sh test` |
| 生成 Clash 脚本 | 菜单 6 | `./cufe-tui.sh gen` |
| 等价 docker 命令 | — | `docker compose up -d` / `down` / `logs -f` / `ps` |

说明:

- VPN 掉线时容器自动退出并被拉起重连;但手动 `stop` 过之后,重启电脑不会自动拉起,需再次执行启动;
- 运行日志同时持久化在 `./logs/`(MotionPro 日志),排查认证问题优先看这里;
- 验证代理出口:`curl --socks5-hostname 127.0.0.1:10801 https://myip.ipip.net`,显示校园网 IP 段(59.64.x.x、121.194.x.x 等)即正确。

---

## 八、安全建议

- 容器内的 SOCKS5 代理**无认证**,默认映射到宿主机所有网卡:同一局域网内的任何设备都可以使用你的 VPN 代理;
- 仅本机使用时,建议把 `docker-compose.yaml` 中 `ports` 改为 `127.0.0.1:10801:1080`;
- 需要共享给局域网设备时保持默认,但请确保网络可信,勿在公共 Wi-Fi 下开放;
- `.env` 含账号密码,已被 `.gitignore` 排除,**不要提交或分享**。

---

## 九、常见问题(FAQ)

**1. 启动后一直无法 connected?**
先看日志(TUI 菜单 4)。确认账号密码正确、账号未锁定;VPN 密码通常与信息门户一致。连续多次失败会触发网关账号锁定(一般 15~30 分钟),请先在浏览器打开 `https://vpn6.cufe.edu.cn` 人工验证凭据,确认可用后再启动容器。

**2. Clash 菜单里没有出现 CUFE-AUTO(连通性测试提示"CUFE 节点未加载")?**
说明全局扩展脚本尚未生效:确认已把生成的脚本粘贴到 Clash Verge 的「全局扩展脚本」并保存,然后**重新激活订阅**(订阅页点击当前订阅卡片,或设置中重启内核),再跑一次连通性测试。

**3. 宿主机 10801 端口被占用?**
`sudo ss -ltnp | grep 10801` 查看占用;若是其他程序,修改 `docker-compose.yaml` 中 `ports` 的宿主机侧端口,并同步修改 Clash 脚本里 `CUFE-SOCKS5` 的 `port` 后重新生成。

**4. 提示 `/dev/net/tun` 不存在?**
执行 `sudo modprobe tun`;若宿主机本身是容器/虚拟机,需要宿主层开启 TUN 设备。

**5. 修改了 Dockerfile 或入口脚本后如何生效?**
`docker-compose.yaml` 已默认启用本地构建(`build: .`),执行 `docker compose up --build -d` 即可。本地构建依赖仓库中的 `MotionPro_Linux_Ubuntu_x64_build-8383-34.sh` 安装包;更换客户端版本时,替换安装包文件并同步修改 `Dockerfile` 中的文件名。

**6. 想更换账号或网关?**
TUI 菜单 1(或 `./cufe-tui.sh config`),完成后按提示重启容器。

**7. 局域网设备连不上代理?**
依次检查:① 是否已把端口映射改为 `127.0.0.1` 前缀;② 宿主机防火墙是否放行 10801;③ 设备填的是否为宿主机内网 IP。

---

## 十、项目文件说明

| 文件 | 说明 |
|---|---|
| `cufe-tui.sh` | TUI 管理台:配置 / 启停 / 日志 / 诊断 / Clash 脚本生成一体化(gum / whiptail / 纯文本自适应) |
| `generated-clash-script.js` | TUI 生成的 Clash 全局扩展脚本(已加入 `.gitignore`) |
| `setup.sh` | 轻量交互式管理脚本(容器生命周期 + 配置) |
| `docker-compose.yaml` | 服务编排:本地构建、端口映射、TUN 设备、`NET_ADMIN` 权限、环境变量 |
| `Dockerfile` | 镜像构建:Ubuntu 18.04 + dante-server + MotionPro 客户端 |
| `docker-entrypoint.sh` | 容器入口:连 VPN、配 DNS、起 danted、掉线检测 |
| `danted.conf` | Dante SOCKS5 配置(无认证,出站走 tun0) |
| `clash.example.yaml` | Clash 订阅级分流配置示例(含完整教育网 IP 段) |
| `.env.example` | 环境变量模板(`VPN_HOST` / `VPN_USER` / `VPN_PASSWD`) |
| `MotionPro_Linux_Ubuntu_x64_build-8383-34.sh` | MotionPro 官方 Linux 安装脚本(构建镜像时使用) |
| `logs/`(运行时生成) | MotionPro 运行日志 |

---

## 十一、声明

本项目仅供个人学习与访问校内资源使用,请在遵守学校信息化管理规定的前提下合理使用,勿用于绕过网络管控等违规用途。
