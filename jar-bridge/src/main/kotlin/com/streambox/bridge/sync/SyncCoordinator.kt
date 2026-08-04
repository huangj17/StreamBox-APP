package com.streambox.bridge.sync

import com.streambox.bridge.aggregator.AggregatorConfigParser
import com.streambox.bridge.aggregator.AggregatorFetchResult
import com.streambox.bridge.aggregator.AggregatorSource
import com.streambox.bridge.aggregator.FetchValidators
import com.streambox.bridge.artifact.ArtifactStore
import com.streambox.bridge.artifact.JarReferenceParser
import com.streambox.bridge.catalog.ActiveCatalog
import com.streambox.bridge.catalog.CatalogBuilder
import com.streambox.bridge.catalog.CatalogIdentity
import com.streambox.bridge.catalog.CatalogManager
import com.streambox.bridge.catalog.CatalogError
import com.streambox.bridge.catalog.CatalogErrorCode
import com.streambox.bridge.catalog.EntryStatus
import com.streambox.bridge.catalog.JarArtifactRef
import com.streambox.bridge.catalog.RuntimeEntry
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.catalog.SourceKind
import com.streambox.bridge.catalog.SourceOrigin
import com.streambox.bridge.storage.CatalogSnapshot
import com.streambox.bridge.storage.CatalogSnapshotStore
import com.streambox.bridge.storage.RecoveredCatalogSnapshot
import com.streambox.bridge.storage.SecretRecord
import com.streambox.bridge.storage.SecretStore
import com.streambox.bridge.storage.SnapshotAggregator
import com.streambox.bridge.storage.SnapshotEntry
import com.streambox.bridge.storage.atomicWrite
import com.streambox.bridge.runtime.SpiderFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.nio.charset.StandardCharsets
import java.nio.file.Path
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.slf4j.LoggerFactory

@Serializable
enum class SyncPhase {
    @SerialName("idle") IDLE,
    @SerialName("fetching") FETCHING,
    @SerialName("parsing") PARSING,
    @SerialName("building") BUILDING,
    @SerialName("preparing_cms") PREPARING_CMS,
    @SerialName("preparing_jars") PREPARING_JARS,
    @SerialName("probing") PROBING,
    @SerialName("committing") COMMITTING,
    @SerialName("succeeded") SUCCEEDED,
    @SerialName("failed") FAILED,
}

@Serializable
data class SyncDiff(
    val added: Int = 0,
    val updated: Int = 0,
    val removed: Int = 0,
    val unchanged: Int = 0,
    val failed: Int = 0,
    val shadowed: Int = 0,
)

@Serializable
data class SyncStatus(
    val jobId: String? = null,
    val phase: SyncPhase = SyncPhase.IDLE,
    val running: Boolean = false,
    val lastAttemptAt: String? = null,
    val lastSuccessAt: String? = null,
    val consecutiveFailures: Int = 0,
    val lastErrorCode: String? = null,
    val lastErrorMessage: String? = null,
    val durationMs: Long? = null,
    val configDigest: String? = null,
    val currentCatalogVersion: String? = null,
    val diff: SyncDiff = SyncDiff(),
    val nextAttemptAt: String? = null,
    val etag: String? = null,
    val lastModified: String? = null,
) {
    fun isStale(now: Instant, syncInterval: Duration): Boolean {
        val success = lastSuccessAt?.let(Instant::parse) ?: return true
        val threshold = maxOf(syncInterval.multipliedBy(2), Duration.ofMinutes(30))
        return Duration.between(success, now) > threshold
    }
}

sealed interface SyncRunResult {
    data class Completed(
        val status: SyncStatus,
        val activated: Boolean,
    ) : SyncRunResult

    data class AlreadyRunning(
        val jobId: String,
        val status: SyncStatus,
    ) : SyncRunResult

    data class Failed(
        val status: SyncStatus,
    ) : SyncRunResult
}

sealed interface SyncStartResult {
    data class Started(val jobId: String) : SyncStartResult

    data class AlreadyRunning(val jobId: String) : SyncStartResult
}

class SyncCoordinator(
    private val source: AggregatorSource,
    private val catalogManager: CatalogManager,
    private val snapshotStore: CatalogSnapshotStore,
    private val manualCatalog: ActiveCatalog,
    private val aggregatorBaseUrl: String,
    private val secretStore: SecretStore? = null,
    private val artifactStore: ArtifactStore? = null,
    private val spiderFactory: SpiderFactory? = null,
    private val statusPath: Path? = null,
    private val clock: () -> Instant = Instant::now,
) : AutoCloseable {
    private val logger = LoggerFactory.getLogger(SyncCoordinator::class.java)
    private val mutex = Mutex()
    private val backgroundScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val closed = AtomicBoolean(false)
    private val attemptStartedNanos = AtomicLong(0)
    private val statusReference = AtomicReference(SyncStatus())
    private var validators: FetchValidators? = null
    private var identityMap: Map<CatalogIdentity, String> =
        snapshotStore.recover()?.identityMap.orEmpty()

    fun status(): SyncStatus = statusReference.get()

    fun lastSnapshot(): RecoveredCatalogSnapshot? = snapshotStore.recover()

    suspend fun synchronize(allowEmpty: Boolean = false): SyncRunResult {
        check(!closed.get()) { "SyncCoordinator is closed" }
        if (!mutex.tryLock()) return alreadyRunningResult()
        beginSync()
        return runLocked(allowEmpty)
    }

    fun startAsync(allowEmpty: Boolean = false): SyncStartResult {
        check(!closed.get()) { "SyncCoordinator is closed" }
        if (!mutex.tryLock()) {
            return SyncStartResult.AlreadyRunning(status().jobId ?: "unknown")
        }
        val jobId = beginSync()
        backgroundScope.launch {
            runLocked(allowEmpty)
        }
        return SyncStartResult.Started(jobId)
    }

    private fun beginSync(): String {
        val jobId = UUID.randomUUID().toString()
        val attemptAt = clock()
        attemptStartedNanos.set(System.nanoTime())
        updateStatus {
            copy(
                jobId = jobId,
                phase = SyncPhase.FETCHING,
                running = true,
                lastAttemptAt = attemptAt.toString(),
                lastErrorCode = null,
                lastErrorMessage = null,
                durationMs = null,
                currentCatalogVersion = catalogManager.current().version,
            )
        }
        return jobId
    }

    private fun alreadyRunningResult(): SyncRunResult.AlreadyRunning {
        val running = status()
        return SyncRunResult.AlreadyRunning(
            jobId = running.jobId ?: "unknown",
            status = running,
        )
    }

    private suspend fun runLocked(allowEmpty: Boolean): SyncRunResult {
        return try {
            when (val fetched = source.fetch(validators)) {
                is AggregatorFetchResult.NotModified -> completeNotModified(fetched)
                is AggregatorFetchResult.Fetched -> synchronizeFetched(fetched, allowEmpty)
            }
        } catch (error: Exception) {
            val failed = updateStatus {
                copy(
                    phase = SyncPhase.FAILED,
                    running = false,
                    consecutiveFailures = consecutiveFailures + 1,
                    lastErrorCode = stableErrorCode(error),
                    lastErrorMessage = error.message?.take(256),
                    durationMs = elapsedMs(),
                    currentCatalogVersion = catalogManager.current().version,
                )
            }
            SyncRunResult.Failed(failed)
        } finally {
            mutex.unlock()
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            backgroundScope.cancel()
        }
    }

    private fun completeNotModified(
        fetched: AggregatorFetchResult.NotModified,
    ): SyncRunResult.Completed {
        validators = fetched.validators
        val completed = updateStatus {
            copy(
                phase = SyncPhase.SUCCEEDED,
                running = false,
                lastSuccessAt = clock().toString(),
                consecutiveFailures = 0,
                durationMs = elapsedMs(),
                currentCatalogVersion = catalogManager.current().version,
                diff = unchangedDiff(catalogManager.current()),
                etag = fetched.validators.etag,
                lastModified = fetched.validators.lastModified,
            )
        }
        return SyncRunResult.Completed(completed, activated = false)
    }

    private suspend fun synchronizeFetched(
        fetched: AggregatorFetchResult.Fetched,
        allowEmpty: Boolean,
    ): SyncRunResult.Completed {
        updatePhase(SyncPhase.PARSING)
        val normalized = AggregatorConfigParser.parse(fetched.body, fetched.finalUrl)
        val activeDigest = status().configDigest
            ?: snapshotStore.recover()?.snapshot?.aggregator?.configDigest
        val requiresRetry = catalogManager.current().entries.values.any { entry ->
            entry.spec.origin == SourceOrigin.AGGREGATOR && (
                entry.status !in setOf(EntryStatus.READY, EntryStatus.SHADOWED, EntryStatus.DISABLED) ||
                    jarRequiresRevalidation(entry)
                )
        }
        if (activeDigest == normalized.configDigest && !requiresRetry) {
            validators = fetched.validators
            val completed = updateStatus {
                copy(
                    phase = SyncPhase.SUCCEEDED,
                    running = false,
                    lastSuccessAt = clock().toString(),
                    consecutiveFailures = 0,
                    durationMs = elapsedMs(),
                    configDigest = normalized.configDigest,
                    currentCatalogVersion = catalogManager.current().version,
                    diff = unchangedDiff(catalogManager.current()),
                    etag = fetched.validators.etag,
                    lastModified = fetched.validators.lastModified,
                )
            }
            return SyncRunResult.Completed(completed, activated = false)
        }
        updatePhase(SyncPhase.BUILDING)
        val now = clock()
        val version = catalogVersion(now, normalized.configDigest)
        val build = CatalogBuilder.build(
            aggregator = normalized,
            manualCatalog = manualCatalog,
            version = version,
            activatedAt = now,
            existingIdentityMap = identityMap,
        )
        updatePhase(SyncPhase.PREPARING_CMS)
        val candidateWithSecrets = attachSecrets(build.candidate, normalized.sites)
        val previousCatalog = catalogManager.current()
        val prepared = prepare(candidateWithSecrets, previousCatalog)
        validateCandidate(prepared, allowEmpty)
        if (
            activeDigest == normalized.configDigest &&
            catalogsEquivalent(prepared, catalogManager.current())
        ) {
            validators = fetched.validators
            val completed = updateStatus {
                copy(
                    phase = SyncPhase.SUCCEEDED,
                    running = false,
                    lastSuccessAt = clock().toString(),
                    consecutiveFailures = 0,
                    durationMs = elapsedMs(),
                    configDigest = normalized.configDigest,
                    currentCatalogVersion = catalogManager.current().version,
                    diff = unchangedDiff(catalogManager.current()),
                    etag = fetched.validators.etag,
                    lastModified = fetched.validators.lastModified,
                )
            }
            return SyncRunResult.Completed(completed, activated = false)
        }
        val snapshot = prepared.toSnapshot(
            createdAt = now,
            aggregator = SnapshotAggregator(
                baseUrl = aggregatorBaseUrl,
                configDigest = normalized.configDigest,
                etag = fetched.validators.etag,
                lastModified = fetched.validators.lastModified,
            ),
        )
        updatePhase(SyncPhase.COMMITTING)
        snapshotStore.commit(snapshot, build.identityMap)
        val catalogDiff = calculateDiff(previousCatalog, prepared)
        catalogManager.activate(prepared)
        cleanupUnreferencedPersistentData()
        identityMap = build.identityMap
        validators = fetched.validators
        val completed = updateStatus {
            copy(
                phase = SyncPhase.SUCCEEDED,
                running = false,
                lastSuccessAt = clock().toString(),
                consecutiveFailures = 0,
                durationMs = elapsedMs(),
                configDigest = normalized.configDigest,
                currentCatalogVersion = prepared.version,
                diff = catalogDiff,
                etag = fetched.validators.etag,
                lastModified = fetched.validators.lastModified,
            )
        }
        return SyncRunResult.Completed(completed, activated = true)
    }

    private fun cleanupUnreferencedPersistentData() {
        val retainedEntries = snapshotStore.retainedSnapshots().flatMap(CatalogSnapshot::entries)
        secretStore?.let { store ->
            val secretReferences = retainedEntries.mapNotNull(SnapshotEntry::secretRef).toSet()
            runCatching { store.deleteUnreferenced(secretReferences) }
        }
        artifactStore?.let { store ->
            val artifactReferences = retainedEntries.mapNotNull(SnapshotEntry::jarSha256).toSet()
            runCatching { store.cleanupUnreferenced(artifactReferences) }
        }
    }

    private suspend fun prepare(candidate: ActiveCatalog, current: ActiveCatalog): ActiveCatalog {
        val entries = linkedMapOf<String, RuntimeEntry>()
        candidate.entries.forEach { (key, planned) ->
            val previous = current.entries[key]
            val requiresJarRefresh = jarRequiresRevalidation(planned)
            if (
                previous?.spec?.specFingerprint == planned.spec.specFingerprint &&
                previous.handler != null &&
                previous.status == EntryStatus.READY &&
                !requiresJarRefresh
            ) {
                entries[key] = planned.copy(
                    status = previous.status,
                    handler = previous.handler,
                    lastReadyAt = previous.lastReadyAt,
                )
                return@forEach
            }
            entries[key] = when (planned.spec.kind) {
                SourceKind.CMS -> {
                    val target = planned.spec.api.toHttpUrlOrNull()
                    if (target == null) {
                        previous?.takeIf { it.handler != null }?.copy(status = EntryStatus.DEGRADED)
                            ?: planned.copy(status = EntryStatus.FAILED)
                    } else {
                        planned.copy(
                            status = EntryStatus.READY,
                            handler = SourceHandler.Cms(target),
                            lastReadyAt = clock(),
                        )
                    }
                }
                SourceKind.JAR -> prepareJar(planned, previous, candidate.version)
                SourceKind.MANUAL -> planned
            }
        }
        return candidate.copy(entries = entries)
    }

    private suspend fun prepareJar(
        planned: RuntimeEntry,
        previous: RuntimeEntry?,
        generation: String,
    ): RuntimeEntry {
        val artifacts = artifactStore ?: return planned
        val factory = spiderFactory ?: return planned
        return try {
            updatePhase(SyncPhase.PREPARING_JARS)
            val jarSource = checkNotNull(planned.spec.jar?.source)
            val reference = JarReferenceParser.parse(jarSource)
            val artifact = artifacts.prepare(reference, checkNotNull(planned.spec.className))
            if (
                previous?.handler != null &&
                previous.spec.specFingerprint == planned.spec.specFingerprint &&
                previous.spec.jar?.sha256 == artifact.sha256
            ) {
                return planned.copy(
                    spec = planned.spec.copy(
                        className = artifact.className,
                        jar = checkNotNull(planned.spec.jar).copy(
                            declaredMd5 = reference.declaredMd5,
                            sha256 = artifact.sha256,
                        ),
                    ),
                    status = EntryStatus.READY,
                    handler = previous.handler,
                    lastReadyAt = clock(),
                )
            }
            val ext = planned.spec.secretRef?.let { secretRef ->
                checkNotNull(secretStore) { "SecretStore is required for encrypted JAR ext" }
                    .read(secretRef)
            }.orEmpty()
            updatePhase(SyncPhase.PROBING)
            val runtime = factory.create(
                key = planned.spec.key,
                name = planned.spec.name,
                artifact = artifact,
                className = artifact.className,
                ext = ext,
                generation = generation,
            )
            planned.copy(
                spec = planned.spec.copy(
                    className = artifact.className,
                    jar = planned.spec.jar.copy(
                        declaredMd5 = reference.declaredMd5,
                        sha256 = artifact.sha256,
                    ),
                ),
                status = EntryStatus.READY,
                handler = SourceHandler.Spider(runtime),
                lastReadyAt = clock(),
            )
        } catch (error: Exception) {
            val catalogError = CatalogError(
                code = CatalogErrorCode.SOURCE_UNAVAILABLE,
                message = error.message?.take(160) ?: "automatic JAR preparation failed",
            )
            previous?.takeIf { it.handler != null }?.copy(
                status = EntryStatus.DEGRADED,
                lastError = catalogError,
            ) ?: planned.copy(
                status = EntryStatus.FAILED,
                handler = null,
                lastError = catalogError,
            )
        }
    }

    private fun attachSecrets(
        candidate: ActiveCatalog,
        sites: List<com.streambox.bridge.aggregator.NormalizedAggregatorSite>,
    ): ActiveCatalog {
        val store = secretStore ?: return candidate
        val current = catalogManager.current()
        val entries = candidate.entries.mapValues { (_, entry) ->
            if (entry.spec.origin != SourceOrigin.AGGREGATOR) return@mapValues entry
            val site = sites.firstOrNull { site ->
                site.key == entry.spec.upstreamKey && site.api == entry.spec.api
            } ?: return@mapValues entry
            val ext = site.ext ?: return@mapValues entry
            val previous = current.entries[entry.spec.key]?.spec
            val existing = if (
                previous?.secretRef != null && previous.extDigest == entry.spec.extDigest
            ) {
                SecretRecord(previous.secretRef, checkNotNull(previous.extDigest))
            } else {
                null
            }
            val stored = store.write(ext, existing)
            entry.copy(
                spec = entry.spec.copy(
                    secretRef = stored.ref,
                    extDigest = stored.extDigest,
                ),
            )
        }
        return candidate.copy(entries = entries)
    }

    private fun jarRequiresRevalidation(entry: RuntimeEntry): Boolean {
        if (entry.spec.kind != SourceKind.JAR) return false
        val store = artifactStore ?: return false
        val source = entry.spec.jar?.source ?: return false
        return runCatching {
            store.requiresRevalidation(JarReferenceParser.parse(source))
        }.getOrDefault(false)
    }

    private fun validateCandidate(candidate: ActiveCatalog, allowEmpty: Boolean) {
        val publicEntries = candidate.entries.values.count { entry ->
            entry.handler != null && entry.status in setOf(EntryStatus.READY, EntryStatus.DEGRADED)
        }
        val previousPublic = catalogManager.listPublic().size
        if (previousPublic > 0 && publicEntries == 0 && !allowEmpty) {
            error("candidate catalog unexpectedly contains no public entries")
        }
        check(candidate.entries.keys.size == candidate.entries.keys.toSet().size)
        check(candidate.version.isNotBlank())
    }

    private fun catalogsEquivalent(first: ActiveCatalog, second: ActiveCatalog): Boolean {
        if (first.entries.keys != second.entries.keys) return false
        return first.entries.all { (key, entry) ->
            val other = second.entries[key] ?: return@all false
            entry.spec == other.spec &&
                entry.status == other.status &&
                entry.handler === other.handler
        }
    }

    private fun ActiveCatalog.toSnapshot(
        createdAt: Instant,
        aggregator: SnapshotAggregator,
    ): CatalogSnapshot = CatalogSnapshot(
        catalogVersion = version,
        createdAt = createdAt.toString(),
        activatedAt = activatedAt.toString(),
        aggregator = aggregator,
        entries = entries.values.map { entry -> entry.toSnapshotEntry() },
    )

    private fun RuntimeEntry.toSnapshotEntry(): SnapshotEntry = SnapshotEntry(
        key = spec.key,
        upstreamKey = spec.upstreamKey,
        name = spec.name,
        kind = spec.kind,
        origin = spec.origin,
        api = spec.api,
        status = status,
        className = spec.className,
        jarSource = spec.jar?.source,
        jarMd5 = spec.jar?.declaredMd5,
        jarSha256 = spec.jar?.sha256,
        secretRef = spec.secretRef,
        extDigest = spec.extDigest,
        searchable = spec.searchable,
        hidden = spec.hidden,
        specFingerprint = spec.specFingerprint,
    )

    private fun calculateDiff(current: ActiveCatalog, candidate: ActiveCatalog): SyncDiff {
        val currentKeys = current.entries.keys
        val candidateKeys = candidate.entries.keys
        val sharedKeys = currentKeys.intersect(candidateKeys)
        val unchanged = sharedKeys.count { key ->
            val before = current.entries.getValue(key)
            val after = candidate.entries.getValue(key)
            before.spec.specFingerprint == after.spec.specFingerprint &&
                before.status == after.status
        }
        return SyncDiff(
            added = (candidateKeys - currentKeys).size,
            updated = sharedKeys.size - unchanged,
            removed = (currentKeys - candidateKeys).size,
            unchanged = unchanged,
            failed = candidate.entries.values.count { it.status == EntryStatus.FAILED },
            shadowed = candidate.entries.values.count { it.status == EntryStatus.SHADOWED },
        )
    }

    private fun unchangedDiff(catalog: ActiveCatalog): SyncDiff = SyncDiff(
        unchanged = catalog.entries.size,
        failed = catalog.entries.values.count { it.status == EntryStatus.FAILED },
        shadowed = catalog.entries.values.count { it.status == EntryStatus.SHADOWED },
    )

    private fun elapsedMs(): Long =
        ((System.nanoTime() - attemptStartedNanos.get()).coerceAtLeast(0L)) / 1_000_000

    private fun updatePhase(phase: SyncPhase) {
        updateStatus { copy(phase = phase) }
    }

    private fun updateStatus(transform: SyncStatus.() -> SyncStatus): SyncStatus {
        val next = statusReference.updateAndGet(transform)
        logger.info(
            "sync jobId={} phase={} catalogVersion={} failures={}",
            next.jobId,
            next.phase,
            catalogManager.current().version,
            next.consecutiveFailures,
        )
        statusPath?.let { path ->
            atomicWrite(
                path,
                Json.encodeToString(next).toByteArray(StandardCharsets.UTF_8),
            )
        }
        return next
    }

    private fun stableErrorCode(error: Exception): String = when (error) {
        is com.streambox.bridge.aggregator.AggregatorFetchException -> error.code
        is com.streambox.bridge.aggregator.AggregatorSchemaException -> error.code
        else -> "SYNC_FAILED"
    }

    private fun catalogVersion(now: Instant, digest: String): String =
        VERSION_TIME_FORMAT.format(now) + "-" + digest.take(8)

    private companion object {
        val VERSION_TIME_FORMAT: DateTimeFormatter = DateTimeFormatter
            .ofPattern("yyyyMMdd'T'HHmmss'Z'")
            .withZone(ZoneOffset.UTC)
    }
}
