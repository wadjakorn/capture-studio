package dev.wadjakorn.capturestudio.phone

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class TexCropTest {
    @Test
    fun fullCropKeepsIdentityTexCoords() {
        assertArrayEquals(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f), TexCrop.FULL.texCoords(), 0f)
    }

    @Test
    fun landscapeSquareCropTrimsX() {
        // 960x720: x in [120/960, 840/960], y full.
        assertEquals(TexCrop(0.125f, 0f, 0.875f, 1f), TexCrop.centerSquare(960, 720))
        val c = TexCrop.centerSquare(1440, 1080)
        assertEquals(0.125f, c.left, 1e-6f)
        assertEquals(0.875f, c.right, 1e-6f)
    }

    @Test
    fun portraitSquareCropTrimsY() {
        assertEquals(TexCrop(0f, 0.125f, 1f, 0.875f), TexCrop.centerSquare(720, 960))
    }

    @Test
    fun squareFrameIsUncropped() {
        assertEquals(TexCrop.FULL, TexCrop.centerSquare(720, 720))
    }
}
