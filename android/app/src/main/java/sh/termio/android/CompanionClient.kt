package sh.termio.android

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import io.github.sagernet.libghostty.GhosttyTerminalSession
import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject

data class RemoteSession(val id: String, val title: String, val agent: String = "", val status: String = "")
data class RemoteProject(val id: String, val name: String, val workspaceID: String,
    val workspaceName: String, val deviceAlias: String, val sessions: List<RemoteSession>)
data class CompanionState(
    val address: String = "",
    val macName: String = "Termio",
    val status: String = "",
    val error: String = "",
    val connected: Boolean = false,
    val hasRoster: Boolean = false,
    val projects: List<RemoteProject> = emptyList(),
    val session: RemoteSession? = null,
    val terminal: GhosttyTerminalSession? = null,
    val sessionStatus: String = "Connecting…",
    val sessionReady: Boolean = false,
)

data class PairingAddress(val url: String, val token: String)

object CompanionProtocol {
    const val wireVersion = 2

    fun pairingAddress(raw: String): PairingAddress {
        val uri = try { URI(raw.trim()) } catch (_: Exception) {
            throw IllegalArgumentException("Copy the address from Settings ▸ Mobile on your Mac.")
        }
        val scheme = when (uri.scheme?.lowercase()) {
            "ws", "http" -> "ws"
            "wss", "https" -> "wss"
            else -> throw IllegalArgumentException("Copy the address from Settings ▸ Mobile on your Mac.")
        }
        require(!uri.host.isNullOrEmpty() && uri.rawUserInfo == null && (uri.port == -1 || uri.port in 1..65535)) {
            "Copy the address from Settings ▸ Mobile on your Mac."
        }
        val token = uri.rawQuery.orEmpty().split('&').firstNotNullOfOrNull { field ->
            val parts = field.split('=', limit = 2)
            if (parts.size == 2 && parts[0] == "t") URLDecoder.decode(parts[1], "UTF-8") else null
        }
        require(!token.isNullOrEmpty()) { "The address has no pairing token. Copy it again from your Mac." }
        val url = scheme + ":" + uri.rawSchemeSpecificPart
        return PairingAddress(url, token)
    }

    fun authentication(token: String): String = JSONObject()
        .put("t", "auth").put("token", token).put("wire", wireVersion).toString()

    fun sessionPreamble(token: String, sessionID: String, columns: Int, rows: Int): List<String> =
        listOf(authentication(token), JSONObject().put("t", "attach").put("session", sessionID).toString(),
            viewport(columns, rows, true, columns, rows))

    fun viewport(columns: Int, rows: Int, rendering: Boolean, surfaceColumns: Int, surfaceRows: Int): String {
        val control = JSONObject().put("t", "resize").put("cols", columns).put("rows", rows)
            .put("rendering", rendering)
        if (surfaceColumns > 0 && surfaceRows > 0 && (surfaceColumns != columns || surfaceRows != rows)) {
            control.put("surfaceCols", surfaceColumns).put("surfaceRows", surfaceRows)
        }
        return control.toString()
    }

    fun projects(roster: JSONObject): List<RemoteProject> {
        val projects = roster.optJSONArray("projects") ?: return emptyList()
        return (0 until projects.length()).mapNotNull { index ->
            val project = projects.optJSONObject(index) ?: return@mapNotNull null
            val id = project.optString("id")
            if (id.isEmpty()) return@mapNotNull null
            val sessions = project.optJSONArray("sessions")
            val rows = if (sessions == null) emptyList() else (0 until sessions.length()).mapNotNull { row ->
                val session = sessions.optJSONObject(row) ?: return@mapNotNull null
                val sessionID = session.optString("id")
                if (sessionID.isEmpty()) null else RemoteSession(sessionID,
                    session.optString("title").ifEmpty { session.optString("name", "Session") },
                    session.optString("agent"), session.optString("status"))
            }
            RemoteProject(id, project.optString("name", "Project"), project.optString("workspaceID"),
                project.optString("workspaceName", "Workspace"), project.optString("deviceAlias"), rows)
        }
    }

    fun refusal(message: JSONObject): String = when (message.optString("code")) {
        "unauthorized" -> "This Mac didn’t recognize this phone. Copy its address again in Settings ▸ Mobile."
        "client_too_old" -> "Update Termio on this phone."
        else -> message.optString("message", "The Mac refused the request.")
    }
}

class CompanionClient(application: Application) : AndroidViewModel(application) {
    private val handler = Handler(Looper.getMainLooper())
    private val preferences = application.getSharedPreferences("companion", Application.MODE_PRIVATE)
    private val client = OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build()
    private val mutableState = MutableStateFlow(CompanionState(address = preferences.getString("address", "").orEmpty()))
    val state = mutableState.asStateFlow()
    private var pairing: PairingAddress? = null
    private var rosterSocket: WebSocket? = null
    private var sessionSocket: WebSocket? = null
    private var foreground = false
    private var sessionAuthenticated = false
    private var applyingSharedGrid = false
    private var viewportColumns = 80
    private var viewportRows = 24
    private var cellWidthPixels = 0
    private var cellHeightPixels = 0
    private val retryRoster = Runnable { if (pairing != null) dialRoster() }
    private val retrySession = Runnable { if (state.value.session != null) dialSession() }

    init {
        state.value.address.takeIf { it.isNotEmpty() }?.let(::connect)
    }

    fun connect(address: String) {
        val parsed = try { CompanionProtocol.pairingAddress(address) } catch (error: IllegalArgumentException) {
            mutableState.update { it.copy(error = error.message.orEmpty(), status = "") }
            return
        }
        stopConnections()
        pairing = parsed
        mutableState.value = CompanionState(address = parsed.url, status = "Connecting…")
        dialRoster()
    }

    private fun dialRoster() {
        val address = pairing ?: return
        handler.removeCallbacks(retryRoster)
        mutableState.update { it.copy(status = "Connecting…", connected = false) }
        rosterSocket = client.newWebSocket(Request.Builder().url(address.url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                handler.post { if (webSocket === rosterSocket) webSocket.send(CompanionProtocol.authentication(address.token)) }
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                handler.post { if (webSocket === rosterSocket) receiveRoster(text) }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w("CompanionClient", "Roster connection failed: ${t.javaClass.simpleName}")
                handler.post { rosterDisconnected(webSocket) }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                handler.post { rosterDisconnected(webSocket) }
            }
        })
    }

    private fun receiveRoster(text: String) {
        val message = decode(text) ?: return
        when (message.optString("t")) {
            "roster" -> {
                if (message.optInt("wire") < CompanionProtocol.wireVersion) {
                    stopConnections()
                    mutableState.update { it.copy(error = "Update Termio on your Mac to connect this phone.", status = "") }
                    return
                }
                preferences.edit().putString("address", pairing?.url).apply()
                mutableState.update { it.copy(hasRoster = true, connected = true, status = "Connected", error = "",
                    macName = message.optString("macName", "Termio"), projects = CompanionProtocol.projects(message)) }
            }
            "started" -> {
                val id = message.optString("session")
                if (id.isNotEmpty()) openSession(RemoteSession(id, "Terminal"))
            }
            "error" -> {
                mutableState.update { it.copy(error = CompanionProtocol.refusal(message)) }
                if (message.optString("code") in listOf("unauthorized", "client_too_old")) {
                    stopConnections()
                    mutableState.update { it.copy(status = "", connected = false, hasRoster = false) }
                }
            }
        }
    }

    private fun rosterDisconnected(socket: WebSocket) {
        if (socket !== rosterSocket || pairing == null) return
        mutableState.update { it.copy(connected = false, status = "Reconnecting…",
            error = if (it.hasRoster) it.error else "Couldn’t reach the Mac. Check Mobile Access and the address.") }
        handler.removeCallbacks(retryRoster)
        handler.postDelayed(retryRoster, 2500)
    }

    fun startTerminal() {
        if (!state.value.connected) return
        val control = JSONObject().put("t", "startTerminal")
        state.value.projects.firstOrNull()?.workspaceID?.takeIf { it.isNotEmpty() }?.let { control.put("workspace", it) }
        mutableState.update { it.copy(error = "") }
        rosterSocket?.send(control.toString())
    }

    fun openSession(session: RemoteSession) {
        leaveSession()
        mutableState.update { it.copy(session = session, sessionStatus = "Connecting…") }
        dialSession()
    }

    private fun dialSession() {
        val address = pairing ?: return
        val selected = state.value.session ?: return
        handler.removeCallbacks(retrySession)
        closeSessionSocket()
        state.value.terminal?.close()
        val terminal = GhosttyTerminalSession(getApplication())
        terminal.transport = object : GhosttyTerminalSession.Transport {
            override fun sendInput(data: ByteArray) {
                handler.post { if (state.value.terminal === terminal) this@CompanionClient.sendInput(data) }
            }
            override fun sendResize(columns: Int, rows: Int, widthPixels: Int, heightPixels: Int) {
                if (applyingSharedGrid || state.value.terminal !== terminal) return
                viewportColumns = columns
                viewportRows = rows
                cellWidthPixels = widthPixels / columns.coerceAtLeast(1)
                cellHeightPixels = heightPixels / rows.coerceAtLeast(1)
                reportViewport()
            }
            // The companion client owns the socket, separately from the renderer.
            override fun close() {}
        }
        mutableState.update { it.copy(terminal = terminal, sessionReady = false, sessionStatus = "Connecting…") }
        sessionSocket = client.newWebSocket(Request.Builder().url(address.url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                handler.post {
                    if (webSocket === sessionSocket) {
                        CompanionProtocol.sessionPreamble(address.token, selected.id, viewportColumns, viewportRows)
                            .forEach { webSocket.send(it) }
                        sessionAuthenticated = true
                        reportViewport()
                    }
                }
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                handler.post { if (webSocket === sessionSocket) receiveSession(text) }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                // Preserve the grid-control/frame order on the same queue.
                handler.post { if (webSocket === sessionSocket) terminal.feedOutput(bytes.toByteArray()) }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w("CompanionClient", "Session connection failed: ${t.javaClass.simpleName}")
                handler.post { sessionDisconnected(webSocket) }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                handler.post { sessionDisconnected(webSocket) }
            }
        })
    }

    private fun receiveSession(text: String) {
        val message = decode(text) ?: return
        when (message.optString("t")) {
            "roster" -> {
                if (message.optInt("wire") < CompanionProtocol.wireVersion) {
                    finishSession("Update Termio on your Mac to connect this phone.")
                } else mutableState.update { it.copy(sessionReady = true, sessionStatus = "Connected") }
            }
            "grid" -> {
                val columns = message.optInt("cols")
                val rows = message.optInt("rows")
                val terminal = state.value.terminal ?: return
                if (columns !in 1..4096 || rows !in 1..2048) {
                    finishSession("The Mac sent an invalid terminal size. Reconnect to this session.")
                    return
                }
                // The shared grid describes the incoming bytes, not this phone's viewport.
                applyingSharedGrid = true
                try {
                    val transport = terminal.transport
                    terminal.transport = null
                    terminal.resize(columns, rows, cellWidthPixels, cellHeightPixels)
                    terminal.transport = transport
                } finally {
                    applyingSharedGrid = false
                }
                reportViewport()
            }
            "exit" -> finishSession("Ended")
            "error" -> finishSession(CompanionProtocol.refusal(message))
        }
    }

    private fun sessionDisconnected(socket: WebSocket) {
        if (socket !== sessionSocket || state.value.session == null) return
        sessionAuthenticated = false
        mutableState.update { it.copy(sessionReady = false, sessionStatus = "Reconnecting…") }
        handler.removeCallbacks(retrySession)
        handler.postDelayed(retrySession, 2500)
    }

    private fun finishSession(status: String) {
        handler.removeCallbacks(retrySession)
        closeSessionSocket()
        state.value.terminal?.finish()
        mutableState.update { it.copy(sessionReady = false, sessionStatus = status) }
    }

    fun sendInput(data: ByteArray) {
        if (state.value.sessionReady) sessionSocket?.send(data.toByteString())
    }

    fun setForeground(visible: Boolean) {
        foreground = visible
        reportViewport()
    }

    private fun reportViewport(rendering: Boolean = foreground) {
        val terminal = state.value.terminal ?: return
        if (!sessionAuthenticated || viewportColumns < 1 || viewportRows < 1) return
        sessionSocket?.send(CompanionProtocol.viewport(viewportColumns, viewportRows, rendering,
            terminal.columns, terminal.rows))
    }

    fun leaveSession() {
        handler.removeCallbacks(retrySession)
        reportViewport(false)
        closeSessionSocket()
        state.value.terminal?.close()
        mutableState.update { it.copy(session = null, terminal = null, sessionReady = false) }
    }

    fun changeMac() {
        stopConnections()
        preferences.edit().remove("address").apply()
        mutableState.value = CompanionState()
    }

    private fun closeSessionSocket() {
        sessionAuthenticated = false
        val socket = sessionSocket
        sessionSocket = null
        socket?.close(1000, null)
    }

    private fun stopConnections() {
        handler.removeCallbacks(retryRoster)
        handler.removeCallbacks(retrySession)
        leaveSession()
        pairing = null
        val socket = rosterSocket
        rosterSocket = null
        socket?.close(1000, null)
    }

    private fun decode(text: String): JSONObject? = try { JSONObject(text) } catch (error: Exception) {
        Log.w("CompanionClient", "Unreadable companion control: ${error.javaClass.simpleName}")
        null
    }

    override fun onCleared() {
        stopConnections()
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }
}
