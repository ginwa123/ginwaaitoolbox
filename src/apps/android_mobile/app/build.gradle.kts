plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.devtools.ksp")
}

android {
    namespace = "com.nalar.mobile"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.nalar.mobile"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

    testOptions {
        unitTests {
            // Robolectric needs the merged manifest and resources to build an
            // Android environment, and Room needs one to open its SQLite file.
            isIncludeAndroidResources = true
        }
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.navigation:navigation-compose:2.8.5")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // The three offline caches. One Room database, three DAOs — see
    // com.nalar.mobile.cache.NalarCacheDatabase.
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    debugImplementation("androidx.compose.ui:ui-tooling")
    // The host activity `createComposeRule` launches. On `debugImplementation`
    // as well as `testImplementation` because the instrumented rules need it
    // merged into the debug manifest, and the unit tests need it on their
    // classpath.
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    // The cache contract is about ordering (paint from cache, then revalidate),
    // which needs a controllable scheduler to observe the intermediate frame.
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    // Room opens a real SQLite file through the Android runtime, so the cache
    // DAO tests run on Robolectric rather than the bare JVM.
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core:1.7.0")
    // The launch gate is Compose behaviour, and the only thing that has ever
    // pinned it is a rendered tree — which meant an emulator. `createComposeRule`
    // under Robolectric renders the real graph on the JVM, so the gate is now
    // covered by the test task CI actually runs, on a box with no device
    // attached. `ui-test-manifest` is what supplies the host activity
    // `createComposeRule` launches; it has to be here, not only on
    // `debugImplementation`, or the rule has nothing to compose into.
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("androidx.compose.ui:ui-test-manifest")
    // `ui-test-junit4` asks for `androidx.test.ext:junit:1.1.5`; 1.3.0 is the
    // version the instrumented tests already use, and pinning it here means the
    // two classpaths resolve to one artifact instead of two.
    testImplementation("androidx.test.ext:junit:1.3.0")
    // Same story for espresso, which `ui-test` drags in transitively: the BOM
    // asks for 3.5.0, the cached artifact is the 3.7.0 the instrumented tests
    // already resolve. Pinned so the unit-test classpath builds offline.
    testImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:core-ktx:1.7.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
