# docker-motionpro-cufe

在 Docker 容器中运行**中央财经大学(CUFE)的 Array MotionPro VPN 客户端**,并在容器内提供 SOCKS5 代理。配合 Clash 等分流工具,可以让**校园网/教育网流量走 VPN,其余流量直连**,无需在电脑上安装 VPN 客户端。

> 客户端版本: MotionPro Linux v1.2.18,来自 [Array Networks 官方下载页](https://client.arraynetworks.com.cn:8080/en/troubleshooting)。

---

## 工作原理

流量链路:

```
Clash / 浏览器 / 其他程序
        │  SOCKS5
        ▼
宿主机 127.0.0.1:10801
        │  端口映射
        ▼
容器内 danted(SOCKS5 服务,监听 0.0.0.0:1080)
        │  出站绑定 tun0
        ▼
MotionPro VPN 隧道
        ▼
校园网 / 教育网资源
```

容器启动后,入口脚本 `docker-entrypoint.sh` 会自动完成:

1. 启动 MotionPro 守护进程 `vpnd`;
2. 执行连接命令 `MotionPro -h $VPN_HOST -u $VPN_USER -p $VPN_PASSWD` 登录 VPN;
3. 轮询等待状态变为 `VPN Status: connected`;
4. 从 MotionPro 日志中提取 VPN 下发的 DNS 服务器,写入容器 `/etc/resolv.conf`;
5. 启动 `danted`,把 SOCKS5 代理的出站流量绑定到 VPN 隧道网卡 `tun0`;
6. 每秒检测 VPN 状态,一旦掉线容器退出,由 `restart: unless-stopped` 自动拉起重连。

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Linux(宿主机) |
| Docker | 20.10 及以上,含 Compose v2 插件(`docker compose` 命令) |
| TUN 设备 | `/dev/net/tun` 存在(一般默认存在;若没有:`sudo modprobe tun`) |
| 网络 | 宿主机能访问 VPN 网关 `vpn6.cufe.edu.cn` |
| 账号 | 校园 VPN 账号密码(通常与信息门户账号相同) |

---

## 快速开始

### 方式一:交互式脚本(推荐)

```bash
cd docker-motionpro-cufe
bash setup.sh
```

首次运行会自动进入**配置向导**,依次完成:

1. **环境自检** —— 检查 Docker、Compose 插件、`/dev/net/tun` 是否就绪;
2. **配置账号** —— 交互输入 VPN 网关(直接回车用默认值)、学号、密码(密码不回显,需输入两次确认),自动生成 `.env` 文件并设置权限为 600;
3. **启动服务** —— 拉取镜像并启动容器,实时显示连接进度,成功后自动测试代理连通性。

之后运行 `bash setup.sh`(不带参数)会进入管理菜单:

| 菜单项 | 功能 |
|---|---|
| 1) 环境自检 | 检查 Docker / Compose / TUN 设备 |
| 2) 配置账号 | 重新生成/修改 `.env` |
| 3) 启动服务 | 启动容器并等待 VPN 连接 |
| 4) 查看状态 | 容器运行状态 + VPN 连接状态 |
| 5) 查看日志 | 实时日志(`Ctrl+C` 退出) |
| 6) 测试连通性 | 通过代理访问校园网认证服务验证 |
| 7) 安全设置 | 把代理限制为**仅本机可访问**(推荐开启) |
| 8) 重启服务 | 停止后重新启动 |
| 9) 停止服务 | 停止并移除容器 |

也支持直接使用子命令,适合写进 shell 别名或脚本:

```bash
bash setup.sh config     # 只配置账号
bash setup.sh start      # 启动并等待连接
bash setup.sh status     # 查看状态
bash setup.sh logs       # 看实时日志
bash setup.sh test       # 测试代理连通性
bash setup.sh security   # 切换"仅本机可访问"
bash setup.sh restart    # 重启
bash setup.sh stop       # 停止
```

### 方式二:手动配置

```bash
# 1. 生成配置文件并填入账号
cp .env.example .env
vim .env

# 2. 启动(首次会自动拉取预构建镜像)
docker compose up -d

# 3. 观察日志,看到 "VPN Status: connected" 即成功
docker compose logs -f
```

`.env` 内容:

```ini
VPN_HOST=vpn6.cufe.edu.cn   # VPN 网关,一般不用改
VPN_USER=你的学号
VPN_PASSWD=你的VPN密码
```

> 变量名必须以 `VPN_` 开头(不要用 `USER`、`HOST` 这类系统已有环境变量名),否则 shell 环境变量会覆盖 `.env` 中的值,导致登录用户名被替换成 Linux 登录名。
> 如果 `.env` 中的值包含 `$`、空格等特殊字符,建议用单引号包裹,例如 `VPN_PASSWD='p@ss word'`。

验证代理可用:

```bash
curl --socks5-hostname 127.0.0.1:10801 -I https://authserver.cufe.edu.cn/authserver/login
```

返回 `HTTP 200` 即代表 VPN 代理已通。

---

## 使用代理

容器启动后本身就是一个**代理服务器**:容器内的 `danted` 提供 SOCKS5 服务,并已通过端口映射暴露到宿主机。基本信息:

| 项目 | 值 |
|---|---|
| 代理协议 | SOCKS5 |
| 本机使用 | `127.0.0.1:10801` |
| 局域网使用 | `宿主机内网IP:10801`(默认对所有网卡开放) |
| 认证方式 | 无 |
| 出口网络 | 校园网 / 教育网 |

### 本机使用(SOCKS5)

任何支持 SOCKS5 的程序直接指向 `127.0.0.1:10801` 即可,流量将全部从校园网出口出去:

```bash
# curl
curl --socks5-hostname 127.0.0.1:10801 https://my.cufe.edu.cn

# ssh 经代理跳转到校内主机
ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:10801 %h %p' user@校内主机IP
```

浏览器可配合 SwitchyOmega 等插件:新建 profile → 代理类型 `SOCKS5` → 服务器 `127.0.0.1` → 端口 `10801`。

### 局域网设备使用(手机、其他电脑)

`docker-compose.yaml` 默认端口映射为 `- 10801:1080`(绑定所有网卡),因此**局域网内的设备开箱即可把这台机器当作代理服务器**:

1. 查询宿主机内网 IP:`hostname -I`(如 `192.168.1.10`);
2. 确保宿主机防火墙放行 10801 端口(如 `sudo ufw allow 10801/tcp`);
3. 在其他设备上配置 SOCKS5 代理,服务器填宿主机内网 IP,端口 `10801`:
   - **电脑**:系统代理或浏览器插件(SwitchyOmega 等)指向 `192.168.1.10:10801`;
   - **手机**:Wi-Fi 设置中手动配置代理,或用 Clash / Shadowrocket 等客户端添加 `socks5` 类型节点(服务器 `192.168.1.10`,端口 `10801`)。

> ⚠️ **安全提醒**:该代理**没有用户名密码认证**,局域网内任何人都可以使用。请只在可信网络中共享;不需要共享时运行 `bash setup.sh security` 把端口限制为仅本机可访问(详见[安全建议](#安全建议))。

### HTTP 代理(danted 仅支持 SOCKS5)

容器内的 danted 只提供 SOCKS5 协议,不支持 HTTP 代理。如果某些软件只认 HTTP 代理,可在宿主机加一层 HTTP → SOCKS5 转换:

**方案一:gost(Docker 一行命令,推荐)**

```bash
docker run -d --name gost-http --restart=unless-stopped --network host \
    ginuerzh/gost -L "http://:10802" -F "socks5://127.0.0.1:10801"
```

之后 `宿主机IP:10802` 即为 HTTP 代理,流量经由 SOCKS5 → VPN 从校园网出去。

**方案二:privoxy(宿主机直接安装)**

```bash
sudo apt install privoxy
echo 'forward-socks5 / 127.0.0.1:10801 .' | sudo tee -a /etc/privoxy/config
echo 'listen-address 0.0.0.0:10802'     | sudo tee -a /etc/privoxy/config
sudo systemctl restart privoxy
```

### Clash 分流(本项目设计的主要用法)

参考仓库中的 `clash.example.yaml`,把下面三段合并进你现有的 Clash 配置:

- **`proxies`** —— 本地代理节点:

  ```yaml
  proxies:
    - name: CUFE-local-vpn
      port: 10801
      server: 127.0.0.1
      type: socks5
  ```

- **`proxy-groups`** —— 名为 `CUFE` 的策略组(带 fallback 掉线检测);

- **`rules`** —— 分流规则:`*.cufe.edu.cn`、教育网 IP 段(59.64/59.65/121.194/202.205.208-223 等)走 `CUFE`,其余全部 `DIRECT`。

配置中的 DNS 部分还把 `+.cufe.edu.cn` 指向校内 DNS `202.205.208.6`,保证校内域名能解析到正确的内网地址。

效果:**日常流量直连,只有访问校内资源时才经过 VPN**,无需手动切换。

---

## 日常管理

| 操作 | 脚本方式 | 等价的 docker 命令 |
|---|---|---|
| 启动 | `bash setup.sh start` | `docker compose up -d` |
| 停止 | `bash setup.sh stop` | `docker compose down` |
| 重启 | `bash setup.sh restart` | `docker compose restart` |
| 状态 | `bash setup.sh status` | `docker compose ps` |
| 日志 | `bash setup.sh logs` | `docker compose logs -f` |

运行日志同时会持久化到宿主机 `./logs/` 目录(MotionPro 运行日志),排查认证失败等问题优先看这里。

VPN 掉线时容器会自动退出并被 Docker 重新拉起(策略 `unless-stopped`),正常情况下无需人工干预。

---

## 安全建议

容器内的 SOCKS5 代理**无认证**。`docker-compose.yaml` 默认把端口映射到宿主机所有网卡,方便局域网设备共享,但也意味着**同一局域网内的任何人都能使用你的 VPN 代理**:

- **只在本机使用**(推荐):执行 `bash setup.sh security`,自动把端口映射改为 `127.0.0.1:10801:1080`(仅本机可访问),并提示是否重建容器使其生效;再次运行该选项可恢复局域网共享;
- **需要共享给局域网设备**:保持默认即可,但请确保所在网络可信(家庭/个人网络),不要在公共 Wi-Fi 等不可信网络下开放。

其他建议:

- `.env` 含账号密码,已在 `.gitignore` 中排除,**不要提交到仓库或分享给他人**;
- 如需改用其他端口,修改 `docker-compose.yaml` 中 `ports` 的宿主机侧端口,并同步修改 Clash 配置里的 `port`。

---

## 常见问题(FAQ)

**1. 启动后一直无法 connected,提示认证失败?**
先用 `bash setup.sh logs` 查看日志。确认账号密码正确、账号未锁定;VPN 密码通常与信息门户一致,若修改过门户密码需使用新密码。部分学校限制同时在线设备数,超出时也会失败。

**2. 宿主机 10801 端口被占用?**
`sudo ss -ltnp | grep 10801` 查看占用进程。若是其他程序,修改 `docker-compose.yaml` 中 `ports` 的宿主机侧端口(如 `- 20801:1080`),并同步修改 Clash 配置。

**3. 提示 `/dev/net/tun` 不存在?**
执行 `sudo modprobe tun` 加载内核模块;若宿主机是容器/虚拟机,需要宿主层开启 TUN 设备。

**4. 修改了 Dockerfile 或 docker-entrypoint.sh 后如何生效?**
默认使用的是预构建镜像 `lihaotong0712/docker-motionpro:latest`,不会应用你的修改。把 `docker-compose.yaml` 中的 `# build: .` 取消注释,然后执行:

```bash
docker compose up --build -d
```

(本地构建需要仓库中的 `MotionPro_Linux_Ubuntu_x64_v1.2.18.sh` 安装脚本。)

**5. 想换 VPN 网关或账号?**
重新运行 `bash setup.sh config`,或直接编辑 `.env`,然后 `bash setup.sh restart` 生效。

**6. 如何确认当前出口 IP?**

```bash
curl --socks5-hostname 127.0.0.1:10801 https://myip.ipip.net
```

显示校园网 IP 段(如 59.64.x.x、121.194.x.x)即说明代理已从校园网出口出去。

**7. 局域网里的其他设备连不上代理?**
按顺序检查:
① 是否运行过 `bash setup.sh security`——它会限制为仅本机访问,局域网设备将无法连接,重新运行一次该选项可恢复共享;
② 宿主机防火墙是否放行 10801 端口(`sudo ufw status` 查看);
③ 设备与宿主机是否在同一网段,代理地址填的是否为**宿主机的内网 IP**(不是 127.0.0.1)。

---

## 项目文件说明

| 文件 | 说明 |
|---|---|
| `setup.sh` | 交互式配置与管理脚本(环境自检/配置/启停/测试) |
| `docker-compose.yaml` | 服务编排:端口映射、TUN 设备、`NET_ADMIN` 权限、环境变量 |
| `Dockerfile` | 镜像构建:Ubuntu 18.04 + dante-server + MotionPro 客户端 |
| `docker-entrypoint.sh` | 容器入口脚本:连接 VPN、配置 DNS、启动 danted、掉线检测 |
| `danted.conf` | Dante SOCKS5 服务配置(无认证,出站走 tun0) |
| `danted.example.conf` | Dante 官方示例配置,仅作参考 |
| `clash.example.yaml` | Clash 分流配置示例 |
| `.env.example` | 环境变量模板,复制为 `.env` 后填写 |
| `MotionPro_Linux_Ubuntu_x64_v1.2.18.sh` | MotionPro 官方安装脚本(Ubuntu 版,构建镜像时使用) |
| `MotionPro_Linux_CentOS_x64_v1.2.18.sh` | MotionPro 官方安装脚本(CentOS 版,当前未使用) |
| `logs/`(运行时生成) | MotionPro 运行日志,已加入 `.gitignore` |

---

## 声明

本项目仅供个人学习与访问校内资源使用,请在遵守学校信息化管理规定的前提下合理使用,勿用于绕过网络管控等违规用途。
