import Foundation

// Mirrors Python's packet.get(key, default) for JSON objects decoded via JSONSerialization.

public func numberField(_ d: [String: Any], _ key: String, default def: Double = 0.0) -> Double {
    (d[key] as? NSNumber)?.doubleValue ?? def
}

public func boolField(_ d: [String: Any], _ key: String, default def: Bool = false) -> Bool {
    (d[key] as? NSNumber)?.boolValue ?? def
}

public func stringField(_ d: [String: Any], _ key: String, default def: String = "") -> String {
    (d[key] as? String) ?? def
}

public func logError(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}
