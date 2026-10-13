//
//  CoreDataMigrationService.swift
//  Meshtastic
//
//  One-time migration from the legacy Core Data store (shipped in 2.7.12 and
//  earlier) into the SwiftData store.
//
//  Migration is triggered automatically by PersistenceController when it detects
//  an existing Core Data store at the expected URL.  After a successful run the
//  old store is renamed to `Meshtastic-coredata-backup.sqlite` so the migration
//  never runs again.
//
//  Entities migrated (every entity that existed in the Core Data model):
//    NodeInfoEntity, UserEntity, MyInfoEntity, ChannelEntity, MessageEntity,
//    PositionEntity, TelemetryEntity, BluetoothConfigEntity,
//    CannedMessageConfigEntity, DeviceConfigEntity, DisplayConfigEntity,
//    ExternalNotificationConfigEntity, LoRaConfigEntity, MQTTConfigEntity,
//    NetworkConfigEntity, PositionConfigEntity, RangeTestConfigEntity,
//    SerialConfigEntity, TelemetryConfigEntity
//

import CoreData
import SwiftData
import OSLog

// MARK: - Public API

enum CoreDataMigrationService {

	/// Folders a pre-SwiftData build may have left `Meshtastic.sqlite` in, most likely first.
	///
	/// `NSPersistentContainer(name:)` stored to `NSPersistentContainer.defaultDirectoryURL()`.
	/// On iOS that is Application Support itself, but on macOS / Mac Catalyst it appends the
	/// product-name folder (`Application Support/Pangea/`), which a flat Application Support
	/// lookup never sees. Both are searched, plus the explicit `Pangea` folder in case the
	/// default folder name ever differs from the one the old build used.
	static var defaultSearchDirectories: [URL] {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		let candidates = [
			NSPersistentContainer.defaultDirectoryURL(),
			appSupport,
			appSupport.appendingPathComponent("Pangea", isDirectory: true)
		]
		var seen = Set<String>()
		return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
	}

	/// Renames the pre-SwiftData Core Data store out of the way so that SwiftData
	/// can create a fresh store without clobbering user data.
	///
	/// Must be called **before** the SwiftData `ModelContainer` is initialised.
	/// Safe to call on every launch — per folder it is a no-op when:
	///   - The candidate file does not exist, or
	///   - The candidate file is not a Core Data store, or
	///   - The renamed legacy file already exists (rename already done).
	/// Nothing is ever deleted: the store is only renamed.
	static func prepareForMigration(in directories: [URL] = defaultSearchDirectories) {
		let fm = FileManager.default
		for directory in directories {
			let candidate = candidateStoreURL(in: directory)
			let legacy = legacyStoreFile(in: directory)
			// Nothing to do if the candidate is already gone or the rename is done.
			guard fm.fileExists(atPath: candidate.path),
				  !fm.fileExists(atPath: legacy.path) else { continue }
			// Only rename if the file is actually a Core Data store.
			guard isCoreDataStore(at: candidate) else {
				Logger.data.info("⬆️ CoreDataMigrationService: \(candidate.path, privacy: .public) is not a Core Data store; left alone")
				continue
			}

			Logger.data.info("⬆️ CoreDataMigrationService: found Core Data store at \(candidate.path, privacy: .public); renaming before SwiftData init")
			// A sidecar already under the new name would pair someone else's journal with this
			// store. An empty one carries nothing and is cleared; anything else leaves the
			// store where it is.
			let suffixes = ["-shm", "-wal"]
			let blocking = suffixes
				.map { URL(fileURLWithPath: legacy.path + $0) }
				.filter { fm.fileExists(atPath: $0.path) }
			if blocking.contains(where: { ((try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 1) > 0 }) {
				Logger.data.error("⬆️ CoreDataMigrationService: \(legacy.lastPathComponent, privacy: .public) sidecar files already exist in \(directory.path, privacy: .public); store left in place")
				continue
			}
			blocking.forEach { try? fm.removeItem(at: $0) }

			// Main file last, and nothing more once a move fails (the moved ones go back): the
			// store and its journal are never split across two names, which would lose the
			// unflushed writes in the journal.
			var moved: [(from: URL, to: URL)] = []
			for suffix in suffixes + [""] {
				let src = URL(fileURLWithPath: candidate.path + suffix)
				let dst = URL(fileURLWithPath: legacy.path + suffix)
				guard fm.fileExists(atPath: src.path) else { continue }
				do {
					try fm.moveItem(at: src, to: dst)
					moved.append((src, dst))
				} catch {
					Logger.data.error("⬆️ CoreDataMigrationService: could not rename \(src.lastPathComponent, privacy: .public); store left in place: \(error.localizedDescription, privacy: .public)")
					for move in moved.reversed() {
						try? fm.moveItem(at: move.to, to: move.from)
					}
					break
				}
			}
		}
	}

	/// The renamed legacy Core Data store that has not yet been migrated into SwiftData,
	/// or nil when there is none in any search folder.
	static func legacyStoreURL(in directories: [URL] = defaultSearchDirectories) -> URL? {
		directories
			.map { legacyStoreFile(in: $0) }
			.first { FileManager.default.fileExists(atPath: $0.path) }
	}

	/// Returns `true` when a renamed legacy Core Data store exists and has not
	/// yet been migrated into SwiftData.
	static func legacyStoreExists(in directories: [URL] = defaultSearchDirectories) -> Bool {
		legacyStoreURL(in: directories) != nil
	}

	/// For Clear App Data: the old Core Data store in every search folder, under any of its
	/// names, with its journals. That is the store not yet renamed, the one waiting to be imported
	/// (the next launch would import it and bring every chat back), the backup kept after an
	/// import, older backups parked under a timestamp, and an unfinished import's marker.
	/// Must not run while an import may (`LegacyStoreImport` holds the UI back until it ends).
	static func removeLegacyStores(in directories: [URL] = defaultSearchDirectories) {
		let fm = FileManager.default
		for directory in directories {
			let legacy = legacyStoreFile(in: directory)
			let prefixes = [legacy.lastPathComponent, backupStoreURL(forLegacy: legacy).lastPathComponent]
			var doomed: [URL] = []
			let candidate = candidateStoreURL(in: directory)
			// Only a Core Data store: anything else there is left alone by the import too.
			if fm.fileExists(atPath: candidate.path), isCoreDataStore(at: candidate) {
				doomed += ["", "-shm", "-wal"].map { URL(fileURLWithPath: candidate.path + $0) }
			}
			let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
			doomed += names
				.filter { name in prefixes.contains { name.hasPrefix($0) } }
				.map { directory.appendingPathComponent($0) }
			for url in doomed where fm.fileExists(atPath: url.path) {
				do {
					try fm.removeItem(at: url)
				} catch {
					Logger.data.error("⬆️ CoreDataMigrationService: couldn't remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
				}
			}
		}
	}

	/// Performs the full Core Data → SwiftData migration.
	///
	/// The import is all-or-nothing: rows are inserted into a dedicated context that is only
	/// saved once every entity has been read, so a failure part-way leaves the SwiftData store
	/// untouched and nothing half-imported for a later save to commit. The legacy store is
	/// renamed to a backup (never deleted) only after that save succeeds.
	///
	/// - Parameter swiftDataContainer: The already-initialised SwiftData
	///   `ModelContainer` that data should be written into.
	/// - Throws: Any error encountered while reading Core Data or writing
	///   SwiftData.  The caller is responsible for surfacing this to the user
	///   rather than silently destroying data.
	///
	/// Not main-actor bound: a large store takes tens of seconds, so the app runs this off the
	/// main thread behind `LegacyStoreImport` (see MeshtasticApp). Everything here uses its own
	/// contexts. Imports are serialized, because the merge state below is shared.
	static func migrate(
		into swiftDataContainer: ModelContainer,
		searchDirectories: [URL] = defaultSearchDirectories
	) throws {
		importLock.lock()
		defer { importLock.unlock() }
		guard let legacyURL = legacyStoreURL(in: searchDirectories) else {
			Logger.data.info("⬆️ CoreDataMigrationService: no legacy store to migrate")
			return
		}
		Logger.data.info("⬆️ CoreDataMigrationService: beginning legacy migration from \(legacyURL.path, privacy: .public)")

		// Reset merge state: non-empty only in the rescue scenario (#2152) — releases
		// 2.7.13–2.7.16 shipped without the legacy model, so affected users upgraded, the
		// migration threw, and they kept using the app. Their SwiftData store is populated
		// while the legacy store still sits on disk. When the migration finally runs, legacy
		// rows fill the history gaps but must not duplicate nodes/users/messages that the
		// mesh has since re-taught the app, nor clobber their fresher configs and channels.
		preexistingNodeNums = []
		preexistingMyInfoNums = []

		let coreDataContainer = try makeCoreDataContainer(storeURL: legacyURL)
		defer { closeStores(of: coreDataContainer) }
		// A private-queue context, not viewContext (which belongs to the main thread).
		let cdContext = coreDataContainer.newBackgroundContext()
		cdContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
		// Read-only use: nothing to undo, and no undo log to grow with every row read.
		cdContext.undoManager = nil

		try cdContext.performAndWait {
			try importAll(cdContext: cdContext, into: swiftDataContainer, legacyURL: legacyURL)
		}
		Logger.data.info("⬆️ CoreDataMigrationService: SwiftData save complete")

		// ── Rename old store so this migration never runs again ──────────────
		// Close the legacy SQLite connection first so its WAL is checkpointed into the
		// file being renamed rather than written to the old path afterwards.
		closeStores(of: coreDataContainer)
		renameOldStore(at: legacyURL)
		// The same store left in another search folder (a copy, or an older install's) would
		// be imported again on the next launch and double every position and reading. It is
		// kept as a backup there, never imported.
		for directory in searchDirectories {
			let other = legacyStoreFile(in: directory)
			guard other.standardizedFileURL != legacyURL.standardizedFileURL,
				  FileManager.default.fileExists(atPath: other.path) else { continue }
			Logger.data.info("⬆️ CoreDataMigrationService: another legacy store at \(other.path, privacy: .public); keeping it as a backup without importing it")
			renameOldStore(at: other)
		}
	}

	/// Only one import runs at a time: the merge state (`preexistingNodeNums`) is per import.
	private static let importLock = NSLock()

	/// The import itself, on `cdContext`'s queue. All-or-nothing, one of two ways:
	///
	/// - Into an empty store (an ordinary upgrade): rows are saved a chunk at a time, so memory
	///   stays bounded instead of holding every row of a large store until one final save. A
	///   failure empties the store again; a crash part-way leaves `importMarker` behind, and the
	///   next attempt empties the store before it starts over. Either way the store ends up with
	///   the whole import or nothing, and the legacy store is kept until it has it all.
	/// - Into a store that already has data (the rescue case, see `migrate`): rows go into a
	///   context saved once, at the end, and dropped on any throw.
	private static func importAll(cdContext: NSManagedObjectContext, into swiftDataContainer: ModelContainer, legacyURL: URL) throws {
		let marker = importMarker(forLegacy: legacyURL)
		if FileManager.default.fileExists(atPath: marker.path) {
			// An earlier attempt into an empty store didn't finish: what it saved goes first.
			Logger.data.warning("⬆️ CoreDataMigrationService: an earlier import was interrupted; emptying the store before importing again")
			do {
				try emptyStore(swiftDataContainer)
			} catch {
				// The marker stays: the store still holds part of an import, so nothing may use it.
				Logger.data.fault("⬆️ CoreDataMigrationService: couldn't empty an interrupted import: \(error.localizedDescription, privacy: .public)")
				throw MigrationError.storeNotEmptied
			}
		}

		// A context of its own, not the main one: on a throw it is simply dropped, so no
		// partial import lingers in mainContext to be committed by the next unrelated save.
		let sdContext = ModelContext(swiftDataContainer)
		sdContext.autosaveEnabled = false

		let startsEmpty = try isEmpty(sdContext)
		if startsEmpty {
			try Data().write(to: marker)
			chunkCommitContext = sdContext
		}
		defer { chunkCommitContext = nil }

		do {
			// ── Phase 1: nodes, users, info (no inter-entity dependencies) ──────
			let nodeMap   = try migrateNodes(cdContext: cdContext, sdContext: sdContext)
			let userMap   = try migrateUsers(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			let infoMap   = try migrateMyInfos(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)

			// ── Phase 2: entities that hang off nodes ────────────────────────────
			try migrateChannels(cdContext: cdContext, sdContext: sdContext, infoMap: infoMap)
			try migratePositions(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateTelemetry(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateBluetoothConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateCannedMessageConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateDeviceConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateDisplayConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateExternalNotifConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateLoRaConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateMQTTConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateNetworkConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migratePositionConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateRangeTestConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateSerialConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)
			try migrateTelemetryConfigs(cdContext: cdContext, sdContext: sdContext, nodeMap: nodeMap)

			// ── Phase 3: messages (depend on user map) ───────────────────────────
			try migrateMessages(cdContext: cdContext, sdContext: sdContext, userMap: userMap)

			// ── Persist ──────────────────────────────────────────────────────────
			try sdContext.save()
		} catch {
			sdContext.rollback()
			if startsEmpty {
				// Saved chunks are taken out again, and the marker goes only once the store is
				// checked empty. If it isn't (most likely the disk is full), the marker stays, the
				// next attempt empties the store first, and this session must not use the store:
				// anything saved into it now would be emptied with the half import.
				do {
					try emptyStore(swiftDataContainer)
				} catch let cleanupError {
					Logger.data.fault("⬆️ CoreDataMigrationService: couldn't empty the store after a failed import (\(error.localizedDescription, privacy: .public)); it is emptied before the next attempt: \(cleanupError.localizedDescription, privacy: .public)")
					throw MigrationError.storeNotEmptied
				}
				try? FileManager.default.removeItem(at: marker)
			}
			Logger.data.error("⬆️ CoreDataMigrationService: import failed, nothing saved; legacy store kept at \(legacyURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
			throw error
		}
		try? FileManager.default.removeItem(at: marker)
	}

	/// Present while an import into an empty store is under way (see `importAll`).
	static func importMarker(forLegacy legacyURL: URL) -> URL {
		URL(fileURLWithPath: legacyURL.path + ".importing")
	}

	/// The context that `forEachObject` saves after each chunk, while an import into an empty
	/// store runs. Guarded by `importLock`.
	nonisolated(unsafe) static var chunkCommitContext: ModelContext?

	#if DEBUG
	/// Test-only: throws after this many chunks have been saved, to stand in for a failure
	/// part-way through. Guarded by `importLock`.
	nonisolated(unsafe) static var failAfterSavedChunks: Int?
	/// Test-only: `emptyStore` throws before deleting anything.
	nonisolated(unsafe) static var failEmptyStore = false
	/// Test-only: `emptyStore` leaves this type's rows without saying so, the way a batch
	/// delete on a full disk does.
	nonisolated(unsafe) static var emptyStoreLeavesType: (any PersistentModel.Type)?
	#endif

	/// Every type the import writes.
	private static let importedTypes: [any PersistentModel.Type] = [
		MessageEntity.self, PositionEntity.self, TelemetryEntity.self, ChannelEntity.self,
		BluetoothConfigEntity.self, CannedMessageConfigEntity.self, DeviceConfigEntity.self,
		DisplayConfigEntity.self, ExternalNotificationConfigEntity.self, LoRaConfigEntity.self,
		MQTTConfigEntity.self, NetworkConfigEntity.self, PositionConfigEntity.self,
		RangeTestConfigEntity.self, SerialConfigEntity.self, TelemetryConfigEntity.self,
		MyInfoEntity.self, UserEntity.self, NodeInfoEntity.self
	]

	/// True when the store holds no row of any type the import writes.
	private static func isEmpty(_ context: ModelContext) throws -> Bool {
		try importedTypes.allSatisfy { try rowCount($0, in: context) == 0 }
	}

	private static func rowCount<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> Int {
		try context.fetchCount(FetchDescriptor<T>())
	}

	/// Deletes the rows of every type the import writes, one type per save (a single save over
	/// many types' deletions trips SwiftData; see `PersistenceController.clearDatabase`). Only
	/// used on a store whose chats were empty before the import, so those rows came from it.
	/// Other types (the device catalogue, which the app may fill at launch) are left alone.
	///
	/// Returns only once a fresh read finds none of those rows left. A batch delete
	/// (`delete(model:)`) on a full disk can log the failure and return normally with every row
	/// still there, so its success proves nothing; whatever it leaves is deleted again a fetched
	/// batch at a time, and if rows are still left after that, this throws.
	static func emptyStore(_ container: ModelContainer) throws {
		#if DEBUG
		if failEmptyStore { throw MigrationError.interruptedForTesting }
		#endif
		let context = ModelContext(container)
		context.autosaveEnabled = false
		let importedNames = Set(importedTypes.map { String(describing: $0) })
		// In the schema's order, the one the app's own clear uses.
		let ordered = MeshtasticSchema.allModels.filter { importedNames.contains(String(describing: $0)) }
		for modelType in ordered where !skippedForTesting(modelType) {
			do {
				try context.delete(model: modelType)
				try context.save()
			} catch {
				// Not fatal yet: the rows it couldn't take are deleted one by one below.
				context.rollback()
				Logger.data.error("⬆️ CoreDataMigrationService: batch delete of \(String(describing: modelType), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
			}
		}
		// A fresh context reads what the store really holds, not what this one thinks it deleted.
		for modelType in ordered where !skippedForTesting(modelType) {
			try deleteByFetch(modelType, in: ModelContext(container))
		}
		let check = ModelContext(container)
		let left = try importedTypes.filter { try rowCount($0, in: check) > 0 }
		if !left.isEmpty {
			throw MigrationError.rowsLeft(left.map { String(describing: $0) })
		}
	}

	/// Deletes every row of `type`, a fetched batch per save, so delete rules run per object.
	private static func deleteByFetch<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
		context.autosaveEnabled = false
		var descriptor = FetchDescriptor<T>()
		descriptor.fetchLimit = 500
		// Bounded: a save that reports success but deletes nothing must not loop forever.
		var rounds = try rowCount(type, in: context) / 500 + 2
		while rounds > 0 {
			rounds -= 1
			let batch = try context.fetch(descriptor)
			if batch.isEmpty { return }
			Logger.data.warning("⬆️ CoreDataMigrationService: deleting \(batch.count, privacy: .public) leftover \(String(describing: type), privacy: .public) rows one by one")
			batch.forEach { context.delete($0) }
			try context.save()
		}
	}

	private static func skippedForTesting(_ type: any PersistentModel.Type) -> Bool {
		#if DEBUG
		if let skipped = emptyStoreLeavesType { return type == skipped }
		#endif
		return false
	}
}

// MARK: - Store URLs

private extension CoreDataMigrationService {

	/// The original path used by the Core Data build in `directory`.
	static func candidateStoreURL(in directory: URL) -> URL {
		directory.appendingPathComponent("Meshtastic.sqlite")
	}

	/// The URL we rename the Core Data store to before SwiftData opens.
	/// `legacyStoreExists()` checks this file, not the candidate.
	static func legacyStoreFile(in directory: URL) -> URL {
		directory.appendingPathComponent("Meshtastic-coredata-legacy.sqlite")
	}

	/// Where we move the legacy store after a successful migration.
	static func backupStoreURL(forLegacy legacyURL: URL) -> URL {
		legacyURL.deletingLastPathComponent().appendingPathComponent("Meshtastic-coredata-backup.sqlite")
	}

	/// Returns `true` when the SQLite file at `url` is a Core Data store.
	///
	/// Uses `NSPersistentStoreCoordinator.metadataForPersistentStore` which is
	/// read-only — it does not modify the file.
	static func isCoreDataStore(at url: URL) -> Bool {
		guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
			ofType: NSSQLiteStoreType,
			at: url
		) else {
			// metadataForPersistentStore threw — the file exists but is not a
			// recognized SQLite/Core Data store (e.g. it is a SwiftData store
			// or a corrupt file).  Do not rename it.
			return false
		}
		// NSStoreModelVersionHashesKey is present in every Core Data store that
		// has been opened at least once with a versioned model.  Older stores
		// that predate model versioning may lack it, so fall back to checking
		// NSStoreTypeKey as a secondary signal.
		if metadata[NSStoreModelVersionHashesKey] != nil { return true }
		if let type = metadata[NSStoreTypeKey] as? String, type == NSSQLiteStoreType { return true }
		return false
	}
}

// MARK: - Core Data container bootstrap

private extension CoreDataMigrationService {

	/// Creates an `NSPersistentContainer` that opens the *existing* Core Data
	/// store using the bundled `.xcdatamodeld` model.  Automatic lightweight
	/// migration is enabled so any minor schema drift across device upgrades
	/// is handled transparently.
	static func makeCoreDataContainer(storeURL: URL) throws -> NSPersistentContainer {
		guard let momdURL = Bundle.main.url(
			forResource: "Meshtastic",
			withExtension: "momd"
		) else {
			throw MigrationError.modelNotFound
		}

		// Load the V58 model directly by path inside the .momd bundle so this
		// is immune to Xcode resetting .xccurrentversion.  The 2.7.12 App Store
		// wrote stores with MeshtasticDataModelV 58.xcdatamodel — loading it by
		// explicit URL means migration always uses the correct schema regardless
		// of which version .xccurrentversion points to.
		let v58URL = momdURL.appendingPathComponent("MeshtasticDataModelV 58.mom")
		let modelURL: URL
		if FileManager.default.fileExists(atPath: v58URL.path) {
			modelURL = v58URL
		} else {
			// Fallback: let Core Data use whatever .xccurrentversion says.
			modelURL = momdURL
		}

		guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
			throw MigrationError.modelLoadFailed
		}

		let container = NSPersistentContainer(name: "Meshtastic", managedObjectModel: model)

		let storeDescription = NSPersistentStoreDescription(url: storeURL)
		storeDescription.shouldMigrateStoreAutomatically = true
		storeDescription.shouldInferMappingModelAutomatically = true
		container.persistentStoreDescriptions = [storeDescription]

		var loadError: Error?
		container.loadPersistentStores { _, error in
			loadError = error
		}
		if let loadError {
			throw loadError
		}
		return container
	}

	/// Detaches every store from the legacy container, closing its SQLite connection.
	/// Idempotent: a second call finds no stores.
	static func closeStores(of container: NSPersistentContainer) {
		let coordinator = container.persistentStoreCoordinator
		for store in coordinator.persistentStores {
			do {
				try coordinator.remove(store)
			} catch {
				Logger.data.error("⬆️ CoreDataMigrationService: could not close legacy store: \(error.localizedDescription, privacy: .public)")
			}
		}
	}
}

// MARK: - Per-entity migration helpers

// Each function returns a dictionary mapping NSManagedObjectID → SwiftData
// entity so that relationships can be wired up in later phases.

private extension CoreDataMigrationService {

	// MARK: NodeInfoEntity

	/// Node nums that already existed in the SwiftData store when the migration started.
	/// Legacy history (positions, telemetry, messages) still attaches to these nodes, but
	/// the node row itself, its configs, and its channels are NOT migrated — the live store's
	/// versions are fresher. See the reset in `migrate(into:)` for the scenario.
	/// Guarded by `importLock`: only the running import reads or writes it.
	nonisolated(unsafe) private(set) static var preexistingNodeNums: Set<Int64> = []
	/// Same, for MyInfoEntity (keyed by myNodeNum) — gates channel migration.
	nonisolated(unsafe) private(set) static var preexistingMyInfoNums: Set<Int64> = []

	/// Calls `body` for every legacy row of `entityName`, a chunk at a time. Each chunk is
	/// fetched and copied inside its own autorelease pool, then dropped from the context
	/// (`reset`), so rows already copied don't pile up in memory. The maps key on object IDs,
	/// which stay valid across a reset. Returns the number of rows.
	@discardableResult
	static func forEachObject(
		_ entityName: String,
		in cdContext: NSManagedObjectContext,
		chunkSize: Int = 1_000,
		_ body: (NSManagedObject) throws -> Void
	) throws -> Int {
		let idRequest = NSFetchRequest<NSManagedObjectID>(entityName: entityName)
		idRequest.resultType = .managedObjectIDResultType
		let ids = try cdContext.fetch(idRequest)
		var start = 0
		while start < ids.count {
			let chunk = Array(ids[start..<min(start + chunkSize, ids.count)])
			try autoreleasepool {
				let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
				request.predicate = NSPredicate(format: "self IN %@", chunk)
				request.returnsObjectsAsFaults = false
				for obj in try cdContext.fetch(request) {
					try body(obj)
				}
			}
			cdContext.reset()
			start += chunkSize
			if let sdContext = chunkCommitContext, sdContext.hasChanges {
				try autoreleasepool {
					try sdContext.save()
				}
				#if DEBUG
				if let remaining = failAfterSavedChunks {
					guard remaining > 1 else { throw MigrationError.interruptedForTesting }
					failAfterSavedChunks = remaining - 1
				}
				#endif
			}
		}
		return ids.count
	}

	static func migrateNodes(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext
	) throws -> [NSManagedObjectID: NodeInfoEntity] {
		var map = [NSManagedObjectID: NodeInfoEntity]()

		let existingByNum = Dictionary(
			(try sdContext.fetch(FetchDescriptor<NodeInfoEntity>())).map { ($0.num, $0) },
			uniquingKeysWith: { first, _ in first }
		)

		var migrated = 0
		let total = try forEachObject("NodeInfoEntity", in: cdContext) { obj in
			let num = (obj.value(forKey: "num") as? Int64) ?? 0
			if let existing = existingByNum[num] {
				// Rescue merge: the mesh re-taught the app this node after the failed
				// migration. Keep the live row; legacy history will attach to it.
				preexistingNodeNums.insert(num)
				map[obj.objectID] = existing
				return
			}
			let sd = NodeInfoEntity()
			sd.bleName      = obj.value(forKey: "bleName") as? String
			sd.channel      = (obj.value(forKey: "channel") as? Int32) ?? 0
			sd.id           = (obj.value(forKey: "id") as? Int64) ?? 0
			sd.lastHeard    = obj.value(forKey: "lastHeard") as? Date ?? Date()
			sd.num          = num
			sd.snr          = (obj.value(forKey: "snr") as? Float) ?? 0
			sd.favorite     = (obj.value(forKey: "favorite") as? Bool) ?? false
			sd.firstHeard   = obj.value(forKey: "firstHeard") as? Date
			sd.hopsAway     = (obj.value(forKey: "hopsAway") as? Int32) ?? 0
			sd.ignored      = (obj.value(forKey: "ignored") as? Bool) ?? false
			sd.peripheralId = obj.value(forKey: "peripheralId") as? String
			sd.rssi         = (obj.value(forKey: "rssi") as? Int32) ?? 0
			sd.sessionExpiration = obj.value(forKey: "sessionExpiration") as? Date
			sd.sessionPasskey = obj.value(forKey: "sessionPasskey") as? Data
			sd.viaMqtt      = (obj.value(forKey: "viaMqtt") as? Bool) ?? false
			sdContext.insert(sd)
			map[obj.objectID] = sd
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(total) NodeInfoEntity records (\(preexistingNodeNums.count) already present)")
		return map
	}

	// MARK: UserEntity

	static func migrateUsers(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws -> [NSManagedObjectID: UserEntity] {
		var map = [NSManagedObjectID: UserEntity]()

		let existingByNum = Dictionary(
			(try sdContext.fetch(FetchDescriptor<UserEntity>())).map { ($0.num, $0) },
			uniquingKeysWith: { first, _ in first }
		)

		// UserEntity.num is unique, so legacy rows sharing a num (legal in V58) end up as one
		// user. The one kept is the row with a node and a key, so the contact stays linked
		// and can still be messaged; the other rows' messages point at it.
		var importedByNum = [Int64: (user: UserEntity, score: Int)]()
		func score(_ obj: NSManagedObject) -> Int {
			let hasNode = obj.value(forKey: "userNode") != nil
			let hasKey = (obj.value(forKey: "publicKey") as? Data)?.isEmpty == false
			return (hasNode ? 2 : 0) + (hasKey ? 1 : 0)
		}

		func fill(_ sd: UserEntity, from obj: NSManagedObject) {
			sd.hwModel   = obj.value(forKey: "hwModel") as? String
			sd.isLicensed = (obj.value(forKey: "isLicensed") as? Bool) ?? false
			sd.longName  = obj.value(forKey: "longName") as? String
			sd.shortName = obj.value(forKey: "shortName") as? String
			sd.userId    = obj.value(forKey: "userId") as? String
			sd.hwDisplayName = obj.value(forKey: "hwDisplayName") as? String
			sd.hwModelId = (obj.value(forKey: "hwModelId") as? Int32) ?? 0
			sd.numString = obj.value(forKey: "numString") as? String
			sd.role      = (obj.value(forKey: "role") as? Int32) ?? 0
			sd.unmessagable = (obj.value(forKey: "unmessagable") as? Bool) ?? false
			sd.mute      = (obj.value(forKey: "mute") as? Bool) ?? false
			// Chats lists a DM conversation only while lastMessage is set.
			sd.lastMessage = obj.value(forKey: "lastMessage") as? Date
			// Keys: without them every contact reads as keyless (DMs refused, no profile sync)
			// until its NodeInfo is heard again.
			sd.publicKey = obj.value(forKey: "publicKey") as? Data
			sd.pkiEncrypted = (obj.value(forKey: "pkiEncrypted") as? Bool) ?? false
			sd.keyMatch  = (obj.value(forKey: "keyMatch") as? Bool) ?? true
			sd.newPublicKey = obj.value(forKey: "newPublicKey") as? Data
			// macaddr existed in Core Data but is intentionally dropped in SwiftData

			if let cdNode = obj.value(forKey: "userNode") as? NSManagedObject,
			   let sdNode = nodeMap[cdNode.objectID],
			   sdNode.user == nil || sdNode.user === sd {
				// Only claim the node when it has no live user; a preexisting node keeps its
				// (fresher) user rather than being reparented onto the legacy row.
				sd.userNode = sdNode
			}
		}

		var migrated = 0
		let total = try forEachObject("UserEntity", in: cdContext) { obj in
			let num = (obj.value(forKey: "num") as? Int64) ?? 0
			if let existing = existingByNum[num] {
				map[obj.objectID] = existing
				return
			}
			let rowScore = score(obj)
			if let imported = importedByNum[num] {
				map[obj.objectID] = imported.user
				if rowScore > imported.score {
					// The chat stays listed from whichever row last had a message.
					let earlierLastMessage = imported.user.lastMessage
					fill(imported.user, from: obj)
					if let earlierLastMessage, earlierLastMessage > (imported.user.lastMessage ?? .distantPast) {
						imported.user.lastMessage = earlierLastMessage
					}
					importedByNum[num] = (imported.user, rowScore)
				}
				return
			}
			let sd = UserEntity()
			sd.num = num
			fill(sd, from: obj)
			sdContext.insert(sd)
			importedByNum[num] = (sd, rowScore)
			map[obj.objectID] = sd
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(total) UserEntity records")
		return map
	}

	// MARK: MyInfoEntity

	static func migrateMyInfos(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws -> [NSManagedObjectID: MyInfoEntity] {
		var map = [NSManagedObjectID: MyInfoEntity]()

		let existingByNum = Dictionary(
			(try sdContext.fetch(FetchDescriptor<MyInfoEntity>())).map { ($0.myNodeNum, $0) },
			uniquingKeysWith: { first, _ in first }
		)

		var migrated = 0
		let total = try forEachObject("MyInfoEntity", in: cdContext) { obj in
			let myNodeNum = (obj.value(forKey: "myNodeNum") as? Int64) ?? 0
			if let existing = existingByNum[myNodeNum] {
				preexistingMyInfoNums.insert(myNodeNum)
				map[obj.objectID] = existing
				return
			}
			let sd = MyInfoEntity()
			sd.bleName         = obj.value(forKey: "bleName") as? String
			sd.minAppVersion   = (obj.value(forKey: "minAppVersion") as? Int32) ?? 0
			sd.myNodeNum       = myNodeNum
			sd.peripheralId    = obj.value(forKey: "peripheralId") as? String
			sd.rebootCount     = (obj.value(forKey: "rebootCount") as? Int32) ?? 0
			sd.deviceId        = obj.value(forKey: "deviceId") as? Data
			sd.pioEnv          = obj.value(forKey: "pioEnv") as? String
			sd.registered      = (obj.value(forKey: "registered") as? Bool) ?? false

			if let cdNode = obj.value(forKey: "myInfoNode") as? NSManagedObject,
			   let sdNode = nodeMap[cdNode.objectID] {
				sd.myInfoNode = sdNode
			}
			sdContext.insert(sd)
			map[obj.objectID] = sd
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(total) MyInfoEntity records")
		return map
	}

	// MARK: ChannelEntity

	static func migrateChannels(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		infoMap: [NSManagedObjectID: MyInfoEntity]
	) throws {
		var migrated = 0
		let total = try forEachObject("ChannelEntity", in: cdContext) { obj in
			let cdInfo = obj.value(forKey: "myInfoChannel") as? NSManagedObject
			guard let sdInfo = cdInfo.flatMap({ infoMap[$0.objectID] }) else {
				// A channel belongs to a radio. One with no MyInfo would be listed by the readers
				// that fetch every ChannelEntity (TAK, the Siri fallback) as a duplicate.
				return
			}
			if preexistingMyInfoNums.contains(sdInfo.myNodeNum) {
				// Rescue merge: this radio's MyInfo survived the failed migration and its
				// current channel set is fresher than the legacy one — don't duplicate it.
				return
			}
			let sd = ChannelEntity()
			sd.downlinkEnabled = (obj.value(forKey: "downlinkEnabled") as? Bool) ?? false
			sd.id              = (obj.value(forKey: "id") as? Int32) ?? 0
			sd.index           = (obj.value(forKey: "index") as? Int32) ?? 0
			sd.name            = obj.value(forKey: "name") as? String
			sd.psk             = obj.value(forKey: "psk") as? Data
			sd.role            = (obj.value(forKey: "role") as? Int32) ?? 0
			sd.uplinkEnabled   = (obj.value(forKey: "uplinkEnabled") as? Bool) ?? false
			sd.mute            = (obj.value(forKey: "mute") as? Bool) ?? false
			sd.positionPrecision = (obj.value(forKey: "positionPrecision") as? Int32) ?? 32

			sd.myInfoChannel = sdInfo
			sdContext.insert(sd)
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(total) ChannelEntity records")
	}

	// MARK: MessageEntity

	static func migrateMessages(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		userMap: [NSManagedObjectID: UserEntity]
	) throws {
		let existingMessageIds = Set(
			(try sdContext.fetch(FetchDescriptor<MessageEntity>())).map { $0.messageId }
		)

		var migrated = 0
		let total = try forEachObject("MessageEntity", in: cdContext) { obj in
			let messageId = (obj.value(forKey: "messageId") as? Int64) ?? 0
			// Rescue merge: don't duplicate a message the live store already has.
			if existingMessageIds.contains(messageId) { return }
			let sd = MessageEntity()
			sd.ackError        = (obj.value(forKey: "ackError") as? Int32) ?? 0
			sd.ackSNR          = (obj.value(forKey: "ackSNR") as? Float) ?? 0
			sd.ackTimestamp    = (obj.value(forKey: "ackTimestamp") as? Int32) ?? 0
			sd.admin           = (obj.value(forKey: "admin") as? Bool) ?? false
			sd.adminDescription = obj.value(forKey: "adminDescription") as? String
			sd.channel         = (obj.value(forKey: "channel") as? Int32) ?? 0
			sd.isEmoji         = (obj.value(forKey: "isEmoji") as? Bool) ?? false
			sd.messageId       = messageId
			sd.messagePayload  = obj.value(forKey: "messagePayload") as? String
			sd.messageTimestamp = (obj.value(forKey: "messageTimestamp") as? Int32) ?? 0
			sd.receivedACK     = (obj.value(forKey: "receivedACK") as? Bool) ?? false
			sd.replyID         = (obj.value(forKey: "replyID") as? Int64) ?? 0
			sd.snr             = (obj.value(forKey: "snr") as? Float) ?? 0
			sd.read            = (obj.value(forKey: "read") as? Bool) ?? false
			sd.realACK         = (obj.value(forKey: "realACK") as? Bool) ?? false
			sd.portNum         = (obj.value(forKey: "portNum") as? Int32) ?? 0
			sd.pkiEncrypted    = (obj.value(forKey: "pkiEncrypted") as? Bool) ?? false
			sd.publicKey       = obj.value(forKey: "publicKey") as? Data
			sd.relayNode       = (obj.value(forKey: "relayNode") as? Int64) ?? 0
			sd.relays          = (obj.value(forKey: "relays") as? Int16) ?? 0
			sd.rssi            = (obj.value(forKey: "rssi") as? Int32) ?? 0
			sd.messagePayloadMarkdown = obj.value(forKey: "messagePayloadMarkdown") as? String
			sd.messagePayloadTranslated = obj.value(forKey: "messagePayloadTranslated") as? String
			sd.messagePayloadTranslatedMarkdown = obj.value(forKey: "messagePayloadTranslatedMarkdown") as? String
			sd.showTranslatedMessage = (obj.value(forKey: "showTranslatedMessage") as? Bool) ?? false

			if let cdFrom = obj.value(forKey: "fromUser") as? NSManagedObject,
			   let sdFrom = userMap[cdFrom.objectID] {
				sd.fromUser = sdFrom
			}
			if let cdTo = obj.value(forKey: "toUser") as? NSManagedObject,
			   let sdTo = userMap[cdTo.objectID] {
				sd.toUser = sdTo
			}
			if sd.toUser != nil && sd.fromUser == nil {
				// A direct message with no sender belongs to no chat, so it could never be
				// opened: left unread, it would hold the badge up for good.
				sd.read = true
			}
			sdContext.insert(sd)
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(total) MessageEntity records")
	}

	// MARK: PositionEntity

	static func migratePositions(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		let total = try forEachObject("PositionEntity", in: cdContext) { obj in
			let sd = PositionEntity()
			sd.altitude    = (obj.value(forKey: "altitude") as? Int32) ?? 0
			sd.heading     = (obj.value(forKey: "heading") as? Int32) ?? 0
			sd.latitudeI   = (obj.value(forKey: "latitudeI") as? Int32) ?? 0
			sd.longitudeI  = (obj.value(forKey: "longitudeI") as? Int32) ?? 0
			sd.satsInView  = (obj.value(forKey: "satsInView") as? Int32) ?? 0
			sd.seqNo       = (obj.value(forKey: "seqNo") as? Int32) ?? 0
			sd.snr         = (obj.value(forKey: "snr") as? Float) ?? 0
			sd.speed       = (obj.value(forKey: "speed") as? Int32) ?? 0
			sd.time        = obj.value(forKey: "time") as? Date

			if let cdNode = obj.value(forKey: "nodePosition") as? NSManagedObject,
			   let sdNode = nodeMap[cdNode.objectID] {
				sd.nodePosition = sdNode
			}
			sdContext.insert(sd)
		}
		Logger.data.info("⬆️ migrated \(total) PositionEntity records")
	}

	// MARK: TelemetryEntity

	static func migrateTelemetry(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		let total = try forEachObject("TelemetryEntity", in: cdContext) { obj in
			let sd = TelemetryEntity()
			sd.metricsType          = (obj.value(forKey: "metricsType") as? Int32) ?? 0
			sd.time                 = obj.value(forKey: "time") as? Date
			sd.airUtilTx            = obj.value(forKey: "airUtilTx") as? Float
			sd.barometricPressure   = obj.value(forKey: "barometricPressure") as? Float
			sd.batteryLevel         = obj.value(forKey: "batteryLevel") as? Int32
			sd.channelUtilization   = obj.value(forKey: "channelUtilization") as? Float
			sd.current              = obj.value(forKey: "current") as? Float
			sd.gasResistance        = obj.value(forKey: "gasResistance") as? Float
			sd.relativeHumidity     = obj.value(forKey: "relativeHumidity") as? Float
			sd.temperature          = obj.value(forKey: "temperature") as? Float
			sd.voltage              = obj.value(forKey: "voltage") as? Float

			if let cdNode = obj.value(forKey: "nodeTelemetry") as? NSManagedObject,
			   let sdNode = nodeMap[cdNode.objectID] {
				sd.nodeTelemetry = sdNode
			}
			sdContext.insert(sd)
		}
		Logger.data.info("⬆️ migrated \(total) TelemetryEntity records")
	}

	// MARK: Config entities

	static func migrateBluetoothConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "BluetoothConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "bluetoothConfigNode",
			nodeMap: nodeMap
		) { obj -> BluetoothConfigEntity in
			let sd = BluetoothConfigEntity()
			sd.enabled  = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.fixedPin = (obj.value(forKey: "fixedPin") as? Int32) ?? 0
			sd.mode     = (obj.value(forKey: "mode") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? BluetoothConfigEntity).map { sdNode.bluetoothConfig = $0 }
		}
	}

	static func migrateCannedMessageConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "CannedMessageConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "cannedMessagesConfigNode",
			nodeMap: nodeMap
		) { obj -> CannedMessageConfigEntity in
			let sd = CannedMessageConfigEntity()
			// enabled is deprecated (no successor) and no longer written — not migrated; the
			// stored property keeps its default. (#2021)
			sd.inputbrokerEventCcw    = (obj.value(forKey: "inputbrokerEventCcw") as? Int32) ?? 0
			sd.inputbrokerEventCw     = (obj.value(forKey: "inputbrokerEventCw") as? Int32) ?? 0
			sd.inputbrokerEventPress  = (obj.value(forKey: "inputbrokerEventPress") as? Int32) ?? 0
			sd.inputbrokerPinA        = (obj.value(forKey: "inputbrokerPinA") as? Int32) ?? 0
			sd.inputbrokerPinB        = (obj.value(forKey: "inputbrokerPinB") as? Int32) ?? 0
			sd.inputbrokerPinPress    = (obj.value(forKey: "inputbrokerPinPress") as? Int32) ?? 0
			sd.rotary1Enabled         = (obj.value(forKey: "rotary1Enabled") as? Bool) ?? false
			sd.sendBell               = (obj.value(forKey: "sendBell") as? Bool) ?? false
			sd.updown1Enabled         = (obj.value(forKey: "updown1Enabled") as? Bool) ?? false
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? CannedMessageConfigEntity).map { sdNode.cannedMessageConfig = $0 }
		}
	}

	static func migrateDeviceConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "DeviceConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "deviceConfigNode",
			nodeMap: nodeMap
		) { obj -> DeviceConfigEntity in
			let sd = DeviceConfigEntity()
			sd.debugLogEnabled = (obj.value(forKey: "debugLogEnabled") as? Bool) ?? false
			sd.role            = (obj.value(forKey: "role") as? Int32) ?? 0
			sd.serialEnabled   = (obj.value(forKey: "serialEnabled") as? Bool) ?? false
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? DeviceConfigEntity).map { sdNode.deviceConfig = $0 }
		}
	}

	static func migrateDisplayConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "DisplayConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "displayConfigNode",
			nodeMap: nodeMap
		) { obj -> DisplayConfigEntity in
			let sd = DisplayConfigEntity()
			sd.compassNorthTop        = (obj.value(forKey: "compassNorthTop") as? Bool) ?? false
			sd.flipScreen             = (obj.value(forKey: "flipScreen") as? Bool) ?? false
			// gpsFormat was removed from the SwiftData model; skip it
			sd.screenCarouselInterval = (obj.value(forKey: "screenCarouselInterval") as? Int32) ?? 0
			sd.screenOnSeconds        = (obj.value(forKey: "screenOnSeconds") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? DisplayConfigEntity).map { sdNode.displayConfig = $0 }
		}
	}

	static func migrateExternalNotifConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "ExternalNotificationConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "externalNotificationConfigNode",
			nodeMap: nodeMap
		) { obj -> ExternalNotificationConfigEntity in
			let sd = ExternalNotificationConfigEntity()
			sd.active             = (obj.value(forKey: "active") as? Bool) ?? false
			sd.alertBell          = (obj.value(forKey: "alertBell") as? Bool) ?? false
			sd.alertMessage       = (obj.value(forKey: "alertMessage") as? Bool) ?? false
			sd.enabled            = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.output             = (obj.value(forKey: "output") as? Int32) ?? 0
			sd.outputMilliseconds = (obj.value(forKey: "outputMilliseconds") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? ExternalNotificationConfigEntity).map { sdNode.externalNotificationConfig = $0 }
		}
	}

	static func migrateLoRaConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "LoRaConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "loRaConfigNode",
			nodeMap: nodeMap
		) { obj -> LoRaConfigEntity in
			let sd = LoRaConfigEntity()
			sd.bandwidth       = (obj.value(forKey: "bandwidth") as? Int32) ?? 0
			sd.channelNum      = (obj.value(forKey: "channelNum") as? Int32) ?? 0
			sd.codingRate      = (obj.value(forKey: "codingRate") as? Int32) ?? 0
			sd.frequencyOffset = (obj.value(forKey: "frequencyOffset") as? Float) ?? 0
			sd.hopLimit        = (obj.value(forKey: "hopLimit") as? Int32) ?? 3
			sd.modemPreset     = (obj.value(forKey: "modemPreset") as? Int32) ?? 0
			sd.regionCode      = (obj.value(forKey: "regionCode") as? Int32) ?? 0
			sd.spreadFactor    = (obj.value(forKey: "spreadFactor") as? Int32) ?? 0
			sd.txEnabled       = (obj.value(forKey: "txEnabled") as? Bool) ?? true
			sd.txPower         = (obj.value(forKey: "txPower") as? Int32) ?? 0
			sd.usePreset       = (obj.value(forKey: "usePreset") as? Bool) ?? true
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? LoRaConfigEntity).map { sdNode.loRaConfig = $0 }
		}
	}

	static func migrateMQTTConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "MQTTConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "mqttConfigNode",
			nodeMap: nodeMap
		) { obj -> MQTTConfigEntity in
			let sd = MQTTConfigEntity()
			sd.address           = obj.value(forKey: "address") as? String
			sd.enabled           = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.encryptionEnabled = (obj.value(forKey: "encryptionEnabled") as? Bool) ?? false
			sd.jsonEnabled       = (obj.value(forKey: "jsonEnabled") as? Bool) ?? false
			sd.password          = obj.value(forKey: "password") as? String
			sd.username          = obj.value(forKey: "username") as? String
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? MQTTConfigEntity).map { sdNode.mqttConfig = $0 }
		}
	}

	static func migrateNetworkConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "NetworkConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "networkConfigNode",
			nodeMap: nodeMap
		) { obj -> NetworkConfigEntity in
			let sd = NetworkConfigEntity()
			sd.ntpServer   = obj.value(forKey: "ntpServer") as? String
			sd.wifiEnabled = (obj.value(forKey: "wifiEnabled") as? Bool) ?? false
			sd.wifiPsk     = obj.value(forKey: "wifiPsk") as? String
			sd.wifiSsid    = obj.value(forKey: "wifiSsid") as? String
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? NetworkConfigEntity).map { sdNode.networkConfig = $0 }
		}
	}

	static func migratePositionConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "PositionConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "positionConfigNode",
			nodeMap: nodeMap
		) { obj -> PositionConfigEntity in
			let sd = PositionConfigEntity()
			sd.deviceGpsEnabled           = (obj.value(forKey: "deviceGpsEnabled") as? Bool) ?? false
			sd.fixedPosition              = (obj.value(forKey: "fixedPosition") as? Bool) ?? false
			sd.gpsAttemptTime             = (obj.value(forKey: "gpsAttemptTime") as? Int32) ?? 0
			sd.gpsUpdateInterval          = (obj.value(forKey: "gpsUpdateInterval") as? Int32) ?? 0
			sd.positionBroadcastSeconds   = (obj.value(forKey: "positionBroadcastSeconds") as? Int32) ?? 0
			sd.positionFlags              = (obj.value(forKey: "positionFlags") as? Int32) ?? 0
			sd.smartPositionEnabled       = (obj.value(forKey: "smartPositionEnabled") as? Bool) ?? false
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? PositionConfigEntity).map { sdNode.positionConfig = $0 }
		}
	}

	static func migrateRangeTestConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "RangeTestConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "rangeTestConfigNode",
			nodeMap: nodeMap
		) { obj -> RangeTestConfigEntity in
			let sd = RangeTestConfigEntity()
			sd.enabled = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.save    = (obj.value(forKey: "save") as? Bool) ?? false
			sd.sender  = (obj.value(forKey: "sender") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? RangeTestConfigEntity).map { sdNode.rangeTestConfig = $0 }
		}
	}

	static func migrateSerialConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "SerialConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "serialConfigNode",
			nodeMap: nodeMap
		) { obj -> SerialConfigEntity in
			let sd = SerialConfigEntity()
			sd.baudRate = (obj.value(forKey: "baudRate") as? Int32) ?? 0
			sd.echo     = (obj.value(forKey: "echo") as? Bool) ?? false
			sd.enabled  = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.mode     = (obj.value(forKey: "mode") as? Int32) ?? 0
			sd.rxd      = (obj.value(forKey: "rxd") as? Int32) ?? 0
			sd.timeout  = (obj.value(forKey: "timeout") as? Int32) ?? 0
			sd.txd      = (obj.value(forKey: "txd") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? SerialConfigEntity).map { sdNode.serialConfig = $0 }
		}
	}

	static func migrateTelemetryConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		try migrateConfigEntity(
			entityName: "TelemetryConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "telemetryConfigNode",
			nodeMap: nodeMap
		) { obj -> TelemetryConfigEntity in
			let sd = TelemetryConfigEntity()
			sd.deviceUpdateInterval           = (obj.value(forKey: "deviceUpdateInterval") as? Int32) ?? 0
			sd.environmentDisplayFahrenheit   = (obj.value(forKey: "environmentDisplayFahrenheit") as? Bool) ?? false
			sd.environmentMeasurementEnabled  = (obj.value(forKey: "environmentMeasurementEnabled") as? Bool) ?? false
			return sd
		} wireNode: { sdNode, sdConfig in
			(sdConfig as? TelemetryConfigEntity).map { sdNode.telemetryConfig = $0 }
		}
	}

	// MARK: Generic config helper

	/// Generic helper that fetches a config entity, creates the SwiftData
	/// counterpart via `make`, inserts it, and links it to its parent node via
	/// `wireNode`.
	static func migrateConfigEntity<T: PersistentModel>(
		entityName: String,
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeKey: String,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		make: (NSManagedObject) throws -> T,
		wireNode: (NodeInfoEntity, T) -> Void
	) throws {
		var migrated = 0
		let total = try forEachObject(entityName, in: cdContext) { obj in
			let cdNode = obj.value(forKey: nodeKey) as? NSManagedObject
			let sdNode = cdNode.flatMap { nodeMap[$0.objectID] }
			if let sdNode, preexistingNodeNums.contains(sdNode.num) {
				// Rescue merge: this node survived the failed migration; its current config
				// reflects the radio's live state and must not be replaced by the legacy one.
				return
			}
			let sd = try make(obj)
			if let sdNode {
				wireNode(sdNode, sd)
			}
			sdContext.insert(sd)
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(total) \(entityName) records")
	}
}

// MARK: - Store rename

private extension CoreDataMigrationService {

	/// Renames the legacy store and its SQLite sidecar files to the backup name so the
	/// migration never runs again. The files are kept, never deleted.
	static func renameOldStore(at legacyURL: URL) {
		let fm = FileManager.default
		let backupURL = backupStoreURL(forLegacy: legacyURL)

		// An older backup would block the move; park it under a timestamp instead of
		// overwriting or deleting it.
		if fm.fileExists(atPath: backupURL.path) {
			let stamp = Int(Date().timeIntervalSince1970)
			for suffix in ["", "-shm", "-wal"] {
				let src = URL(fileURLWithPath: backupURL.path + suffix)
				guard fm.fileExists(atPath: src.path) else { continue }
				try? fm.moveItem(at: src, to: URL(fileURLWithPath: backupURL.path + ".\(stamp)" + suffix))
			}
		}

		// Main file first: once it has moved, `legacyStoreExists()` is false and the import
		// cannot run a second time, even if a sidecar move fails.
		for suffix in ["", "-shm", "-wal"] {
			let src = URL(fileURLWithPath: legacyURL.path + suffix)
			let dst = URL(fileURLWithPath: backupURL.path + suffix)
			guard fm.fileExists(atPath: src.path) else { continue }
			do {
				try fm.moveItem(at: src, to: dst)
			} catch {
				Logger.data.error("⬆️ CoreDataMigrationService: could not rename \(src.lastPathComponent, privacy: .public) to the backup name: \(error.localizedDescription, privacy: .public)")
			}
		}
		if fm.fileExists(atPath: legacyURL.path) {
			Logger.data.fault("⬆️ CoreDataMigrationService: imported, but the legacy store is still at \(legacyURL.path, privacy: .public); the import will be attempted again next launch")
		} else {
			Logger.data.info("⬆️ CoreDataMigrationService: legacy store kept as \(backupURL.path, privacy: .public) – migration complete")
		}
	}
}

// MARK: - Errors

enum MigrationError: LocalizedError {
	case modelNotFound
	case modelLoadFailed
	/// A failed import's rows couldn't all be taken out again; the store must not be used
	/// until a later launch has emptied it.
	case storeNotEmptied
	/// `emptyStore` found these types' rows still in the store.
	case rowsLeft([String])
	#if DEBUG
	case interruptedForTesting
	#endif

	var errorDescription: String? {
		switch self {
		case .modelNotFound:  return "Legacy Core Data model file not found in bundle."
		case .modelLoadFailed: return "Failed to load legacy Core Data model from bundle."
		case .storeNotEmptied: return "A failed import couldn't be taken out of the store."
		case .rowsLeft(let types): return "Rows left after emptying the store: \(types.joined(separator: ", "))."
		#if DEBUG
		case .interruptedForTesting: return "Import stopped part-way by a test."
		#endif
		}
	}
}
