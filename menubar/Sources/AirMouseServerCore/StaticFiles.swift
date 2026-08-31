import Foundation

// Ported from mouse_controller.py's process_request: serves web/ over the same
// port, with the same directory-traversal protection and cache headers.

struct StaticFileResponse {
    let statusCode: Int
    let reasonPhrase: String
    let contentType: String
    let body: Data
}

private func contentType(for path: String) -> String {
    if path.hasSuffix(".html") { return "text/html" }
    if path.hasSuffix(".css") { return "text/css" }
    if path.hasSuffix(".js") { return "text/javascript" }
    if path.hasSuffix(".png") { return "image/png" }
    return "text/plain"
}

func serveStaticFile(requestPath: String, webRoot: URL) -> StaticFileResponse {
    var cleanPath = requestPath.components(separatedBy: "?").first ?? "/"
    if cleanPath == "/" { cleanPath = "/index.html" }

    let fileURL = webRoot.appendingPathComponent(String(cleanPath.dropFirst()))

    // Must be exactly webRoot or a path inside it, not merely a prefix match
    // (which would also allow a sibling directory like "web-private").
    let realWebRoot = webRoot.resolvingSymlinksInPath().standardizedFileURL.path
    let realFilePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
    guard realFilePath == realWebRoot || realFilePath.hasPrefix(realWebRoot + "/") else {
        return StaticFileResponse(statusCode: 403, reasonPhrase: "Forbidden", contentType: "text/plain", body: Data("Forbidden".utf8))
    }

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue,
          let content = try? Data(contentsOf: fileURL)
    else {
        return StaticFileResponse(statusCode: 404, reasonPhrase: "Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
    }

    return StaticFileResponse(statusCode: 200, reasonPhrase: "OK", contentType: contentType(for: fileURL.path), body: content)
}
