package sh.termio.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CompanionProtocolTest {
    @Test fun pairingRetainsTheEncodedAddressAndDecodesOnlyTheToken() {
        val pairing = CompanionProtocol.pairingAddress(" https://mac.example:8787/path?t=a%2Bb%22&other=1 ")
        assertEquals("wss://mac.example:8787/path?t=a%2Bb%22&other=1", pairing.url)
        assertEquals("a+b\"", pairing.token)
        assertEquals("a+b\"", JSONObject(CompanionProtocol.authentication(pairing.token)).getString("token"))
    }

    @Test fun invalidPairingsDoNotOpenAConnection() {
        for (address in listOf("not an address", "termio://device?token=secret", "ws://mac/", "ws://mac/?t=", "ws://user:secret@mac/?t=secret", "ws://mac:0/?t=secret", "ws://mac:65536/?t=secret")) {
            assertThrows(IllegalArgumentException::class.java) { CompanionProtocol.pairingAddress(address) }
        }
    }

    @Test fun directAttachQrCodesExplainHowToGetACompatibleCode() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            CompanionProtocol.pairingAddress("termio://device?token=secret")
        }
        assertEquals("Turn off Direct Attach in Settings ▸ Mobile on your Mac, then scan the QR code again.", error.message)
        assertFalse(error.message.orEmpty().contains("secret"))
    }

    @Test fun eachSessionAuthenticatesBeforeAttachingAndDeclaringItsViewport() {
        val messages = CompanionProtocol.sessionPreamble("secret", "session", 47, 30).map(::JSONObject)
        assertEquals(listOf("auth", "attach", "resize"), messages.map { it.getString("t") })
        assertEquals(2, messages[0].getInt("wire"))
        assertEquals("session", messages[1].getString("session"))
        assertEquals(47, messages[2].getInt("cols"))
        assertEquals(30, messages[2].getInt("rows"))
        assertTrue(messages[2].getBoolean("rendering"))
        assertFalse(messages[2].has("surfaceCols"))
    }

    @Test fun sharedGridDoesNotReplaceThePhonesViewport() {
        val message = JSONObject(CompanionProtocol.viewport(47, 30, true, 120, 40))
        assertEquals(47, message.getInt("cols"))
        assertEquals(30, message.getInt("rows"))
        assertEquals(120, message.getInt("surfaceCols"))
        assertEquals(40, message.getInt("surfaceRows"))
        assertFalse(JSONObject(CompanionProtocol.viewport(47, 30, false, 47, 30)).getBoolean("rendering"))
    }

    @Test fun rosterKeepsWorkspaceAndSessionIdentity() {
        val roster = JSONObject("""{"projects":[{"id":"project","name":"Example","workspaceID":"workspace","workspaceName":"Work","sessions":[{"id":"session","title":"Deploy 🟢","agent":"terminal","status":"idle"}]}]}""")
        val project = CompanionProtocol.projects(roster).single()
        assertEquals("workspace", project.workspaceID)
        assertEquals("Work", project.workspaceName)
        assertEquals("session", project.sessions.single().id)
        assertEquals("Deploy 🟢", project.sessions.single().title)
        assertTrue(CompanionProtocol.projects(JSONObject()).isEmpty())
    }

    @Test fun refusalsExplainTheActionWithoutRevealingTheAddress() {
        assertTrue(CompanionProtocol.refusal(JSONObject().put("code", "unauthorized")).contains("Copy its address again"))
        assertEquals("Update Termio on this phone.", CompanionProtocol.refusal(JSONObject().put("code", "client_too_old")))
    }
}
