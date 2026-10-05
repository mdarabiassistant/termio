package sh.termio.android

import android.content.Context
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
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
    fun flatSessionsAndHeaderActionKeepTheCorrectMachine() {
        val snapshot = JSONObject(firstRoster.get())
        snapshot.getJSONArray("projects").put(JSONObject().put("id", "another-project")
            .put("name", "Another project").put("workspaceName", "Another workspace")
            .put("sessions", JSONArray().put(JSONObject().put("id", "cross-project")
                .put("title", "Session from another project"))))
        firstRoster.set(snapshot.toString())
        compose.onNodeWithText("Refresh").performClick()
        awaitText("Session from another project")
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
        fun roster(id: String, name: String, session: String): String = JSONObject()
            .put("t", "roster").put("wire", CompanionProtocol.wireVersion)
            .put("macID", id).put("macName", name)
            .put("projects", JSONArray().put(JSONObject().put("id", "project").put("name", "Project")
                .put("workspaceName", "Workspace").put("sessions", JSONArray().put(
                    JSONObject().put("id", session).put("title", session))))).toString()
    }
}
