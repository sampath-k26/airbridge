plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    api(libs.coroutines.core)
    implementation(libs.serialization.json)
    testImplementation(libs.junit)
    testImplementation(kotlin("test-junit"))
}

application {
    // `./gradlew :core:installDist` produces build/install/core/bin/core (interop CLI).
    mainClass.set("com.mahi.airbridge.core.cli.CliKt")
    applicationName = "airbridge-jvm"
}

tasks.test {
    // Shared vectors live in the repo-level protocol directory.
    systemProperty("airbridge.vectors", rootProject.file("../protocol/test-vectors").absolutePath)
    maxHeapSize = "512m"
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}
