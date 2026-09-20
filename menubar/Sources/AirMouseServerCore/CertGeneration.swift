import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Self-signed cert generation via openssl, ported from mouse_controller.py's
// ensure_ssl_certs. NIOSSL loads the resulting PEM files directly (like Python's
// ssl.SSLContext.load_cert_chain) — no Keychain involvement, unlike the
// Network-framework/SecIdentity approach this replaced (see ADR-0002).
//
// The cert must carry a subjectAltName. Safari has ignored commonName for
// hostname matching since iOS 13, so a CN-only cert does not merely warn — it
// cannot be matched against the URL at all, and the "visit this website anyway"
// escape hatch is not reliably offered. A CN=localhost cert served at
// https://<host>.local:8443 was wrong on both counts.

enum CertGenerationError: Error, CustomStringConvertible {
    case opensslFailed(String)
    case sanMissing

    var description: String {
        switch self {
        case .opensslFailed(let stderr): return "openssl failed: \(stderr)"
        case .sanMissing:
            return "openssl produced a certificate without a subjectAltName — "
                + "this build of openssl does not support -addext"
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

/// The Bonjour name the phone connects to, e.g. `MacBook-Pro-von-Robert.local`.
///
/// Preferred over a raw LAN IP because it survives a DHCP lease change: the
/// home-screen PWA stores whatever URL it was added from, so an IP-based URL
/// turns into a dead icon the next time the router hands out a different lease.
/// iOS resolves `.local` over mDNS with no configuration.
public func localHostname() -> String {
    var name = ProcessInfo.processInfo.hostName
    if !name.hasSuffix(".local") { name += ".local" }
    return name
}

/// Non-loopback IPv4 addresses, as a fallback for networks that block mDNS
/// (client isolation, some corporate Wi-Fi). Listing them in the SAN costs
/// nothing and means the IP URL also validates if the user has to fall back.
public func lanIPv4Addresses() -> [String] {
    var addresses: [String] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            addr, socklen_t(addr.pointee.sa_len),
            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard result == 0 else { continue }

        let ip = String(cString: host)
        // Link-local means DHCP never completed; it is not reachable from the phone.
        if ip.hasPrefix("169.254.") { continue }
        if !addresses.contains(ip) { addresses.append(ip) }
    }
    return addresses
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    // Read before waiting: a pipe that fills up deadlocks a process that is
    // still writing to it.
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(data: outData, encoding: .utf8) ?? "",
        String(data: errData, encoding: .utf8) ?? ""
    )
}

/// The SAN entries the cert must carry, in a stable order so it can be compared
/// against an existing cert without spurious regeneration.
func desiredSANEntries(hostname: String, ipAddresses: [String]) -> [String] {
    var entries = ["DNS:\(hostname)", "DNS:localhost"]
    entries += ipAddresses.sorted().map { "IP:\($0)" }
    entries.append("IP:127.0.0.1")
    return entries
}

/// Reads the SAN entries out of an existing cert, normalised to match
/// `desiredSANEntries`' spelling so the two can be compared directly.
private func existingSANEntries(certPath: String) -> [String]? {
    // -text rather than "-ext subjectAltName": the latter is OpenSSL 1.1.1+ only,
    // and macOS ships LibreSSL, where it is not a recognised option at all.
    guard let (status, stdout, _) = try? runProcess(
        "/usr/bin/openssl", ["x509", "-in", certPath, "-noout", "-text"]),
        status == 0
    else { return nil }

    // The entries sit on the line *after* the extension's name, comma separated,
    // as "DNS:foo.local, IP Address:192.168.1.5".
    let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
    guard let headerIndex = lines.firstIndex(where: { $0.contains("Subject Alternative Name") }),
          case let valueIndex = lines.index(after: headerIndex),
          valueIndex < lines.endIndex
    else { return nil }

    return lines[valueIndex]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "IP Address:", with: "IP:") }
        .filter { !$0.isEmpty }
}

func ensureCertAndKey(dir: URL, hostname: String, ipAddresses: [String]) throws -> (cert: URL, key: URL) {
    let cert = dir.appendingPathComponent("cert.pem")
    let key = dir.appendingPathComponent("key.pem")
    let wanted = desiredSANEntries(hostname: hostname, ipAddresses: ipAddresses)

    var needsGeneration = !FileManager.default.fileExists(atPath: cert.path)
        || !FileManager.default.fileExists(atPath: key.path)

    if !needsGeneration {
        let (status, _, _) = try runProcess(
            "/usr/bin/openssl", ["x509", "-in", cert.path, "-noout", "-checkend", "86400"])
        if status != 0 { needsGeneration = true }
    }

    // Regenerate when the machine's name or addresses have moved on, otherwise a
    // cert minted on a previous network keeps failing to match and the user has
    // no way to tell why.
    if !needsGeneration, Set(existingSANEntries(certPath: cert.path) ?? []) != Set(wanted) {
        needsGeneration = true
    }

    guard needsGeneration else { return (cert, key) }

    // 365 days: iOS rejects TLS server certs whose validity exceeds 825 days
    // outright, and a shorter life limits the damage if the key ever leaks.
    let (status, _, err) = try runProcess("/usr/bin/openssl", [
        "req", "-x509", "-newkey", "rsa:2048",
        "-keyout", key.path, "-out", cert.path,
        "-sha256", "-days", "365", "-nodes",
        "-subj", "/CN=\(hostname)",
        "-addext", "subjectAltName=\(wanted.joined(separator: ","))",
        "-addext", "basicConstraints=critical,CA:FALSE",
        "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
        "-addext", "extendedKeyUsage=serverAuth",
    ])
    if status != 0 { throw CertGenerationError.opensslFailed(err) }

    // -addext is silently ignored by some older openssl builds, which would ship
    // a cert that cannot be matched at all. Fail loudly instead.
    guard let produced = existingSANEntries(certPath: cert.path), !produced.isEmpty else {
        throw CertGenerationError.sanMissing
    }

    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    return (cert, key)
}
