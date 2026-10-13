//
//  GroupChatTests.swift
//  MeshtasticTests
//

import Foundation
import Testing
import SwiftData
import MeshtasticProtobufs
@testable import Meshtastic

@Suite("GroupInvite")
struct GroupInviteTests {

	let invite = GroupInvite(name: "Hiking", psk: Data((0..<32).map { UInt8($0) }))

	@Test func linkRoundTrips() throws {
		let url = try #require(invite.link)
		#expect(url.scheme == "pangea")
		#expect(url.host == "group")
		#expect(GroupInvite(url: url) == invite)
	}

	@Test func payloadRoundTrips() throws {
		let payload = try #require(invite.invitePayload)
		#expect(GroupInvite(invitePayload: payload) == invite)
	}

	@Test func ignoresForeignPrivateAppPayloads() {
		#expect(GroupInvite(invitePayload: Data("hello".utf8)) == nil)
		#expect(GroupInvite(invitePayload: Data()) == nil)
	}

	@Test func rejectsWeakOrMissingKeys() throws {
		let noKey = GroupInvite(name: "Open", psk: Data([1]))
		let url = try #require(noKey.link)
		#expect(GroupInvite(url: url) == nil)
	}

	@Test func clampsNameToFirmwareLimit() {
		#expect(GroupInvite.clampedName("  Weekend Camping Trip ").utf8.count <= GroupInvite.maxNameBytes)
		#expect(GroupInvite.clampedName("Hiking") == "Hiking")
	}

	@Test func dmCodesAreNotGroupLinks() throws {
		let url = try #require(URL(string: "pangea://dm/0D2PF2DZ"))
		#expect(GroupInvite(url: url) == nil)
	}

	@Test(arguments: ["gpio", "GPIO", " serial ", "mqtt", "Admin", "gpio\0x", "admin\u{0}", "\u{202E}nimda", "Hi\u{200B}ke"])
	func reservedChannelNamesAreRefused(name: String) throws {
		var settings = ChannelSettings()
		settings.name = name
		settings.psk = invite.psk
		#expect(GroupInvite(settings: settings) == nil)
		let payload = try settings.serializedData()
		#expect(GroupInvite(invitePayload: Data("PGI1".utf8) + payload) == nil)
	}

	/// The name is the channel's identity, so a received one is refused, never trimmed or
	/// cut: "Hike" isn't the channel "Hike " is.
	@Test(arguments: ["Hike ", " Hike", "Hike\n", "Hike\u{00A0}", "Hike\u{3000}", "Hike\t", "Weekend Camping Trip", "123456789012", "\u{0301}Hike"])
	func receivedNamesAreTakenExactlyOrRefused(name: String) throws {
		var settings = ChannelSettings()
		settings.name = name
		settings.psk = invite.psk
		#expect(GroupInvite(settings: settings) == nil)
		#expect(GroupInvite(invitePayload: Data("PGI1".utf8) + (try settings.serializedData())) == nil)
		var set = ChannelSet()
		set.settings = [settings]
		let url = try #require(URL(string: "pangea://group#\(try set.serializedData().base64EncodedString().base64ToBase64url())"))
		#expect(GroupInvite(url: url) == nil)
	}

	@Test(arguments: ["Hike", "Bike Group", "12345678901", "Café", "Hike ❤️"])
	func aCleanNameComesThroughByteForByte(name: String) throws {
		let invite = GroupInvite(name: name, psk: invite.psk)
		let link = try #require(invite.link)
		let payload = try #require(invite.invitePayload)
		let fromLink = try #require(GroupInvite(url: link))
		let fromPayload = try #require(GroupInvite(invitePayload: payload))
		for received in [fromLink, fromPayload] {
			#expect(Array(received.name.utf8) == Array(name.utf8))
			#expect(received.psk == invite.psk)
		}
		// The QR code is the link.
		#expect(GroupInvite.shareable(name: name, psk: invite.psk) == .success(invite))
	}

	/// What the invite sheet offers is what a friend's app accepts: nothing for a name it
	/// would refuse, so no link, QR or DM that silently goes nowhere.
	@Test(arguments: ["Bike  Group", "Bike Group ", " Bike", "Bike\u{00A0}Group", "Hi\u{200B}ke", "admin", "123456789012"])
	func namesAFriendCantJoinAreNotOffered(name: String) {
		#expect(GroupInvite.shareable(name: name, psk: invite.psk) == .failure(.cantShareName))
	}

	/// The published default key written out in full, and its 1-byte variants (last byte
	/// 0x01 + n - 1, for any n the firmware takes): anyone can read those.
	@Test(arguments: [0x01, 0x02, 0x0a, 0xff] as [UInt8])
	func theDefaultKeyWrittenOutIsntPrivate(last: UInt8) {
		let psk = Data([0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59, 0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, last])
		#expect(!GroupInvite.isPrivateKey(psk))
		var settings = ChannelSettings()
		settings.name = "Hike"
		settings.psk = psk
		#expect(GroupInvite(settings: settings) == nil)
		#expect(throws: GroupChatError.cantShareKey) { try GroupInvite.shareable(name: "Hike", psk: psk).get() }
	}

	@Test(arguments: [16, 32])
	func anAllZeroKeyIsntPrivate(bytes: Int) {
		let psk = Data(count: bytes)
		#expect(!GroupInvite.isPrivateKey(psk))
		#expect(throws: GroupChatError.cantShareKey) { try GroupInvite.shareable(name: "Hike", psk: psk).get() }
	}

	@Test func aRandomKeyIsPrivate() {
		#expect(GroupInvite.isPrivateKey(Data((1...16).map { UInt8($0 * 13) })))
		#expect(GroupInvite.isPrivateKey(Data((1...32).map { UInt8($0 * 7) })))
		// Only the 15-byte prefix makes the default key; a 32-byte key starting with it is someone's own.
		#expect(GroupInvite.isPrivateKey(Data([0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59, 0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01]) + Data(repeating: 9, count: 16)))
	}

	/// No key, the default 1-byte key, or a length the firmware pads out: the sheet says
	/// it's the key, not the name.
	@Test(arguments: [Data(), Data([1]), Data(repeating: 7, count: 20), Data(repeating: 7, count: 33)])
	func aGroupWithoutAPrivateKeyIsNotOfferedForTheKey(psk: Data) {
		#expect(GroupInvite.shareable(name: "Hike", psk: psk) == .failure(.cantShareKey))
		#expect(GroupInvite.shareable(name: "Bike  Group", psk: psk) == .failure(.cantShareKey))
		#expect(GroupInvite.shareable(name: "Hike", psk: Data(repeating: 7, count: 16)) == .success(GroupInvite(name: "Hike", psk: Data(repeating: 7, count: 16))))
	}

	/// "Café" with é as one character and as e plus an accent: the same to Swift's `==`,
	/// two channels to the radio.
	@Test func namesAreComparedByTheirBytes() {
		let composed = GroupInvite(name: "Caf\u{E9}", psk: invite.psk)
		let decomposed = GroupInvite(name: "Cafe\u{301}", psk: invite.psk)
		#expect(composed.name == decomposed.name)
		#expect(composed != decomposed)
		#expect(composed.id != decomposed.id)
		#expect(composed == GroupInvite(name: "Caf\u{E9}", psk: invite.psk))
	}

	@Test func emojiNamesWithJoinersAreStillAllowed() {
		// Zero-width joiners and tag characters are part of these emoji, not hidden text.
		#expect(!GroupInvite.isReserved("👨‍👩‍👧"))
		#expect(!GroupInvite.isReserved("🏴󠁧󠁢󠁳󠁣󠁴󠁿"))
		#expect(!GroupInvite.isReserved("Café"))
	}

	@Test func hugeNameClampsQuickly() {
		let huge = String(repeating: "é", count: 100_000)
		let start = Date()
		let clamped = GroupInvite.clampedName(huge)
		#expect(Date().timeIntervalSince(start) < 0.1)
		#expect(clamped == String(repeating: "é", count: 5))
	}

	@Test func clampKeepsWholeCharacters() {
		// 🇺🇸 is 8 bytes; it never gets cut in half.
		#expect("ab🇺🇸".clampedUTF8(6) == "ab")
		#expect("ab🇺🇸".clampedUTF8(10) == "ab🇺🇸")
		#expect("".clampedUTF8(4) == "")
	}

	@Test func idDoesNotContainTheKey() {
		#expect(!invite.id.contains(invite.psk.base64EncodedString()))
		#expect(invite.id == GroupInvite(name: "Hiking", psk: invite.psk).id)
		#expect(invite.id != GroupInvite(name: "Hiking", psk: Data(repeating: 9, count: 32)).id)
	}
}

@Suite("Pending group invites")
@MainActor
struct GroupInviteStoreTests {

	/// Time since boot and the wall clock, set by hand.
	private final class FakeClock: @unchecked Sendable {
		var reading = InviteClock.Reading(boot: "boot 1", sinceBoot: 3_600 * 1_000_000_000, wall: Date(timeIntervalSince1970: 2_000_000_000))

		var clock: InviteClock { InviteClock { self.reading } }

		/// Time passes, on both clocks.
		func pass(_ seconds: TimeInterval) {
			reading.sinceBoot += UInt64(seconds * 1_000_000_000)
			reading.wall += seconds
		}

		/// Someone sets the phone's clock; no time passes.
		func setWall(by seconds: TimeInterval) {
			reading.wall += seconds
		}

		/// The phone restarts after `seconds`, with its clock then off by `wrong`.
		func restart(after seconds: TimeInterval, wallOffBy wrong: TimeInterval = 0) {
			reading = InviteClock.Reading(boot: "boot \(UUID().uuidString)", sinceBoot: 30 * 1_000_000_000, wall: reading.wall + seconds + wrong)
		}
	}

	private static let day: TimeInterval = 24 * 60 * 60
	private static let year: TimeInterval = 365 * day

	private func defaults() -> UserDefaults {
		UserDefaults(suiteName: "pangea.tests.\(UUID().uuidString)")!
	}

	private func store(_ clock: FakeClock = FakeClock(), defaults: UserDefaults? = nil) -> GroupInviteStore {
		GroupInviteStore(defaults: defaults ?? self.defaults(), key: "invites", clock: clock.clock)
	}

	private func invite(_ seed: UInt8, name: String = "Trip") -> GroupInvite {
		GroupInvite(name: name, psk: Data(repeating: seed, count: 32))
	}

	@Test func sameGroupIsOnlyListedOnce() {
		let store = store()
		#expect(store.add(invite(1), from: 10, notify: false))
		// Same name and key, even from someone else.
		#expect(!store.add(invite(1), from: 11, notify: false))
		#expect(store.pending.count == 1)
	}

	/// A group is its name and key, as on the radio: a decoy on the same key under another
	/// name, sent first, doesn't keep the real invite out, and joining one leaves the other.
	@Test func aSameKeyInviteUnderAnotherNameIsAnotherGroup() {
		let store = store()
		let decoy = invite(1, name: "Hik3")
		let real = invite(1, name: "Hike")
		#expect(store.add(decoy, from: 10, notify: false))
		#expect(store.add(real, from: 11, notify: false))
		#expect(store.pending.count == 2)
		store.remove(invite: real)
		#expect(store.pending.map(\.invite) == [decoy])
	}

	@Test func nfcAndNfdInvitesAreBothKept() {
		let store = store()
		let composed = invite(1, name: "Caf\u{E9}")
		let decomposed = invite(1, name: "Cafe\u{301}")
		#expect(store.add(composed, from: 10, notify: false))
		#expect(store.add(decomposed, from: 10, notify: false))
		#expect(store.pending.count == 2)
		#expect(Set(store.pending.map(\.id)).count == 2)
	}

	@Test func onePersonCantFloodInvites() {
		let store = store()
		for seed in 1...UInt8(GroupInviteStore.maxPerSender) {
			#expect(store.add(invite(seed), from: 10, notify: false))
		}
		#expect(!store.add(invite(50), from: 10, notify: false))
		#expect(store.add(invite(51), from: 11, notify: false))
	}

	@Test func aFullListRefusesNewInvitesInsteadOfDroppingOldOnes() {
		let store = store()
		let first = invite(1)
		#expect(store.add(first, from: 1, notify: false))
		for seed in 2...UInt8(GroupInviteStore.maxPending) {
			#expect(store.add(invite(seed), from: Int64(seed), notify: false))
		}
		#expect(!store.add(invite(200), from: 200, notify: false))
		#expect(store.pending.count == GroupInviteStore.maxPending)
		#expect(store.pending.contains { $0.invite == first })
	}

	/// On the monotonic clock, so a clock set back can't hold notifications off.
	@Test func notificationsAreThrottled() {
		let store = store()
		let now = ContinuousClock.now
		for _ in 0..<GroupInviteStore.maxNotificationsPerHour {
			#expect(store.mayNotify(now: now))
		}
		#expect(!store.mayNotify(now: now + .seconds(60)))
		#expect(store.mayNotify(now: now + .seconds(60 * 60 + 1)))
	}

	@Test func aFloodOnlyPushesOutTheFloodersOwnInvites() {
		let store = store()
		// Seven node numbers fill the list.
		var seed: UInt8 = 1
		for sender in 1...7 {
			for _ in 0..<GroupInviteStore.maxPerSender where store.pending.count < GroupInviteStore.maxPending {
				#expect(store.add(invite(seed), from: Int64(sender), notify: false))
				seed += 1
			}
		}
		#expect(store.pending.count == GroupInviteStore.maxPending)
		// A flooder can't add more; someone new gets in, in place of a flooder's oldest invite.
		#expect(!store.add(invite(100), from: 1, notify: false))
		#expect(store.add(invite(101), from: 50, notify: false))
		#expect(store.pending.count == GroupInviteStore.maxPending)
		#expect(store.pending.contains { $0.invite == invite(101) })
		#expect(!store.pending.contains { $0.invite == invite(1) })
	}

	@Test func oldInvitesExpire() {
		let clock = FakeClock()
		let defaults = defaults()
		let store = store(clock, defaults: defaults)
		for seed in 1...UInt8(GroupInviteStore.maxPending) {
			#expect(store.add(invite(seed), from: Int64(seed), notify: false))
		}
		#expect(!store.add(invite(200), from: 200, notify: false))
		// A week and a day later the junk is gone and a real invite gets in.
		clock.pass(8 * Self.day)
		#expect(store.add(invite(201), from: 201, notify: false))
		#expect(store.pending.map(\.invite) == [invite(201)])
		// And that's what a relaunch finds.
		#expect(self.store(clock, defaults: defaults).pending.map(\.invite) == [invite(201)])
	}

	/// The clock a year ahead, then put right, then a year behind: none of it counts.
	@Test func settingTheClockDoesntChangeHowLongAnInviteWaits() throws {
		let clock = FakeClock()
		let store = store(clock)
		clock.setWall(by: Self.year)
		#expect(store.add(invite(1), from: 10, notify: false))
		clock.setWall(by: -Self.year)
		store.advance()
		clock.setWall(by: -Self.year)
		store.advance()
		clock.pass(Self.day)
		store.advance()
		let kept = try #require(store.pending.first)
		#expect(abs(kept.age - Self.day) < 1)
		clock.pass(5.5 * Self.day)
		store.advance()
		#expect(store.pending.count == 1)
		clock.pass(Self.day)
		store.advance()
		#expect(store.pending.isEmpty)
	}

	/// It came while the clock was a year behind, and then the clock was put right.
	@Test func anInviteFromWhileTheClockWasBehindIsKept() {
		let clock = FakeClock()
		let store = store(clock)
		clock.setWall(by: -Self.year)
		#expect(store.add(invite(1), from: 10, notify: false))
		clock.setWall(by: Self.year)
		clock.pass(60)
		store.advance()
		#expect(store.pending.count == 1)
		#expect(store.pending.first.map { abs($0.age - 60) < 1 } == true)
	}

	/// Across a restart only the wall clock is left: it's trusted for a day at most.
	@Test func aRestartWithTheClockFarAheadAgesInvitesByADayAtMost() {
		let clock = FakeClock()
		let defaults = defaults()
		#expect(store(clock, defaults: defaults).add(invite(1), from: 10, notify: false))
		clock.restart(after: 60, wallOffBy: Self.year)
		let pending = store(clock, defaults: defaults).pending
		#expect(pending.count == 1)
		#expect(pending.first.map { $0.age <= GroupInviteStore.maxRestartGap } == true)
	}

	@Test func aRestartWithTheClockBehindDoesntAgeInvites() {
		let clock = FakeClock()
		let defaults = defaults()
		let first = store(clock, defaults: defaults)
		#expect(first.add(invite(1), from: 10, notify: false))
		clock.pass(2 * Self.day)
		first.advance()
		clock.restart(after: 60, wallOffBy: -Self.year)
		let pending = store(clock, defaults: defaults).pending
		#expect(pending.count == 1)
		#expect(pending.first.map { abs($0.age - 2 * Self.day) < 1 } == true)
	}

	/// A relaunch without a restart carries on counting from where the last one left off.
	@Test func aRelaunchCarriesOnCounting() {
		let clock = FakeClock()
		let defaults = defaults()
		#expect(store(clock, defaults: defaults).add(invite(1), from: 10, notify: false))
		clock.pass(3 * Self.day)
		let relaunched = store(clock, defaults: defaults)
		#expect(relaunched.pending.first.map { abs($0.age - 3 * Self.day) < 1 } == true)
		clock.pass(5 * Self.day)
		#expect(store(clock, defaults: defaults).pending.isEmpty)
	}

	private struct Legacy: Codable {
		var invite: GroupInvite
		var fromNum: Int64
		var received: Date
	}

	/// What earlier versions saved: a wall-clock stamp, read once, by the store's clock.
	@Test func invitesSavedByAnEarlierVersionKeepTheirAge() throws {
		let clock = FakeClock()
		let defaults = defaults()
		let wall = clock.reading.wall
		let saved = [
			Legacy(invite: invite(1), fromNum: 10, received: wall.addingTimeInterval(-3 * Self.day)),
			Legacy(invite: invite(2), fromNum: 10, received: wall.addingTimeInterval(Self.year)),
			Legacy(invite: invite(3), fromNum: 10, received: wall.addingTimeInterval(-8 * Self.day))
		]
		defaults.set(try JSONEncoder().encode(saved), forKey: "invites")
		let pending = store(clock, defaults: defaults).pending
		#expect(pending.map(\.invite) == [invite(1), invite(2)])
		#expect(abs(pending[0].age - 3 * Self.day) < 60)
		#expect(pending[1].age == 0)
	}

	/// An earlier version's invite is saved with its age on the first load, so later loads
	/// don't read the stamp again on top of the time counted since.
	@Test func anEarlierVersionsInviteIsAgedOnceAcrossLaunches() throws {
		let clock = FakeClock()
		let defaults = defaults()
		let saved = [Legacy(invite: invite(1), fromNum: 10, received: clock.reading.wall.addingTimeInterval(-3 * Self.day))]
		defaults.set(try JSONEncoder().encode(saved), forKey: "invites")
		let first = store(clock, defaults: defaults).pending
		#expect(first.first.map { abs($0.age - 3 * Self.day) < 1 } == true)
		let data = try #require(defaults.data(forKey: "invites"))
		#expect(String(decoding: data, as: UTF8.self).contains("\"age\""))
		clock.pass(3 * Self.day)
		let second = store(clock, defaults: defaults).pending
		#expect(second.count == 1)
		#expect(second.first.map { abs($0.age - 6 * Self.day) < 1 } == true)
		clock.pass(1.5 * Self.day)
		#expect(store(clock, defaults: defaults).pending.isEmpty)
	}

	// MARK: No boot id (the system doesn't say which boot it is)

	/// Clock toggles with no time passing count for nothing, boot id or not.
	@Test func withoutABootIdSettingTheClockStillChangesNothing() {
		let clock = FakeClock()
		clock.reading.boot = nil
		let store = store(clock)
		#expect(store.add(invite(1), from: 10, notify: false))
		for toggle in 0..<20 {
			clock.setWall(by: toggle.isMultiple(of: 2) ? Self.year : -Self.year)
			store.advance()
		}
		#expect(store.pending.count == 1)
		#expect(store.pending.first?.age == 0)
	}

	@Test func withoutABootIdTimeSinceBootStillCounts() {
		let clock = FakeClock()
		clock.reading.boot = nil
		let store = store(clock)
		#expect(store.add(invite(1), from: 10, notify: false))
		clock.pass(8 * Self.day)
		store.advance()
		#expect(store.pending.isEmpty)
	}

	/// Time since boot went back: that's a restart, counted by the wall clock, a day at most.
	@Test func withoutABootIdARestartIsBounded() {
		let clock = FakeClock()
		clock.reading.boot = nil
		let defaults = defaults()
		#expect(store(clock, defaults: defaults).add(invite(1), from: 10, notify: false))
		clock.reading.sinceBoot = 30 * 1_000_000_000
		clock.reading.wall += 3 * Self.day
		let pending = store(clock, defaults: defaults).pending
		#expect(pending.first.map { abs($0.age - GroupInviteStore.maxRestartGap) < 1 } == true)
	}

	/// The boot id was readable, then isn't: time since boot that went forward still counts, not the wall clock.
	@Test func aBootIdThatGoesMissingCountsTimeSinceBoot() {
		let clock = FakeClock()
		let store = store(clock)
		#expect(store.add(invite(1), from: 10, notify: false))
		clock.reading.boot = nil
		clock.reading.wall += Self.year
		clock.reading.sinceBoot += 3600 * 1_000_000_000
		store.advance()
		#expect(store.pending.first.map { abs($0.age - 3600) < 1 } == true)
	}

	@Test func whenItCameIsShownFromItsAge() throws {
		let clock = FakeClock()
		let store = store(clock)
		#expect(store.add(invite(1), from: 10, notify: false))
		clock.pass(2 * 60 * 60)
		store.advance()
		let pending = try #require(store.pending.first)
		#expect(abs(store.received(pending).timeIntervalSince(clock.reading.wall) + 2 * 60 * 60) < 1)
	}

	/// An earlier version listed invites to a key anyone could read (the default key written
	/// out): they're dropped when the list loads, and can't be added or joined.
	@Test func anEarlierVersionsInviteToAPublicKeyIsDropped() async throws {
		var publicKey = Data([0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59, 0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69])
		publicKey.append(0x05)
		let open = GroupInvite(name: "Hike", psk: publicKey)
		let good = invite(1)
		let defaults = defaults()
		let clock = FakeClock()
		let saved = [Legacy(invite: open, fromNum: 10, received: clock.reading.wall), Legacy(invite: good, fromNum: 11, received: clock.reading.wall)]
		defaults.set(try JSONEncoder().encode(saved), forKey: "invites")
		#expect(store(clock, defaults: defaults).pending.map(\.invite) == [good])
		let data = try #require(defaults.data(forKey: "invites"))
		#expect(try JSONDecoder().decode([GroupInviteStore.Pending].self, from: data).map(\.invite) == [good])
		#expect(!GroupInvite.isJoinable(open))
		#expect(GroupInvite.isJoinable(good))
		let store = store()
		#expect(!store.add(open, from: 12, notify: false))
		#expect(store.pending.isEmpty)
		#expect(throws: GroupChatError.cantShareKey) { try GroupChats.joinCheck(open) }
		#expect(throws: Never.self) { try GroupChats.joinCheck(good) }
		// Refused by `join` itself, before it looks for a radio.
		let manager = AccessoryManager(transports: [])
		MqttClientProxyManager.shared.delegate = AccessoryManager.shared
		await #expect(throws: GroupChatError.cantShareKey) { try await GroupChats.join(open, accessoryManager: manager) }
		await #expect(throws: GroupChatError.notConnected) { try await GroupChats.join(good, accessoryManager: manager) }
	}

	/// Saved invites with one in the middle that can't be read (a bad key), as JSON.
	private func mixedBlob() throws -> Data {
		let good = [GroupInviteStore.Pending(invite: invite(1, name: "Good"), fromNum: 10), GroupInviteStore.Pending(invite: invite(2, name: "Good2"), fromNum: 11)]
		var entries = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [[String: Any]])
		var bad = entries[0]
		bad["invite"] = ["name": "Bad", "psk": "not base64!"]
		entries.insert(bad, at: 1)
		return try JSONSerialization.data(withJSONObject: entries)
	}

	/// A store that has run before (its clock is saved), so nothing but the load itself happens.
	private func usedDefaults() -> UserDefaults {
		let defaults = defaults()
		_ = store(FakeClock(), defaults: defaults)
		return defaults
	}

	/// One entry that can't be read loses only itself. The saved list is copied aside
	/// first, and isn't written over just because of it.
	@Test(.timeLimit(.minutes(1)))
	func oneUnreadableInviteLosesOnlyItself() throws {
		let defaults = usedDefaults()
		let blob = try mixedBlob()
		defaults.set(blob, forKey: "invites")
		let clock = FakeClock()
		let store = store(clock, defaults: defaults)
		#expect(store.pending.map(\.invite.name) == ["Good", "Good2"])
		#expect(defaults.data(forKey: "invites.unreadable") == blob)
		#expect(defaults.data(forKey: "invites") == blob)
		#expect(store.add(invite(3, name: "New"), from: 12, notify: false))
		#expect(store.pending.map(\.invite.name) == ["New", "Good", "Good2"])
		#expect(defaults.data(forKey: "invites.unreadable") == blob)
		// Loaded again: the same copy isn't kept twice.
		_ = self.store(clock, defaults: defaults)
		#expect(defaults.data(forKey: "invites.unreadable.2") == nil)
	}

	/// Saved data that isn't a list at all: nothing loads, it's kept aside, and the
	/// saved data stays as it was until something really changes.
	@Test(arguments: [Data("{}".utf8), Data([0xde, 0xad, 0xbe, 0xef])])
	func unreadableSavedInvitesAreKeptAside(data: Data) {
		let defaults = usedDefaults()
		defaults.set(data, forKey: "invites")
		let store = store(FakeClock(), defaults: defaults)
		#expect(store.pending.isEmpty)
		#expect(defaults.data(forKey: "invites.unreadable") == data)
		#expect(defaults.data(forKey: "invites") == data)
	}

	/// Copies that differ are kept, the latest few: once every slot is used,
	/// the oldest goes, so what's about to be saved over always has a copy.
	@Test func theLatestUnreadableListsAreKept() {
		let defaults = usedDefaults()
		let blobs = (1...4).map { Data("not a list \($0)".utf8) }
		let slots = ["invites.unreadable", "invites.unreadable.2", "invites.unreadable.3"]
		for (index, blob) in blobs.enumerated() {
			defaults.set(blob, forKey: "invites")
			#expect(store(FakeClock(), defaults: defaults).add(invite(UInt8(index + 1), name: "New \(index)"), from: 12, notify: false))
			// Saved over, but not before it was kept.
			#expect(defaults.data(forKey: "invites") != blob)
			#expect(slots.contains { defaults.data(forKey: $0) == blob })
		}
		#expect(defaults.data(forKey: "invites.unreadable") == blobs[1])
		#expect(defaults.data(forKey: "invites.unreadable.2") == blobs[2])
		#expect(defaults.data(forKey: "invites.unreadable.3") == blobs[3])
		#expect(defaults.data(forKey: "invites.unreadable.4") == nil)
		#expect(!slots.contains { defaults.data(forKey: $0) == blobs[0] })
	}

	/// A copy already kept, in any slot, isn't kept again, and doesn't push out the oldest.
	@Test func aListAlreadyKeptIsntKeptAgain() {
		let defaults = usedDefaults()
		let blobs = (1...3).map { Data("not a list \($0)".utf8) }
		for blob in blobs {
			defaults.set(blob, forKey: "invites")
			_ = store(FakeClock(), defaults: defaults)
		}
		for blob in [blobs[0], blobs[2]] {
			defaults.set(blob, forKey: "invites")
			_ = store(FakeClock(), defaults: defaults)
		}
		#expect(defaults.data(forKey: "invites.unreadable") == blobs[0])
		#expect(defaults.data(forKey: "invites.unreadable.2") == blobs[1])
		#expect(defaults.data(forKey: "invites.unreadable.3") == blobs[2])
	}

	/// Something saved under the key that isn't data at all is kept aside too, before
	/// the first invite is saved over it; Data and other values sit side by side in the slots.
	@Test func aSavedValueThatIsntDataIsKeptAside() {
		let defaults = usedDefaults()
		defaults.set("garbage string", forKey: "invites")
		let store = store(FakeClock(), defaults: defaults)
		#expect(store.pending.isEmpty)
		#expect(store.add(invite(1, name: "New"), from: 12, notify: false))
		#expect(defaults.string(forKey: "invites.unreadable") == "garbage string")
		// Loaded again: kept once.
		defaults.set("garbage string", forKey: "invites")
		_ = self.store(FakeClock(), defaults: defaults)
		#expect(defaults.object(forKey: "invites.unreadable.2") == nil)
		// Then a list that is data but can't be read, and an array.
		defaults.set(Data("not a list".utf8), forKey: "invites")
		_ = self.store(FakeClock(), defaults: defaults)
		defaults.set(["a", "b"], forKey: "invites")
		_ = self.store(FakeClock(), defaults: defaults)
		#expect(defaults.string(forKey: "invites.unreadable") == "garbage string")
		#expect(defaults.data(forKey: "invites.unreadable.2") == Data("not a list".utf8))
		#expect(defaults.stringArray(forKey: "invites.unreadable.3") == ["a", "b"])
	}

	/// Forgetting the radio deletes the copies kept aside as well: they hold its groups' keys.
	@Test func forgetClearsInviteBackupsToo() throws {
		let defaults = usedDefaults()
		let blob = try mixedBlob()
		defaults.set(Data("older 1".utf8), forKey: "invites.unreadable.2")
		defaults.set(Data("older 2".utf8), forKey: "invites.unreadable.3")
		defaults.set(blob, forKey: "invites")
		let store = store(FakeClock(), defaults: defaults)
		#expect(store.pending.map(\.invite.name) == ["Good", "Good2"])
		#expect(defaults.data(forKey: "invites.unreadable") == blob)
		store.removeAll()
		for key in store.unreadableKeys {
			#expect(defaults.object(forKey: key) == nil, "\(key)")
		}
		#expect(defaults.object(forKey: "invites.unreadable.2") == nil)
		#expect(defaults.object(forKey: "invites.unreadable.3") == nil)
		#expect(self.store(FakeClock(), defaults: defaults).pending.isEmpty)
	}

	/// Everything readable: no copy.
	@Test func readableInvitesLeaveNoCopy() {
		let defaults = usedDefaults()
		let clock = FakeClock()
		#expect(store(clock, defaults: defaults).add(invite(1), from: 10, notify: false))
		#expect(store(clock, defaults: defaults).pending.count == 1)
		#expect(defaults.object(forKey: "invites.unreadable") == nil)
	}

	@Test func joiningClearsTheInvite() {
		let store = store()
		store.add(invite(1), from: 10, notify: false)
		store.add(invite(2), from: 10, notify: false)
		store.remove(invite: invite(1))
		#expect(store.pending.map(\.invite) == [invite(2)])
		store.removeAll()
		#expect(store.pending.isEmpty)
	}
}

@Suite("Groups already joined")
@MainActor
struct ExistingGroupTests {

	/// A store of the suite's own; nothing in it is ever saved. Held here because objects
	/// lose their values once their container is gone.
	private let container = PangeaTestStore.make()
	private var context: ModelContext { container.mainContext }

	private func channel(_ index: Int32, _ name: String, psk: Data) -> ChannelEntity {
		let channel = context.add(ChannelEntity())
		channel.index = index
		channel.role = index == 0 ? 1 : 2
		channel.name = name
		channel.psk = psk
		return channel
	}

	private func myInfo(channels: [(index: Int32, name: String, psk: Data)]) -> MyInfoEntity {
		let info = context.add(MyInfoEntity())
		info.channels = channels.map { item in
			let channel = context.add(ChannelEntity())
			channel.index = item.index
			channel.role = 2
			channel.name = item.name
			channel.psk = item.psk
			return channel
		}
		return info
	}

	private let key = Data(repeating: 4, count: 32)

	@Test func sameKeyAndNameIsTheSameGroup() {
		let info = myInfo(channels: [(1, "Hike", key)])
		#expect(GroupChats.existing(GroupInvite(name: "Hike", psk: key), in: info)?.index == 1)
	}

	@Test func sameKeyUnderAnotherNameIsADifferentGroup() {
		let info = myInfo(channels: [(1, "Hike", key)])
		#expect(GroupChats.existing(GroupInvite(name: "Hiking", psk: key), in: info) == nil)
	}

	/// "Hike " is heard by a different hash than "Hike", so it isn't the group being joined.
	@Test func aNameThatDiffersOnlyInSpacingIsADifferentGroup() {
		let info = myInfo(channels: [(3, "Hike ", key), (4, "Bike  Group", key)])
		#expect(GroupChats.existing(GroupInvite(name: "Hike", psk: key), in: info) == nil)
		#expect(GroupChats.existing(GroupInvite(name: "Bike Group", psk: key), in: info) == nil)
		#expect(GroupChats.existing(GroupInvite(name: "Hike ", psk: key), in: info)?.index == 3)
	}

	@Test func nfcAndNfdNamesAreDifferentGroups() {
		let info = myInfo(channels: [(1, "Caf\u{E9}", key)])
		#expect(GroupChats.existing(GroupInvite(name: "Cafe\u{301}", psk: key), in: info) == nil)
		#expect(GroupChats.existing(GroupInvite(name: "Caf\u{E9}", psk: key), in: info)?.index == 1)
	}

	/// A channel on no key or the default one is still listed, but nothing of mine goes to
	/// it: anyone who adds a channel of that name can read it.
	@Test(arguments: [Data(), Data([1]), Data(repeating: 3, count: 5)])
	func aChannelWithoutAPrivateKeyIsListedButNotAPangeaGroup(psk: Data) {
		let open = channel(2, "Public2", psk: psk)
		#expect(GroupChats.isChat(open))
		#expect(!GroupChats.isPrivateGroup(open))
		#expect(ProfileRules.route(pkiEncrypted: false, to: Constants.maximumNodeNum, channel: 2, isGroupChat: { _ in GroupChats.isPrivateGroup(open) }) == nil)
		let info = context.add(MyInfoEntity())
		info.channels = [open]
		#expect(GroupChats.groups(in: info).map(\.index) == [2])
	}

	@Test(arguments: [16, 32])
	func aChannelWithAPrivateKeyIsAPangeaGroup(bytes: Int) {
		let group = channel(3, "Hike", psk: Data(repeating: 9, count: bytes))
		#expect(GroupChats.isPrivateGroup(group))
		#expect(ProfileRules.route(pkiEncrypted: false, to: Constants.maximumNodeNum, channel: 3, isGroupChat: { _ in GroupChats.isPrivateGroup(group) }) == .group(3))
		// Everyone Nearby never is, whatever its key.
		#expect(!GroupChats.isPrivateGroup(channel(0, "", psk: Data(repeating: 9, count: bytes))))
	}

	/// A joined channel whose name starts with a lone accent still shows (it draws as a
	/// dotted circle), but isn't offered as an invite. Names that hide or cut text are hidden.
	@Test func aStrayMarkDoesntHideAJoinedChannel() {
		let marked = channel(1, "\u{0301}Hike", psk: key)
		let spaced = channel(2, "Bike \u{0301}x", psk: key)
		let cut = channel(3, "gpio\u{0}x", psk: key)
		let flipped = channel(4, "\u{202E}nimda", psk: key)
		let info = context.add(MyInfoEntity())
		info.channels = [marked, spaced, cut, flipped]
		#expect(GroupChats.groups(in: info).map(\.index) == [1, 2])
		#expect(GroupInvite.shareable(name: "\u{0301}Hike", psk: key) == .failure(.cantShareName))
		#expect(GroupInvite.shareable(name: "Bike \u{0301}x", psk: key) == .failure(.cantShareName))
	}

	@Test func anInviteToAGroupFriendsCantJoinIsNeverSent() async {
		let recipient = context.add(UserEntity())
		recipient.num = 77
		recipient.pkiEncrypted = true
		recipient.publicKey = Data(repeating: 5, count: 32)
		for name in ["Bike  Group", "Bike Group "] {
			await #expect(throws: GroupChatError.cantShareName) {
				try await GroupChats.sendInvite(GroupInvite(name: name, psk: key), to: recipient, accessoryManager: AccessoryManager.shared)
			}
		}
		await #expect(throws: GroupChatError.cantShareKey) {
			try await GroupChats.sendInvite(GroupInvite(name: "Hike", psk: Data([1])), to: recipient, accessoryManager: AccessoryManager.shared)
		}
	}

	/// A channel link opened outside Expert Mode says why it couldn't be added.
	@Test func aRefusedChannelLinkSaysWhy() {
		#expect(SaveChannelQRCode.message(for: GroupChatError.full) == GroupChatError.full.errorDescription)
		#expect(SaveChannelQRCode.message(for: GroupChatError.channelsNotLoaded) == GroupChatError.channelsNotLoaded.errorDescription)
		#expect(SaveChannelQRCode.message(for: AccessoryError.appError("Channel already exists")) == "Failed to save channel configuration")
	}
}

@Suite("Mentions")
@MainActor
struct MentionTests {

	let people = [
		Mentions.Person(name: "Sam Rivera", num: 0x1A2B3C4D),
		Mentions.Person(name: "Sam", num: 0x0000BEEF)
	]

	@Test func linksLongestMatchingName() {
		let result = Mentions.linkify("hey @Sam Rivera, lunch?", people: people)
		#expect(result.contains("[@Sam Rivera](pangea://dm/"))
		#expect(result.hasSuffix(", lunch?"))
	}

	@Test func linksShortName() {
		let result = Mentions.linkify("@sam you there", people: people)
		#expect(result.hasPrefix("[@sam](pangea://dm/"))
	}

	@Test func linkedCodeResolvesToThePerson() throws {
		let result = Mentions.linkify("@Sam Rivera", people: people)
		let start = try #require(result.range(of: "(")).upperBound
		let end = try #require(result.range(of: ")")).lowerBound
		let url = try #require(URL(string: String(result[start..<end])))
		#expect(PangeaCode.invite(from: url)?.nodeNum == 0x1A2B3C4D)
	}

	@Test func leavesEmailsAndUnknownNamesAlone() {
		#expect(Mentions.linkify("mail sam@Sam.com", people: people) == "mail sam@Sam.com")
		#expect(Mentions.linkify("@Alex hi", people: people) == "@Alex hi")
		#expect(Mentions.linkify("@Samantha hi", people: people) == "@Samantha hi")
	}

	@Test func leavesExistingLinksAlone() {
		let markdown = "[@Sam](https://example.com)"
		#expect(Mentions.linkify(markdown, people: people) == markdown)
	}

	@Test func leavesLinkTargetsAlone() {
		// Upstream turns URLs into [url](url); the "@sam" in the target must survive.
		let markdown = "see [https://mastodon.social/@sam](https://mastodon.social/@sam) ok @Sam"
		let result = Mentions.linkify(markdown, people: people)
		#expect(result.hasPrefix("see [https://mastodon.social/@sam](https://mastodon.social/@sam) ok [@Sam](pangea://dm/"))
	}

	@Test func ambiguousNamesAreNotLinked() {
		let twins = [
			Mentions.Person(name: "Sam Rivera", num: 1),
			Mentions.Person(name: "Sam", num: 2),
			Mentions.Person(name: "SAM", num: 3)
		]
		#expect(Mentions.linkify("@Sam hi", people: twins) == "@Sam hi")
		#expect(Mentions.linkify("@Sam Rivera hi", people: twins).hasPrefix("[@Sam Rivera](pangea://dm/"))
	}

	/// Sending turns ’ into ', so a name typed with a curly quote arrives with a straight one.
	@Test func curlyAndStraightApostrophesMatch() {
		let curly = [Mentions.Person(name: "Sam’s Radio", num: 0x1A2B3C4D)]
		let straight = [Mentions.Person(name: "Sam's Radio", num: 0x1A2B3C4D)]
		#expect(Mentions.linkify("@Sam's Radio hi", people: curly).hasPrefix("[@Sam\\'s Radio](pangea://dm/"))
		#expect(Mentions.linkify("@Sam’s Radio hi", people: straight).hasPrefix("[@Sam’s Radio](pangea://dm/"))
		#expect(Mentions.linkify("@Sam's Radio hi", people: curly).hasSuffix(") hi"))
		// The same name with either quote, on two people, can't tell them apart.
		let both = [Mentions.Person(name: "Sam’s Radio", num: 1), Mentions.Person(name: "Sam's Radio", num: 2)]
		#expect(Mentions.linkify("@Sam's Radio hi", people: both) == "@Sam's Radio hi")
	}

	@Test func codeSpansAreLeftAlone() {
		#expect(Mentions.linkify("`@Sam` is the syntax", people: people) == "`@Sam` is the syntax")
		#expect(Mentions.linkify("``a ` @Sam`` then @Sam", people: people).hasPrefix("``a ` @Sam`` then [@Sam](pangea://dm/"))
		// An unclosed backtick is plain text.
		#expect(Mentions.linkify("` @Sam", people: people).hasPrefix("` [@Sam](pangea://dm/"))
	}

	@Test func codeSpansCloseOnlyOnARunOfTheSameLength() {
		// "```" isn't the closing "`", so the code runs to the last backtick.
		#expect(Mentions.linkify("`a```@Sam`", people: people) == "`a```@Sam`")
		#expect(Mentions.linkify("``a`@Sam`` @Sam", people: people).hasPrefix("``a`@Sam`` [@Sam](pangea://dm/"))
	}

	@Test func markdownInNamesShowsAsTyped() throws {
		let odd = [Mentions.Person(name: "Sam_1*", num: 0x0000BEEF), Mentions.Person(name: "`Ky`", num: 0x0000BEEE)]
		for (text, shown) in [("@Sam_1* hi", "@Sam_1* hi"), ("@`Ky` hi", "@`Ky` hi")] {
			let result = Mentions.linkify(text, people: odd)
			#expect(result.contains("](pangea://dm/"))
			let attributed = try AttributedString(markdown: result)
			#expect(String(attributed.characters) == shown)
			#expect(!attributed.runs.contains { $0.inlinePresentationIntent != nil })
		}
	}

	@Test func aStrayBracketDoesNotHideLaterMentions() {
		#expect(Mentions.linkify("[ oops\n@Sam hi", people: people).hasPrefix("[ oops\n[@Sam](pangea://dm/"))
		#expect(Mentions.linkify("see ](nope @Sam", people: people).contains("[@Sam](pangea://dm/"))
	}

	@Test func bracketsInNamesAreEscaped() {
		let odd = [Mentions.Person(name: "Sam [K]", num: 0x0000BEEF)]
		let result = Mentions.linkify("@Sam [K] hi", people: odd)
		#expect(result.hasPrefix("[@Sam \\[K\\]](pangea://dm/"))
		let attributed = try? AttributedString(markdown: result)
		#expect(attributed.map { String($0.characters) } == "@Sam [K] hi")
	}

	@Test func activeQueryOnlyAtWordStart() {
		#expect(Mentions.activeQuery(in: "hi @Sa") == "Sa")
		#expect(Mentions.activeQuery(in: "@") == "")
		#expect(Mentions.activeQuery(in: "mail me@ex") == nil)
		#expect(Mentions.activeQuery(in: "no mention") == nil)
	}
}

@Suite("Everyone Nearby notifications")
struct EveryoneNotificationTests {

	/// Outside Expert Mode nothing shows the radio's mute for Everyone Nearby, so the bell
	/// alone decides; a mute left on the radio can't silence a bell that shows on.
	@Test func theBellAloneDecidesOutsideExpertMode() {
		#expect(!GroupChats.radioMuteApplies(channelIndex: 0, expertMode: false))
		#expect(GroupChats.mayNotify(channelIndex: 0, expertMode: false, everyoneOn: true))
		#expect(!GroupChats.mayNotify(channelIndex: 0, expertMode: false, everyoneOn: false))
	}

	/// Expert Mode keeps the radio's per-channel mute. Outside it nothing shows a group's
	/// mute either, so one left on the radio can't silence the group.
	@Test func theRadioMuteAppliesOnlyInExpertMode() {
		#expect(GroupChats.radioMuteApplies(channelIndex: 0, expertMode: true))
		#expect(!GroupChats.radioMuteApplies(channelIndex: 1, expertMode: false))
		#expect(GroupChats.radioMuteApplies(channelIndex: 7, expertMode: true))
	}
}
