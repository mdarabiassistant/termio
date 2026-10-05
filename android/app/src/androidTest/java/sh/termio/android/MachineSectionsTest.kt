package sh.termio.android

import android.content.Context
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.swipeUp
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicReference
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

class MachineSectionsTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val preferences = context.getSharedPreferences("companion", Context.MODE_PRIVATE)
    private val servers = mutableListOf<MockWebServer>()
    private val messages = ConcurrentLinkedQueue<Pair<MockWebServer, JSONObject>>()
    private lateinit var savedPreferences: Map<String, *>
    private lateinit var first: MockWebServer
    private lateinit var second: MockWebServer
    private lateinit var scenario: ActivityScenario<MainActivity>
    private val firstRoster = AtomicReference(roster("first", "Studio Mac", "First session"))

    @Before
    fun setUp() {
        savedPreferences = preferences.all
        first = server(firstRoster)
        second = server(AtomicReference(roster("second", "Build Mac", "Second session")))
        val machines = listOf(
            PairedMachine("first", first.url("/?t=test").toString(), "Studio Mac", "first"),
            PairedMachine("second", second.url("/?t=test").toString(), "Build Mac", "second"),
        )
        preferences.edit().clear().putString("machines", PairedMachines.encode(machines)).commit()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitText("First session")
    }

    @After
    fun tearDown() {
        if (::scenario.isInitialized) scenario.close()
        servers.forEach { it.shutdown() }
        if (::savedPreferences.isInitialized) preferences.edit().clear().apply {
            savedPreferences.forEach { (key, value) ->
                when (value) {
                    is String -> putString(key, value)
                    is Boolean -> putBoolean(key, value)
                    is Int -> putInt(key, value)
                    is Long -> putLong(key, value)
                    is Float -> putFloat(key, value)
                    is Set<*> -> putStringSet(key, value.filterIsInstance<String>().toSet())
                }
            }
        }.commit()
    }

    @Test
    fun collapseIsIndependentAndSurvivesRefreshAndTerminalNavigation() {
        compose.onNodeWithText("Studio Mac").performClick()
        assertCollapsed("Studio Mac")
        compose.onNodeWithText("First session").assertDoesNotExist()
        compose.onNodeWithText("Second session").performScrollTo().assertIsDisplayed()
        assertEquals(1, first.requestCount)
        assertEquals(1, second.requestCount)

        firstRoster.set(roster("first", "Studio Mac", "Added while collapsed"))
        compose.onNodeWithText("Refresh").performClick()
        compose.waitUntil(10_000) { first.requestCount == 2 && second.requestCount == 2 }
        compose.waitForIdle()
        assertCollapsed("Studio Mac")
        compose.onNodeWithText("Added while collapsed").assertDoesNotExist()

        compose.onNodeWithText("Second session").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Back").performClick()
        assertCollapsed("Studio Mac")
        compose.onNodeWithText("Studio Mac").performScrollTo().performClick()
        awaitText("Added while collapsed")
        compose.onNodeWithText("Added while collapsed").assertIsDisplayed()
        compose.onNodeWithText("First session").assertDoesNotExist()
    }

    @Test
    fun draggingBothDirectionsPreservesConnectionsCollapseAndSavedOrder() {
        compose.onNodeWithText("Studio Mac").performClick()
        dragMachine("Studio Mac", "Build Mac", after = true)
        assertEquals(listOf("second", "first"), savedOrder())
        assertCollapsed("Studio Mac")
        compose.onNodeWithText("First session").assertDoesNotExist()
        compose.onNodeWithText("Second session").assertIsDisplayed()
        assertEquals(1, first.requestCount)
        assertEquals(1, second.requestCount)

        compose.onNodeWithText("Refresh").performClick()
        compose.waitUntil(10_000) { first.requestCount == 2 && second.requestCount == 2 }
        compose.waitForIdle()
        assertEquals(listOf("second", "first"), savedOrder())
        assertCollapsed("Studio Mac")

        scenario.close()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitText("First session")
        val firstTop = compose.onNodeWithText("Studio Mac").fetchSemanticsNode().boundsInRoot.top
        val secondTop = compose.onNodeWithText("Build Mac").fetchSemanticsNode().boundsInRoot.top
        org.junit.Assert.assertTrue(firstTop > secondTop)
        dragMachine("Studio Mac", "Build Mac", after = false)
        assertEquals(listOf("first", "second"), savedOrder())
    }

    @Test
    fun cancelledDragKeepsTheOriginalOrder() {
        dragMachine("Studio Mac", "Build Mac", after = true, cancel = true)
        assertEquals(listOf("first", "second"), savedOrder())
        compose.onNodeWithText("First session").assertIsDisplayed()
        assertEquals(1, first.requestCount)
        assertEquals(1, second.requestCount)
    }

    @Test
    fun dragScrollsPastOffscreenMachinesAndNormalListScrollingStillWorks() {
        scenario.close()
        val machines = PairedMachines.restore(preferences.getString("machines", null), null).toMutableList()
        for (index in 3..7) {
            val id = "machine-$index"
            val name = "Machine $index"
            val server = server(AtomicReference(roster(id, name, "Session $index")))
            machines.add(PairedMachine(id, server.url("/?t=test").toString(), name, id))
        }
        preferences.edit().putString("machines", PairedMachines.encode(machines)).commit()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitText("First session")
        compose.onRoot().performTouchInput { swipeUp() }
        compose.onNodeWithText("Studio Mac").assertIsNotDisplayed()
        assertEquals(machines.map { it.id }, savedOrder())
        compose.onNode(hasScrollAction()).performScrollToIndex(0)

        val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
        val handle = compose.onNodeWithContentDescription("Reorder Studio Mac").fetchSemanticsNode().boundsInRoot
        compose.mainClock.autoAdvance = false
        try {
            compose.onRoot().performTouchInput {
                down(handle.center - root.topLeft)
                moveTo(Offset(handle.center.x - root.left, root.height - 4f))
            }
            compose.mainClock.advanceTimeBy(3_000)
            compose.onRoot().performTouchInput { up() }
        } finally {
            compose.mainClock.autoAdvance = true
        }
        compose.waitForIdle()
        assertEquals(machines.drop(1).map { it.id } + "first", savedOrder())
    }

    @Test
    fun localAndRemoteSessionsKeepMachineGroupsWithoutProjectHeadings() {
        val snapshot = JSONObject(firstRoster.get()).put("projects", JSONArray()
            .put(project("remote-one", "Remote Mac", "Remote 1", "Remote 2"))
            .put(project("local-one", null, "Local 1", "Local 2"))
            .put(project("remote-two", "Remote Mac", "Remote 3", "Remote 4"))
            .put(project("local-two", null, "Local 3").put("deviceAlias", JSONObject.NULL)))
        firstRoster.set(snapshot.toString())
        compose.onNodeWithText("Refresh").performClick()
        awaitText("Local 1")

        val expected = listOf("This machine", "Local 1", "Local 2", "Local 3",
            "Remote Mac", "Remote 1", "Remote 2", "Remote 3", "Remote 4")
        expected.zipWithNext().forEach { (before, after) ->
            compose.onNodeWithText(before).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText(after).performScrollTo().assertIsDisplayed()
            assertTrue(compose.onNodeWithText(before).fetchSemanticsNode().boundsInRoot.top <
                compose.onNodeWithText(after).fetchSemanticsNode().boundsInRoot.top)
        }
        compose.onNodeWithText("Hidden project").assertDoesNotExist()
        compose.onNodeWithText("Development").assertDoesNotExist()
        compose.onNodeWithText("Remote 4").performClick()
        compose.waitUntil(10_000) {
            messages.any { (server, message) -> server === first &&
                message.optString("t") == "attach" && message.optString("session") == "Remote 4" }
        }
        assertTrue(messages.none { (server, message) -> server === second && message.optString("t") == "attach" })
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Studio Mac").performScrollTo().performClick()
        compose.onNodeWithText("This machine").assertDoesNotExist()
        compose.onNodeWithText("Remote Mac").assertDoesNotExist()
        compose.onNodeWithText("Studio Mac").performClick()
        compose.onNodeWithText("This machine").assertIsDisplayed()
        compose.onNodeWithText("Remote Mac").performScrollTo().assertIsDisplayed()
    }

    @Test
    fun remoteOnlyRosterStillNamesTheRemoteMachine() {
        firstRoster.set(JSONObject(firstRoster.get()).put("projects", JSONArray()
            .put(project("remote", "Remote Mac", "Remote session"))).toString())
        compose.onNodeWithText("Refresh").performClick()
        awaitText("Remote session")
        compose.onNodeWithText("Remote Mac").assertIsDisplayed()
        compose.onNodeWithText("This machine").assertDoesNotExist()
    }

    @Test
    fun flatSessionsAndHeaderActionKeepTheCorrectMachine() {
        val snapshot = JSONObject(firstRoster.get())
        snapshot.getJSONArray("projects").put(JSONObject().put("id", "another-project")
            .put("name", "Another project").put("workspaceName", "Another workspace")
            .put("sessions", JSONArray().put(JSONObject().put("id", "cross-project")
                .put("title", "Session from another project"))))
        firstRoster.set(snapshot.toString())
        compose.onNodeWithText("Refresh").performClick()
        awaitText("Session from another project")
        compose.onNodeWithText("This machine").assertDoesNotExist()
        compose.onNodeWithText("Another project").assertDoesNotExist()
        compose.onNodeWithText("Another workspace").assertDoesNotExist()
        compose.onNodeWithText("Session from another project").performScrollTo().performClick()
        compose.waitUntil(10_000) {
            messages.any { (server, message) ->
                server === first && message.optString("t") == "attach" &&
                    message.optString("session") == "cross-project"
            }
        }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Studio Mac").performScrollTo().performClick()
        assertCollapsed("Studio Mac")
        compose.onAllNodesWithText("New Terminal")[0].performClick()
        compose.waitUntil(10_000) { messages.any { it.second.optString("t") == "startTerminal" } }
        val starts = messages.filter { it.second.optString("t") == "startTerminal" }
        assertEquals(listOf(first), starts.map { it.first })
        assertCollapsed("Studio Mac")
    }

    @Test
    fun collapseSurvivesRecreationAndExistingDialogsRemainAvailable() {
        compose.onNodeWithText("Studio Mac").performClick()
        scenario.recreate()
        awaitText("Studio Mac")
        assertCollapsed("Studio Mac")
        compose.onNodeWithText("First session").assertDoesNotExist()

        compose.onNodeWithContentDescription("Delete Studio Mac").performClick()
        compose.onNodeWithText("Delete “Studio Mac”?").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        assertCollapsed("Studio Mac")

        compose.onNodeWithText("Add Mac").performClick()
        compose.onNodeWithText("Connect a Mac").assertIsDisplayed()
        compose.onNodeWithText("Scan QR Code").assertIsEnabled()
        compose.onNodeWithText("Cancel").performClick()
        assertCollapsed("Studio Mac")
    }

    private fun assertCollapsed(name: String) {
        compose.onNodeWithText(name).assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Collapsed"))
    }

    private fun savedOrder() = PairedMachines.restore(preferences.getString("machines", null), null).map { it.id }

    private fun dragMachine(name: String, targetName: String, after: Boolean, cancel: Boolean = false) {
        val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
        val source = compose.onNodeWithContentDescription("Reorder $name").fetchSemanticsNode().boundsInRoot
        val target = compose.onNodeWithContentDescription("Reorder $targetName").fetchSemanticsNode().boundsInRoot
        val destination = Offset(source.center.x, if (after) target.bottom + target.height else target.top)
        compose.onRoot().performTouchInput {
            if (cancel) {
                down(source.center - root.topLeft)
                moveTo(destination - root.topLeft)
                cancel()
            } else swipe(source.center - root.topLeft, destination - root.topLeft, durationMillis = 500)
        }
        compose.waitForIdle()
    }

    private fun awaitText(text: String) {
        compose.waitUntil(10_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun server(snapshot: AtomicReference<String>) = MockWebServer().also { server ->
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        val message = JSONObject(text)
                        messages.add(server to message)
                        if (message.optString("t") == "auth") webSocket.send(snapshot.get())
                    }
                })
        }
        server.start()
        servers.add(server)
    }

    private companion object {
        fun project(id: String, alias: String?, vararg sessions: String) = JSONObject()
            .put("id", id).put("name", "Hidden project").put("workspaceName", "Development")
            .apply { if (alias != null) put("deviceAlias", alias) }
            .put("sessions", JSONArray().apply {
                sessions.forEach { put(JSONObject().put("id", it).put("title", it)) }
            })

        fun roster(id: String, name: String, session: String): String = JSONObject()
            .put("t", "roster").put("wire", CompanionProtocol.wireVersion)
            .put("macID", id).put("macName", name)
            .put("projects", JSONArray().put(JSONObject().put("id", "project").put("name", "Project")
                .put("workspaceName", "Workspace").put("sessions", JSONArray().put(
                    JSONObject().put("id", session).put("title", session))))).toString()
    }
}
