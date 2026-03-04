import Foundation
import Testing
@testable import TmuxChat

#if canImport(SSHClient) && canImport(NIOSSH)
struct SSHPrivateKeyParserTests {
    @Test("Parses PEM-encoded ECDSA private key")
    func parsesPEMECDSA() throws {
        _ = try SSHPrivateKeyParser.parse(privateKey: Fixtures.pemECDSA, passphrase: nil)
    }

    @Test("Parses unencrypted OpenSSH Ed25519 private key")
    func parsesOpenSSHEd25519() throws {
        _ = try SSHPrivateKeyParser.parse(privateKey: Fixtures.openSSHEd25519, passphrase: nil)
    }

    @Test("Rejects encrypted OpenSSH Ed25519 private key")
    func rejectsEncryptedOpenSSHEd25519() {
        do {
            _ = try SSHPrivateKeyParser.parse(privateKey: Fixtures.openSSHEd25519Encrypted, passphrase: nil)
            #expect(false, "Expected encryptedPrivateKeyUnsupported")
        } catch let error as SSHCommandExecutorError {
            switch error {
            case .encryptedPrivateKeyUnsupported:
                #expect(true)
            default:
                #expect(false, "Expected encryptedPrivateKeyUnsupported, got \(error.localizedDescription)")
            }
        } catch {
            #expect(false, "Unexpected error type: \(error)")
        }
    }

    @Test("Rejects malformed OpenSSH private key")
    func rejectsMalformedOpenSSH() {
        do {
            _ = try SSHPrivateKeyParser.parse(privateKey: Fixtures.malformedOpenSSH, passphrase: nil)
            #expect(false, "Expected unsupportedPrivateKeyFormat")
        } catch let error as SSHCommandExecutorError {
            switch error {
            case .unsupportedPrivateKeyFormat:
                #expect(true)
            default:
                #expect(false, "Expected unsupportedPrivateKeyFormat, got \(error.localizedDescription)")
            }
        } catch {
            #expect(false, "Unexpected error type: \(error)")
        }
    }

    @Test("Rejects non-Ed25519 OpenSSH private key")
    func rejectsOpenSSHECDSA() {
        do {
            _ = try SSHPrivateKeyParser.parse(privateKey: Fixtures.openSSHECDSA, passphrase: nil)
            #expect(false, "Expected unsupportedPrivateKeyFormat")
        } catch let error as SSHCommandExecutorError {
            switch error {
            case .unsupportedPrivateKeyFormat:
                #expect(true)
            default:
                #expect(false, "Expected unsupportedPrivateKeyFormat, got \(error.localizedDescription)")
            }
        } catch {
            #expect(false, "Unexpected error type: \(error)")
        }
    }
}

private enum Fixtures {
    static let openSSHEd25519 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACCamo6RsLx4ED/MK8/szy4eJZ8W+azVVxb061hzljR5dwAAALDS8ogF0vKI
    BQAAAAtzc2gtZWQyNTUxOQAAACCamo6RsLx4ED/MK8/szy4eJZ8W+azVVxb061hzljR5dw
    AAAEA0Vslc748Ru/hC3ztohSeaB7XHLcGQDovkjpweZQhmuJqajpGwvHgQP8wrz+zPLh4l
    nxb5rNVXFvTrWHOWNHl3AAAAKGFsbGVubmV2ZXJsYW5kQGFsbGVuaHNpYW8tbWFjLW1pbm
    kubG9jYWwBAgMEBQ==
    -----END OPENSSH PRIVATE KEY-----
    """

    static let openSSHEd25519Encrypted = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCVtJ7BSP
    nolRpsxqvEpqR+AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIAPSd3ck4VnEH0tE
    opYbE46PfGpHVCWfVHiMAgbVyTRJAAAAsA4RU1KOIxVEzpqSuIG3HT8SJs1Myx5zDD5PbS
    t40SkMEzfoW/IK/9e6VuAHYQMrRtNOlQdGibw3GuDWtsHAvYY+Z4hyA+dNB/SIqG1dHLJJ
    aWXnJxuV7nuwQtkc88X/bgt7Kym9EN6LtlSIgGtYEzVPcMTETP4n8ROfFzUGZg3GRrqaKy
    QbO+liYaXi0Mg7j3n+bGYnTqIg7VjHBQ4MghIPNhsB1ql5SLlGwxQqlXvh
    -----END OPENSSH PRIVATE KEY-----
    """

    static let openSSHECDSA = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQQqq0l4JNYXk+u1etCMrd8tvAQLW6qk
    AR2Ed+Eu91nd8ctF5U0Rwp6VzHlErarIpoyXrOgY+SbFedTZOrbCuH+UAAAAwFvu1TNb7t
    UzAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCqrSXgk1heT67V6
    0Iyt3y28BAtbqqQBHYR34S73Wd3xy0XlTRHCnpXMeUStqsimjJes6Bj5JsV51Nk6tsK4f5
    QAAAAgEkC+2k0ibEE7MpSAUOX8GVIWQGNFjZMyDS6qLCHKHB8AAAAoYWxsZW5uZXZlcmxh
    bmRAYWxsZW5oc2lhby1tYWMtbWluaS5sb2NhbA==
    -----END OPENSSH PRIVATE KEY-----
    """

    static let pemECDSA = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIHEdTB5OGTqxvyxG1E0R9QiNl8Er9xKcdM6I1ZPoynoRoAoGCCqGSM49
    AwEHoUQDQgAEPFn6r2+ysL4zwZ4hjME/MN2J+f55I5dAZY7wfnHuZDqvNfep9Os9
    Q78aynpSJWgpl3Bk5bP7NzgMQCrg6Id9rg==
    -----END EC PRIVATE KEY-----
    """

    static let malformedOpenSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    Zm9vYmFy
    -----END OPENSSH PRIVATE KEY-----
    """
}
#endif
