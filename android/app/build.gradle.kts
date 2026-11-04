plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.wadjakorn.capturestudio.phone"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.wadjakorn.capturestudio.phone"
        minSdk = 30
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
    }

    // Release signing comes from the environment only; nothing secret is committed.
    // Without all four variables the release APK is built unsigned.
    val releaseKeystore = System.getenv("CS_PHONE_KEYSTORE")
    val releaseKeystorePassword = System.getenv("CS_PHONE_KEYSTORE_PASSWORD")
    val releaseKeyAlias = System.getenv("CS_PHONE_KEY_ALIAS")
    val releaseKeyPassword = System.getenv("CS_PHONE_KEY_PASSWORD")
    val hasReleaseSigning = listOf(
        releaseKeystore, releaseKeystorePassword, releaseKeyAlias, releaseKeyPassword,
    ).all { !it.isNullOrEmpty() }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseKeystore!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.03")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-service:2.8.6")
    implementation("androidx.core:core-ktx:1.13.1")

    val cameraxVersion = "1.3.4"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")

    testImplementation("junit:junit:4.13.2")
    // Real org.json on the JVM test classpath (android.jar ships only stubs).
    testImplementation("org.json:json:20240303")
}
