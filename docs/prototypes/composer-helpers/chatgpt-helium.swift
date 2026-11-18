// Tested prototype: drive the user's Helium (by pid, not the agent instance) over ScriptingBridge without raising it.
// usage: gpt <pid> open <url>        -> prints new tab id
//        gpt <pid> js <tabId> <code> -> prints result
import Foundation
import ScriptingBridge

let a = CommandLine.arguments
guard a.count >= 4, let pid = pid_t(a[1]), let app = SBApplication(processIdentifier: pid) else { print("usage"); exit(2) }
let windows = app.value(forKey: "windows") as! SBElementArray
guard windows.count > 0 else { print("no windows"); exit(1) }
let win = windows.object(at: 0) as! SBObject

func tabs(_ w: SBObject) -> SBElementArray { w.value(forKey: "tabs") as! SBElementArray }
func find(_ id: String) -> SBObject? {
  for case let w as SBObject in windows {
    for case let t as SBObject in tabs(w) where "\((t as AnyObject).value(forKey: "id")!)" == id { return t }
  }
  return nil
}

switch a[2] {
case "open":
  let prev = win.value(forKey: "activeTabIndex") as! Int
  let cls: AnyObject = app.class(forScriptingClass: "tab")!
  let raw = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
  let tab = raw.perform(NSSelectorFromString("initWithProperties:"), with: ["URL": a[3]])!.takeUnretainedValue()
  let before = Set(tabs(win).compactMap { ($0 as AnyObject).value(forKey: "id").map { "\($0)" } })
  tabs(win).add(tab)
  // the add lands asynchronously and focuses the new tab: wait for it, then put the user's tab back
  var newId: String?
  for _ in 0..<50 {
    newId = tabs(win).compactMap { ($0 as AnyObject).value(forKey: "id").map { "\($0)" } }.first { !before.contains($0) }
    if newId != nil { break }
    usleep(20_000)
  }
  win.setValue(prev, forKey: "activeTabIndex")
  print(newId ?? "none")
case "js":
  guard let t = find(a[3]) else { print("no tab"); exit(1) }
  let r = t.perform(Selector(("executeJavascript:")), with: a[4])?.takeUnretainedValue()
  print(r ?? "nil")
case "close":
  guard let t = find(a[3]) else { print("no tab"); exit(1) }
  t.perform(Selector(("close")))
default: print("usage"); exit(2)
}
