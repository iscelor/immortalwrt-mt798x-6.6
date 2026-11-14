# 802.11v 漫游引导：修复说明

本分支重做了 `802.11v`（BSS Transition Management）漫游引导的整条链路。原来的实现有两类问题：
一类会让路由器直接崩溃重启，另一类会让功能"配了但没反应"。

## 一、原来的问题

### 1. 内核侧：栈上 `argv` + 异步 helper（真正的崩溃根因）

`package/mtk/drivers/mt_wifi/patches/021-add-roam-steering-setting.patch`
往 `MacTableMaintenance()` 里塞了这段：

```c
char path[20]={0};
char arg1[6]={0};
char arg2[24]={0};
char *argv[]={path,arg1,arg2,NULL};
...
call_usermodehelper(path, argv, envp, UMH_NO_WAIT);
```

`call_usermodehelper()` **不会复制** `path`/`argv` 指向的字符串，它只是把指针存进
`subprocess_info`；而 `UMH_NO_WAIT` 意味着 helper 线程在函数返回之后才去读这些指针。
于是 helper 读到的是**已经回收的内核栈**。栈上内容随后会被定时器、软中断、其他函数覆写，
`argv[1]` / `argv[2]` 变成任意值甚至非法地址 —— 这是必然发生的 use-after-return，
不是"概率性竞态"。

再加上 `MacTableMaintenance()` 由 1 秒周期的 MLME 定时器调用（`ap_mlme.c`，注释就写着
`/* one second timer */`），在软中断上下文里 exec 用户态程序本身也不合规。

### 2. 完全没有限速

`Rssi_Updated` 只在表项初始化时被清 `FALSE`，`cmm_asic.c` 置 `TRUE` 之后不再清零，
所以只要弱信号终端还连着，就是**每秒一次** `call_usermodehelper` + 每秒一条
`DBG_LVL_NOTICE` 日志。叠加第 1 点，就是"开 11v → 终端重连 → 再崩 → 无限重启"。

### 3. `pEntry->wdev` 没判空

同一函数其他地方都写成 `if (pEventHdlrHook && pEntry->wdev)`，只有这段直接
`pEntry->wdev->PhyMode`。终端掉线/漫游窗口正好是它被清空的时刻。

### 4. 用户态链路是断的（默认固件）

- `/sbin/steeringsta`、`wapp`、`wappctrl`、`setbssid`、`startwapp.sh` 原属 **`mtwifi-wapp`** 包，
  而 `defconfig/*.config` 里**没有任何一个**选中它 —— 默认固件里这些文件根本不存在，
  驱动 exec 直接 `-ENOENT`，功能静默失效。
- `startwapp.sh` 判"要不要启动 wapp"时只读 `wireless.default_MT7981_1_2.steeringthresold`
  和 `MT7986_1_2`（固定 5G 段名）。只给 2.4G 配阈值 → 判定为"不需要" → wapp 不启动。
- `steeringsta` 里 `case "$1"` 只用来打日志，实际调 `wappctrl` 时硬编码 `ra0`/`rax0`。
- `setbssid` 用 `IFS='/'` 切分候选 BSSID，但 `uci get` 返回的是空格分隔的 list，
  多 BSSID 场景下整串被当成一个 MAC 传给 `wappctrl`。
- `100-startwapp` 是 hotplug 脚本，每次接口事件都 `killall wapp` 再重启，且没有并发保护。

## 二、改了什么

### 驱动（替换 `021-add-roam-steering-setting.patch`）

| 改动 | 说明 |
|---|---|
| 改为 workqueue 延迟执行 | `schedule_work()` 从定时器上下文入队，`call_usermodehelper(..., UMH_WAIT_EXEC)` 在进程上下文执行；helper 字符串放**静态存储**，不再有栈 UAF |
| 单飞 + 限速 | `atomic_cmpxchg` 保证同时只有一个请求；每终端 30 秒冷却（`MTK_STEER_HISTORY` 槽位表） |
| `wdev` 判空 | 触发条件增加 `IS_ENTRY_CLIENT(pEntry) && pEntry->wdev` |
| 真实接口名 | 用 `RTMP_OS_NETDEV_GET_DEVNAME(pEntry->wdev->if_dev)`，不再硬编码 `ra0`/`rax0`，多 BSS 也对 |
| 日志降级 | 触发日志从 `DBG_LVL_NOTICE` 降到 `DBG_LVL_INFO`，且只在真正放行时打印 |
| 越界保护 | `Set_AP_SteeringThreshold_Proc()` 增加 `apidx >= BssidNum` 判断，`os_str_tol` 结果先按 `LONG` 校验再收敛到 `CHAR` |
| 卸载安全 | `os_module_exit()` 里 `cancel_work_sync()`，避免 rmmod 后仍有 work 引用模块代码 |

### 用户态脚本

| 文件 | 改动 |
|---|---|
| `startwapp.sh` | 按配置**推导**是否需要 wapp（device 的 `wapp`/`bandsteering`，iface 的 `steeringthresold<0`/`ieee80211r`），不再依赖固定段名；按 `band` 决定 `-cra0`/`-crax0`；状态文件做幂等，配置没变就不重启 daemon；wapp 起不来时明确报错 |
| `100-startwapp` | 加锁目录串行化 hotplug 事件，重叠事件直接丢弃；清理陈旧锁 |
| `steeringsta` | 校验接口名/MAC 格式；`pidof wapp` 预检；`timeout 3` 包裹 `wappctrl`，避免 daemon 卡死拖住内核 worker |
| `setbssid` | 同时接受空格与 `/` 分隔；逐个校验 MAC；按接口所在频段选择要通告的信道，不再固定读 `MT7981_1_1`/`MT7986_1_1` |

### 打包（Ruijie 式重构）

`wapp`/`bs20`/`wappctrl`/`steeringsta`/`setbssid`/`startwapp.sh`/`100-startwapp` 及配套配置
**全部并入 `mtwifi-cfg` 的安装清单**，并把源码编译的 `package/mtk/libs/openssl1.1`
（OpenSSL 1.1.1w）设为其依赖。只要镜像选了 `mtwifi-cfg`，802.11v 所需的用户态组件就自动
齐备，无需再手工选 `mtwifi-wapp`（该包保留作兼容，内容与 mtwifi-cfg 重复，不必再选）。

## 三、前置条件

无。选了 `mtwifi-cfg` 即全部就绪。固件体积较原先增大约 2 MB
（wapp 约 1.0 MB + bs20 约 0.9 MB + wappctrl 0.24 MB + 压缩后的 openssl 1.1）。

`wapp` / `bs20` / `wappctrl` 是联发科闭源二进制，无法重编；OpenSSL 1.1 为源码编译。

## 四、启用

```bash
# 1. 打开 11v 引导阈值（负值，单位 dBm；0 = 关闭）
uci set wireless.default_MT7986_1_2.steeringthresold='-72'
uci set wireless.default_MT7986_1_1.steeringthresold='-72'

# 2. 填写候选 BSSID：除自己以外、所有参与漫游的 AP 的 MAC，空格分隔
uci set wireless.default_MT7986_1_2.steeringbssid='aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02'

uci commit wireless
wifi reload
```

`startwapp.sh` 会由 hotplug 自动拉起 wapp，不需要再额外勾 `WAPP` 开关
（勾了也只是强制启动，不改变行为）。

## 五、验证

```bash
# wapp 是否在跑、起了哪些接口
ps w | grep -E "wapp|bs20"

# 阈值有没有写进 dat
grep -i steering /etc/wireless/*/*.dat

# 驱动侧是否在触发（限速后 30 秒最多一条，INFO 级）
logread | grep "802.11v steer"

# 用户态是否收到并执行
logread | grep wapp-steering

# 候选 BSSID 是否下发成功
logread | grep wapp-setbssid
```

判断依据：

- 有 `802.11v steer` 但没有 `wapp-steering` → `steeringsta` 执行失败，查内核日志里的
  `steeringsta: cannot execute helper (...)`。
- 有 `wapp-steering` 但 `steer request failed` → wapp 没跑或 `wappctrl` 报错。
- 都成功但客户端不动 → 客户端不支持 BTM，或 `steeringbssid` 没填全。

## 六、回滚

```bash
uci set wireless.@wifi-iface[0].steeringthresold='0'
uci commit wireless && wifi reload
```

`SteeringThreshold=0` 在驱动里就是关闭（触发条件有短路），无需改固件。

## 七、EasyWrt 接入

云编译项目把克隆源指向本 fork 即可，seed 配置无需任何改动（`mtwifi-cfg` 已选中，
wapp 全套会随依赖自动进固件）：

```yaml
# .github/workflows/Build_mt7981_ax3000t.yml 与 Build_mt7986_ax6000.yml 各一处
- name: Clone source code
  env:
    REPO_URL: https://github.com/<你的账号>/immortalwrt-mt798x-6.6
    REPO_BRANCH: fix/80211v
```

注意：本分支基于 lyimoexiao（含其 MT7981 `l1profile.dat` 的 `EEPROM_size=0x200000`
改动）。小米 AX3000T 首刷后请先确认 WiFi 正常，若有异常可把 `REPO_BRANCH` 换成
`fix/80211v-pdv`（基于 padavanonly 原树的同款修复）。
