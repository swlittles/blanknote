import CoreGraphics
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BlankNote"
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    print(w[kCGWindowNumber as String]!, w[kCGWindowLayer as String]!, b["Width"]!, b["Height"]!, w[kCGWindowIsOnscreen as String] ?? 0)
}
