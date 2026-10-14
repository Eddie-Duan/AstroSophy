allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val relocatedBuildDirectory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(relocatedBuildDirectory)

subprojects {
    val subprojectBuildDirectory = relocatedBuildDirectory.dir(project.name)
    project.layout.buildDirectory.value(subprojectBuildDirectory)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
