// Проверки формата без симулятора: собираются `swiftc` под macOS на VM (scripts/host-test.sh).
// Аргументы: <копия «как с Android»> <куда записать свой zip>
import Foundation

var failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if condition() {
        print("  ok   \(what)")
    } else {
        failures += 1
        print("  FAIL \(what) (строка \(line))")
    }
}

func section(_ name: String) { print("== \(name)") }

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: host-tests <fixture.backup> <out.zip>")
    exit(2)
}
let fixture = URL(fileURLWithPath: args[1])
let outZip = URL(fileURLWithPath: args[2])

do {
    try testBackupFormat(fixture: fixture, outZip: outZip)
} catch {
    failures += 1
    print("  FAIL исключение: \(error)")
}

testSpotifyAuth()

print(failures == 0 ? "ALL TESTS PASSED" : "FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
