# CS2 Dedicated Server (Docker) + MatchZy + cs2-WeaponPaints

CS2 专用服容器,**镜像不在服务器构建** —— 由 GitHub Actions (amd64 runner) 在云端构建并推送到 GHCR,服务器只 pull。

镜像 baked-in:
- **CS2 dedicated server** (Steam app 730, ≈30 GB)
- **Metamod:Source 1.11** — mod 框架
- **CounterStrikeSharp 1.0.370** (with-runtime)
- **MatchZy 0.8.15** — pug / scrim / match 管理 ([docs](https://shobhit-pathak.github.io/MatchZy/))
- **cs2-WeaponPaints build-423** — 武器/刀/手套/agent 皮肤 ([repo](https://github.com/Nereziel/cs2-WeaponPaints))
- 三个依赖: **PlayerSettingsCS2** / **AnyBaseLibCS2** / **MenuManagerCS2**
- **MySQL 8.0** 侧车容器

## 目录

```
cs2-server-building/
├── Dockerfile                          # 三阶段: SteamCMD → plugins → runtime
├── docker-compose.yml                  # cs2 + mysql;image 指向 GHCR
├── .env.example                        # 复制为 .env (永远不入 git)
├── .dockerignore
├── .gitignore
├── README.md
├── cs2/
│   ├── entrypoint.sh                   # envsubst + steamcmd update + MySQL wait
│   ├── start_cs2.sh                    # 拼 srcds 命令行 (含 GSLT)
│   ├── server.cfg                      # 全局 cfg,MatchZy 不管的部分
│   ├── scripts/fetch-plugins.sh        # 拉 7 个插件 zip
│   ├── plugins/                        # zip 缓存 (gitignore, 运行时拉取)
│   └── configs/                        # 模板,entrypoint 注入 env
│       ├── core.json                   # CSS FollowCS2ServerGuidelines=false
│       ├── admins.json
│       ├── plugins/WeaponPaints/WeaponPaints.json
│       └── cfg/MatchZy/{config.cfg,admins.json,database.json}
├── mysql/init.sql                      # 预创建 weaponpaints / matchzy DB
└── .github/workflows/build.yml         # GH Actions:fetch + gitleaks + buildx + push
```

## 1. 一次性配置 (本地 Mac)

```bash
# 0) 在 GitHub 上确保仓库是 public (GHCR 配额需要)
#    https://github.com/Ryannhasacat/cs2-server-ci/settings

# 1) git 初始化 + push
cd /Users/ryan/Documents/cc-pro/cs2-server-building
git init
git add .
git commit -m "initial commit"
git remote add origin git@github.com:Ryannhasacat/cs2-server-ci.git
git branch -M main
git push -u origin main

# 2) GitHub Actions 自动触发
#    https://github.com/Ryannhasacat/cs2-server-ci/actions
#    首次 build ~20 分钟 (SteamCMD 下载 CS2)
#    完成后镜像出现在:
#    https://github.com/Ryannhasacat/cs2-server-ci/pkgs/container/cs2-dedicated
```

之后任何 `git push` 改动 Dockerfile / 插件 / configs 都会自动重 build。

## 2. 一次性配置 (服务器)

```bash
ssh user@SERVER

# 1) 创建工作目录 + 拷项目 (排除 .env、plugins、运行时数据)
mkdir -p /opt/cs2-server
cd /opt/cs2-server
rsync -avz \
  --exclude='.git' \
  --exclude='.env' \
  --exclude='cs2/plugins/' \
  --exclude='cs2/local-configs/' \
  user@local:/Users/ryan/Documents/cc-pro/cs2-server-building/ ./

# 2) 准备 .env
cp .env.example .env
$EDITOR .env   # 改 CS2_RCON_PASSWORD / MYSQL_ROOT_PASSWORD / CS2_MYSQL_PASS / CS2_ADMIN_STEAMID
chmod 600 .env
chown $USER:$USER .env

# 3) 装 Docker (一次)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker
sudo apt install -y docker-compose-plugin

# 4) 拉预构建镜像并启动
docker compose pull      # 首次 ~10-15 GB
docker compose up -d
docker compose logs -f cs2
```

预期日志:
```
[entrypoint] Waiting for MySQL ...
[entrypoint] MySQL ready
[entrypoint] Updating CS2 (app 730)...
Connection to Steam servers successful
[MatchZy] MatchZy by WD- has been loaded!
[WeaponPaints] Plugin loaded successfully!
```

容器起来后,**修改 .env 重启生效** (服务器无需 rebuild):
```bash
$EDITOR .env
docker compose restart cs2
```

## 3. 升级 CS2 / 插件

```bash
# 在本地 Mac — 替换插件 zip,或改 Dockerfile
cd /Users/ryan/Documents/cc-pro/cs2-server-building
curl -fsSL -o cs2/plugins/matchzy.zip <新版本 URL>   # 例:升级 MatchZy
git add . && git commit -m "升级 MatchZy" && git push
# GitHub Actions 5-10 分钟构建完 (有 cache)

# 服务器 — pull + up
ssh user@SERVER
docker compose pull && docker compose up -d
```

## 4. 端口

| 用途 | 端口 | 协议 |
|---|---|---|
| 游戏流量 / RCON | 27015 | UDP + TCP |
| GOTV (观战) | 27020 | UDP |

公网安全组同时放行。RCON password 别用 `changeme-rcon`。

## 5. GSLT (Game Server Login Token)

没 GSLT 也能跑(客户端用控制台 `connect IP:port` 直连),但服务器**不会出现在公网浏览器列表**。建议拿到正式公网服再申请。

| 行为 | 有 GSLT | 无 GSLT |
|---|---|---|
| `connect IP:port` 直连 | ✅ | ✅ |
| 公网服务器浏览器 | ✅ | ❌ |
| Steam 好友邀请加入 | ✅ | ❌ |

申请: https://steamcommunity.com/dev/managegameservers (app 730,绑 IP:port,迁 IP 要重新生成)。填 `.env` 的 `CS2_GSLT`,重启容器。

## 6. 持久化数据

`cs2-serverdata` 卷 (挂 `/opt/serverdata`):

| 路径 | 内容 |
|---|---|
| `csgo/cfg/server.cfg` | 全局 server.cfg |
| `csgo/cfg/MatchZy/` | MatchZy 的 warmup/knife/live/prac CFG + admins.json + config.cfg + database.json |
| `csgo/maps/` | 自定义地图 |
| `counterstrikesharp-configs/` | CSS / WeaponPaints 配置 |
| `csgo/MatchZy/` | MatchZy 比赛 demo |
| `csgo/MatchZy_Stats/` | MatchZy CSV 统计 |
| `logs/` | 服务器日志 |

`mysql-data` 卷 (挂 MySQL `/var/lib/mysql`):武器皮 + MatchZy 数据库。

`docker compose down` 不丢,`down -v` 才丢。

## 7. 常用运维

```bash
docker compose logs -f cs2              # 看日志
docker compose logs -f mysql            # MySQL 日志

# RCON (需装一次 netcat)
docker exec cs2-server bash -c 'apt-get install -y --no-install-recommends netcat-openbsd >/dev/null 2>&1
  && printf "status\n" | nc -q1 127.0.0.1 27015'

# 改图 (MatchZy 模式下 admin 用 .map)
docker exec cs2-server bash -c 'printf "css_plugins list\n" | nc -q1 127.0.0.1 27015'

# 进容器调试
docker exec -it cs2-server bash

# 备份 MySQL
docker exec cs2-mysql mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases > backup-$(date +%F).sql
```

## 8. 验证 CS2 客户端连通性

```
CS2 → 设置 → 游戏 → 启用开发者控制台 ~
控制台:
  status                # 看 server info
  connect <服务器IP>:27015
  # 或无 GSLT 时:直接 console connect
```

进服后:
- 聊天 `!ready` / `!knife` —— MatchZy / WeaponPaints 都在工作
- RCON `meta list` → CounterStrikeSharp running
- RCON `css_plugins list` → 5+ plugins (MatchZy, WeaponPaints, MenuManagerCore, PlayerSettings, AnyBaseLib)

## 9. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| GH Actions build 失败 `no space left` | runner 70G 紧张,可加 `--no-cache` 验证;workflow 里已用 `--max-workers=1` 和 cache-from |
| 服务器 pull 镜像超时 | GitHub Container Registry 国内访问慢 → 考虑用 ghproxy 或迁移到阿里云镜像仓库 |
| 服务器 `Connection to Steam servers successful` 卡住 | 服务器出网被限,Steam 大量 CDN,加白名单 |
| `!knife` 无反应 | WeaponPaints 未连 MySQL,看 `docker compose logs mysql` |
| MatchZy 不响应 | `cfg/MatchZy/admins.json` 里 SteamID 是不是替换成了你的 |
| `Access denied for user 'cs2'` | MySQL 没就绪就启了 cs2,看 entrypoint 日志中 MySQL wait 是否超时 |

## 10. Security

### 仓库是 public,核心原则:镜像内不含任何 secret

`.gitignore` 已排除 `.env`、`*.pem`、`*.key`、`secrets/`。本项目设计为**所有 secret 通过环境变量在容器启动时注入**,构建期镜像只含 `__PLACEHOLDER__` 模板。任何 `docker pull ghcr.io/Ryannhasacat/cs2-dedicated` 的人看到的只是占位字符串。

### CI 防御

`.github/workflows/build.yml` 在 docker build **之前** 跑 `gitleaks/gitleaks-action@v2`,扫整个仓库,任何疑似 API key / `password=xxx` 模式 fail build。

### 服务器 `.env` 管理

```bash
# 写在服务器上的 .env 永远 chmod 600
chmod 600 .env
chown $USER:$USER .env

# 别加入 server 上的任何自动化备份(不加密)
# 重启后 docker compose 读取;rotate 密码就改 .env 然后 restart
```

### 轮换凭证

| 服务 | 轮换 |
|---|---|
| Steam GSLT | https://steamcommunity.com/dev/managegameservers — 撤销重发,绑 IP 立即生效 |
| Steam Web API key | https://steamcommunity.com/dev/apikey — 撤销重发 |
| MySQL `cs2` 用户 | `docker exec cs2-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "ALTER USER 'cs2'@'%' IDENTIFIED BY '新密码';"` + 改 .env + restart |
| MySQL root | 同上但用户是 `'root'@'localhost'` |
| RCON | 改 `.env` 的 `CS2_RCON_PASSWORD`,`docker compose restart cs2` |

### 如果 commit 过 secret

即使 `.gitignore` 阻止了未来 commit,**已经进 git 历史的 secret 仍在**:
1. **立刻轮换** (见上表)
2. `git filter-repo --invert-paths --path .env` 重写 history(注意破坏 force-push)
3. 通知 GitHub 删除已 fork / 已缓存的镜像:`support@github.com` 请求 purge GHCR

### 不要做

- ❌ 在 GitHub Issue / PR / Discord 贴完整 `.env` 或服务器日志
- ❌ `docker build --build-arg SECRET=xxx` (参数进 image history,公网可查)
- ❌ 在 Dockerfile 里写 `ENV PASSWORD=...` (env 持留到镜像 metadata)
- ❌ 公开 `docker history cs2-dedicated` 截图 (可能漏 env)

## 11. 免责声明

**cs2-WeaponPaints** 改皮要求 `FollowCS2ServerGuidelines=false`,Valve 可能因此吊销 GSLT(作者 README 原文警告)。公网开服自担风险。

本项目仅供学习/测试,使用即同意 Valve 服务条款。
