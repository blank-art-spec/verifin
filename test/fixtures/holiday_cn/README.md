# holiday-cn 真实格式夹具

2026-10-21 从 [NateScarlet/holiday-cn](https://github.com/NateScarlet/holiday-cn) 原样下载：

- `2026.json`：[原始年度文件](https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/2026.json)，完整 39 条记录。
- `2027_unpublished.json`：[2027 年文件](https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/2027.json)，获取时 `papers` 和 `days` 都为空；用于防止把 HTTP 200 的占位文件当成完整年度。
- `LICENSE`：上游 MIT 许可原文及版权声明。

这些文件只用于测试，不打包到生产 APK。负向用例基于独立副本修改字段；固定时钟测试中变换年份的输入均明确标注为隔离测试数据，不能用于生产日历或宣称该年的实际放假安排。上游允许下一年度文件带上一年十二月的修订，且部分“与周末连休”的普通周末可能不单列；解析须保留这两种语义。
