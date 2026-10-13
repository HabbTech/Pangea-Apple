//
//  ProfileSharingTests.swift
//  MeshtasticTests
//

import Foundation
import Testing
import UIKit
@testable import Meshtastic

@Suite("Profile routing and sharing")
struct ProfileRulesTests {

	private let me: UInt32 = 0x1234
	private let broadcast = Constants.maximumNodeNum
	/// Slots 1 and 2 are Pangea groups; 3 is some other secondary channel.
	private let isGroupChat: (Int32) -> Bool = { $0 == 1 || $0 == 2 }

	@Test func privateDmIsDirect() {
		#expect(ProfileRules.route(pkiEncrypted: true, to: me, channel: 0, isGroupChat: isGroupChat) == .direct)
	}

	@Test func publicChannelIsIgnored() {
		#expect(ProfileRules.route(pkiEncrypted: false, to: broadcast, channel: 0, isGroupChat: isGroupChat) == nil)
		// Addressed to me, but not encrypted to my key: anyone on the public channel can read it.
		#expect(ProfileRules.route(pkiEncrypted: false, to: me, channel: 0, isGroupChat: isGroupChat) == nil)
	}

	@Test func broadcastIsNeverDirect() {
		#expect(ProfileRules.route(pkiEncrypted: true, to: broadcast, channel: 0, isGroupChat: isGroupChat) == nil)
		#expect(ProfileRules.route(pkiEncrypted: true, to: broadcast, channel: 2, isGroupChat: isGroupChat) == .group(2))
	}

	@Test func onlyPangeaGroupsCount() {
		#expect(ProfileRules.route(pkiEncrypted: false, to: broadcast, channel: 1, isGroupChat: isGroupChat) == .group(1))
		#expect(ProfileRules.route(pkiEncrypted: false, to: me, channel: 2, isGroupChat: isGroupChat) == .group(2))
		#expect(ProfileRules.route(pkiEncrypted: false, to: broadcast, channel: 3, isGroupChat: isGroupChat) == nil)
		// Even if something claimed slot 0 was a group, Everyone Nearby never is.
		#expect(ProfileRules.route(pkiEncrypted: false, to: broadcast, channel: 0, isGroupChat: { _ in true }) == nil)
	}

	@Test func privateRepliesOnlyToPeopleITalkTo() {
		#expect(!ProfileRules.mayShare(over: .direct, iMessagedThem: false, inMyGroup: false, savedContact: false))
		#expect(ProfileRules.mayShare(over: .direct, iMessagedThem: true, inMyGroup: false, savedContact: false))
		#expect(ProfileRules.mayShare(over: .direct, iMessagedThem: false, inMyGroup: true, savedContact: false))
		#expect(ProfileRules.mayShare(over: .group(1), iMessagedThem: false, inMyGroup: false, savedContact: false))
	}
}

@Suite("Photo send limits")
struct PhotoSendLimiterTests {

	private let start = ContinuousClock.now
	private let slots = 20
	private let hike = PhotoSendLimiter.Key(audience: .group(channel: 1, key: "1:Hike:9"), version: 7)
	private let camp = PhotoSendLimiter.Key(audience: .group(channel: 2, key: "2:Camp:9"), version: 7)
	private func person(_ num: Int64, version: UInt32 = 7) -> PhotoSendLimiter.Key {
		PhotoSendLimiter.Key(audience: .person(num), version: version)
	}

	/// Everything the limiter hands out, in order.
	private func drain(_ limiter: inout PhotoSendLimiter, at now: ContinuousClock.Instant) -> [(key: PhotoSendLimiter.Key, slot: UInt8)] {
		var out: [(key: PhotoSendLimiter.Key, slot: UInt8)] = []
		while let next = limiter.next(now: now) { out.append(next) }
		return out
	}

	@Test func twoMembersOfAGroupGetOneBroadcast() {
		var limiter = PhotoSendLimiter()
		// Two members ask (or one member and someone claiming to be another): same group, same photo.
		do { let ok = limiter.admit(nil, slotCount: slots, for: hike, now: start); #expect(ok) }
		do { let ok = limiter.admit(nil, slotCount: slots, for: hike, now: start + .seconds(5)); #expect(ok) }
		let sent = drain(&limiter, at: start + .seconds(6))
		#expect(sent.count == slots)
		#expect(Set(sent.map(\.slot)).count == slots)
		#expect(sent.allSatisfy { $0.key == hike })
	}

	@Test func aReaskWhileSendingOnlyAddsWhatsMissing() {
		var limiter = PhotoSendLimiter()
		do { let ok = limiter.admit([0, 1, 2], slotCount: slots, for: hike, now: start); #expect(ok) }
		_ = limiter.next(now: start)
		do { let ok = limiter.admit([1, 2, 9], slotCount: slots, for: hike, now: start + .seconds(3)); #expect(ok) }
		#expect(limiter.queued(for: hike) == [1, 2, 9])
	}

	@Test func spoofedGroupRequestsDontBlockADirectFriend() {
		var limiter = PhotoSendLimiter()
		// Three requests in a group, each claiming a different sender, then a friend's private request.
		for _ in 0..<3 {
			do { let ok = limiter.admit(nil, slotCount: slots, for: hike, now: start); #expect(ok) }
		}
		do { let ok = limiter.admit(nil, slotCount: slots, for: person(42), now: start + .seconds(1)); #expect(ok) }
		// They take turns: the friend's first piece goes second, not after the whole group send.
		let sent = drain(&limiter, at: start + .seconds(2))
		#expect(sent.prefix(2).map(\.key) == [hike, person(42)])
		#expect(sent.filter { $0.key == person(42) }.count == slots)
		#expect(sent.filter { $0.key == hike }.count == slots)
	}

	@Test func groupTrafficCantUseUpThePrivateBudget() {
		// The biggest photo there is, so three of them are the whole class budget.
		let slots = PhotoRequest.maxSlots
		var limiter = PhotoSendLimiter()
		// Every group asks as often as its budget allows.
		for round in 0..<PhotoSendLimiter.photosPerKey {
			for key in [hike, camp] {
				_ = limiter.admit(nil, slotCount: slots, for: key, now: start + .seconds(Double(round)))
			}
			_ = drain(&limiter, at: start + .seconds(Double(round)))
		}
		do { let ok = !limiter.admit(nil, slotCount: slots, for: hike, now: start + .seconds(10)); #expect(ok) }
		// Private requests still have their own.
		for num in 1...Int64(PhotoSendLimiter.photosPerClass) {
			do { let ok = limiter.admit(nil, slotCount: slots, for: person(num), now: start + .seconds(11)); #expect(ok) }
			_ = drain(&limiter, at: start + .seconds(11))
		}
		// And those are capped too, across everyone.
		do { let ok = !limiter.admit(nil, slotCount: slots, for: person(99), now: start + .seconds(12)); #expect(ok) }
	}

	/// The class budget is airtime: slots of an old, big photo still count, but only as
	/// what they are, not as so many copies of a small new one.
	@Test func aSmallNewPhotoIsntShutOutByABigOldOne() {
		var limiter = PhotoSendLimiter()
		// 84 slots of an old version went out, to one person.
		do { let ok = limiter.admit(nil, slotCount: PhotoRequest.maxSlots, for: person(1, version: 1), now: start); #expect(ok) }
		_ = drain(&limiter, at: start)
		// A new 12-slot photo: 84 + 12 is well within 3 big photos' worth.
		do { let ok = limiter.admit(nil, slotCount: 12, for: person(2, version: 2), now: start + .seconds(1)); #expect(ok) }
	}

	@Test func aFullClassBudgetFreesUpOnceTheOldSlotsAgeOut() {
		var limiter = PhotoSendLimiter()
		// 252 slots of an old version, to three people.
		for num in 1...Int64(PhotoSendLimiter.photosPerClass) {
			do { let ok = limiter.admit(nil, slotCount: PhotoRequest.maxSlots, for: person(num, version: 1), now: start); #expect(ok) }
			_ = drain(&limiter, at: start)
		}
		do { let ok = !limiter.admit(nil, slotCount: 12, for: person(9, version: 2), now: start + .seconds(60)); #expect(ok) }
		do { let ok = limiter.admit(nil, slotCount: 12, for: person(9, version: 2), now: start + PhotoSendLimiter.window + .seconds(1)); #expect(ok) }
	}

	@Test func eachGroupAndPersonCanGetThePhotoTwice() {
		var limiter = PhotoSendLimiter()
		for _ in 0..<PhotoSendLimiter.photosPerKey {
			do { let ok = limiter.admit(nil, slotCount: slots, for: person(7), now: start); #expect(ok) }
			_ = drain(&limiter, at: start)
		}
		do { let ok = !limiter.admit(nil, slotCount: slots, for: person(7), now: start + .seconds(60)); #expect(ok) }
		do { let ok = !limiter.admit([3], slotCount: slots, for: person(7), now: start + .seconds(61)); #expect(ok) }
		// Back after the window.
		do { let ok = limiter.admit(nil, slotCount: slots, for: person(7), now: start + PhotoSendLimiter.window + .seconds(1)); #expect(ok) }
	}

	@Test func aNewPhotoGetsANewAllowance() {
		var limiter = PhotoSendLimiter()
		for _ in 0..<PhotoSendLimiter.photosPerKey {
			do { let ok = limiter.admit(nil, slotCount: slots, for: person(7, version: 1), now: start); #expect(ok) }
			_ = drain(&limiter, at: start)
		}
		do { let ok = !limiter.admit(nil, slotCount: slots, for: person(7, version: 1), now: start + .seconds(1)); #expect(ok) }
		do { let ok = limiter.admit(nil, slotCount: slots, for: person(7, version: 2), now: start + .seconds(1)); #expect(ok) }
	}

	@Test func theQueueHasRoomForAFewAtOnce() {
		var limiter = PhotoSendLimiter()
		for num in 1...Int64(PhotoSendLimiter.maxQueued) {
			do { let ok = limiter.admit([0], slotCount: slots, for: person(num), now: start); #expect(ok) }
		}
		do { let ok = !limiter.admit([0], slotCount: slots, for: person(99), now: start); #expect(ok) }
		_ = drain(&limiter, at: start)
		do { let ok = limiter.admit([0], slotCount: slots, for: person(99), now: start + .seconds(1)); #expect(ok) }
	}

	@Test func aStalledSendIsSkippedOnceTheyveGivenUp() {
		var limiter = PhotoSendLimiter()
		do { let ok = limiter.admit(nil, slotCount: slots, for: person(7), now: start); #expect(ok) }
		do { let ok = limiter.next(now: start + PhotoSendLimiter.maxWait + .seconds(1)) == nil; #expect(ok) }
		#expect(limiter.isIdle)
		// Nothing went out, so nothing was charged.
		for _ in 0..<PhotoSendLimiter.photosPerKey {
			do { let ok = limiter.admit(nil, slotCount: slots, for: person(7), now: start + .seconds(300)); #expect(ok) }
			_ = drain(&limiter, at: start + .seconds(300))
		}
	}

	/// Three pieces go out, the fourth finds no radio: it's put back with everything
	/// else queued, uncharged, and once the radio's back every piece goes exactly once.
	@Test func losingTheRadioMidSendKeepsWhatsQueued() throws {
		var limiter = PhotoSendLimiter()
		do { let ok = limiter.admit(nil, slotCount: slots, for: person(7), now: start); #expect(ok) }
		do { let ok = limiter.admit(nil, slotCount: slots, for: hike, now: start); #expect(ok) }
		var went = (0..<3).compactMap { _ in limiter.next(now: start) }
		let fourth = limiter.next(now: start)
		let failed = try #require(fourth)
		limiter.putBack(failed)
		#expect(!limiter.isIdle)
		#expect(limiter.queued(for: failed.key).contains(failed.slot))
		went += drain(&limiter, at: start + .seconds(200))
		for key in [person(7), hike] {
			#expect(went.filter { $0.key == key }.map(\.slot).sorted() == (0..<UInt8(slots)).map { $0 })
		}
		// Only what went counts: each got the photo once, so once more fits, and no more.
		do { let ok = limiter.admit(nil, slotCount: slots, for: person(7), now: start + .seconds(201)); #expect(ok) }
		_ = drain(&limiter, at: start + .seconds(201))
		do { let ok = !limiter.admit([0], slotCount: slots, for: person(7), now: start + .seconds(202)); #expect(ok) }
	}

	/// A request heard while the radio's still connecting waits, uncharged, for as long
	/// as the asker does: all of it goes, in order, once the radio's ready.
	@Test func aRequestHeardWhileConnectingWaitsForTheRadio() {
		var limiter = PhotoSendLimiter()
		do { let ok = limiter.admit(nil, slotCount: slots, for: hike, now: start); #expect(ok) }
		let out = drain(&limiter, at: start + .seconds(200))
		#expect(out.map(\.slot) == (0..<UInt8(slots)).map { $0 })
		#expect(limiter.isIdle)
		// Each sent once: the group can still have the photo once more.
		do { let ok = limiter.admit(nil, slotCount: slots, for: hike, now: start + .seconds(201)); #expect(ok) }
	}

	/// A job that's started expires too, once it's handed nothing out for `maxWait`.
	@Test func aStartedSendHeldUpTooLongIsDropped() {
		for (late, expired) in [(260.0, false), (271.0, true)] {
			var limiter = PhotoSendLimiter()
			do { let ok = limiter.admit(nil, slotCount: slots, for: person(7), now: start); #expect(ok) }
			#expect(limiter.next(now: start)?.slot == 0)
			#expect(limiter.next(now: start + .seconds(30))?.slot == 1)
			let next = limiter.next(now: start + .seconds(late))
			#expect((next == nil) == expired, "\(late)")
			#expect(limiter.isIdle == expired, "\(late)")
		}
	}

	/// Putting back a job's last piece brings the job back, with only that piece, and
	/// hands its airtime back; other jobs are left as they were.
	@Test func puttingBackALastPieceBringsItsJobBack() throws {
		var limiter = PhotoSendLimiter()
		do { let ok = limiter.admit([0, 1], slotCount: 2, for: person(7), now: start); #expect(ok) }
		do { let ok = limiter.admit(nil, slotCount: slots, for: hike, now: start); #expect(ok) }
		var handed: [(key: PhotoSendLimiter.Key, slot: UInt8)] = []
		while handed.filter({ $0.key == person(7) }).count < 2, let next = limiter.next(now: start) { handed.append(next) }
		let last = try #require(handed.last)
		#expect(last.key == person(7))
		#expect(limiter.queued(for: person(7)).isEmpty)
		let hikeBefore = limiter.queued(for: hike)
		limiter.putBack(last)
		#expect(limiter.queued(for: person(7)) == [last.slot])
		#expect(limiter.queued(for: hike) == hikeBefore)
		// Sent: slot 0 once, slot 1 once more now. Two whole photos fit, a third doesn't.
		_ = drain(&limiter, at: start + .seconds(1))
		do { let ok = limiter.admit(nil, slotCount: 2, for: person(7), now: start + .seconds(2)); #expect(ok) }
		_ = drain(&limiter, at: start + .seconds(2))
		do { let ok = !limiter.admit([0], slotCount: 2, for: person(7), now: start + .seconds(3)); #expect(ok) }
	}

	/// What the sender does when one person can't be sent to (their key is gone, or that
	/// one send failed): only their job ends, and the group still gets every piece.
	@Test func onePersonWithoutAKeyDoesntStopTheOthers() throws {
		var limiter = PhotoSendLimiter()
		do { let ok = limiter.admit(nil, slotCount: slots, for: person(7), now: start); #expect(ok) }
		do { let ok = limiter.admit(nil, slotCount: slots, for: hike, now: start); #expect(ok) }
		var groupSlots: [UInt8] = []
		while let next = limiter.next(now: start) {
			if next.key == person(7) {
				limiter.cancel(next.key, unsent: next.slot)
			} else {
				groupSlots.append(next.slot)
			}
		}
		#expect(groupSlots.sorted() == (0..<slots).map { UInt8($0) })
		// Nothing was charged to person 7: the slot handed out didn't go.
		for _ in 0..<PhotoSendLimiter.photosPerKey {
			do { let ok = limiter.admit(nil, slotCount: slots, for: person(7), now: start + .seconds(5)); #expect(ok) }
			_ = drain(&limiter, at: start + .seconds(5))
		}
	}

	/// A job's last piece, while it's out, keeps the job's place: putting it back never
	/// makes more than `maxQueued` wait. Once it went, the place is free.
	@Test func aPieceOutKeepsItsJobsPlace() throws {
		for went in [false, true] {
			var limiter = PhotoSendLimiter()
			do { let ok = limiter.admit([0], slotCount: 4, for: person(1), now: start); #expect(ok) }
			let first = limiter.next(now: start)
			let handed = try #require(first)
			#expect(limiter.isIdle)
			for num in 2...Int64(PhotoSendLimiter.maxQueued) {
				do { let ok = limiter.admit(nil, slotCount: 4, for: person(num), now: start + .seconds(1)); #expect(ok) }
			}
			if went {
				limiter.delivered(handed.key)
				do { let ok = limiter.admit(nil, slotCount: 4, for: person(99), now: start + .seconds(1)); #expect(ok) }
			} else {
				do { let ok = !limiter.admit(nil, slotCount: 4, for: person(99), now: start + .seconds(1)); #expect(ok) }
				limiter.putBack(handed)
				#expect(limiter.queued(for: person(1)) == [0])
			}
			#expect(limiter.queuedCount == PhotoSendLimiter.maxQueued, "\(went)")
		}
	}

	/// Asked again for pieces already queued (the radio's away, say): they're still
	/// waiting, so the job isn't dropped as given up `maxWait` after the first ask.
	@Test func aReaskWhileParkedCountsAsProgress() {
		var limiter = PhotoSendLimiter()
		do { let ok = limiter.admit(nil, slotCount: 4, for: person(1), now: start); #expect(ok) }
		do { let ok = limiter.admit(nil, slotCount: 4, for: person(1), now: start + .seconds(200)); #expect(ok) }
		let afterReask = limiter.next(now: start + .seconds(241))
		#expect(afterReask?.slot == 0)
		// Nothing heard from them after that: dropped `maxWait` later.
		let late = limiter.next(now: start + .seconds(241) + PhotoSendLimiter.maxWait + .seconds(1))
		#expect(late == nil)
		#expect(limiter.isIdle)
	}

	@Test func requestsForNothingAreIgnored() {
		var limiter = PhotoSendLimiter()
		do { let ok = !limiter.admit([], slotCount: slots, for: person(7), now: start); #expect(ok) }
		do { let ok = !limiter.admit([40, 50], slotCount: slots, for: person(7), now: start); #expect(ok) }
		do { let ok = !limiter.admit(nil, slotCount: 0, for: person(7), now: start); #expect(ok) }
		#expect(limiter.isIdle)
	}

	@Test func fullBitmapCountsAsAFullRequest() {
		var limiter = PhotoSendLimiter()
		let everything = Set((0..<84).map { UInt8($0) })
		do { let ok = limiter.admit(everything, slotCount: slots, for: person(7), now: start); #expect(ok) }
		do { let ok = drain(&limiter, at: start).count == slots; #expect(ok) }
	}
}

@Suite("Profile file")
@MainActor
struct ProfileFileTests {

	private func folder() -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	}

	@Test func unreadableFileIsSetAsideNotOverwritten() throws {
		let folder = folder()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let garbage = Data("{\"me\": 12".utf8)
		try garbage.write(to: folder.appendingPathComponent("profiles.json"))

		let store = ProfileStore(folder: folder)
		#expect(store.me == MyProfile())
		store.setNickname("Bear", for: 5)

		#expect(try Data(contentsOf: folder.appendingPathComponent("profiles.corrupt.json")) == garbage)
		#expect(ProfileStore(folder: folder).profile(5)?.nickname == "Bear")
	}

	@Test func fileWithMissingFieldsStillLoads() throws {
		let folder = folder()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		// No groupSends, a contact with only a nickname, and a field from some later version.
		let json = #"{"me":{"displayName":"Sam","futureField":true},"contacts":[42,{"nickname":"Bear"}]}"#
		try Data(json.utf8).write(to: folder.appendingPathComponent("profiles.json"))

		let store = ProfileStore(folder: folder)
		#expect(store.me.displayName == "Sam")
		#expect(store.me.photoVersion == 0)
		#expect(store.profile(42)?.nickname == "Bear")
		#expect(store.profile(42)?.sentCardVersion == 0)
		#expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("profiles.corrupt.json").path))
	}

	/// My own emoji is held to the rule every receiver applies, so what I see on my avatar
	/// is what they see: older versions took any text.
	@Test(arguments: [("\u{2764}", ""), ("\u{2122}", ""), ("hi", ""), ("🏄🏻‍♂️", "🏄🏻‍♂️"), ("🦊", "🦊")])
	func myEmojiIsCleanedWhenLoaded(saved: String, loaded: String) throws {
		let folder = folder()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let json = try JSONSerialization.data(withJSONObject: ["me": ["displayName": "Sam", "emoji": saved]])
		try json.write(to: folder.appendingPathComponent("profiles.json"))
		#expect(ProfileStore(folder: folder).me.emoji == loaded)
		#expect(ProfileCard.cleanEmoji(saved) == loaded)
	}

	@Test func myEmojiIsCleanedWhenSet() {
		let store = ProfileStore(folder: folder())
		store.updateMe(displayName: "Sam", emoji: "\u{2122}", color: 0, photo: nil)
		#expect(store.me.emoji == "")
		store.updateMe(displayName: "Sam", emoji: "🦊", color: 0, photo: nil)
		#expect(store.me.emoji == "🦊")
	}

	@Test func avatarHasNoAlphaAndStaysUpright() throws {
		// Red on top, blue below.
		let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
			UIColor.red.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
			UIColor.blue.setFill()
			context.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
		}
		let square = try #require(PhotoCompressor.square(image, side: 100, pixels: 16))
		#expect(square.alphaInfo == .noneSkipLast)

		let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
											 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
		context.draw(square, in: CGRect(x: 0, y: 0, width: 16, height: 16))
		let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
		// Row 0 of the buffer is the top of the image.
		let top = (pixels[0], pixels[2])
		let bottom = (pixels[15 * 64], pixels[15 * 64 + 2])
		#expect(top.0 > 200 && top.1 < 60)
		#expect(bottom.0 < 60 && bottom.1 > 200)
	}
}

@Suite("Photo requests and pieces")
struct PhotoRequestRouteTests {

	@Test func askInsideASharedGroupUnlessTheyMessagedMe() {
		// They've DM'd me: their app accepts my private request.
		#expect(ProfileRules.requestRoute(canReachDirectly: true, theyMessagedMe: true, sharedGroup: 2) == .direct)
		// Only a shared group: a private request would be dropped, the group one isn't.
		#expect(ProfileRules.requestRoute(canReachDirectly: true, theyMessagedMe: false, sharedGroup: 2) == .group(2))
		#expect(ProfileRules.requestRoute(canReachDirectly: false, theyMessagedMe: false, sharedGroup: 3) == .group(3))
		#expect(ProfileRules.requestRoute(canReachDirectly: true, theyMessagedMe: false, sharedGroup: nil) == .direct)
		#expect(ProfileRules.requestRoute(canReachDirectly: false, theyMessagedMe: false, sharedGroup: nil) == nil)
	}

	@Test func extraPiecesDontStopAssembly() {
		let photo = Data(repeating: 3, count: 400)
		var chunks: [UInt8: Data] = [:]
		for chunk in PhotoChunk.split(photo) { chunks[chunk.index] = chunk.bytes }
		chunks[40] = Data([9])
		#expect(PhotoChunk.assemble(chunks, count: UInt8(PhotoChunk.split(photo).count), version: PangeaWire.hash(photo)) == photo)
	}
}

@Suite("Photo downloads")
struct PhotoDownloadTests {

	/// A photo of 50 pieces: 3 manifest parts, then the pieces.
	private let photo = Data((0..<(PhotoChunk.maxBytes * 49 + 77)).map { UInt8(($0 * 7) % 251) })
	private var pieces: PhotoPieces { PhotoPieces(photo: photo)! }
	private var card: ProfileCard { ProfileCard(displayName: "Sam", emoji: "", color: 0, photo: pieces) }

	private func forged(_ index: UInt8, count: Int = 1) -> PhotoChunk {
		PhotoChunk(photoVersion: pieces.version, index: index, bytes: Data(repeating: 0xEE, count: count))
	}

	@Test func everythingCheckedInOrderCompletes() throws {
		var download = try #require(PhotoDownload(card: card))
		#expect(download.slotCount == pieces.slotCount)
		#expect(download.missingSlots.count == pieces.slotCount)
		for part in pieces.manifest { do { let ok = download.accept(part) == .added; #expect(ok) } }
		for chunk in pieces.chunks.reversed() { do { let ok = download.accept(chunk) == .added; #expect(ok) } }
		#expect(download.isComplete)
		#expect(download.progress == 1)
		#expect(download.assemble() == photo)
	}

	@Test func aForgedPieceIsNeverKeptAndNothingIsLost() throws {
		var download = try #require(PhotoDownload(card: card))
		for part in pieces.manifest { _ = download.accept(part) }
		for chunk in pieces.chunks.prefix(10) { _ = download.accept(chunk) }
		let before = download.progress
		// A forged copy of a piece already held, and a forged first copy of one not yet here.
		do { let ok = download.accept(forged(3)) == .duplicate; #expect(ok) }
		do { let ok = download.accept(forged(20)) == .ignored; #expect(ok) }
		#expect(download.progress == before)
		#expect(download.missingSlots.contains(UInt8(pieces.manifest.count + 20)))
		// The real ones still finish it, with nothing asked for twice.
		for chunk in pieces.chunks.dropFirst(10) { do { let ok = download.accept(chunk) == .added; #expect(ok) } }
		#expect(download.assemble() == photo)
	}

	@Test func theCountComesFromTheCardNotAPiece() throws {
		var download = try #require(PhotoDownload(card: card))
		// Old-style attack: a piece past the end (the count used to be pinned by the first piece).
		do { let ok = download.accept(forged(79)) == .ignored; #expect(ok) }
		do { let ok = download.accept(PhotoChunk(photoVersion: pieces.version &+ 1, index: 0, bytes: pieces.chunks[0].bytes)) == .ignored; #expect(ok) }
		for part in pieces.manifest { _ = download.accept(part) }
		for chunk in pieces.chunks { _ = download.accept(chunk) }
		#expect(download.assemble() == photo)
	}

	@Test func aForgedManifestIsRejected() throws {
		var download = try #require(PhotoDownload(card: card))
		var fake = pieces.manifest[0]
		fake.tags[0] = PangeaWire.tag(Data([1, 2, 3]))
		do { let ok = download.accept(fake) == .ignored; #expect(ok) }
		// Wrong number of tags for that part.
		var short = pieces.manifest[1]
		short.tags.removeLast()
		do { let ok = download.accept(short) == .ignored; #expect(ok) }
		#expect(download.missingSlots.contains(0))
		do { let ok = download.accept(pieces.manifest[0]) == .added; #expect(ok) }
		do { let ok = download.accept(pieces.manifest[0]) == .duplicate; #expect(ok) }
	}

	@Test func piecesBeforeTheirManifestAreCheckedWhenItComes() throws {
		var download = try #require(PhotoDownload(card: card))
		// The manifest part was lost; pieces 0 and 1 arrive, plus forged copies of 0 and 2.
		do { let ok = download.accept(forged(0)) == .held; #expect(ok) }
		do { let ok = download.accept(pieces.chunks[0]) == .held; #expect(ok) }
		do { let ok = download.accept(pieces.chunks[1]) == .held; #expect(ok) }
		do { let ok = download.accept(forged(2)) == .held; #expect(ok) }
		#expect(download.missingSlots.contains(0)) // the manifest part is asked for again
		do { let ok = download.accept(pieces.manifest[0]) == .added; #expect(ok) }
		// 0 and 1 were the real ones; 2 was forged and is asked for again.
		do { let ok = download.accept(pieces.chunks[0]) == .duplicate; #expect(ok) }
		do { let ok = download.accept(pieces.chunks[1]) == .duplicate; #expect(ok) }
		#expect(download.missingSlots.contains(UInt8(pieces.manifest.count + 2)))
		do { let ok = download.accept(pieces.chunks[2]) == .added; #expect(ok) }
	}

	@Test func floodingAPieceBeforeItsManifestCantShutTheRealOneOut() throws {
		var download = try #require(PhotoDownload(card: card))
		for n in 1...10 { _ = download.accept(forged(5, count: n)) }
		#expect(download.accept(pieces.chunks[5]) == .ignored) // no room while unchecked
		_ = download.accept(pieces.manifest[0])
		// The forgeries fail the check, so the piece is asked for again and then taken.
		#expect(download.missingSlots.contains(UInt8(pieces.manifest.count + 5)))
		do { let ok = download.accept(pieces.chunks[5]) == .added; #expect(ok) }
	}

	@Test func aCardWithoutAPieceListCantBeDownloaded() {
		#expect(PhotoDownload(card: ProfileCard(displayName: "Sam", emoji: "", color: 0, photoVersion: 99)) == nil)
		#expect(PhotoDownload(card: ProfileCard(displayName: "Sam", emoji: "", color: 0, photoVersion: 0)) == nil)
	}

	@Test func requestsNameSlotsAcrossManifestAndPieces() {
		#expect(PhotoRequest.maxSlots == 84)
		let all = Set((0..<84).map { UInt8($0) })
		let request = PhotoRequest(photoVersion: 9, wanted: all)
		#expect(PhotoRequest(payload: request.payload) == request)
		#expect(pieces.payload(slot: 0) == pieces.manifest[0].payload)
		#expect(pieces.payload(slot: UInt8(pieces.manifest.count)) == pieces.chunks[0].payload)
		#expect(pieces.payload(slot: UInt8(pieces.slotCount)) == nil)
	}

	@Test func privateDownloadsOnlyTakePrivatePieces() {
		// Asked privately: a piece heard in a group (where anyone can claim to be them) is ignored.
		#expect(ProfileRules.photoPart(arrivedOver: .direct, fits: .direct))
		#expect(!ProfileRules.photoPart(arrivedOver: .group(1), fits: .direct))
		// Asked in a group: that group's broadcast, or a private copy from them.
		#expect(ProfileRules.photoPart(arrivedOver: .group(1), fits: .group(1)))
		#expect(ProfileRules.photoPart(arrivedOver: .direct, fits: .group(1)))
		#expect(!ProfileRules.photoPart(arrivedOver: .group(2), fits: .group(1)))
	}

	/// Asked in group A in slot 2; A was left and group B joined into slot 2.
	@Test func aGroupDownloadIsTiedToTheGroupNotTheSlot() {
		#expect(ProfileRules.photoPart(arrivedOver: .group(2), fits: .group(2)))
		// Same slot, but not the same group any more: its pieces don't count, and asking
		// again would ask B, so the download is dropped.
		#expect(!ProfileRules.isSameGroup(askedIn: "2:Hike:11", now: "2:Camp:42"))
		#expect(!ProfileRules.isSameGroup(askedIn: "2:Hike:11", now: nil))
		#expect(!ProfileRules.isSameGroup(askedIn: nil, now: "2:Hike:11"))
		#expect(ProfileRules.isSameGroup(askedIn: "2:Hike:11", now: "2:Hike:11"))
	}
}

@Suite("Received profiles")
@MainActor
struct ReceivedProfileTests {

	private func folder() -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	}

	@Test func hiddenCharactersAreStrippedFromNames() throws {
		let card = ProfileCard(displayName: "\u{202E}Sam\u{200B}\u{0} ", emoji: "", color: 0, photoVersion: 0)
		let payload = try #require(card.payload)
		let parsed = try #require(ProfileCard(payload: payload))
		#expect(parsed.displayName == "Sam")
		let blank = ProfileCard(displayName: "\u{200B}\u{200F}", emoji: "", color: 0, photoVersion: 0)
		let blankPayload = try #require(blank.payload)
		#expect(ProfileCard(payload: blankPayload)?.displayName == "")
	}

	@Test func onlyOneRealEmojiIsKept() {
		#expect(ProfileCard.cleanEmoji("🦊") == "🦊")
		#expect(ProfileCard.cleanEmoji("🧑🏻‍🤝‍🧑🏿") == "🧑🏻‍🤝‍🧑🏿")
		#expect(ProfileCard.cleanEmoji("🇺🇸") == "🇺🇸")
		#expect(ProfileCard.cleanEmoji("1️⃣") == "1️⃣")
		#expect(ProfileCard.cleanEmoji("1") == "")
		#expect(ProfileCard.cleanEmoji("#") == "")
		#expect(ProfileCard.cleanEmoji("hi") == "")
		#expect(ProfileCard.cleanEmoji("🦊🦊") == "")
		#expect(ProfileCard.cleanEmoji("") == "")
	}

	@Test func bytesThatArentUTF8AreNoName() throws {
		// Card: color, no photo, no emoji, then a 2-byte name.
		var payload = PangeaWire.cardMagic + Data([0]) + PangeaWire.bytes(UInt32(0))
		payload.append(contentsOf: [0, 2, 0xFF, 0x41])
		let card = try #require(ProfileCard(payload: payload))
		#expect(card.displayName == "")
		var bad = PangeaWire.cardMagic + Data([3]) + PangeaWire.bytes(UInt32(0))
		bad.append(contentsOf: [1, 0xC3, 3])
		bad.append(contentsOf: Array("Sam".utf8))
		let partly = try #require(ProfileCard(payload: bad))
		#expect(partly.emoji == "")
		#expect(partly.displayName == "Sam")
		#expect(partly.color == 3)
		let good = ProfileCard(displayName: "Zoë", emoji: "🦊", color: 0, photoVersion: 0)
		let goodPayload = try #require(good.payload)
		#expect(ProfileCard(payload: goodPayload) == good)
	}

	@Test func blankDisplayNameFallsBackToRadioName() {
		let store = ProfileStore(folder: folder())
		store.receivedCard(ProfileCard(displayName: "\u{200B} ", emoji: "", color: 0, photoVersion: 0), from: 5, channel: nil)
		#expect(store.name(num: 5, radioName: "Radio Sam") == "Radio Sam")
	}

	@Test func aGroupCardCantReplaceAPrivateOne() throws {
		let store = ProfileStore(folder: folder())
		let real = ProfileCard(displayName: "Sam", emoji: "🦊", color: 1, photoVersion: 0)
		#expect(store.receivedCard(real, from: 5, channel: nil))
		// Someone in a group sends a card in Sam's name.
		let fake = ProfileCard(displayName: "Not Sam", emoji: "", color: 2, photoVersion: 0)
		#expect(!store.receivedCard(fake, from: 5, channel: 1, groupKey: "1:Hike:9"))
		#expect(store.profile(5)?.card == real)
		#expect(store.profile(5)?.lastGroupKey == nil)
		// A newer private card still replaces it, and a group-only contact still updates from the group.
		#expect(store.receivedCard(fake, from: 5, channel: nil))
		#expect(store.receivedCard(fake, from: 6, channel: 1, groupKey: "1:Hike:9"))
		#expect(store.receivedCard(real, from: 6, channel: 1, groupKey: "1:Hike:9"))
		#expect(store.profile(6)?.card == real)
	}

	/// Bob's card came privately; a group card under his number can't replace it, so a
	/// different one makes me ask him, privately, and his answer is what's kept.
	@Test func aDifferentGroupCardMakesMeAskPrivately() throws {
		let store = ProfileStore(folder: folder())
		var outbox = ProfileOutbox()
		var random = SeededRandom(seed: 1)
		let now = ContinuousClock.now
		let v1 = ProfileCard(displayName: "Bob", emoji: "🦊", color: 1, photoVersion: 0)
		let v2 = ProfileCard(displayName: "Bobby", emoji: "🐻", color: 1, photoVersion: 0)
		#expect(store.receivedCard(v1, from: 5, channel: nil))
		#expect(!store.receivedCard(v2, from: 5, channel: 1, groupKey: "1:Hike:9"))
		#expect(store.profile(5)?.card == v1)
		#expect(ProfileRules.asksForCard(heard: v2, stored: store.profile(5)?.card, canReachDirectly: true))
		outbox.schedule(.cardAsk(5), reason: .ask, delay: ProfileOutbox.ask, hint: v2, now: now, using: &random)
		let asks = OutboxDrain.run(&outbox, from: now, for: .seconds(61))
		#expect(asks.map(\.entry.item) == [.cardAsk(5)])
		// His private answer.
		#expect(store.receivedCard(v2, from: 5, channel: nil))
		#expect(store.profile(5)?.card == v2)
		// What's checked before an ask goes: now that his card says the same, it isn't asked.
		#expect(!ProfileRules.asksForCard(heard: v2, stored: store.profile(5)?.card, canReachDirectly: true))
	}

	@Test func theSameGroupCardOrNoKeyAsksNothing() {
		let card = ProfileCard(displayName: "Bob", emoji: "", color: 1, photoVersion: 0)
		#expect(!ProfileRules.asksForCard(heard: card, stored: card, canReachDirectly: true))
		// Can't reach him privately (his key went with a node database reset): stale beats forged.
		#expect(!ProfileRules.asksForCard(heard: ProfileCard(displayName: "Bobby", emoji: "", color: 1, photoVersion: 0), stored: card, canReachDirectly: false))
	}

	/// A forged card a second, each one different: Bob is asked once at first, then at most
	/// once per `askRearm`, never more.
	@Test func aStreamOfForgedGroupCardsAsksRarely() {
		var outbox = ProfileOutbox()
		var random = SeededRandom(seed: 2)
		let start = ContinuousClock.now
		var asks: [OutboxDrain.Sent] = []
		var clock = start
		for n in 0..<(30 * 60) {
			let forged = ProfileCard(displayName: "Bob \(n)", emoji: "", color: UInt8(n % 8), photoVersion: 0)
			outbox.schedule(.cardAsk(5), reason: .ask, delay: ProfileOutbox.ask, hint: forged, now: start + .seconds(n), using: &random)
			asks += OutboxDrain.run(&outbox, from: clock, until: start + .seconds(n + 1))
			clock = start + .seconds(n + 1)
		}
		#expect(asks.filter { $0.at < start + ProfileOutbox.askRearm }.count == 1)
		#expect(asks.count <= 6)
		#expect(asks.count >= 2)
		#expect(zip(asks, asks.dropFirst()).allSatisfy { $1.at - $0.at >= ProfileOutbox.askRearm })
	}

	@Test func cardRequestsAreAnsweredOncePerPersonPerWindow() {
		var outbox = ProfileOutbox()
		let start = ContinuousClock.now
		func answer(_ num: Int64, at time: ContinuousClock.Instant) -> Bool {
			outbox.schedule(.card(.person(num)), reason: .answer, delay: 0...0, now: time)
			guard let entry = outbox.take(now: time) else { return false }
			outbox.finish(entry, .sent, at: time)
			return true
		}
		do { let ok = answer(5, at: start); #expect(ok) }
		do { let ok = !answer(5, at: start + .seconds(30)); #expect(ok) }
		do { let ok = answer(6, at: start + .seconds(33)); #expect(ok) }
		// The one held back goes once the window is over, not before.
		do { let ok = outbox.take(now: start + .seconds(9 * 60)) == nil; #expect(ok) }
		do { let ok = outbox.take(now: start + ProfileOutbox.answerInterval)?.item == .card(.person(5)); #expect(ok) }
	}

	@Test func cardRequestsAreOnlyAnsweredToPeopleITalkTo() {
		// The same rule as photo replies: a stranger who found my key gets nothing.
		#expect(!ProfileRules.mayShare(over: .direct, iMessagedThem: false, inMyGroup: false, savedContact: false))
		#expect(ProfileRules.mayShare(over: .direct, iMessagedThem: true, inMyGroup: false, savedContact: false))
		#expect(PangeaWire.cardRequestMagic == Data("PGK1".utf8))
	}

	@Test func storedCardsAreCleanedWhenLoaded() throws {
		let folder = folder()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		// Saved by an earlier version: a hidden override in the name, and an emoji that isn't one.
		let json = #"{"contacts":[5,{"card":{"displayName":"Sam\u202eevil","emoji":"12","color":0,"photoVersion":0}}]}"#
		try Data(json.utf8).write(to: folder.appendingPathComponent("profiles.json"))
		let card = try #require(ProfileStore(folder: folder).profile(5)?.card)
		#expect(card.displayName == "Samevil")
		#expect(card.emoji == "")
	}

	/// Once a day to each group, unless my card changed, or the clock was set back past the
	/// last send (else an unchanged card would never go again).
	@Test func aGroupGetsMyCardDailyWhateverTheClockDoes() {
		let store = ProfileStore(folder: folder())
		let hour: TimeInterval = 60 * 60
		#expect(store.needsGroupSend("1:Hike:9", version: 7))
		store.markGroupSent("1:Hike:9", version: 7)
		#expect(!store.needsGroupSend("1:Hike:9", version: 7, now: Date().addingTimeInterval(hour)))
		#expect(store.needsGroupSend("1:Hike:9", version: 8, now: Date().addingTimeInterval(hour)))
		#expect(store.needsGroupSend("1:Hike:9", version: 7, now: Date().addingTimeInterval(25 * hour)))
		// The last send looks a day in the future: the clock went back.
		#expect(store.needsGroupSend("1:Hike:9", version: 7, now: Date().addingTimeInterval(-24 * hour)))
	}

	@Test func groupCardRemembersWhichGroup() {
		let store = ProfileStore(folder: folder())
		store.receivedCard(ProfileCard(displayName: "Sam", emoji: "", color: 0, photoVersion: 0), from: 5, channel: 2, groupKey: "2:Hike:123")
		#expect(store.profile(5)?.lastChannel == 2)
		#expect(store.profile(5)?.lastGroupKey == "2:Hike:123")
		// Survives a reload.
		let dir = folder()
		let saved = ProfileStore(folder: dir)
		saved.receivedCard(ProfileCard(displayName: "Sam", emoji: "", color: 0, photoVersion: 0), from: 5, channel: 2, groupKey: "2:Hike:123")
		#expect(ProfileStore(folder: dir).profile(5)?.lastGroupKey == "2:Hike:123")
	}

	@Test func oneBadContactDoesNotLoseTheOthers() throws {
		let folder = folder()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		// Contact 7 has a wrong-typed field, 8 isn't even an object, "x" isn't a node number.
		let json = #"{"me":{"displayName":"Sam","color":"red"},"contacts":[42,{"nickname":"Bear"},7,{"nickname":"Wolf","sentCardVersion":"lots"},8,"junk","x",{"nickname":"Nope"},9,{"nickname":"Fox"}]}"#
		try Data(json.utf8).write(to: folder.appendingPathComponent("profiles.json"))

		let store = ProfileStore(folder: folder)
		#expect(store.me.displayName == "Sam")
		#expect(store.me.color == 0)
		#expect(store.profile(42)?.nickname == "Bear")
		#expect(store.profile(7)?.nickname == "Wolf")
		#expect(store.profile(7)?.sentCardVersion == 0)
		#expect(store.profile(8) == nil)
		#expect(store.profile(9)?.nickname == "Fox")
		// What couldn't be read is kept in a copy, since the next save leaves it out.
		#expect(try Data(contentsOf: folder.appendingPathComponent("profiles.corrupt.json")) == Data(json.utf8))
		// The good data was saved right away, so the copy isn't made again next launch.
		_ = ProfileStore(folder: folder)
		let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("profiles.corrupt") }
		#expect(copies == ["profiles.corrupt.json"])
		#expect(ProfileStore(folder: folder).profile(42)?.nickname == "Bear")
	}

	@Test(arguments: [
		#"{"me":{"displayName":"Sam"},"contacts":{"42":{"nickname":"Bear"}}}"#,
		#"{"me":"Sam","contacts":[42,{"nickname":"Bear"}]}"#,
		#"{"me":{"displayName":"Sam"},"contacts":[42,{"nickname":"Bear"},7,"junk"]}"#,
		#"{"me":{"displayName":"Sam"},"contacts":[42,{"nickname":"Bear"}],"groupSends":[1,2]}"#
	])
	func aSectionThatCantBeReadIsCopiedAside(json: String) throws {
		let folder = folder()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try Data(json.utf8).write(to: folder.appendingPathComponent("profiles.json"))
		let store = ProfileStore(folder: folder)
		store.setNickname("Fox", for: 9)
		#expect(try Data(contentsOf: folder.appendingPathComponent("profiles.corrupt.json")) == Data(json.utf8))
		#expect(ProfileStore(folder: folder).profile(9)?.nickname == "Fox")
	}

	@Test func aSecondUnreadableFileKeepsTheFirstCopy() throws {
		let folder = folder()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let first = Data("{\"me\": 1".utf8)
		try first.write(to: folder.appendingPathComponent("profiles.json"))
		_ = ProfileStore(folder: folder)
		let second = Data("not json".utf8)
		try second.write(to: folder.appendingPathComponent("profiles.json"))
		_ = ProfileStore(folder: folder)

		#expect(try Data(contentsOf: folder.appendingPathComponent("profiles.corrupt.json")) == first)
		let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
		let others = names.filter { $0.hasPrefix("profiles.corrupt-") }
		#expect(others.count == 1)
		#expect(try others.first.map { try Data(contentsOf: folder.appendingPathComponent($0)) } == second)
	}
}

@Suite("Received photos")
struct ReceivedPhotoTests {

	private func png(width: Int, height: Int) throws -> Data {
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
			UIColor.green.setFill()
			context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		}
		return try #require(image.pngData())
	}

	@Test func onlySmallRealImagesAreKept() throws {
		#expect(PhotoCompressor.isAcceptableAvatar(try png(width: 256, height: 256)))
		#expect(!PhotoCompressor.isAcceptableAvatar(try png(width: 2000, height: 20)))
		#expect(!PhotoCompressor.isAcceptableAvatar(Data(repeating: 7, count: 300)))
		#expect(!PhotoCompressor.isAcceptableAvatar(Data()))
	}

	@Test func decodingIsCappedAtAvatarSize() throws {
		let image = try #require(PhotoCompressor.avatarImage(from: try png(width: 1200, height: 1200)))
		#expect(max(image.size.width * image.scale, image.size.height * image.scale) <= 256)
	}

	@Test func transparentImagesGetAWhiteBackground() throws {
		let format = UIGraphicsImageRendererFormat()
		format.opaque = false
		format.scale = 1
		let clear = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { _ in }
		let square = try #require(PhotoCompressor.square(clear, side: 20, pixels: 8))
		let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
											 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
		context.draw(square, in: CGRect(x: 0, y: 0, width: 8, height: 8))
		let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
		#expect(pixels[0] > 240 && pixels[1] > 240 && pixels[2] > 240)
	}
}


/// The same numbers every run.
struct SeededRandom: RandomNumberGenerator {
	private var state: UInt64

	init(seed: UInt64) { state = seed }

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}

extension ProfileOutbox {
	/// The next outbox entry, with no photo pieces waiting.
	mutating func take(now: Instant) -> Entry? {
		guard case .entry(let entry)? = next(now: now, piecesWaiting: false) else { return nil }
		return entry
	}
}

/// What ProfileSync's lane would put on the air from an outbox, if every send reached the radio.
enum OutboxDrain {
	struct Sent {
		var entry: ProfileOutbox.Entry
		var at: ContinuousClock.Instant
	}

	static func run(_ outbox: inout ProfileOutbox, from start: ContinuousClock.Instant, for duration: Duration) -> [Sent] {
		run(&outbox, from: start, until: start + duration)
	}

	static func run(_ outbox: inout ProfileOutbox, from start: ContinuousClock.Instant, until end: ContinuousClock.Instant) -> [Sent] {
		var sent: [Sent] = []
		var now = start
		while now < end {
			if let entry = outbox.take(now: now) {
				outbox.finish(entry, .sent, at: now)
				sent.append(Sent(entry: entry, at: now))
				continue
			}
			guard let wake = outbox.nextWake(now: now, piecesWaiting: false), wake > now else { break }
			now = wake
		}
		return sent
	}
}

/// ProfileSync's lane on a made-up clock. It drives the real outbox (`next`, `finish`,
/// `nextWake`), a real PhotoSendLimiter, and the real send-time, booking and watchdog rules
/// (`ProfileRules.stillNeeded`, `outcome`, `afterNoRadio`, `PhotoWatchdog`), with the radio
/// coming and going and the app suspended. `requestPhoto`, `deliver`'s radio check, the
/// readiness edges, the watchdog loop, the backoff and the lane's start and pause follow
/// ProfileSync step for step.
final class LaneDrain {
	typealias Instant = ContinuousClock.Instant

	struct Sent {
		var entry: ProfileOutbox.Entry?
		var piece: PhotoSendLimiter.Key?
		var at: Instant
	}

	var outbox = ProfileOutbox()
	var pieces = PhotoSendLimiter()
	let start: Instant
	private(set) var now: Instant
	private var random: SeededRandom
	private(set) var log: [Sent] = []
	/// What `schedule` said no to.
	private(set) var refused: [ProfileOutbox.Item] = []
	/// Linked and done connecting. Down is what a real teardown leaves: no link, no node
	/// number, not subscribed, so nothing that needs the radio can be looked up.
	var radioUp: (Instant) -> Bool = { _ in true }
	/// My own node is known (it isn't, for a while, after a node database reset).
	var myNodeKnown: (Instant) -> Bool = { _ in true }
	/// What a send that got to the radio comes to (a write that fails across a reconnect).
	var sendResult: (Instant) -> ProfileSync.SendResult = { _ in .sent }
	/// How long each write takes; the next packet's spacing counts from when it returns.
	var latency: Duration = .zero
	/// Nothing runs until then, the lane included.
	var suspendedUntil: Instant?
	private(set) var transfers: [Int64: PhotoWatchdog.Clock] = [:]
	private(set) var abandoned: [(num: Int64, at: Instant)] = []
	/// Sends that found no radio.
	private(set) var noRadioAttempts: [Instant] = []
	/// How many times the lane looked at the outbox.
	private(set) var looks = 0
	/// What `AccessoryManager.readiness` would say, through the same reducer.
	private(set) var readiness: RadioReadiness
	/// Every readiness edge, as the funnel would report it.
	private(set) var edges: [(edge: RadioReadiness.Edge, at: Instant)] = []
	private var events: [(at: Instant, run: (LaneDrain) -> Void)] = []
	private var running = false
	private var waitingForRadio = false
	private var backoff: Duration?
	private(set) var backoffUntil: Instant?
	private var napUntil: Instant?
	private var watchdogOn = false
	/// Times the lane got to `deliver` or a piece's radio check: tried to put something on the air.
	private(set) var writeAttempts: [Instant] = []

	init(start: Instant, seed: UInt64) {
		self.start = start
		now = start
		random = SeededRandom(seed: seed)
		readiness = RadioReadiness(now: start)
		refreshReadiness()
	}

	func t(_ seconds: Double) -> Instant { start + .seconds(seconds) }

	func at(_ seconds: Double, _ run: @escaping (LaneDrain) -> Void) {
		at(t(seconds), run)
	}

	private func at(_ time: Instant, _ run: @escaping (LaneDrain) -> Void) {
		let index = events.firstIndex { $0.at > time } ?? events.endIndex
		events.insert((time, run), at: index)
	}

	/// The radio drops at `from` and is back at `to` (seconds), each change reported as
	/// `AccessoryManager` reports its inputs to `readiness`.
	func radioDown(_ from: Double, _ to: Double) {
		let window = t(from)..<t(to)
		let before = radioUp
		radioUp = { !window.contains($0) && before($0) }
		at(from) { $0.refreshReadiness() }
		at(to) { $0.refreshReadiness() }
	}

	/// Linked throughout, but my own node isn't in the database from `from` to `to`; its
	/// row coming and going is seen as `readiness` sees database changes. `reported` false:
	/// nothing reports it (a change the funnel missed), so only a send attempt notices.
	func myNodeMissing(_ from: Double, _ to: Double, reported: Bool = true) {
		let window = t(from)..<t(to)
		let before = myNodeKnown
		myNodeKnown = { !window.contains($0) && before($0) }
		guard reported else { return }
		at(from) { $0.refreshReadiness() }
		at(to) { $0.refreshReadiness() }
	}

	func ready(_ instant: Instant) -> Bool {
		let up = radioUp(instant)
		return ProfileRules.radioReady(hasConnection: up, state: up ? .subscribed : .discovering, hasMyUser: up && myNodeKnown(instant))
	}

	// MARK: ProfileSync

	@discardableResult
	func schedule(_ item: ProfileOutbox.Item, reason: ProfileOutbox.Reason, delay: ClosedRange<Double>, hint: ProfileCard? = nil, isReask: Bool = false) -> Bool {
		guard outbox.schedule(item, reason: reason, delay: delay, hint: hint, isReask: isReask, now: now, using: &random) else {
			refused.append(item)
			return false
		}
		startLane()
		return true
	}

	/// Someone asks me for my photo (a private request for every slot).
	func photoRequest(from num: Int64, slots: Int) -> Bool {
		guard pieces.admit(nil, slotCount: slots, for: PhotoSendLimiter.Key(audience: .person(num), version: 1), now: now) else { return false }
		startLane()
		return true
	}

	@discardableResult
	func requestPhoto(_ num: Int64) -> Bool {
		if transfers[num] != nil { return true }
		guard liveReady() else { return false }
		guard transfers.count < ProfileOutbox.maxTransfers, schedule(.photoAsk(num), reason: .photoAsk, delay: 0...0) else { return false }
		transfers[num] = PhotoWatchdog.Clock(lastActivity: now)
		startWatchdog()
		return true
	}

	/// `AccessoryManager.refreshRadioReady`: the reducer, then the edge to ProfileSync.
	func refreshReadiness() {
		guard let edge = readiness.update(ready: ready(now), now: now) else { return }
		edges.append((edge, now))
		readinessChanged(edge)
	}

	/// `ProfileSync.radioReady`: read live, and the published value healed if it differs.
	private func liveReady() -> Bool {
		let live = ready(now)
		if live != readiness.ready { refreshReadiness() }
		return live
	}

	/// `ProfileSync.radioReadinessChanged`.
	private func readinessChanged(_ edge: RadioReadiness.Edge) {
		guard case .becameReady(let awayFor) = edge else { return }
		waitingForRadio = false
		backoff = nil
		backoffUntil = nil
		if let awayFor {
			for num in transfers.keys {
				transfers[num]?.radioBack(awaySince: now - awayFor, now: now)
			}
		}
		startLane()
	}

	private func startLane() {
		guard !running else {
			// Cuts the lane's sleep short.
			napUntil = nil
			return
		}
		guard !waitingForRadio || ready(now) else { return }
		waitingForRadio = false
		running = true
	}

	private func pauseForRadio() {
		waitingForRadio = true
		running = false
		napUntil = nil
	}

	private func waitOutNoRadio() {
		guard let wait = ProfileRules.afterNoRadio(linked: radioUp(now), lastBackoff: backoff) else {
			pauseForRadio()
			return
		}
		backoff = wait
		backoffUntil = now + wait
	}

	private func sentOne() {
		backoff = nil
		backoffUntil = nil
	}

	private func abandon(_ num: Int64) {
		transfers[num] = nil
		abandoned.append((num, now))
		outbox.remove(.photoAsk(num))
	}

	private func startWatchdog() {
		guard !watchdogOn else { return }
		watchdogOn = true
		at(now + .seconds(10)) { $0.watchdogTick() }
	}

	private func watchdogTick() {
		_ = liveReady()
		let steps = PhotoWatchdog(clocks: transfers).steps(now: now, radio: readiness, askQueued: { self.outbox.contains(.photoAsk($0)) }, stillAskedGroup: { _ in true })
		for num in steps.keys.sorted() {
			switch steps[num] {
			case .wait?, nil:
				continue
			case .giveUp?:
				abandon(num)
			case .askAgain?:
				guard schedule(.photoAsk(num), reason: .photoAsk, delay: ProfileOutbox.reask, isReask: true) else { continue }
				transfers[num]?.attempts += 1
				transfers[num]?.asked(now: now)
			}
		}
		if transfers.isEmpty {
			watchdogOn = false
		} else {
			at(now + .seconds(10)) { $0.watchdogTick() }
		}
	}

	/// What `deliver` would find: my card is new to everyone, and everyone may get it. With
	/// no radio, everything it looks up reads as gone (no card, no group, nobody I've messaged).
	private func facts(_ entry: ProfileOutbox.Entry) -> ProfileRules.SendFacts {
		var facts = ProfileRules.SendFacts()
		if case .photoAsk(let num) = entry.item {
			facts.transferExists = transfers[num] != nil
		}
		guard ready(now) else { return facts }
		facts.myCardVersion = 2
		facts.sentCardVersion = 1
		facts.canReachDirectly = true
		facts.mayShare = true
		facts.sameGroup = true
		facts.needsGroupSend = true
		return facts
	}

	/// `deliver`: the radio first, then whether it's still needed, then the send.
	private func deliver(_ entry: ProfileOutbox.Entry) -> ProfileSync.SendResult? {
		writeAttempts.append(now)
		guard liveReady() else { return .noRadio }
		guard ProfileRules.stillNeeded(entry, facts: facts(entry)) else { return nil }
		let result = sendResult(now)
		now = now + latency
		if result == .sent, case .photoAsk(let num) = entry.item { transfers[num]?.asked(now: now) }
		return result
	}

	// MARK: Running

	func run(for duration: Duration) {
		run(until: now + duration)
	}

	func run(until end: Instant) {
		var steps = 0
		while now < end {
			steps += 1
			guard steps < 100_000 else {
				Issue.record("The lane never settled at \(now - start)")
				return
			}
			while let first = events.first, first.at <= now {
				events.removeFirst()
				first.run(self)
			}
			let nextEvent = min(events.first?.at ?? end, end)
			if let until = suspendedUntil {
				if now < until {
					now = min(until, end)
					continue
				}
				suspendedUntil = nil
			}
			guard running else {
				now = nextEvent
				continue
			}
			// Backing off: a wake doesn't end it.
			if let until = backoffUntil, until > now {
				now = min(until, nextEvent)
				continue
			}
			if let until = napUntil {
				if now < until {
					now = min(until, nextEvent)
					continue
				}
				napUntil = nil
			}
			let ready = outbox.sendableAt(now)
			if ready > now {
				now = min(ready, nextEvent)
				continue
			}
			looks += 1
			switch outbox.next(now: now, piecesWaiting: !pieces.isIdle) {
			case .entry(let entry)?:
				let edgesBefore = edges.count
				let result = deliver(entry)
				let outcome = ProfileRules.outcome(of: result, readyAfter: self.ready(now), sameLink: edges.count == edgesBefore)
				if outcome == .noRadio { noRadioAttempts.append(now) }
				if outcome == .sent { log.append(Sent(entry: entry, at: now)) }
				if outbox.finish(entry, outcome, at: now) {
					waitOutNoRadio()
				} else if outcome == .sent {
					sentOne()
				}
			case .piece?:
				writeAttempts.append(now)
				guard liveReady() else {
					noRadioAttempts.append(now)
					waitOutNoRadio()
					continue
				}
				guard let next = pieces.next(now: now) else { continue }
				let edgesBefore = edges.count
				let result = sendResult(now)
				now = now + latency
				switch ProfileRules.outcome(of: result, readyAfter: self.ready(now), sameLink: edges.count == edgesBefore) {
				case .sent:
					pieces.delivered(next.key)
					outbox.sentPhotoPiece(at: now)
					log.append(Sent(piece: next.key, at: now))
					sentOne()
				case .noRadio:
					noRadioAttempts.append(now)
					pieces.putBack(next)
					waitOutNoRadio()
				case .failed, .notNeeded:
					pieces.cancel(next.key, unsent: next.slot)
				}
			case nil:
				// Sleeps until it's due; anything queued meanwhile (an event) wakes it.
				guard let wake = outbox.nextWake(now: now, piecesWaiting: !pieces.isIdle) else {
					running = false
					continue
				}
				guard wake > now else {
					Issue.record("The lane would spin at \(now - start)")
					return
				}
				now = min(wake, nextEvent)
			}
		}
	}

	func sends(_ item: ProfileOutbox.Item) -> [Instant] {
		log.filter { $0.entry?.item == item }.map(\.at)
	}

	func sends(where match: (ProfileOutbox.Item) -> Bool) -> [Instant] {
		log.filter { $0.entry.map { match($0.item) } == true }.map(\.at)
	}

	func pieces(for num: Int64) -> [Instant] {
		log.filter { $0.piece?.audience == .person(num) }.map(\.at)
	}

	/// The most of `times` in any `window`.
	static func most(_ times: [Instant], in window: Duration) -> Int {
		times.map { first in times.filter { $0 >= first && $0 - first < window }.count }.max() ?? 0
	}
}

@Suite("Profile outbox")
struct ProfileOutboxTests {

	private let start = ContinuousClock.now
	/// Every lane test runs with each of these; the bounds hold for all of them.
	private static let seeds = Array(UInt64(1)...UInt64(20))

	private func card(_ name: String) -> ProfileCard {
		ProfileCard(displayName: name, emoji: "", color: 0, photoVersion: 0)
	}

	private func isPhotoAsk(_ item: ProfileOutbox.Item) -> Bool {
		if case .photoAsk = item { return true }
		return false
	}

	// MARK: Lane scenarios

	/// Two edits to 8 friends 40 s apart, then a first DM to Carol: my card goes with the
	/// DM, not after the edits, and each friend's second card is out within a minute.
	@Test func twoEditsThenAFirstDmCarriesMyCardAtOnce() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			let friends = (101...108).map { Int64($0) }
			for num in friends {
				lane.schedule(.card(.person(num)), reason: .myEdit, delay: ProfileOutbox.afterEdit)
			}
			lane.at(40) { lane in
				for num in friends {
					lane.schedule(.card(.person(num)), reason: .myEdit, delay: ProfileOutbox.afterEdit)
				}
			}
			lane.at(80) { $0.schedule(.card(.person(200)), reason: .myMessage, delay: ProfileOutbox.afterMessage) }
			lane.run(for: .seconds(1200))
			let carol = lane.sends(.card(.person(200))).first.map { $0 - lane.t(80) }
			#expect(carol.map { $0 <= .seconds(10) } == true, "seed \(seed): \(String(describing: carol))")
			for num in friends {
				let second = lane.sends(.card(.person(num))).first { $0 > lane.t(40) }.map { $0 - lane.t(40) }
				#expect(second.map { $0 <= .seconds(60) } == true, "seed \(seed), \(num): \(String(describing: second))")
			}
			#expect(lane.refused.isEmpty, "seed \(seed)")
		}
	}

	/// "Update" on 40 photo offers while Carol asks for my photo and I DM Alice: only a few
	/// downloads start, and neither my card nor the pieces Carol asked for wait behind the asks.
	@Test func aBigBannerTapDoesntStarveMyCardOrPiecesIOwe() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			let started = (1...Int64(40)).filter { lane.requestPhoto($0) }
			#expect(started.count == ProfileOutbox.maxTransfers, "seed \(seed)")
			lane.at(0.1) { #expect($0.photoRequest(from: 500, slots: 30)) }
			lane.at(0.2) { $0.schedule(.card(.person(600)), reason: .myMessage, delay: ProfileOutbox.afterMessage) }
			lane.run(for: .seconds(300))
			let alice = lane.sends(.card(.person(600))).first.map { $0 - lane.t(0.2) }
			#expect(alice.map { $0 <= .seconds(8) } == true, "seed \(seed): \(String(describing: alice))")
			let carol = lane.pieces(for: 500)
			#expect(carol.count == 30, "seed \(seed)")
			#expect(carol.first.map { $0 - lane.t(0.1) <= .seconds(10) } == true, "seed \(seed)")
			#expect(carol.last.map { $0 - lane.t(0.1) <= .seconds(150) } == true, "seed \(seed)")
			#expect(lane.sends(where: isPhotoAsk).count <= ProfileOutbox.photoAsksPerWindow, "seed \(seed)")
			#expect(lane.refused.isEmpty, "seed \(seed)")
		}
	}

	/// Asks held back by their cap fill only their own room, so card backs still get in, and go.
	@Test func heldAsksDontCrowdOutCards() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			let asks = (1...Int64(30)).map { lane.schedule(.cardAsk($0), reason: .ask, delay: ProfileOutbox.ask, hint: card("Forged \($0)")) }
			let room = ProfileOutbox.room(.ask)
			#expect(asks == Array(repeating: true, count: room) + Array(repeating: false, count: 30 - room), "seed \(seed)")
			lane.run(for: .seconds(20 * 60))
			let replies = (301...Int64(315)).map { lane.schedule(.card(.person($0)), reason: .reply, delay: ProfileOutbox.cardBack) }
			#expect(replies.allSatisfy { $0 }, "seed \(seed)")
			lane.run(for: .seconds(30 * 60))
			for num in 301...Int64(315) {
				#expect(lane.sends(.card(.person(num))).first.map { $0 - lane.t(20 * 60) <= .seconds(30 * 60) } == true, "seed \(seed), \(num)")
			}
		}
	}

	/// The radio drops for 3.5 s, and a photo ask asked for just before meets the gap: it's
	/// kept, uncharged, and goes once the radio is back, and the card queued before the gap
	/// still goes, once.
	@Test func aBlipKeepsWhatsQueued() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			lane.schedule(.card(.person(702)), reason: .reply, delay: 0...0)
			lane.schedule(.card(.person(700)), reason: .myMessage, delay: ProfileOutbox.afterMessage)
			lane.at(0.4) { #expect($0.requestPhoto(701)) }
			lane.radioDown(0.5, 4)
			lane.run(for: .seconds(10))
			let erin = lane.sends(.photoAsk(701))
			#expect(erin.first.map { $0 - lane.start <= .seconds(8) } == true, "seed \(seed)")
			#expect(!lane.noRadioAttempts.isEmpty, "seed \(seed)")
			// The send that found no radio wasn't charged: only the one that went counts.
			#expect(lane.outbox.charged(.photoAsk, now: lane.now) == erin.count, "seed \(seed)")
			lane.run(for: .seconds(190))
			let dave = lane.sends(.card(.person(700)))
			#expect(dave.count == 1, "seed \(seed)")
			#expect(dave.first.map { $0 - lane.start <= .seconds(8) } == true, "seed \(seed)")
		}
	}

	/// 30 people ask for my card at once: every one is answered, spread over the cap, and
	/// the lane wakes when the cap frees rather than every second.
	@Test func thirtyAnswersAtOnceAreAllSent() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			for num in 0..<Int64(30) {
				#expect(lane.schedule(.card(.person(1000 + num)), reason: .answer, delay: ProfileOutbox.afterMessage))
			}
			lane.run(for: .seconds(7200))
			let sent = lane.sends { if case .card = $0 { return true }; return false }
			#expect(sent.count == 30, "seed \(seed)")
			#expect(sent.last.map { $0 - lane.start <= .seconds(21 * 60) } == true, "seed \(seed)")
			#expect(LaneDrain.most(sent, in: ProfileOutbox.window) <= ProfileOutbox.answersPerWindow, "seed \(seed)")
			#expect(lane.looks < 100, "seed \(seed): \(lane.looks)")
		}
	}

	/// Past the answers' room, `schedule` says no (their app asks again later); everything
	/// it said yes to is sent.
	@Test func pastTheAnswerReservationScheduleSaysNo() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			let accepted = (0..<Int64(40)).map { lane.schedule(.card(.person(1000 + $0)), reason: .answer, delay: ProfileOutbox.afterMessage) }
			let room = ProfileOutbox.room(.answer)
			#expect(accepted == Array(repeating: true, count: room) + Array(repeating: false, count: 40 - room), "seed \(seed)")
			lane.run(for: .seconds(7200))
			let sent = lane.sends { if case .card = $0 { return true }; return false }
			#expect(sent.count == room, "seed \(seed)")
			#expect(sent.last.map { $0 - lane.start <= .seconds(21 * 60) } == true, "seed \(seed)")
		}
	}

	/// Suspended for 70 minutes with cards due, longer than `maxBlockedAge`: none is dropped on
	/// waking. Nothing counts as held back until a cap actually holds it back after the app wakes.
	@Test func aLongSuspensionDropsNothing() {
		for reason in [ProfileOutbox.Reason.myEdit, .answer] {
			let lane = LaneDrain(start: start, seed: 5)
			for num in 0..<Int64(13) {
				#expect(lane.schedule(.card(.person(2000 + num)), reason: reason, delay: 1...1))
			}
			let resume = lane.t(70 * 60)
			lane.suspendedUntil = resume
			lane.run(until: resume)
			#expect(lane.log.isEmpty)
			#expect(lane.outbox.entries.allSatisfy { $0.blockedSince == nil })
			lane.run(for: .seconds(60))
			if reason == .answer {
				#expect(lane.log.count == ProfileOutbox.answersPerWindow)
				#expect(lane.outbox.entries.first?.blockedSince.map { $0 >= resume } == true)
			}
			lane.run(for: .seconds(3600))
			#expect(lane.log.count == 13, "\(reason)")
			if reason == .answer {
				#expect(lane.log.last.map { $0.at - resume <= ProfileOutbox.window + ProfileOutbox.spacing } == true)
			}
		}
	}

	/// Bob's ask merged into my update for him: the update isn't held for his answer interval,
	/// and goes as an answer too. An answer on its own within that interval still waits.
	/// And the other way: an answer merged into an update the edit interval holds goes as the answer.
	@Test func anAnswerMergedIntoAnUpdateDoesntHoldIt() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			lane.schedule(.card(.person(5)), reason: .answer, delay: 0...0)
			lane.at(60) { $0.schedule(.card(.person(5)), reason: .myEdit, delay: ProfileOutbox.afterEdit) }
			lane.at(61) { $0.schedule(.card(.person(5)), reason: .answer, delay: ProfileOutbox.afterMessage) }
			lane.run(for: .seconds(120))
			let bob = lane.log.filter { $0.entry?.item == .card(.person(5)) }
			#expect(bob.count == 2, "seed \(seed)")
			guard bob.count == 2, let update = bob[1].entry else { continue }
			#expect(bob[1].at - lane.t(60) <= .seconds(11), "seed \(seed)")
			#expect(update.admittedAs == .myEdit, "seed \(seed)")
			#expect(update.force, "seed \(seed)")
			lane.schedule(.card(.person(5)), reason: .answer, delay: 0...0)
			lane.run(until: bob[1].at + ProfileOutbox.answerInterval - .seconds(1))
			#expect(lane.sends(.card(.person(5))).count == 2, "seed \(seed)")
			lane.run(for: .seconds(10))
			#expect(lane.sends(.card(.person(5))).count == 3, "seed \(seed)")
		}
		let lane = LaneDrain(start: start, seed: 1)
		lane.schedule(.card(.person(5)), reason: .myEdit, delay: 0...0)
		lane.at(5) { $0.schedule(.card(.person(5)), reason: .myEdit, delay: 0...0) }
		lane.at(10) { $0.schedule(.card(.person(5)), reason: .answer, delay: 0...0) }
		lane.run(for: .seconds(120))
		let bob = lane.log.filter { $0.entry?.item == .card(.person(5)) }
		#expect(bob.count == 2)
		#expect(bob.last.map { $0.at == lane.t(10) } == true)
		#expect(bob.last?.entry?.admittedAs == .answer)
		// Charged to the reason it went under, not its lead.
		#expect(lane.outbox.charged(.answer, now: lane.now) == 1)
		#expect(lane.outbox.charged(.myEdit, now: lane.now) == 1)
	}

	/// 32 answers waiting don't hold up my own edit going out to 8 people and 7 groups.
	@Test func myEditIsntHeldByInboundWork() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			for num in 0..<Int64(32) {
				#expect(lane.schedule(.card(.person(3000 + num)), reason: .answer, delay: ProfileOutbox.afterMessage))
			}
			lane.run(for: .seconds(30))
			var mine: [ProfileOutbox.Item] = (101...Int64(108)).map { .card(.person($0)) }
			mine += (1...Int32(7)).map { .card(.group($0, key: "\($0):G:1")) }
			for item in mine {
				#expect(lane.schedule(item, reason: .myEdit, delay: ProfileOutbox.afterEdit), "seed \(seed)")
			}
			lane.run(for: .seconds(1800))
			for item in mine {
				#expect(lane.sends(item).first.map { $0 - lane.t(30) <= .seconds(60) } == true, "seed \(seed), \(item)")
			}
		}
	}

	/// Six downloads from people out of range: each is asked for four times, then given up,
	/// and never more photo asks in ten minutes than the cap. An ask still waiting its turn
	/// (here, for the radio) isn't a try.
	@Test func stalledDownloadsAskAtMostTheCap() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			for num in 1...Int64(6) {
				#expect(lane.requestPhoto(num))
			}
			lane.run(for: .seconds(900))
			let asks = lane.sends(where: isPhotoAsk)
			#expect(LaneDrain.most(asks, in: ProfileOutbox.window) <= ProfileOutbox.photoAsksPerWindow, "seed \(seed)")
			#expect(lane.abandoned.map(\.num).sorted() == Array(1...Int64(6)), "seed \(seed)")
			for num in 1...Int64(6) {
				#expect(lane.sends(.photoAsk(num)).count == ProfileOutbox.maxPhotoAttempts, "seed \(seed), \(num)")
			}
		}
		// The radio is gone for five minutes just after the first ask: the asks wait, and still get every try.
		let lane = LaneDrain(start: start, seed: 9)
		for num in 1...Int64(6) {
			#expect(lane.requestPhoto(num))
		}
		lane.radioDown(0.5, 300)
		lane.run(for: .seconds(1500))
		for num in 1...Int64(6) {
			#expect(lane.sends(.photoAsk(num)).count == ProfileOutbox.maxPhotoAttempts, "\(num)")
			#expect(lane.sends(.photoAsk(num)).dropFirst(num == 1 ? 1 : 0).allSatisfy { $0 >= lane.t(300) })
		}
		#expect(lane.abandoned.count == 6)
		#expect(ProfileRules.photoRetry(quietFor: .seconds(120), attempts: 1, askQueued: true, stillAskedGroup: true) == .wait)
		#expect(ProfileRules.photoRetry(quietFor: .seconds(30), attempts: 1, askQueued: false, stillAskedGroup: true) == .wait)
		#expect(ProfileRules.photoRetry(quietFor: .seconds(61), attempts: 1, askQueued: false, stillAskedGroup: true) == .askAgain)
		#expect(ProfileRules.photoRetry(quietFor: .seconds(61), attempts: ProfileOutbox.maxPhotoAttempts, askQueued: false, stillAskedGroup: true) == .giveUp)
		#expect(ProfileRules.photoRetry(quietFor: .seconds(61), attempts: 1, askQueued: false, stillAskedGroup: false) == .giveUp)
	}

	/// With photo asks, asks and card backs all waiting, the pieces someone asked me for
	/// still get every other turn.
	@Test func piecesGetEveryOtherSlotWhenAnythingElseWaits() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			for num in 1...Int64(6) {
				#expect(lane.requestPhoto(num))
			}
			for num in 11...Int64(16) {
				lane.schedule(.cardAsk(num), reason: .ask, delay: 0...0, hint: card("Forged \(num)"))
			}
			for num in 21...Int64(26) {
				lane.schedule(.card(.person(num)), reason: .reply, delay: 0...0)
			}
			#expect(lane.photoRequest(from: 500, slots: 20))
			lane.run(for: .seconds(120))
			let first = lane.log.prefix(20)
			#expect(first.count == 20, "seed \(seed)")
			#expect(first.filter { $0.piece != nil }.count >= 10, "seed \(seed)")
		}
	}

	// MARK: The lane step

	/// Only airtime is charged: a send that found no radio goes back as it was, and one not
	/// needed any more counts for nothing.
	@Test func finishChargesOnlyAirtime() {
		var outbox = ProfileOutbox()
		outbox.schedule(.card(.person(5)), reason: .reply, delay: 0...0, now: start)
		outbox.schedule(.card(.person(5)), reason: .answer, delay: 0...0, now: start)
		do {
			let entry = outbox.take(now: start)
			#expect(entry?.admittedAs == .reply)
			guard let entry else { return }
			do { let ok = outbox.finish(entry, .noRadio, at: start); #expect(ok) }
			#expect(outbox.entries.count == 1)
			let back = outbox.entries.first
			#expect(back.map { $0.due == entry.due && $0.reasons == entry.reasons && $0.queued == entry.queued } == true)
			#expect(back?.admittedAs == nil)
			#expect(outbox.charged(.reply, now: start) == 0)
			#expect(outbox.sendableAt(start) == start)
		}
		do {
			let entry = outbox.take(now: start)
			#expect(entry != nil)
			guard let entry else { return }
			do { let ok = !outbox.finish(entry, .notNeeded, at: start); #expect(ok) }
			#expect(outbox.entries.isEmpty)
			#expect(outbox.charged(.reply, now: start) == 0)
			#expect(outbox.sendableAt(start) == start)
		}
		for outcome in [ProfileOutbox.Outcome.sent, .failed] {
			var outbox = ProfileOutbox()
			outbox.schedule(.card(.person(5)), reason: .reply, delay: 0...0, now: start)
			outbox.schedule(.card(.person(5)), reason: .answer, delay: 0...0, now: start)
			guard let entry = outbox.take(now: start) else {
				Issue.record("nothing to send")
				continue
			}
			do { let ok = !outbox.finish(entry, outcome, at: start); #expect(ok) }
			// Charged to the reason it went under, and the next packet waits.
			#expect(outbox.charged(.reply, now: start) == 1)
			#expect(outbox.charged(.answer, now: start) == 0)
			#expect(outbox.sendableAt(start) == start + ProfileOutbox.spacing)
		}
	}

	/// What's checked when a packet that waited comes up.
	@Test func anAskIsntSentOnceTheirCardCame() {
		let heard = card("Bobby")
		let ask = ProfileOutbox.Entry(item: .cardAsk(5), due: start, reasons: [.ask], hint: heard, queued: start)
		var facts = ProfileRules.SendFacts()
		facts.canReachDirectly = true
		facts.storedCard = heard
		#expect(!ProfileRules.stillNeeded(ask, facts: facts))
		facts.storedCard = card("Bob")
		#expect(ProfileRules.stillNeeded(ask, facts: facts))

		// My card to someone I may no longer share it with.
		let mine = ProfileOutbox.Entry(item: .card(.person(5)), due: start, reasons: [.myMessage], queued: start)
		var person = ProfileRules.SendFacts()
		person.myCardVersion = 7
		person.sentCardVersion = 3
		person.canReachDirectly = true
		person.mayShare = false
		#expect(!ProfileRules.stillNeeded(mine, facts: person))
		person.mayShare = true
		#expect(ProfileRules.stillNeeded(mine, facts: person))
		person.sentCardVersion = 7
		#expect(!ProfileRules.stillNeeded(mine, facts: person))
		// Unless they asked for it.
		let answer = ProfileOutbox.Entry(item: .card(.person(5)), due: start, reasons: [.myEdit, .answer], queued: start)
		#expect(ProfileRules.stillNeeded(answer, facts: person))
		person.myCardVersion = nil
		#expect(!ProfileRules.stillNeeded(answer, facts: person))

		let group = ProfileOutbox.Entry(item: .card(.group(1, key: "1:Hike:9")), due: start, reasons: [.myMessage], queued: start)
		var groupFacts = ProfileRules.SendFacts()
		groupFacts.myCardVersion = 7
		groupFacts.sameGroup = true
		groupFacts.needsGroupSend = true
		#expect(ProfileRules.stillNeeded(group, facts: groupFacts))
		groupFacts.sameGroup = false
		#expect(!ProfileRules.stillNeeded(group, facts: groupFacts))
		groupFacts.sameGroup = true
		groupFacts.needsGroupSend = false
		#expect(!ProfileRules.stillNeeded(group, facts: groupFacts))

		let photo = ProfileOutbox.Entry(item: .photoAsk(5), due: start, reasons: [.photoAsk], queued: start)
		#expect(!ProfileRules.stillNeeded(photo, facts: ProfileRules.SendFacts()))
		var going = ProfileRules.SendFacts()
		going.transferExists = true
		#expect(ProfileRules.stillNeeded(photo, facts: going))
	}

	/// Editing my profile while my card waits to go to them: still one card, at the sooner of
	/// the two times. The outbox holds no card, only whom it's for, so what goes is my card
	/// as it is when it goes.
	@Test func anEditWhileACardWaitsLeavesOneForThem() {
		var outbox = ProfileOutbox()
		outbox.schedule(.card(.person(5)), reason: .myMessage, delay: 2...2, now: start)
		outbox.schedule(.card(.person(5)), reason: .myEdit, delay: 3...3, now: start + .milliseconds(300))
		#expect(outbox.entries.count == 1)
		#expect(outbox.entries.first?.due == start + .seconds(2))
		#expect(outbox.entries.first?.reasons == [.myMessage, .myEdit])
		outbox.schedule(.card(.person(5)), reason: .myEdit, delay: 1...1, now: start + .milliseconds(300))
		#expect(outbox.entries.first?.due == start + .milliseconds(1300))
		for seed in Self.seeds {
			var random = SeededRandom(seed: seed)
			var copy = random
			let drawn = Double.random(in: ProfileOutbox.afterEdit, using: &copy)
			var outbox = ProfileOutbox()
			outbox.schedule(.card(.person(5)), reason: .myMessage, delay: 2...2, now: start)
			outbox.schedule(.card(.person(5)), reason: .myEdit, delay: ProfileOutbox.afterEdit, now: start + .milliseconds(300), using: &random)
			#expect(outbox.entries.count == 1)
			#expect(outbox.entries.first?.due == min(start + .seconds(2), start + .milliseconds(300) + .seconds(drawn)), "seed \(seed)")
		}
	}

	// MARK: Caps and intervals

	/// Asks about a few people I've got private cards for, each with a forged card in a
	/// group: spread out, and only a few go in any ten minutes.
	@Test func asksForManyPeopleAreSpreadAndCapped() {
		var outbox = ProfileOutbox()
		var random = SeededRandom(seed: 7)
		for num in 1...Int64(ProfileOutbox.room(.ask)) {
			outbox.schedule(.cardAsk(num), reason: .ask, delay: ProfileOutbox.ask, hint: card("Forged \(num)"), now: start, using: &random)
		}
		#expect(Set(outbox.entries.map(\.due)).count == ProfileOutbox.room(.ask))
		let first = OutboxDrain.run(&outbox, from: start, until: start + ProfileOutbox.window - .seconds(1))
		#expect(first.count == ProfileOutbox.asksPerWindow)
		#expect(first.allSatisfy { $0.at >= start + .seconds(5) })
		#expect(zip(first, first.dropFirst()).allSatisfy { $1.at - $0.at >= ProfileOutbox.spacing })
		// The rest go as windows free up, never more than the cap in any ten minutes.
		let all = first + OutboxDrain.run(&outbox, from: start + ProfileOutbox.window - .seconds(1), for: .seconds(3600))
		#expect(all.count == ProfileOutbox.room(.ask))
		#expect(LaneDrain.most(all.map(\.at), in: ProfileOutbox.window) <= ProfileOutbox.asksPerWindow)
		#expect(Set(all.map(\.entry.item)).count == all.count)
	}

	@Test func theSameCardAgainIsntAskedAboutUntilTheIntervalIsOver() {
		var outbox = ProfileOutbox()
		let heard = card("Bob?")
		outbox.schedule(.cardAsk(5), reason: .ask, delay: 0...0, hint: heard, now: start)
		do { let ok = OutboxDrain.run(&outbox, from: start, for: .seconds(1)).count == 1; #expect(ok) }
		outbox.schedule(.cardAsk(5), reason: .ask, delay: 0...0, hint: heard, now: start + .seconds(6 * 60))
		do { let ok = outbox.take(now: start + .seconds(6 * 60)) == nil; #expect(ok) }
		do { let ok = outbox.take(now: start + ProfileOutbox.askInterval)?.item == .cardAsk(5); #expect(ok) }
	}

	/// A forged card just before a real change can't hold the real one off for half an hour.
	@Test func aDifferentCardReArmsTheAskSooner() {
		var outbox = ProfileOutbox()
		outbox.schedule(.cardAsk(5), reason: .ask, delay: 0...0, hint: card("Forged"), now: start)
		do { let ok = OutboxDrain.run(&outbox, from: start, for: .seconds(1)).count == 1; #expect(ok) }
		let real = card("Bobby")
		outbox.schedule(.cardAsk(5), reason: .ask, delay: 0...0, hint: real, now: start + .seconds(60))
		do { let ok = outbox.take(now: start + .seconds(4 * 60)) == nil; #expect(ok) }
		do { let ok = outbox.take(now: start + ProfileOutbox.askRearm)?.hint == real; #expect(ok) }
	}

	@Test func reArmedAsksStillCountAgainstTheCap() {
		var outbox = ProfileOutbox()
		for num in 1...Int64(ProfileOutbox.asksPerWindow) {
			outbox.schedule(.cardAsk(num), reason: .ask, delay: 0...0, hint: card("A"), now: start)
		}
		do { let ok = OutboxDrain.run(&outbox, from: start, for: .seconds(30)).count == ProfileOutbox.asksPerWindow; #expect(ok) }
		outbox.schedule(.cardAsk(1), reason: .ask, delay: 0...0, hint: card("B"), now: start + ProfileOutbox.askRearm)
		do { let ok = OutboxDrain.run(&outbox, from: start + ProfileOutbox.askRearm, for: .seconds(60)).isEmpty; #expect(ok) }
		do { let ok = outbox.take(now: start + ProfileOutbox.window + .seconds(10))?.item == .cardAsk(1); #expect(ok) }
	}

	/// Their private card and their ask came together: my card back and my answer are one packet.
	@Test func aCardBackAndAnAnswerToOnePersonAreOnePacket() {
		var outbox = ProfileOutbox()
		var random = SeededRandom(seed: 4)
		outbox.schedule(.card(.person(5)), reason: .reply, delay: ProfileOutbox.cardBack, now: start, using: &random)
		outbox.schedule(.card(.person(5)), reason: .answer, delay: ProfileOutbox.afterMessage, now: start, using: &random)
		#expect(outbox.entries.count == 1)
		#expect(outbox.entries.first?.force == true)
		#expect(outbox.entries.first?.reasons == [.reply, .answer])
		#expect(OutboxDrain.run(&outbox, from: start, for: .seconds(60)).count == 1)
	}

	/// Quick edits send one card per person per minute: the latest, since what goes is
	/// worked out when it goes.
	@Test func quickEditsSendOneCardAMinute() {
		var outbox = ProfileOutbox()
		var sent: [OutboxDrain.Sent] = []
		var clock = start
		for edit in 0..<5 {
			let at = start + .seconds(edit * 10)
			sent += OutboxDrain.run(&outbox, from: clock, until: at)
			outbox.schedule(.card(.person(5)), reason: .myEdit, delay: 1...1, now: at)
			clock = at
		}
		sent += OutboxDrain.run(&outbox, from: clock, for: .seconds(300))
		#expect(sent.map(\.at) == [start + .seconds(1), start + .seconds(61)])
	}

	@Test func mergingKeepsTheSoonerTime() {
		var outbox = ProfileOutbox()
		outbox.schedule(.card(.group(1, key: "1:Hike:9")), reason: .myMessage, delay: 10...10, now: start)
		outbox.schedule(.card(.group(1, key: "1:Hike:9")), reason: .myMessage, delay: 2...2, now: start)
		outbox.schedule(.card(.group(1, key: "1:Hike:9")), reason: .myMessage, delay: 30...30, now: start)
		#expect(outbox.entries.map(\.due) == [start + .seconds(2)])
		// Another group (or the same slot holding another group) is its own entry.
		outbox.schedule(.card(.group(1, key: "1:Camp:4")), reason: .myMessage, delay: 2...2, now: start)
		#expect(outbox.entries.count == 2)
	}

	@Test func packetsAreSpacedWhateverTheirKind() {
		var outbox = ProfileOutbox()
		for num in 1...Int64(5) {
			outbox.schedule(.card(.person(num)), reason: .myMessage, delay: 0...0, now: start)
		}
		let sent = OutboxDrain.run(&outbox, from: start, for: .seconds(60))
		#expect(sent.map(\.at) == (0..<5).map { start + ProfileOutbox.spacing * $0 })
		// The lane asks the same before a photo piece.
		#expect(outbox.sendableAt(sent[4].at + .seconds(1)) == sent[4].at + ProfileOutbox.spacing)
		// And a photo piece holds off the next packet the same way.
		var after = ProfileOutbox()
		after.sentPhotoPiece(at: start)
		after.schedule(.cardAsk(5), reason: .ask, delay: 0...0, hint: card("Bob?"), now: start)
		do { let ok = after.take(now: start + .milliseconds(2900)) == nil; #expect(ok) }
		do { let ok = after.take(now: start + ProfileOutbox.spacing) != nil; #expect(ok) }
	}

	/// Asking several people for their photos, or asking again for several stalled ones:
	/// one at a time, not all at once.
	@Test func photoAsksGoOneAtATime() {
		var outbox = ProfileOutbox()
		for num in 1...Int64(ProfileOutbox.maxTransfers) {
			outbox.schedule(.photoAsk(num), reason: .photoAsk, delay: 0...0, now: start)
		}
		let sent = OutboxDrain.run(&outbox, from: start, for: .seconds(120))
		#expect(sent.count == ProfileOutbox.maxTransfers)
		#expect(zip(sent, sent.dropFirst()).allSatisfy { $1.at - $0.at == ProfileOutbox.spacing })
		// A re-ask merged into a first ask still asks for everything.
		outbox.schedule(.photoAsk(9), reason: .photoAsk, delay: 0...0, now: start)
		outbox.schedule(.photoAsk(9), reason: .photoAsk, delay: 0...0, isReask: true, now: start)
		#expect(outbox.entries.first?.isReask == false)
		// A download given up takes its ask with it.
		outbox.remove(.photoAsk(9))
		#expect(!outbox.contains(.photoAsk(9)))
	}

	/// After an edit: up to 8 people and 7 groups. My own cards aren't capped, so all of
	/// them go within a minute.
	@Test func anEditToEveryoneLosesNothing() {
		var outbox = ProfileOutbox()
		var random = SeededRandom(seed: 3)
		for num in 1...Int64(8) {
			do { let ok = outbox.schedule(.card(.person(num)), reason: .myEdit, delay: ProfileOutbox.afterEdit, now: start, using: &random); #expect(ok) }
		}
		for index in 1...Int32(7) {
			do { let ok = outbox.schedule(.card(.group(index, key: "\(index):G:1")), reason: .myEdit, delay: ProfileOutbox.afterEdit, now: start, using: &random); #expect(ok) }
		}
		let sent = OutboxDrain.run(&outbox, from: start, for: .seconds(30 * 60))
		#expect(sent.count == 15)
		#expect(sent.allSatisfy { $0.at - start <= .seconds(60) })
	}

	/// Each reason has its own room: a full one refuses only more of its own, and something
	/// already waiting still merges.
	@Test func eachReasonHasItsOwnRoom() {
		for reason in ProfileOutbox.Reason.allCases {
			var outbox = ProfileOutbox()
			func item(_ num: Int) -> ProfileOutbox.Item {
				switch reason {
				case .photoAsk: return .photoAsk(Int64(num))
				case .ask: return .cardAsk(Int64(num))
				default: return .card(.person(Int64(num)))
				}
			}
			for num in 1...ProfileOutbox.room(reason) {
				do { let ok = outbox.schedule(item(num), reason: reason, delay: 1...1, now: start); #expect(ok, "\(reason)") }
			}
			do { let ok = !outbox.schedule(item(999), reason: reason, delay: 1...1, now: start); #expect(ok, "\(reason)") }
			do { let ok = outbox.schedule(item(1), reason: reason, delay: 1...1, now: start); #expect(ok, "\(reason)") }
			let other: ProfileOutbox.Reason = reason == .myMessage ? .reply : .myMessage
			do { let ok = outbox.schedule(.card(.person(5000)), reason: other, delay: 1...1, now: start); #expect(ok, "\(reason)") }
		}
	}

	/// Held back for over an hour by its cap (others always first), or waiting six hours for
	/// a radio that never came back: dropped.
	@Test func aPacketHeldBackTooLongIsDropped() {
		var outbox = ProfileOutbox()
		outbox.schedule(.card(.person(99)), reason: .answer, delay: 0...0, now: start)
		// Every ten minutes, a cap's worth of answers goes: 99's never gets through.
		for round in 0...7 {
			let at = start + .seconds(round * 10 * 60)
			for num in 0..<ProfileOutbox.answersPerWindow {
				let other = ProfileOutbox.Entry(item: .card(.person(Int64(1000 + num))), due: at, reasons: [.answer], queued: at, admittedAs: .answer)
				outbox.finish(other, .sent, at: at)
			}
			do { let ok = outbox.take(now: at + .seconds(5)) == nil; #expect(ok) }
			#expect(outbox.entries.isEmpty == (round == 7))
		}
		#expect(outbox.nextWake(now: start + .seconds(71 * 60), piecesWaiting: false) == nil)

		var queued = ProfileOutbox()
		queued.schedule(.card(.person(5)), reason: .myMessage, delay: 2...2, now: start)
		do { let ok = queued.take(now: start + ProfileOutbox.maxQueuedAge + .seconds(1)) == nil; #expect(ok) }
		#expect(queued.entries.isEmpty)
	}
}

/// What the lane does while the radio can't take a packet: nothing queued is judged not
/// needed or charged, and it all goes once the radio is back.
@Suite("Profile lane and the radio", .serialized)
struct ProfileRadioTests {

	private let start = ContinuousClock.now
	private static let seeds = Array(UInt64(1)...UInt64(20))

	private static let states: [AccessoryManagerState] = [
		.uninitialized, .idle, .discovering, .connecting, .retrying(attempt: 1, maxAttempts: 3),
		.retrievingDatabase(nodeCount: 5), .communicating, .subscribed
	]

	private func card(_ name: String) -> ProfileCard {
		ProfileCard(displayName: name, emoji: "", color: 0, photoVersion: 0)
	}

	// MARK: The radio check

	@Test func onlyALinkedSubscribedRadioWithMyNodeIsReady() {
		for state in Self.states {
			for hasConnection in [false, true] {
				for hasMyUser in [false, true] {
					let ready = ProfileRules.radioReady(hasConnection: hasConnection, state: state, hasMyUser: hasMyUser)
					#expect(ready == (hasConnection && hasMyUser && state == .subscribed), "\(state) \(hasConnection) \(hasMyUser)")
				}
			}
		}
	}

	/// A send refused as the radio went away found no radio: put back, not charged.
	@Test func aSendRefusedAsTheRadioWentIsPutBack() {
		for readyAfter in [false, true] {
			for sameLink in [false, true] {
				#expect(ProfileRules.outcome(of: nil, readyAfter: readyAfter, sameLink: sameLink) == .notNeeded)
				#expect(ProfileRules.outcome(of: .sent, readyAfter: readyAfter, sameLink: sameLink) == .sent)
				#expect(ProfileRules.outcome(of: .noRadio, readyAfter: readyAfter, sameLink: sameLink) == .noRadio)
			}
		}
		#expect(ProfileRules.outcome(of: .failed, readyAfter: true, sameLink: true) == .failed)
		#expect(ProfileRules.outcome(of: .failed, readyAfter: false, sameLink: true) == .noRadio)
		// Ready on both sides of the send, but the radio dropped and came back while it
		// was out: the write failed with the old link, so it goes back for the new one, uncharged.
		#expect(ProfileRules.outcome(of: .failed, readyAfter: true, sameLink: false) == .noRadio)
		#expect(ProfileRules.outcome(of: .failed, readyAfter: false, sameLink: false) == .noRadio)

		var outbox = ProfileOutbox()
		outbox.schedule(.card(.person(5)), reason: .reply, delay: 0...0, now: start)
		guard let entry = outbox.take(now: start) else {
			Issue.record("nothing to send")
			return
		}
		let wait = outbox.finish(entry, ProfileRules.outcome(of: .failed, readyAfter: false, sameLink: true), at: start)
		#expect(wait)
		#expect(outbox.entries.map(\.item) == [.card(.person(5))])
		#expect(outbox.charged(.reply, now: start) == 0)
		#expect(outbox.sendableAt(start) == start)
	}

	@Test func stillLinkedItTriesAgainLaterAndLater() {
		#expect(ProfileRules.afterNoRadio(linked: false, lastBackoff: nil) == nil)
		#expect(ProfileRules.afterNoRadio(linked: false, lastBackoff: .seconds(20)) == nil)
		var waits: [Duration] = []
		var last: Duration?
		for _ in 0..<7 {
			last = ProfileRules.afterNoRadio(linked: true, lastBackoff: last)
			waits.append(last ?? .zero)
		}
		#expect(waits == [5, 10, 20, 40, 60, 60, 60].map { Duration.seconds($0) })
	}

	// MARK: Through the lane

	/// T4b. A real drop, from 0.5 to 12 s long, with a DM card, an edit to three people, a
	/// group card, a card ask and a photo ask queued: each goes once after the radio's back,
	/// and the attempts that found no radio cost nothing.
	@Test(arguments: [0.5, 2.0, 6.0, 12.0])
	func aRealDropKeepsEverythingQueued(seconds: Double) {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			#expect(lane.requestPhoto(806))
			lane.schedule(.cardAsk(805), reason: .ask, delay: 0...0, hint: card("Bob?"))
			lane.schedule(.card(.person(800)), reason: .myMessage, delay: ProfileOutbox.afterMessage)
			let edited: [Int64] = [801, 802, 803]
			for num in edited {
				lane.schedule(.card(.person(num)), reason: .myEdit, delay: ProfileOutbox.afterEdit)
			}
			let group = ProfileOutbox.Item.card(.group(1, key: "1:Hike:9"))
			lane.schedule(group, reason: .myMessage, delay: ProfileOutbox.afterMessage)
			// From just before the second packet is due, so every drop meets a send.
			lane.radioDown(2.9, 2.9 + seconds)
			lane.run(for: .seconds(300))
			let back = max(lane.t(2.9 + seconds), lane.t(10))
			let items: [ProfileOutbox.Item] = [.card(.person(800)), group, .cardAsk(805)] + edited.map { .card(.person($0)) }
			for item in items {
				let sends = lane.sends(item)
				#expect(sends.count == 1, "seed \(seed), \(seconds) s, \(item)")
				#expect(sends.first.map { $0 - back <= .seconds(20) } == true, "seed \(seed), \(seconds) s, \(item): \(sends)")
			}
			#expect(!lane.noRadioAttempts.isEmpty, "seed \(seed), \(seconds) s")
			// One charge per packet that went, none for the attempts that didn't.
			#expect(lane.outbox.charged(.myMessage, now: lane.now) == 2, "seed \(seed)")
			#expect(lane.outbox.charged(.myEdit, now: lane.now) == 3, "seed \(seed)")
			#expect(lane.outbox.charged(.ask, now: lane.now) == 1, "seed \(seed)")
		}
	}

	/// T4c. A write that fails across a reconnect, with the radio back and ready: tried again
	/// within the first backoff, and the lane keeps going.
	@Test func aLateNoRadioWhileReadyIsTriedAgainSoon() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			let failing = lane.t(0)..<lane.t(6)
			lane.sendResult = { failing.contains($0) ? .noRadio : .sent }
			lane.schedule(.card(.person(810)), reason: .myMessage, delay: ProfileOutbox.afterMessage)
			lane.run(for: .seconds(30))
			let first = lane.noRadioAttempts.first
			let sent = lane.sends(.card(.person(810)))
			#expect(sent.count == 1, "seed \(seed)")
			#expect(zip(first.map { [$0] } ?? [], sent).allSatisfy { $1 - $0 <= ProfileOutbox.firstBackoff * 2 + ProfileOutbox.spacing }, "seed \(seed): \(String(describing: first)) \(sent)")
			lane.at(30) { $0.schedule(.card(.person(811)), reason: .reply, delay: 0...0) }
			lane.run(for: .seconds(10))
			#expect(lane.sends(.card(.person(811))).first.map { $0 - lane.t(30) <= ProfileOutbox.spacing } == true, "seed \(seed)")
		}
	}

	/// T4d. Linked, but my own node unknown for ten minutes: the lane keeps trying, at most
	/// about once a minute, never spins, and the card goes as soon as the node is known (the
	/// readiness edge), not at the next backoff. Unreported, the backoff still finds it.
	@Test func linkedWithoutMyNodeTriesAtMostOnceAMinute() {
		for reported in [true, false] {
			let lane = LaneDrain(start: start, seed: 3)
			lane.myNodeMissing(0, 600, reported: reported)
			let missing = lane.t(0)..<lane.t(600)
			lane.schedule(.card(.person(820)), reason: .myMessage, delay: ProfileOutbox.afterMessage)
			lane.run(for: .seconds(700))
			let attempts = lane.noRadioAttempts.filter { missing.contains($0) }
			#expect(attempts.count >= 8, "\(reported)")
			#expect(attempts.count <= 14, "\(reported) \(attempts.count)")
			#expect(zip(attempts, attempts.dropFirst()).allSatisfy { $1 - $0 >= ProfileOutbox.firstBackoff })
			#expect(lane.looks < 100, "\(lane.looks)")
			let sent = lane.sends(.card(.person(820)))
			#expect(sent.count == 1)
			let bound = reported ? Duration.seconds(1) : ProfileOutbox.maxBackoff + ProfileOutbox.spacing
			#expect(sent.first.map { $0 - lane.t(600) <= bound } == true, "\(reported) \(sent)")
		}
	}

	// MARK: The backoff

	/// After attempts backed off 5, 10 and 20 s, a 40 s backoff begins. 30 wakes
	/// 200 ms apart (messages queued meanwhile) put nothing on the air before it's over, and
	/// the next attempt is when it ends.
	@Test func wakesDontCutTheBackoffShort() {
		let lane = LaneDrain(start: start, seed: 2)
		lane.sendResult = { _ in .noRadio }
		lane.schedule(.card(.person(830)), reason: .myMessage, delay: 0...0)
		// Attempts at 0, 5, 15 and 35 s; the one at 35 s starts the 40 s backoff.
		lane.run(for: .seconds(36))
		#expect(lane.noRadioAttempts.map { $0 - lane.start } == [0, 5, 15, 35].map { Duration.seconds($0) })
		let until = lane.backoffUntil
		#expect(until == lane.t(75))
		for wake in 0..<30 {
			lane.at(36 + Double(wake) * 0.2) { $0.schedule(.card(.person(840 + Int64(wake))), reason: .myMessage, delay: 0...0) }
		}
		lane.run(until: lane.t(80))
		let during = lane.writeAttempts.filter { $0 > lane.t(35) && $0 < lane.t(75) }
		#expect(during.isEmpty, "\(during.map { $0 - lane.start })")
		let next = lane.writeAttempts.first { $0 > lane.t(35) }
		#expect(next.map { $0 >= lane.t(75) && $0 - lane.t(75) <= ProfileOutbox.spacing } == true, "\(String(describing: next.map { $0 - lane.start }))")
		lane.run(until: lane.t(300))
		let gaps = zip(lane.noRadioAttempts, lane.noRadioAttempts.dropFirst()).map { $1 - $0 }.prefix(6)
		#expect(Array(gaps) == [5, 10, 20, 40, 60, 60].map { Duration.seconds($0) })
	}

	/// Ready again mid-backoff: tried at once, not when the backoff ends.
	@Test func readyAgainEndsTheBackoff() {
		let lane = LaneDrain(start: start, seed: 4)
		lane.myNodeMissing(0, 50)
		lane.schedule(.card(.person(850)), reason: .myMessage, delay: 0...0)
		lane.run(for: .seconds(100))
		// Attempts at 0, 5, 15, 35 s: the 40 s backoff from 35 s would run to 75 s.
		let sent = lane.sends(.card(.person(850)))
		#expect(sent.count == 1)
		#expect(sent.first.map { $0 - lane.t(50) <= .seconds(1) } == true, "\(sent.map { $0 - lane.start })")
	}

	/// Wakes while linked without my node don't double the backoff any faster
	/// than time alone does.
	@Test func wakesDontDoubleTheBackoff() {
		let quiet = LaneDrain(start: start, seed: 5)
		let woken = LaneDrain(start: start, seed: 5)
		for lane in [quiet, woken] {
			lane.myNodeMissing(0, 400, reported: false)
			lane.schedule(.card(.person(860)), reason: .myMessage, delay: 0...0)
		}
		for wake in 0..<30 {
			woken.at(1 + Double(wake) * 2) { $0.schedule(.card(.person(870 + Int64(wake))), reason: .myMessage, delay: 0...0) }
		}
		quiet.run(for: .seconds(120))
		woken.run(for: .seconds(120))
		#expect(woken.noRadioAttempts == quiet.noRadioAttempts, "\(woken.noRadioAttempts.map { $0 - woken.start }) vs \(quiet.noRadioAttempts.map { $0 - quiet.start })")
	}

	// MARK: Saving my profile

	/// An edit is pushed whatever the radio's doing; a name is saved to the radio only
	/// when it's ready (it's kept for later either way).
	@Test func aSavedEditIsAlwaysPushed() {
		#expect(ProfileRules.afterSave(nameChanged: false, meChanged: true, radioReady: false) == [.push])
		#expect(ProfileRules.afterSave(nameChanged: false, meChanged: true, radioReady: true) == [.push])
		#expect(ProfileRules.afterSave(nameChanged: true, meChanged: true, radioReady: true) == [.applyName, .push])
		#expect(ProfileRules.afterSave(nameChanged: true, meChanged: true, radioReady: false) == [.push])
		#expect(ProfileRules.afterSave(nameChanged: true, meChanged: false, radioReady: true) == [.applyName])
		#expect(ProfileRules.afterSave(nameChanged: false, meChanged: false, radioReady: true) == [])
		#expect(ProfileRules.afterSave(nameChanged: false, meChanged: false, radioReady: false) == [])
	}

	/// A push made with no radio is kept across a relaunch, and kept again by an edge
	/// that turns out not to be ready; `reset` clears it. Own defaults: the app's are untouched.
	@MainActor
	@Test func aPushHeldForTheRadioSurvivesARelaunch() throws {
		let suite = "pangea.tests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		let app = ProfileSync.defaults
		ProfileSync.defaults = defaults
		defer {
			ProfileSync.defaults = app
			UserDefaults().removePersistentDomain(forName: suite)
		}
		// This test host has no radio: AccessoryManager.shared isn't linked.
		#expect(!ProfileSync.radioReady)
		ProfileSync.pushUpdatedCard()
		#expect(ProfileSync.pushWhenBack)
		// A relaunch reads it from where it was saved.
		#expect(UserDefaults(suiteName: suite)?.bool(forKey: "pangeaPushCardWhenBack") == true)
		// Consumed by the edge, then held again since the radio still can't take it: not lost.
		ProfileSync.radioReadinessChanged(.becameReady(awayFor: .seconds(1)))
		#expect(ProfileSync.pushWhenBack)
		// Going away does nothing to it.
		ProfileSync.radioReadinessChanged(.wentAway)
		#expect(ProfileSync.pushWhenBack)
		ProfileSync.reset()
		#expect(!ProfileSync.pushWhenBack)
		#expect(defaults.object(forKey: "pangeaPushCardWhenBack") as? Bool == false)
	}

	// MARK: The gap between pieces

	/// Time with the radio away isn't time the sender took.
	@Test func timeWithoutTheRadioIsntPartOfAGap() {
		let t0 = start
		func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .seconds(seconds) }
		// Away from 1 to 46 s, a piece at 47 s: a 2 s gap, so the usual minute's patience.
		var clock = PhotoWatchdog.Clock(lastActivity: t0)
		clock.radioBack(awaySince: at(1), now: at(46))
		clock.pieceCame(now: at(47), awaySince: nil)
		#expect(clock.longestGap == .seconds(2))
		#expect(ProfileRules.photoPatience(longestGap: clock.longestGap) == .seconds(60))
		#expect(clock.awayInGap == .zero)
		#expect(clock.lastActivity == at(47))
		// No outage: all of it.
		#expect(ProfileRules.pieceGap(now: at(47), lastActivity: t0, awayInGap: .zero, awaySince: nil) == .seconds(47))
		// A piece heard while still away.
		#expect(ProfileRules.pieceGap(now: at(10), lastActivity: t0, awayInGap: .zero, awaySince: at(1)) == .seconds(1))
		// Away since before the last piece: only since that piece.
		#expect(ProfileRules.pieceGap(now: at(10), lastActivity: t0, awayInGap: .zero, awaySince: t0 - .seconds(5)) == .zero)
		// Two outages in one gap add up.
		var twice = PhotoWatchdog.Clock(lastActivity: t0)
		twice.radioBack(awaySince: at(2), now: at(12))
		twice.radioBack(awaySince: at(20), now: at(40))
		#expect(twice.awayInGap == .seconds(30))
		twice.pieceCame(now: at(45), awaySince: nil)
		#expect(twice.longestGap == .seconds(15))
	}

	/// Asking again starts a new gap: an outage before the ask isn't taken off the next one.
	@Test func anAskStartsAGapWithNoTimeAwayInIt() {
		func at(_ seconds: Double) -> ContinuousClock.Instant { start + .seconds(seconds) }
		var clock = PhotoWatchdog.Clock(lastActivity: at(0))
		clock.radioBack(awaySince: at(1), now: at(46))
		#expect(clock.awayInGap == .seconds(45))
		clock.asked(now: at(50))
		#expect(clock.awayInGap == .zero)
		#expect(clock.lastActivity == at(50))
		// The sender took 30 s.
		clock.pieceCame(now: at(80), awaySince: nil)
		#expect(clock.longestGap == .seconds(30))
	}

	// MARK: A name waiting for the radio

	/// Name writes that finish when the test says, and how.
	@MainActor
	private final class NameWrites {
		private var waiting: [String: CheckedContinuation<Void, Error>] = [:]

		func write(_ name: String) async throws {
			try await withCheckedThrowingContinuation { waiting[name] = $0 }
		}

		func isWaiting(_ name: String) -> Bool { waiting[name] != nil }

		func finish(_ name: String, failing: Bool) {
			let write = waiting.removeValue(forKey: name)
			if failing { write?.resume(throwing: CancellationError()) } else { write?.resume() }
		}
	}

	/// A name write that fails puts its name back for the next time the radio's ready,
	/// unless a newer name was set meanwhile (waiting, or being written) or the radio was
	/// forgotten; one that goes after a Forget holds no push for the next radio.
	@MainActor
	@Test(.timeLimit(.minutes(1)))
	func aNameThatCouldntBeSavedComesBackOnlyIfNothingTookItsPlace() async throws {
		let suite = "pangea.tests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		let app = (defaults: ProfileSync.defaults, applyName: ProfileSync.applyName)
		let writes = NameWrites()
		ProfileSync.defaults = defaults
		ProfileSync.applyName = { try await writes.write($0) }
		defer {
			ProfileSync.reset()
			ProfileSync.defaults = app.defaults
			ProfileSync.applyName = app.applyName
			UserDefaults().removePersistentDomain(forName: suite)
		}
		/// What `ProfileEditorSheet.save` and `.becameReady` do: the waiting name is written.
		func apply(_ name: String) async -> Task<Void, Never>? {
			ProfileSync.pendingRadioName = name
			ProfileSync.applyPendingName()
			let task = ProfileSync.nameApply
			while !writes.isWaiting(name) { await Task.yield() }
			#expect(ProfileSync.pendingRadioName == nil)
			return task
		}

		// (a) Renamed again, offline, while the older name was being written: the newer stays.
		let older = await apply("Older")
		ProfileSync.pendingRadioName = "Newer"
		writes.finish("Older", failing: true)
		await older?.value
		#expect(ProfileSync.pendingRadioName == "Newer")

		// (b) The radio's forgotten (`clearRadioData`) while it's written: nothing comes back.
		let forgotten = await apply("Radio A Name")
		ProfileSync.reset()
		ProfileSync.pendingRadioName = nil
		writes.finish("Radio A Name", failing: true)
		await forgotten?.value
		#expect(ProfileSync.pendingRadioName == nil)

		// (c) Two saves, both written at once. The first fails: the second took its place.
		let first = await apply("A")
		let second = await apply("B")
		writes.finish("A", failing: true)
		await first?.value
		#expect(ProfileSync.pendingRadioName == nil)
		// The second fails too: it's the latest, so it's kept.
		writes.finish("B", failing: true)
		await second?.value
		#expect(ProfileSync.pendingRadioName == "B")
		ProfileSync.pendingRadioName = nil

		// (d) Written, but only after the radio was forgotten: no push held for the next one.
		let late = await apply("Gone")
		ProfileSync.reset()
		writes.finish("Gone", failing: false)
		await late?.value
		#expect(!ProfileSync.pushWhenBack)
		#expect(ProfileSync.pendingRadioName == nil)

		// Control: written with the same radio, the push goes (held here: this host has no radio).
		let kept = await apply("Same")
		writes.finish("Same", failing: false)
		await kept?.value
		#expect(ProfileSync.pushWhenBack)
	}

	// MARK: The watchdog

	/// The per-download decision, with the radio as `RadioReadiness` has it.
	@Test func theWatchdogGoesByTheRadio() {
		let now = start + .seconds(3600)
		var calls = 0
		func steps(_ clock: PhotoWatchdog.Clock, radio: RadioReadiness, askQueued: Bool = false, group: Bool = true) -> ProfileRules.PhotoRetry? {
			PhotoWatchdog(clocks: [5: clock]).steps(now: now, radio: radio, askQueued: { _ in askQueued }, stillAskedGroup: { _ in calls += 1; return group })[5]
		}
		let quiet30 = PhotoWatchdog.Clock(lastActivity: now - .seconds(30))
		let quiet61 = PhotoWatchdog.Clock(lastActivity: now - .seconds(61))
		let ready = RadioReadiness(ready: true, awaySince: nil)
		#expect(steps(quiet30, radio: RadioReadiness(ready: false, awaySince: now - .seconds(11 * 60))) == .giveUp)
		#expect(steps(quiet30, radio: RadioReadiness(ready: false, awaySince: now - .seconds(9 * 60))) == .wait)
		#expect(steps(quiet61, radio: ready) == .askAgain)
		#expect(steps(quiet61, radio: ready, askQueued: true) == .wait)
		var tried = quiet61
		tried.attempts = ProfileOutbox.maxPhotoAttempts
		#expect(steps(tried, radio: ready) == .giveUp)
		#expect(steps(quiet61, radio: ready, group: false) == .giveUp)
		// Away, its group reads as gone: it waits, and the group isn't even looked up.
		calls = 0
		#expect(steps(quiet61, radio: RadioReadiness(ready: false, awaySince: now - .seconds(60)), group: false) == .wait)
		#expect(calls == 0)
	}

	// MARK: Room, with one in flight

	/// An entry in flight keeps its place in its room until it's finished, so one put
	/// back never makes the room hold more than it may. A newer one for the same item still gets in.
	@Test(arguments: [ProfileOutbox.Reason.myEdit, .myMessage])
	func anEntryInFlightKeepsItsPlace(reason: ProfileOutbox.Reason) throws {
		let room = ProfileOutbox.room(reason)
		for outcome in [ProfileOutbox.Outcome.noRadio, .sent] {
			var outbox = ProfileOutbox()
			for num in 0..<Int64(room) {
				do { let ok = outbox.schedule(.card(.person(100 + num)), reason: reason, delay: 0...0, now: start); #expect(ok) }
			}
			let taken = outbox.take(now: start)
			let entry = try #require(taken)
			#expect(outbox.entries.count == room - 1)
			do { let ok = !outbox.schedule(.card(.person(900)), reason: reason, delay: 0...0, now: start); #expect(ok, "\(reason)") }
			do { let ok = outbox.schedule(entry.item, reason: reason, delay: 0...0, now: start); #expect(ok, "\(reason)") }
			outbox.finish(entry, outcome, at: start)
			#expect(outbox.entries.count == room, "\(reason) \(outcome)")
			// Finished: what's queued is all there is.
			if outcome == .sent {
				outbox.remove(entry.item)
				do { let ok = outbox.schedule(.card(.person(901)), reason: reason, delay: 0...0, now: start); #expect(ok, "\(reason)") }
			}
		}
		// Put back with nothing queued for it meanwhile: the room's exactly full again.
		var outbox = ProfileOutbox()
		for num in 0..<Int64(room) {
			outbox.schedule(.card(.person(100 + num)), reason: reason, delay: 0...0, now: start)
		}
		let taken = outbox.take(now: start)
		let entry = try #require(taken)
		do { let ok = !outbox.schedule(.card(.person(900)), reason: reason, delay: 0...0, now: start); #expect(ok) }
		outbox.finish(entry, .noRadio, at: start)
		#expect(outbox.entries.count == room)
		do { let ok = !outbox.schedule(.card(.person(902)), reason: reason, delay: 0...0, now: start); #expect(ok) }
	}

	// MARK: Photo downloads without a radio

	@Test func aDownloadWaitsForTheRadioThenGivesUp() {
		let quiet = Duration.seconds(300)
		#expect(ProfileRules.photoRetry(quietFor: quiet, attempts: 1, askQueued: false, stillAskedGroup: false, radioAwayFor: .seconds(599)) == .wait)
		#expect(ProfileRules.photoRetry(quietFor: quiet, attempts: 1, askQueued: true, stillAskedGroup: true, radioAwayFor: .seconds(30)) == .wait)
		#expect(ProfileRules.photoRetry(quietFor: quiet, attempts: 1, askQueued: false, stillAskedGroup: true, radioAwayFor: .seconds(601)) == .giveUp)
		#expect(ProfileRules.photoRetry(quietFor: quiet, attempts: 1, askQueued: true, stillAskedGroup: true, radioAwayFor: .seconds(601)) == .giveUp)
		#expect(ProfileRules.photoRetry(quietFor: quiet, attempts: 1, askQueued: false, stillAskedGroup: true, radioAwayFor: nil) == .askAgain)

		// Away 11 minutes: given up once, ten minutes into it, without using a try.
		for seed in Self.seeds.prefix(5) {
			let lane = LaneDrain(start: start, seed: seed)
			#expect(lane.requestPhoto(901))
			lane.radioDown(5, 5 + 11 * 60)
			lane.run(for: .seconds(15 * 60))
			#expect(lane.abandoned.map(\.num) == [901], "seed \(seed)")
			#expect(lane.abandoned.first.map { $0.at - lane.t(5) > ProfileOutbox.maxRadioAway && $0.at - lane.t(5) <= ProfileOutbox.maxRadioAway + .seconds(10) } == true, "seed \(seed)")
			#expect(lane.sends(.photoAsk(901)).count == 1, "seed \(seed)")
		}
		// Away 9:50: still going when it's back, and asked again.
		let lane = LaneDrain(start: start, seed: 1)
		#expect(lane.requestPhoto(902))
		lane.radioDown(5, 595)
		lane.run(for: .seconds(620))
		#expect(lane.abandoned.isEmpty)
		#expect(lane.sends(.photoAsk(902)).count == 2)
		#expect(lane.sends(.photoAsk(902)).last.map { $0 - lane.t(595) <= .seconds(20) } == true)
		// And none is asked for while it's away.
		let away = LaneDrain(start: start, seed: 1)
		away.radioDown(0, 60)
		away.run(for: .seconds(1))
		#expect(!away.requestPhoto(903))
		#expect(away.outbox.entries.isEmpty)
	}

	@Test func photoLines() {
		typealias Line = ProfileRules.PhotoLine
		#expect(ProfileRules.photoLine(downloading: true, radioAway: false, full: true, lastAsk: nil) == nil)
		#expect(ProfileRules.photoLine(downloading: true, radioAway: true, full: false, lastAsk: nil) == Line.waitingForRadio)
		#expect(ProfileRules.photoLine(downloading: false, radioAway: true, full: true, lastAsk: nil) == Line.connectRadio)
		#expect(ProfileRules.photoLine(downloading: false, radioAway: false, full: false, lastAsk: .noRadio) == Line.connectRadio)
		#expect(ProfileRules.photoLine(downloading: false, radioAway: false, full: true, lastAsk: nil) == Line.busy)
		#expect(ProfileRules.photoLine(downloading: false, radioAway: false, full: false, lastAsk: .busy) == Line.busy)
		#expect(ProfileRules.photoLine(downloading: false, radioAway: false, full: false, lastAsk: nil) == nil)
		#expect(ProfileRules.photoLine(downloading: false, radioAway: false, full: false, lastAsk: .unavailable) == nil)
	}

	/// A finished download's ask leaves at once, so its place is free for the next one.
	@Test func aDownloadsAskFreesItsPlaceWhenRemoved() {
		var outbox = ProfileOutbox()
		for num in 1...Int64(ProfileOutbox.room(.photoAsk)) {
			outbox.schedule(.photoAsk(num), reason: .photoAsk, delay: 60...60, now: start)
		}
		do { let ok = !outbox.schedule(.photoAsk(99), reason: .photoAsk, delay: 0...0, now: start); #expect(ok) }
		outbox.remove(.photoAsk(1))
		do { let ok = outbox.schedule(.photoAsk(99), reason: .photoAsk, delay: 0...0, now: start); #expect(ok) }
	}

	// MARK: Room

	/// A push held by the edit interval, then two people new to my top 8: both still fit.
	@Test func aHeldPushLeavesRoomForANewOne() {
		var outbox = ProfileOutbox()
		var mine: [ProfileOutbox.Item] = (1...Int64(8)).map { .card(.person($0)) }
		mine += (1...Int32(7)).map { .card(.group($0, key: "\($0):G:1")) }
		for item in mine {
			outbox.schedule(item, reason: .myEdit, delay: 0...0, now: start)
		}
		let sent = OutboxDrain.run(&outbox, from: start, for: .seconds(50))
		#expect(sent.count == 15)
		let again = start + .seconds(50)
		for item in mine {
			do { let ok = outbox.schedule(item, reason: .myEdit, delay: 0...0, now: again); #expect(ok) }
		}
		#expect(outbox.take(now: again) == nil)
		let newcomers = [Int64(20), 21].map { outbox.schedule(.card(.person($0)), reason: .myEdit, delay: 0...0, now: again) }
		#expect(newcomers == [true, true])
	}

	/// Edits merged into 32 waiting answers don't take my edits' room, and don't free the answers'.
	@Test func mergingDoesntMoveAnEntrysRoom() {
		var outbox = ProfileOutbox()
		for num in 0..<Int64(ProfileOutbox.room(.answer)) {
			do { let ok = outbox.schedule(.card(.person(1000 + num)), reason: .answer, delay: 60...60, now: start); #expect(ok) }
		}
		for num in 0..<Int64(16) {
			do { let ok = outbox.schedule(.card(.person(1000 + num)), reason: .myEdit, delay: 1...1, now: start); #expect(ok) }
		}
		#expect(outbox.entries.count == ProfileOutbox.room(.answer))
		do { let ok = outbox.schedule(.card(.person(5000)), reason: .myEdit, delay: 1...1, now: start); #expect(ok) }
		do { let ok = !outbox.schedule(.card(.person(6000)), reason: .answer, delay: 1...1, now: start); #expect(ok) }
		// Put back after a send that found no radio, it keeps the room it had.
		guard let entry = outbox.take(now: start + .seconds(1)) else {
			Issue.record("nothing to send")
			return
		}
		outbox.finish(entry, .noRadio, at: start + .seconds(1))
		#expect(outbox.entries.first { $0.item == entry.item }?.roomReason == entry.roomReason)
	}

	// MARK: Pieces between other packets

	/// While pieces wait, never more than `maxBetweenPieces` other packets in a row, mine included.
	@Test func piecesWaitAtMostAFewPackets() {
		for seed in Self.seeds {
			let lane = LaneDrain(start: start, seed: seed)
			#expect(lane.photoRequest(from: 500, slots: 40))
			for num in 1...Int64(16) {
				lane.schedule(.card(.person(600 + num)), reason: .myMessage, delay: 0...1)
				lane.schedule(.card(.person(700 + num)), reason: .reply, delay: 0...1)
				lane.schedule(.card(.person(800 + num)), reason: .myEdit, delay: 0...1)
			}
			lane.run(for: .seconds(600))
			let lastPiece = lane.log.lastIndex { $0.piece != nil } ?? 0
			var run = 0
			var longest = 0
			for sent in lane.log.prefix(lastPiece) {
				run = sent.piece == nil ? run + 1 : 0
				longest = max(longest, run)
			}
			#expect(lane.pieces(for: 500).count == 40, "seed \(seed)")
			#expect(longest <= ProfileOutbox.maxBetweenPieces, "seed \(seed): \(longest)")
		}
	}

	/// How many times someone would ask again for what's missing, from when their pieces came.
	private static func reasks(asked: ContinuousClock.Instant, pieces: [ContinuousClock.Instant]) -> Int {
		var last = asked
		var longest = Duration.zero
		var count = 0
		for time in pieces {
			if time - last > ProfileRules.photoPatience(longestGap: longest) { count += 1 }
			longest = max(longest, time - last)
			last = time
		}
		return count
	}

	/// Four people getting my photo, each write taking a while, and a burst of 16 first DMs:
	/// none of them goes quiet long enough to ask again, and my cards still go.
	@Test(arguments: [0.0, 0.5, 2.0])
	func aBurstOfMyCardsDoesntMakeAnyoneAskAgain(latency: Double) {
		for jobs in [1, 4] {
			for seed in Self.seeds.prefix(5) {
				let lane = LaneDrain(start: start, seed: seed)
				lane.latency = .seconds(latency)
				let people = (0..<Int64(jobs)).map { 9000 + $0 }
				for num in people {
					#expect(lane.photoRequest(from: num, slots: 30))
				}
				let burst = 20.0
				let dms = (1...Int64(16)).map { ProfileOutbox.Item.card(.person(9100 + $0)) }
				lane.at(burst) { lane in
					for item in dms {
						lane.schedule(item, reason: .myMessage, delay: ProfileOutbox.afterMessage)
					}
				}
				lane.run(for: .seconds(900))
				for num in people {
					let pieces = lane.pieces(for: num)
					#expect(pieces.count == 30, "J\(jobs) L\(latency) seed \(seed)")
					#expect(Self.reasks(asked: lane.start, pieces: pieces) == 0, "J\(jobs) L\(latency) seed \(seed) \(num)")
				}
				// Each card waits for the ones before it, and a piece after every few.
				let slot = ProfileOutbox.spacing + .seconds(latency)
				let bound = .seconds(ProfileOutbox.afterMessage.upperBound) + slot * (dms.count + dms.count / ProfileOutbox.maxBetweenPieces + 1)
				for item in dms {
					#expect(lane.sends(item).first.map { $0 - lane.t(burst) <= bound } == true, "J\(jobs) L\(latency) seed \(seed) \(item)")
				}
			}
		}
	}
}

/// Every room and cap in the outbox and the photo limiter, under any order of what the
/// lane does to them. As in the lane, each has at most one hand-out outstanding. Each bound is
/// also counted when it's met exactly, so the test can't quietly stop reaching one.
@Suite("Caps under any sequence")
struct CapInvariantTests {
	typealias Instant = ContinuousClock.Instant

	/// Ops at which a bound was met exactly, over every seed.
	private struct Reached {
		var counts: [String: Int]

		init() {
			let limiter = ["limiter queued", "limiter one key", "limiter groups", "limiter people"]
			let rooms = ProfileOutbox.Reason.allCases.map { "room \($0)" }
			let caps = ProfileOutbox.Reason.allCases.filter { ProfileOutbox.cap($0) != nil }.map { "cap \($0)" }
			counts = Dictionary(uniqueKeysWithValues: (limiter + rooms + caps).map { ($0, 0) })
		}

		mutating func check(_ bound: String, _ value: Int, _ limit: Int) {
			if value == limit { counts[bound, default: 0] += 1 }
		}
	}

	@Test func capsHoldUnderAnySequence() {
		var reached = Reached()
		for seed in 0..<200 {
			var random = SeededRandom(seed: UInt64(seed))
			limiterHolds(seed: seed, &random, &reached)
			outboxHolds(seed: seed, &random, &reached)
		}
		let report = reached.counts.sorted { $0.key < $1.key }
		print("Caps reached (ops at each bound over 200 seeds): \(report.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
		for (bound, count) in report {
			#expect(count > 0, "\(bound) was never reached")
		}
	}

	private func limiterHolds(seed: Int, _ random: inout SeededRandom, _ reached: inout Reached) {
		var now = ContinuousClock.now
		// Every third seed is one long burst (time hardly moves) with photos of the largest
		// size, so a whole class's airtime can be used up.
		let burst = seed % 3 == 0
		var keys: [PhotoSendLimiter.Key] = []
		var slotCount: [PhotoSendLimiter.Key: Int] = [:]
		let audiences: [PhotoAudience] = (1...4).map { .group(channel: Int32($0), key: "\($0):Group:9") } + (1...4).map { .person(Int64($0)) }
		for audience in audiences {
			for version in [UInt32(1), 2] {
				let key = PhotoSendLimiter.Key(audience: audience, version: version)
				keys.append(key)
				slotCount[key] = burst && version == 1 ? PhotoRequest.maxSlots - Int.random(in: 0...2, using: &random) : Int.random(in: 1...12, using: &random)
			}
		}
		var limiter = PhotoSendLimiter()
		var outstanding: (key: PhotoSendLimiter.Key, slot: UInt8)?
		for op in 0..<(burst ? 1500 : 600) {
			var putBack: (key: PhotoSendLimiter.Key, slot: UInt8)?
			switch Int.random(in: 0..<100, using: &random) {
			case 0..<45:
				let key = keys[Int.random(in: 0..<keys.count, using: &random)]
				let count = slotCount[key] ?? 1
				var wanted: Set<UInt8>?
				if Bool.random(using: &random) {
					var some = Set<UInt8>()
					for slot in 0..<count where Bool.random(using: &random) { some.insert(UInt8(slot)) }
					wanted = some
				}
				_ = limiter.admit(wanted, slotCount: count, for: key, now: now)
			case 45..<70:
				guard outstanding == nil else { break }
				outstanding = limiter.next(now: now)
			case 70..<90:
				guard let piece = outstanding else { break }
				switch Int.random(in: 0..<3, using: &random) {
				case 0:
					limiter.putBack(piece)
					putBack = piece
				case 1:
					limiter.cancel(piece.key, unsent: piece.slot)
				default:
					limiter.delivered(piece.key)
				}
				outstanding = nil
			default:
				// A piece is out for one send: time only moves on between sends.
				guard outstanding == nil else { break }
				now += .seconds(burst ? Int.random(in: 0...3, using: &random) : Int.random(in: 0...300, using: &random))
			}

			let at = "seed \(seed), limiter op \(op)"
			let outsideQueue = outstanding.map { limiter.queued(for: $0.key).isEmpty } ?? false
			guard limiter.queuedCount + (outsideQueue ? 1 : 0) <= PhotoSendLimiter.maxQueued, limiter.queuedCount <= PhotoSendLimiter.maxQueued else {
				Issue.record("\(at): \(limiter.queuedCount) queued, one more out: \(outsideQueue)")
				return
			}
			reached.check("limiter queued", limiter.queuedCount + (outsideQueue ? 1 : 0), PhotoSendLimiter.maxQueued)
			for key in keys {
				let charged = limiter.charged(key, now: now) + limiter.queued(for: key).count
				guard charged <= (slotCount[key] ?? 0) * PhotoSendLimiter.photosPerKey else {
					Issue.record("\(at): \(charged) for one key")
					return
				}
				reached.check("limiter one key", charged, (slotCount[key] ?? 0) * PhotoSendLimiter.photosPerKey)
			}
			for groups in [true, false] {
				let queued = keys.filter { $0.audience.isGroup == groups }.reduce(0) { $0 + limiter.queued(for: $1).count }
				guard limiter.charged(groups: groups, now: now) + queued <= PhotoSendLimiter.classSlots else {
					Issue.record("\(at): class over its slots (groups \(groups))")
					return
				}
				reached.check(groups ? "limiter groups" : "limiter people", limiter.charged(groups: groups, now: now) + queued, PhotoSendLimiter.classSlots)
			}
			if let putBack, !limiter.queued(for: putBack.key).contains(putBack.slot) {
				Issue.record("\(at): a piece put back isn't queued")
				return
			}
		}
	}

	private func outboxHolds(seed: Int, _ random: inout SeededRandom, _ reached: inout Reached) {
		var now = ContinuousClock.now
		// More of each kind than its reason has room for, so every room can fill.
		let cards: [ProfileOutbox.Item] = (1...40).map { .card(.person(Int64($0))) } + (1...10).map { .card(.group(Int32($0), key: "\($0):Group:9")) }
		let cardAsks: [ProfileOutbox.Item] = (1...10).map { .cardAsk(Int64(100 + $0)) }
		let photoAsks: [ProfileOutbox.Item] = (1...8).map { .photoAsk(Int64(200 + $0)) }
		let cardReasons: [ProfileOutbox.Reason] = [.myMessage, .myEdit, .reply, .answer]
		// Most seeds lean on one reason, so that one's room fills and its cap is reached.
		let focus: ProfileOutbox.Reason? = seed % 7 == 0 ? nil : ProfileOutbox.Reason.allCases[seed % 7 - 1]
		let delays = [0.0...0.0, 0.0...30.0]
		var outbox = ProfileOutbox()
		var outstanding: ProfileOutbox.Entry?
		var lastWent: Instant?
		for op in 0..<600 {
			let at = "seed \(seed), outbox op \(op)"
			switch Int.random(in: 0..<100, using: &random) {
			case 0..<30:
				let reason: ProfileOutbox.Reason
				if let focus, Int.random(in: 0..<8, using: &random) != 0 {
					reason = focus
				} else {
					switch Int.random(in: 0..<4, using: &random) {
					case 0, 1: reason = cardReasons[Int.random(in: 0..<cardReasons.count, using: &random)]
					case 2: reason = .ask
					default: reason = .photoAsk
					}
				}
				let item: ProfileOutbox.Item
				switch reason {
				case .ask: item = cardAsks[Int.random(in: 0..<cardAsks.count, using: &random)]
				case .photoAsk: item = photoAsks[Int.random(in: 0..<photoAsks.count, using: &random)]
				default: item = cards[Int.random(in: 0..<cards.count, using: &random)]
				}
				let delay = delays[Int.random(in: 0..<delays.count, using: &random)]
				outbox.schedule(item, reason: reason, delay: delay, isReask: Bool.random(using: &random), now: now, using: &random)
			case 30..<55:
				guard outstanding == nil else { break }
				// Photo asks get one turn in ten: with pieces waiting too, they couldn't fill their cap.
				let piecesWaiting = focus != .photoAsk && Bool.random(using: &random)
				if case .entry(let entry)? = outbox.next(now: now, piecesWaiting: piecesWaiting) {
					outstanding = entry
				}
			case 55..<80:
				guard let entry = outstanding else { break }
				// Mostly charged, so the caps fill.
				let outcomes: [ProfileOutbox.Outcome] = [.sent, .sent, .failed, .noRadio, .notNeeded]
				let outcome = outcomes[Int.random(in: 0..<outcomes.count, using: &random)]
				if outcome == .sent || outcome == .failed {
					if let lastWent, now - lastWent < ProfileOutbox.spacing {
						Issue.record("\(at): two packets \(now - lastWent) apart")
						return
					}
					lastWent = now
				}
				outbox.finish(entry, outcome, at: now)
				outstanding = nil
			case 80..<82:
				outbox.remove(photoAsks[Int.random(in: 0..<photoAsks.count, using: &random)])
			default:
				// A send takes a moment. Between sends, mostly the spacing or a little more (so
				// caps fill within their window), now and then a long quiet spell, but not while
				// leaning on one reason, whose cap needs a busy window.
				if outstanding != nil {
					now += .seconds(Int.random(in: 0...5, using: &random))
				} else if focus == nil, Int.random(in: 0..<40, using: &random) == 0 {
					now += .seconds(Int.random(in: 0...900, using: &random))
				} else {
					now += .seconds(Int.random(in: 3...(focus == nil ? 8 : 4), using: &random))
				}
			}

			for reason in ProfileOutbox.Reason.allCases {
				let waiting = outbox.entries.filter { ($0.roomReason ?? $0.lead) == reason }.count
				let out = outstanding.map { ($0.roomReason ?? $0.lead) == reason && !outbox.contains($0.item) } ?? false
				guard waiting + (out ? 1 : 0) <= ProfileOutbox.room(reason) else {
					Issue.record("\(at): \(reason) holds \(waiting) and one out \(out); room \(ProfileOutbox.room(reason))")
					return
				}
				reached.check("room \(reason)", waiting + (out ? 1 : 0), ProfileOutbox.room(reason))
				if let cap = ProfileOutbox.cap(reason) {
					guard outbox.charged(reason, now: now) <= cap else {
						Issue.record("\(at): \(reason) charged \(outbox.charged(reason, now: now)) over its cap \(cap)")
						return
					}
					reached.check("cap \(reason)", outbox.charged(reason, now: now), cap)
				}
			}
		}
	}
}
