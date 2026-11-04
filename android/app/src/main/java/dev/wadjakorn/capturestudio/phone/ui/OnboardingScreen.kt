package dev.wadjakorn.capturestudio.phone.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

fun requiredPermissions(): Array<String> =
    if (Build.VERSION.SDK_INT >= 33) {
        arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
    } else {
        arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
    }

fun isBatteryUnrestricted(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

/**
 * @param permsGranted camera + mic granted (notifications optional)
 * @param onRecheck re-reads permission state after a system dialog returns
 */
@Composable
fun OnboardingScreen(permsGranted: Boolean, batteryOk: Boolean, onRecheck: () -> Unit, onContinue: () -> Unit) {
    val context = LocalContext.current
    var skippedBattery by rememberSaveable { mutableStateOf(false) }

    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { onRecheck() }
    val batteryLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { onRecheck() }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Capture Studio Phone", style = MaterialTheme.typography.headlineMedium)
        Text("Capture Studio Phone streams your camera and microphone to Capture Studio on your Mac over Wi-Fi.")

        Text("1. Permissions", style = MaterialTheme.typography.titleMedium)
        Text("Camera and microphone are required. Notifications keep the streaming notice visible.")
        Button(onClick = { permLauncher.launch(requiredPermissions()) }, enabled = !permsGranted) {
            Text(if (permsGranted) "Permissions granted" else "Grant permissions")
        }

        if (!batteryOk && !skippedBattery) {
            Text("2. Battery", style = MaterialTheme.typography.titleMedium)
            Text(
                "Samsung and other phones put unused apps to sleep, which stops streaming. " +
                    "Allow Capture Studio Phone to run unrestricted.",
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    batteryLauncher.launch(
                        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")),
                    )
                }) { Text("Allow") }
                TextButton(onClick = { skippedBattery = true }) { Text("Skip") }
            }
        }

        Button(onClick = onContinue, enabled = permsGranted && (batteryOk || skippedBattery)) { Text("Continue") }
    }
}
