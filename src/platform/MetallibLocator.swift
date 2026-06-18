import Foundation

// Resolves the compiled Metal library path for every entry point (app, bench,
// tests). The build graph passes `--metallib=<path>` so each binary loads the
// content-addressed artifact the build produced; an installed binary falls back
// to the sdf.metallib sitting next to the executable. A missing library is a
// hard boundary — there is nothing to render without it.
enum MetallibLocator {
    private static let argumentPrefix = "--metallib="

    static func resolve() -> String {
        if let fromArgument = pathFromArguments() {
            return fromArgument
        }
        if let adjacent = executableAdjacentPath() {
            return adjacent
        }
        fatalError(
            "Could not locate sdf.metallib: pass \(argumentPrefix)<path> or place "
                + "sdf.metallib next to the executable"
        )
    }

    private static func pathFromArguments() -> String? {
        for argument in CommandLine.arguments where argument.hasPrefix(argumentPrefix) {
            return String(argument.dropFirst(argumentPrefix.count))
        }
        return nil
    }

    private static func executableAdjacentPath() -> String? {
        guard let executablePath = Bundle.main.executablePath else {
            return nil
        }
        let candidate = (executablePath as NSString)
            .deletingLastPathComponent
            .appending("/sdf.metallib")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }
}
