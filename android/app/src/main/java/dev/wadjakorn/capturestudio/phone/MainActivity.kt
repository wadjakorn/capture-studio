package dev.wadjakorn.capturestudio.phone

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import dev.wadjakorn.capturestudio.phone.ui.CaptureStudioPhoneTheme
import dev.wadjakorn.capturestudio.phone.ui.MainScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { CaptureStudioPhoneTheme { MainScreen() } }
    }
}
