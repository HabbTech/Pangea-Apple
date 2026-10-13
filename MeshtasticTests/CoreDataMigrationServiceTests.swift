//
//  CoreDataMigrationServiceTests.swift
//  MeshtasticTests
//
//  Regression tests for #2152: the Core Data → SwiftData migration silently never ran in
//  2.7.13–2.7.16 because Meshtastic.momd was dropped from the app target's Resources build
//  phase by a hand-resolved project.pbxproj conflict (#1898). These tests guard the bundled
//  model itself and exercise the full migration — including the "rescue" merge into a store
//  the user has already been writing to since the failed upgrade.
//

import XCTest
import CoreData
import SwiftData
@testable import Meshtastic

final class CoreDataMigrationServiceTests: XCTestCase {

	// A scratch "Application Support" laid out like a real install. On macOS / Mac Catalyst
	// the pre-SwiftData build kept its store one folder down, in `Application Support/Pangea/`
	// (NSPersistentContainer.defaultDirectoryURL()); on iOS it sat in Application Support
	// itself. The service searches both, so these tests do too.
	private var applicationSupportURL: URL!
	private var productFolderURL: URL { applicationSupportURL.appendingPathComponent("Pangea", isDirectory: true) }
	private var searchDirectories: [URL] { [productFolderURL, applicationSupportURL] }
	private var originalStoreURL: URL { productFolderURL.appendingPathComponent("Meshtastic.sqlite") }
	private var legacyStoreURL: URL { productFolderURL.appendingPathComponent("Meshtastic-coredata-legacy.sqlite") }
	private var backupStoreURL: URL { productFolderURL.appendingPathComponent("Meshtastic-coredata-backup.sqlite") }

	override func setUpWithError() throws {
		try super.setUpWithError()
		applicationSupportURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("CoreDataMigrationServiceTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: productFolderURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: applicationSupportURL)
		try super.tearDownWithError()
	}

	// MARK: - Store location

	/// The real search list must include the folder `NSPersistentContainer(name:)` wrote to —
	/// on Mac Catalyst that is `Application Support/Pangea/`, not Application Support itself.
	func testDefaultSearchIncludesCoreDataDefaultDirectory() {
		let paths = CoreDataMigrationService.defaultSearchDirectories.map(\.standardizedFileURL.path)
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		XCTAssertTrue(paths.contains(NSPersistentContainer.defaultDirectoryURL().standardizedFileURL.path))
		XCTAssertTrue(paths.contains(appSupport.standardizedFileURL.path))
		XCTAssertEqual(paths.count, Set(paths).count, "search folders must not repeat")
	}

	/// A store in the product folder (the Mac layout) is found and renamed aside, with its
	/// sidecars, and nothing is deleted.
	func testPrepareFindsStoreInProductFolder() throws {
		try buildLegacyStore(at: originalStoreURL)
		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))

		CoreDataMigrationService.prepareForMigration(in: searchDirectories)

		XCTAssertFalse(FileManager.default.fileExists(atPath: originalStoreURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStoreURL.path))
		XCTAssertEqual(CoreDataMigrationService.legacyStoreURL(in: searchDirectories)?.standardizedFileURL, legacyStoreURL.standardizedFileURL)
	}

	/// A file that is not a Core Data store is left exactly where it is.
	func testPrepareLeavesNonCoreDataFileAlone() throws {
		try Data("not a database".utf8).write(to: originalStoreURL)
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		XCTAssertTrue(FileManager.default.fileExists(atPath: originalStoreURL.path))
		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))
	}

	/// A failed import saves nothing and keeps the legacy store, so the next launch can retry
	/// instead of committing half an import.
	@MainActor
	func testFailedImportSavesNothingAndKeepsLegacyStore() throws {
		try Data("not a database".utf8).write(to: legacyStoreURL)
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationFailTest", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)

		XCTAssertThrowsError(try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories))

		XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStoreURL.path), "legacy store must never be removed on failure")
		XCTAssertFalse(FileManager.default.fileExists(atPath: backupStoreURL.path))
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<NodeInfoEntity>()), 0)
		XCTAssertFalse(container.mainContext.hasChanges)
	}

	// MARK: - Bundle regression guard

	/// The direct #2152 regression: the compiled legacy model must ship in the app bundle,
	/// including the exact versioned model the migration loads by name. If this fails, the
	/// one-time migration throws `modelNotFound` on every launch and upgraders from ≤2.7.12
	/// see an empty database.
	func testLegacyCoreDataModelIsInAppBundle() throws {
		let momdURL = Bundle.main.url(forResource: "Meshtastic", withExtension: "momd")
		XCTAssertNotNil(
			momdURL,
			"Meshtastic.momd is missing from the app bundle — Meshtastic.xcdatamodeld must stay in the app target's Resources build phase (#2152)"
		)
		guard let momdURL else { return }

		let v58URL = momdURL.appendingPathComponent("MeshtasticDataModelV 58.mom")
		XCTAssertTrue(
			FileManager.default.fileExists(atPath: v58URL.path),
			"MeshtasticDataModelV 58.mom (the version CoreDataMigrationService loads) is missing from Meshtastic.momd"
		)
		XCTAssertNotNil(NSManagedObjectModel(contentsOf: v58URL), "The bundled V58 model failed to load")
	}

	// MARK: - End-to-end migration

	/// Full migration into a POPULATED SwiftData store — the #2152 rescue scenario. Users on
	/// 2.7.13–2.7.16 upgraded, the migration threw, and they kept using the app; their legacy
	/// store still sits on disk. When the migration finally runs it must fill the gaps
	/// (old nodes, users, messages, configs) without duplicating rows the mesh has since
	/// re-taught the app, and without replacing their fresher configs/channels. A fresh
	/// install is the degenerate case (nothing preexisting), so this covers both paths:
	/// node 111 exists only in the legacy store, node 222 exists in both.
	@MainActor
	func testMigrationFillsGapsWithoutDuplicatingLiveData() throws {
		try buildLegacyStore(at: originalStoreURL)
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))

		// Destination store, as the rescued user's app would have it: node 222 re-taught by
		// the mesh (with a fresher bleName and a live device config), message 1002 re-received.
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationTest", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)
		let context = container.mainContext

		let liveNode = NodeInfoEntity()
		liveNode.num = 222
		liveNode.bleName = "live-222"
		context.insert(liveNode)
		let liveUser = UserEntity()
		liveUser.num = 222
		liveUser.longName = "Live User 222"
		liveUser.userNode = liveNode
		context.insert(liveUser)
		let liveConfig = DeviceConfigEntity()
		liveConfig.role = 1
		context.insert(liveConfig)
		liveNode.deviceConfig = liveConfig
		let liveMessage = MessageEntity()
		liveMessage.messageId = 1002
		liveMessage.messagePayload = "live copy"
		context.insert(liveMessage)
		try context.save()

		try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)
		XCTAssertFalse(context.hasChanges, "the import must not leave pending inserts in the main context")

		// Node 111 migrated with its user and config; node 222 kept, not duplicated.
		let nodes = try context.fetch(FetchDescriptor<NodeInfoEntity>())
		XCTAssertEqual(nodes.count, 2, "expected legacy node 111 + live node 222, no duplicates")
		let node111 = try XCTUnwrap(nodes.first(where: { $0.num == 111 }))
		XCTAssertEqual(node111.bleName, "legacy-111")
		XCTAssertEqual(node111.user?.longName, "Legacy User 111")
		XCTAssertTrue(node111.favorite, "favorites must survive the import")
		XCTAssertTrue(node111.ignored)
		XCTAssertEqual(node111.hopsAway, 2)
		// Fields Pangea relies on: keys (DM gate, profile sync), lastMessage (Chats lists a
		// DM only while it is set), mute.
		let user111 = try XCTUnwrap(node111.user)
		XCTAssertEqual(user111.publicKey, Data(repeating: 7, count: 32))
		XCTAssertTrue(user111.pkiEncrypted)
		XCTAssertFalse(user111.keyMatch)
		XCTAssertTrue(user111.mute)
		XCTAssertNotNil(user111.lastMessage)
		XCTAssertEqual(user111.role, 2)
		XCTAssertEqual(node111.deviceConfig?.role, 5, "legacy config should migrate for a legacy-only node")
		let node222 = try XCTUnwrap(nodes.first(where: { $0.num == 222 }))
		XCTAssertEqual(node222.bleName, "live-222", "live node must not be overwritten by the legacy row")
		XCTAssertEqual(node222.user?.longName, "Live User 222", "live node must keep its fresher user")
		XCTAssertEqual(node222.deviceConfig?.role, 1, "live node must keep its fresher config")

		// Users deduped by num.
		let users = try context.fetch(FetchDescriptor<UserEntity>())
		XCTAssertEqual(users.filter { $0.num == 222 }.count, 1, "user 222 must not be duplicated")

		// Message 1001 fills the gap; 1002 is not duplicated and keeps the live payload.
		let messages = try context.fetch(FetchDescriptor<MessageEntity>())
		XCTAssertEqual(messages.count, 2)
		let message1001 = try XCTUnwrap(messages.first(where: { $0.messageId == 1001 }))
		XCTAssertEqual(message1001.messagePayload, "legacy hello")
		XCTAssertTrue(message1001.read, "read state must survive, or every old message shows as unread")
		XCTAssertTrue(message1001.realACK)
		XCTAssertTrue(message1001.pkiEncrypted)
		XCTAssertEqual(message1001.portNum, 1)
		XCTAssertEqual(message1001.toUser?.num, 222, "DM recipient must be wired")
		let dupes = messages.filter { $0.messageId == 1002 }
		XCTAssertEqual(dupes.count, 1)
		XCTAssertEqual(dupes.first?.messagePayload, "live copy")

		// MyInfo + its channel migrate (they only existed in the legacy store).
		let infos = try context.fetch(FetchDescriptor<MyInfoEntity>())
		XCTAssertEqual(infos.count, 1)
		XCTAssertEqual(infos.first?.myNodeNum, 111)
		XCTAssertEqual(infos.first?.peripheralId, "PERIPHERAL-111", "isMyRadio matches on peripheralId")
		let channels = try context.fetch(FetchDescriptor<ChannelEntity>())
		XCTAssertEqual(channels.count, 1)
		XCTAssertEqual(channels.first?.name, "LegacyChan")
		XCTAssertEqual(channels.first?.mute, true)
		XCTAssertEqual(channels.first?.positionPrecision, 13)
		XCTAssertTrue(channels.first?.myInfoChannel === infos.first)

		// The legacy store is retired so the migration never runs again.
		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(in: searchDirectories), "legacy store should be renamed after a successful migration")
		XCTAssertTrue(FileManager.default.fileExists(atPath: backupStoreURL.path), "renamed backup store should exist")

		// A second launch finds nothing to import and does not duplicate anything.
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))
		try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageEntity>()), 2)
	}

	// MARK: - Off the main thread

	/// The app runs the import on a background thread (LegacyStoreImport), so it must not need
	/// the main actor: this compiles only while `migrate` isn't main-actor bound, and runs it
	/// from a detached task end to end.
	@MainActor
	func testMigrationRunsOffTheMainThread() async throws {
		try buildLegacyStore(at: originalStoreURL)
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationDetachedTest", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)
		let directories = searchDirectories

		let ranOnMainThread = try await Task.detached {
			try CoreDataMigrationService.migrate(into: container, searchDirectories: directories)
			return Self.onMainThread()
		}.value

		XCTAssertFalse(ranOnMainThread)
		let context = container.mainContext
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<NodeInfoEntity>()), 2)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageEntity>()), 2)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChannelEntity>()), 1)
		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))
		XCTAssertTrue(FileManager.default.fileExists(atPath: backupStoreURL.path))
	}

	private nonisolated static func onMainThread() -> Bool { Thread.isMainThread }

	// MARK: - Store file edge cases

	/// A journal already sitting under the new name would be paired with this store; the
	/// store is left exactly where it is instead.
	func testPrepareLeavesStoreWhenAJournalAlreadyHasTheNewName() throws {
		try buildLegacyStore(at: originalStoreURL)
		let strayWAL = URL(fileURLWithPath: legacyStoreURL.path + "-wal")
		try Data(repeating: 1, count: 64).write(to: strayWAL)

		CoreDataMigrationService.prepareForMigration(in: searchDirectories)

		XCTAssertTrue(FileManager.default.fileExists(atPath: originalStoreURL.path), "the store must stay under its own name")
		XCTAssertFalse(FileManager.default.fileExists(atPath: legacyStoreURL.path))
		XCTAssertEqual(try Data(contentsOf: strayWAL).count, 64, "the stray journal is not touched")
		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))
	}

	/// An empty leftover under the new name carries nothing, so it doesn't hold the rename up.
	func testPrepareClearsAnEmptyLeftoverJournal() throws {
		try buildLegacyStore(at: originalStoreURL)
		let emptyWAL = URL(fileURLWithPath: legacyStoreURL.path + "-wal")
		try Data().write(to: emptyWAL)

		CoreDataMigrationService.prepareForMigration(in: searchDirectories)

		XCTAssertFalse(FileManager.default.fileExists(atPath: originalStoreURL.path))
		XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))
	}

	/// The same store in both search folders is imported once: positions and readings would
	/// otherwise double on the next launch. The other copy is kept as a backup.
	@MainActor
	func testAStoreInBothFoldersIsImportedOnce() throws {
		try buildLegacyStore(at: originalStoreURL)
		let flatStore = applicationSupportURL.appendingPathComponent("Meshtastic.sqlite")
		try buildLegacyStore(at: flatStore)
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationBothFolders", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)

		try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)

		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(in: searchDirectories), "no copy is left to import next launch")
		XCTAssertTrue(FileManager.default.fileExists(atPath: applicationSupportURL.appendingPathComponent("Meshtastic-coredata-backup.sqlite").path))
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<MessageEntity>()), 2)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<NodeInfoEntity>()), 2)
	}

	/// Two legacy users with one num become one; the row with a node and a key is the one
	/// kept, whichever comes first, and the other row's messages point at it. A direct message
	/// with no sender belongs to no chat, so it comes in read rather than holding the badge up.
	@MainActor
	func testDuplicateUsersKeepTheLinkedRowAndSenderlessDirectMessagesAreRead() throws {
		try buildLegacyStore(at: originalStoreURL) { insert in
			let node = insert("NodeInfoEntity", ["num": Int64(333), "lastHeard": Date()])
			let stale = insert("UserEntity", ["num": Int64(333), "longName": "Stale 333", "shortName": "S333", "hwModel": "TBEAM", "userId": "!0000014d"])
			let real = insert("UserEntity", ["num": Int64(333), "longName": "Real 333", "shortName": "R333", "hwModel": "TBEAM", "userId": "!0000014d", "publicKey": Data(repeating: 3, count: 32)])
			real.setValue(node, forKey: "userNode")
			let fromStale = insert("MessageEntity", ["messageId": Int64(3001), "messagePayload": "hi", "messageTimestamp": Int32(1), "receivedACK": false])
			fromStale.setValue(stale, forKey: "fromUser")
			let noSender = insert("MessageEntity", ["messageId": Int64(3002), "messagePayload": "lost", "messageTimestamp": Int32(1), "read": false, "receivedACK": false])
			noSender.setValue(real, forKey: "toUser")
		}
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationDuplicates", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)

		try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)

		let context = container.mainContext
		let users = try context.fetch(FetchDescriptor<UserEntity>(predicate: #Predicate { $0.num == 333 }))
		XCTAssertEqual(users.count, 1)
		XCTAssertEqual(users.first?.longName, "Real 333")
		XCTAssertEqual(users.first?.userNode?.num, 333)
		XCTAssertEqual(users.first?.publicKey, Data(repeating: 3, count: 32))
		let messages = try context.fetch(FetchDescriptor<MessageEntity>())
		XCTAssertEqual(messages.first(where: { $0.messageId == 3001 })?.fromUser?.num, 333)
		let noSender = try XCTUnwrap(messages.first(where: { $0.messageId == 3002 }))
		XCTAssertNil(noSender.fromUser)
		XCTAssertTrue(noSender.read)
	}

	// MARK: - All-or-nothing with chunked saves

	/// Into an empty store the import saves a chunk at a time (bounded memory). A failure
	/// part-way takes the saved chunks out again: the store is as empty as it started, and the
	/// legacy store is kept for the next attempt, which then imports everything once.
	@MainActor
	func testAFailurePartWayLeavesTheStoreEmpty() throws {
		try buildLegacyStore(at: originalStoreURL)
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationPartWay", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)
		let context = container.mainContext

		CoreDataMigrationService.failAfterSavedChunks = 2
		defer { CoreDataMigrationService.failAfterSavedChunks = nil }
		XCTAssertThrowsError(try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories))

		XCTAssertEqual(try context.fetchCount(FetchDescriptor<NodeInfoEntity>()), 0, "saved chunks must be taken out again")
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserEntity>()), 0)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageEntity>()), 0)
		XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))
		XCTAssertFalse(FileManager.default.fileExists(atPath: CoreDataMigrationService.importMarker(forLegacy: legacyStoreURL).path))

		CoreDataMigrationService.failAfterSavedChunks = nil
		try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<NodeInfoEntity>()), 2)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageEntity>()), 2)
		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))
	}

	/// A crash part-way leaves the marker and some saved rows. The next attempt empties the
	/// store first, so nothing is doubled and nothing half-done is kept as if it were live.
	@MainActor
	func testAnInterruptedImportIsEmptiedBeforeTheRetry() throws {
		try buildLegacyStore(at: originalStoreURL)
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationInterrupted", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)
		let context = container.mainContext
		// What the interrupted attempt had saved.
		let node = NodeInfoEntity()
		node.num = 111
		context.insert(node)
		let position = PositionEntity()
		context.insert(position)
		position.nodePosition = node
		let message = MessageEntity()
		message.messageId = 1001
		message.messagePayload = "half imported"
		context.insert(message)
		try context.save()
		try Data().write(to: CoreDataMigrationService.importMarker(forLegacy: legacyStoreURL))

		try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)

		XCTAssertEqual(try context.fetchCount(FetchDescriptor<PositionEntity>()), 0, "the half import's rows go")
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<NodeInfoEntity>()), 2)
		let messages = try ModelContext(container).fetch(FetchDescriptor<MessageEntity>())
		XCTAssertEqual(messages.count, 2)
		XCTAssertEqual(messages.first(where: { $0.messageId == 1001 })?.messagePayload, "legacy hello")
		XCTAssertFalse(FileManager.default.fileExists(atPath: CoreDataMigrationService.importMarker(forLegacy: legacyStoreURL).path))
	}

	/// When the saved chunks can't be taken out again (on a full disk), the store holds part of
	/// an import. The marker stays, so the next launch empties it before importing, and the
	/// failure says so (`storeNotEmptied`), so this session keeps the store closed.
	@MainActor
	func testAFailedCleanupKeepsTheMarker() throws {
		try buildLegacyStore(at: originalStoreURL)
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationCleanupFails", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)
		let marker = CoreDataMigrationService.importMarker(forLegacy: legacyStoreURL)

		CoreDataMigrationService.failAfterSavedChunks = 2
		CoreDataMigrationService.failEmptyStore = true
		defer {
			CoreDataMigrationService.failAfterSavedChunks = nil
			CoreDataMigrationService.failEmptyStore = false
		}
		XCTAssertThrowsError(try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)) { error in
			guard case MigrationError.storeNotEmptied = error else {
				return XCTFail("expected storeNotEmptied, got \(error)")
			}
		}
		XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the marker stays while the store holds part of an import")
		XCTAssertGreaterThan(try ModelContext(container).fetchCount(FetchDescriptor<NodeInfoEntity>()), 0)

		// The next launch, with space: emptied first, then imported once.
		CoreDataMigrationService.failAfterSavedChunks = nil
		CoreDataMigrationService.failEmptyStore = false
		try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)
		let context = ModelContext(container)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<NodeInfoEntity>()), 2)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserEntity>()), 2)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageEntity>()), 2)
		XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
	}

	/// A batch delete on a full disk can return normally and leave every row. The store is
	/// read back, so a cleanup that silently left rows is treated as failed: the marker stays.
	@MainActor
	func testACleanupThatSilentlyLeavesRowsIsNotTrusted() throws {
		try buildLegacyStore(at: originalStoreURL)
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationCleanupSilent", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)
		let marker = CoreDataMigrationService.importMarker(forLegacy: legacyStoreURL)

		CoreDataMigrationService.failAfterSavedChunks = 2
		CoreDataMigrationService.emptyStoreLeavesType = UserEntity.self
		defer {
			CoreDataMigrationService.failAfterSavedChunks = nil
			CoreDataMigrationService.emptyStoreLeavesType = nil
		}
		XCTAssertThrowsError(try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)) { error in
			guard case MigrationError.storeNotEmptied = error else {
				return XCTFail("expected storeNotEmptied, got \(error)")
			}
		}
		XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
		XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<UserEntity>()), 2, "the rows the cleanup left")
		XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(in: searchDirectories))
	}

	/// A failure after positions were saved, with plenty of space: the cleanup takes nodes and
	/// their positions out (no "mandatory OTO nullify inverse" on PositionEntity/nodePosition),
	/// and the store is checked empty before the marker goes.
	@MainActor
	func testAFailureAfterPositionsLeavesTheStoreEmpty() throws {
		try buildLegacyStore(at: originalStoreURL) { insert in
			let node = insert("NodeInfoEntity", ["num": Int64(444), "lastHeard": Date()])
			for index in 0..<3 {
				let position = insert("PositionEntity", ["latitudeI": Int32(index + 1), "time": Date(timeIntervalSinceNow: Double(-index))])
				position.setValue(node, forKey: "nodePosition")
			}
		}
		CoreDataMigrationService.prepareForMigration(in: searchDirectories)
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("MigrationLateFailure", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)

		// Saves: nodes, users, my info, channels, positions; the fifth is followed by the throw.
		CoreDataMigrationService.failAfterSavedChunks = 5
		defer { CoreDataMigrationService.failAfterSavedChunks = nil }
		XCTAssertThrowsError(try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)) { error in
			if case MigrationError.storeNotEmptied = error {
				XCTFail("the cleanup must succeed with space to spare")
			}
		}
		let context = ModelContext(container)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<PositionEntity>()), 0)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<NodeInfoEntity>()), 0)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChannelEntity>()), 0)
		XCTAssertFalse(FileManager.default.fileExists(atPath: CoreDataMigrationService.importMarker(forLegacy: legacyStoreURL).path))

		CoreDataMigrationService.failAfterSavedChunks = nil
		try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)
		XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PositionEntity>()), 3)
	}

	// MARK: - Legacy store construction

	/// Builds a real V58 Core Data store at `url` using the bundled model, exactly as a
	/// pre-SwiftData install would have left it.
	private func buildLegacyStore(at url: URL, extra: ((_ insert: (String, [String: Any]) -> NSManagedObject) -> Void)? = nil) throws {
		try Self.makeLegacyStore(at: url, extra: extra)
	}

	/// The same store, for tests outside this class.
	static func makeLegacyStore(at url: URL, extra: ((_ insert: (String, [String: Any]) -> NSManagedObject) -> Void)? = nil) throws {
		let momdURL = try XCTUnwrap(Bundle.main.url(forResource: "Meshtastic", withExtension: "momd"))
		let modelURL = momdURL.appendingPathComponent("MeshtasticDataModelV 58.mom")
		let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))

		let container = NSPersistentContainer(name: "Meshtastic", managedObjectModel: model)
		let description = NSPersistentStoreDescription(url: url)
		description.shouldAddStoreAsynchronously = false
		container.persistentStoreDescriptions = [description]
		var loadError: Error?
		container.loadPersistentStores { _, error in loadError = error }
		if let loadError { throw loadError }

		let ctx = container.viewContext

		func insert(_ entity: String, _ values: [String: Any]) -> NSManagedObject {
			let obj = NSEntityDescription.insertNewObject(forEntityName: entity, into: ctx)
			for (key, value) in values { obj.setValue(value, forKey: key) }
			return obj
		}

		let node111 = insert("NodeInfoEntity", [
			"num": Int64(111), "bleName": "legacy-111", "lastHeard": Date(),
			"favorite": true, "ignored": true, "hopsAway": Int32(2)
		])
		let node222 = insert("NodeInfoEntity", ["num": Int64(222), "bleName": "legacy-222", "lastHeard": Date()])

		let user111 = insert("UserEntity", [
			"num": Int64(111), "longName": "Legacy User 111", "shortName": "L111",
			"hwModel": "TBEAM", "userId": "!0000006f",
			"publicKey": Data(repeating: 7, count: 32), "pkiEncrypted": true, "keyMatch": false,
			"mute": true, "lastMessage": Date(), "role": Int32(2)
		])
		user111.setValue(node111, forKey: "userNode")
		let user222 = insert("UserEntity", [
			"num": Int64(222), "longName": "Legacy User 222", "shortName": "L222",
			"hwModel": "TBEAM", "userId": "!000000de"
		])
		user222.setValue(node222, forKey: "userNode")

		let myInfo = insert("MyInfoEntity", ["myNodeNum": Int64(111), "peripheralId": "PERIPHERAL-111"])
		myInfo.setValue(node111, forKey: "myInfoNode")

		let channel = insert("ChannelEntity", [
			"index": Int32(0), "name": "LegacyChan", "role": Int32(1),
			"mute": true, "positionPrecision": Int32(13)
		])
		channel.setValue(myInfo, forKey: "myInfoChannel")

		let message1001 = insert("MessageEntity", [
			"messageId": Int64(1001), "messagePayload": "legacy hello",
			"messageTimestamp": Int32(Date().timeIntervalSince1970), "receivedACK": true,
			"read": true, "realACK": true, "pkiEncrypted": true, "portNum": Int32(1)
		])
		message1001.setValue(user111, forKey: "fromUser")
		message1001.setValue(user222, forKey: "toUser")
		let message1002 = insert("MessageEntity", [
			"messageId": Int64(1002), "messagePayload": "legacy copy of 1002",
			"messageTimestamp": Int32(Date().timeIntervalSince1970), "receivedACK": false
		])
		message1002.setValue(user222, forKey: "fromUser")

		// Configs: one on the legacy-only node (should migrate) and one on the node the
		// live store also has (must be skipped in favor of the live config).
		let config111 = insert("DeviceConfigEntity", ["role": Int32(5)])
		config111.setValue(node111, forKey: "deviceConfigNode")
		let config222 = insert("DeviceConfigEntity", ["role": Int32(9)])
		config222.setValue(node222, forKey: "deviceConfigNode")

		extra?(insert)
		try ctx.save()

		// Detach so the migration's own container gets exclusive access.
		for store in container.persistentStoreCoordinator.persistentStores {
			try container.persistentStoreCoordinator.remove(store)
		}
	}
}
