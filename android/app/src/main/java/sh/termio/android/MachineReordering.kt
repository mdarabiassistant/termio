package sh.termio.android

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlin.math.abs

internal data class MachineDropTarget(val id: String, val after: Boolean)

internal class MachineReorderState {
    val headers = mutableMapOf<String, Rect>()
    val handles = mutableMapOf<String, Rect>()
    var viewport by mutableStateOf(Rect.Zero)
    var draggedID by mutableStateOf<String?>(null)
    var pointerY by mutableFloatStateOf(0f)
    var target by mutableStateOf<MachineDropTarget?>(null)

    fun updateTarget() {
        if (draggedID == null) return
        val nearest = headers.entries.filter { (_, bounds) ->
            bounds.bottom > viewport.top && bounds.top < viewport.bottom
        }.minByOrNull { (_, bounds) ->
            when {
                pointerY < bounds.top -> bounds.top - pointerY
                pointerY > bounds.bottom -> pointerY - bounds.bottom
                else -> 0f
            }
        }
        target = nearest?.takeUnless { it.key == draggedID }?.let {
            MachineDropTarget(it.key, pointerY > it.value.center.y)
        }
    }

    fun clear() {
        draggedID = null
        target = null
    }
}

@Composable
internal fun MachineReorderContainer(
    machines: List<MachineState>,
    state: MachineReorderState,
    listState: LazyListState,
    onMove: (String, String, Boolean) -> Unit,
    modifier: Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    val move by rememberUpdatedState(onMove)
    val machineIDs = machines.map { it.machine.id }
    val currentIDs by rememberUpdatedState(machineIDs)
    val density = LocalDensity.current
    val edgeSize = with(density) { 64.dp.toPx() }
    val maximumSpeed = with(density) { 900.dp.toPx() }
    val previewHeight = with(density) { 48.dp.toPx() }
    val speed = if (state.draggedID == null) 0f else when {
        state.pointerY < state.viewport.top + edgeSize ->
            -maximumSpeed * ((state.viewport.top + edgeSize - state.pointerY) / edgeSize).coerceIn(0f, 1f)
        state.pointerY > state.viewport.bottom - edgeSize ->
            maximumSpeed * ((state.pointerY - state.viewport.bottom + edgeSize) / edgeSize).coerceIn(0f, 1f)
        else -> 0f
    }
    LaunchedEffect(machineIDs) {
        if (state.draggedID !in machineIDs) state.clear()
    }
    LaunchedEffect(state.draggedID, speed) {
        if (speed == 0f) return@LaunchedEffect
        var previous = withFrameNanos { it }
        while (state.draggedID != null) {
            val now = withFrameNanos { it }
            val elapsed = ((now - previous) / 1_000_000_000f).coerceAtMost(0.05f)
            previous = now
            val scrolled = listState.scrollBy(speed * elapsed)
            state.updateTarget()
            if (scrolled == 0f) break
        }
    }
    Box(modifier.onGloballyPositioned { state.viewport = it.boundsInRoot() }
        // Own the gesture here so scrolling the source header offscreen does not cancel it.
        .pointerInput(state) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                if (currentIDs.size < 2) return@awaitEachGesture
                val rootPosition = down.position + state.viewport.topLeft
                val id = state.handles.entries.firstOrNull { (id, bounds) ->
                    id in currentIDs && bounds.contains(rootPosition)
                }?.key ?: return@awaitEachGesture
                down.consume()
                try {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (id !in currentIDs) break
                        if (!change.pressed) {
                            state.updateTarget()
                            val target = state.target
                            // Compose marks the synthetic release from ACTION_CANCEL as consumed.
                            if (!change.isConsumed && state.draggedID != null && target != null) {
                                move(id, target.id, target.after)
                            }
                            change.consume()
                            break
                        }
                        change.consume()
                        if (state.draggedID == null && abs(change.position.y - down.position.y) > viewConfiguration.touchSlop) {
                            state.draggedID = id
                        }
                        if (state.draggedID != null) {
                            state.pointerY = change.position.y + state.viewport.top
                            state.updateTarget()
                        }
                    }
                } finally {
                    state.clear()
                }
            }
        }) {
        content()
        val dragged = machines.firstOrNull { it.machine.id == state.draggedID }
        if (dragged != null) Surface(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).graphicsLayer {
                translationY = (state.pointerY - state.viewport.top - previewHeight / 2)
                    .coerceIn(0f, (state.viewport.height - previewHeight).coerceAtLeast(0f))
            },
            shape = RoundedCornerShape(12.dp), shadowElevation = 8.dp,
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary),
            color = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ) {
            Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TermioIcon(TermioSymbol.Drag, Modifier.size(20.dp))
                Text(dragged.machine.name, style = MaterialTheme.typography.titleSmall,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
