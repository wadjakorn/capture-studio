package dev.wadjakorn.capturestudio.phone

import android.content.Context
import android.util.Log
import android.view.OrientationEventListener
import android.view.Surface
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Physical device orientation from the accelerometer, as a [Surface] rotation.
 * Lives for the whole service so a stream that starts while the phone is already
 * turned gets the right rotation from its first frame. A service has no window,
 * so CameraX's default (the display rotation, often locked to portrait) would
 * ignore how the phone is actually held.
 */
object DeviceOrientation {
    @Volatile var rotation: Int = Surface.ROTATION_0
        private set
    private val listeners = CopyOnWriteArraySet<(Int) -> Unit>()
    private var sensor: OrientationEventListener? = null

    fun start(context: Context) {
        if (sensor != null) return
        sensor = object : OrientationEventListener(context.applicationContext) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN) return
                val r = when (orientation) {
                    in 45..134 -> Surface.ROTATION_270
                    in 135..224 -> Surface.ROTATION_180
                    in 225..314 -> Surface.ROTATION_90
                    else -> Surface.ROTATION_0
                }
                if (r != rotation) {
                    rotation = r
                    Log.i("CSPhone", "Device rotation -> $r (orientation $orientation)")
                    listeners.forEach { it(r) }
                }
            }
        }.also { it.enable() }
    }

    fun stop() {
        sensor?.disable()
        sensor = null
        listeners.clear()
    }

    fun addListener(l: (Int) -> Unit) { listeners += l }
    fun removeListener(l: (Int) -> Unit) { listeners -= l }
}
