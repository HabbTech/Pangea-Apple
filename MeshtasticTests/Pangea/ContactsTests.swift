//
//  ContactsTests.swift
//  MeshtasticTests
//

import Foundation
import CoreData
import MeshtasticProtobufs
import Testing
@testable import Meshtastic

/// Saved contacts, deleting a chat, and who a group invite can go to. Nothing here touches
/// the app's own profiles or database: each test has a temporary folder or an in-memory one.
@Suite("Contacts")
@MainActor
struct ContactsTests {

	private let persistence = PersistenceController(inMemory: true)

	private func tempFolder() -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	}

	// MARK: Saved contacts

	@Test func contactSurvivesARelaunch() {
		let folder = tempFolder()
		let store = ProfileStore(folder: folder)
		store.setNickname("Bear", for: 7)
		store.setContact(true, for: 7, radioName: "Bear Radio")
		store.setContact(true, for: 9)
		#expect(store.isContact(7))

		let reopened = ProfileStore(folder: folder)
		#expect(reopened.isContact(7))
		#expect(reopened.isContact(9))
		#expect(!reopened.isContact(8))
		#expect(reopened.profile(7)?.contactName == "Bear Radio")
		#expect(reopened.profile(7)?.nickname == "Bear")

		// Removing keeps the rest of what we know about them.
		reopened.setContact(false, for: 7)
		let again = ProfileStore(folder: folder)
		#expect(!again.isContact(7))
		#expect(again.profile(7)?.contactName == nil)
		#expect(again.profile(7)?.nickname == "Bear")
		#expect(again.contactNums == [9])
	}

	@Test func profilesSavedBeforeContactsStillLoad() throws {
		let folder = tempFolder()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let json = #"{"me":{"displayName":"Sam"},"contacts":[42,{"nickname":"Bear","sentCardVersion":3,"lastChannel":2}],"groupSends":{}}"#
		try Data(json.utf8).write(to: folder.appendingPathComponent("profiles.json"))

		let store = ProfileStore(folder: folder)
		#expect(store.me.displayName == "Sam")
		#expect(store.profile(42)?.nickname == "Bear")
		#expect(store.profile(42)?.sentCardVersion == 3)
		#expect(store.profile(42)?.lastChannel == 2)
		#expect(store.isContact(42) == false)
		#expect(store.contactNums.isEmpty)
		// Read cleanly, so nothing was set aside.
		#expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("profiles.corrupt.json").path))
	}

	@Test func contactsAreSortedByName() {
		let store = ProfileStore(folder: tempFolder())
		store.setContact(true, for: 3, radioName: "charlie")
		store.setContact(true, for: 1, radioName: "Bravo")
		store.setContact(true, for: 2)
		store.setNickname("Alpha", for: 2)
		#expect(store.contactNums == [2, 1, 3])
	}

	@Test func contactsAreSortedByTheNameTheyShowWith() {
		let store = ProfileStore(folder: tempFolder())
		store.setContact(true, for: 1, radioName: "Adam")
		store.setContact(true, for: 2, radioName: "Beth")
		// Adam's radio is now called Zed, and that's what his row shows.
		let current: [Int64: String] = [1: "Zed"]
		#expect(store.contactNums(radioName: { current[$0] }) == [2, 1])
		#expect(store.contactNums == [1, 2])
	}

	// MARK: Deleting a chat

	@Test func deleteChatRemovesOnlyThatPersonsPrivateMessages() throws {
		let context = persistence.container.viewContext
		func user(_ num: Int64) -> UserEntity {
			let user = UserEntity(context: context)
			user.num = num
			user.userId = "!\(num)"
			user.longName = "User \(num)"
			user.shortName = "U\(num)"
			user.hwModel = "UNSET"
			user.lastMessage = Date()
			return user
		}
		// messageId is unique in the model, so each message needs its own.
		var nextId: Int64 = 100
		func message(_ text: String, from: UserEntity, to: UserEntity?, emoji: Bool = false) -> MessageEntity {
			let message = MessageEntity(context: context)
			nextId += 1
			message.messageId = nextId
			message.messagePayload = text
			message.fromUser = from
			message.toUser = to
			message.isEmoji = emoji
			message.receivedACK = false
			return message
		}
		let me = user(1)
		me.lastMessage = nil
		let alice = user(2)
		let bob = user(3)
		let gone = [
			message("hi alice", from: me, to: alice),
			message("hi back", from: alice, to: me),
			message("👍", from: alice, to: me, emoji: true)
		]
		let kept = [
			message("hello everyone", from: alice, to: nil),
			message("hi bob", from: me, to: bob)
		]

		try ChatsView.deleteChat(with: alice, context: context, activeDeviceNum: nil, preferred: 0)

		// The test store is SQLite at /dev/null, so saved rows can't be fetched back: check the objects.
		// A deleted object leaves its context when it's saved; the rest stay in it.
		#expect(gone.allSatisfy { $0.managedObjectContext == nil })
		#expect(kept.allSatisfy { $0.managedObjectContext === context && !$0.isDeleted })
		#expect([me, alice, bob].allSatisfy { $0.managedObjectContext === context && !$0.isDeleted })
		#expect(alice.lastMessage == nil)
		#expect(bob.lastMessage != nil)
		#expect(!context.hasChanges)
	}

	/// A real in-memory store, unlike `persistence`'s SQLite at /dev/null: saved rows can be
	/// counted again, as the badges do.
	/// The container is returned, not just its context, so it lives as long as the test uses it.
	private func memoryContainer() throws -> NSPersistentContainer {
		let container = NSPersistentContainer(name: "Meshtastic", managedObjectModel: persistence.container.managedObjectModel)
		let description = NSPersistentStoreDescription()
		description.type = NSInMemoryStoreType
		container.persistentStoreDescriptions = [description]
		var loadError: Error?
		container.loadPersistentStores { _, error in loadError = error }
		if let loadError { throw loadError }
		return container
	}

	private struct Chats {
		let context: NSManagedObjectContext
		var nextId: Int64 = 100

		func user(_ num: Int64) -> UserEntity {
			let user = UserEntity(context: context)
			user.num = num
			user.userId = "!\(num)"
			user.longName = "User \(num)"
			user.shortName = "U\(num)"
			user.hwModel = "UNSET"
			user.lastMessage = Date()
			return user
		}

		// messageId is unique in the model, so each message needs its own.
		mutating func message(_ text: String, from: UserEntity, to: UserEntity?, emoji: Bool = false, admin: Bool = false, read: Bool = true) -> MessageEntity {
			let message = MessageEntity(context: context)
			nextId += 1
			message.messageId = nextId
			message.messagePayload = text
			message.fromUser = from
			message.toUser = to
			message.isEmoji = emoji
			message.admin = admin
			message.read = read
			message.receivedACK = false
			return message
		}
	}

	@Test func deleteChatKeepsAdminMessagesAndTakesMyReactions() throws {
		let context = persistence.container.viewContext
		var chats = Chats(context: context)
		let me = chats.user(1)
		let alice = chats.user(2)
		// Every node heard on the mesh gets a MyInfo like this one: it doesn't make Alice mine.
		let aliceNode = NodeInfoEntity(context: context)
		aliceNode.num = 2
		aliceNode.user = alice
		let aliceInfo = MyInfoEntity(context: context)
		aliceInfo.myNodeNum = 2
		aliceInfo.rebootCount = 0
		aliceNode.myInfo = aliceInfo
		// The user of a radio I used before: the DM screen shows those messages too.
		let oldRadio = chats.user(4)
		let gone = [
			chats.message("👍", from: me, to: alice, emoji: true),
			chats.message("from my old radio", from: oldRadio, to: alice),
			chats.message("to my old radio", from: alice, to: oldRadio)
		]
		let kept = [
			chats.message("admin to alice", from: me, to: alice, admin: true),
			chats.message("admin from alice", from: alice, to: me, admin: true)
		]

		try ChatsView.deleteChat(with: alice, context: context, activeDeviceNum: nil, preferred: 0)

		#expect(gone.allSatisfy { $0.managedObjectContext == nil })
		#expect(kept.allSatisfy { $0.managedObjectContext === context && !$0.isDeleted })
		#expect(!context.hasChanges)
	}

	@Test func deleteChatTakesItsUnreadMessagesOffTheBadge() throws {
		let container = try memoryContainer()
		let context = container.viewContext
		var chats = Chats(context: context)
		let me = chats.user(1)
		me.lastMessage = nil
		let node = NodeInfoEntity(context: context)
		node.num = 1
		node.user = me
		let info = MyInfoEntity(context: context)
		info.myNodeNum = 1
		node.myInfo = info
		let alice = chats.user(2)
		let bob = chats.user(3)
		_ = chats.message("one", from: alice, to: me, read: false)
		_ = chats.message("two", from: alice, to: me, read: false)
		_ = chats.message("from bob", from: bob, to: me, read: false)
		_ = chats.message("in a group", from: alice, to: nil, read: false)
		try context.save()
		#expect(ChatsView.unreadCounts(myNum: 1, context: context) == (direct: 3, channel: 1))

		try ChatsView.deleteChat(with: alice, context: context, activeDeviceNum: nil, preferred: 0)

		// Bob's is still unread, and channel messages aren't touched.
		#expect(ChatsView.unreadCounts(myNum: 1, context: context) == (direct: 1, channel: 1))
		withExtendedLifetime(container) {}
	}

	@Test func deleteChatPutsEverythingBackWhenTheSaveFails() throws {
		let container = try memoryContainer()
		let context = container.viewContext
		var chats = Chats(context: context)
		let me = chats.user(1)
		let alice = chats.user(2)
		let message = chats.message("hi", from: me, to: alice)
		try context.save()
		// A user without its required name can't be saved, so the delete's save fails.
		let broken = UserEntity(context: context)
		broken.num = 9

		#expect(throws: (any Error).self) {
			try ChatsView.deleteChat(with: alice, context: context, activeDeviceNum: nil, preferred: 0)
		}
		#expect(message.managedObjectContext === context && !message.isDeleted)
		#expect(alice.lastMessage != nil)
		#expect(broken.managedObjectContext == nil)
		#expect(!context.hasChanges)
		withExtendedLifetime(container) {}
	}

	// MARK: My own radios

	@Test func myRadioIsNotListedWhileItsAway() {
		let context = persistence.container.viewContext
		let chats = Chats(context: context)
		let me = chats.user(1)
		let alice = chats.user(2)
		// Disconnected: no active radio, so the list falls back to the last one.
		let myNum = ChatsView.myNum(activeDeviceNum: nil, preferred: 1)
		#expect(myNum == 1)
		let list = ChatsView.list(myInfo: nil, users: [me, alice], myNum: myNum ?? -1)
		#expect(list.map(\.id) == ["u2"])
		#expect(ChatsView.myNum(activeDeviceNum: 7, preferred: 1) == 7)
		#expect(ChatsView.myNum(activeDeviceNum: nil, preferred: 0) == nil)
	}

	@Test func myRadiosCantBeDeletedAsChats() throws {
		let container = try memoryContainer()
		let context = container.viewContext
		var chats = Chats(context: context)
		let current = chats.user(1)
		let last = chats.user(3)
		// A radio that set up this phone before.
		let old = chats.user(4)
		let node = NodeInfoEntity(context: context)
		node.num = 4
		node.user = old
		let info = MyInfoEntity(context: context)
		info.myNodeNum = 4
		// Only a connection writes this.
		info.peripheralId = UUID().uuidString
		node.myInfo = info
		let alice = chats.user(2)
		let bob = chats.user(5)
		let messages = [
			chats.message("hi alice", from: current, to: alice),
			chats.message("hi bob", from: current, to: bob),
			chats.message("old to bob", from: old, to: bob),
			chats.message("last to alice", from: last, to: alice),
			chats.message("note to self", from: current, to: current)
		]
		try context.save()

		for radio in [current, last, old] {
			#expect(ChatsView.isMyRadio(radio.num, activeDeviceNum: 1, preferred: 3, context: context))
			#expect(throws: ChatsView.DeleteChatError.self) {
				try ChatsView.deleteChat(with: radio, context: context, activeDeviceNum: 1, preferred: 3)
			}
		}
		#expect(!ChatsView.isMyRadio(alice.num, activeDeviceNum: 1, preferred: 3, context: context))
		#expect(!ChatsView.isMyRadio(bob.num, activeDeviceNum: nil, preferred: 0, context: context))
		// Nothing went: every DM those radios had is still here.
		#expect(messages.allSatisfy { $0.managedObjectContext === context && !$0.isDeleted })
		#expect(!context.hasChanges)
		withExtendedLifetime(container) {}
	}

	/// Upstream gives every node it hears a MyInfo with no peripheralId. That's a person, not
	/// one of my radios, so their chat can still be deleted.
	@Test func nodeInfoMyInfoDoesntMakeAPersonMyRadio() throws {
		let container = try memoryContainer()
		let context = container.viewContext
		var chats = Chats(context: context)
		let me = chats.user(1)
		let alice = chats.user(2)
		let bob = chats.user(5)
		func node(_ user: UserEntity, peripheralId: String?) {
			let node = NodeInfoEntity(context: context)
			node.num = user.num
			node.user = user
			let info = MyInfoEntity(context: context)
			info.myNodeNum = user.num
			info.rebootCount = 0
			info.peripheralId = peripheralId
			node.myInfo = info
		}
		node(bob, peripheralId: nil)
		let mine = chats.user(6)
		node(mine, peripheralId: UUID().uuidString)
		let blank = chats.user(7)
		node(blank, peripheralId: "")
		let withBob = [chats.message("hi bob", from: me, to: bob), chats.message("hi", from: bob, to: me)]
		let others = [chats.message("hi alice", from: me, to: alice), chats.message("bob in a group", from: bob, to: nil),
					  chats.message("to my radio", from: me, to: mine)]
		try context.save()

		#expect(!ChatsView.isMyRadio(bob.num, activeDeviceNum: 1, preferred: 0, context: context))
		#expect(!ChatsView.isMyRadio(blank.num, activeDeviceNum: 1, preferred: 0, context: context))
		#expect(ChatsView.isMyRadio(mine.num, activeDeviceNum: 1, preferred: 0, context: context))
		#expect(throws: ChatsView.DeleteChatError.self) {
			try ChatsView.deleteChat(with: mine, context: context, activeDeviceNum: 1, preferred: 0)
		}

		try ChatsView.deleteChat(with: bob, context: context, activeDeviceNum: 1, preferred: 0)
		#expect(withBob.allSatisfy { $0.managedObjectContext == nil })
		#expect(others.allSatisfy { $0.managedObjectContext === context && !$0.isDeleted })
		withExtendedLifetime(container) {}
	}

	// MARK: Leaving a group

	@Test func leavingTwiceLeavesEveryoneNearbyAlone() throws {
		let container = try memoryContainer()
		let context = container.viewContext
		var chats = Chats(context: context)
		let alice = chats.user(2)
		let group = ChannelEntity(context: context)
		group.index = 2
		group.role = 2
		group.name = "Hikers"
		func post(_ text: String, channel: Int32) -> MessageEntity {
			let message = chats.message(text, from: alice, to: nil)
			message.channel = channel
			return message
		}
		let everyone = [post("hello all", channel: 0), post("anyone?", channel: 0)]
		let inGroup = [post("trail at 9", channel: 2), post("see you", channel: 2)]
		try context.save()
		let id = group.objectID

		#expect(GroupChats.removeLocally(id, index: 2, context: context))
		#expect(inGroup.allSatisfy { $0.managedObjectContext == nil })
		// What the second leave used to fetch by: the deleted channel reads slot 0.
		#expect(group.managedObjectContext == nil)
		#expect(!GroupChats.removeLocally(id, index: 2, context: context))
		#expect(!GroupChats.removeLocally(id, index: group.index, context: context))

		let request = MessageEntity.fetchRequest()
		request.predicate = NSPredicate(format: "channel == 0")
		#expect(try context.count(for: request) == 2)
		#expect(everyone.allSatisfy { $0.managedObjectContext === context && !$0.isDeleted })
		withExtendedLifetime(container) {}
	}

	@Test func leaveDoesNothingWhenTheSlotHasANewGroup() throws {
		let container = try memoryContainer()
		let context = container.viewContext
		var chats = Chats(context: context)
		let alice = chats.user(2)
		let group = ChannelEntity(context: context)
		group.index = 3
		group.role = 2
		let message = chats.message("hi", from: alice, to: nil)
		message.channel = 3
		try context.save()
		// Captured as slot 2, but the object now holds slot 3.
		#expect(!GroupChats.removeLocally(group.objectID, index: 2, context: context))
		#expect(!group.isDeleted && message.managedObjectContext === context)
		withExtendedLifetime(container) {}
	}

	// MARK: Sends the radio never answered

	@Test func unansweredSendsBecomeRetryableAfterAWhile() throws {
		let container = try memoryContainer()
		let context = container.viewContext
		var chats = Chats(context: context)
		let me = chats.user(1)
		let alice = chats.user(2)
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		func sent(_ text: String, from: UserEntity = me, to: UserEntity? = alice, ago: TimeInterval, acked: Bool = false, error: Int32 = 0) -> MessageEntity {
			let message = chats.message(text, from: from, to: to)
			message.messageTimestamp = Int32(now.timeIntervalSince1970 - ago)
			message.receivedACK = acked
			message.ackError = error
			return message
		}
		let lost = sent("lost", ago: 600)
		let lostInGroup = sent("lost too", to: nil, ago: 301)
		let recent = sent("just sent", ago: 60)
		let delivered = sent("delivered", ago: 600, acked: true)
		let failed = sent("failed", ago: 600, error: Int32(RoutingError.noRoute.rawValue))
		let theirs = sent("from alice", from: alice, to: me, ago: 600)
		try context.save()

		#expect(DeliveryStatus.markStaleSends(fromNum: 1, now: now, context: context) == 2)
		#expect(lost.canRetry && lostInGroup.canRetry)
		#expect(recent.ackError == 0 && !recent.canRetry)
		#expect(delivered.ackError == 0)
		#expect(failed.ackError == Int32(RoutingError.noRoute.rawValue))
		#expect(theirs.ackError == 0)
		// Nothing new was sent: the same rows, no more of them.
		#expect(try context.count(for: MessageEntity.fetchRequest()) == 6)
		#expect(DeliveryStatus.markStaleSends(fromNum: 1, now: now, context: context) == 0)
		withExtendedLifetime(container) {}
	}

	/// Right after a reconnect the radio is still handing over replies it queued, so a send
	/// that was delivered isn't called "Not delivered" before its reply lands.
	@Test func staleSweepWaitsForQueuedReplies() throws {
		let container = try memoryContainer()
		let context = container.viewContext
		var chats = Chats(context: context)
		let me = chats.user(1)
		let alice = chats.user(2)
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		let sent = chats.message("before the link dropped", from: me, to: alice)
		sent.messageTimestamp = Int32(now.timeIntervalSince1970 - 600)
		try context.save()

		let justConnected = now.addingTimeInterval(-(DeliveryStatus.replyGrace - 1))
		#expect(!DeliveryStatus.shouldSweep(connectedSince: justConnected, now: now))
		#expect(DeliveryStatus.markStaleSends(fromNum: 1, connectedSince: justConnected, now: now, context: context) == 0)
		#expect(sent.ackError == 0 && !sent.canRetry)

		let settled = now.addingTimeInterval(-DeliveryStatus.replyGrace)
		#expect(DeliveryStatus.shouldSweep(connectedSince: settled, now: now))
		#expect(DeliveryStatus.markStaleSends(fromNum: 1, connectedSince: settled, now: now, context: context) == 1)
		#expect(sent.canRetry)
		withExtendedLifetime(container) {}
	}

	/// Rows my radio made itself (a sensor alert, a range test, canned text) aren't sends the
	/// app can retry: Try Again would resend them as a text message.
	@Test func radioOriginatedRowsArentSwept() throws {
		let container = try memoryContainer()
		let context = container.viewContext
		var chats = Chats(context: context)
		let me = chats.user(1)
		let alice = chats.user(2)
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		func row(_ text: String, portNum: PortNum?) -> MessageEntity {
			let message = chats.message(text, from: me, to: portNum == nil ? alice : nil)
			message.messageTimestamp = Int32(now.timeIntervalSince1970 - 600)
			if let portNum { message.portNum = Int32(portNum.rawValue) }
			return message
		}
		let fromRadio = [row("Motion detected", portNum: .detectionSensorApp), row("seq 12", portNum: .rangeTestApp),
						 row("canned", portNum: .textMessageApp)]
		let appSent = row("typed in the app", portNum: nil)
		try context.save()

		#expect(DeliveryStatus.markStaleSends(fromNum: 1, now: now, context: context) == 1)
		#expect(fromRadio.allSatisfy { $0.ackError == 0 && !$0.canRetry })
		#expect(appSent.canRetry)
		withExtendedLifetime(container) {}
	}

	// MARK: Notifications

	@Test func notificationPrefixMatchesOnlyThatChat() {
		let dm = ChatsView.notificationPrefix(for: .dm(userNum: 12))
		#expect("meshtastic:///messages?userNum=12&messageId=5".hasPrefix(dm))
		#expect(!"meshtastic:///messages?userNum=123&messageId=5".hasPrefix(dm))
		let group = ChatsView.notificationPrefix(for: .group(index: 2))
		#expect("meshtastic:///messages?channelId=2&messageId=5".hasPrefix(group))
		#expect(!"meshtastic:///messages?channelId=22&messageId=5".hasPrefix(group))
		#expect(!"meshtastic:///messages?userNum=2&messageId=5".hasPrefix(group))
	}

	// MARK: Sharing with saved contacts

	@Test func savedContactsKeepGettingMyCardWithoutAChat() {
		#expect(ProfileRules.mayShare(over: .direct, iMessagedThem: false, inMyGroup: false, savedContact: true))
		#expect(!ProfileRules.mayShare(over: .direct, iMessagedThem: false, inMyGroup: false, savedContact: false))
	}

	// MARK: Group invites

	@Test func inviteListPutsContactsFirstWithoutDuplicates() {
		let list = GroupInviteContent.inviteList(contacts: [5, 9, 1], messaged: [7, 9, 1, 3, 7], me: 1)
		#expect(list == [5, 9, 7, 3])
		#expect(GroupInviteContent.inviteList(contacts: [], messaged: [4, 2], me: nil) == [4, 2])
		#expect(GroupInviteContent.inviteList(contacts: [8], messaged: [], me: 8).isEmpty)
	}
}
