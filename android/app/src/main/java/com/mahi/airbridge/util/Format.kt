package com.mahi.airbridge.util

import java.util.Locale

object Format {
    /** Decimal units (MB = 10^6 bytes), matching Finder and the MB/s shown in benchmarks. */
    fun bytes(b: Long): String = when {
        b < 1_000 -> "$b B"
        b < 1_000_000 -> String.format(Locale.US, "%.1f KB", b / 1e3)
        b < 1_000_000_000 -> String.format(Locale.US, "%.1f MB", b / 1e6)
        else -> String.format(Locale.US, "%.2f GB", b / 1e9)
    }

    fun speed(bytesPerSecond: Double?): String =
        if (bytesPerSecond == null) "—" else String.format(Locale.US, "%.1f MB/s", bytesPerSecond / 1e6)

    fun eta(seconds: Long?): String = when {
        seconds == null -> "—"
        seconds < 60 -> "${seconds}s left"
        seconds < 3600 -> "${seconds / 60}m ${seconds % 60}s left"
        else -> "${seconds / 3600}h ${(seconds % 3600) / 60}m left"
    }

    /** Short local date, e.g. "14 Oct". */
    fun date(epochMillis: Long): String =
        java.text.SimpleDateFormat("d MMM", Locale.getDefault()).format(java.util.Date(epochMillis))
}
