plugins {
    id("com.android.application")
}

android {
    namespace = "top.talyra42.verifin"
    compileSdk = 36

    defaultConfig {
        applicationId = "top.talyra42.verifin"
        minSdk = 24
        targetSdk = 36
        versionCode = 156
        versionName = "1.19.7-rescue"
    }

    signingConfigs {
        create("verifinRelease") {
            // 继续使用正式应用的原有密钥，Android 才允许覆盖安装且保留数据。
            storeFile = rootProject.file("../../android/app/verifin-release.jks")
            storePassword = providers.environmentVariable("VERIFIN_RELEASE_STORE_PASSWORD").get()
            keyAlias = "verifin"
            keyPassword = providers.environmentVariable("VERIFIN_RELEASE_KEY_PASSWORD").get()
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("verifinRelease")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
