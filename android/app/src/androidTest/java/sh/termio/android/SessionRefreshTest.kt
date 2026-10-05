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

    private fun server() = MockWebServer().also { it.start(); servers.add(it) }

    private fun connect(server: MockWebServer) {
        val address = server.url("/?t=test-token").toString()
        onMain { client.connect(address) }
    }

    private class RosterReply(val message: String?) : WebSocketListener() {
        val authentications = LinkedBlockingQueue<Pair<WebSocket, JSONObject>>()
        override fun onMessage(webSocket: WebSocket, text: String) {
            val control = JSONObject(text)
            if (control.optString("t") == "auth") {
                authentications.put(webSocket to control)
                message?.let { webSocket.send(it) }
            }
        }

        fun authenticatedSocket(): WebSocket {
            val received = requireNotNull(authentications.poll(10, TimeUnit.SECONDS)) { "No authentication received" }
            assertEquals("test-token", received.second.getString("token"))
            assertEquals(CompanionProtocol.wireVersion, received.second.getInt("wire"))
            return received.first
        }
    }

    private fun MockWebServer.roster(message: String? = null) = RosterReply(message).also {
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
