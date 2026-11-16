plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.bloxtrade.capture"
    compileSdk = 34
    defaultConfig { minSdk = 26 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    // Match this to the Godot version you export with.
    compileOnly("org.godotengine:godot:4.3.0.stable")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}
