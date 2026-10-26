import CoreGraphics
// Lists an app's windows: id, layer, width, height, on screen. The argument is the owner's name
// ("BlankNote") or "pid:<process id>" to pick one copy when several are running.
let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BlankNote"
let pid = target.hasPrefix("pid:") ? Int(target.dropFirst(4)) : nil
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where pid.map({ (w[kCGWindowOwnerPID as String] as? Int) == $0 }) ?? ((w[kCGWindowOwnerName as String] as? String) == target) {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    print(w[kCGWindowNumber as String]!, w[kCGWindowLayer as String]!, b["Width"]!, b["Height"]!, w[kCGWindowIsOnscreen as String] ?? 0)
}
