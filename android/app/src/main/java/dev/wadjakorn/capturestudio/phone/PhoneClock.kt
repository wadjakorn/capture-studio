package dev.wadjakorn.capturestudio.phone

import android.hardware.camera2.CameraCharacteristics
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraInfo

/**
 * Every phone timestamp on the wire is BOOTTIME (`SystemClock.elapsedRealtimeNanos`).
 * Camera buffers are BOOTTIME when `SENSOR_INFO_TIMESTAMP_SOURCE` is `REALTIME`;
 * otherwise (`UNKNOWN`, common on Samsung) they are MONOTONIC (`System.nanoTime`),
 * which falls behind BOOTTIME by every suspend, so they are shifted by an offset
 * sampled at START.
 */
object PhoneClock {
    private const val TAG = "CSPhone"
    private const val SAMPLES = 5

    @Volatile var offsetNs: Long = 0L
        private set

    @OptIn(ExperimentalCamera2Interop::class)
    fun configure(cameraInfo: CameraInfo) {
        val source = try {
            Camera2CameraInfo.from(cameraInfo)
                .getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Camera2CameraInfo unavailable; assuming UNKNOWN timestamp source", e)
            null
        }
        if (source == CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME) {
            offsetNs = 0L
            Log.i(TAG, "Camera timestamps are BOOTTIME (REALTIME)")
        } else {
            offsetNs = sampleMonotonicOffset()
            Log.i(TAG, "Camera timestamps are MONOTONIC (source=$source); BOOTTIME offset ${offsetNs}ns")
        }
    }

    /** Camera/codec timestamp (ns) → BOOTTIME ns. */
    fun toBoottime(monotonicNs: Long): Long = monotonicNs + offsetNs

    /** min over adjacent (elapsedRealtimeNanos − nanoTime) readings; the min has the least preemption error. */
    fun sampleMonotonicOffset(): Long {
        var best = Long.MAX_VALUE
        repeat(SAMPLES) {
            // nanoTime first: any delay between the reads inflates d, so min picks the tightest pair.
            val n = System.nanoTime()
            val d = SystemClock.elapsedRealtimeNanos() - n
            if (d < best) best = d
        }
        return best
    }
}
