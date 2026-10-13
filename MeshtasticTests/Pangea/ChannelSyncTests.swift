//
//  ChannelSyncTests.swift
//  MeshtasticTests
//

import Foundation
import CoreData
import Testing
import MeshtasticProtobufs
@testable import Meshtastic

/// The radio's channel list as it's saved on each connect: cleared, then each channel the
/// radio reports, on the packet handler's background context, while the screens read and
/// leave groups on the view context. Each test has its own in-memory database.
@Suite("Channel list across reconnects")
@MainActor
struct ChannelSyncTests {

	private let persistence = PersistenceController(inMemory: true)
	private let packets: MeshPackets
	private let num: Int64 = 2322439327
	private let key = Data(repeating: 7, count: 32)

	init() {
		packets = MeshPackets(container: persistence.container)
	}

	private var viewContext: NSManagedObjectContext { persistence.container.viewContext }

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

	/// What `handleMyInfo`, `handleChannel` and the end of the config download do on a connect.
	/// `complete: false` is a link that drops before the radio has sent everything.
	private func connect(_ channels: [Channel], complete: Bool = true) async {
		await packets.beginChannelDownload(fromNum: num)
		for channel in channels {
			await packets.channelPacket(channel: channel, fromNum: num)
		}
		if complete {
			await packets.finishChannelDownload(fromNum: num)
		}
	}

	/// Read straight from the store, as a screen opened after the connect would.
	private func saved() -> (listed: [Int32], rows: [(index: Int32, attached: Bool)]) {
		let context = persistence.container.newBackgroundContext()
		context.stalenessInterval = 0
		return context.performAndWait {
			let infoRequest = MyInfoEntity.fetchRequest()
			infoRequest.predicate = NSPredicate(format: "myNodeNum == %lld", num)
			let info = try? context.fetch(infoRequest).first
			let listed = (info?.channels?.array as? [ChannelEntity] ?? []).map(\.index)
			let rowRequest = ChannelEntity.fetchRequest()
			rowRequest.sortDescriptors = [NSSortDescriptor(key: "index", ascending: true)]
			let rows = ((try? context.fetch(rowRequest)) ?? []).map { ($0.index, $0.myInfoChannel?.myNodeNum == num) }
			return (listed, rows)
		}
	}

	@Test func everyChannelStaysOnTheRadioAcrossReconnects() async throws {
		try await addMyInfo()
		for _ in 1...6 {
			await connect([channel(0, ""), channel(1, "HABB TEAM")])
			let state = saved()
			#expect(state.listed == [0, 1])
			#expect(state.rows.count == 2)
			#expect(state.rows.allSatisfy { $0.attached })
		}
	}

	/// The context is reset every so often to free memory; that mustn't change the outcome.
	@Test func reconnectsAfterTheBackgroundContextIsResetKeepEveryChannel() async throws {
		try await addMyInfo()
		for _ in 1...4 {
			let context = await packets.backgroundContext
			await context.perform { context.reset() }
			await connect([channel(0, ""), channel(1, "HABB TEAM")])
			#expect(saved().listed == [0, 1])
		}
	}

	/// Rows an earlier version left off the list are taken back on the next connect, and
	/// updated in place rather than copied.
	@Test func channelsLeftOffTheListAreReattachedOnTheNextConnect() async throws {
		try await addMyInfo()
		for (index, name) in [(Int32(0), ""), (Int32(1), "HABB TEAM")] {
			let orphan = ChannelEntity(context: viewContext)
			orphan.index = index
			orphan.role = index == 0 ? 1 : 2
			orphan.name = name
		}
		try viewContext.save()
		#expect(saved().rows.map { $0.attached } == [false, false])

		await connect([channel(0, ""), channel(1, "HABB TEAM")])
		let state = saved()
		#expect(state.listed == [0, 1])
		#expect(state.rows.count == 2)
		#expect(state.rows.allSatisfy { $0.attached })
	}

	@Test func theListIsInIndexOrderWhateverOrderTheRadioReports() async throws {
		try await addMyInfo()
		await connect([channel(2, "Hike"), channel(0, ""), channel(1, "HABB TEAM")])
		#expect(saved().listed == [0, 1, 2])
	}

	@Test func aSlotTheRadioNoLongerReportsDropsOff() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "Hike")])
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "", role: .disabled)])
		#expect(saved().listed == [0, 1])
	}

	/// Leaving deletes the group on the view context, which the background context doesn't
	/// hear about. Joining a group into the same slot right after, and reconnecting, must
	/// still list it.
	@Test func aGroupLeftOnTheViewContextCanBeJoinedAgainAtOnce() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "Hike")])

		let request = ChannelEntity.fetchRequest()
		request.predicate = NSPredicate(format: "index == 2")
		for row in try viewContext.fetch(request) {
			viewContext.delete(row)
		}
		try viewContext.save()
		#expect(saved().listed == [0, 1])

		await packets.channelPacket(channel: channel(2, "Bike"), fromNum: num)
		#expect(saved().listed == [0, 1, 2])

		for row in try viewContext.fetch(request) {
			viewContext.delete(row)
		}
		try viewContext.save()
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "Ride")])
		#expect(saved().listed == [0, 1, 2])
		#expect(saved().rows.count == 3)
	}

	/// A drop part way through the download leaves every group listed, and the next full
	/// download still takes off a slot the radio stopped using.
	@Test func aDropPartWayThroughTheDownloadKeepsEveryGroup() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "Hike")])
		await connect([channel(0, "")], complete: false)
		#expect(saved().listed == [0, 1, 2])
		// Nothing is cleared when the download starts either.
		await packets.beginChannelDownload(fromNum: num)
		#expect(saved().listed == [0, 1, 2])
		await connect([channel(0, ""), channel(1, "HABB TEAM"), channel(2, "", role: .disabled)])
		#expect(saved().listed == [0, 1])
		#expect(saved().rows.count == 3)
	}

	/// Only the radio whose download it is settles its list, and only once.
	@Test func finishingWithoutADownloadChangesNothing() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM")])
		await packets.finishChannelDownload(fromNum: num)
		#expect(saved().listed == [0, 1])
	}

	@Test func aChannelIsUpdatedWhereItIs() async throws {
		try await addMyInfo()
		await connect([channel(0, ""), channel(1, "HABB TEAM")])
		await connect([channel(0, ""), channel(1, "Renamed")])
		let request = ChannelEntity.fetchRequest()
		request.predicate = NSPredicate(format: "index == 1")
		let context = persistence.container.newBackgroundContext()
		let names = context.performAndWait { ((try? context.fetch(request)) ?? []).map(\.name) }
		#expect(names == ["Renamed"])
	}

	/// A slot reused by another group (as `GroupChats.join` writes it, with no module settings)
	/// starts unmuted at full precision; the same group reported again keeps its own.
	@Test func aNewGroupInAReusedSlotDoesntKeepTheOldMute() async throws {
		try await addMyInfo()
		var old = channel(2, "Old")
		old.settings.moduleSettings.isMuted = true
		old.settings.moduleSettings.positionPrecision = 13
		await connect([channel(0, ""), channel(1, "Keep"), old])
		// Left on another phone: pruned at the end of the next download.
		await connect([channel(0, ""), channel(1, "Keep")])
		var joined = channel(2, "New")
		joined.settings.psk = Data(repeating: 9, count: 32)
		await packets.channelPacket(channel: joined, fromNum: num)
		// The same group again, without module settings, keeps what it had.
		var muted = channel(1, "Keep")
		muted.settings.moduleSettings.isMuted = true
		muted.settings.moduleSettings.positionPrecision = 11
		await packets.channelPacket(channel: muted, fromNum: num)
		await packets.channelPacket(channel: channel(1, "Keep"), fromNum: num)

		let context = persistence.container.newBackgroundContext()
		let rows = context.performAndWait {
			let request = ChannelEntity.fetchRequest()
			request.sortDescriptors = [NSSortDescriptor(key: "index", ascending: true)]
			return ((try? context.fetch(request)) ?? []).map { (index: $0.index, name: $0.name, mute: $0.mute, precision: $0.positionPrecision) }
		}
		let slot2 = try #require(rows.first { $0.index == 2 })
		#expect(slot2.name == "New" && !slot2.mute && slot2.precision == 0)
		let slot1 = try #require(rows.first { $0.index == 1 })
		#expect(slot1.mute && slot1.precision == 11)
	}
}

@Suite("Picking a slot for a new group")
@MainActor
struct GroupSlotTests {

	private let persistence = PersistenceController(inMemory: true)
	private var context: NSManagedObjectContext { persistence.container.viewContext }

	private func channels(_ slots: [(index: Int32, role: Int32)]) -> [ChannelEntity] {
		slots.map { slot in
			let channel = ChannelEntity(context: context)
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
		try #require(AccessoryManager.shared.activeDeviceNum == nil)
		let savedUser = server.userReadOnlyMode
		let savedForced = UserDefaults.standard.object(forKey: "takServerReadOnlyForced")
		defer {
			server.userReadOnlyMode = savedUser
			UserDefaults.standard.set(savedForced, forKey: "takServerReadOnlyForced")
		}
		server.userReadOnlyMode = false
		let readOnlyBefore = server.readOnlyMode
		server.checkPrimaryChannelValidity()
		#expect(server.userReadOnlyMode == false)
		#expect(server.readOnlyMode == readOnlyBefore)
		#expect(server.readOnlyForcedByCheck == false)
	}
}
