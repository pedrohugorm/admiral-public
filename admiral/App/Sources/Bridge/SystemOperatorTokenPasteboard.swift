import AppKit
import AdmiralCore

/// General pasteboard for Settings → Copy token. Marked concealed so clipboard managers that
/// honour the nspasteboard.org convention skip it. The pasteboard is not cleared afterwards.
final class SystemOperatorTokenPasteboard: OperatorTokenPasteboard {
    func setString(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pb.setString(value, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}
