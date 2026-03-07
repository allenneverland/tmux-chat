import Foundation
import Testing
@testable import TmuxChat

struct SSHCommandExecutorTests {
    @Test
    func timeoutProfilesUseExpectedDurations() {
        #expect(SSHCommandTimeoutProfile.quick.connectTimeout == 10)
        #expect(SSHCommandTimeoutProfile.quick.commandTimeout == 15)
        #expect(SSHCommandTimeoutProfile.standard.connectTimeout == 15)
        #expect(SSHCommandTimeoutProfile.standard.commandTimeout == 45)
        #expect(SSHCommandTimeoutProfile.long.connectTimeout == 20)
        #expect(SSHCommandTimeoutProfile.long.commandTimeout == 180)
    }

    @Test
    func commandTimedOutErrorIncludesTimeoutAndCommandSummary() {
        let error = SSHCommandExecutorError.commandTimedOut(
            command: "tmux-chatd devices issue --name iPhone",
            timeout: 45
        )
        let message = error.errorDescription ?? ""
        #expect(message.contains("timed out"))
        #expect(message.contains("45s"))
        #expect(message.contains("tmux-chatd devices issue --name iPhone"))
    }
}
