package sh.termio.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.sagernet.libghostty.compose.GhosttyDialogs
import io.github.sagernet.libghostty.compose.GhosttyExtraKeysBar
import io.github.sagernet.libghostty.compose.GhosttyTerminal
import io.github.sagernet.libghostty.compose.rememberGhosttyTerminalState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val client: CompanionClient by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(
                primary = Color(0xff8eb5ff),
                background = Color(0xff15171c),
                surface = Color(0xff15171c),
            )) {
                TermioApp(client)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        client.setForeground(true)
    }

    override fun onStop() {
        client.setForeground(false)
        super.onStop()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TermioApp(client: CompanionClient) {
    val state by client.state.collectAsStateWithLifecycle()
    BackHandler(enabled = state.session != null) { client.leaveSession() }
    Scaffold(
        modifier = Modifier.imePadding(),
        topBar = {
            TopAppBar(
                title = {
                    Text(state.session?.title ?: state.macName,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                },
                navigationIcon = {
                    if (state.session != null) TextButton(onClick = client::leaveSession) { Text("Back") }
                },
                actions = {
                    if (state.hasRoster && state.session == null) {
                        TextButton(onClick = client::changeMac) { Text("Change Mac") }
                    }
                },
            )
        },
    ) { padding ->
        val modifier = Modifier.fillMaxSize().padding(padding)
        when {
            state.session != null -> TerminalPage(state, modifier)
            state.hasRoster -> SessionList(state, client, modifier)
            else -> PairPage(state, client, modifier)
        }
    }
}

@Composable
private fun PairPage(state: CompanionState, client: CompanionClient, modifier: Modifier) {
    var address by rememberSaveable(state.address) { mutableStateOf(state.address) }
    var scanning by rememberSaveable { mutableStateOf(false) }
    var cameraDenied by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        cameraDenied = !granted
        scanning = granted
    }
    if (scanning) QrScanner(onDismiss = { scanning = false }, onScan = { scannedAddress ->
        scanning = false
        address = scannedAddress
        client.connect(scannedAddress)
    })
    Column(modifier.verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Image(painterResource(R.drawable.termio_icon), contentDescription = null,
            modifier = Modifier.size(64.dp))
        Text("Connect a Mac", style = MaterialTheme.typography.headlineSmall)
        Text("In Termio on your Mac, open Settings ▸ Mobile, turn off Direct Attach, and scan the QR code.",
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Button(onClick = {
            focusManager.clearFocus()
            keyboard?.hide()
            cameraDenied = false
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                scanning = true
            } else cameraPermission.launch(Manifest.permission.CAMERA)
        }, modifier = Modifier.fillMaxWidth(), enabled = state.status != "Connecting…") {
            Text("Scan QR Code")
        }
        if (cameraDenied) {
            Text("Allow camera access to scan a QR code, or paste the Mac address below.",
                color = MaterialTheme.colorScheme.error)
            TextButton(onClick = {
                context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", context.packageName, null)))
            }) { Text("Open Settings") }
        }
        OutlinedTextField(
            value = address,
            onValueChange = { address = it },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Mac Address") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                keyboardType = KeyboardType.Uri,
            ),
        )
        Button(onClick = { client.connect(address) }, enabled = state.status != "Connecting…") {
            Text("Connect")
        }
        if (state.error.isNotEmpty()) Text(state.error, color = MaterialTheme.colorScheme.error)
        else if (state.status.isNotEmpty()) Text(state.status, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SessionList(state: CompanionState, client: CompanionClient, modifier: Modifier) {
    LazyColumn(modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(state.status, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                Button(onClick = client::startTerminal, enabled = state.connected) { Text("New Terminal") }
            }
        }
        if (state.error.isNotEmpty()) item { Text(state.error, color = MaterialTheme.colorScheme.error) }
        if (state.projects.isEmpty()) item {
            Text("Open a project or start a terminal on your Mac, or tap New Terminal here.")
        }
        state.projects.groupBy { it.workspaceName }.forEach { (workspace, projects) ->
            item { Text(workspace, style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(top = 12.dp)) }
            items(projects, key = { it.id }) { project ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(project.name, style = MaterialTheme.typography.titleMedium)
                        if (project.deviceAlias.isNotEmpty()) Text(project.deviceAlias,
                            style = MaterialTheme.typography.bodySmall)
                        project.sessions.forEach { session ->
                            TextButton(onClick = { client.openSession(session) }, modifier = Modifier.fillMaxWidth()) {
                                Column(Modifier.fillMaxWidth()) {
                                    Text(session.title)
                                    Text(listOf(session.agent, session.status).filter { it.isNotEmpty() }.joinToString(" · "),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }
            }
        }
        item { Spacer(Modifier.size(12.dp)) }
    }
}

@Composable
private fun TerminalPage(state: CompanionState, modifier: Modifier) {
    val terminalState = rememberGhosttyTerminalState()
    val coroutineScope = rememberCoroutineScope()
    var command by rememberSaveable(state.session?.id) { mutableStateOf("") }
    var sendingCommand by remember { mutableStateOf(false) }
    val inputReady = state.sessionReady && terminalState.view != null && !sendingCommand
    val sendCommand: () -> Unit = {
        val view = terminalState.view
        val terminal = state.terminal
        if (inputReady && view != null) {
            val text = command
            command = ""
            sendingCommand = true
            coroutineScope.launch {
                try {
                    view.sendText(text)
                    // Codex treats Enter within a text burst as a pasted newline.
                    if (text.isNotEmpty()) delay(200)
                    if (terminalState.view === view && view.session === terminal) {
                        view.sendKey(KeyEvent.KEYCODE_ENTER)
                    }
                } finally {
                    sendingCommand = false
                }
            }
        }
    }
    Column(modifier) {
        Text(state.sessionStatus, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        GhosttyTerminal(
            session = state.terminal,
            state = terminalState,
            modifier = Modifier.weight(1f).fillMaxWidth().clipToBounds(),
            fontSizeSp = 14f,
            focusOnAttach = true,
            darkColorScheme = true,
        )
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            GhosttyExtraKeysBar(state = terminalState, modifier = Modifier.weight(1f))
            Button(onClick = { terminalState.view?.sendKey(KeyEvent.KEYCODE_ENTER) },
                enabled = inputReady, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Enter") }
        }
        Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = command,
                onValueChange = { command = it },
                label = { Text("Type a command") },
                modifier = Modifier.weight(1f),
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false, imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { if (inputReady) sendCommand() }),
            )
            Button(onClick = sendCommand, enabled = inputReady) { Text("Send") }
        }
    }
    GhosttyDialogs(terminalState)
}
