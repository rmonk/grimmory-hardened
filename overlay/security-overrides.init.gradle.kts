// Gradle init script: raise vulnerable dependencies to a minimum ("floor") version.
//
// Rules only ever *raise* a version, and only within the same major.minor line,
// so once upstream moves to a newer line (e.g. Jackson 2.22) the rule stops
// applying on its own and upstream's choice wins.
//
// The rules are registered after all projects are evaluated so they run after
// io.spring.dependency-management's own eachDependency rule (which would
// otherwise reset managed versions back to the Spring Boot BOM).
//
// Keep this list short and remove entries once the upstream release catches up.

data class Floor(val group: Regex, val artifact: Regex, val version: String)

val floors = listOf(
    // Tomcat (CVE-2026-65182, -65905, -68525, -65637)
    Floor(Regex("""org\.apache\.tomcat\.embed"""), Regex(""".*"""), "11.0.29"),
    // Jackson 2.x (CVE-2026-89407, -89425, -68497, -91776, -91777, -19032, -83557).
    // jackson-annotations uses a major.minor-only version scheme, so leave it alone.
    Floor(Regex("""com\.fasterxml\.jackson(\..+)?"""), Regex("""(?!jackson-annotations$).*"""), "2.21.8"),
    // Jackson 3.x, same CVEs
    Floor(Regex("""tools\.jackson(\..+)?"""), Regex(""".*"""), "3.1.8"),
    // MariaDB Connector/J (CVE-2026-119280, -119210, -119276, -119281)
    Floor(Regex("""org\.mariadb\.jdbc"""), Regex("""mariadb-java-client"""), "3.5.11"),
    // org.json (CVE-2026-59171); date-based versions, so no major.minor line check
    Floor(Regex("""org\.json"""), Regex("""json"""), "20260814"),
)

fun parts(v: String): List<Int> = v.split('.', '-', '_').map { it.toIntOrNull() ?: 0 }

fun lower(a: String, b: String): Boolean {
    val x = parts(a); val y = parts(b)
    for (i in 0 until maxOf(x.size, y.size)) {
        val c = x.getOrElse(i) { 0 }.compareTo(y.getOrElse(i) { 0 })
        if (c != 0) return c < 0
    }
    return false
}

fun sameLine(a: String, b: String): Boolean {
    val x = a.split('.'); val y = b.split('.')
    if (x.size < 2 || y.size < 2) return true
    return x[0] == y[0] && x[1] == y[1]
}

gradle.projectsEvaluated {
    allprojects {
        configurations.configureEach {
            resolutionStrategy.eachDependency {
                val current = target.version ?: return@eachDependency
                val floor = floors.firstOrNull {
                    it.group.matches(target.group) && it.artifact.matches(target.name)
                } ?: return@eachDependency
                if (lower(current, floor.version) && sameLine(current, floor.version)) {
                    useVersion(floor.version)
                    because("grimmory-hardened security floor (was $current)")
                }
            }
        }
    }
}
