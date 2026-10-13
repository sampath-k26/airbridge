pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "AirBridge"
// :core — pure Kotlin/JVM protocol, crypto and transfer engine (unit-testable on the JVM,
//         and runnable as a CLI for interop tests against the macOS implementation).
// :app  — Android UI, storage (SAF/MediaStore), foreground service.
include(":core", ":app")
