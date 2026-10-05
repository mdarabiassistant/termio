package sh.termio.android

import android.text.InputType
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.test.platform.app.InstrumentationRegistry
import io.github.sagernet.libghostty.GhosttyTerminalSession
import io.github.sagernet.libghostty.GhosttyTerminalView
import java.io.ByteArrayOutputStream
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class TerminalInputTest {
    private lateinit var session: GhosttyTerminalSession
    private lateinit var view: GhosttyTerminalView
    private lateinit var connection: InputConnection
    private lateinit var editorInfo: EditorInfo
    private val sent = ByteArrayOutputStream()

    @Before
    fun setUp() = onMain {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        session = GhosttyTerminalSession(context)
        session.transport = object : GhosttyTerminalSession.Transport {
            override fun sendInput(data: ByteArray) { sent.write(data) }
            override fun sendResize(columns: Int, rows: Int, widthPixels: Int, heightPixels: Int) {}
            override fun close() {}
        }
        view = GhosttyTerminalView(context).also { it.session = session }
        editorInfo = EditorInfo()
        connection = view.onCreateInputConnection(editorInfo)
        sent.reset()
    }

    @After
    fun tearDown() = onMain {
        if (::view.isInitialized) view.session = null
        if (::session.isInitialized) session.close()
    }

    @Test
    fun terminalAcceptsTextWithoutAdvertisingAPasswordField() = onMain {
        assertTrue(view.onCheckIsTextEditor())
        assertEquals(InputType.TYPE_CLASS_TEXT, editorInfo.inputType and InputType.TYPE_MASK_CLASS)
        assertEquals(InputType.TYPE_TEXT_VARIATION_NORMAL, editorInfo.inputType and InputType.TYPE_MASK_VARIATION)
        assertTrue(editorInfo.inputType and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0)
        assertEquals(0, editorInfo.inputType and InputType.TYPE_TEXT_FLAG_AUTO_CORRECT)
        assertEquals(EditorInfo.IME_ACTION_NONE, editorInfo.imeOptions and EditorInfo.IME_MASK_ACTION)
    }

    @Test
    fun dictatedPhraseIsSentOnceWithoutSubmitting() = onMain {
        connection.commitText("Review these changes, please.", 1)
        connection.finishComposingText()
        assertEquals("Review these changes, please.", sentText())
    }

    @Test
    fun interimDictationStaysLocalUntilCommitted() = onMain {
        connection.beginBatchEdit()
        connection.setComposingText("Review", 1)
        connection.setComposingText("Review the change", 1)
        connection.setComposingText("Review the changes.", 1)
        assertEquals("", sentText())
        connection.commitText("Review these changes.", 1)
        connection.endBatchEdit()
        connection.finishComposingText()
        assertEquals("Review these changes.", sentText())
    }

    @Test
    fun finishingCompositionCommitsItOnlyOnce() = onMain {
        connection.setComposingText("hello", 1)
        connection.finishComposingText()
        connection.finishComposingText()
        assertEquals("hello", sentText())
    }

    @Test
    fun cancelledCompositionDoesNotReachTheSession() = onMain {
        connection.setComposingText("discard this", 1)
        connection.commitText("", 1)
        connection.finishComposingText()
        assertEquals("", sentText())
    }

    @Test
    fun unicodeCompositionPreservesTheFinalText() = onMain {
        connection.setComposingText("سلام", 1)
        connection.commitText("سلام 👋 café", 1)
        assertEquals("سلام 👋 café", sentText())
    }

    @Test
    fun typingAndBackspaceKeepTerminalSemantics() = onMain {
        connection.commitText("git status", 1)
        connection.deleteSurroundingText(1, 0)
        assertEquals("git status\u007f", sentText())
    }

    @Test
    fun keyboardEnterSubmitsOnce() = onMain {
        connection.commitText("hello", 1)
        connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
        connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        assertEquals("hello\r", sentText())
    }

    @Test
    fun keyboardEditorActionSubmitsOnce() = onMain {
        connection.commitText("hello", 1)
        connection.performEditorAction(EditorInfo.IME_ACTION_NONE)
        assertEquals("hello\r", sentText())
    }

    private fun sentText() = sent.toString(Charsets.UTF_8.name())

    private fun onMain(action: () -> Unit) {
        var failure: Throwable? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            try { action() } catch (error: Throwable) { failure = error }
        }
        failure?.let { throw it }
    }
}
