package sh.termio.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.Image
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
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

class MainActivity : ComponentActivity() {
    private val client: CompanionClient by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        window.statusBarColor = android.graphics.Color.rgb(14, 19, 27)
        @Suppress("DEPRECATION")
        window.navigationBarColor = android.graphics.Color.rgb(14, 19, 27)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(
                primary = Color(0xffa8c7ff),
                onPrimary = Color(0xff10284a),
                primaryContainer = Color(0xff263a54),
                onPrimaryContainer = Color(0xffd6e5ff),
                background = Color(0xff0e131b),
                onBackground = Color(0xffe5eaf2),
                surface = Color(0xff0e131b),
                onSurface = Color(0xffe5eaf2),
                surfaceContainer = Color(0xff171f2b),
                surfaceContainerLow = Color(0xff121a25),
                surfaceContainerHigh = Color(0xff202c3b),
                surfaceVariant = Color(0xff202c3b),
                onSurfaceVariant = Color(0xffa8b5c7),
                secondaryContainer = Color(0xff263a54),
                onSecondaryContainer = Color(0xffd6e5ff),
                outline = Color(0xff536174),
                outlineVariant = Color(0xff2d394a),
                error = Color(0xffffb4ab),
                errorContainer = Color(0xff37262b),
                onErrorContainer = Color(0xffffdad5),
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
    val selected = state.selectedConnection
    val inTerminal = selected?.session != null
    var collapsedMachineIDs by rememberSaveable { mutableStateOf(listOf<String>()) }
    val listState = rememberLazyListState()
    BackHandler(enabled = inTerminal || state.showingPairing) {
        if (inTerminal) client.leaveSession() else client.cancelPairing()
    }
    Scaffold(
        modifier = Modifier.imePadding(),
        topBar = {
            TopAppBar(
                title = {
                    Text(selected?.session?.title ?: "Termio", fontWeight = FontWeight.SemiBold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                },
                navigationIcon = {
                    if (inTerminal) IconButton(onClick = client::leaveSession) {
                        TermioIcon(TermioSymbol.Back, Modifier.size(22.dp), description = "Back")
                    }
                },
                actions = {
                    if (!inTerminal && state.machines.isNotEmpty() && !state.showingPairing) {
                        OutlinedButton(onClick = client::refreshSessions, enabled = !state.refreshingSessions,
                            shape = RoundedCornerShape(12.dp),
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                            modifier = Modifier.semantics {
                                if (state.refreshingSessions) stateDescription = "Refreshing sessions"
                            }) {
                            if (state.refreshingSessions) CircularProgressIndicator(Modifier.size(16.dp),
                                strokeWidth = 2.dp)
                            else TermioIcon(TermioSymbol.Refresh, Modifier.size(16.dp))
                            Spacer(Modifier.size(6.dp))
                            Text("Refresh", maxLines = 1)
                        }
                        Spacer(Modifier.size(8.dp))
                        FilledTonalButton(onClick = client::beginPairing,
                            shape = RoundedCornerShape(12.dp),
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp)) {
                            TermioIcon(TermioSymbol.Plus, Modifier.size(16.dp))
                            Spacer(Modifier.size(6.dp))
                            Text("Add Mac", maxLines = 1)
                        }
                        Spacer(Modifier.size(12.dp))
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        val modifier = Modifier.fillMaxSize().padding(padding)
        if (inTerminal && selected != null) key(state.selectedMachineID, selected.session?.id) {
            TerminalPage(selected, modifier)
        } else SessionList(state, client, modifier, listState, collapsedMachineIDs) { id ->
            collapsedMachineIDs = if (id in collapsedMachineIDs) collapsedMachineIDs - id
                else collapsedMachineIDs + id
        }
    }
}

@Composable
private fun PairPage(state: HomeState, client: CompanionClient, modifier: Modifier) {
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
        client.connect(scannedAddress)
    })
    Card(modifier, shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Image(painterResource(R.drawable.termio_icon), contentDescription = null,
                modifier = Modifier.size(56.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Connect a Mac", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
                if (state.machines.isNotEmpty()) TextButton(onClick = client::cancelPairing) { Text("Cancel") }
            }
            Text("In Termio on your Mac, open Settings ▸ Mobile, turn off Direct Attach, and scan the QR code.",
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = {
                focusManager.clearFocus()
                keyboard?.hide()
                cameraDenied = false
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                    scanning = true
                } else cameraPermission.launch(Manifest.permission.CAMERA)
            }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(12.dp)) {
                TermioIcon(TermioSymbol.Scan, Modifier.size(20.dp))
                Spacer(Modifier.size(8.dp))
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
                value = state.pairingAddress,
                onValueChange = client::editPairingAddress,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Mac Address") },
                leadingIcon = { TermioIcon(TermioSymbol.Link, Modifier.size(20.dp)) },
                shape = RoundedCornerShape(12.dp),
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                    keyboardType = KeyboardType.Uri,
                ),
            )
            FilledTonalButton(onClick = { client.connect(state.pairingAddress) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(12.dp)) {
                TermioIcon(TermioSymbol.Plus, Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Connect")
            }
            if (state.pairingError.isNotEmpty()) Text(state.pairingError, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun SessionList(
    state: HomeState,
    client: CompanionClient,
    modifier: Modifier,
    listState: LazyListState,
    collapsedMachineIDs: List<String>,
    toggleMachine: (String) -> Unit,
) {
    val reordering = remember { MachineReorderState() }
    val moveMachine: (String, String, Boolean) -> Unit = { id, targetID, after ->
        val firstVisibleIndex = listState.firstVisibleItemIndex
        val firstVisibleOffset = listState.firstVisibleItemScrollOffset
        client.moveMachine(id, targetID, after)
        listState.requestScrollToItem(firstVisibleIndex, firstVisibleOffset)
    }
    var pendingDeletionID by rememberSaveable { mutableStateOf<String?>(null) }
    val pendingDeletion = state.machines.firstOrNull { it.machine.id == pendingDeletionID }?.machine
    if (pendingDeletion != null) AlertDialog(
        onDismissRequest = { pendingDeletionID = null },
        title = { Text("Delete “${pendingDeletion.name}”?") },
        text = { Text("This removes the saved connection from this phone. Sessions on your Mac keep running.") },
        confirmButton = {
            TextButton(onClick = {
                pendingDeletionID = null
                client.deleteMachine(pendingDeletion.id)
            }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = {
            TextButton(onClick = { pendingDeletionID = null }) { Text("Cancel") }
        },
    )
    LaunchedEffect(state.showingPairing) {
        if (state.showingPairing) listState.scrollToItem(0)
    }
    MachineReorderContainer(state.machines, reordering, listState, moveMachine, modifier) {
        LazyColumn(Modifier.fillMaxSize(), state = listState,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 24.dp)) {
            if (state.showingPairing || state.machines.isEmpty()) item(key = "pairing") {
                PairPage(state, client, Modifier.fillMaxWidth().padding(bottom = 12.dp))
            }
            state.machines.forEachIndexed { index, linked ->
                val machine = linked.machine
                val connection = linked.connection
                val expanded = machine.id !in collapsedMachineIDs
                item(key = "${machine.id}:name") {
                    MachineHeader(linked, expanded, onToggle = { toggleMachine(machine.id) },
                        onDelete = { pendingDeletionID = machine.id },
                        onNewTerminal = { client.startTerminal(machine.id) },
                        reordering = reordering,
                        onMoveUp = state.machines.getOrNull(index - 1)?.let { previous ->
                            { moveMachine(machine.id, previous.machine.id, false) }
                        },
                        onMoveDown = state.machines.getOrNull(index + 1)?.let { next ->
                            { moveMachine(machine.id, next.machine.id, true) }
                        },
                        modifier = Modifier.padding(top = if (index == 0) 0.dp else 24.dp, bottom = 8.dp))
                }
                if (expanded) {
                    if (connection.error.isNotEmpty()) item(key = "${machine.id}:status") {
                        Surface(
                            modifier = Modifier.padding(top = 4.dp),
                            shape = RoundedCornerShape(16.dp),
                            color = MaterialTheme.colorScheme.errorContainer,
                            contentColor = MaterialTheme.colorScheme.onErrorContainer,
                        ) {
                            Column(Modifier.fillMaxWidth().padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                    TermioIcon(TermioSymbol.Alert, Modifier.size(20.dp))
                                    Text(connection.error, style = MaterialTheme.typography.bodyMedium,
                                        modifier = Modifier.weight(1f))
                                }
                                OutlinedButton(onClick = { client.retryMachine(machine.id) },
                                    shape = RoundedCornerShape(10.dp),
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        contentColor = MaterialTheme.colorScheme.onErrorContainer)) {
                                    TermioIcon(TermioSymbol.Refresh, Modifier.size(16.dp))
                                    Spacer(Modifier.size(8.dp))
                                    Text("Retry")
                                }
                            }
                        }
                    }
                    if (connection.connected && connection.error.isEmpty()) {
                        val sessions = connection.projects.flatMap { project ->
                            project.sessions.map { project.id to it }
                        }
                        if (sessions.isEmpty()) item(key = "${machine.id}:empty") {
                            Surface(shape = RoundedCornerShape(16.dp),
                                color = MaterialTheme.colorScheme.surfaceContainerLow) {
                                Row(Modifier.fillMaxWidth().padding(20.dp),
                                    horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                    TermioIcon(TermioSymbol.Terminal, Modifier.size(22.dp),
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text("Open a project or start a terminal on your Mac, or tap New Terminal here.",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                        itemsIndexed(sessions, key = { _, (projectID, session) ->
                            "${machine.id}:session:$projectID:${session.id}"
                        }) { sessionIndex, (_, session) ->
                            if (sessionIndex > 0) HorizontalDivider(Modifier.padding(start = 48.dp, end = 12.dp),
                                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f))
                            SessionRow(session, onOpen = { client.openSession(machine.id, session) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MachineHeader(
    linked: MachineState,
    expanded: Boolean,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
    onNewTerminal: () -> Unit,
    reordering: MachineReorderState,
    onMoveUp: (() -> Unit)?,
    onMoveDown: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val connection = linked.connection
    val count = connection.projects.sumOf { it.sessions.size }
    val id = linked.machine.id
    val canReorder = onMoveUp != null || onMoveDown != null
    val indicatorColor = MaterialTheme.colorScheme.primary
    DisposableEffect(id, reordering) {
        onDispose {
            reordering.headers.remove(id)
            reordering.handles.remove(id)
        }
    }
    Surface(modifier.fillMaxWidth()
        .onGloballyPositioned {
            reordering.headers[id] = it.boundsInRoot()
            reordering.updateTarget()
        }
        .alpha(if (reordering.draggedID == id) 0.45f else 1f)
        .drawWithContent {
            drawContent()
            reordering.target?.takeIf { it.id == id }?.let { target ->
                val y = if (target.after) size.height else 0f
                drawLine(indicatorColor, Offset(0f, y), Offset(size.width, y), strokeWidth = 3.dp.toPx())
            }
        }, shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surfaceContainer,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.padding(start = 12.dp).size(48.dp)
                    .onGloballyPositioned { reordering.handles[id] = it.boundsInRoot() }
                    .semantics {
                        if (canReorder) {
                            contentDescription = "Reorder ${linked.machine.name}"
                            customActions = buildList {
                                onMoveUp?.let { add(CustomAccessibilityAction("Move up") { it(); true }) }
                                onMoveDown?.let { add(CustomAccessibilityAction("Move down") { it(); true }) }
                            }
                        }
                    }, contentAlignment = Alignment.Center) {
                    Surface(shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.primaryContainer,
                        contentColor = MaterialTheme.colorScheme.onPrimaryContainer) {
                        Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
                            TermioIcon(if (canReorder) TermioSymbol.Drag else TermioSymbol.Machine, Modifier.size(22.dp))
                        }
                    }
                }
                Row(Modifier.weight(1f)
                    .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }
                    .clickable(role = Role.Button,
                        onClickLabel = if (expanded) "Collapse ${linked.machine.name}" else "Expand ${linked.machine.name}",
                        onClick = onToggle)
                    .padding(start = 8.dp, top = 14.dp, bottom = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(linked.machine.name, style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        if (connection.connected && connection.error.isEmpty()) Text(
                            "$count ${if (count == 1) "session" else "sessions"}",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    TermioIcon(TermioSymbol.ChevronDown,
                        Modifier.size(20.dp).rotate(if (expanded) 0f else -90f),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = onDelete) {
                    TermioIcon(TermioSymbol.Delete, Modifier.size(18.dp),
                        description = "Delete ${linked.machine.name}",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, bottom = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { ConnectionBadge(connection) }
                if (connection.connected && connection.error.isEmpty()) {
                    FilledTonalButton(onClick = onNewTerminal, enabled = !connection.loadingRoster,
                        shape = RoundedCornerShape(10.dp),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
                        TermioIcon(TermioSymbol.Plus, Modifier.size(16.dp))
                        Spacer(Modifier.size(6.dp))
                        Text("New Terminal")
                    }
                }
            }
        }
    }
}

@Composable
private fun ConnectionBadge(connection: CompanionState) {
    val color = when {
        connection.error.isNotEmpty() -> MaterialTheme.colorScheme.error
        connection.loadingRoster -> Color(0xffe9c784)
        connection.connected -> Color(0xff87d9b7)
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val label = if (connection.error.isNotEmpty()) "Connection issue"
        else connection.status.ifEmpty { "Not connected" }
    Surface(shape = RoundedCornerShape(6.dp), color = color.copy(alpha = 0.10f), contentColor = color) {
        Row(Modifier.padding(horizontal = 7.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(5.dp).background(color, CircleShape))
            Text(label, style = MaterialTheme.typography.labelSmall, maxLines = 1,
                overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun SessionRow(session: RemoteSession, onOpen: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)
        .heightIn(min = 64.dp).padding(horizontal = 12.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        TermioIcon(TermioSymbol.Terminal, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(session.title, style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface)
            val detail = listOf(session.agent, session.status).filter { it.isNotEmpty() }.joinToString(" · ")
            if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        TermioIcon(TermioSymbol.ChevronRight, Modifier.size(16.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun TerminalPage(state: CompanionState, modifier: Modifier) {
    val terminalState = rememberGhosttyTerminalState()
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
        GhosttyExtraKeysBar(state = terminalState, modifier = Modifier.fillMaxWidth())
    }
    GhosttyDialogs(terminalState)
}
