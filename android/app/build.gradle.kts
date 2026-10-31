plugins {
    id("com.android.application")
}

android {
    namespace = "com.phonetrackpad.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.phonetrackpad.app"
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
