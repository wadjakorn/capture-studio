package dev.wadjakorn.capturestudio.phone.ui

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.view.Surface as ViewSurface
import android.view.WindowManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.wadjakorn.capturestudio.phone.DeviceOrientation
import dev.wadjakorn.capturestudio.phone.PairedMac
import dev.wadjakorn.capturestudio.phone.PairingCode
import dev.wadjakorn.capturestudio.phone.PairingStore
import dev.wadjakorn.capturestudio.phone.SessionState
import dev.wadjakorn.capturestudio.phone.StreamService
import dev.wadjakorn.capturestudio.phone.VideoPipeline
import java.text.DateFormat
import java.util.Date

private fun cameraMicGranted(context: Context): Boolean =
    listOf(android.Manifest.permission.CAMERA, android.Manifest.permission.RECORD_AUDIO).all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

@Composable
fun MainScreen() {
    val context = LocalContext.current
    var permsGranted by remember { mutableStateOf(cameraMicGranted(context)) }
    var batteryOk by remember { mutableStateOf(isBatteryUnrestricted(context)) }
    // Returning users with permissions already granted skip onboarding.
    var onboarded by rememberSaveable { mutableStateOf(permsGranted) }
    var userStopped by rememberSaveable { mutableStateOf(false) }

    fun recheck() {
        permsGranted = cameraMicGranted(context)
        batteryOk = isBatteryUnrestricted(context)
    }

    // Re-check on every resume; start the service from the visible activity only.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        recheck()
        if (onboarded && permsGranted && !userStopped && !StreamService.isRunning) StreamService.start(context)
    }

    Surface(Modifier.fillMaxSize()) {
        if (!onboarded || !permsGranted) {
            OnboardingScreen(
                permsGranted = permsGranted,
                batteryOk = batteryOk,
                onRecheck = ::recheck,
                onContinue = {
                    onboarded = true
                    userStopped = false
                    if (permsGranted && !StreamService.isRunning) StreamService.start(context)
                },
            )
        } else {
            Dashboard(
                onUserStopped = { userStopped = true },
                onToggleService = { running ->
                    if (running) {
                        userStopped = true
                        StreamService.stop(context)
                    } else {
                        userStopped = false
                        StreamService.start(context)
                    }
                },
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Dashboard(onUserStopped: () -> Unit, onToggleService: (running: Boolean) -> Unit) {
    val context = LocalContext.current
    val state by StreamService.sessionState.collectAsStateWithLifecycle()
    val request by StreamService.pairingRequest.collectAsStateWithLifecycle()
    val settings by StreamService.settings.collectAsStateWithLifecycle()
    val store = remember { PairingStore.get(context) }
    val paired by store.paired.collectAsStateWithLifecycle()
    val streaming = state is SessionState.Streaming

    val running by StreamService.running.collectAsStateWithLifecycle()
val caps by VideoPipeline.caps.collectAsStateWithLifecycle()
    // Service went away (notification Stop, startup failure): don't auto-restart on resume.
    var wasRunning by remember { mutableStateOf(false) }
    LaunchedEffect(running) {
        if (wasRunning && !running) onUserStopped()
        wasRunning = running
    }

    val prefs = remember { context.getSharedPreferences("ui", Context.MODE_PRIVATE) }
    var keepOn by remember { mutableStateOf(prefs.getBoolean("keep_screen_on", false)) }
    val window = (context as? Activity)?.window
    DisposableEffect(keepOn) {
        if (keepOn) window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Status", style = MaterialTheme.typography.titleMedium)
                Text(
                    when {
                        !running -> "Stopped"
                        state is SessionState.Streaming -> "Streaming to ${(state as SessionState.Streaming).macName}"
                        state is SessionState.Connected -> "Connected to ${(state as SessionState.Connected).macName}"
                        else -> "Advertising on Wi-Fi as ${Build.MODEL}"
                    },
                )
                if (running) {
                    OutlinedButton(onClick = { onToggleService(true) }) { Text("Stop") }
                } else {
                    Button(onClick = { onToggleService(false) }) { Text("Start") }
                }
            }
        }

        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Camera", style = MaterialTheme.typography.titleMedium)
                val facing = settings.facing
                Choice(listOf("back" to "Back", "front" to "Front"), facing, !streaming) { v ->
                    StreamService.updateSettings(context) { it.copy(facing = v) }
                }
                val height = settings.height
                Choice(listOf(720 to "720p", 1080 to "1080p"), height, !streaming) { h ->
                    StreamService.updateSettings(context) { it.copy(width = if (h == 1080) 1920 else 1280, height = h) }
                }
                Text("Aspect", style = MaterialTheme.typography.bodyMedium)
                Choice(listOf("16:9" to "16:9", "4:3" to "4:3", "1:1" to "1:1"), settings.aspect ?: "16:9", !streaming) { a ->
                    StreamService.updateSettings(context) { it.copy(aspect = a) }
                }
                if (streaming) Text("Settings apply to the next stream.", style = MaterialTheme.typography.bodySmall)
                val zoom = settings.zoom ?: 1f
                Text("Zoom  ${"%.1f".format(zoom)}×", style = MaterialTheme.typography.bodyMedium)
                Slider(
                    value = zoom,
                    onValueChange = { z -> StreamService.updateSettings(context) { it.copy(zoom = z) } },
                    valueRange = (caps?.minZoom ?: 1f)..(caps?.maxZoom ?: 10f),
                )
                Text("A fixed zoom also pins the lens the phone uses.", style = MaterialTheme.typography.bodySmall)
                Text("Focus", style = MaterialTheme.typography.bodyMedium)
                Choice(listOf("auto" to "Auto", "locked" to "Locked", "manual" to "Manual"), settings.focus ?: "auto", true) { f ->
                    StreamService.updateSettings(context) { it.copy(focus = if (f == "auto") null else f) }
                }
                if (settings.focus == "manual") {
                    if (caps?.manualFocus == false) {
                        Text("This camera has no manual focus.", style = MaterialTheme.typography.bodySmall)
                    }
                    Text("Distance  far ← → near", style = MaterialTheme.typography.bodySmall)
                    Slider(
                        value = settings.focusDistance ?: 0f,
                        onValueChange = { d -> StreamService.updateSettings(context) { it.copy(focusDistance = d) } },
                        valueRange = 0f..1f,
                    )
                } else if (settings.focus == "locked") {
                    Text("Focuses once on the centre when the stream starts, then holds.", style = MaterialTheme.typography.bodySmall)
                }
                val locked = settings.lockedRotation
                Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Lock orientation")
                        if (locked != null) {
                            Text("Locked to ${rotationName(locked)}", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    Switch(checked = locked != null, onCheckedChange = { on ->
                        StreamService.updateSettings(context) {
                            it.copy(lockedRotation = if (on) DeviceOrientation.rotation else null)
                        }
                    })
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text("Keep screen on", Modifier.weight(1f))
                    Switch(checked = keepOn, onCheckedChange = {
                        keepOn = it
                        prefs.edit().putBoolean("keep_screen_on", it).apply()
                    })
                }
            }
        }

        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Paired computers", style = MaterialTheme.typography.titleMedium)
                if (paired.isEmpty()) Text("None yet")
                paired.forEach { PairedRow(it) { store.revoke(it.hash) } }
            }
        }
    }

    request?.let { req ->
        AlertDialog(
            onDismissRequest = { StreamService.denyPairing(req.sessionId) },
            title = { Text("Pair with ${req.macName}?") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        PairingCode.formatted(req.code),
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Bold,
                        fontSize = 40.sp,
                    )
                    Text("Make sure this matches the code on your Mac.")
                }
            },
            confirmButton = { TextButton(onClick = { StreamService.allowPairing(req.sessionId) }) { Text("Allow") } },
            dismissButton = { TextButton(onClick = { StreamService.denyPairing(req.sessionId) }) { Text("Deny") } },
        )
    }
}

/** ROTATION_0 is the device's natural orientation. */
private fun rotationName(rotation: Int): String = when (rotation) {
    ViewSurface.ROTATION_90 -> "Landscape"
    ViewSurface.ROTATION_180 -> "Upside down"
    ViewSurface.ROTATION_270 -> "Landscape (reversed)"
    else -> "Portrait"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> Choice(options: List<Pair<T, String>>, selected: T?, enabled: Boolean, onSelect: (T) -> Unit) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { i, (value, label) ->
            SegmentedButton(
                selected = value == selected,
                onClick = { onSelect(value) },
                enabled = enabled,
                shape = SegmentedButtonDefaults.itemShape(i, options.size),
            ) { Text(label) }
        }
    }
}

@Composable
private fun PairedRow(mac: PairedMac, onRevoke: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(mac.name)
            Text(
                DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(mac.pairedAt)),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        TextButton(onClick = onRevoke) { Text("Revoke") }
    }
}
