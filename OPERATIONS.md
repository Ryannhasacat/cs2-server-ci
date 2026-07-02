# CS2 Server Operations Manual

> 部署入门见 [`README.md`](README.md)。本文档覆盖**长期运维** —— 配置在哪、改什么生效什么、更新流程、故障定位。

## 目录

1. [架构总览](#1-架构总览)
2. [服务器目录速查](#2-服务器目录速查)
3. [配置文件位置(全表)](#3-配置文件位置全表)
4. [环境变量(.env)参考](#4-环境变量env参考)
5. [更新操作](#5-更新操作)
6. [日常运维命令](#6-日常运维命令)
7. [MatchZy / cs2-WeaponPaints 命令速查](#7-matchzy--cs2-weaponpaints-命令速查)
8. [RCON 操作](#8-rcon-操作)
9. [数据库操作](#9-数据库操作)
10. [备份与恢复](#10-备份与恢复)
11. [故障排查](#11-故障排查)
12. [凭证轮换](#12-凭证轮换)
13. [灾难恢复](#13-灾难恢复)

---

## 1. 架构总览

```
┌────────────────────┐
│ GitHub Actions     │  push → buildx + gitleaks + push
│ (ubuntu-latest)    │  →  ghcr.io/ryannhasacat/cs2-dedicated
└────────────────────┘
         │
         │ docker pull
         ▼
┌──────────────────────────────────────────────────┐
│  ECS 实例(按量付费)                              │
│                                                  │
│  ┌──────────────┐    bind mount                  │
│  │ cs2 容器    │◄──────/mnt/cs2-install/cs2     │◄──── 云数据盘(50GB)
│  │  + entrypoint│    (CS2 30 GB)                 │       (随实例释放=否)
│  │  + start_cs2 │                                │
│  └──────┬───────┘                                │
│         │                                        │
│         │  /opt/serverdata  (named volume)        │
│         │  /opt/cs2 (cs2-install via bind mount) │
│         ▼                                        │
│  ┌──────────────┐                                │
│  │ mysql 容器  │  /var/lib/mysql (named vol)    │
│  └──────────────┘                                │
└──────────────────────────────────────────────────┘
         ▲
         │  CS2 客户端 connect IP:27015
         │
┌────────┴───────┐
│  公网安全组     │  UDP/TCP 27015 (game+RCON)
│  放行 27015    │  UDP 27020 (GOTV)
└────────────────┘
```

**关键事实**:
- 镜像 ≈ 350 MB,只含 ubuntu + apt 依赖 + SteamCMD + 7 个插件
- CS2 30 GB 在 `cs2-install` 数据盘,**容器首次启动由 entrypoint 拉取**
- MySQL 在独立 named volume
- 凭据全部从 `.env` 注入容器,**镜像/仓库/数据盘都不含真实密码**

---

## 2. 服务器目录速查

服务器 `/opt/cs2-server` 是项目根。运行后实际产生的目录/卷:

```
/opt/cs2-server/                          # 项目根
├── .env                                  # 你创建,chmod 600,所有 secret 在这
├── .env.example                          # 模板,git 跟踪
├── docker-compose.yml                    # 服务定义
├── README.md, OPERATIONS.md
├── cs2/
│   ├── entrypoint.sh                     # 启动时拉 CS2 / 注入 env / 等 MySQL
│   ├── start_cs2.sh                      # 拼 srcds 命令行
│   ├── server.cfg                        # 镜像内默认,实际被 serverdata 覆盖
│   ├── scripts/
│   │   ├── fetch-plugins.sh              # CI 拉 7 个 zip(本地不需要)
│   │   └── setup-cloud-disk.sh           # 服务器初始化数据盘
│   ├── configs/                          # 镜像内模板,首次启动 seed 到 serverdata
│   └── plugins/                          # 不在服务器上(只 CI 用)
└── mysql/
    └── init.sql                          # 预创建 weaponpaints / matchzy DB

# ----- 运行时数据(主机上) -----

/opt/cs2-server/cs2-serverdata/            # 命名卷,挂入容器 /opt/serverdata
├── csgo/cfg/                             # 所有 .cfg,可在主机直接 vim
│   ├── server.cfg
│   └── MatchZy/                          # 插件 cfgs
├── csgo/maps/                            # 自定义地图
├── counterstrikesharp-configs/           # CSS / WeaponPaints 配置
└── logs/

/mnt/cs2-install/cs2/                     # 数据盘 bind mount,挂入容器 /opt/cs2
├── game/                                 # CS2 完整文件(~30 GB)
└── steamapps/                            # SteamCMD 工作区
```

---

## 3. 配置文件位置(全表)

> **改配置文件之前必看**:每个文件都有"什么时候生效"一栏。

| 文件 | 容器内路径 | 主机 / 数据卷路径 | 生效时机 | 用途 |
|---|---|---|---|---|
| `.env` | (不挂载) | `/opt/cs2-server/.env` | 重启容器 | Docker env 变量,所有 secret |
| `cs2/server.cfg` | `/opt/cs2/game/csgo/cfg/server.cfg` | `/opt/cs2-server/cs2-serverdata/csgo/cfg/server.cfg` | 下次切图 | 全局 CVAR,MatchZy 不管的部分 |
| `cfg/MatchZy/config.cfg` | `/opt/cs2/game/csgo/cfg/MatchZy/config.cfg` | `/opt/cs2-server/cs2-serverdata/csgo/cfg/MatchZy/config.cfg` | `exec MatchZy/config.cfg` 热加载 | MatchZy 全局设置 |
| `cfg/MatchZy/admins.json` | `/opt/cs2/game/csgo/cfg/MatchZy/admins.json` | `/opt/cs2-server/cs2-serverdata/csgo/cfg/MatchZy/admins.json` | 下次比赛加载 | MatchZy admin Steam64 ID 列表 |
| `cfg/MatchZy/database.json` | `/opt/cs2/game/csgo/cfg/MatchZy/database.json` | `/opt/cs2-server/cs2-serverdata/csgo/cfg/MatchZy/database.json` | 重启容器 | MatchZy MySQL 凭据 |
| `cfg/MatchZy/warmup.cfg` | 同 MatchZy/ | 同 MatchZy/ | 比赛进入 warmup | 暖身设置 |
| `cfg/MatchZy/knife.cfg` | 同 MatchZy/ | 同 MatchZy/ | 比赛进入 knife | 刀战设置 |
| `cfg/MatchZy/live.cfg` | 同 MatchZy/ | 同 MatchZy/ | 比赛进入 live | 主比赛设置 |
| `cfg/MatchZy/prac.cfg` | 同 MatchZy/ | 同 MatchZy/ | 进入 prac 模式 | 练习模式设置 |
| `core.json` | `/opt/cs2/game/csgo/addons/counterstrikesharp/configs/core.json` | `/opt/cs2-server/cs2-serverdata/counterstrikesharp-configs/core.json` | 重启容器 | CSS 核心(`FollowCS2ServerGuidelines` 等) |
| `admins.json` (CSS) | `/opt/cs2/game/csgo/addons/counterstrikesharp/configs/admins.json` | `/opt/cs2-server/cs2-serverdata/counterstrikesharp-configs/admins.json` | 重启容器 | CSS admin 权限 |
| `WeaponPaints.json` | `/opt/cs2/game/csgo/addons/counterstrikesharp/configs/plugins/WeaponPaints/WeaponPaints.json` | `/opt/cs2-server/cs2-serverdata/counterstrikesharp-configs/plugins/WeaponPaints/WeaponPaints.json` | 重启容器 | cs2-WeaponPaints 全设置 + MySQL |
| MySQL `weaponpaints` DB | (容器内) | `/var/lib/docker/volumes/cs2-server_mysql-data/` | — | 玩家皮选择 |
| MySQL `matchzy` DB | (容器内) | 同上 | — | 比赛统计 |
| `docker-compose.yml` | (docker 层) | `/opt/cs2-server/docker-compose.yml` | `docker compose up -d` | 端口/卷/服务定义 |

**快速找到配置文件**:
```bash
ssh user@SERVER
cd /opt/cs2-server
# 容器内路径 ↔ 主机路径(symbolic 链接,容器内 /opt/cs2 实际就是 /mnt/cs2-install/cs2)
docker exec cs2-server ls -la /opt/cs2/game/csgo/cfg/
docker exec cs2-server ls -la /opt/cs2/game/csgo/addons/counterstrikesharp/configs/
```

**在容器内 vs 主机内编辑**:
- 主机内编辑 → 实时反映到容器(因 bind mount / 命名卷)
- 容器内编辑 → 也实时,但更难找到文件
- **推荐:主机内编辑**,因为 vim / nano / VSCode 都方便

---

## 4. 环境变量(.env)参考

`.env` 是**所有**运行时配置的单一来源(密码、网络、插件绑定都靠它)。容器启动时 `entrypoint.sh` 会把里面的变量注入到插件 JSON 配置。

| 变量 | 默认 | 用途 | 改后生效 |
|---|---|---|---|
| `CS2_PORT` | `27015` | 游戏端口 | 重启容器 |
| `CS2_TV_PORT` | `27020` | GOTV 端口 | 重启容器 |
| `CS2_TICKRATE` | `64` | 服务器 tickrate | 重启容器 |
| `CS2_REGION` | `3` | Valve 区域码(3=亚洲) | 重启容器 |
| `CS2_LAN` | `0` | 局域网模式 | 重启容器 |
| `CS2_MAXPLAYERS` | `10` | 最大玩家数(5v5=10) | 重启容器 |
| `CS2_GAMEMODE` | `competitive` | (仅启动命令行参数) | — |
| `CS2_HOTNAME` | `CS2 Dedicated Server` | 服务器名 | 重启容器 |
| `CS2_RCON_PASSWORD` | `changeme-rcon` | RCON 密码 | 重启容器 |
| `CS2_SERVER_PASSWORD` | (空) | 服务器密码(空=公开) | 重启容器 |
| `CS2_GSLT` | (空) | Steam Game Server Login Token | 重启容器 |
| `CS2_AUTHKEY` | (空) | Steam Web API key(创意工坊必需) | 重启容器 |
| `CS2_ADMIN_STEAMID` | `76561198104682187` | MatchZy + CSS 全局 admin | 重启容器 |
| `CS2_HOST_WORKSHOP_MAP` | (空) | 单个创意工坊地图 ID | 重启容器 |
| `CS2_WORKSHOP_COLLECTION` | (空) | 创意工坊合集 ID | 重启容器 |
| `CS2_TV_ENABLE` | `1` | 启用 GOTV | 重启容器 |
| `CS2_TV_DELAY` | `0` | GOTV 延迟秒数(0=实时) | 重启容器 |
| `CS2_MYSQL_HOST` | `mysql` | MySQL 主机名(同 compose network) | 重启容器 |
| `CS2_MYSQL_PORT` | `3306` | MySQL 端口 | 重启容器 |
| `CS2_MYSQL_USER` | `cs2` | MySQL 用户 | 重启容器 |
| `CS2_MYSQL_PASS` | `changeme-cs2` | MySQL 密码 | 重启容器 |
| `CS2_MYSQL_DB_WEAPON` | `weaponpaints` | WeaponPaints DB 名 | 重启容器 |
| `CS2_MYSQL_DB_MATCH` | `matchzy` | MatchZy DB 名 | 重启容器 |
| `MYSQL_ROOT_PASSWORD` | `changeme-root` | MySQL root 密码 | 重启容器 |
| `CS2_EXTRA_ARGS` | (空) | 追加到 srcds 命令行(高级) | 重启容器 |
| `TZ` | `UTC` | 时区(`Asia/Shanghai`) | 重启容器 |

**改完 .env 必须重启**:
```bash
$EDITOR /opt/cs2-server/.env
cd /opt/cs2-server && docker compose restart cs2
```

---

## 5. 更新操作

### 5.1 CS2 游戏更新(Valve 推补丁)

**自动模式(推荐,日常无需操作)**:
- 每次容器启动,`entrypoint.sh` 跑 `steamcmd +app_update 730 validate`
- 小补丁:几秒-几分钟,玩家无感
- 大补丁(罕见,1-3 月):10-30 分钟,容器启动会卡一会

**手动触发 validate(不重启容器)**:
```bash
docker exec cs2-server /opt/steamcmd/steamcmd.sh \
  +force_install_dir /opt/cs2 +login anonymous \
  +app_update 730 validate +quit
```

**完全强制重下(CS2 损坏/版本冲突)**:
```bash
docker compose down
sudo rm -rf /mnt/cs2-install/cs2/*     # 清空数据盘上的 CS2
docker compose up -d                    # entrypoint 看到空目录,重新下 20-30 min
docker compose logs -f cs2
```

### 5.2 插件更新(MatchZy / cs2-WeaponPaints)

**流程:本地改 zip → git push → 服务器 pull + restart**

```bash
# 1) 本地:替换 zip
cd /Users/ryan/Documents/cc-pro/cs2-server-building
# 手动:浏览器去 release 页面下载新 zip 到 cs2/plugins/matchzy.zip
# 或 curl:
curl -fsSL -o cs2/plugins/matchzy.zip <新版本 release URL>
sha256sum cs2/plugins/matchzy.zip   # 验证完整性

# 2) 提交 + push
git add cs2/plugins/matchzy.zip
git commit -m "升级 MatchZy 到 0.8.16"
git push
# CI 3-5 分钟构建完(有 cache)

# 3) 服务器:拉新镜像 + 重启
ssh user@SERVER
cd /opt/cs2-server
docker compose pull
docker compose up -d
docker compose logs -f cs2 | grep -E "MatchZy|loaded"
```

**没有新版本但想改 MatchZy/WeaponPaints 配置?**
- 见 §3 的"配置位置全表"
- MatchZy 的 `config.cfg` 改完可以**热加载**(不重启容器):
  ```bash
  # 进游戏控制台(管理员),或 RCON:
  exec MatchZy/config.cfg
  ```
- 改完 admins.json 或 plugin DLLs → 仍然需要 `docker compose up -d` 重启

### 5.3 CounterStrikeSharp / Metamod 更新(框架)

跟 §5.2 一样,改 zip + push:
```bash
curl -fsSL -o cs2/plugins/css-with-runtime.zip <CSS 新版 release URL>
curl -fsSL -o cs2/plugins/mmsource.tar.gz <Metamod 新版 URL>
git add . && git commit -m "升级 CSS 1.0.371" && git push
```

**注意**:CS2 大版本 + 框架升级可能不兼容。升级前看 GitHub Issues,等社区确认。

### 5.4 base image 更新(ubuntu 24.04 / SteamCMD)

`Dockerfile` 改 `FROM ubuntu:24.04` 标签(比如 `ubuntu:24.10`)→ push → CI rebuild。

**不推荐随便升级 base image**:CS2 服务器对 glibc 版本敏感,ubuntu 太新可能跑不起来。**保持 `ubuntu:24.04` 至少到 26.04 LTS**。

### 5.5 创意工坊地图

**单地图**:
```bash
# .env
CS2_AUTHKEY=<你的 Steam Web API key,https://steamcommunity.com/dev/apikey>
CS2_HOST_WORKSHOP_MAP=123456789   # 地图 ID
docker compose restart cs2
```

**合集(Collection)**:
```bash
CS2_WORKSHOP_COLLECTION=987654321   # 合集 ID
docker compose restart cs2
```

两者冲突时优先合集。

---

## 6. 日常运维命令

```bash
# ---- 服务状态 ----
docker compose ps                     # 看容器运行状态
docker compose logs -f cs2            # CS2 实时日志
docker compose logs -f mysql          # MySQL 实时日志
docker compose logs --tail=200 cs2    # 最近 200 行

# ---- 重启 ----
docker compose restart cs2            # 重启 CS2(常用)
docker compose restart mysql          # 重启 MySQL
docker compose up -d                  # 应用配置变更后
docker compose down                   # 停所有
docker compose up -d                  # 启动

# ---- 资源使用 ----
docker stats                          # 实时 CPU/内存/网络
docker system df                      # 镜像/卷占用
df -h /mnt/cs2-install                # 数据盘使用
du -sh /opt/cs2-server/cs2-serverdata # 命名卷大小

# ---- 进容器调试 ----
docker exec -it cs2-server bash       # 进 CS2 容器
docker exec -it cs2-mysql bash        # 进 MySQL 容器
docker exec -u steam cs2-server bash  # 以 steam 用户身份进(配置编辑建议)

# ---- 文件编辑(用主机 vim/VSCode) ----
# 所有命名卷 + bind mount 都实时双向同步,直接编辑主机文件
vim /opt/cs2-server/cs2-serverdata/counterstrikesharp-configs/plugins/WeaponPaints/WeaponPaints.json
docker compose restart cs2   # 改完记得重启
```

---

## 7. MatchZy / cs2-WeaponPaints 命令速查

### 7.1 玩家命令(任意玩家可用)

| 命令 | 说明 |
|---|---|
| `!ready` / `!unready` | 准备 / 取消准备(MatchZy) |
| `!pause` / `!unpause` | 暂停 / 取消暂停 |
| `!tac` | 战术暂停 |
| `!stop` | 停止比赛 + 回滚 |
| `!knife` | 打开刀选择菜单(WeaponPaints) |
| `!skins` / `!ws` | 打开武器皮菜单 |
| `!gloves` | 打开手套菜单 |
| `!agents` | 打开角色(agent)菜单 |
| `!wp` | 同步武器皮(进服后或改完皮后用) |
| `!pins` / `!music` | 徽章 / 音乐盒菜单 |

### 7.2 管理员命令(SteamID 在 `admins.json` 里)

| 命令 | 说明 |
|---|---|
| `.match` | 进入 match 模式(可加载比赛) |
| `.pug` | 进入 PUG 模式 |
| `.prac` | 进入练习模式 |
| `.map <mapname>` | 切图 |
| `.rcon <cmd>` | 在 MatchZy 里执行 srcds RCON |
| `.asay <msg>` | 管理员广播 |
| `.forcepause` / `.fup` | 强制暂停 / 强制恢复 |
| `.readyall` / `.unreadyall` | 强制全员 ready / unready |
| `.whitelist` | 切换白名单模式 |
| `.playout` | 切换打满 BO 模式 |
| `.roundknife` | 切换刀战 |
| `.ban <steamid64> [duration] [reason]` | 封禁 |
| `.unban <steamid64>` | 解封 |

详细见 https://shobhit-pathak.github.io/MatchZy/commands/

### 7.3 加载一场比赛

```bash
# 准备 match 配置文件 (JSON)
# 例子: /opt/cs2-server/cs2-serverdata/csgo/MatchZy/match.json
cat > /tmp/match.json <<EOF
{
  "matchid": "demo-001",
  "team1": {"name": "Team A", "players": []},
  "team2": {"name": "Team B", "players": []},
  "num_maps": 1,
  "maplist": ["de_dust2"]
}
EOF

# RCON(管理员)
matchzy_loadmatch_url "file:///opt/cs2-server/cs2-serverdata/csgo/MatchZy/match.json"
```

或从 URL 加载:`matchzy_loadmatch_url "https://example.com/match.json"`

---

## 8. RCON 操作

### 8.1 启用 RCON

已在 docker-compose 暴露 27015 TCP,`CS2_RCON_PASSWORD` 在 `.env`。CS2 客户端连进服后,按 `~` 打开控制台,直接输命令。

### 8.2 从服务器命令行用 RCON

需要 `netcat-openbsd` 一次性安装:
```bash
docker exec cs2-server bash -c 'apt-get install -y --no-install-recommends netcat-openbsd'
```

用:
```bash
RCON='printf "status\n" | nc -q1 127.0.0.1 27015'
# 或写入脚本(避免每次输密码)
cat > /usr/local/bin/cs2-rcon <<'EOF'
#!/bin/bash
PASS=$(grep CS2_RCON_PASSWORD /opt/cs2-server/.env | cut -d= -f2)
echo "$@" | nc -q1 127.0.0.1 27015
EOF
chmod +x /usr/local/bin/cs2-rcon
cs2-rcon status
cs2-rcon "css_plugins list"
cs2-rcon "matchzy_loadmatch_url https://example.com/match.json"
```

### 8.3 常用 RCON 命令

| 命令 | 说明 |
|---|---|
| `status` | 服务器状态、玩家列表、ping |
| `meta list` | 列出 Metamod 插件(CSS 在不在) |
| `css_plugins list` | 列出 CSS 插件(MatchZy/WeaponPaints/MenuManager/PlayerSettings/AnyBaseLib) |
| `css_plugins info MatchZy` | MatchZy 详细信息 |
| `changelevel de_dust2` | 切图(基础切图) |
| `map de_inferno` | 切图(另一种语法) |
| `exec server.cfg` | 重新加载 server.cfg |
| `exec MatchZy/config.cfg` | 热加载 MatchZy 配置 |
| `matchzy_loadmatch_url <url>` | 加载 match JSON |
| `matchzy_get_match` | 查看当前 match 状态 |
| `matchzy_endmatch` | 强制结束当前 match |
| `wp_reload` | 重新加载 WeaponPaints(改完配置后) |
| `wp_command_kill` | 触发玩家自杀(改完刀皮后) |
| `cvarlist` / `cvarlist \| grep mp_` | 列出 cvar |
| `kick <steamid64>` | 踢人 |
| `banid <duration> <steamid64>` | 封禁 |
| `exit` | 关服(不推荐,直接 docker compose stop 更稳) |

---

## 9. 数据库操作

### 9.1 进 MySQL

```bash
docker exec -it cs2-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
# 或从 .env 读:
docker exec -it cs2-mysql mysql -uroot -p"$(grep MYSQL_ROOT_PASSWORD /opt/cs2-server/.env | cut -d= -f2)"
```

### 9.2 看 WeaponPaints 数据

```sql
USE weaponpaints;
SHOW TABLES;
-- 通常有 wp_player_skins, wp_player_knife, wp_player_gloves, wp_player_agents
SELECT * FROM wp_player_skins LIMIT 10;
```

### 9.3 看 MatchZy 统计

```sql
USE matchzy;
SHOW TABLES;
-- matchzy_stats_matches, matchzy_stats_players
SELECT * FROM matchzy_stats_matches ORDER BY id DESC LIMIT 5;
```

### 9.4 直接改 WeaponPaints 配置(应急)

```sql
-- 给某个 SteamID 强制设某把武器的皮
INSERT INTO wp_player_skins (steamid, weapon_defindex, paint_id, seed, wear) 
VALUES ('76561198000000000', 9, 38, 100, 0.05)
ON DUPLICATE KEY UPDATE paint_id=38, seed=100, wear=0.05;
-- weapon_defindex: 9=AK47, 60=M4A1-S, 1=Deagle, 等
-- paint_id 在 https://bymykel.github.io/CSGO-API/api/ 查
```

改完告诉玩家 `!wp` 同步。

---

## 10. 备份与恢复

### 10.1 备份什么

**重要数据**:
1. `/opt/cs2-server/.env` —— **最关键**,凭据都在这
2. `/opt/cs2-server/cs2-serverdata/` —— 命名卷(配置 / demo / 统计)
3. `/var/lib/docker/volumes/cs2-server_mysql-data/` —— MySQL 数据(皮 + 比赛统计)
4. `/mnt/cs2-install/cs2/` —— CS2 游戏文件(可重下,可备份以加速)

**不重要的**:
- 镜像本身(GHCR 有)
- 插件 zip(`cs2/plugins/`,git 跟踪)
- 临时日志

### 10.2 备份脚本

```bash
# /opt/cs2-server/scripts/backup.sh
#!/bin/bash
set -e
BACKUP_DIR=/opt/cs2-backups/$(date +%F)
mkdir -p $BACKUP_DIR

# 1. .env
cp /opt/cs2-server/.env $BACKUP_DIR/

# 2. cs2-serverdata(配置 + demo)
docker run --rm \
  -v cs2-server_cs2-serverdata:/src:ro \
  -v $BACKUP_DIR:/dst \
  alpine:3.20 tar czf /dst/cs2-serverdata.tgz -C /src .

# 3. MySQL
docker exec cs2-mysql mysqldump -uroot -p"$(grep MYSQL_ROOT_PASSWORD /opt/cs2-server/.env | cut -d= -f2)" \
  --all-databases | gzip > $BACKUP_DIR/mysql.sql.gz

echo "Backup: $BACKUP_DIR"
ls -lah $BACKUP_DIR
```

### 10.3 恢复

```bash
# .env
cp /opt/cs2-backups/2026-07-02/.env /opt/cs2-server/

# cs2-serverdata(命名卷)
docker run --rm \
  -v cs2-server_cs2-serverdata:/dst \
  -v /opt/cs2-backups/2026-07-02:/src:ro \
  alpine:3.20 tar xzf /src/cs2-serverdata.tgz -C /dst

# MySQL
gunzip < /opt/cs2-backups/2026-07-02/mysql.sql.gz | \
  docker exec -i cs2-mysql mysql -uroot -p"$(grep MYSQL_ROOT_PASSWORD /opt/cs2-server/.env | cut -d= -f2)"

docker compose restart cs2
```

---

## 11. 故障排查

### 11.1 启动期

| 现象 | 排查 |
|---|---|
| `docker compose up` 卡在 `[entrypoint] CS2 not found at /opt/cs2; downloading` | 正常首次启动,20-30 分钟。看 `docker compose logs cs2` 有 SteamCMD depot 下载进度 |
| `bind mount source path does not exist: /mnt/cs2-install/cs2` | 数据盘没初始化或没 mount。`lsblk`、`df -h /mnt/cs2-install` 验证。`sudo bash cs2/scripts/setup-cloud-disk.sh /dev/vdb` 修 |
| `Connection to Steam servers successful` 卡住 | 服务器出网被限。`curl -I https://steamcdn-a.akamaihd.net` 在容器内测 |
| `[entrypoint] Waiting for MySQL` 超时 | MySQL 容器没起。`docker compose logs mysql` 看密码错还是端口冲突 |

### 11.2 运行时

| 现象 | 排查 |
|---|---|
| `!knife` 无响应 | WeaponPaints 没连 MySQL。`docker exec cs2-server bash -c 'cat /opt/cs2/game/csgo/addons/counterstrikesharp/configs/plugins/WeaponPaints/WeaponPaints.json' \| jq` 看 DatabasePassword 是否替换了 `${CS2_MYSQL_PASS}` |
| MatchZy 命令不响应 | SteamID 不在 admins.json。`cat /opt/cs2-server/cs2-serverdata/csgo/cfg/MatchZy/admins.json` |
| `meta list` 没 CSS | 镜像 pull 不对。`docker pull ghcr.io/ryannhasacat/cs2-dedicated:latest` 重试 |
| 改完配置没生效 | §3 表查"生效时机"。配置改了没重启 / 没热加载 |
| 玩家搜不到服务器(公网) | 没 GSLT。`https://steamcommunity.com/dev/managegameservers` 申请,填 `.env` |
| 创意工坊地图 404 | `CS2_AUTHKEY` 没填,或合集设为 private |

### 11.3 性能

| 现象 | 排查 |
|---|---|
| 内存爆 | 8G 限制可能在 5v5 满员时不够。看 `docker stats`,若常驻 7G+,`docker-compose.yml` 里把 `memory: 8G` 调高 |
| CPU 高 | `top` 看是不是某个玩家脚本插件 |
| 帧率低(tick 跳) | `net_graph 1` 客户端看 loss/choke。服务器:查 `tv_maxclients`、`mp_maxplayers` |
| MySQL 慢 | `docker exec cs2-mysql mysql -e "SHOW PROCESSLIST"` |

### 11.4 数据盘

| 现象 | 排查 |
|---|---|
| `df -h /mnt/cs2-install` 显示已满 | CS2 30G + plugin data 顶多 35G。50G 盘应该够。如果满:`du -sh /mnt/cs2-install/cs2/*` 看哪个目录大 |
| 数据盘不挂载 | `/etc/fstab` 用了 UUID。VM 重启后磁盘 ID 可能变(Aliyun 数据盘 UUID 是稳定的,但 fstab 写法要对)。`lsblk` + `blkid` 验证 |

---

## 12. 凭证轮换

### 12.1 什么时候轮换

- **怀疑泄露**(commit 过、贴在 Issue 上、log 截图)
- **定期**(建议每 3-6 月,虽然麻烦但安全)
- **人员变动**(admin 离职、共享账号结束)

### 12.2 轮换清单

| 凭证 | 轮换步骤 |
|---|---|
| **CS2_RCON_PASSWORD** | 改 `.env` → `docker compose restart cs2`。分发新密码给 admin |
| **CS2_ADMIN_STEAMID** | 改 `.env` → `docker compose restart cs2` |
| **MYSQL_ROOT_PASSWORD** | (1) `docker exec -it cs2-mysql mysql -uroot -p"旧密码" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '新密码';"` (2) 改 `.env` `MYSQL_ROOT_PASSWORD` (3) `docker compose restart` |
| **MYSQL cs2 用户密码** | (1) `docker exec -it cs2-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "ALTER USER 'cs2'@'%' IDENTIFIED BY '新密码';"` (2) 改 `.env` `CS2_MYSQL_PASS` (3) `docker compose restart cs2` |
| **CS2_GSLT** | https://steamcommunity.com/dev/managegameservers 撤销 → 重新生成 → 改 `.env` → restart |
| **CS2_AUTHKEY** | https://steamcommunity.com/dev/apikey 撤销 → 重新生成 → 改 `.env` → restart |
| **GitHub PAT** (如使用) | https://github.com/settings/tokens → 撤销 → 重新生成 |

**轮换后必做**:
- 更新本地 `.env`(有 .env 副本的话)
- 确认新凭证能用(`docker compose logs cs2 | grep -E "MatchZy|loaded"`)
- **永远不要 commit 新 .env 到 git**

---

## 13. 灾难恢复

### 13.1 VM 被误释放(数据盘还在)

```bash
# 新 VM:在云控制台把数据盘 attach 过来
sudo bash /opt/cs2-server/cs2/scripts/setup-cloud-disk.sh /dev/vdb
docker compose pull
docker compose up -d
# entrypoint 看到 CS2 已存在 → validate 几秒就绪
```

### 13.2 数据盘也被释放了(最坏情况)

CS2 完全丢失 → 重建流程:
```bash
# 数据盘重建(重新走 setup)
sudo bash /opt/cs2-server/cs2/scripts/setup-cloud-disk.sh /dev/vdb
# 空的数据盘 → 容器启动时 SteamCMD 重下 20-30 min

# MySQL 重建
docker compose down
docker volume rm cs2-server_mysql-data
docker compose up -d   # init.sql 重新 CREATE DATABASE
# 玩家的皮选择全部丢失
```

### 13.3 镜像完全坏(回滚)

```bash
# 1. 看历史 tag
docker exec cs2-mysql mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases > /tmp/db-backup.sql

# 2. 服务器:指定旧 tag
docker compose pull
# 改 docker-compose.yml 把 image 改成旧 tag(看 GHCR 有什么 tag)
# https://github.com/Ryannhasacat/cs2-server-ci/pkgs/container/cs2-dedicated
docker compose up -d

# 3. 数据保留在 cs2-serverdata + 数据盘,镜像回滚不影响
```

### 13.4 完全重部署

如果是新机器 / 全新环境:
- 按 README §2 + §7 完整流程走一遍
- 从备份恢复 `.env` 和 `cs2-serverdata` / `mysql-data`
- 数据盘 attach 后 `setup-cloud-disk.sh`

---

## 附录:快速参考卡

```bash
# === 状态 ===
docker compose ps
docker compose logs --tail=50 cs2

# === 重启 ===
docker compose restart cs2

# === 改配置 ===
$EDITOR /opt/cs2-server/.env                          # 改 env
$EDITOR /opt/cs2-server/cs2-serverdata/csgo/cfg/MatchZy/config.cfg
docker compose restart cs2

# === RCON ===
echo "status" | nc -q1 127.0.0.1 27015
echo "css_plugins list" | nc -q1 127.0.0.1 27015

# === 进容器 ===
docker exec -u steam -it cs2-server bash
docker exec -it cs2-mysql bash

# === 更新 CS2(强制) ===
sudo rm -rf /mnt/cs2-install/cs2/*
docker compose up -d

# === 更新插件 ===
# 本地:替换 cs2/plugins/*.zip → git push
# 服务器:cd /opt/cs2-server && docker compose pull && docker compose up -d

# === 数据库 ===
docker exec -it cs2-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD"

# === 备份 ===
docker exec cs2-mysql mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases | gzip > /opt/cs2-backups/db-$(date +%F).sql.gz

# === 凭据轮换 ===
$EDITOR /opt/cs2-server/.env
docker compose restart cs2
```

---

## 文档维护

- 本文档跟代码一起在 git
- 改完配置**记得回来更新对应章节**(尤其是 §3 配置文件位置全表)
- 发现新问题 → 加到 §11 故障排查
- 三个月回看一次,清理过期信息
