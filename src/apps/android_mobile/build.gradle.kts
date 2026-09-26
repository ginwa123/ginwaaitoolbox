plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
    // Room's compiler is an annotation processor, not a plugin: it is wired to
    // the KSP task below and must match the Kotlin version exactly, which is
    // why the `2.0.21-` prefix is pinned rather than ranged.
    id("com.google.devtools.ksp") version "2.0.21-1.0.28" apply false
}
