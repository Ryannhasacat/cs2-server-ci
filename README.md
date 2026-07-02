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
├── Dockerfile                          # 三阶段: 基础(无CS2) → plugins → runtime
├── docker-compose.yml                  # cs2 + mysql;image 指向 GHCR;CS2 bind mount 到云数据盘
├── .env.example                        # 复制为 .env (永远不入 git)
├── .dockerignore
├── .gitignore
├── README.md
├── cs2/
│   ├── entrypoint.sh                   # 检测/下载 CS2 + envsubst + MySQL wait
│   ├── start_cs2.sh                    # 拼 srcds 命令行 (含 GSLT)
│   ├── server.cfg                      # 全局 cfg,MatchZy 不管的部分
│   ├── scripts/
│   │   ├── fetch-plugins.sh            # 拉 7 个插件 zip (CI 跑)
│   │   └── setup-cloud-disk.sh         # 初始化云数据盘 (服务器跑)
│   ├── plugins/                        # zip 缓存 (gitignore, CI 拉取)
│   └── configs/                        # 模板,entrypoint 注入 env
│       ├── core.json                   # CSS FollowCS2ServerGuidelines=false
│       ├── admins.json
│       ├── plugins/WeaponPaints/WeaponPaints.json
│       └── cfg/MatchZy/{config.cfg,admins.json,database.json}
├── mysql/init.sql                      # 预创建 weaponpaints / matchzy DB
└── .github/workflows/build.yml         # GH Actions:fetch + gitleaks + buildx + push
```

**镜像结构** (运行时):
- **构建期包含**: ubuntu + apt 依赖 + SteamCMD (~2 MB) + 7 个插件 (≈150 MB)
- **运行期下载**: CS2 游戏文件 ≈30 GB (进云数据盘 bind mount,首次启动 SteamCMD)
- 镜像压缩后 ≈ **350 MB**,解后 ≈ 1 GB

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

# 4) 云数据盘 (按量付费必备,见 §7)
#    在云控制台:创建 50 GB 数据盘,挂载,设"随实例释放 = 否"
#    然后初始化:
sudo bash /opt/cs2-server/cs2/scripts/setup-cloud-disk.sh /dev/vdb
#    (设备名按实际改;首次会格式化 + 加 fstab + chown 1001:1001)

# 5) 拉预构建镜像 + 启动
docker compose pull              # ~350 MB(只镜像本身,无 CS2)
docker compose up -d             # 首次:cs2 容器后台下载 CS2,20-30 分钟
docker compose logs -f cs2       # 看到 [entrypoint] MySQL ready 后等 SteamCMD 完成
```

预期首次启动日志(顺序):
```
[entrypoint] CS2 not found at /opt/cs2; downloading via SteamCMD...
[entrypoint] This takes 20-30 minutes on first run; subsequent starts use cached volume.
   ... SteamCMD 输出 (~20-30 分钟,显示 depot 下载进度) ...
[entrypoint] Waiting for MySQL ...
[entrypoint] MySQL ready
Connection to Steam servers successful
[MatchZy] MatchZy by WD- has been loaded!
[WeaponPaints] Plugin loaded successfully!
```

容器起来后,**修改 .env 重启生效** (服务器无需 rebuild):
```bash
$EDITOR .env
docker compose restart cs2
```

升级 CS2 (Valve 推了补丁):
```bash
docker compose restart cs2       # entrypoint 会自动 steamcmd validate,几秒-几分钟
```

## 3. 升级 CS2 / 插件

```bash
# 在本地 Mac — 替换插件 zip,或改 Dockerfile
cd /Users/ryan/Documents/cc-pro/cs2-server-building
curl -fsSL -o cs2/plugins/matchzy.zip <新版本 URL>   # 例:升级 MatchZy
git add . && git commit -m "升级 MatchZy" && git push
# GitHub Actions 3-5 分钟构建完 (有 cache)

# 服务器 — pull 镜像 + 重启
ssh user@SERVER
docker compose pull && docker compose up -d
# entrypoint 看到 CS2 已存在(从云数据盘),只跑 validate(delta update)
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

| 卷 / 绑定 | 物理位置 | 大小 | 内容 |
|---|---|---|---|
| Bind mount | `/mnt/cs2-install/cs2` (云数据盘) → `/opt/cs2` | **~30 GB** | CS2 游戏文件,首次启动下载,后续 validate delta |
| `cs2-serverdata` | Docker named volume (`/opt/serverdata`) | ~MB | server.cfg、MatchZy cfgs、WeaponPaints 配置、demo、stats、logs |
| `mysql-data` | Docker named volume (`/var/lib/mysql`) | ~MB-GB | 武器皮 + MatchZy 比赛统计 |

**关键点**:CS2 通过 bind mount 绑到**云数据盘**(`/mnt/cs2-install/cs2`),不依赖系统盘也不依赖 Docker named volume。这是为了**按量付费服务器**设计 —— 即使 VM 被释放(只要云盘没释放),CS2 仍然完整保留,新 VM 挂回云盘即用。详细见 §7。

`cs2-serverdata` 内结构:
| 路径 | 内容 |
|---|---|
| `csgo/cfg/server.cfg` | 全局 server.cfg |
| `csgo/cfg/MatchZy/` | MatchZy 的 warmup/knife/live/prac CFG + admins.json + config.cfg + database.json |
| `csgo/maps/` | 自定义地图 |
| `counterstrikesharp-configs/` | CSS / WeaponPaints 配置 |
| `csgo/MatchZy/` | MatchZy 比赛 demo |
| `csgo/MatchZy_Stats/` | MatchZy CSV 统计 |
| `logs/` | 服务器日志 |

`docker compose down` 不丢,`down -v` 才会清 named volumes(**不会**清云数据盘上的 CS2)。

## 7. 按量付费服务器:CS2 安装与更新机制

这一节专门解决按量付费场景的两个问题:
1. **"关机"是否会重下 30 GB CS2?** → 不会
2. **CS2 后续怎么更新?** → 自动

### 7.1 云数据盘设置(一次性)

> **核心思想**:CS2(30 GB)从 VM 的"系统盘"上,移到独立的"数据盘"上。数据盘独立计费、独立生命周期。

#### 在云控制台(以 Aliyun 为例,Tencent/华为云类似)

1. ECS 控制台 → 你的实例 → "云盘" → "创建云盘"
2. 参数:
   - **容量:50 GB**(30 GB CS2 + 10 GB docker cache + 10 GB 余量)
   - **类型:高效云盘或 SSD**(便宜够用)
   - **计费:按量付费**
3. 挂载到当前实例
4. **关键一步**:云盘详情 → "更多" → **"随实例释放" = 否**
   - Aliyun: "云盘属性" → "释放设置" → "随实例释放" 取消勾选
   - Tencent: "设置自动续费" 旁边的 "到期回收" 关闭
   - 华为云: "删除保护" 开启

#### 在实例里初始化(SSH)

```bash
lsblk                                    # 看到新盘,假设是 /dev/vdb
sudo bash /opt/cs2-server/cs2/scripts/setup-cloud-disk.sh /dev/vdb
# 该脚本:
#   - mkfs.ext4 (首次)
#   - mkdir -p /mnt/cs2-install/cs2
#   - 写 fstab 持久化
#   - mount -a
#   - chown 1001:1001 (容器内 steam 用户的 UID)
```

验证:
```bash
df -h /mnt/cs2-install   # 看到 ~50 GB
ls -la /mnt/cs2-install  # 看到 cs2/ 子目录
```

### 7.2 日常 Stop/Start 不重下 CS2

**Aliyun ECS Stop 行为**:
- Stop 时:**计算资源(VCPU、内存)不收费**
- 数据盘:继续按量计费(¥5-10/月)
- **CS2 完整保留**(在数据盘上)
- Start:几秒钟开机,容器内 entrypoint 看到 CS2 已存在 → 跑 `+app_update 730 validate` → 几秒-几分钟就绪

```bash
# 日常使用流程(按量付费)
# 用完 → 控制台 Stop ECS(几秒钟)→ CS2 完整保留
# 再用 → 控制台 Start ECS(几秒钟)→ ssh 进去 → docker compose up -d → 几秒到 1 分钟就绪
```

### 7.3 CS2 更新机制 — **全自动**

每次容器启动,entrypoint 会跑:
```bash
# entrypoint.sh 节选
if [ -x "${CS2_DIR}/game/bin/linux/cs2" ]; then
    steamcmd +app_update 730 validate +quit
fi
```

| 更新类型 | 频率 | 我们的处理 | 你要做的 |
|---|---|---|---|
| 小补丁(Valve 每周) | 高 | 容器启动自动 validate | **零操作** |
| 大更新(1-3 月) | 中 | validate 会下载大文件(10-30 分钟) | 零操作,等久一点 |
| 插件升级(MatchZy 等) | 中 | 改 `cs2/plugins/*.zip` → `git push` → 服务器 `docker compose pull && up -d` | 5 分钟 |
| CSS 框架升级 | 低 | 同上 | 5 分钟 |

**想立即检查/应用更新**(不必重启容器):
```bash
docker exec cs2-server /opt/steamcmd/steamcmd.sh \
  +force_install_dir /opt/cs2 +login anonymous \
  +app_update 730 validate +quit
```

### 7.4 强制重下 CS2

CS2 出问题(文件损坏、版本冲突、想回到"完全干净"状态):

```bash
# 1. 停容器
docker compose down

# 2. 删数据盘上的 CS2 内容(只删 csgo/ 和 game/ 即可,保留容器外的元数据)
sudo rm -rf /mnt/cs2-install/cs2/game /mnt/cs2-install/cs2/steamapps
#   或者更彻底:
# sudo rm -rf /mnt/cs2-install/cs2/*

# 3. 重新拉起容器 → entrypoint 看到 /opt/cs2 空 → SteamCMD 重下(20-30 分钟)
docker compose up -d
docker compose logs -f cs2
```

### 7.5 数据盘迁移(VM 释放/换机器)

如果 VM 因升级、迁移、故障重建:

```bash
# 旧 VM:停服
docker compose down
# 控制台:分离数据盘("卸载"而非"释放"),保留数据盘

# 新 VM:关联数据盘 → ssh 进去
sudo bash /opt/cs2-server/cs2/scripts/setup-cloud-disk.sh /dev/vdb
# (新 VM 没数据盘,需先在云控制台把旧数据盘 attach)
docker compose up -d
# entrypoint 看到 CS2 已存在 → validate 几秒
```

### 7.6 重要提醒:别删错东西

| 想做的 | 正确命令 | ❌ 错误命令 |
|---|---|---|
| 重下 CS2 | `sudo rm -rf /mnt/cs2-install/cs2/*` | 删 `/mnt/cs2-install` 整个 mount |
| 改 server.cfg | `docker exec -it cs2-server vim /opt/serverdata/csgo/cfg/server.cfg` | 在镜像里改(重启丢失) |
| 看 demo | `ls /opt/serverdata/csgo/MatchZy/` (在主机或容器) | 直接 `cat` 大文件(慢) |
| 备份配置 | `tar czf cfg-$(date +%F).tgz /opt/serverdata/csgo/cfg/ /opt/serverdata/counterstrikesharp-configs/` | 用 `docker cp` 单文件(慢) |

## 8. 常用运维

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

## 9. 验证 CS2 客户端连通性

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

## 10. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| GH Actions build 失败 `no space left` | 设计上已避免(CS2 在运行时下,镜像只 ~350 MB);若仍发生,`cache-from` 已加 |
| 服务器 `docker compose up` 卡在 SteamCMD | CS2 首次下载 20-30 分钟,正常现象;看 `docker compose logs cs2` 看 depot 进度 |
| 服务器 `Connection to Steam servers successful` 卡住 | 服务器出网被限,Steam 大量 CDN,加白名单 |
| `!knife` 无反应 | WeaponPaints 未连 MySQL,看 `docker compose logs mysql` |
| MatchZy 不响应 | `csgo/cfg/MatchZy/admins.json` 里 SteamID 是不是替换成了你的 (在 `cs2-serverdata` 卷里) |
| `Access denied for user 'cs2'` | MySQL 没就绪就启了 cs2,看 entrypoint 日志中 MySQL wait 是否超时 |
| 想强制重下 CS2(比如 CS2 出问题) | `sudo rm -rf /mnt/cs2-install/cs2/* && docker compose up -d`(详 §7.4) |
| bind mount 失败 `/mnt/cs2-install/cs2` 不存在 | 数据盘没挂上,跑 `sudo bash cs2/scripts/setup-cloud-disk.sh /dev/vdb` |

## 11. Security

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

## 12. 免责声明

**cs2-WeaponPaints** 改皮要求 `FollowCS2ServerGuidelines=false`,Valve 可能因此吊销 GSLT(作者 README 原文警告)。公网开服自担风险。

本项目仅供学习/测试,使用即同意 Valve 服务条款。
