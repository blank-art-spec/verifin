// 应急导出包独立于 Flutter 工程构建，避免应用启动时加载 Flutter 运行时。
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}
