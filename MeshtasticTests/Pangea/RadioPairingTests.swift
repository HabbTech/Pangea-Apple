//
//  RadioPairingTests.swift
//  MeshtasticTests
//

import CoreData
import Foundation
import Testing
import MeshtasticProtobufs
import SwiftData
import UIKit
@testable import Meshtastic

/// Stands in for a live radio link; nothing is sent anywhere.
private actor StubConnection: Connection {
	let type: TransportType = .ble
	var isConnected: Bool { true }
	func send(_ data: ToRadio) async throws {}
	func connect() async throws -> AsyncStream<ConnectionEvent> { AsyncStream { $0.finish() } }
	func disconnect(withError: Error?, shouldReconnect: Bool) async throws {}
	func drainPendingPackets() async throws {}
	func startDrainPendingPackets() throws {}
	func appDidEnterBackground() {}
	func appDidBecomeActive() {}
}

/// A link whose close never comes back (a radio gone quiet mid-teardown).
private actor HangingConnection: Connection {
	let type: TransportType = .ble
	var isConnected: Bool { true }
	func send(_ data: ToRadio) async throws {}
	func connect() async throws -> AsyncStream<ConnectionEvent> { AsyncStream { $0.finish() } }
	func disconnect(withError: Error?, shouldReconnect: Bool) async throws {
		try await Task.sleep(for: .milliseconds(1500))
	}
	func drainPendingPackets() async throws {}
	func startDrainPendingPackets() throws {}
	func appDidEnterBackground() {}
	func appDidBecomeActive() {}
}

@Suite("Scanning for radios", .serialized)
@MainActor
struct DiscoveryStateTests {

	private let device = Device(id: UUID(), name: "Test Radio", transportType: .ble, identifier: "BLE-TEST")

	/// No transports, so starting discovery never touches Bluetooth or the network.
	private func manager() -> AccessoryManager {
		let manager = AccessoryManager(transports: [])
		// The init takes over the shared MQTT delegate; hand it back to the app's manager.
		MqttClientProxyManager.shared.delegate = AccessoryManager.shared
		return manager
	}

	@Test func scanningWhileConnectedKeepsTheRadioConnected() {
		let manager = manager()
		manager.activeConnection = (device: device, connection: StubConnection())
		manager.updateState(.subscribed)

		// What "Pair a Different Radio" and finishing setup both do.
		manager.startDiscovery()

		#expect(manager.state == .subscribed)
		#expect(manager.isConnected)
		#expect(manager.discoveryTask != nil)
		manager.stopDiscovery()
	}

	@Test func scanningWhileConnectingLeavesTheConnectionAlone() {
		let manager = manager()
		manager.updateState(.connecting)
		manager.startDiscovery()
		#expect(manager.state == .connecting)
		#expect(manager.isConnecting)
		manager.stopDiscovery()
	}

	@Test func scanningWithNoRadioShowsSearching() {
		let manager = manager()
		manager.updateState(.idle)
		manager.startDiscovery()
		#expect(manager.state == .discovering)
		#expect(!manager.isConnected)
		manager.stopDiscovery()
	}
}

/// A transport that counts connects and hands out links that never finish the config
/// handshake, so an attempt stays in flight until it's cancelled.
private final class FakeTransport: Transport, @unchecked Sendable {
	let type: TransportType = .ble
	var status: TransportStatus { .ready }
	let latency: Duration
	private let lock = NSLock()
	private var connectCount = 0
	private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
	var connects: Int { lock.withLock { connectCount } }

	init(latency: Duration) { self.latency = latency }

	func discoverDevices() async -> AsyncStream<DiscoveryEvent> {
		AsyncStream { continuation in self.lock.withLock { self.continuation = continuation } }
	}

	func yield(_ event: DiscoveryEvent) { lock.withLock { continuation }?.yield(event) }

	func connect(to device: Device) async throws -> any Connection {
		lock.withLock { connectCount += 1 }
		try? await Task.sleep(for: latency)
		return FakeConnection()
	}

	var requiresPeriodicHeartbeat: Bool { false }
	var supportsManualConnection: Bool { false }
	func device(forManualConnection: String) -> Device? { nil }
	func manuallyConnect(toDevice: Device) async throws {}
}

/// A link that closes when asked, the way a real one reports it.
private actor FakeConnection: Connection {
	let type: TransportType = .ble
	var isConnected: Bool { true }
	private var continuation: AsyncStream<ConnectionEvent>.Continuation?
	func send(_ data: ToRadio) async throws {}
	func connect() async throws -> AsyncStream<ConnectionEvent> {
		AsyncStream { continuation in self.continuation = continuation }
	}
	func disconnect(withError error: Error?, shouldReconnect: Bool) async throws {
		continuation?.yield(.disconnected(shouldReconnect: shouldReconnect))
		continuation?.finish()
		continuation = nil
	}
	func drainPendingPackets() async throws {}
	func startDrainPendingPackets() throws {}
	func appDidEnterBackground() {}
	func appDidBecomeActive() {}
}

@Suite("Connecting and disconnecting", .serialized)
@MainActor
struct ConnectionRaceTests {

	private let device = Device(id: UUID(), name: "Test Radio", transportType: .ble, identifier: "BLE-TEST")

	private func manager(_ transport: FakeTransport? = nil) -> AccessoryManager {
		let manager = AccessoryManager(transports: transport.map { [$0] } ?? [])
		MqttClientProxyManager.shared.delegate = AccessoryManager.shared
		return manager
	}

	/// Pairing settings are put back afterwards, and nothing stale is purged from the store.
	private func withDefaults(_ body: () async -> Void) async {
		let savedId = UserDefaults.preferredPeripheralId
		let savedNum = UserDefaults.preferredPeripheralNum
		let savedPurge = UserDefaults.purgeStaleNodeDays
		UserDefaults.purgeStaleNodeDays = 0
		await body()
		UserDefaults.preferredPeripheralId = savedId
		UserDefaults.preferredPeripheralNum = savedNum
		UserDefaults.purgeStaleNodeDays = savedPurge
	}

	private func teardown(_ manager: AccessoryManager) async {
		try? await manager.disconnect()
		for _ in 0..<60 where manager.connectionStepper != nil || manager.activeConnection != nil || manager.closingConnections > 0 {
			try? await Task.sleep(for: .milliseconds(50))
		}
		manager.stopDiscovery()
	}

	/// The radio was lost and auto-connect is armed; the user taps Reconnect, then the radio
	/// turns up. Whoever gets there first, there's one attempt, and Reconnect reports it.
	@Test(arguments: [50, 300, 1500])
	func reconnectAndAutoConnectMakeOneAttempt(latencyMs: Int) async {
		await withDefaults {
			UserDefaults.preferredPeripheralId = device.id.uuidString
			let transport = FakeTransport(latency: .milliseconds(latencyMs))
			let manager = manager(transport)
			manager.startDiscovery()
			let reconnect = Task { await RadioPairing.reconnect(accessoryManager: manager, timeout: .seconds(4), attemptTimeout: .seconds(8)) }
			try? await Task.sleep(for: .milliseconds(120))
			transport.yield(.deviceFound(device))
			// What discovery does when it hears the preferred radio (the test host doesn't
			// arm it on its own), while Reconnect's own search is about to find it too.
			manager.connectToPreferredDevice(device: device)
			for _ in 0..<100 where manager.activeConnection == nil {
				try? await Task.sleep(for: .milliseconds(50))
			}
			// Room for a second attempt to show up, if anything let one in.
			try? await Task.sleep(for: .milliseconds(800))
			#expect(transport.connects == 1)
			#expect(manager.activeConnection != nil)
			// The radio finishes sending its config.
			manager.updateState(.subscribed)
			#expect(await reconnect.value)
			await teardown(manager)
		}
	}

	@Test func aSecondConnectWhileOneIsStartingIsRefused() async {
		await withDefaults {
			let transport = FakeTransport(latency: .milliseconds(300))
			let manager = manager(transport)
			let first = Task { try? await manager.connect(to: device) }
			try? await Task.sleep(for: .milliseconds(50))
			// Still in its first step: not connected yet, but no longer free either.
			#expect(manager.activeConnection == nil)
			await #expect(throws: (any Error).self) { try await manager.connect(to: device) }
			try? await Task.sleep(for: .milliseconds(500))
			#expect(transport.connects == 1)
			await teardown(manager)
			_ = await first.value
			#expect(manager.connectionStepper == nil)
		}
	}

	@Test func disconnectWaitsUntilTheTeardownIsDone() async {
		await withDefaults {
			let manager = manager(FakeTransport(latency: .milliseconds(10)))
			let link = FakeConnection()
			let events = (try? await link.connect()) ?? AsyncStream(unfolding: { nil })
			manager.activeConnection = (device: device, connection: link)
			manager.connectionEventTask = Task {
				for await event in events { await manager.didReceive(event) }
			}
			manager.updateState(.subscribed)
			#expect(await RadioPairing.disconnect(accessoryManager: manager))
			#expect(manager.activeConnection == nil)
			#expect(manager.closingConnections == 0)
			#expect(!manager.isConnecting)
			await teardown(manager)
		}
	}

	/// Upstream's "Connect to new radio" calls `disconnect()` and connects straight away,
	/// while the old attempt is still being cancelled.
	@Test func disconnectReturnsOnlyOnceAnAttemptHasEnded() async {
		await withDefaults {
			let transport = FakeTransport(latency: .milliseconds(10))
			let manager = manager(transport)
			let first = Task { try? await manager.connect(to: device) }
			// Linked, and waiting for a config that never comes.
			for _ in 0..<100 where manager.activeConnection == nil {
				try? await Task.sleep(for: .milliseconds(20))
			}
			#expect(manager.activeConnection != nil)
			#expect(manager.connectionStepper != nil)
			try? await manager.disconnect()
			#expect(manager.connectionStepper == nil)
			#expect(manager.activeConnection == nil)
			#expect(manager.closingConnections == 0)
			_ = await first.value
			// So connecting at once is let in, not refused as "Already connecting".
			let second = Task { () -> Error? in
				do {
					try await manager.connect(to: device)
					return nil
				} catch {
					return error
				}
			}
			for _ in 0..<100 where transport.connects < 2 {
				try? await Task.sleep(for: .milliseconds(20))
			}
			#expect(transport.connects == 2)
			await teardown(manager)
			#expect(await second.value.map { "\($0)" }?.contains("Already") != true)
		}
	}

	@Test func aDisconnectThatNeverFinishesIsReported() async {
		await withDefaults {
			UserDefaults.preferredPeripheralId = device.id.uuidString
			let manager = manager()
			// This link never answers the request to close.
			manager.activeConnection = (device: device, connection: HangingConnection())
			manager.updateState(.subscribed)
			#expect(!(await RadioPairing.disconnect(accessoryManager: manager, timeout: .milliseconds(300))))
			// Forgetting then changes nothing: still paired, nothing cleared.
			#expect(!(await RadioPairing.forget(accessoryManager: manager, timeout: .milliseconds(300))))
			#expect(UserDefaults.preferredPeripheralId == device.id.uuidString)
			// The close the wait gave up on still finishes: the radio is then disconnected,
			// and still paired. Nothing was forgotten behind the "couldn't disconnect".
			for _ in 0..<200 where !manager.isFullyDisconnected {
				try? await Task.sleep(for: .milliseconds(20))
			}
			#expect(manager.isFullyDisconnected)
			#expect(!manager.isConnected)
			#expect(UserDefaults.preferredPeripheralId == device.id.uuidString)
			manager.activeConnection = nil
		}
	}

	/// An old store's import owns the store until it has saved: a connect waits for it, so
	/// no radio data lands first. Discovery's auto-connect and Reconnect both come through here.
	@Test func aConnectWaitsForTheOldStoreImport() async {
		await withDefaults {
			let transport = FakeTransport(latency: .milliseconds(10))
			let manager = manager(transport)
			let release = ImportRelease()
			LegacyStoreImport.shared.start { await release.wait() }
			#expect(LegacyStoreImport.shared.isRunning)
			let attempt = Task { try? await manager.connect(to: device) }
			try? await Task.sleep(for: .milliseconds(400))
			#expect(transport.connects == 0, "nothing may connect while the import runs")
			#expect(manager.connectionStepper == nil)

			await release.open()
			await LegacyStoreImport.shared.waitUntilFinished()
			#expect(!LegacyStoreImport.shared.isRunning)
			for _ in 0..<100 where transport.connects == 0 {
				try? await Task.sleep(for: .milliseconds(20))
			}
			#expect(transport.connects == 1)
			await teardown(manager)
			_ = await attempt.value
		}
	}

	/// An import whose rows couldn't be taken out again (a full disk) leaves part of an import
	/// in the store, which the next launch empties. The store stays closed for the session:
	/// the "Not enough space" placeholder stays up and nothing connects, so no chat is saved
	/// only to be emptied with it. The marker stays for the next launch.
	@Test func anImportThatRanOutOfSpaceKeepsTheStoreClosed() async throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("ImportOutOfSpace-\(UUID().uuidString)", isDirectory: true)
		let folder = base.appendingPathComponent("Pangea", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: base) }
		try CoreDataMigrationServiceTests.makeLegacyStore(at: folder.appendingPathComponent("Meshtastic.sqlite"))
		CoreDataMigrationService.prepareForMigration(in: [folder])
		let legacy = try #require(CoreDataMigrationService.legacyStoreURL(in: [folder]))
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("ImportOutOfSpace", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)

		CoreDataMigrationService.failAfterSavedChunks = 2
		CoreDataMigrationService.failEmptyStore = true
		LegacyStoreImport.shared.start(into: container, searchDirectories: [folder])
		#expect(LegacyStoreImport.shared.holdsStore)
		await LegacyStoreImport.shared.waitUntilFinished()
		CoreDataMigrationService.failAfterSavedChunks = nil
		CoreDataMigrationService.failEmptyStore = false
		defer { LegacyStoreImport.shared.resetForTesting() }

		#expect(LegacyStoreImport.shared.needsFreeSpace)
		#expect(LegacyStoreImport.shared.holdsStore, "the placeholder stays up")
		#expect(FileManager.default.fileExists(atPath: CoreDataMigrationService.importMarker(forLegacy: legacy).path))
		await withDefaults {
			let transport = FakeTransport(latency: .milliseconds(10))
			let manager = manager(transport)
			var refused = false
			do {
				try await manager.connect(to: device)
			} catch {
				refused = true
			}
			#expect(refused)
			#expect(transport.connects == 0, "nothing may connect into a store the next launch empties")
			#expect(manager.connectionStepper == nil)
			#expect(manager.activeConnection == nil)
		}
	}

	@Test func waitingForARadioToBeHeardAgain() async {
		let manager = manager()
		#expect(await RadioPairing.waitForDevice(id: device.id, accessoryManager: manager, timeout: .milliseconds(300)) == nil)
		let device = device
		Task {
			try? await Task.sleep(for: .milliseconds(200))
			manager.devices.append(device)
		}
		#expect(await RadioPairing.waitForDevice(id: device.id, accessoryManager: manager, timeout: .seconds(3))?.id == device.id)
	}
}

/// Holds a fake import open until the test lets it finish.
private actor ImportRelease {
	private var isOpen = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !isOpen else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func open() {
		isOpen = true
		waiters.forEach { $0.resume() }
		waiters.removeAll()
	}
}

/// Forget and Pair a Different Radio clear the old radio's data on the one SwiftData
/// container. Replacing the container leaves SwiftUI's observer of the old one alive, and the
/// next save traps in it (upstream's node switch documents this), so it may only happen on
/// the escalation, and only once.
@Suite("Clearing a radio's data", .serialized)
@MainActor
struct ClearRadioDataTests {

	@Test func aFailedClearReplacesTheContainerExactlyOnce() async {
		let before = PersistenceController.shared.containerGeneration
		await RadioPairing.clearRadioData(clearStore: { false })
		#expect(PersistenceController.shared.containerGeneration == before + 1)
		// Rebound to the new container, not replaced a second time.
		#expect(AccessoryManager.shared.context === PersistenceController.shared.context)
		#expect(AccessoryManager.shared.appState?.isDatabaseResetting != true)
	}

	/// Settings → Clear App Data clears in place too: the same container, empty afterwards, and
	/// the device catalogue refresh that follows saves into it.
	@Test func clearingAppDataKeepsTheContainer() async throws {
		let container = PersistenceController.shared.container
		let seed = ModelContext(container)
		let node = NodeInfoEntity()
		node.num = 0x7E57_0101
		seed.insert(node)
		let message = MessageEntity()
		message.messageId = 0x7E57_0102
		message.messagePayload = "everything goes"
		seed.insert(message)
		let channel = ChannelEntity()
		channel.index = 2
		seed.insert(channel)
		let route = RouteEntity()
		route.name = "Walk"
		seed.insert(route)
		try seed.save()
		let generation = PersistenceController.shared.containerGeneration
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EraseKeepsContainer-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let suite = "pangea.tests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		let scratch = EraseScratch()
		defer { scratch.remove() }
		await erase(
			scratch,
			profiles: ProfileStore(folder: folder),
			invites: GroupInviteStore(defaults: defaults, key: "invites"),
			defaults: defaults
		)

		#expect(PersistenceController.shared.containerGeneration == generation, "the container must not be replaced")
		#expect(PersistenceController.shared.container === container)
		let check = ModelContext(container)
		#expect(try check.fetchCount(FetchDescriptor<NodeInfoEntity>()) == 0)
		#expect(try check.fetchCount(FetchDescriptor<MessageEntity>()) == 0)
		#expect(try check.fetchCount(FetchDescriptor<ChannelEntity>()) == 0)
		#expect(try check.fetchCount(FetchDescriptor<RouteEntity>()) == 0)
		#expect(AccessoryManager.shared.appState?.isDatabaseResetting != true)

		// What Settings does next: the catalogue refresh, then the app saves as usual.
		try? await MeshtasticAPI.shared.refreshBundledDevicesData()
		let after = container.mainContext
		let fresh = NodeInfoEntity()
		fresh.num = 0x7E57_0103
		after.insert(fresh)
		try after.save()
		#expect(PersistenceController.shared.containerGeneration == generation)
		#expect(try ModelContext(container).fetchCount(FetchDescriptor<NodeInfoEntity>()) == 1)
		after.delete(fresh)
		try after.save()
	}

	/// A second clear while one is still running waits for it, and the gate stays up until the
	/// last has finished; each bumps `databaseResetID` after its own store work.
	@Test func overlappingClearsKeepTheGateUpUntilTheLastEnds() async {
		guard let appState = AccessoryManager.shared.appState else { return }
		var timeline: [String] = []
		func mark(_ event: String) {
			timeline.append("\(event) gate=\(appState.isDatabaseResetting ? "up" : "down")")
		}
		let first = Task { @MainActor in
			await RadioPairing.clearRadioData(clearStore: {
				mark("A starts")
				try? await Task.sleep(for: .milliseconds(1_000))
				mark("A ends")
				return true
			})
			mark("A returned")
		}
		try? await Task.sleep(for: .milliseconds(400))
		let resetIDDuringA = appState.databaseResetID
		let second = Task { @MainActor in
			await RadioPairing.clearRadioData(clearStore: {
				mark("B starts")
				#expect(appState.databaseResetID != resetIDDuringA, "A bumped it after its own store work")
				try? await Task.sleep(for: .milliseconds(600))
				mark("B ends")
				return true
			})
			mark("B returned")
		}
		await first.value
		await second.value
		#expect(timeline == [
			"A starts gate=up", "A ends gate=up", "B starts gate=up",
			"A returned gate=up", "B ends gate=up", "B returned gate=down"
		] || timeline == [
			"A starts gate=up", "A ends gate=up", "A returned gate=up",
			"B starts gate=up", "B ends gate=up", "B returned gate=down"
		], "\(timeline)")
		#expect(!appState.isDatabaseResetting)
	}

	@Test func pairingADifferentRadioClearsInPlace() async throws {
		let container = PersistenceController.shared.container
		let seed = ModelContext(container)
		let node = NodeInfoEntity()
		node.num = 0x7E57_0001
		seed.insert(node)
		let user = UserEntity()
		user.num = 0x7E57_0001
		seed.insert(user)
		user.userNode = node
		let myInfo = MyInfoEntity()
		myInfo.myNodeNum = 0x7E57_0001
		seed.insert(myInfo)
		let channel = ChannelEntity()
		channel.index = 1
		channel.role = 2
		seed.insert(channel)
		myInfo.channels = [channel]
		let message = MessageEntity()
		message.messageId = 0x7E57_0002
		message.messagePayload = "old radio"
		seed.insert(message)
		message.fromUser = user
		try seed.save()
		let generation = PersistenceController.shared.containerGeneration
		let resetID = AccessoryManager.shared.appState?.databaseResetID

		await RadioPairing.clearRadioData()

		#expect(PersistenceController.shared.containerGeneration == generation, "the container must not be replaced")
		#expect(PersistenceController.shared.container === container)
		let check = ModelContext(container)
		#expect(try check.fetchCount(FetchDescriptor<NodeInfoEntity>()) == 0)
		#expect(try check.fetchCount(FetchDescriptor<UserEntity>()) == 0)
		#expect(try check.fetchCount(FetchDescriptor<MessageEntity>()) == 0)
		#expect(try check.fetchCount(FetchDescriptor<ChannelEntity>()) == 0)
		#expect(try check.fetchCount(FetchDescriptor<MyInfoEntity>()) == 0)
		if let appState = AccessoryManager.shared.appState {
			#expect(appState.databaseResetID != resetID, "lists remount to fetch again")
			#expect(!appState.isDatabaseResetting)
		}
	}

	// MARK: What stays and what goes

	private func temporaryFolder(_ name: String) -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
	}

	/// My profile with a photo, and one saved contact with a nickname, a downloaded photo, and my card sent.
	private func seed(_ profiles: ProfileStore) {
		profiles.updateMe(displayName: "Riley", emoji: "🦊", color: 3, photo: .some(Data([1, 2, 3])))
		profiles.receivedCard(ProfileCard(displayName: "Sam", emoji: "", color: 0, photoVersion: 9), from: 5, channel: nil)
		profiles.savePhoto(Data([4, 5, 6]), version: 9, for: 5)
		profiles.setNickname("Sammy", for: 5)
		profiles.setContact(true, for: 5, radioName: "Sam's Radio")
		profiles.markCardSent(7, to: 5)
	}

	private func fileNames(in folder: URL) -> Set<String> {
		Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []))
	}

	/// Clear App Data starts Pangea over: my profile and photo, everyone's cards, nicknames, saved
	/// contacts and their photos, waiting invites and their kept copies, and the settings Pangea
	/// keeps for itself all go. App settings stay; Reset App Settings is for those.
	@Test func clearingAppDataErasesProfilesContactsAndInvites() async throws {
		let folder = temporaryFolder("EraseProfiles")
		defer { try? FileManager.default.removeItem(at: folder) }
		let profiles = ProfileStore(folder: folder)
		seed(profiles)
		#expect(fileNames(in: folder) == ["profiles.json", "me.jpg", "5.jpg"])
		let suite = "pangea.tests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let invites = GroupInviteStore(defaults: defaults, key: "invites")
		#expect(invites.add(GroupInvite(name: "Trip", psk: Data(repeating: 1, count: 32)), from: 10, notify: false))
		defaults.set(Data([0xFF]), forKey: invites.unreadableKeys[0])
		defaults.set("PERIPHERAL", forKey: UserDefaults.Keys.preferredPeripheralId.rawValue)
		defaults.set(0x7E57, forKey: UserDefaults.Keys.preferredPeripheralNum.rawValue)
		defaults.set(false, forKey: UserDefaults.Keys.firstLaunch.rawValue)
		defaults.set(true, forKey: GroupChats.everyoneNotificationsKey)
		defaults.set(["32343": 2], forKey: RadioAutoConfig.pairingCodeAttemptsKey)
		defaults.set("New Name", forKey: ProfileSync.pendingNameKey)
		defaults.set(true, forKey: ProfileSync.pushWhenBackKey)
		defaults.set(true, forKey: UserDefaults.Keys.expertModeEnabled.rawValue)

		defaults.set(Data("[]".utf8), forKey: UserDefaults.Keys.manualConnections.rawValue)
		let chatIcons = ChatIconStore(defaults: defaults)
		chatIcons.set(ChatIcon(emoji: "🔥", color: 0), for: "everyone")
		let app = ProfileSync.defaults
		ProfileSync.defaults = defaults
		defer { ProfileSync.defaults = app }
		let scratch = EraseScratch()
		defer { scratch.remove() }

		var erasingShown: Bool?
		var radioKeysAtClear: [Any?] = []
		let erased = await erase(scratch, profiles: profiles, invites: invites, defaults: defaults, chatIcons: chatIcons, clearStore: {
			erasingShown = AccessoryManager.shared.appState?.isErasingAppData
			radioKeysAtClear = [
				defaults.object(forKey: UserDefaults.Keys.preferredPeripheralId.rawValue),
				defaults.object(forKey: UserDefaults.Keys.preferredPeripheralNum.rawValue)
			]
			return true
		})

		#expect(erased)
		#expect(radioKeysAtClear.count == 2 && radioKeysAtClear.allSatisfy { $0 == nil }, "the radio is forgotten before the store is cleared, so auto-connect can't bring it back")
		#expect(defaults.object(forKey: ProfileSync.pushWhenBackKey) == nil, "removed, not written back as false")
		#expect(ManualConnectionList.shared.connectionsList.isEmpty)
		#expect(chatIcons.icons.isEmpty)

		if AccessoryManager.shared.appState != nil {
			#expect(erasingShown == true, "the placeholder says Erasing app data")
			#expect(AccessoryManager.shared.appState?.isErasingAppData == false)
		}
		#expect(profiles.me == MyProfile())
		#expect(profiles.myPhotoData == nil)
		#expect(profiles.contacts.isEmpty)
		#expect(profiles.contactNums.isEmpty)
		#expect(profiles.photo(for: 5) == nil)
		#expect(profiles.name(num: 5, radioName: "Sam's Radio") == "Sam's Radio", "no nickname or card left")
		#expect(fileNames(in: folder) == ["profiles.json"], "both photos are gone")
		let reopened = ProfileStore(folder: folder)
		#expect(reopened.me == MyProfile())
		#expect(reopened.contacts.isEmpty)

		#expect(invites.pending.isEmpty)
		#expect(defaults.object(forKey: invites.unreadableKeys[0]) == nil)
		#expect(GroupInviteStore(defaults: defaults, key: "invites").pending.isEmpty)

		for key in RadioPairing.localDefaultsKeys {
			#expect(defaults.object(forKey: key) == nil, "\(key)")
		}
		#expect(defaults.bool(forKey: UserDefaults.Keys.expertModeEnabled.rawValue), "app settings stay")
		chatIcons.set(ChatIcon(emoji: "🐻", color: 1), for: "other")
		#expect(ChatIconStore(defaults: defaults).icons == ["other": ChatIcon(emoji: "🐻", color: 1)], "the next icon change doesn't write the old icons back")
	}

	/// The keys are the ones the app reads, by name: a renamed key would quietly survive an erase.
	@Test func clearingAppDataCoversEveryPangeaSetting() {
		#expect(Set(RadioPairing.localDefaultsKeys) == [
			"preferredPeripheralId", "preferredPeripheralNum", "firstLaunch",
			"pangeaEveryoneNotifications", "pangeaPairingCodeAttempts",
			"pangeaPendingRadioName", "pangeaPushCardWhenBack", "manualConnections",
			"pangeaChatIcons"
		])
	}

	// MARK: Clear App Data, beyond the store

	/// The old chats an upgrade from the Core Data build kept: waiting to be imported, kept as a
	/// backup after the import, older backups under a timestamp, an unfinished import's marker,
	/// and a store never renamed. Both folders the import looks in (Catalyst's
	/// `Application Support/Pangea/` and the flat one). Nothing is left for the next launch to
	/// import, and nothing else in those folders goes.
	@Test func clearingAppDataRemovesTheOldCoreDataChats() async throws {
		let scratch = EraseScratch()
		defer { scratch.remove() }
		let fm = FileManager.default
		let flat = scratch.storeFolders[0], pangea = scratch.storeFolders[1]
		for folder in scratch.storeFolders {
			for name in [
				"Meshtastic-coredata-legacy.sqlite", "Meshtastic-coredata-legacy.sqlite-wal",
				"Meshtastic-coredata-legacy.sqlite-shm", "Meshtastic-coredata-legacy.sqlite.importing",
				"Meshtastic-coredata-backup.sqlite", "Meshtastic-coredata-backup.sqlite-wal",
				"Meshtastic-coredata-backup.sqlite-shm", "Meshtastic-coredata-backup.sqlite.1700000000",
				"Meshtastic-coredata-backup.sqlite.1700000000-wal",
				"Meshtastic.store", "notes.txt"
			] {
				try Data([1]).write(to: folder.appendingPathComponent(name))
			}
		}
		try makeCoreDataStore(at: pangea.appendingPathComponent("Meshtastic.sqlite"))
		#expect(CoreDataMigrationService.legacyStoreExists(in: scratch.storeFolders))
		let suite = "pangea.tests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let profilesFolder = temporaryFolder("EraseOldChats")
		defer { try? fm.removeItem(at: profilesFolder) }

		await erase(scratch, profiles: ProfileStore(folder: profilesFolder),
					invites: GroupInviteStore(defaults: defaults, key: "invites"), defaults: defaults,
					clearStore: { true })

		#expect(fileNames(in: flat) == ["Meshtastic.store", "notes.txt", "Pangea"])
		#expect(fileNames(in: pangea) == ["Meshtastic.store", "notes.txt"])
		#expect(!CoreDataMigrationService.legacyStoreExists(in: scratch.storeFolders))
		// The next launch's rename finds nothing to bring back either.
		CoreDataMigrationService.prepareForMigration(in: scratch.storeFolders)
		#expect(!CoreDataMigrationService.legacyStoreExists(in: scratch.storeFolders))
	}

	/// Every node backup, the ones the index lists or not, and the folder an earlier release kept
	/// them in; private keys saved on this device only. A key synced through iCloud Keychain stays
	/// (deleting it would delete it on the user's other devices), and so does anything else.
	@Test func clearingAppDataRemovesBackupsAndSavedKeys() async throws {
		let scratch = EraseScratch()
		defer { scratch.remove() }
		let fm = FileManager.default
		let unindexed = scratch.backupFolder.appendingPathComponent("123456", isDirectory: true)
		try fm.createDirectory(at: unindexed, withIntermediateDirectories: true)
		try Data([1]).write(to: unindexed.appendingPathComponent("Meshtastic.store"))
		try Data([1]).write(to: scratch.backupFolder.appendingPathComponent("dropped-in.txt"))
		try fm.createDirectory(at: scratch.oldBackupFolder.appendingPathComponent("42"), withIntermediateDirectories: true)
		let helper = KeychainHelper.standard
		let service = scratch.keychainService
		defer {
			for key in ["PrivateKeyNode7", "PrivateKeyNode8", "SomethingElse"] {
				_ = helper.delete(key: key, service: service, synchronizable: false)
				_ = helper.delete(key: key, service: service, synchronizable: true)
			}
		}
		#expect(helper.save(key: "PrivateKeyNode7", value: "a", service: service, synchronizable: false) == errSecSuccess)
		#expect(helper.save(key: "PrivateKeyNode8", value: "b", service: service, synchronizable: true) == errSecSuccess)
		#expect(helper.save(key: "SomethingElse", value: "c", service: service, synchronizable: false) == errSecSuccess)
		let suite = "pangea.tests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let profilesFolder = temporaryFolder("EraseBackups")
		defer { try? fm.removeItem(at: profilesFolder) }

		await erase(scratch, profiles: ProfileStore(folder: profilesFolder),
					invites: GroupInviteStore(defaults: defaults, key: "invites"), defaults: defaults,
					clearStore: { true })

		#expect(fileNames(in: scratch.backupFolder) == ["backup-index.json"])
		#expect(scratch.backups.listBackups().isEmpty)
		#expect(!fm.fileExists(atPath: scratch.oldBackupFolder.path))
		#expect(helper.read(key: "PrivateKeyNode7", service: service, synchronizable: false) == nil, "kept on this device only")
		#expect(helper.read(key: "PrivateKeyNode8", service: service, synchronizable: true) == "b", "synced: it stays")
		#expect(helper.read(key: "SomethingElse", service: service, synchronizable: false) == "c")
	}

	private struct DisconnectFailed: Error {}

	/// The radio wouldn't let go: nothing is erased, and the caller is told so.
	@Test func anEraseWhoseDisconnectFailsErasesNothing() async throws {
		let scratch = EraseScratch()
		defer { scratch.remove() }
		let legacy = scratch.storeFolders[0].appendingPathComponent("Meshtastic-coredata-legacy.sqlite")
		try Data([1]).write(to: legacy)
		let folder = temporaryFolder("EraseFails")
		defer { try? FileManager.default.removeItem(at: folder) }
		let profiles = ProfileStore(folder: folder)
		seed(profiles)
		let suite = "pangea.tests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set("PERIPHERAL", forKey: UserDefaults.Keys.preferredPeripheralId.rawValue)

		var cleared = false
		let erased = await erase(scratch, profiles: profiles,
								 invites: GroupInviteStore(defaults: defaults, key: "invites"), defaults: defaults,
								 disconnect: { throw DisconnectFailed() },
								 clearStore: { cleared = true; return true })

		#expect(!erased)
		#expect(!cleared)
		#expect(profiles.contactNums == [5])
		#expect(defaults.string(forKey: UserDefaults.Keys.preferredPeripheralId.rawValue) == "PERIPHERAL")
		#expect(FileManager.default.fileExists(atPath: legacy.path))
		#expect(AccessoryManager.shared.appState?.isErasingAppData != true)
	}

	/// First launch: onboarding has its own Siri screen, so launch doesn't ask as well.
	@Test func siriIsAskedForAtLaunchOnlyAfterSetup() {
		#expect(!MeshtasticAppDelegate.asksForSiriAtLaunch(firstLaunch: true))
		#expect(MeshtasticAppDelegate.asksForSiriAtLaunch(firstLaunch: false))
	}

	/// Where Clear App Data looks for backups, old stores and saved keys, all in a scratch
	/// folder and a keychain service of its own: nothing of the test host's is touched.
	@MainActor
	private struct EraseScratch {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("EraseScratch-\(UUID().uuidString)", isDirectory: true)
		let keychainService = "pangea.tests.\(UUID().uuidString)"
		var backupFolder: URL { root.appendingPathComponent("Documents/NodeBackups", isDirectory: true) }
		var oldBackupFolder: URL { root.appendingPathComponent("Application Support/NodeBackups", isDirectory: true) }
		/// The flat Application Support folder and Catalyst's `Pangea` one inside it.
		var storeFolders: [URL] {
			let flat = root.appendingPathComponent("Application Support/Store", isDirectory: true)
			return [flat, flat.appendingPathComponent("Pangea", isDirectory: true)]
		}
		let backups: NodeBackupManager

		init() {
			backups = NodeBackupManager(baseURL: root.appendingPathComponent("Documents/NodeBackups", isDirectory: true))
			for folder in storeFolders {
				try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			}
		}

		func remove() {
			try? FileManager.default.removeItem(at: root)
		}
	}

	@discardableResult
	private func erase(
		_ scratch: EraseScratch,
		profiles: ProfileStore,
		invites: GroupInviteStore,
		defaults: UserDefaults,
		chatIcons: ChatIconStore? = nil,
		disconnect: @MainActor () async throws -> Void = {},
		clearStore: @MainActor () async -> Bool = { await MeshPackets.shared.clearDatabase(includeRoutes: true) }
	) async -> Bool {
		await RadioPairing.eraseAppData(
			disconnect: disconnect,
			profiles: profiles,
			invites: invites,
			// A scratch store unless one is passed, so tests leave the app's icons alone.
			chatIcons: chatIcons ?? ChatIconStore(defaults: defaults),
			defaults: defaults,
			backups: scratch.backups,
			oldBackupFolders: [scratch.backupFolder, scratch.oldBackupFolder],
			oldStoreFolders: scratch.storeFolders,
			keychainService: scratch.keychainService,
			clearStore: clearStore
		)
	}

	/// A real (empty) Core Data SQLite store, as the old build left it.
	private func makeCoreDataStore(at url: URL) throws {
		let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
		let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
		try coordinator.remove(store)
	}

	/// Forget and Pair a Different Radio take the radio's chats only. My profile, everyone in
	/// Contacts, nicknames and photos stay, and so do setup and Pangea's settings; only the record
	/// of who has my card goes, since it went through the old radio. A radio switch
	/// (`switchToDevice`) does the same without the store.
	@Test func forgettingARadioKeepsProfileAndContacts() async throws {
		let folder = temporaryFolder("ForgetKeepsProfiles")
		defer { try? FileManager.default.removeItem(at: folder) }
		let profiles = ProfileStore(folder: folder)
		seed(profiles)
		let me = profiles.me
		let standard = UserDefaults.standard
		// (Not the Everyone Nearby bell: notification tests set it on the shared defaults too.)
		let watched = [UserDefaults.Keys.firstLaunch.rawValue, RadioAutoConfig.pairingCodeAttemptsKey]
		let saved = watched.map { standard.object(forKey: $0) }
		defer {
			for (key, value) in zip(watched, saved) {
				if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
			}
		}
		standard.set(false, forKey: UserDefaults.Keys.firstLaunch.rawValue)
		standard.set(["32343": 2], forKey: RadioAutoConfig.pairingCodeAttemptsKey)

		func expectKept(_ path: String) {
			#expect(profiles.me == me, "\(path)")
			#expect(profiles.myPhotoData == Data([1, 2, 3]), "\(path)")
			let sam = profiles.profile(5)
			#expect(sam?.nickname == "Sammy", "\(path)")
			#expect(sam?.isContact == true, "\(path)")
			#expect(sam?.contactName == "Sam's Radio", "\(path)")
			#expect(sam?.card?.displayName == "Sam", "\(path)")
			#expect(sam?.savedPhotoVersion == 9, "\(path)")
			#expect(sam?.sentCardVersion == 0, "my card goes again through the new radio (\(path))")
			#expect(fileNames(in: folder) == ["profiles.json", "me.jpg", "5.jpg"], "\(path)")
			#expect(ProfileStore(folder: folder).contactNums == [5], "\(path)")
			#expect(standard.object(forKey: UserDefaults.Keys.firstLaunch.rawValue) as? Bool == false, "setup isn't shown again (\(path))")
			#expect(RadioAutoConfig.pairingCodeAttempts(for: 32343) == 2, "\(path)")
		}

		var erasingShown: Bool?
		await RadioPairing.clearRadioData(profiles: profiles, clearStore: {
			erasingShown = AccessoryManager.shared.appState?.isErasingAppData
			return true
		})
		#expect(erasingShown != true, "the placeholder keeps the radio wording")
		expectKept("clearRadioData")

		profiles.markCardSent(7, to: 5)
		RadioPairing.clearRadioState(profiles: profiles)
		expectKept("clearRadioState")
	}
}

/// The launch import starts in the app's init, before UIApplicationMain has made the
/// application, when asking it for background time does nothing. The time is asked for once
/// the app has launched, at most once per import, and given back exactly once.
@Suite("Background time for the old chats' import", .serialized)
@MainActor
struct LegacyImportBackgroundTimeTests {

	@MainActor
	private final class Recorder {
		var begins: [String] = []
		var ends: [UIBackgroundTaskIdentifier] = []
		var expire: (@MainActor @Sendable () -> Void)?
		private var next = 40

		var time: BackgroundTime {
			BackgroundTime(
				begin: { name, expired in
					self.begins.append(name)
					self.expire = expired
					self.next += 1
					return UIBackgroundTaskIdentifier(rawValue: self.next)
				},
				end: { self.ends.append($0) }
			)
		}
	}

	@Test func theGrantWaitsForTheAppAndEndsOnce() async {
		let legacyImport = LegacyStoreImport()
		let recorder = Recorder()
		let release = ImportRelease()
		legacyImport.start { await release.wait() }
		#expect(recorder.begins.isEmpty)

		legacyImport.appDidLaunch(recorder.time)
		#expect(recorder.begins == ["LegacyImport"])
		legacyImport.appDidLaunch(recorder.time)
		#expect(recorder.begins.count == 1, "a second launch call takes nothing more")
		#expect(recorder.ends.isEmpty)

		await release.open()
		await legacyImport.waitUntilFinished()
		#expect(!legacyImport.isRunning)
		#expect(recorder.ends == [UIBackgroundTaskIdentifier(rawValue: 41)])
	}

	@Test func anExpiredGrantIsEndedOnlyOnce() async {
		let legacyImport = LegacyStoreImport()
		let recorder = Recorder()
		legacyImport.appDidLaunch(recorder.time)
		#expect(recorder.begins.isEmpty, "nothing to hold time for yet")

		let release = ImportRelease()
		legacyImport.start { await release.wait() }
		#expect(recorder.begins.count == 1, "once the app exists, an import asks at its start")
		recorder.expire?()
		#expect(recorder.ends == [UIBackgroundTaskIdentifier(rawValue: 41)])
		await release.open()
		await legacyImport.waitUntilFinished()
		#expect(recorder.ends.count == 1, "the import ending after the time ran out ends nothing")

		// A later import has its own grant.
		legacyImport.start {}
		await legacyImport.waitUntilFinished()
		#expect(recorder.begins.count == 2)
		#expect(recorder.ends == [UIBackgroundTaskIdentifier(rawValue: 41), UIBackgroundTaskIdentifier(rawValue: 42)])
	}

	@Test func anImportDoneBeforeLaunchAsksForNothing() async {
		let legacyImport = LegacyStoreImport()
		let recorder = Recorder()
		legacyImport.start {}
		await legacyImport.waitUntilFinished()
		legacyImport.appDidLaunch(recorder.time)
		#expect(recorder.begins.isEmpty)
		#expect(recorder.ends.isEmpty)
	}
}
