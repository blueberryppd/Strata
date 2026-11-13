# Strata Duo：两台 Mac 合跑一个 DeepSeek V4.1 Flash 模型

> **实验性质。** Strata Duo 是 [Strata](https://github.com/Niko1221/Strata) 0.2.10 的一个分支（fork）。它只在一对机器上
> 测试过（见[实测结果](#实测结果)）。它不是上游 Strata 的一部分，也不会自动跟随上游的新版本。

English: [DUO.md](DUO.md)（以英文版为准）

## 目录

1. [它是什么，不是什么](#它是什么不是什么)
2. [工作原理](#工作原理)
3. [硬件和软件要求](#硬件和软件要求)
4. [从零开始安装](#从零开始安装)
5. [日常使用](#日常使用)
6. [配置项说明](#配置项说明)
7. [按需加载的入口程序（gate）](#按需加载的入口程序gate)
8. [切换模型精度](#切换模型精度)
9. [实测结果](#实测结果)
10. [限制](#限制)
11. [安全说明](#安全说明)
12. [故障排查](#故障排查)
13. [运行测试](#运行测试)
14. [代码结构](#代码结构)
15. [来源、致谢和许可证](#来源致谢和许可证)

## 它是什么，不是什么

DeepSeek V4.1 Flash 是混合专家（MoE）模型。它量化后的专家权重比一台 96 GB Mac 的内存还大。这样的 Mac 无法把专家权重
全部常驻内存，所以 Strata 的 DeepSeek 引擎每生成一个 token 都要从 SSD 读一部分专家，或者在 CPU 上现算，速度就受限于此。

Strata Duo 把模型**按层**拆到两台 Mac 上。两台 Mac 都加载同一份模型文件，但各自只把自己那一半层留在内存里：
*前半主机（prefix host）* 运行第 0-19 层，*后半主机（suffix host）* 运行第 20-39 层。每台只管一半专家，两台 96 GB 的 Mac
就能让几乎全部专家常驻内存。两个引擎通过雷雳线上的一条加密连接通信。对客户端来说，这一对机器就是一个兼容 OpenAI 接口的服务。

它是：

- 对 Strata 的 DeepSeek V4.1 Metal 引擎（`strata_ds4`）的一个补丁：五个文件，新增约 1,250 行；
- [`duo/`](../duo) 目录里的一组 shell 和 Python 工具：编译引擎、生成证书、启动和停止这一对机器、检查安装
  （`duo.sh doctor`）、按需加载模型；
- 一组测试，其中一部分不需要模型就能运行。

它不是：

- 通用集群，也不是把多台机器的内存合并起来的办法：只支持两台主机；
- 对单台 Mac 内存本来就放得下的模型的加速手段；
- Strata 的功能。Strata App 不知道它的存在，App 里看不到这个模型。

## 工作原理

```
   客户端（任何兼容 OpenAI 接口的程序）
      |  http://127.0.0.1:8080  （需要 API 密钥）
      v
+---- 本机（运行 duo.sh 的这台）--------------+        +---- 另一台 Mac（PEER）---------------------+
|                                             |        |                                            |
|  入口 gate  duo_gate.py   127.0.0.1:8080    |        |                                            |
|    | 第一个请求到来时加载这一对；           |        |                                            |
|    | 闲置 IDLE_MIN 分钟后卸载               |        |                                            |
|    v                                        |        |                                            |
|  127.0.0.1:8081 ======= 带端口转发的 ssh 会话 =======>  Strata API 服务（serve.server）           |
|                                             |        |             127.0.0.1:8080                 |
|                                             |        |                |  启动并驱动               |
|                                             |        |                v                           |
|  前半引擎  strata_ds4 --duo-listen          |        |  后半引擎  strata_ds4 --duo-connect        |
|    第 0-19 层、Engram 行                    |<======>|    第 20-39 层、输出头、采样               |
|                                             |  链路  |                                            |
+---------------------------------------------+        +--------------------------------------------+
        链路 = 雷雳线上的一条 TCP 连接，TLS 1.3，双向认证
```

上图是实测时的布局（`duo.conf` 里 `LOCAL_ROLE=prefix`）。两个角色可以对调（`LOCAL_ROLE=suffix`：API 服务在本机运行，
另一台运行前半引擎），见[没有测试过的](#没有测试过的)。

每生成一个 token，后半主机把新的 token 编号发给前半主机。前半主机跑完自己的 20 层，把*交接数据（hand-off）* 发回来：
隐藏状态和下一层需要的几个附带数组，每个 token 约 92 KB。后半主机再跑自己的 20 层、输出头和采样，把 token 交给 API 服务。
长提示词不是逐个 token 发送的：它按每块 2048 个 token 分块通过，两台 Mac 同时处理。

两个引擎是同一个程序，用同一个模型包（pack）。连接时双方比较一个身份字符串（引擎版本、模型结构、模型文件的名字和大小、
切点、上下文大小、分块大小），不一致就拒绝配对。

服务端搁置的会话（这样切回去时不必重读提示词）把两台主机各自的一半状态存成后半主机上的一个文件。前半主机重启不会丢东西。

## 硬件和软件要求

硬件：

- 两台 Apple Silicon Mac。测试过的：两台 Mac Studio M5 Ultra，各 96 GB。其他机型和内存大小没有测试过。
- 两台之间一根雷雳线（测试过的：雷雳 5）。其他连接方式没有测试过。
- **每台** Mac 的内置盘或其他高速盘上都要有完整的模型文件：某一精度的四个 GGUF 分片，加上 Engram GGUF（以及模型包引用的
  drafter 文件）。文件大小见 Strata 自己的文档 [DEEPSEEK41.md](DEEPSEEK41.md) 和 [DEEPSEEK_MAC.md](DEEPSEEK_MAC.md)。

软件：

- 两台都是 macOS（测试过的：macOS 27），装有 Xcode 命令行工具（`xcode-select --install`）。不需要 Homebrew，不需要 sudo。
- 另一台 Mac 打开「远程登录」（ssh），本机能用密钥免密码 ssh 过去。
- 后半主机上要有 Strata 的 control 目录（里面有 `serve/server.py` 的那个文件夹）和它自带的 Python。实测用的是
  Strata 0.2.10 App 里的那一份（`Strata.app/Contents/Resources/control`）。其他 Strata 版本没有和这个引擎一起测试过。
- 编译时两台 Mac 都要能上网（下载 Apple 的 metal-cpp 头文件、固定提交的 llama.cpp、OpenSSL 3.5.9，以及在你没有
  cmake 和 ninja 时下载它们）。

## 从零开始安装

「本机」指你运行 `duo/duo.sh`、客户端连接的那台 Mac。「另一台」通过 ssh 访问。实测布局里本机是前半主机。
下面的例子在两台 Mac 上都用 `~/strata-duo` 作安装目录，用 `user@other-mac.local` 指另一台 Mac；请换成你自己的。
安装目录的路径里不要有空格（编译脚本会拒绝）。

### 1. 接线

用雷雳线把两台 Mac 连起来。在「系统设置 > 网络」里，两台都应该出现「雷雳网桥」，并带有一个自分配地址（169.254.x.y）。
不需要手动配置地址：`duo.sh` 每次启动都会重新查找，因为自分配地址在重启后会变。

### 2. 在另一台 Mac 上打开远程登录

在另一台 Mac 上：系统设置 > 通用 > 共享 > 远程登录：打开。

### 3. ssh 密钥

在本机：

```sh
ssh-keygen -t ed25519                  # 只有在你还没有密钥时才需要
ssh-copy-id user@other-mac.local
ssh -o BatchMode=yes user@other-mac.local true && echo ok     # 必须不问密码直接打印 "ok"
```

第一次连接会让你确认另一台 Mac 的主机密钥。请手动确认一次。

### 4. 在两台 Mac 上克隆

```sh
xcode-select --install                 # 只需一次，如果还没装命令行工具
git clone -b strata-duo <本仓库的地址> ~/strata-duo
```

在另一台 Mac 上做同样的事。两台必须是同一个提交（commit）。

### 5. 在两台 Mac 上编译

```sh
cd ~/strata-duo
duo/build.sh
```

它会下载依赖，把静态的 OpenSSL 编译到 `.duo-deps/`，把引擎编译到 `build-duo/strata_ds4`。第一次最慢，因为还要编译 OpenSSL。结束时会打印
引擎版本，例如 `strata-dsv41 0.1.56-metal build 0123abcde`。在另一台 Mac 上运行同样的两条命令。每台 Mac 必须自己编译：
二进制文件里记着它所在的检出目录（它从那里的 `metal/kernels` 加载 Metal 内核），所以编译后不要移动或删除这个目录。

以后要在这一对机器运行期间重新编译，请编译到另一个目录（`duo/build.sh build-duo-next`），在 `duo.conf` 里设
`BUILD=build-duo-next`，再运行 `duo/duo.sh restart`。脚本拒绝覆盖正在运行的二进制文件。

### 6. 证书

在本机：

```sh
duo/gen_certs.sh
```

它写出 `duo/certs-new/prefix/`、`duo/certs-new/suffix/` 和 `duo/certs-new/ca/`，并打印每个文件夹该怎么处理。
对于实测布局（本机是前半主机）：

```sh
mkdir -p duo/certs && chmod 700 duo/certs && cp -p duo/certs-new/prefix/* duo/certs/
ssh user@other-mac.local 'mkdir -p ~/strata-duo/duo/certs && chmod 700 ~/strata-duo/duo/certs'
scp -p duo/certs-new/suffix/* user@other-mac.local:strata-duo/duo/certs/
rm -rf duo/certs-new/prefix duo/certs-new/suffix
```

然后把 `duo/certs-new/ca/ca.key` 移到离线存储，或者删掉（`rm -P duo/certs-new/ca/ca.key`）。两台 Mac 运行时都不需要它。
见[安全说明](#安全说明)。

### 7. 两台 Mac 上的模型文件和模型包

按 [`duo/make_pack.md`](../duo/make_pack.md) 操作。简单说：在一台 Mac 上让 Strata 自己的启动器下载模型并生成*模型包*，
把模型文件和模型包文件夹复制到另一台 Mac，在那里运行 `duo/pack_relocate.py`，让模型包指向那台 Mac 上的文件。

### 8. 配置

```sh
cp duo/duo.conf.example duo/duo.conf
chmod 600 duo/duo.conf
```

编辑 `duo/duo.conf`：至少要填 `PEER`、`PEER_DIR`、`LOCAL_PACK`、`PEER_PACK` 和 `SUFFIX_CONTROL_DIR`。每一项在文件里
和[配置项说明](#配置项说明)里都有解释。

### 9. 体检（doctor）

```sh
duo/duo.sh doctor
```

它不改动任何东西。每项检查打印一行 `PASS`、`FAIL`、`WARN`、`INFO` 或 `SKIP`，每个失败下面有一行 `fix:` 说明怎么修。
反复运行，直到最后一行是 `RESULT: all checks passed`。它检查：配置、免密码 ssh、远程登录、两台 Mac 的引擎是否同一次构建
（比较的是 `strata_ds4 --version` 的输出，其中包含引擎版本和源码提交；文件哈希只作为信息显示，因为每台 Mac 的构建里含有
各自的路径）、证书（是否存在、角色是否正确、是否由同一个 CA 签发、是否过期、私钥权限是否为 600、有没有私钥放错了主机、
引擎自己是否接受这些证书）、模型包和模型文件（两台都有，名字和大小一致）、磁盘剩余空间、端口是否空闲、链路地址。

### 10. 启动

```sh
duo/duo.sh start
```

它先启动入口程序，再加载这一对：先是前半引擎，然后是 API 服务和后半引擎。它会打印链路地址和每个引擎的头几行输出，
等这一对能应答时返回（实测的那一对加载一次大约一分钟）。之后 `duo/duo.sh status` 会显示两个引擎。

### 11. 第一个请求

API 密钥在第一次启动时生成，放在 `duo/run/api_key`（同时在 `duo/run/api_auth.hdr` 里有一行现成的请求头）。
用 curl 时从文件传请求头，这样密钥不会出现在进程列表里：

```sh
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H @duo/run/api_auth.hdr -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","max_tokens":300,"messages":[{"role":"user","content":"用三种语言说你好。"}]}'
```

### 12. 连接兼容 OpenAI 接口的客户端

| 设置 | 值 |
|---|---|
| Base URL | `http://127.0.0.1:8080/v1` |
| API 密钥 | `duo/run/api_key` 文件的内容 |
| 模型 | `deepseek-v4.1-flash` |

支持流式输出。入口程序只监听 127.0.0.1，所以客户端必须在本机运行。要从别的机器访问，请用 ssh 隧道连到本机
（`ssh -L 8080:127.0.0.1:8080 ...`）；不要把端口暴露到网络上。

### 13. 停止

```sh
duo/duo.sh stop
```

两个引擎、API 服务和入口程序都会结束。在下一次 `start` 之前不会自动加载任何东西。

## 日常使用

| 想做什么 | 怎么做 |
|---|---|
| 开启服务（马上加载） | `duo/duo.sh start` |
| 彻底关闭 | `duo/duo.sh stop` |
| 看看在运行什么 | `duo/duo.sh status` |
| 让改过的配置生效 | `duo/duo.sh restart`（改了 `IDLE_MIN` 或 `BUSY_PATTERNS`：先 `stop` 再 `start`） |
| 现在就腾出内存，但保留服务 | `duo/duo.sh down`（下一个请求会重新加载） |
| 测速 | `ROUNDS=8 duo/duo.sh bench` |
| 检查安装 | `duo/duo.sh doctor` |
| 登录后让入口程序自动回来 | 安装 LaunchAgent：[`duo/launchd/README.md`](../duo/launchd/README.md) |

服务开启期间，这一对在闲置 `IDLE_MIN` 分钟后卸载，两台 Mac 都腾出内存。下一个请求会重新加载，大约一分钟后得到回答。
如果任何一台 Mac 重启或链路断开，两个引擎都会结束；下一个经过入口程序的请求会把这一对重新启动。（如果重启的是本机，
入口程序自己得先回来：运行 `duo/duo.sh start`，或者安装 LaunchAgent。）

本机 `duo/run/` 里的文件（都不进 git）：`api_key`、`api_auth.hdr`、`gate.log`、`prefix.log`、`server.log`、
`gate_state.json`、`bench.jsonl`、`.duo_wanted`（服务处于开启状态）、`.duo_starting`（正在加载）。后半主机的 `duo/run/`
里有 `engine.log`、`serve.json`、启动脚本和搁置的会话（`slots-<MODEL>/`）。

## 配置项说明

所有配置都在 `duo/duo.conf`（一个 bash 文件；见 [`duo/duo.conf.example`](../duo/duo.conf.example)）。
`DUO_CONF=/path/to/file` 可以指定另一个文件。

| 配置项 | 默认值 | 含义 |
|---|---|---|
| `PEER` | （必填） | 另一台 Mac 的 ssh 目标（`user@host`，或 `~/.ssh/config` 里的别名） |
| `LOCAL_ROLE` | `prefix` | 本机跑哪一半：`prefix`（第 0-19 层）或 `suffix`（第 20-39 层和 API 服务）。另一台跑另一半 |
| `LOCAL_DIR` | 当前检出目录 | 本机的安装目录 |
| `PEER_DIR` | （必填） | 另一台 Mac 的安装目录（`"~/..."` 在那一台上展开） |
| `BUILD` | `build-duo` | 安装目录里放 `strata_ds4` 的编译目录（两台不同时用 `LOCAL_BUILD`、`PEER_BUILD`） |
| `LOCAL_CERTS`、`PEER_CERTS` | `<安装目录>/duo/certs` | 每台 Mac 的证书目录 |
| `MODEL` | `default` | 你给所加载模型起的标签；用来命名搁置会话的文件夹；可以用在模型包路径里 |
| `LOCAL_PACK`、`PEER_PACK` | （必填） | 每台 Mac 上的模型包文件夹 |
| `MODEL_ID` | `deepseek-v4.1-flash` | 客户端看到的模型名 |
| `VX1`、`VX2` | `0.85`、`0.90` | 前半 / 后半主机上，空闲内存中给常驻专家的比例（`--vram-experts`） |
| `CTX` | `65536` | 上下文大小（token 数） |
| `SUFFIX_CONTROL_DIR` | （必填） | 后半主机上 Strata 的 control 目录（里面有 `serve/server.py`） |
| `SUFFIX_PYTHON` | `<control 目录>/python/bin/python3.12` | 运行 API 服务的 Python |
| `SLOT_DIR` | `<后半主机 run 目录>/slots-<MODEL>` | 服务端存放搁置会话的位置 |
| `IDLE_MIN` | `30` | 闲置多少分钟后卸载；`0`：永不卸载 |
| `BUSY_PATTERNS` | `()` | `pgrep -f` 模式：这些程序运行时不加载这一对（见入口程序一节） |
| `BUSY_MAX_S` | `2400` | 最多等它们多少秒，之后照样加载；`0`：一直等 |
| `APIPORT` | `8080` | 本机入口程序的端口（客户端连这个） |
| `BACKPORT` | `8081` | 本机入口程序后面的端口（隧道的本机一端） |
| `SERVER_PORT` | 同 `APIPORT` | API 服务在另一台 Mac 的 127.0.0.1 上的端口 |
| `PORT` | `50090` | 两个引擎之间链路的端口 |
| `LINK_PREFIX` | `169.254.` | 链路地址的开头，用于自动查找 |
| `LINK_LOCAL_IP`、`LINK_PEER_IP` | （空） | 固定的链路地址，代替自动查找 |
| `MIN_FREE_GB` | `20` | `doctor` 要求每台 Mac 至少剩余的磁盘空间 |
| `LOCAL_RUN`、`PEER_RUN` | `<安装目录>/duo/run` | 日志、密钥和状态文件 |
| `GATE_PYTHON` | `/usr/bin/python3` | 运行入口程序和测速脚本的 Python（3.9 或更新，不需要额外的包） |
| `SSH_OPTS` | `()` | 额外的 ssh 选项 |
| `LAUNCHD_LABEL` | `local.strata-duo.ensure` | 可选的 LaunchAgent 的标签 |

引擎总是带着 `--duo-cut 20 --dspark none --vision off --ssd-cache 0 --profile-readonly` 启动。

## 按需加载的入口程序（gate）

`duo/duo_gate.py` 是一个小型 HTTP 代理（只用 Python 标准库），监听 `127.0.0.1:APIPORT`。它自己不装载模型。

- 这一对处于卸载状态时来了请求，入口程序会运行 `duo.sh up`，等它完成，再把请求转过去。同时到达的多个请求只触发一次加载。
- 连续 `IDLE_MIN` 分钟没有请求，它会运行 `duo.sh down`。
- 卸载状态下 `GET /v1/models` 由入口程序自己回答，所以客户端随时都能看到模型。这个请求不会触发加载。
- 所有请求都需要 API 密钥（`Authorization: Bearer ...` 或 `x-api-key`），只有 `GET /duo/status` 例外，它只返回
  `{"loaded", "loading", "active", "idle_s", "idle_min"}`。
- `POST /duo/unload`（带密钥）立刻卸载这一对。成功时回答 `200 {"unloaded": true}`；有请求正在处理或正在加载时回答 `409`。
  其他需要内存的程序可以在自己启动前调用它：

  ```sh
  curl -s -X POST -H @duo/run/api_auth.hdr http://127.0.0.1:8080/duo/unload
  ```

- `BUSY_PATTERNS`：每一项是一个 `pgrep -f` 模式。只要本机有进程匹配其中一项，入口程序就不加载这一对，请求会等待。
  等满 `BUSY_MAX_S` 秒后照样加载。这些模式只在加载之前检查；如果某个程序是在这一对已经加载之后才启动的，
  它应该自己调用 `/duo/unload`。
- 大于 64 MB 的请求体会被拒绝（`--max-body-mb`）。

## 切换模型精度

这一对同一时间只加载一个模型。要在两种精度之间切换（例如 2.00 和 2.25 bpw），请在两台 Mac 上都保留两套模型文件和两个
模型包，并在 `duo.conf` 的模型包路径里使用标签：

```sh
MODEL=${MODEL:-2.25}
LOCAL_PACK="$HOME/strata-duo/packs/deepseek-v4.1-flash-${MODEL}bpw"
PEER_PACK="~/strata-duo/packs/deepseek-v4.1-flash-${MODEL}bpw"
```

然后修改 `MODEL` 并运行 `duo/duo.sh restart`（或者只切换这一次：`MODEL=2.00 duo/duo.sh restart`；入口程序以后自动加载时
仍然使用文件里的值）。每个标签有自己的搁置会话文件夹。

## 实测结果

下面所有数字都来自同一对机器：**两台 Mac Studio M5 Ultra，各 96 GB，一根雷雳 5 线，macOS 27**。

测法：5 到 8 道中英文混合的题目，每题生成 400 个 token，temperature 0，通过 HTTP API 发送（`duo/bench.py`）。
速度 = 生成的 token 总数 / 总墙钟时间。

| 测量项 | 结果 |
|---|---|
| 单台 Mac，DeepSeek V4.1 Flash 2.00 bpw，使用引擎的内存专家缓存 | 4.10 tokens/s |
| 两台 Mac，2.00 bpw | 12.41 tokens/s，共 30 轮（范围 12.13-12.58） |
| 两台 Mac，2.25 bpw，默认设置 | 12.04 tokens/s，共 8 轮（范围 11.6-12.6） |
| 读入 12,724 token 的提示词（两种精度相同） | 22.7-22.9 秒（约 555-560 tokens/s） |
| 切回一个搁置的 7,600 token 会话 | 2.4 秒；重新读一遍要 17.8 秒 |
| 闲置卸载后的第一个请求 | 60-77 秒后得到回答 |
| 链路断开后的恢复 | 约 80 秒 |
| 链路上的数据量 | 每生成一个 token 约 92 KB |
| 链路的时间开销 | 每个 token 约 0.03-0.15 毫秒 |

没有实现 RDMA，因为链路不是瓶颈。

正确性：把所有被路由到的专家都放在 CPU 通道上（`--vram-experts 0.0`）时，在一台机器上拆分运行的输出与不拆分的引擎
逐 token 一致。窗口路径在默认设置下如此；分块路径在加上 `DS4_SUM_BY_EXPERT=1 DS4_SPEC_WASTE=1e9`
（它们固定了浮点求和的顺序）时如此。

### 没有测试过的

- 其他 Mac 机型或内存大小；
- 多于两台主机；
- Linux；
- 连续数小时的长时间运行；
- 接近 64K 上下文上限的会话；
- 雷雳以外的连接方式。

关于本分支里的工具，还有这些没有测试过：`duo/` 里的脚本是把实测时使用的脚本改写成通用形式得到的。改写后的 `duo.sh`
在一台 Mac 上用替身程序演练过（`duo/tests/duo_sh_selftest.sh`），但**还没有在两台真实的 Mac 上运行过**；
`LOCAL_ROLE=suffix` 这种形式从未在真实硬件上运行过；由 launchd 启动入口程序，以及整机重启后的启动，都没有测试过。

## 限制

- 只支持两台主机。
- 只支持 Apple Silicon 和 Metal。
- 只支持 DeepSeek V4.1 Flash。对这个模型，切点固定在第 20 层。
- 只支持文字（不支持图片）。一次只处理一个请求（`--parallel 1`）。drafter 关闭。
- 在读长提示词的过程中点「停止」，要等这次读完才生效。
- 任何一台主机重启，这一对就必须重启。入口程序会在下一个请求到来时做这件事。
- 基于 Strata 0.2.10（引擎 0.1.56），不会自动跟随上游的新版本。
- 实验性质。

## 安全说明

**威胁模型。** 两台归你所有、由你控制的 Mac，用一根线直连。你网络上的其他设备和其他用户账户不被信任。能以你的用户身份
在任一台 Mac 上运行程序的人是被信任的：他们能读到私钥、API 密钥、日志和搁置的会话。Strata Duo 没有经过独立的安全审计。

**TLS 链路做了什么。** 两个引擎之间的连接传输的是你会话的 token 编号和模型的激活值。它使用 TLS 1.3 并双向认证：
每个引擎持有一张由你的私有 CA 签发的证书，检查对方的证书是否出自同一个 CA、是否带有*另一个角色*
（前半主机只接受 `strata-stage-coordinator`，后半主机只接受 `strata-stage-worker`），其他一律拒绝。前半引擎只监听链路地址，
只接受来自另一台 Mac 链路地址的连接（`--duo-allow`），并且只接一条连接。

**它没做什么。** 它防不住拿到了角色私钥或 CA 私钥的人，也防不住控制了两台 Mac 之一的人。没有吊销机制：如果私钥可能泄露，
请用 `gen_certs.sh` 重新生成一套，并替换两台 Mac 上的文件。两个引擎在认证通过后互相信任；链路协议没有针对
「持有有效证书但行为异常的对端」做过加固。证书会过期（默认 365 天；`doctor` 会提前 30 天警告），过期后这一对无法连接，
直到你生成新的一套。

**私钥的保管。**

- worker 私钥（`strata-stage-worker.key`）绝不能离开前半主机；coordinator 私钥绝不能离开后半主机。`doctor` 发现私钥
  放错主机时会警告。
- CA 私钥请离线保存，或者删除。两台主机都不需要它。有了它就能为你这一对签发新证书。
- 私钥文件权限是 600，所在目录是 700。`certs/`、`certs-new/`、`run/` 和 `duo.conf` 都在 `.gitignore` 里。
- `gen_certs.sh` 在一台 Mac 上生成所有私钥，然后由你通过 ssh 把其中一个角色的文件夹复制到另一台。如果你希望私钥完全
  不经过传输，可以在第三台机器上运行 `gen_certs.sh`，再把两个文件夹分别复制到各自的主机。

**API。** 入口程序和 API 服务只监听 127.0.0.1。API 密钥（48 个十六进制字符，权限 600）在第一次启动时生成，通过 ssh 的
标准输入复制到另一台 Mac，并以环境变量的形式交给服务端。这些工具从不把它放在命令行上；你自己用 curl 时请用
`curl -H @duo/run/api_auth.hdr`。`GET /duo/status` 不需要密钥，只透露这一对是否已加载。

**磁盘上的数据。** 搁置的会话（后半主机上的 `slots-<MODEL>/`）包含会话的 token 和状态，没有加密。`duo/run/` 里的日志
也请当作私密数据对待（其中有路径、地址和时间信息）。

**`duo.conf` 是一个 shell 脚本**，`duo.sh` 会执行它。请保证只有你自己能写它（`chmod 600`）。

**`--duo-insecure`。** 没有 `--duo-certs` 时引擎拒绝打开链路，除非给了 `--duo-insecure`。这个参数选择明文 TCP 连接：
token 编号和激活值不加密，只凭来源地址识别对端。它是为单机回环测试准备的。`duo.sh` 从不使用它。不要在两台机器之间使用它。

## 故障排查

先运行 `duo/duo.sh doctor`：大多数安装问题都会有一行 `FAIL` 并附带修复方法。

| 现象 | 原因和处理 |
|---|---|
| `cannot find the other Mac on the link` | 线没接好，或者某一端的雷雳网桥没有 169.254 地址。检查两台 Mac 的「系统设置 > 网络」。如果用的是固定地址，请设置 `LINK_LOCAL_IP` 和 `LINK_PEER_IP`。 |
| `the prefix host did not start` | 看 `duo/run/prefix.log`。常见原因：模型包路径不对、模型文件缺失（`duo/pack_relocate.py PACK`）、证书问题（引擎的报错会指出是哪个文件）。 |
| `the suffix host failed:` 后面跟着一行 `maya-ds4: duo:` | 两个引擎拒绝配对。`the two hosts differ: here ... there ...` 会显示双方的身份字符串：两台 Mac 在引擎版本、模型文件（名字和大小）、上下文大小或分块大小上不一致。如果是 TLS 相关的报错，说明证书不匹配：两台 Mac 需要用同一次 `gen_certs.sh` 生成的文件。 |
| `the ssh session that holds the server ended` | 看 `duo/run/server.log`。常见原因：`SUFFIX_CONTROL_DIR` 或 `SUFFIX_PYTHON` 不对，或者另一台 Mac 上端口被占用。 |
| 另一台 Mac 上的引擎报 `No route to host` | macOS 不允许脱离登录会话的进程访问本地网络。所以 `duo.sh` 让另一台 Mac 上的进程始终作为一个长期 ssh 会话的子进程。不要通过 ssh 用 `nohup ... &` 手动启动那个进程。 |
| HTTP 401 | 没带 API 密钥或密钥不对。密钥是本机 `duo/run/api_key` 的内容。 |
| HTTP 503 `the pair did not start: ...` | 入口程序没能加载这一对；消息里是 `duo.sh up` 的最后几行输出。手动运行 `duo/duo.sh up` 可以看到全部。 |
| 停顿一段时间后的第一个回答要等一分钟左右 | 这一对在闲置 `IDLE_MIN` 分钟后被卸载了，正在重新加载。设 `IDLE_MIN=0` 可以让它一直保持加载。 |
| `max_tokens` 很小时得到空回答 | 模型的思考过程用光了额度。把 token 上限调大（几百）。 |
| 「停止」停不下长提示词 | 读长提示词过程中的「停止」要等读完才生效（见「限制」）。 |
| 请求等了很久，`gate.log` 里写着 `busy` | 有进程匹配了 `BUSY_PATTERNS` 中的一项。`duo/duo.sh doctor` 会显示是哪一项。 |
| Mac 开始用交换空间或变慢 | 有别的程序需要内存。调低那台 Mac 的 `VX1` 或 `VX2` 后重启这一对，或者把那个程序写进 `BUSY_PATTERNS` 并让它调用 `/duo/unload`。 |
| `the gate did not start` | 别的程序占用了 `APIPORT`。在 `duo.conf` 里换一个端口。 |
| 原来能用，Strata App 升级后不能用了 | Duo 引擎是从这个分支编译的，不会随 App 变化，但 API 服务来自 `SUFFIX_CONTROL_DIR`。请保留一份 0.2.10 的 control 文件夹，并让 `SUFFIX_CONTROL_DIR` 指向它。 |

日志：`duo/run/gate.log`（入口程序）、`duo/run/prefix.log`（前半引擎）、`duo/run/server.log`（ssh 会话和 API 服务），
以及后半主机上的 `duo/run/engine.log`（后半引擎）。

## 运行测试

每个测试证明什么、要多久，见 [`duo/tests/README.md`](../duo/tests/README.md)（英文）。其中四个不需要模型，也不需要第二台 Mac：

```sh
duo/tests/link_smoke.sh              # 只测 TLS 链路，回环，使用测试证书：约 10 秒
python3 duo/tests/gate_selftest.py   # 入口程序对替身程序：约 30 秒
duo/tests/duo_sh_selftest.sh         # duo.sh 对替身程序的完整流程，两种布局：约 2 分钟
duo/tests/doctor_selftest.sh         # 另一台 Mac 连不上时的 doctor：约 20 秒
```

引擎测试（拆分与不拆分的对比、TLS 的反向测试、会话搁置）会在一台 Mac 上把模型加载两次，需要一个内存放得下的模型包。
不要在正在提供服务的 Mac 上运行它们。

## 代码结构

写给想阅读引擎改动、或者想把它移植到其他后端或其他模型的人。`git diff c5ab5d4 -- src metal` 就是全部改动
（c5ab5d4 是本分支所基于的上游提交）。

| 文件 | 内容 |
|---|---|
| `src/dsv41/ds4_duo.hpp` | 链路：消息头和操作码、`Link` 类（监听 / 连接、发送 / 接收）、TLS 上下文和握手检查、`link_policy` 和 `link_preflight`。它不依赖其他部分；`duo/tests/link_bench.cpp` 单独使用它。 |
| `src/dsv41/ds4_model.cu` | 所有和模型有关的部分：`duo_check`、`duo_identity`、`duo_open`、`duo_serve`、层循环里的交接、分块路径（`duo_give_chunk`、`duo_take_chunk`、`duo_serve_chunks`）、会话搁置（`duo_slot_save`、`duo_slot_load`），以及只加载本主机的层。 |
| `src/dsv41/ds4_main.cpp` | `--duo-*` 选项、默认分块大小、前半主机的主循环、这一对的会话搁置文件夹。 |
| `src/dsv41/ds4_model.hpp` | 选项（`duo_role`、`duo_cut`、`duo_addr`、`duo_allow`、`duo_certs`、`duo_insecure`）和两个方法。 |
| `metal/CMakeLists.txt` | `-DSTRATA_DUO_TLS=ON -DSTRATA_DUO_OPENSSL_ROOT=...`：给 `strata_ds4` 静态链接 OpenSSL 3。默认关闭；关闭时构建结果就是上游的，只多了一条对 `--duo-certs` 的拒绝。 |

主要思路，按你需要了解的顺序：

**切点必须在 KV 源层上。** 这个模型里，有些层会写一个压缩的键值存储，后面的层要读它（模型包 `ds4.txt` 里的
`kv_source_layer_ids` 和 `index_source_layer_ids`）。一个层不能去读由另一台主机写的存储。`duo_check` 遍历所有层，
拒绝会把读者和它的源分开的切点。第 20 层是源层，并且正好把 40 层对半分；它也是长提示词跳过（skip）所在的层，
所以后半主机可以和单机一样跳过那些行。`duo.sh` 总是传 `--duo-cut 20`；其他切点没有测试过。

**交接数据（hand-off）。** 从第 19 层交给第 20 层的，就是引擎本来在同一台机器的两块 GPU 之间传递的内容：
`h | pre | topk | cand`（隐藏状态，每个 token 4 x 5120 个浮点数，加上三个小的附带数组），每个 token 92,192 字节。
布局由 `duo_sizes` 给出。前半主机在跑完最后一层后发送；后半主机把它作为自己第一层的输入读入。

**镜像的状态调用。** 服务端只和后半主机打交道。每一个会改变会话状态的调用都会转发给前半主机，由它在自己的层上执行：
`kForward`（一个窗口的 token）、`kReset`、`kCheckpoint`、`kMark`、`kPin`、`kRestore`。其中只有 `kForward` 有应答
（应答是交接数据 `kHand`）。两台主机各自按相同的顺序从自己的层保存恢复点，所以恢复之后两边状态一致。握手过程：
后半主机发送 `kHello` 和自己的身份字符串，前半主机与自己的比较，回答 `kOk`，或者带着双方字符串回答 `kErr`
（`the two hosts differ: here ... there ...`）。

**会话搁置（slots）。** 后半主机上的 `slot_save` 保存自己那一半，向前半主机要它那一半（`kSlotSave` -> `kSlot`），
返回一个整体数据块（`"DS4DUOS1"`、切点、层数、位置、两个大小、两半数据）。`slot_load` 把前半主机那一半发回去
（`kSlotLoad`），再恢复自己那一半。要么两半都装回去，要么都不装；写了一部分之后失败会把两台主机都重置。
搁置数据的身份以 ` duo-cut=K` 结尾，所以单机的搁置数据永远不会被交给一对机器使用。

**分块读提示词。** 对于长提示词，后半主机只发一次 `kChunks`：token、每块的行数、跳过的设置、需要保留的恢复点
（`ChunksPlan`）。前半主机在每一块上跑自己的层，并把这一块的交接行以流的方式发回；后半主机一块一块地处理。
默认每块 2048 行（`--prefill-chunk`，两台主机必须相同）。一轮分块读取不会被「停止」打断。

**只加载本主机的层。** 每一层根据角色和切点被标记为 `foreign`（对方的）或不是；主机不加载对方那些层的稠密权重，
前半主机也不加载输出头。

**链路。** 一条 TCP 连接，一个线程，32 字节的消息头（`magic "DDUO"`、操作码、两个整数、负载大小）加负载。
TLS 就加在这同一条流上。移植到其他后端只需要保持消息格式；移植到其他模型需要一个能通过 `duo_check` 的切点，
以及那个模型的交接数据布局。

## 来源、致谢和许可证

- Strata Duo 基于 Niko1221 和贡献者们的 **Strata**（MIT 许可证），提交 c5ab5d4（App 0.2.10，引擎 0.1.56）：
  <https://github.com/Niko1221/Strata>。Strata 里的 DeepSeek 引擎来自 Project Maya（见
  `third_party/project-maya/NOTICE.md`）。
- 「一个模型跑在两台主机上」的思路和 TLS 传输层的设计，沿用了 **petria** 的 Linux/CUDA stage-RPC 分支
  （<https://github.com/petria/Strata>，分支 `rpc-v0.2.13`）。它的传输层是 TLS 链路的参考实现（TLS 1.3、私有 CA、
  名为 `strata-stage-worker` 和 `strata-stage-coordinator` 的角色证书）。
- 上游 issue **#5298** 是关于多主机运行的需求。
- Duo 的代码和这些文档是用 AI 编程助手编写的，并在[实测结果](#实测结果)所述的硬件上测试。
- 许可证：MIT，与 Strata 相同；见 [`LICENSE`](../LICENSE)。本分支的声明在
  [`third_party/strata-duo/NOTICE.md`](../third_party/strata-duo/NOTICE.md)。
