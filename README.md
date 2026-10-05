# Google Send-Zhong Check

逐节点检测代理节点是否「Google 送中」——即访问 `https://www.google.com/` 被重定向到 `https://www.google.com.hk`。

> 仅用于自检自己的网络环境。请勿用于任何违规用途。

## 什么是「送中」

当某个代理出口被 Google 判定为香港 / 中国大陆区域时，访问 `google.com` 会被 302 重定向到
`google.com.hk`，带 `pref=hkredirect`。这会影响部分 Google 服务的地区可用性与结果。

**关键难点**：仅看出口 IP 归属地会误判。同一个节点，出口 IP 可能是美国/日本/新加坡，
但机场线路整体落到香港 Google 入口时，照样送中。因此必须真实请求并读取第一跳 `Location` 头。

## 特性

- 逐节点检测，输出「送中 / 正常 / 不可用」三态
- 输入方式三选一：订阅 URL、本地订阅文件、自动探测 Clash Verge 当前 profile
- **隔离运行**：另起独立 mihomo 实例（独立端口），不影响你正在使用的 Clash
- 结束后自动恢复并关闭独立实例（异常时也清理）
- 支持按地区筛选、输出格式选择
- 零外部依赖（仅用 .NET 内置类 + 本机 mihomo 内核）

## 环境要求

- Windows（PowerShell 5.1+）
- 已安装 Clash Verge / Mihomo（提供 mihomo 内核）
- 能访问订阅地址

## 快速开始

```powershell
# 1) 用订阅 URL 测试
.\src\check-sendzhong.ps1 -SubscriptionUrl "https://example.com/sub"

# 2) 用本地订阅文件测试
.\src\check-sendzhong.ps1 -ProfilePath "D:\sub\config.yaml"

# 3) 什么都不传，自动探测 Clash Verge 当前 profile
.\src\check-sendzhong.ps1

# 4) 只测某个地区 + 输出 Markdown
.\src\check-sendzhong.ps1 -SubscriptionUrl "https://..." -Regions 日本,美国 -Format md
```

运行后会在脚本同目录生成 `report_<时间戳>.txt`（或 `.md`），并在控制台打印摘要。

## 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-SubscriptionUrl` | 空 | 订阅 URL（自动带 Clash UA 下载为 YAML） |
| `-ProfilePath` | 空 | 本地订阅 / Clash YAML 文件路径 |
| `-MihomoPath` | 自动 | mihomo 内核可执行文件路径 |
| `-Regions <string[]>` | 全部 | 只测指定地区（按节点名关键字匹配） |
| `-ExcludeRegions <string[]>` | 香港 | 排除的地区 |
| `-Output <path>` | 脚本目录 | 报告输出路径 |
| `-Format <txt\|md>` | txt | 报告格式 |
| `-TimeoutSec <int>` | 12 | 单次请求超时 |
| `-DelayMs <int>` | 350 | 切节点后的等待 |
| `-MixedPort <int>` | 自动 | 独立实例混合代理端口 |
| `-CtrlPort <int>` | 自动 | 独立实例控制端口 |
| `-KeepInstance` | 关 | 调试用，测完不关实例 |

> 注：`-Regions`/`-ExcludeRegions` 含中文时，请从 PowerShell 会话内调用（而非直接写进 cmd 命令），
> 以免命令行编码导致匹配失败。

## 判定标准

| 响应 | 判定 |
| --- | --- |
| `302 → https://www.google.com.hk/...` | ❌ 送中 |
| `200 OK` | ✅ 正常 |
| `302 → consent.google.com` | ✅ 正常 |
| `302 → google.com.xx`（xx≠hk） | ⚠️ 跳他国 |
| 超时 / 连接失败 | ⚪ 不可用 |

## 工作原理

1. 定位 mihomo 内核，解析订阅来源（URL 下载 / 本地文件 / Clash Verge 自动探测）。
2. 生成**独立配置**（独立端口，DNS 走代理解析），起一个隔离的 mihomo 实例。
3. 枚举节点（排除信息项与默认排除地区）。
4. 逐节点：切换该实例的出口 → 无 Cookie + 禁跟随跳转请求 `google.com` → 读第一跳 `Location`。
5. 输出结果文件 + 控制台摘要，结束后清理独立实例。

**为什么用独立实例**：不修改、不占用你正在使用的 Clash，保证测试不影响日常上网。

## 常见问题

**Q: 找不到 mihomo 内核 / 配置？**
用 `-MihomoPath` / `-ProfilePath` 显式指定。

**Q: 提示订阅不是 Clash YAML？**
订阅可能是 base64 URI 列表。请提供 Clash/YAML 格式的订阅地址或文件。

**Q: 端口被占用？**
工具会自动递增端口；仍冲突可手动指定 `-MixedPort` / `-CtrlPort`。

**Q: 全部节点都 DEAD？**
检查订阅是否可访问、节点是否真正可用、`-TimeoutSec` 是否过小。

## 隐私与安全

- 脚本只读取本机 Clash 配置，**不上传任何数据**到第三方。
- 独立实例使用的订阅凭据仅存在于临时目录，测试结束即删除。
- 报告/实例目录默认被 `.gitignore` 忽略，不会误提交。

## 依赖

- [Mihomo](https://github.com/MetaCubeX/mihomo) / Clash Meta 内核

## 许可

[MIT](LICENSE)