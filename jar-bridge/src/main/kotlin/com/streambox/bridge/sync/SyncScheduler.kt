package com.streambox.bridge.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Duration
import java.util.concurrent.atomic.AtomicBoolean

class SyncScheduler(
    private val interval: Duration,
    private val trigger: suspend () -> Unit,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) : AutoCloseable {
    private val started = AtomicBoolean(false)
    private var job: Job? = null

    fun start() {
        if (!started.compareAndSet(false, true)) return
        job = scope.launch {
            while (isActive) {
                runCatching { trigger() }
                delay(interval.toMillis())
            }
        }
    }

    override fun close() {
        if (!started.compareAndSet(true, false)) return
        job?.cancel()
        job = null
        scope.cancel()
    }
}
