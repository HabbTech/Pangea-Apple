//
//  ChatsListTests.swift
//  MeshtasticTests
//

import Foundation
import SwiftData
import Testing
@testable import Meshtastic

/// The Chats list's order. Each chat's date is a database fetch, so the dates are given here
/// and counted: the list works each one out once, however many chats it sorts. Nothing here
/// touches the app's own database: each test has an in-memory one.
@Suite("Chats list")
@MainActor
struct ChatsListTests {

	private let container = PangeaTestStore.make()
	private var context: ModelContext { container.mainContext }

	private func myInfo(groups: [(index: Int32, name: String)], extra: [ChannelEntity] = []) -> MyInfoEntity {
		let info = context.add(MyInfoEntity())
		info.myNodeNum = 1
		let everyone = context.add(ChannelEntity())
		everyone.index = 0
		everyone.role = 1
		everyone.name = ""
		var channels = [everyone]
		for group in groups {
			let channel = context.add(ChannelEntity())
			channel.index = group.index
			channel.role = 2
			channel.name = group.name
			channels.append(channel)
		}
		info.channels = channels + extra
		return info
	}

	private func user(_ num: Int64) -> UserEntity {
		let user = context.add(UserEntity())
		user.num = num
		user.lastMessage = Date()
		return user
	}

	/// What the list did before it worked each date out once: the date on both sides of
	/// every comparison.
	private func reference(_ items: [ChatSummary], _ date: (ChatSummary) -> Date) -> [ChatSummary] {
		items.sorted { lhs, rhs in
			if lhs.isEveryone != rhs.isEveryone { return lhs.isEveryone }
			return date(lhs) > date(rhs)
		}
	}

	@Test func everyoneFirstThenGroupsAndDMsNewestFirst() {
		let disabled = context.add(ChannelEntity())
		disabled.index = 5
		disabled.role = 0
		disabled.name = "Off"
		let info = myInfo(groups: [(1, "Hike"), (2, "Camp")], extra: [disabled])
		let me = user(1)
		let users = [user(10), user(11), user(12), me]
		let now = Date()
		let dates: [String: Date] = [
			"g0": .distantPast, // Everyone Nearby, with nothing in it yet
			"g1": now.addingTimeInterval(-50),
			"g2": .distantPast, // a group with no messages yet
			"u10": now.addingTimeInterval(-100),
			"u11": now, // a DM newer than both groups
			"u12": now.addingTimeInterval(-60)
		]
		var calls = 0
		let list = ChatsView.list(myInfo: info, users: users, myNum: 1) { chat in
			calls += 1
			return dates[chat.id] ?? .distantPast
		}
		#expect(list.map(\.id) == ["g0", "u11", "g1", "u12", "u10", "g2"])
		#expect(calls == 6)
	}

	/// The same order as the comparator that fetched on both sides, ties included, over many
	/// random lists; and one date per chat, where that comparator asked for about 4·n·log n.
	@Test func sameOrderAsBeforeWithOneDatePerChat() {
		let info = myInfo(groups: (1...7).map { (Int32($0), "G\($0)") })
		let users = (0..<200).map { user(100 + Int64($0)) }
		let base = Date()
		for round in 0..<40 {
			var generator = SplitMix(seed: UInt64(round))
			var dates: [String: Date] = [:]
			for chat in ChatsView.list(myInfo: info, users: users, myNum: -1, lastDate: { _ in base }) {
				// Few distinct seconds, so many chats tie.
				dates[chat.id] = Bool.random(using: &generator) && round % 4 == 0 ? .distantPast : base.addingTimeInterval(-Double(Int.random(in: 0..<60, using: &generator)))
			}
			let shuffled = users.shuffled(using: &generator)
			var calls = 0
			let list = ChatsView.list(myInfo: info, users: shuffled, myNum: shuffled[0].num) { chat in
				calls += 1
				return dates[chat.id]!
			}
			var items: [ChatSummary] = info.sortedChannels.map { .group($0) }
			items += shuffled.dropFirst().map { .dm($0) }
			var referenceCalls = 0
			let expected = reference(items) { chat in
				referenceCalls += 1
				return dates[chat.id]!
			}
			#expect(list.map(\.id) == expected.map(\.id), "round \(round)")
			#expect(list.first?.id == "g0")
			#expect(!list.contains { $0.id == "u\(shuffled[0].num)" })
			#expect(calls == 8 + 199, "round \(round)")
			if round == 0 { print("Chats list dates for 207 chats: \(calls); the comparator that fetched on both sides: \(referenceCalls)") }
		}
	}
}

/// What a chat's row draws. The row redraws only when this value changes, so it has to change
/// with every new message, read, rename and short name, and stay equal when nothing did. The
/// message and the unread count are given, as `ChatSummary.row` would fetch them.
@Suite("Chat rows")
@MainActor
struct ChatRowModelTests {

	private let container = PangeaTestStore.make()
	private var context: ModelContext { container.mainContext }

	private func channel(_ index: Int32, _ name: String) -> ChannelEntity {
		let channel = context.add(ChannelEntity())
		channel.index = index
		channel.role = index == 0 ? 1 : 2
		channel.name = name
		return channel
	}

	private func user(_ num: Int64, _ longName: String, short: String) -> UserEntity {
		let user = context.add(UserEntity())
		user.num = num
		user.longName = longName
		user.shortName = short
		return user
	}

	private func message(_ text: String?, from: UserEntity?, at time: Int32) -> MessageEntity {
		let message = context.add(MessageEntity())
		message.messagePayload = text
		message.fromUser = from
		message.messageTimestamp = time
		return message
	}

	private func radioName(_ user: UserEntity) -> String { user.longName ?? "" }

	@Test func directMessage() {
		let ann = user(10, "Ann Lee", short: "AL")
		let empty = ChatRowModel.make(chat: .dm(ann), last: nil, unread: 0, name: radioName)
		#expect(empty == ChatRowModel(title: "Ann Lee", preview: "Say hello", date: nil, unread: 0, avatar: .person(num: 10, shortName: "AL")))
		let last = message("hi there", from: ann, at: 1_700_000_000)
		let row = ChatRowModel.make(chat: .dm(ann), last: last, unread: 2, name: radioName)
		#expect(row == ChatRowModel(title: "Ann Lee", preview: "hi there", date: Date(timeIntervalSince1970: 1_700_000_000), unread: 2, avatar: .person(num: 10, shortName: "AL")))
	}

	@Test func groupAndEveryone() {
		let ann = user(10, "Ann Lee", short: "AL")
		let hike = channel(2, "Hike")
		let empty = ChatRowModel.make(chat: .group(hike), last: nil, unread: 0, name: radioName)
		#expect(empty == ChatRowModel(title: "Hike", preview: "No messages yet. Invite people to start.", date: nil, unread: 0, avatar: .group(key: ChatIconStore.key(name: "Hike", psk: hike.psk ?? Data()))))
		let post = message("on my way", from: ann, at: 1_700_000_100)
		let row = ChatRowModel.make(chat: .group(hike), last: post, unread: 1, name: radioName)
		#expect(row == ChatRowModel(title: "Hike", preview: "Ann: on my way", date: Date(timeIntervalSince1970: 1_700_000_100), unread: 1, avatar: .group(key: ChatIconStore.key(name: "Hike", psk: hike.psk ?? Data()))))
		// No sender, or a blank name: no prefix.
		#expect(ChatRowModel.make(chat: .group(hike), last: message("anon", from: nil, at: 1), unread: 0, name: radioName).preview == "anon")
		#expect(ChatRowModel.make(chat: .group(hike), last: post, unread: 0) { _ in " " }.preview == "on my way")
		let everyone = channel(0, "")
		let nearby = ChatRowModel.make(chat: .group(everyone), last: nil, unread: 0, name: radioName)
		#expect(nearby == ChatRowModel(title: "Everyone Nearby", preview: "Public chat with everyone in range", date: nil, unread: 0, avatar: .everyone))
		#expect(ChatRowModel.make(chat: .group(everyone), last: post, unread: 0, name: radioName).preview == "Ann: on my way")
	}

	@Test func changesWithEachThingTheRowShows() {
		let ann = user(10, "Ann Lee", short: "AL")
		let hike = channel(2, "Hike")
		let first = message("one", from: ann, at: 100)
		let dm = ChatRowModel.make(chat: .dm(ann), last: first, unread: 1, name: radioName)
		let group = ChatRowModel.make(chat: .group(hike), last: first, unread: 1, name: radioName)

		// Nothing changed, nothing to redraw.
		#expect(ChatRowModel.make(chat: .dm(ann), last: first, unread: 1, name: radioName) == dm)
		#expect(ChatRowModel.make(chat: .group(hike), last: first, unread: 1, name: radioName) == group)

		// A new message, with its own text and time.
		let second = message("two", from: ann, at: 200)
		#expect(ChatRowModel.make(chat: .dm(ann), last: second, unread: 1, name: radioName) != dm)
		// The same text a second later still moves the time.
		let again = message("one", from: ann, at: 101)
		#expect(ChatRowModel.make(chat: .dm(ann), last: again, unread: 1, name: radioName) != dm)
		// Every message gone.
		#expect(ChatRowModel.make(chat: .dm(ann), last: nil, unread: 0, name: radioName) != dm)
		// Read: only the badge changes.
		#expect(ChatRowModel.make(chat: .dm(ann), last: first, unread: 0, name: radioName) != dm)
		#expect(ChatRowModel.make(chat: .group(hike), last: first, unread: 2, name: radioName) != group)
		// A nickname or a new card name, through `name`; the group's sender prefix follows too.
		#expect(ChatRowModel.make(chat: .dm(ann), last: first, unread: 1) { _ in "Annie" } != dm)
		#expect(ChatRowModel.make(chat: .group(hike), last: first, unread: 1) { _ in "Annie" } != group)
		// The radio's long name.
		ann.longName = "Ann Renamed"
		#expect(ChatRowModel.make(chat: .dm(ann), last: first, unread: 1, name: radioName) != dm)
		ann.longName = "Ann Lee"
		// The radio's short name: the avatar's initials.
		ann.shortName = "AR"
		#expect(ChatRowModel.make(chat: .dm(ann), last: first, unread: 1, name: radioName) != dm)
		ann.shortName = "AL"
		#expect(ChatRowModel.make(chat: .dm(ann), last: first, unread: 1, name: radioName) == dm)
		// The group renamed.
		hike.name = "Trek"
		#expect(ChatRowModel.make(chat: .group(hike), last: first, unread: 1, name: radioName) != group)
	}

	/// Each field on its own makes two rows unequal.
	@Test func everyFieldCounts() {
		let base = ChatRowModel(title: "A", preview: "p", date: Date(timeIntervalSince1970: 1), unread: 1, avatar: .person(num: 1, shortName: "A"))
		#expect(base == ChatRowModel(title: "A", preview: "p", date: Date(timeIntervalSince1970: 1), unread: 1, avatar: .person(num: 1, shortName: "A")))
		let changes: [(String, (inout ChatRowModel) -> Void)] = [
			("title", { $0.title = "B" }),
			("preview", { $0.preview = "q" }),
			("date", { $0.date = Date(timeIntervalSince1970: 2) }),
			("no date", { $0.date = nil }),
			("unread", { $0.unread = 0 }),
			("short name", { $0.avatar = .person(num: 1, shortName: "B") }),
			("no short name", { $0.avatar = .person(num: 1, shortName: nil) }),
			("num", { $0.avatar = .person(num: 2, shortName: "A") }),
			("group", { $0.avatar = .group(key: "a") }),
			("group icon", { $0.avatar = .group(key: "b") })
		]
		for (field, change) in changes {
			var copy = base
			change(&copy)
			#expect(copy != base, "\(field)")
		}
		#expect(ChatRowModel.Avatar.group(key: "everyone") != .everyone)
	}
}

/// A seeded generator, so a failing round can be replayed.
private struct SplitMix: RandomNumberGenerator {
	var state: UInt64
	init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}

/// Standard mode puts the status line under a sent message in plain words; Expert Mode keeps the
/// mesh's own terms. Icon, colour and Try Again stay as the mesh status has them.
@Suite("Delivery wording")
@MainActor
struct DeliveryWordingTests {

	private func message(acked: Bool = false, real: Bool = false, error: RoutingError? = nil, sentAgo: TimeInterval = 10) -> MessageEntity {
		let message = MessageEntity()
		message.receivedACK = acked
		message.realACK = real
		message.ackError = Int32(error?.rawValue ?? 0)
		message.messageTimestamp = Int32(Date().timeIntervalSince1970 - sentAgo)
		return message
	}

	@Test func plainWordsOutsideExpertMode() {
		let saved = UserDefaults.expertModeEnabled
		UserDefaults.expertModeEnabled = false
		defer { UserDefaults.expertModeEnabled = saved }
		#expect(message().deliveryStatus(isDirectMessage: true).text == DeliveryStatus.waiting)
		#expect(message(acked: true, real: true).deliveryStatus(isDirectMessage: true).text == String(localized: "Delivered"))
		#expect(message(acked: true).deliveryStatus(isDirectMessage: true).text == DeliveryStatus.relayedOnly)
		#expect(message(acked: true).deliveryStatus(isDirectMessage: false).text == String(localized: "Sent"))
		#expect(message(error: .noRoute).deliveryStatus(isDirectMessage: true).text == DeliveryStatus.text(for: .noRoute, isDirect: true))
		let stale = message(sentAgo: MessageEntity.sendAckTimeout + 60)
		#expect(stale.deliveryStatus(isDirectMessage: true).text == DeliveryStatus.text(for: nil, isDirect: true))
		#expect(stale.deliveryStatus(isDirectMessage: true).canRetry == stale.meshDeliveryStatus(isDirectMessage: true).canRetry)
	}

	@Test func meshWordsInExpertMode() {
		let saved = UserDefaults.expertModeEnabled
		UserDefaults.expertModeEnabled = true
		defer { UserDefaults.expertModeEnabled = saved }
		let sent = message(acked: true, real: true)
		#expect(sent.deliveryStatus(isDirectMessage: true).text == sent.meshDeliveryStatus(isDirectMessage: true).text)
	}
}
