package sh.termio.android

import android.app.Application
import android.content.Context
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import java.util.concurrent.FutureTask
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import okio.ByteString

class SessionRefreshTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val preferenceName = "session-refresh-test-${UUID.randomUUID()}"
    private val servers = mutableListOf<MockWebServer>()
    private val store = ViewModelStore()
    private lateinit var client: CompanionClient

    @Before
    fun setUp() {
        val application = object : Application() {
            init { attachBaseContext(instrumentation.targetContext) }
            override fun getSharedPreferences(name: String, mode: Int) =
                instrumentation.targetContext.getSharedPreferences(preferenceName, Context.MODE_PRIVATE)
        }
        onMain {
            client = CompanionClient(application)
            store.put("client", client)
            client.setForeground(true)
        }
    }

    @After
    fun tearDown() {
        onMain { store.clear() }
        servers.forEach { it.shutdown() }
        instrumentation.targetContext.deleteSharedPreferences(preferenceName)
    }

    @Test
    fun refreshReplacesAddedAndDeletedSessionsAndKeepsSnapshotWhileWaiting() {
        val server = server()
        server.roster(roster("mac", "kept", "deleted"))
        connect(server)
        awaitState { it.sessions() == listOf("kept", "deleted") }

        val refreshed = server.roster()
        onMain {
            client.refreshSessions()
            assertTrue(client.state.value.refreshingSessions)
            assertEquals(listOf("kept", "deleted"), client.state.value.sessions())
            client.refreshSessions()
        }
        val socket = refreshed.authenticatedSocket()
        assertTrue(socket.send(roster("mac", "kept", "new")))
        val state = awaitState { !it.refreshingSessions && it.sessions() == listOf("kept", "new") }
        assertEquals("Connected", state.machines.single().connection.status)
        assertEquals(2, server.requestCount)
    }

    @Test
    fun refreshWaitsForEverySavedMacAndAcceptsAnEmptyRoster() {
        val first = server()
        val second = server()
        first.roster(roster("first", "old-first"))
        second.roster(roster("second", "old-second"))
        connect(first)
        connect(second)
        awaitState { it.machines.size == 2 && it.machines.all { machine -> machine.connection.connected } }

        val firstRefresh = first.roster()
        val secondRefresh = second.roster()
        onMain { client.refreshSessions() }
        val firstSocket = firstRefresh.authenticatedSocket()
        val secondSocket = secondRefresh.authenticatedSocket()
        assertTrue(firstSocket.send(roster("first", "new-first")))
        val pending = awaitState { it.sessions().contains("new-first") }
        assertTrue(pending.refreshingSessions)
        assertTrue(pending.sessions().contains("old-second"))
        assertTrue(secondSocket.send(roster("second")))
        val done = awaitState { !it.refreshingSessions }
        assertEquals(listOf("new-first"), done.sessions())
        assertTrue(done.machines.all { it.connection.connected && it.connection.error.isEmpty() })
        assertTrue(done.machines.single { it.connection.macID == "second" }.connection.projects.isEmpty())
    }

    @Test
    fun refreshReconnectsAnUnreachableMac() {
        val server = server()
        server.enqueue(MockResponse().setResponseCode(503))
        connect(server)
        awaitState { it.machines.singleOrNull()?.connection?.error?.isNotEmpty() == true }

        server.roster(roster("mac", "recovered"))
        onMain { client.refreshSessions() }
        val state = awaitState { it.sessions() == listOf("recovered") && !it.refreshingSessions }
        assertTrue(state.machines.single().connection.connected)
        assertEquals("", state.machines.single().connection.error)
    }

    @Test
    fun refusedRefreshStopsLoadingAndCanBeRetried() {
        val server = server()
        server.roster(roster("mac", "old"))
        connect(server)
        awaitState { it.sessions() == listOf("old") }
        server.roster("""{"t":"error","code":"unauthorized"}""")
        onMain { client.refreshSessions() }
        val failed = awaitState { !it.refreshingSessions && it.machines.single().connection.error.isNotEmpty() }
        assertFalse(failed.machines.single().connection.connected)
        assertEquals(listOf("old"), failed.sessions())

        server.roster(roster("mac", "new"))
        onMain { client.refreshSessions() }
        awaitState { !it.refreshingSessions && it.sessions() == listOf("new") }
    }

    @Test
    fun unresponsiveRefreshTimesOutAndCanBeRetried() {
        val server = server()
        server.roster(roster("mac", "old"))
        connect(server)
        awaitState { it.sessions() == listOf("old") }
        val pending = server.roster()
        onMain { client.refreshSessions() }
        pending.authenticatedSocket()
        val failed = awaitState(22_000) {
            !it.refreshingSessions && it.machines.single().connection.error.isNotEmpty()
        }
        assertFalse(failed.machines.single().connection.connected)
        assertEquals(listOf("old"), failed.sessions())
        server.roster(roster("mac", "new"))
        onMain { client.refreshSessions() }
        awaitState { !it.refreshingSessions && it.sessions() == listOf("new") }
    }

    @Test
    fun offlineMacRetriesDoNotRestartRefreshAfterTimeout() {
        val first = server()
        val second = server()
        first.roster(roster("first", "old-first"))
        second.roster(roster("second", "old-second"))
        connect(first)
        connect(second)
        awaitState { it.machines.size == 2 && it.machines.all { machine -> machine.connection.connected } }

        first.roster(roster("first", "new-first"))
        val unresponsive = second.roster()
        val reconnect = second.roster()
        onMain { client.refreshSessions() }
        unresponsive.authenticatedSocket()
        val timedOut = awaitState(22_000) {
            !it.refreshingSessions && it.machines.any { machine -> machine.connection.macID == "second" &&
                machine.connection.error.isNotEmpty() }
        }
        assertEquals(listOf("new-first", "old-second"), timedOut.sessions())

        val retrySocket = reconnect.authenticatedSocket()
        val retrying = awaitState { it.machines.any { machine -> machine.connection.macID == "second" &&
            machine.connection.loadingRoster } }
        assertFalse("Automatic reconnect must not restart the refresh spinner", retrying.refreshingSessions)
        assertTrue(retrying.machines.single { it.connection.macID == "first" }.connection.connected)
        assertEquals(listOf("new-first", "old-second"), retrying.sessions())

        retrySocket.send(roster("second", "recovered-second"))
        awaitState { !it.refreshingSessions && it.sessions() == listOf("new-first", "recovered-second") }
    }

    @Test
    fun explicitRefreshCanWaitForAnAutomaticConnectionAlreadyInProgress() {
        val server = server()
        server.enqueue(MockResponse().setResponseCode(503))
        val reconnect = server.roster()
        connect(server)
        awaitState { it.machines.singleOrNull()?.connection?.error?.isNotEmpty() == true }
        val retrySocket = reconnect.authenticatedSocket()
        onMain {
            client.refreshSessions()
            assertTrue(client.state.value.refreshingSessions)
            client.refreshSessions()
        }
        assertEquals(2, server.requestCount)
        retrySocket.send(roster("mac", "recovered"))
        awaitState { !it.refreshingSessions && it.sessions() == listOf("recovered") }
    }

    @Test
    fun refreshingRosterLeavesTheTerminalConnectionIntact() {
        val server = server()
        server.roster(roster("mac", "terminal"))
        connect(server)
        val initial = awaitState { it.sessions() == listOf("terminal") }
        server.roster(roster("mac", "terminal"))
        onMain {
            client.openSession(initial.machines.single().machine.id, RemoteSession("terminal", "Terminal"))
        }
        val attached = awaitState { it.selectedConnection?.sessionReady == true }
        val terminal = attached.selectedConnection!!.terminal

        server.roster(roster("mac", "terminal", "new"))
        onMain { client.refreshSessions() }
        val refreshed = awaitState { !it.refreshingSessions && it.sessions().contains("new") }
        assertTrue(refreshed.selectedConnection!!.sessionReady)
        assertSame(terminal, refreshed.selectedConnection!!.terminal)
        assertEquals("terminal", refreshed.selectedConnection!!.session!!.id)
        assertEquals(3, server.requestCount)
    }

    @Test
    fun returningAfterBackgroundDisconnectReattachesTheSameSessionWithoutRetry() {
        val server = server()
        val originalRoster = server.roster(roster("mac", "terminal"))
        connect(server)
        val initial = awaitState { it.sessions() == listOf("terminal") }
        val originalTerminal = server.roster(roster("mac", "terminal"))
        onMain { client.openSession(initial.machines.single().machine.id, RemoteSession("terminal", "Terminal")) }
        val attached = awaitState { it.selectedConnection?.sessionReady == true }
        onMain { attached.selectedConnection?.terminal?.transport?.sendInput("test prompt\r".toByteArray()) }
        assertEquals("test prompt\r", originalTerminal.inputs.poll(10, TimeUnit.SECONDS)?.utf8())

        onMain { client.setForeground(false) }
        originalRoster.authenticatedSocket().close(1001, "background test")
        originalTerminal.authenticatedSocket().close(1001, "background test")
        val background = awaitState { it.machines.single().connection.connected == false }
        assertEquals("terminal", background.selectedConnection?.session?.id)
        assertEquals(initial.machines.single().machine.id, background.selectedMachineID)

        val attachments = LinkedBlockingQueue<String>()
        server.roster(roster("mac", "terminal"), attachments)
        server.roster(roster("mac", "terminal"), attachments)
        onMain { client.setForeground(true) }
        val recovered = awaitState { it.selectedConnection?.sessionReady == true && it.machines.single().connection.connected }
        assertEquals("terminal", recovered.selectedConnection?.session?.id)
        assertEquals("terminal", attachments.poll(10, TimeUnit.SECONDS))
        assertNull(attachments.poll())
        assertEquals(4, server.requestCount)
    }

    @Test
    fun repeatedBackgroundReturnsReconnectEverySavedMacWithoutDuplicateConnections() {
        val first = server()
        val second = server()
        first.roster(roster("first", "one"))
        second.roster(roster("second", "two"))
        connect(first)
        connect(second)
        awaitState { it.machines.size == 2 && it.machines.all { machine -> machine.connection.connected } }

        repeat(3) { cycle ->
            onMain { client.setForeground(false) }
            val background = awaitState { it.machines.all { machine -> !machine.connection.connected } }
            assertEquals(listOf("one", "two"), background.sessions())
            first.roster(roster("first", "one"))
            second.roster(roster("second", "two"))
            onMain { client.setForeground(true) }
            awaitState { it.machines.all { machine -> machine.connection.connected } }
            onMain { client.setForeground(true) }
            assertEquals(cycle + 2, first.requestCount)
            assertEquals(cycle + 2, second.requestCount)
        }
    }

    @Test
    fun temporaryRosterFailureRecoversWithoutRetry() {
        val server = server()
        server.enqueue(MockResponse().setResponseCode(503))
        server.roster(roster("mac", "recovered"))
        connect(server)
        awaitState { it.machines.singleOrNull()?.connection?.error?.isNotEmpty() == true }
        val recovered = awaitState { it.machines.single().connection.connected }
        assertEquals(listOf("recovered"), recovered.sessions())
        assertEquals("", recovered.machines.single().connection.error)
        assertEquals(2, server.requestCount)
    }

    @Test
    fun foregroundRosterLossDoesNotDiscardTheLiveTerminal() {
        val server = server()
        val originalRoster = server.roster(roster("mac", "terminal"))
        connect(server)
        val initial = awaitState { it.sessions() == listOf("terminal") }
        server.roster(roster("mac", "terminal"))
        onMain { client.openSession(initial.machines.single().machine.id, RemoteSession("terminal", "Terminal")) }
        val attached = awaitState { it.selectedConnection?.sessionReady == true }
        val terminal = attached.selectedConnection?.terminal
        server.roster(roster("mac", "terminal", "new"))
        originalRoster.authenticatedSocket().close(1001, "roster disconnected")
        val disconnected = awaitState { !it.machines.single().connection.connected }
        assertTrue(disconnected.selectedConnection?.sessionReady == true)
        assertSame(terminal, disconnected.selectedConnection?.terminal)
        val recovered = awaitState { it.machines.single().connection.connected && it.sessions().contains("new") }
        assertSame(terminal, recovered.selectedConnection?.terminal)
        assertEquals("terminal", recovered.selectedConnection?.session?.id)
        assertEquals(3, server.requestCount)
    }

    @Test
    fun unauthorizedConnectionRequiresExplicitRetryAfterReturning() {
        val server = server()
        server.roster("""{"t":"error","code":"unauthorized"}""")
        connect(server)
        val failed = awaitState { it.machines.singleOrNull()?.connection?.error?.contains("Scan") == true }
        assertNotNull(server.takeRequest(10, TimeUnit.SECONDS))
        onMain { client.setForeground(false); client.setForeground(true) }
        assertNull(server.takeRequest(1500, TimeUnit.MILLISECONDS))
        assertEquals(failed.machines.single().connection.error, client.state.value.machines.single().connection.error)
    }

    @Test
    fun endedSessionIsNotReattachedOnReturn() {
        val server = server()
        server.roster(roster("mac", "terminal"))
        connect(server)
        val initial = awaitState { it.sessions() == listOf("terminal") }
        val terminal = server.roster(roster("mac", "terminal"))
        onMain { client.openSession(initial.machines.single().machine.id, RemoteSession("terminal", "Terminal")) }
        awaitState { it.selectedConnection?.sessionReady == true }
        terminal.authenticatedSocket().send("""{"t":"exit"}""")
        awaitState { it.selectedConnection?.sessionStatus == "Ended" }
        onMain { client.setForeground(false) }
        val attachments = LinkedBlockingQueue<String>()
        server.roster(roster("mac", "terminal"), attachments)
        onMain { client.setForeground(true) }
        val returned = awaitState { it.machines.single().connection.connected }
        assertEquals("Ended", returned.selectedConnection?.sessionStatus)
        assertNull(attachments.poll(1500, TimeUnit.MILLISECONDS))
        assertEquals(3, server.requestCount)
    }

    @Test
    fun deletingAMacCancelsItsPendingReconnect() {
        val server = server()
        server.enqueue(MockResponse().setResponseCode(503))
        connect(server)
        val failed = awaitState { it.machines.singleOrNull()?.connection?.error?.isNotEmpty() == true }
        assertNotNull(server.takeRequest(10, TimeUnit.SECONDS))
        onMain { client.deleteMachine(failed.machines.single().machine.id) }
        assertNull(server.takeRequest(1500, TimeUnit.MILLISECONDS))
        assertTrue(client.state.value.machines.isEmpty())
    }

    private fun server() = MockWebServer().also { it.start(); servers.add(it) }

    private fun connect(server: MockWebServer) {
        val address = server.url("/?t=test-token").toString()
        onMain { client.connect(address) }
    }

    private class RosterReply(val message: String?, val attachments: LinkedBlockingQueue<String>) : WebSocketListener() {
        val authentications = LinkedBlockingQueue<Pair<WebSocket, JSONObject>>()
        val inputs = LinkedBlockingQueue<ByteString>()
        override fun onMessage(webSocket: WebSocket, text: String) {
            val control = JSONObject(text)
            if (control.optString("t") == "attach") attachments.put(control.getString("session"))
            if (control.optString("t") == "auth") {
                authentications.put(webSocket to control)
                message?.let { webSocket.send(it) }
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            inputs.put(bytes)
        }

        fun authenticatedSocket(): WebSocket {
            val received = requireNotNull(authentications.poll(10, TimeUnit.SECONDS)) { "No authentication received" }
            assertEquals("test-token", received.second.getString("token"))
            assertEquals(CompanionProtocol.wireVersion, received.second.getInt("wire"))
            return received.first
        }
    }

    private fun MockWebServer.roster(message: String? = null, attachments: LinkedBlockingQueue<String> = LinkedBlockingQueue()) = RosterReply(message, attachments).also {
        enqueue(MockResponse().withWebSocketUpgrade(it))
    }

    private fun roster(macID: String, vararg sessions: String): String {
        val projects = JSONArray()
        if (sessions.isNotEmpty()) projects.put(JSONObject().put("id", "project").put("name", "Project")
            .put("sessions", JSONArray(sessions.map { JSONObject().put("id", it).put("title", it) })))
        return JSONObject().put("t", "roster").put("wire", CompanionProtocol.wireVersion)
            .put("macID", macID).put("macName", macID).put("projects", projects).toString()
    }

    private fun HomeState.sessions() = machines.flatMap { machine ->
        machine.connection.projects.flatMap { project -> project.sessions.map { it.id } }
    }

    private fun awaitState(timeout: Long = 10_000, predicate: (HomeState) -> Boolean): HomeState = runBlocking {
        withTimeout(timeout) { client.state.first(predicate) }
    }

    private fun <T> onMain(action: () -> T): T {
        val task = FutureTask(action)
        instrumentation.runOnMainSync(task)
        return task.get()
    }
}
