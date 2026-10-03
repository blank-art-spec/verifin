// 应用版本号展示文案;由 scripts/publish.sh 在发版时自动更新。

const String appVersionLabel = 'v1.19.6+155';

// 仅供紧急恢复包：关闭启动补记、采集处理和自动备份，防止备份前改写现有数据。
const bool isEmergencyRecoveryBuild = true;
