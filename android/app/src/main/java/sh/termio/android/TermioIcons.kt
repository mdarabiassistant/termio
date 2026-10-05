package sh.termio.android

import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp

internal enum class TermioSymbol(val path: String) {
    Drag("M8,6 H8.01 M16,6 H16.01 M8,12 H8.01 M16,12 H16.01 M8,18 H8.01 M16,18 H16.01"),
    Machine("M4,4 H20 Q21,4 21,5 V15 Q21,16 20,16 H4 Q3,16 3,15 V5 Q3,4 4,4 Z M12,16 V20 M8,20 H16"),
    Refresh("M20,10 A8,8 0,0 0,6,6 L3,9 M3,4 V9 H8 M4,14 A8,8 0,0 0,18,18 L21,15 M16,15 H21 V20"),
    Plus("M12,5 V19 M5,12 H19"),
    ChevronDown("M6,9 L12,15 L18,9"),
    ChevronRight("M9,6 L15,12 L9,18"),
    Back("M19,12 H5 M11,6 L5,12 L11,18"),
    Delete("M4,7 H20 M9,7 V4 H15 V7 M6,7 L7,20 H17 L18,7 M10,10 V17 M14,10 V17"),
    Terminal("M5,6 L10,11 L5,16 M13,17 H20"),
    Link("M10,13 L14,9 M8,15 L6,17 A4,4 0,0 1,1,12 L5,8 A4,4 0,0 1,11,8 M13,16 A4,4 0,0 0,19,16 L23,12 A4,4 0,0 0,18,7 L16,9"),
    Scan("M8,3 H3 V8 M16,3 H21 V8 M3,16 V21 H8 M21,16 V21 H16 M7,7 H10 V10 H7 Z M14,7 H17 V10 H14 Z M7,14 H10 V17 H7 Z M14,14 H17 V17"),
    Alert("M12,8 V12 M12,16 H12.01 M10.3,4.8 L2.5,18.2 Q1.5,20 3.6,20 H20.4 Q22.5,20 21.5,18.2 L13.7,4.8 Q12,2 10.3,4.8 Z"),
}

@Composable
internal fun TermioIcon(
    symbol: TermioSymbol,
    modifier: Modifier = Modifier,
    description: String? = null,
    tint: Color = androidx.compose.material3.LocalContentColor.current,
) {
    val vector = remember(symbol) {
        ImageVector.Builder(name = symbol.name, defaultWidth = 24.dp, defaultHeight = 24.dp,
            viewportWidth = 24f, viewportHeight = 24f,
            autoMirror = symbol == TermioSymbol.Back || symbol == TermioSymbol.ChevronRight)
            .addPath(pathData = PathParser().parsePathString(symbol.path).toNodes(),
                fill = null, stroke = SolidColor(Color.White), strokeLineWidth = 1.7f,
                strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
            .build()
    }
    Icon(vector, contentDescription = description, modifier = modifier, tint = tint)
}
