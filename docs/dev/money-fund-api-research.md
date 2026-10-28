# 天天基金货币基金接口验证

验证日期：2026-10-28。本文只记录公开数据接口的实际覆盖和 Android 直连验证，
不表示 Veri Fin 已接入货币基金，也不表示来源已获得正式发布准入。
现有股票来源的范围仍见[公开股票研究](public-quote-research.md)。

**本轮结论：开发机可获取内地对照基金的公开收益和历史；Android WebView 能直接建立
HTTPS 连接，但数据端点返回业务错误 `-999`，取数未通过。指定的香港 B 类基金未找到
可验证的来源代码映射，不能承诺由天天基金提供其万份收益、七日年化或历史数据。**

## 指定标的与数据口径

本次指定标的是**招商美元货币市场基金 B 类**：

- ISIN：`HK0001039582`；
- 币种：USD；
- 彭博代码：`CMSUMMB HK Equity`；
- 管理人：招商证券资产管理（香港）有限公司。

身份依据为[招商证券官方产品页](https://www.cmschina.com.hk/gb/AM/FundProduct?view=NPCF)。
该 ISIN 不能截取、改写为内地六位基金代码，也不能用相似名称的招商内地货币基金替代。

官方按每单位资产净值披露该基金价格；股息是否分派、分派频率和金额由管理人酌情决定。
[官方第六份增补](https://www.cmschina.com.hk/gb/_files/AM/HK/Sixth%20Addendum_chi.pdf)
第 12 页说明每交易日估值及每单位净值披露。
[2026 年 4 月官方月报](https://www.cmschina.com.hk/_files/AM/NPCF/%E6%8B%9B%E5%95%86%E7%BE%8E%E5%85%83%E8%B4%A7%E5%B8%81%E5%B8%82%E5%9C%BA%E5%9F%BA%E9%87%91202604%20CHI.pdf)
展示单位净值和区间表现，未列万份收益、七日年化；其中组合到期收益率不是基金回报。
因此，本次不从净值变化或其他收益率伪造这两项公开指标，也不套用内地每日收益结转模型。

## 实际请求的接口

所有请求均为 HTTPS GET，不带账号、API Key、Cookie、Authorization、账户余额或持仓数量。

| 用途 | 地址及关键参数 | 参数含义 |
| --- | --- | --- |
| 基金身份搜索 | `https://fundsuggest.eastmoney.com/FundSearch/api/FundSearchAPI.ashx?m=1&key=...` | `key` 为 ISIN 或基金名称；结果是模糊候选，必须再次核对身份 |
| 历史货币基金收益 | `https://api.fund.eastmoney.com/f10/lsjz?fundCode=...&pageIndex=1&pageSize=10&startDate=&endDate=` | `fundCode` 是来源认可的代码；页码从 1 开始；日期参数限定查询区间 |
| 最新货币基金收益目录 | `https://api.fund.eastmoney.com/FundRank/GetHbRankList` | 使用 `intCompany=0`、`MinsgType=`、`IsSale=1`、`strSortCol=SYL_1N`、`orderType=desc`、`pageIndex=1`、`pageSize=10000`，用于核对该目录的公开身份和收益字段 |
| 香港基金目录 | `https://overseas.1234567.com.cn/overseasapi/OpenApiHander.ashx` | 使用 `api=HKFDApi`、`m=MethodFundList`、`action=1`、`pageindex=0`、`pagesize=5000`、`dy=1`、`date1=2026-10-28`、`date2=2026-10-28`、`sortfield=Y`、`sorttype=-1`、`isbuy=0` |

请求形状及字段语义参考 AKShare 的一手文档和实现：

- [公募基金文档](https://akshare.akfamily.xyz/data/fund/fund_public.html)：`fund_money_fund_info_em`、`fund_money_rank_em`、`fund_hk_rank_em`；
- [历史收益实现](https://github.com/akfamily/akshare/blob/main/akshare/fund/fund_em.py)：货币基金历史行的 `FSRQ` 是收益日期，`DWJZ` 对应万份收益，`LJJZ` 对应七日年化百分数；不能按普通净值接口的同名字段解释；
- [排行与香港目录实现](https://github.com/akfamily/akshare/blob/main/akshare/fund/fund_rank_em.py)。

这些是网站所用的公开端点，不把开源库可调用等同于数据供应方允许第三方应用正式分发。

## 开发机直接请求结果

Windows 上使用现成 `curl` 完成有界请求，单次不超过 20 秒，验证系统证书，
不跟随重定向；历史和搜索响应上限 512 KiB，目录上限 1 MiB。首次有效的历史请求带
`Referer: https://fundf10.eastmoney.com/`，没有修改 `curl` 默认的 User-Agent。

| 项目 | 实际结果 | 可得出的结论 |
| --- | --- | --- |
| 指定 ISIN 的历史请求 | HTTP 200，`ErrCode=0`，`TotalCount=0`，`LSJZList=[]` | 该请求没有得到指定标的历史数据；HTTP 成功不等于有基金数据 |
| 指定 ISIN 与完整中英文名称搜索 | HTTP 200，但候选没有匹配该基金 B 类身份 | 搜索成功不能把不相关候选当作该基金 |
| 香港目录 | HTTP 200，返回 191 项，`TotalCount=191`、`PageCount=1`；未匹配指定身份 | 本次目录没有提供可验证的目标代码映射；不能据此断言所有东方财富产品均无覆盖 |
| 货币基金目录 | HTTP 200，返回 545 项；未匹配指定身份 | 此目录不能为该 ISIN 提供对应万份收益和七日年化 |
| 内地对照基金 `000009` 历史 | HTTP 200，总计 4,795 条，本次取 10 条 | 端点确实有可用历史数据，指定 ISIN 的空结果不能归因于整个端点不可达 |
| 对照基金最新收益 | `FSRQ=2026-10-27`，万份收益 `0.3101` 元，七日年化 `1.1380%` | 是该时点的来源数据，不作为未来最新值或指定香港基金的数据 |

对照基金为**易方达天天理财货币 A，代码 `000009`**，仅用于检验接口连通和字段，
没有替换用户指定的测试标的，也没有向任何账本写入该基金或收益。

同一历史 URL 在电脑上去掉 Referer 后，返回 HTTP 200、97 字节、`ErrCode=-999`、
`Data=""`。这说明请求格式会影响结果；但 Android 补齐该来源页面请求头后仍失败，
不能仅凭这组电脑对照就把 Android 错误归结为缺少 Referer。

## Android 实际验证

本次按用户选择先验证模拟器，不等待实体手机。复用项目已有 Android 15 / API 35
模拟器 `verifin_x300_lite`（`emulator-5556`），未编译或安装任何新应用。
使用预装 Android WebView 发出 HTTPS 请求；电脑只通过 adb 调试通道读取结果，
不提供数据转发服务或 HTTP 代理。WebView 版本为 `124.0.6367.219`，设备系统
`http_proxy=null`，不把电脑的 HTTP 响应注入设备。

首次受限进程启动的模拟器存在一般 DNS 失败：基金端点与普通 HTTPS 对照页面都报告
`net::ERR_NAME_NOT_RESOLVED`。保留初始证据后，仅停止本次模拟器并在允许联网的
执行环境重启，没有清数据；下面记录的是排除此环境问题后的实际响应。

北京时间 10:30:57–10:31:05，保持真实 Android 移动 User-Agent 的第一轮结果：

| Android 请求 | HTTP 与业务结果 | 数据验收 |
| --- | --- | --- |
| `000009` 历史第一页 | HTTP 200，`ErrCode=-999`、`Data=""`、`TotalCount=0` | 没有 `LSJZList`，未通过 |
| `HK0001039582` 历史第一页 | HTTP 200，同上 | 没有目标历史，未通过；这一响应本身不能用于判断是否收录 |
| 最新货币基金目录 | HTTP 200，同上 | 没有收益目录，未通过 |
| ISIN 搜索 | HTTP 200、`ErrCode=0`，10 条候选均为无关股票 | 精确目标身份匹配为 0 |

北京时间 10:33:02–10:33:03，再对 `000009` 历史进行一次公开请求格式对照，
实际发送 `Referer: https://fundf10.eastmoney.com/jjjz_000009.html`，保持同一真实
Android User-Agent，仍返回 HTTP 200、`ErrCode=-999`、`Data=""`。
没有继续改身份、添加 Cookie/Authorization 或重复请求；数据未通过，未做第二页验证。

以上 API 响应均没有重定向、磁盘缓存或 ServiceWorker，使用系统默认证书校验，
`securityState=secure`、TLS 1.2；没有关闭证书校验。四次数据错误正文均为 97 字节：

```json
{"Data":"","ErrCode":-999,"ErrMsg":"","TotalCount":0,"Expansion":null,"PageSize":0,"PageIndex":0}
```

正文 SHA-256 为 `a9e56b48434e33e0db5abe6376d9f93a14cbe8ac3bcfb26f4979d45711ffe18a`。
来源没有给出 `-999` 的具体原因，因此不能断言是 User-Agent、Referer、浏览器上下文、
访问资格或其他某一个原因，也不把 HTTP 200 当成收益获取成功。

这次确认了 Android 无自有后台的 HTTPS 直连能力，但**没有完成 Android 业务取数验收**。
WebView 的结果不能代替 Flutter `HttpClient` 或实体手机验收；后续如需验证正式客户端，
须准备原生请求入口后按项目约定手动编译，不通过放宽解析或伪造零值掩盖错误。

## 本机证据与实现边界

原始公开响应、HTTP 头、时间和 SHA-256 保存在被 Git 忽略的
`build/validation/money-fund-20261028/`；开发机汇总为 `desktop-summary.json`，
Android 证据位于其 `android/` 子目录，汇总为 `verified-requests-summary.json`，
各请求附 `.body.json`、`.metadata.json`，校验清单为 `sha256-manifest.txt`。
初始 DNS 失败和最终界面截图亦保留。这些文件不包含账目或凭证，不作为历史行情档案。

此次没有修改证券模型、账务计算、持仓、行情准入或发布配置，没有触发编译、推送或发版。
万份收益、七日年化及来源身份缺失时，应保留“不支持/暂无数据”，不得填零或自动记收益。
本次只改研究文档，执行文档差异、路径和本机证据校验，不运行 Flutter analyze/test。
