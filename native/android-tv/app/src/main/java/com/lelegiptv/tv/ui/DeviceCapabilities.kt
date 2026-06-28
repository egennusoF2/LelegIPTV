package com.lelegiptv.tv.ui

import android.os.Build

object DeviceCapabilities {
    fun isEmulator(): Boolean {
        val hw = Build.HARDWARE.orEmpty().lowercase()
        val product = Build.PRODUCT.orEmpty().lowercase()
        val model = Build.MODEL.orEmpty().lowercase()
        return hw.contains("ranchu") ||
            hw.contains("goldfish") ||
            product.contains("sdk") ||
            model.contains("emulator") ||
            model.contains("android sdk built for")
    }

    /** Anteprima sempre visibile; su emulatore usa pipeline leggera. */
    fun useLightweightPreview(): Boolean = isEmulator()
}
