// Ported-From: danwright32/overture mac/Overture/App/SecureFileWrite.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
//
// Ported on 2026-09-19 by backstage#2. Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// TAKEN WHOLE AND UNCHANGED, because it carries a FIX: the token file holds a standing login, and
// this is what keeps it from ever being visible at wider permissions, even for an instant.
import Foundation
import Darwin

// Shared by GmailCredentials.saveTokens and DebugSeed's token-file copy (#524): both must write a
// file that is never observable wider than the intended mode. A plain write followed by a separate
// best-effort chmod leaves a real window where the file sits at wider permissions, and a silent
// chmod failure leaves it there permanently (#486). Writing to a temp file created directly at the
// target mode, then renaming into place, avoids both: rename() preserves the temp file's own
// permissions across the swap, and a failure at either step is reported instead of hidden.
enum SecureFileWrite {
    @discardableResult
    static func writeOwnerOnly(_ data: Data, to url: URL, mode: Int = 0o600) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        } catch {
            return false
        }
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: data,
                                             attributes: [.posixPermissions: mode]) else {
            return false
        }
        guard rename(tempURL.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
        return true
    }
}
