import Foundation

// Self-signed cert generation via openssl, ported directly from
// mouse_controller.py's ensure_ssl_certs. NIOSSL loads the resulting PEM files
// directly (like Python's ssl.SSLContext.load_cert_chain) — no Keychain
// involvement, unlike the Network-framework/SecIdentity approach this replaced
// (see the project plan for why that was a dead end).

enum CertGenerationError: Error, CustomStringConvertible {
    case opensslFailed(String)

    var description: String {
        switch self {
        case .opensslFailed(let stderr): return "openssl failed: \(stderr)"
        }
    }
}

public func appSupportDirectory() throws -> URL {
    let base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent("AirMouse", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let errPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
}

func ensureCertAndKey(dir: URL) throws -> (cert: URL, key: URL) {
    let cert = dir.appendingPathComponent("cert.pem")
    let key = dir.appendingPathComponent("key.pem")

    var needsGeneration = !FileManager.default.fileExists(atPath: cert.path)
        || !FileManager.default.fileExists(atPath: key.path)
    if !needsGeneration {
        let (status, _) = try runProcess("/usr/bin/openssl", ["x509", "-in", cert.path, "-noout", "-checkend", "86400"])
        if status != 0 { needsGeneration = true }
    }
    if needsGeneration {
        let (status, err) = try runProcess("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", key.path, "-out", cert.path,
            "-sha256", "-days", "365", "-nodes",
            "-subj", "/CN=localhost",
        ])
        if status != 0 { throw CertGenerationError.opensslFailed(err) }
    }
    return (cert, key)
}
