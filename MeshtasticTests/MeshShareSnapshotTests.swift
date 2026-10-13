import Foundation
import MeshtasticProtobufs
import Security
import SwiftData
import Testing

@testable import Meshtastic

@Suite("iMessage share snapshots")
struct MeshShareSnapshotTests {
	@Test @MainActor func channelEntityPreservesEveryShareableSetting() {
		var incoming = Channel()
		incoming.index = 3
		incoming.role = .secondary
		incoming.settings.id = 0xF1234567
		incoming.settings.name = "Private"
		incoming.settings.psk = Data(repeating: 4, count: 16)
		incoming.settings.uplinkEnabled = true
		incoming.settings.downlinkEnabled = true
		incoming.settings.moduleSettings.positionPrecision = 11
		incoming.settings.moduleSettings.isMuted = true
		let entity = ChannelEntity()

		entity.update(from: incoming)
		let output = entity.settingsProto

		#expect(entity.id == 3)
		#expect(entity.index == 3)
		#expect(entity.role == Int32(Channel.Role.secondary.rawValue))
		#expect(output.id == 3)
		#expect(output.name == "Private")
		#expect(output.psk == Data(repeating: 4, count: 16))
		#expect(output.uplinkEnabled)
		#expect(output.downlinkEnabled)
		#expect(output.moduleSettings.positionPrecision == 11)
		#expect(output.moduleSettings.isMuted)
	}

	@Test func failedRefreshClearsOnlyADifferentRadiosSnapshot() {
		#expect(MeshShareSnapshotBuilder.shouldClearExistingSnapshot(existingNodeNum: 1, attemptedNodeNum: 2))
		#expect(!MeshShareSnapshotBuilder.shouldClearExistingSnapshot(existingNodeNum: 2, attemptedNodeNum: 2))
		#expect(!MeshShareSnapshotBuilder.shouldClearExistingSnapshot(existingNodeNum: nil, attemptedNodeNum: 2))
	}

	@Test func keychainQueryAlwaysUsesDedicatedAccessGroup() {
		let group = "TEAM.gvh.MeshtasticClient.MessagesSharing"

		let query = MeshShareStore.query(accessGroup: group)

		#expect(query[kSecAttrAccessGroup as String] as? String == group)
		#expect(query[kSecAttrService as String] as? String == MeshShareStore.service)
		#expect(query[kSecAttrSynchronizable as String] as? Bool == false)
	}

	@Test func snapshotRoundTripsThroughTheDedicatedKeychainGroup() throws {
		let snapshot = MeshShareSnapshot(
			radioNodeNum: 0x12345678,
			radioLongName: "Keychain Test",
			radioShortName: "KEY",
			contactURL: "https://meshtastic.org/v/#abc",
			loraConfigData: Data([1, 2, 3]),
			channels: [],
			refreshedAt: Date(timeIntervalSince1970: 2_000_000)
		)
		try MeshShareStore.delete()
		defer { try? MeshShareStore.delete() }

		try MeshShareStore.save(snapshot)

		#expect(MeshShareStore.load() == snapshot)
	}

	@Test func snapshotRoundTripsAndBecomesStaleAfterThirtyDays() throws {
		let now = Date(timeIntervalSince1970: 2_000_000)
		let snapshot = MeshShareSnapshot(
			radioNodeNum: 42,
			radioLongName: "Base Camp",
			radioShortName: "BASE",
			contactURL: "https://meshtastic.org/v/#abc",
			loraConfigData: Data([1]),
			channels: [],
			refreshedAt: now
		)

		let data = try JSONEncoder().encode(snapshot)
		let decoded = try JSONDecoder().decode(MeshShareSnapshot.self, from: data)

		#expect(decoded == snapshot)
		#expect(!snapshot.isStale(at: now.addingTimeInterval(30 * 86_400)))
		#expect(snapshot.isStale(at: now.addingTimeInterval(30 * 86_400 + 1)))
		#expect(
			MeshShareSnapshot(
				radioNodeNum: 42,
				radioLongName: "Base Camp",
				radioShortName: "BASE",
				contactURL: "https://meshtastic.org/v/?exchange=true#abc",
				loraConfigData: Data(),
				channels: [],
				refreshedAt: now
			).contactReplyURL == "https://meshtastic.org/v/#abc"
		)
	}

	@Test func channelSelectionDefaultsToAllAndReplacePreservesLoRa() throws {
		var lora = Config.LoRaConfig()
		lora.hopLimit = 5
		var alpha = ChannelSettings()
		alpha.name = "Alpha"
		alpha.psk = Data([1, 2, 3, 4])
		var beta = ChannelSettings()
		beta.name = "Beta"
		beta.psk = Data([9, 8, 7, 6])
		let snapshot = MeshShareSnapshot(
			radioNodeNum: 42,
			radioLongName: "Base Camp",
			radioShortName: "BASE",
			contactURL: "https://meshtastic.org/v/#abc",
			loraConfigData: try lora.serializedData(),
			channels: [
				MeshShareChannel(index: 0, name: "Alpha", isEncrypted: true, settingsData: try alpha.serializedData()),
				MeshShareChannel(index: 1, name: "Beta", isEncrypted: true, settingsData: try beta.serializedData())
			],
			refreshedAt: .now
		)
		let selection = MeshChannelSelection(snapshot: snapshot)

		#expect(selection.defaultSelectedIndexes == [0, 1])
		let parsed = try MeshtasticChannelURL.parse(
			selection.url(selectedIndexes: [1], mode: .replace)
		)
		#expect(parsed.channelSet.settings.map(\.name) == ["Beta"])
		#expect(parsed.channelSet.loraConfig.hopLimit == 5)
		#expect(parsed.channelSet.settings[0].psk == Data([9, 8, 7, 6]))
	}

	@Test func addModeClearsLoRaAndEmptySelectionFails() throws {
		var channel = ChannelSettings()
		channel.name = "Alpha"
		let snapshot = MeshShareSnapshot(
			radioNodeNum: 42,
			radioLongName: "Base Camp",
			radioShortName: "BASE",
			contactURL: "https://meshtastic.org/v/#abc",
			loraConfigData: try Config.LoRaConfig().serializedData(),
			channels: [
				MeshShareChannel(index: 0, name: "Alpha", isEncrypted: false, settingsData: try channel.serializedData())
			],
			refreshedAt: .now
		)
		let selection = MeshChannelSelection(snapshot: snapshot)

		let parsed = try MeshtasticChannelURL.parse(selection.url(selectedIndexes: [0], mode: .add))
		#expect(parsed.addChannels)
		#expect(!parsed.channelSet.hasLoraConfig)
		#expect(throws: MeshChannelSelection.SelectionError.noChannels) {
			_ = try selection.url(selectedIndexes: [], mode: .replace)
		}
	}
}

/// Stands in for a live radio link; what is sent goes nowhere.
private actor SnapshotStubConnection: Connection {
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

/// Pangea: joining or leaving a group rebuilds the Messages extension's copy of the radio's
/// channels at once, rather than at the next connect, so a group left keeps no key there.
@Suite("iMessage snapshot follows groups", .serialized)
@MainActor
struct MeshShareSnapshotGroupTests {
	private let myNum: Int64 = 0x5EED_0001
	private let groupKey = Data((0..<32).map { UInt8(200 &+ $0) })

	private func connectedRadio() throws -> (AccessoryManager, ModelContainer, ChannelEntity) {
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let config = ModelConfiguration("SnapshotGroups-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
		let container = try ModelContainer(for: schema, configurations: config)
		let context = container.mainContext

		let node = NodeInfoEntity()
		node.num = myNum
		context.insert(node)
		let user = UserEntity()
		user.num = myNum
		user.longName = "Base Camp"
		user.shortName = "BASE"
		user.publicKey = Data(repeating: 9, count: 32)
		user.unmessagable = false
		context.insert(user)
		user.userNode = node
		let lora = LoRaConfigEntity()
		context.insert(lora)
		node.loRaConfig = lora
		let myInfo = MyInfoEntity()
		myInfo.myNodeNum = myNum
		context.insert(myInfo)
		myInfo.myInfoNode = node
		let everyone = ChannelEntity()
		everyone.index = 0
		everyone.role = Int32(Channel.Role.primary.rawValue)
		everyone.psk = Data([1])
		context.insert(everyone)
		let group = ChannelEntity()
		group.id = 1
		group.index = 1
		group.role = Int32(Channel.Role.secondary.rawValue)
		group.name = "Trail"
		group.psk = groupKey
		context.insert(group)
		myInfo.channels = [everyone, group]
		try context.save()

		let manager = AccessoryManager(transports: [])
		// The init takes over the shared MQTT delegate; hand it back to the app's manager.
		MqttClientProxyManager.shared.delegate = AccessoryManager.shared
		manager.context = context
		manager.activeConnection = (device: Device(id: UUID(), name: "Base Camp", transportType: .ble, identifier: "BLE-SNAP"), connection: SnapshotStubConnection())
		manager.updateState(.subscribed)
		manager.activeDeviceNum = myNum
		return (manager, container, group)
	}

	private func sharedKeys() throws -> [Int32: Data] {
		let snapshot = try #require(MeshShareStore.load())
		var keys: [Int32: Data] = [:]
		for channel in snapshot.channels {
			keys[channel.index] = try ChannelSettings(serializedBytes: channel.settingsData).psk
		}
		return keys
	}

	@Test func leavingAGroupTakesItsKeyOutOfTheSnapshot() async throws {
		try MeshShareStore.delete()
		defer { try? MeshShareStore.delete() }
		let (manager, container, group) = try connectedRadio()
		MeshShareSnapshotBuilder.refresh(nodeNum: myNum, context: manager.context)
		#expect(try sharedKeys()[1] == groupKey)
		#expect(MeshShareStore.load()?.channels.first(where: { $0.index == 0 })?.name == "Everyone Nearby")

		try await GroupChats.leave(group, accessoryManager: manager)

		let keys = try sharedKeys()
		#expect(keys[1] == nil, "a left group's key must not stay shareable")
		#expect(!keys.values.contains(groupKey))
		#expect(keys[0] != nil)
		manager.activeConnection = nil
		withExtendedLifetime(container) {}
	}

	@Test func joiningAGroupAddsItToTheSnapshot() async throws {
		try MeshShareStore.delete()
		defer { try? MeshShareStore.delete() }
		let (manager, container, _) = try connectedRadio()
		MeshShareSnapshotBuilder.refresh(nodeNum: myNum, context: manager.context)
		let newKey = Data((0..<32).map { UInt8(17 &+ $0) })

		let slot = try await GroupChats.join(GroupInvite(name: "Ridge", psk: newKey), accessoryManager: manager)

		#expect(slot == 2)
		#expect(try sharedKeys()[2] == newKey)
		#expect(MeshShareStore.load()?.channels.first(where: { $0.index == 2 })?.name == "Ridge")
		manager.activeConnection = nil
		withExtendedLifetime(container) {}
	}
}
