allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// CameraX exposes CallbackToFutureAdapter from this artifact. Declaring it for
// its plugin module keeps Android builds compatible with the current Gradle
// toolchain, which otherwise omits it from the Java compilation classpath.
project(":camera_android_camerax") {
    afterEvaluate {
        dependencies.add(
            "implementation",
            "androidx.concurrent:concurrent-futures:1.2.0",
        )
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
