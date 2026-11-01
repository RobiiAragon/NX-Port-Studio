import Foundation

public struct DependencyStatus: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isAvailable: Bool
    public let detail: String
    public let remediation: String?
    public let isRequired: Bool
    public init(id: String, name: String, isAvailable: Bool, detail: String,
                remediation: String? = nil, isRequired: Bool = true) {
        self.id = id; self.name = name; self.isAvailable = isAvailable
        self.detail = detail; self.remediation = remediation; self.isRequired = isRequired
    }
}

public enum EnvironmentInspector {
    public static func inspect(repositoryURL: URL, pythonURL: URL,
                               destination: BuildDestination = .iOS) async -> [DependencyStatus] {
        await withTaskGroup(of: DependencyStatus.self) { group in
            group.addTask {
                #if arch(arm64)
                let available = true
                let detail = "ARM64 Mac"
                #else
                let available = false
                let detail = "An M1 or newer Mac is required."
                #endif
                return DependencyStatus(id: "silicon", name: "Apple silicon", isAvailable: available,
                                        detail: detail)
            }
            group.addTask {
                let script = repositoryURL.appendingPathComponent("scripts/build_ipa_from_nsp.py")
                let translator = repositoryURL.appendingPathComponent("dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate")
                let available = FileManager.default.isReadableFile(atPath: script.path) && FileManager.default.fileExists(atPath: translator.path)
                return DependencyStatus(id: "engine", name: "nxnative engine", isAvailable: available,
                                        detail: available ? "Build script and shader translator found" : "Build script or bundled shader translator missing.",
                                        remediation: "Select a complete nxnative checkout.")
            }
            group.addTask { await check(id: "xcode", name: "Xcode", executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"), args: ["-version"], remediation: "Install Xcode from the App Store and open it once.") }
            group.addTask { await check(id: "metal", name: "Metal compiler", executable: URL(fileURLWithPath: "/usr/bin/xcrun"), args: ["-sdk", destination == .macOS ? "macosx" : "iphoneos", "metal", "--version"], remediation: "Install the Metal Toolchain in Xcode Settings > Components, or run xcodebuild -downloadComponent MetalToolchain.") }
            group.addTask {
                await check(id: "python", name: "Python packages", executable: pythonURL,
                            args: ["-c", "import lz4.block, capstone, fontTools; import sys; __import__('compression.zstd' if sys.version_info >= (3,14) else 'backports.zstd'); print('Python dependencies ready')"],
                            remediation: "Use Prepare environment to install packages into the app's isolated Python environment.")
            }
            group.addTask {
                guard let url = ToolEnvironment.executable(named: "dotnet") else {
                    return DependencyStatus(id: "dotnet", name: ".NET 10 SDK and runtime", isAvailable: false, detail: "dotnet was not found.", remediation: "Install .NET 10 SDK from Microsoft, or brew install --formula dotnet@10.")
                }
                let sdk = try? await ProcessRunner().run(ProcessCommand(executableURL: url, arguments: ["--list-sdks"]))
                let runtime = try? await ProcessRunner().run(ProcessCommand(executableURL: url, arguments: ["--list-runtimes"]))
                let sdkFound = sdk?.output.split(separator: "\n").contains(where: { (Int($0.split(separator: ".").first ?? "") ?? 0) >= 10 }) == true
                let runtimeFound = runtime?.output.contains("Microsoft.NETCore.App 10.") == true
                return DependencyStatus(id: "dotnet", name: ".NET 10 SDK and runtime", isAvailable: sdkFound && runtimeFound,
                                        detail: sdkFound && runtimeFound ? "Compatible SDK and .NET 10 runtime installed" : "Both an SDK >=10 and Microsoft.NETCore.App 10.x are required.",
                                        remediation: "Install Microsoft's .NET 10 SDK (including its .NET 10 runtime).")
            }
            for (id, name, arguments, required) in [("xcodegen", "XcodeGen", ["--version"], destination == .iOS),
                                                     ("zstd", "Zstandard", ["--version"], true),
                                                     ("spirv-cross", "SPIRV-Cross", ["--revision"], true),
                                                     ("glslangValidator", "glslang", ["--version"], false),
                                                     ("make", "Make", ["--version"], true)] {
                group.addTask {
                    guard let url = ToolEnvironment.executable(named: id) else {
                        return DependencyStatus(id: id, name: name, isAvailable: false, detail: "Not found in the tool search path.",
                                                remediation: id == "make" ? "Install Xcode." : "Install the relevant Homebrew package.", isRequired: required)
                    }
                    return await check(id: id, name: name, executable: url, args: arguments,
                                       remediation: "Repair the \(name) installation.", required: required)
                }
            }
            var statuses: [DependencyStatus] = []
            for await status in group { statuses.append(status) }
            let order = ["silicon", "engine", "xcode", "metal", "python", "dotnet", "xcodegen", "zstd", "spirv-cross", "glslangValidator", "make"]
            return statuses.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
        }
    }

    private static func check(id: String, name: String, executable: URL, args: [String],
                              remediation: String, required: Bool = true) async -> DependencyStatus {
        do {
            let result = try await ProcessRunner().run(ProcessCommand(executableURL: executable, arguments: args))
            return DependencyStatus(id: id, name: name, isAvailable: result.exitCode == 0,
                                    detail: result.output.split(separator: "\n").first.map(String.init) ?? "No version output",
                                    remediation: result.exitCode == 0 ? nil : remediation, isRequired: required)
        } catch {
            return DependencyStatus(id: id, name: name, isAvailable: false, detail: error.localizedDescription,
                                    remediation: remediation, isRequired: required)
        }
    }
}

public enum EnvironmentSetup {
    /// This only returns a plan. The GUI executes it after the user chooses Prepare environment.
    /// Homebrew's versioned .NET formula avoids an interactive administrator installer.
    public static func commands(pythonURL: URL, venvURL: URL, dependencies: [DependencyStatus] = []) -> [ProcessCommand] {
        var commands: [ProcessCommand] = []
        if let brew = ToolEnvironment.executable(named: "brew") {
            let packages = [("xcodegen", "xcodegen"), ("zstd", "zstd"), ("spirv-cross", "spirv-cross"), ("glslangValidator", "glslang")]
                .filter { ToolEnvironment.executable(named: $0.0) == nil }.map(\.1)
            if !packages.isEmpty {
                commands.append(ProcessCommand(executableURL: brew, arguments: ["install"] + packages,
                                               redactedDescription: "Install nxnative tools with Homebrew"))
            }
            if ToolEnvironment.executable(named: "dotnet") == nil || dependencies.first(where: { $0.id == "dotnet" })?.isAvailable == false {
                commands.append(ProcessCommand(executableURL: brew, arguments: ["install", "--formula", "dotnet@10"],
                                               redactedDescription: "Install the .NET 10 SDK and runtime with Homebrew"))
            }
        }
        commands.append(ProcessCommand(executableURL: pythonURL, arguments: ["-m", "venv", venvURL.path],
                                       redactedDescription: "Create isolated Python environment"))
        commands.append(ProcessCommand(executableURL: venvURL.appendingPathComponent("bin/python3"),
                                       arguments: ["-m", "pip", "install", "--no-binary=lz4", "lz4", "capstone", "fonttools", "backports.zstd; python_version < '3.14'", "nsz"],
                                       environment: ["PYLZ4_USE_SYSTEM_LZ4": "0"], redactedDescription: "Install Python build dependencies"))
        return commands
    }
}

public struct GameFolderSummary: Sendable {
    public static let supportedInputExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz", "zip", "7z"]
    public static let archiveExtensions: Set<String> = ["zip", "7z"]
    public let files: [URL]
    public let byteCount: Int64
    public var containsArchives: Bool { files.contains { Self.archiveExtensions.contains($0.pathExtension.lowercased()) } }
    /// A planning heuristic. Archive expansion is checked against actual member sizes by the builder.
    public var estimatedFreeBytesNeeded: Int64 {
        let (doubled, multiplicationOverflow) = byteCount.multipliedReportingOverflow(by: 2)
        let (estimate, additionOverflow) = doubled.addingReportingOverflow(10 * 1_073_741_824)
        return multiplicationOverflow || additionOverflow ? Int64.max : estimate
    }
    public static func inspect(_ folderURL: URL) throws -> Self {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
        var files: [URL] = []
        var bytes: Int64 = 0
        func visit(_ folder: URL, depth: Int) throws {
            let contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            for file in contents {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, values.isHidden != true, !file.lastPathComponent.hasPrefix(".") else { continue }
                if values.isDirectory == true {
                    let name = file.lastPathComponent.lowercased()
                    guard depth < 4, values.isPackage != true,
                          !["app", "bundle", "framework", "xcassets", "xcodeproj", "xcworkspace", "appex"].contains(file.pathExtension.lowercased()),
                          !name.hasSuffix("_build"), !name.hasSuffix("-work"), !name.hasSuffix("_survey") else { continue }
                    try visit(file, depth: depth + 1)
                } else if values.isRegularFile == true, supportedInputExtensions.contains(file.pathExtension.lowercased()) {
                    files.append(file)
                    let (total, overflow) = bytes.addingReportingOverflow(Int64(values.fileSize ?? 0))
                    bytes = overflow ? Int64.max : total
                }
            }
        }
        let root = try folderURL.resourceValues(forKeys: keys)
        if root.isDirectory == true, root.isSymbolicLink != true, root.isPackage != true { try visit(folderURL, depth: 0) }
        return Self(files: files.sorted { $0.path < $1.path }, byteCount: bytes)
    }
}
