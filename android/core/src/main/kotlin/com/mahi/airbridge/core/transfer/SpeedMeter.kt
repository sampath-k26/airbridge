package com.mahi.airbridge.core.transfer

/**
 * Throughput from measured bytes over elapsed time — no estimates are invented.
 * `current` uses a sliding window; `average` covers the whole transfer.
 */
class SpeedMeter(private val windowMs: Long = 2_000) {
    private val samples = ArrayDeque<Pair<Long, Long>>() // (timeMs, bytes)
    private var startMs = -1L
    private var startBytes = 0L
    private var lastBytes = 0L

    @Synchronized
    fun add(bytesDone: Long, nowMs: Long) {
        if (startMs < 0) { startMs = nowMs; startBytes = bytesDone }
        lastBytes = bytesDone
        samples.addLast(nowMs to bytesDone)
        while (samples.size > 2 && nowMs - samples.first().first > windowMs) samples.removeFirst()
    }

    /** Bytes per second over the last [windowMs], or null until two samples exist. */
    @Synchronized
    fun current(): Double? {
        if (samples.size < 2) return null
        val (t0, b0) = samples.first()
        val (t1, b1) = samples.last()
        return if (t1 > t0) (b1 - b0) * 1000.0 / (t1 - t0) else null
    }

    @Synchronized
    fun average(nowMs: Long): Double? =
        if (startMs >= 0 && nowMs > startMs) (lastBytes - startBytes) * 1000.0 / (nowMs - startMs) else null

    /** Seconds remaining at the current rate, or null when unknown. */
    @Synchronized
    fun etaSeconds(totalBytes: Long): Long? {
        val rate = current() ?: return null
        if (rate <= 0) return null
        return ((totalBytes - lastBytes).coerceAtLeast(0) / rate).toLong()
    }
}
