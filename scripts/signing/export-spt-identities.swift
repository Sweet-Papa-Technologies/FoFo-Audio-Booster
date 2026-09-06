// Exports ONLY the two SPT identities, encrypted with a password read on stdin.
// Binary output is consumed directly by setup-signing.py; never invoke in a log.
import Foundation
import Security
let allowed = Set([
    "Developer ID Application: Forrester Terry (6Y5SZ2K5XY)",
    "Developer ID Installer: Forrester Terry (6Y5SZ2K5XY)"
])
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
guard let password = readLine(), password.count >= 32 else { fail("A strong export password must be supplied on stdin.") }
let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let identities = result as? [SecIdentity] else { fail("Could not enumerate signing identities.") }
var selected: [SecIdentity] = []
var found: Set<String> = []
for identity in identities {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
          let subject = SecCertificateCopySubjectSummary(certificate) as String?, allowed.contains(subject) else { continue }
    guard found.insert(subject).inserted else { fail("Duplicate SPT identity; resolve the ambiguity before export.") }
    selected.append(identity)
}
guard found == allowed else { fail("The SPT Application and Installer identities must both be present.") }
let passphrase = password as CFString
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.passphrase = Unmanaged.passUnretained(passphrase)
var data: CFData?
let status = SecItemExport(selected as CFArray, .formatPKCS12, [], &parameters, &data)
guard status == errSecSuccess, let data else { fail("Selected-identity export failed (Security \(status)).") }
FileHandle.standardOutput.write(data as Data)
