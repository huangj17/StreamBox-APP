package com.streambox.bridge.catalog

import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean

fun interface RetirementTask {
    fun cancel()
}

fun interface RetirementScheduler {
    fun schedule(delayMs: Long, block: () -> Unit): RetirementTask
}

private class ExecutorRetirementScheduler : RetirementScheduler, AutoCloseable {
    private val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "catalog-retirement").apply { isDaemon = true }
    }

    override fun schedule(delayMs: Long, block: () -> Unit): RetirementTask {
        val future = executor.schedule(block, delayMs, TimeUnit.MILLISECONDS)
        return RetirementTask { future.cancel(false) }
    }

    override fun close() {
        executor.shutdownNow()
    }
}

class CatalogManager(
    initial: ActiveCatalog = ActiveCatalog.empty(),
    private val retirementGraceMs: Long = 30_000,
    private val scheduler: RetirementScheduler = ExecutorRetirementScheduler(),
) : AutoCloseable {
    private data class RuntimeState(
        val runtime: SpiderRuntime,
        var catalogReferences: Int = 0,
        var requestReferences: Int = 0,
        var closed: Boolean = false,
        var retirementTask: RetirementTask? = null,
    )

    private val lock = Any()
    private val closed = AtomicBoolean(false)
    private val active = AtomicReference(initial)
    private val runtimeStates = IdentityHashMap<SpiderRuntime, RuntimeState>()

    init {
        synchronized(lock) {
            registerCatalog(initial)
        }
    }

    fun current(): ActiveCatalog = active.get()

    fun activate(next: ActiveCatalog): ActiveCatalog {
        check(!closed.get()) { "catalog manager is closed" }
        val runtimesToClose = synchronized(lock) {
            registerCatalog(next)
            val previous = active.getAndSet(next)
            unregisterCatalog(previous)
            scheduleRetiringRuntimes()
            collectRetiredRuntimes()
        }
        runtimesToClose.forEach(SpiderRuntime::close)
        return next
    }

    fun acquire(key: String): CatalogLease? = synchronized(lock) {
        if (closed.get()) return@synchronized null
        val entry = active.get().entries[key] ?: return@synchronized null
        if (
            entry.handler == null ||
            entry.status !in setOf(EntryStatus.READY, EntryStatus.DEGRADED)
        ) {
            return@synchronized null
        }
        val runtimeState = (entry.handler as? SourceHandler.Spider)
            ?.runtime
            ?.let(runtimeStates::get)
        runtimeState?.let { it.requestReferences += 1 }
        CatalogLease(entry) {
            release(runtimeState)
        }
    }

    fun listPublic(): List<RuntimeEntry> = current().entries.values.filter { entry ->
        entry.handler != null &&
            !entry.spec.hidden &&
            entry.status in setOf(EntryStatus.READY, EntryStatus.DEGRADED)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val runtimesToClose = synchronized(lock) {
            val previous = active.getAndSet(ActiveCatalog.empty())
            unregisterCatalog(previous)
            runtimeStates.values.map { state ->
                state.retirementTask?.cancel()
                state.retirementTask = null
                state.closed = true
                state.runtime
            }.also {
                runtimeStates.clear()
            }
        }
        runtimesToClose.forEach(SpiderRuntime::close)
        (scheduler as? AutoCloseable)?.close()
    }

    private fun release(runtimeState: RuntimeState?) {
        val runtimesToClose = synchronized(lock) {
            if (runtimeState != null && runtimeState.requestReferences > 0) {
                runtimeState.requestReferences -= 1
            }
            collectRetiredRuntimes()
        }
        runtimesToClose.forEach(SpiderRuntime::close)
    }

    private fun registerCatalog(catalog: ActiveCatalog) {
        catalog.uniqueSpiderRuntimes().forEach { runtime ->
            val state = runtimeStates.getOrPut(runtime) { RuntimeState(runtime) }
            check(!state.closed) { "cannot reactivate a closed Spider runtime" }
            state.retirementTask?.cancel()
            state.retirementTask = null
            state.catalogReferences += 1
        }
    }

    private fun unregisterCatalog(catalog: ActiveCatalog) {
        catalog.uniqueSpiderRuntimes().forEach { runtime ->
            runtimeStates[runtime]?.let { state ->
                state.catalogReferences = (state.catalogReferences - 1).coerceAtLeast(0)
            }
        }
    }

    private fun collectRetiredRuntimes(): List<SpiderRuntime> {
        val closable = runtimeStates.values.filter { state ->
            !state.closed && state.catalogReferences == 0 && state.requestReferences == 0
        }
        closable.forEach { state ->
            state.retirementTask?.cancel()
            state.retirementTask = null
            state.closed = true
            runtimeStates.remove(state.runtime)
        }
        return closable.map(RuntimeState::runtime)
    }

    private fun scheduleRetiringRuntimes() {
        runtimeStates.values
            .filter { state ->
                !state.closed &&
                    state.catalogReferences == 0 &&
                    state.requestReferences > 0 &&
                    state.retirementTask == null
            }
            .forEach { state ->
                state.retirementTask = scheduler.schedule(retirementGraceMs) {
                    forceRetire(state)
                }
            }
    }

    private fun forceRetire(state: RuntimeState) {
        val runtime = synchronized(lock) {
            if (state.closed || state.catalogReferences > 0) {
                return@synchronized null
            }
            state.closed = true
            state.retirementTask = null
            runtimeStates.remove(state.runtime)
            state.runtime
        }
        runtime?.close()
    }
}

class CatalogLease internal constructor(
    val entry: RuntimeEntry,
    private val release: () -> Unit,
) : AutoCloseable {
    private val closed = AtomicBoolean(false)

    val handler: SourceHandler
        get() = checkNotNull(entry.handler)

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            release()
        }
    }
}

private fun ActiveCatalog.uniqueSpiderRuntimes(): Set<SpiderRuntime> {
    val runtimes = Collections.newSetFromMap(IdentityHashMap<SpiderRuntime, Boolean>())
    entries.values.forEach { entry ->
        (entry.handler as? SourceHandler.Spider)?.runtime?.let(runtimes::add)
    }
    return runtimes
}
