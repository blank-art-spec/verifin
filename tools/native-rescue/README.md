# Android 原生账本应急导出包

此项目只在 Flutter 应用无法启动、用户需要先抢救本机数据时使用。它是独立的 Android 应用工程，不包含 Flutter 运行时；`applicationId` 和签名证书与 Veri Fin 正式 GitHub 包相同，因此**覆盖安装会保留应用私有数据**。不要卸载原应用，也不要在系统设置里清除数据。

当前应急包的 `versionCode` 为 156，专用于覆盖代码 155 及以下的包。启动后点“选择位置并导出”，通过系统文件选择器保存 `.db` 文件。导出先执行 SQLite `VACUUM INTO`，纳入主库与尚未合并的 WAL 内容；随后对快照运行 `PRAGMA integrity_check`，写出后重新读取文件比较字节数和 SHA-256。只有全部通过才显示成功。失败时原数据库不被迁移或删除。

导出的原始数据库包含账本、交易、附件和自动采集记录等 SQLite 数据，也保留第六批次的表；它**不是**应用内备份 ZIP，不能直接在旧版应用的“恢复备份”入口导入。偏好设置、应用锁及 WebDAV/AI 凭据不在该文件内。恢复时应由开发者在修复后的程序中读取，或在安全环境中从该数据库转换。

## 手动编译

使用与主工程相同的 Android SDK、JDK 17、Gradle 9.1.0 和原项目 `android/app/verifin-release.jks`。本工程的 `local.properties` 和构建目录不提交。只在当前终端设置 `ANDROID_HOME`、`JAVA_HOME`、`VERIFIN_RELEASE_STORE_PASSWORD`、`VERIFIN_RELEASE_KEY_PASSWORD`，然后运行：

```powershell
.\gradlew.bat :app:assembleRelease --offline --no-daemon
```

产物是 `app/build/outputs/apk/release/app-release.apk`。交付前用 `aapt dump badging` 核对包名、版本号和入口，用 `apksigner verify --print-certs` 核对正式证书，用 `zipalign -c -P 16 -v 4` 核对 APK，并确认包内无 Flutter 运行库。没有设备时，不能宣称已完成真机验证。
