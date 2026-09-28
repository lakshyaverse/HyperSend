plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.hypersend.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.hypersend.app"
        minSdk = 26
        targetSdk = 34
        versionCode = 6
        versionName = "0.4.2"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Intentionally zero: stdlib + platform APIs only, for a fast version-proof build.
}
