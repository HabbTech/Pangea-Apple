//
//  ChannelSyncTests.swift
//  MeshtasticTests
//

import Foundation
import SwiftData
import Testing
import MeshtasticProtobufs
@testable import Meshtastic

/// The radio's channel list as it's saved on each connect. The radio reports all 8 slots during
/// the config download; they're staged and only replace the list once the download completes, so
/// a link that drops part way leaves every group listed. Each test uses a radio number of its
/// own in the shared test store.
@Suite("Channel list across reconnects")
@MainActor
struct ChannelSyncTests {

	private let packets = MeshPackets(modelContainer: sharedModelContainer)
	private let num = Int64.random(in: 1_000_000_000...4_000_000_000)
	private let key = Data(repeating: 7, count: 32)

	private func channel(_ index: Int32, _ name: String, role: Channel.Role? = nil) -> Channel {
		var channel = Channel()
		channel.index = index
		channel.role = role ?? (index == 0 ? .primary : .secondary)
		channel.settings.name = name
		channel.settings.psk = index == 0 ? Data([1]) : key
		return channel
	}

	private func addMyInfo() async throws {
		var info = MyNodeInfo()
		info.myNodeNum = UInt32(num)
		_ = try #require(await packets.myInfoPacket(myInfo: info, peripheralId: "test"))
	}

	/// What a connect does: stage the download, take each channel the radio reports (every slot
	/// it doesn't list comes as disabled), and commit at the end of the config download.
	/// `complete: false` is a link that drops before the radio has sent everything.
	private func connect(_ channels: [Channel], complete: Bool = true) async {
		#expect(await packets.beginChannelRefreshStage(for: num))
		for channel in channels {
			await packets.channelPacket(channel: channel, fromNum: num)
		}
		guard complete else {
			// What closing the connection does with a stage that never finished.
			await packets.discardChannelRefreshStage(for: num)
			return
		}
		let reported = Set(channels.map { Int32($0.index) })
		for index in Int32(0)...Int32(7) where !reported.contains(index) {
			await packets.channelPacket(channel: channel(index, "", role: .disabled), fromNum: num)
		}
		await packets.commitChannelRefreshStage(for: num)
	}

	/// Read on a fresh context, as a screen opened after the connect would.
	private func saved() -> (listed: [Int32], names: [Int32: String]) {
		let context = ModelContext(sharedModelContainer)
		let radio = num
		let info = try? context.fetch(FetchDescriptor<MyInfoEntity>(predicate: #Predicate { $0.myNodeNum == radio })).first
		let channels = (info?.channels ?? []).sorted { $0.index < $1.index }
		return (channels.map(\.index), Dictionary(channels.map { ($0.index, $0.name ?? "") }, uniquingKeysWith: { first, _ in first }))
	}

	private func rows(_ index: Int32) -> [ChannelEntity] {
		let context = ModelContext(sharedModelContainer)
		let radio = num
		let info = try? context.fetch(FetchDescriptor<MyInfoEntity>(predicate: #Predicate { $0.myNodeNum == radio })).first
		return (info?.channels ?? []).filter { $0.index == index }
	}

	@Test func everyChannelStaysOnTheRadioAcrossReconnects() async throws {
		try await addMyInfo()
		for _ in 1...6 {
			await connect([channel(0, ""), channel(1, "HABB TEAM")])
			#expect(saved().listed == [0, 1])
		}
	}

	/// The packet handler is replaced every so often to free memory; a download in progress
	/// carries on with the new one.
	@Test func replacingThePacketHandlerMidDownloadKeepsEveryChannel() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM")])
		#expect(await packets.beginChannelRefreshStage(for: num))
		await packets.channelPacket(channel: channel(0, ""), fromNum: num)
		let successor = MeshPackets(modelContainer: sharedModelContainer)
		await successor.channelPacket(channel: channel(1, "HABB TEAM"), fromNum: num)
		for index in Int32(2)...Int32(7) {
			await successor.channelPacket(channel: channel(index, "", role: .disabled), fromNum: num)
		}
		await successor.commitChannelRefreshStage(for: num)
		#expect(saved().listed == [0, 1])
	}

	@Test func theListIsInIndexOrderWhateverOrderTheRadioReports() async throws {
		try await addMyInfo()
		await connect([channel(2, "Hike"), channel(0, ""), channel(1, "HABB TEAM")])
		#expect(saved().listed == [0, 1, 2])
		let info = try #require(try ModelContext(sharedModelContainer).fetch(FetchDescriptor<MyInfoEntity>()).first { $0.myNodeNum == num })
		#expect(info.sortedChannels.map(\.index) == [0, 1, 2])
	}

	@Test func aSlotTheRadioNoLongerReportsDropsOff() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "Hike")])
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "", role: .disabled)])
		#expect(saved().listed == [0, 1])
	}

	/// Leaving deletes the group on the main context. Joining a group into the same slot right
	/// after, and reconnecting, must still list it, once.
	@Test func aGroupLeftOnTheMainContextCanBeJoinedAgainAtOnce() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "Hike")])

		let main = sharedModelContainer.mainContext
		for row in rows(2) {
			if let live = main.model(for: row.persistentModelID) as? ChannelEntity {
				main.delete(live)
			}
		}
		try main.save()
		#expect(saved().listed == [0, 1])

		await packets.channelPacket(channel: channel(2, "Bike"), fromNum: num, stageIfRefreshing: false)
		#expect(saved().listed == [0, 1, 2])

		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "Ride")])
		#expect(saved().listed == [0, 1, 2])
		#expect(rows(2).count == 1)
		#expect(saved().names[2] == "Ride")
	}

	/// A drop part way through the download leaves every group listed, and the next full
	/// download still takes off a slot the radio stopped using.
	@Test func aDropPartWayThroughTheDownloadKeepsEveryGroup() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "Hike")])
		await connect([channel(0, "")], complete: false)
		#expect(saved().listed == [0, 1, 2])
		// Nothing is cleared when the download starts either.
		#expect(await packets.beginChannelRefreshStage(for: num))
		#expect(saved().listed == [0, 1, 2])
		await packets.discardChannelRefreshStage(for: num)
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "", role: .disabled)])
		#expect(saved().listed == [0, 1])
	}

	/// A download that didn't report every slot isn't trusted to replace the list.
	@Test func anIncompleteDownloadChangesNothing() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM")])
		#expect(await packets.beginChannelRefreshStage(for: num))
		await packets.channelPacket(channel: channel(0, ""), fromNum: num)
		await packets.commitChannelRefreshStage(for: num)
		#expect(saved().listed == [0, 1])
	}

	@Test func aChannelIsUpdatedWhereItIs() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM")])
		await connect([channel(0, ""), channel(1, "Renamed")])
		#expect(rows(1).map(\.name) == ["Renamed"])
	}

	/// Reconnecting keeps each slot's row, so a screen holding a group (Leave, an invite, the
	/// open chat) still has a live model after the radio reconnects.
	@Test func aReconnectKeepsTheSameRowForEachSlot() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "Hike")])
		let before = try #require(rows(1).first).persistentModelID
		let held = try #require(sharedModelContainer.mainContext.model(for: before) as? ChannelEntity)
		await connect([channel(0, ""), channel(1, "Renamed"), channel(2, "", role: .disabled)])
		#expect(rows(1).map(\.persistentModelID) == [before])
		#expect(!held.isDeleted && held.modelContext != nil)
		#expect(saved().listed == [0, 1])
	}

	/// A slot reused by another group (as `GroupChats.join` writes it, with no module settings)
	/// starts unmuted, with location sharing off.
	@Test func aNewGroupInAReusedSlotDoesntKeepTheOldMute() async throws {
		try await addMyInfo()
		var old = channel(2, "Old")
		old.settings.moduleSettings.isMuted = true
		old.settings.moduleSettings.positionPrecision = 13
		await connect([channel(0, ""), channel(1, "Keep"), old])
		// Left on another phone: gone at the end of the next download.
		await connect([channel(0, ""), channel(1, "Keep")])
		var joined = channel(2, "New")
		joined.settings.psk = Data(repeating: 9, count: 32)
		await packets.channelPacket(channel: joined, fromNum: num, stageIfRefreshing: false)

		let slot2 = try #require(rows(2).first)
		#expect(slot2.name == "New" && !slot2.mute && slot2.positionPrecision == 0)
	}
}

@Suite("Picking a slot for a new group")
@MainActor
struct GroupSlotTests {

	private func channels(_ slots: [(index: Int32, role: Int32)]) -> [ChannelEntity] {
		slots.map { slot in
			let channel = ChannelEntity()
			channel.index = slot.index
			channel.role = slot.role
			return channel
		}
	}

	/// An empty or partial list means the radio's channels aren't loaded; slot 1 may hold a
	/// group, so nothing is written.
	@Test func refusesWithoutThePrimaryChannel() {
		#expect(throws: GroupChatError.channelsNotLoaded) { try GroupChats.freeSlot(in: []) }
		#expect(throws: GroupChatError.channelsNotLoaded) { try GroupChats.freeSlot(in: channels([(2, 2)])) }
		#expect(throws: GroupChatError.channelsNotLoaded) { try GroupChats.freeSlot(in: channels([(0, 0)])) }
	}

	@Test func takesTheFirstSlotNotInUse() throws {
		#expect(try GroupChats.freeSlot(in: channels([(0, 1)])) == 1)
		#expect(try GroupChats.freeSlot(in: channels([(0, 1), (1, 2), (3, 2)])) == 2)
		#expect(try GroupChats.freeSlot(in: channels([(0, 1), (1, 0)])) == 1)
	}

	@Test func fullWhenEverySlotIsInUse() {
		let all = channels([(0, 1)] + (1...7).map { (Int32($0), Int32(2)) })
		#expect(throws: GroupChatError.full) { try GroupChats.freeSlot(in: all) }
	}

	/// Adding a channel set from a link takes free slots, not the next index by count: with
	/// slot 1 left, the list is [0, 2], and writing index 2 would replace that group.
	@Test func anAddedChannelSetFillsTheGaps() throws {
		#expect(try GroupChats.freeSlots(in: channels([(0, 1), (2, 2)]), count: 1) == [1])
		#expect(try GroupChats.freeSlots(in: channels([(0, 1), (2, 2)]), count: 3) == [1, 3, 4])
		#expect(try GroupChats.freeSlots(in: channels([(0, 1), (1, 2), (2, 0)]), count: 1) == [2])
		#expect(try GroupChats.freeSlots(in: channels([(0, 1)]), count: 0) == [])
	}

	/// Every slot written is 1 to 7; a set too big for the free slots writes none of it.
	@Test func anAddedChannelSetThatDoesntFitIsRefused() {
		let six = channels([(0, 1)] + (1...6).map { (Int32($0), Int32(2)) })
		#expect(throws: GroupChatError.full) { try GroupChats.freeSlots(in: six, count: 2) }
		#expect(throws: GroupChatError.full) { try GroupChats.freeSlots(in: channels([(0, 1)]), count: 8) }
		#expect(throws: GroupChatError.channelsNotLoaded) { try GroupChats.freeSlots(in: channels([(2, 2)]), count: 1) }
		#expect((try? GroupChats.freeSlots(in: channels([(0, 1)]), count: 7)) == Array(Int32(1)...Int32(7)))
	}
}

@Suite("Turning off the pairing code")
struct PairingCodeAttemptTests {

	/// A send that failed before anything was written doesn't use up a try; one that may
	/// have reached the radio does.
	@Test func onlySendsThatMayHaveArrivedCount() {
		#expect(AccessoryError.neverSent(AccessoryError.connectionFailed("Not connected to any device")))
		#expect(AccessoryError.neverSent(AccessoryError.ioFailed("Not connected or characteristic not found")))
		#expect(!AccessoryError.neverSent(AccessoryError.disconnected("Unknown error")))
		#expect(!AccessoryError.neverSent(AccessoryError.timeout))
		#expect(!AccessoryError.neverSent(CancellationError()))
	}

	@Test func triesEachRadioALimitedNumberOfTimes() throws {
		let defaults = try #require(UserDefaults(suiteName: "pairing-\(UUID().uuidString)"))
		#expect(RadioAutoConfig.pairingCodeAttempts(for: 5, defaults: defaults) == 0)
		#expect(RadioAutoConfig.mayTryTurningOffCode(attempts: 0))
		RadioAutoConfig.setPairingCodeAttempts(1, for: 5, defaults: defaults)
		#expect(RadioAutoConfig.mayTryTurningOffCode(attempts: RadioAutoConfig.pairingCodeAttempts(for: 5, defaults: defaults)))
		RadioAutoConfig.setPairingCodeAttempts(2, for: 5, defaults: defaults)
		#expect(!RadioAutoConfig.mayTryTurningOffCode(attempts: RadioAutoConfig.pairingCodeAttempts(for: 5, defaults: defaults)))
		// Counted per radio.
		#expect(RadioAutoConfig.pairingCodeAttempts(for: 6, defaults: defaults) == 0)
	}

	/// A radio that starts reporting a new node number keeps its tries.
	@Test func triesFollowARenumberedRadio() throws {
		let defaults = try #require(UserDefaults(suiteName: "pairing-\(UUID().uuidString)"))
		RadioAutoConfig.setPairingCodeAttempts(2, for: 5, defaults: defaults)
		RadioAutoConfig.renumberPairingCodeAttempts(from: 5, to: 9, defaults: defaults)
		#expect(RadioAutoConfig.pairingCodeAttempts(for: 9, defaults: defaults) == 2)
		#expect(RadioAutoConfig.pairingCodeAttempts(for: 5, defaults: defaults) == 0)
	}
}

@Suite("TAK read-only after the channel check")
@MainActor
struct TAKReadOnlyTests {

	@Test func aFailedCheckTurnsItOnAndAPassingOneUndoesOnlyThat() {
		var state = TAKServerManager.readOnlyAfterCheck(isValid: false, userReadOnly: false, forced: false)
		#expect(state == (true, true))
		state = TAKServerManager.readOnlyAfterCheck(isValid: false, userReadOnly: state.userReadOnly, forced: state.forced)
		#expect(state == (true, true))
		state = TAKServerManager.readOnlyAfterCheck(isValid: true, userReadOnly: state.userReadOnly, forced: state.forced)
		#expect(state == (false, false))
	}

	/// Read-only the user chose stays on through a failed check and a passing one.
	@Test func theUsersChoiceIsNeverUndone() {
		var state = TAKServerManager.readOnlyAfterCheck(isValid: false, userReadOnly: true, forced: false)
		#expect(state == (true, false))
		state = TAKServerManager.readOnlyAfterCheck(isValid: true, userReadOnly: state.userReadOnly, forced: state.forced)
		#expect(state == (true, false))
		#expect(TAKServerManager.readOnlyAfterCheck(isValid: true, userReadOnly: false, forced: false) == (false, false))
	}

	/// At launch there's no radio yet, so there's nothing to check and nothing changes.
	@Test func launchingWithNoRadioLeavesReadOnlyAlone() throws {
		let server = TAKServerManager.shared
		// Other suites leave a device number on the shared manager; this test needs none.
		let savedNum = AccessoryManager.shared.activeDeviceNum
		AccessoryManager.shared.activeDeviceNum = nil
		let savedUser = server.userReadOnlyMode
		let savedForced = UserDefaults.standard.object(forKey: "takServerReadOnlyForced")
		defer {
			server.userReadOnlyMode = savedUser
			UserDefaults.standard.set(savedForced, forKey: "takServerReadOnlyForced")
			AccessoryManager.shared.activeDeviceNum = savedNum
		}
		server.userReadOnlyMode = false
		let readOnlyBefore = server.readOnlyMode
		server.checkPrimaryChannelValidity()
		#expect(server.userReadOnlyMode == false)
		#expect(server.readOnlyMode == readOnlyBefore)
		#expect(server.readOnlyForcedByCheck == false)
	}
}
