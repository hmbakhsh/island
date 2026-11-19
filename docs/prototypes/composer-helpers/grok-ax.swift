// Tested prototype: send to Grok Bot in the background over Accessibility.
// usage: swift grok-ax.swift set "<message>" ; swift grok-ax.swift press
// Run `open -g "grokbot://app/v1/agent?id=<agentId>"` first to select the bot without raising Grok.
import Cocoa
let mode = CommandLine.arguments[1]           // set | press | clear | look
let text = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anysphere.sand").first!
let ax = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func s(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
var ta: AXUIElement?; var buttons: [AXUIElement] = []
func walk(_ e: AXUIElement) {
  let r = s(e, "AXRole")
  if r == "AXTextArea" && s(e, "AXDescription") == "Prompt" { ta = e }
  if r == "AXButton" { buttons.append(e) }
  for c in (attr(e, "AXChildren") as? [AXUIElement] ?? []) { walk(c) }
}
walk(ax)
guard let t = ta else { print("no textarea"); exit(1) }
switch mode {
case "set":
  print("set AXValue:", AXUIElementSetAttributeValue(t, "AXValue" as CFString, text as CFString).rawValue)
case "seltext":
  print("set AXSelectedText:", AXUIElementSetAttributeValue(t, "AXSelectedText" as CFString, text as CFString).rawValue)
case "press":
  if let b = buttons.first(where: { s($0, "AXDescription").lowercased().hasPrefix("send") }) { print("press", s(b, "AXDescription"), AXUIElementPerformAction(b, "AXPress" as CFString).rawValue) } else { print("no send button") }
case "clear":
  print("clear:", AXUIElementSetAttributeValue(t, "AXValue" as CFString, "" as CFString).rawValue)
default: break
}
Thread.sleep(forTimeInterval: 0.6)
buttons = []; ta = nil; walk(ax)
print("value=[\(ta.map { s($0, "AXValue") } ?? "-")]")
print("buttons:", Set(buttons.map { s($0, "AXDescription") }).filter { !$0.isEmpty }.sorted().joined(separator: " | "))
