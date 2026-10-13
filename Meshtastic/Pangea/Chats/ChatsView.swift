//
//  ChatsView.swift
//  Pangea
//
//  Standard mode's Messages tab: one list of every conversation, newest first.
//  Group chats and DMs look the same; channels and nodes never come up.
//

import SwiftUI
import CoreData
import OSLog
import UserNotifications

enum ChatRoute: Hashable {
	case group(index: Int32)
	case dm(userNum: Int64)
}

struct ChatsView: View {
	@Environment(\.managedObjectContext) private var context
	@EnvironmentObject var accessoryManager: AccessoryManager
	@EnvironmentObject var appState: AppState
	@ObservedObject var router: Router
	@ObservedObject private var invites = GroupInviteStore.shared
	@ObservedObject private var inbox = PangeaInbox.shared
	@ObservedObject private var profiles = ProfileStore.shared

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \UserEntity.lastMessage, ascending: false)],
		predicate: NSPredicate(format: "lastMessage != nil")
	) private var dmUsers: FetchedResults<UserEntity>

	@State private var path: [ChatRoute] = []
	@State private var showNewGroup = false
	@State private var refresh = 0
	/// Chat waiting on "Delete Chat" or "Leave Group" to be confirmed.
	@State private var removing: ChatSummary?
	/// Why leaving a group didn't happen, shown in an alert.
	@State private var removeError: String?

	/// The connected radio, or the last one while it's away.
	private var myNum: Int64? {
		Self.myNum(activeDeviceNum: accessoryManager.activeDeviceNum)
	}

	nonisolated static func myNum(activeDeviceNum: Int64?, preferred: Int = UserDefaults.preferredPeripheralNum) -> Int64? {
		activeDeviceNum ?? (preferred > 0 ? Int64(preferred) : nil)
	}

	/// One of my radios, now or before: the connected one, the last one, or any that set
	/// up this phone. Messages with it are every DM that radio had, so it's never offered as
	/// a chat to delete. Every node heard on the mesh gets a MyInfo too, so only one with a
	/// `peripheralId` (written only when this phone connected to it) counts.
	static func isMyRadio(_ num: Int64, activeDeviceNum: Int64?, preferred: Int = UserDefaults.preferredPeripheralNum, context: NSManagedObjectContext) -> Bool {
		if num == activeDeviceNum || (preferred > 0 && num == Int64(preferred)) { return true }
		let request = MyInfoEntity.fetchRequest()
		request.predicate = NSPredicate(format: "(myNodeNum == %lld OR myInfoNode.num == %lld) AND peripheralId != nil AND peripheralId != ''", num, num)
		request.fetchLimit = 1
		// When unsure, keep the messages.
		guard let count = try? context.count(for: request) else { return true }
		return count > 0
	}

	private var myInfo: MyInfoEntity? {
		guard let myNum else { return nil }
		return getNodeInfo(id: myNum, context: context)?.myInfo
	}

	private var chats: [ChatSummary] {
		_ = refresh
		return Self.list(myInfo: myInfo, users: dmUsers, myNum: myNum ?? -1)
	}

	/// Everyone Nearby first, so it's always in reach, then my groups and everyone I have DMs
	/// with, newest first. Each chat's
	/// date is a fetch, so it's worked out once per chat, not on both sides of every comparison.
	static func list(myInfo: MyInfoEntity?, users: some Sequence<UserEntity>, myNum: Int64, lastDate: ((ChatSummary) -> Date)? = nil) -> [ChatSummary] {
		var items: [ChatSummary] = []
		if let myInfo {
			for channel in (myInfo.channels?.array as? [ChannelEntity] ?? []) where GroupChats.isChat(channel) {
				items.append(.group(channel))
			}
		}
		for user in users where user.num != myNum {
			items.append(.dm(user))
		}
		return items.map { (chat: $0, isEveryone: $0.isEveryone, date: lastDate?($0) ?? $0.lastDate) }
			.sorted { lhs, rhs in
				if lhs.isEveryone != rhs.isEveryone { return lhs.isEveryone }
				return lhs.date > rhs.date
			}
			.map(\.chat)
	}

	var body: some View {
		NavigationStack(path: $path) {
			List {
				let chats = self.chats
				if !invites.pending.isEmpty {
					Section {
						ForEach(invites.pending) { pending in
							InviteRow(pending: pending, sender: profiles.name(num: pending.fromNum, radioName: existingUser(num: pending.fromNum, context: context)?.longName)) {
								inbox.openJoin(pending.invite, pending: pending)
							} onDecline: {
								invites.remove(pending)
							}
						}
					}
				}
				if chats.isEmpty {
					emptyState
						.listRowSeparator(.hidden)
				} else {
					ForEach(chats) { chat in
						// Worked out once per row: for a DM it's a fetch.
						let title = removeTitle(chat)
						// Built here, not in `list`, so only the rows on screen fetch their message.
						NavigationLink(value: chat.route) {
							ChatRow(row: chat.row)
						}
						// Trailing only and never a full swipe, so a tap still opens the chat.
						.swipeActions(edge: .trailing, allowsFullSwipe: false) {
							if let title {
								// Not .destructive: that slides the row away before it's confirmed.
								Button {
									askToRemove(chat)
								} label: {
									Label(title, systemImage: removeIcon(chat))
								}
								.tint(.red)
							}
						}
						.contextMenu {
							if let title {
								Button(role: .destructive) {
									askToRemove(chat)
								} label: {
									Label(title, systemImage: removeIcon(chat))
								}
							}
						}
					}
				}
			}
			.listStyle(.plain)
			.navigationTitle("Chats")
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					MeshtasticLogo()
				}
				ToolbarItem(placement: .topBarTrailing) {
					Menu {
						Button {
							inbox.isComposing = true
						} label: {
							Label("New Message", systemImage: "person")
						}
						Button {
							showNewGroup = true
						} label: {
							Label("New Group", systemImage: "person.3")
						}
						Button {
							inbox.isScanning = true
						} label: {
							Label("Scan a Code", systemImage: "qrcode.viewfinder")
						}
					} label: {
						Image(systemName: "square.and.pencil")
					}
					.accessibilityLabel("New Chat")
				}
			}
			.navigationDestination(for: ChatRoute.self) { route in
				destination(for: route)
			}
		}
		.environment(\.openURL, OpenURLAction { url in
			inbox.handle(url: url) ? .handled : .systemAction
		})
		.confirmationDialog(removing.map(removeQuestion) ?? "", isPresented: Binding(
			get: { removing != nil },
			set: { if !$0 { removing = nil } }
		), titleVisibility: .visible, presenting: removing) { chat in
			Button(removeTitle(chat) ?? "", role: .destructive) {
				remove(chat)
			}
		} message: { chat in
			switch chat {
			case .group:
				Text("Messages in this group will be removed from this phone. You can rejoin with an invite.")
			case .dm(let user):
				if ProfileSync.keepsSharingWithoutChat(user.num) {
					Text("Messages are removed from this device only.")
				} else {
					Text("Messages are removed from this device only. They'll stop getting your profile updates until you message them again.")
				}
			}
		}
		.alert("Couldn't Leave Group", isPresented: Binding(
			get: { removeError != nil },
			set: { if !$0 { removeError = nil } }
		)) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(removeError ?? "")
		}
		.sheet(isPresented: $showNewGroup) {
			NewGroupSheet { index in
				path = [.group(index: index)]
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)) { _ in
			refresh &+= 1
		}
		.onChange(of: router.messagesState) { _, state in
			consume(state)
		}
		.onChange(of: inbox.openedGroup) { _, index in
			if let index {
				inbox.openedGroup = nil
				path = [.group(index: index)]
			}
		}
		.onAppear {
			consume(router.messagesState)
		}
	}

	@ViewBuilder
	private func destination(for route: ChatRoute) -> some View {
		switch route {
		case .group(let index):
			if let myInfo, let channel = (myInfo.channels?.array as? [ChannelEntity])?.first(where: { $0.index == index }) {
				GroupChatScreen(myInfo: myInfo, channel: channel) {
					path.removeAll()
				}
			} else {
				ContentUnavailableView("Group Not Found", systemImage: "person.3", description: Text("Connect your radio to see this group."))
			}
		case .dm(let num):
			if let user = existingUser(num: num, context: context) {
				UserMessageList(user: user)
					.safeAreaInset(edge: .top) {
						PhotoUpdateBanner(nums: [num])
					}
			} else {
				ContentUnavailableView("Chat Not Found", systemImage: "person", description: Text("Connect your radio to see this chat."))
			}
		}
	}

	// MARK: Delete and leave

	/// Nil for Everyone Nearby: it's the public mesh, so there's nothing to leave. Nil for one
	/// of my own radios too (`isMyRadio`).
	private func removeTitle(_ chat: ChatSummary) -> String? {
		switch chat {
		case .group: return chat.isEveryone ? nil : String(localized: "Leave Group")
		case .dm(let user):
			if Self.isMyRadio(user.num, activeDeviceNum: accessoryManager.activeDeviceNum, context: context) { return nil }
			return String(localized: "Delete Chat")
		}
	}

	private func removeIcon(_ chat: ChatSummary) -> String {
		if case .group = chat { return "rectangle.portrait.and.arrow.right" }
		return "trash"
	}

	private func removeQuestion(_ chat: ChatSummary) -> String {
		switch chat {
		case .group(let channel): return String(localized: "Leave \(GroupChats.displayName(channel))?")
		case .dm(let user): return String(localized: "Delete chat with \(profiles.name(for: user))?")
		}
	}

	/// Pops the chat if it's open, so its screen isn't left showing objects being deleted.
	private func askToRemove(_ chat: ChatSummary) {
		// The radio has to drop the group; without it, say so up front rather than do nothing.
		if case .group = chat, !accessoryManager.isConnected {
			removeError = Self.leaveNeedsRadio
		} else {
			removing = chat
		}
	}

	private func remove(_ chat: ChatSummary) {
		removing = nil
		let route = chat.route
		let wasOpen = path.contains(route)
		path.removeAll { $0 == route }
		switch chat {
		case .group(let channel):
			Task {
				if wasOpen { try? await Task.sleep(for: .milliseconds(600)) }
				do {
					// Takes away its notifications and badge counts itself.
					try await GroupChats.leave(channel, accessoryManager: accessoryManager)
				} catch {
					Logger.services.error("👥 [Groups] Leave failed: \(error.localizedDescription, privacy: .public)")
					// The radio went away meanwhile, or didn't take the change.
					removeError = (error as? GroupChatError) == .notConnected ? Self.leaveNeedsRadio : String(localized: "Your radio didn't take the change. Try again in a moment.")
				}
			}
		case .dm(let user):
			let num = user.num
			Task {
				if wasOpen { try? await Task.sleep(for: .milliseconds(600)) }
				guard let user = existingUser(num: num, context: context) else { return }
				do {
					try Self.deleteChat(with: user, context: context, activeDeviceNum: accessoryManager.activeDeviceNum)
					Self.removeNotifications(opening: route)
					if let myNum {
						Self.refreshUnread(appState: appState, myNum: myNum, context: context)
					}
				} catch {
					Logger.data.error("💬 [Chats] Delete chat failed: \(error.localizedDescription, privacy: .public)")
				}
			}
		}
	}

	/// Removes our private messages with this person, reactions included, and takes them off
	/// the list. They stay in the node list, with their nickname, profile and contact status.
	/// Group and Everyone Nearby messages (no `toUser`) are left alone.
	/// Refuses one of my own radios: with it as "them", the predicate matches every DM that radio had.
	static func deleteChat(with user: UserEntity, context: NSManagedObjectContext, activeDeviceNum: Int64?,
						   preferred: Int = UserDefaults.preferredPeripheralNum) throws {
		guard !isMyRadio(user.num, activeDeviceNum: activeDeviceNum, preferred: preferred, context: context) else {
			throw DeleteChatError.myRadio
		}
		let request = MessageEntity.fetchRequest()
		request.predicate = NSPredicate(format: "((toUser == %@) OR (fromUser == %@)) AND toUser != nil AND fromUser != nil AND admin == false", user, user)
		for message in try context.fetch(request) {
			context.delete(message)
		}
		user.lastMessage = nil
		do {
			try context.save()
		} catch {
			context.rollback()
			throw error
		}
	}

	private static var leaveNeedsRadio: String {
		String(localized: "Connect your radio to leave this group.")
	}

	enum DeleteChatError: Error {
		case myRadio
	}

	/// Some of what was deleted may not have been read yet: count again for the tab and app icon badges.
	static func refreshUnread(appState: AppState, myNum: Int64, context: NSManagedObjectContext) {
		let counts = unreadCounts(myNum: myNum, context: context)
		appState.unreadDirectMessages = counts.direct
		appState.unreadChannelMessages = counts.channel
	}

	/// What the badges count: unread private messages with me, and unread channel messages.
	static func unreadCounts(myNum: Int64, context: NSManagedObjectContext) -> (direct: Int, channel: Int) {
		let node = getNodeInfo(id: myNum, context: context)
		// skipLastMessageCheck: my own node's lastMessage isn't kept up to date.
		return (node?.user?.unreadMessages(context: context, skipLastMessageCheck: true) ?? 0,
				node?.myInfo?.unreadMessages(context: context) ?? 0)
	}

	/// The start of the link a notification for this chat opens (see MeshPackets), up to
	/// the "&" so user 12 doesn't match user 123.
	nonisolated static func notificationPrefix(for route: ChatRoute) -> String {
		switch route {
		case .dm(let num): return "meshtastic:///messages?userNum=\(num)&"
		case .group(let index): return "meshtastic:///messages?channelId=\(index)&"
		}
	}

	/// A notification for a chat that's gone would open it empty, or open whatever group takes its slot next.
	static func removeNotifications(opening route: ChatRoute) {
		let prefix = notificationPrefix(for: route)
		Task {
			await removeNotifications(withPathPrefix: prefix)
			// One for a message that came in just before can still be on its way to the system.
			try? await Task.sleep(for: .milliseconds(1500))
			await removeNotifications(withPathPrefix: prefix)
		}
	}

	private nonisolated static func removeNotifications(withPathPrefix prefix: String) async {
		let center = UNUserNotificationCenter.current()
		func matches(_ content: UNNotificationContent) -> Bool {
			(content.userInfo["path"] as? String)?.hasPrefix(prefix) == true
		}
		let delivered = await center.deliveredNotifications().filter { matches($0.request.content) }.map(\.request.identifier)
		center.removeDeliveredNotifications(withIdentifiers: delivered)
		let pending = await center.pendingNotificationRequests().filter { matches($0.content) }.map(\.identifier)
		center.removePendingNotificationRequests(withIdentifiers: pending)
	}

	/// Routes from notifications, links and New Message arrive through the router.
	private func consume(_ state: MessagesNavigationState?) {
		switch state {
		case .channels(let channelId?, _):
			path = [.group(index: channelId)]
			router.messagesState = nil
		case .directMessages(let userNum?, _):
			path = [.dm(userNum: userNum)]
			router.messagesState = nil
		default:
			break
		}
	}

	private var emptyState: some View {
		VStack(spacing: 20) {
			Image(systemName: "bubble.left.and.bubble.right")
				.font(.system(size: 48))
				.foregroundStyle(Color.accentColor)
			Text("No Chats Yet")
				.font(.title2.bold())
			Text("Message a friend with their code, or start a group and invite people.")
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			VStack(spacing: 12) {
				Button {
					inbox.isComposing = true
				} label: {
					Text("Message Someone")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				Button {
					showNewGroup = true
				} label: {
					Text("Start a Group")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
			}
			.controlSize(.large)
			.buttonBorderShape(.capsule)
			.frame(maxWidth: 360)
			MyCodeCard()
		}
		.padding(.vertical, 32)
		.frame(maxWidth: .infinity)
	}
}

// MARK: Rows

@MainActor
enum ChatSummary: Identifiable {
	case group(ChannelEntity)
	case dm(UserEntity)

	var id: String {
		switch self {
		case .group(let channel): return "g\(channel.index)"
		case .dm(let user): return "u\(user.num)"
		}
	}

	var route: ChatRoute {
		switch self {
		case .group(let channel): return .group(index: channel.index)
		case .dm(let user): return .dm(userNum: user.num)
		}
	}

	var isEveryone: Bool {
		if case .group(let channel) = self { return GroupChats.isEveryone(channel) }
		return false
	}

	var lastMessage: MessageEntity? {
		switch self {
		case .group(let channel): return channel.mostRecentPrivateMessage
		case .dm(let user): return user.mostRecentMessage
		}
	}

	var lastDate: Date {
		if let message = lastMessage {
			return Date(timeIntervalSince1970: TimeInterval(message.messageTimestamp))
		}
		if case .dm(let user) = self, let date = user.lastMessage { return date }
		return .distantPast
	}

	var unread: Int {
		switch self {
		case .group(let channel): return channel.unreadMessages
		case .dm(let user): return user.unreadMessages
		}
	}

	/// What this chat's row shows right now: one message fetch and one unread count.
	var row: ChatRowModel {
		ChatRowModel.make(chat: self, last: lastMessage, unread: unread, name: ProfileStore.shared.name(for:))
	}
}

/// What a chat's row draws, as values. SwiftUI redraws a row only when its inputs change, and
/// an entity is the same object after its messages, read flags or names change.
struct ChatRowModel: Equatable {
	enum Avatar: Equatable {
		case everyone
		case group
		case person(num: Int64, shortName: String?)
	}

	var title: String
	var preview: String
	var date: Date?
	var unread: Int
	var avatar: Avatar

	@MainActor
	static func make(chat: ChatSummary, last: MessageEntity?, unread: Int, name: (UserEntity) -> String) -> ChatRowModel {
		switch chat {
		case .group(let channel):
			let everyone = GroupChats.isEveryone(channel)
			var preview = everyone ? String(localized: "Public chat with everyone in range") : String(localized: "No messages yet. Invite people to start.")
			if let last, let text = last.messagePayload {
				preview = text
				if let sender = last.fromUser {
					let first = name(sender).split(separator: " ").first.map(String.init) ?? ""
					if !first.isEmpty { preview = "\(first): \(text)" }
				}
			}
			return ChatRowModel(title: GroupChats.displayName(channel), preview: preview, date: date(last), unread: unread, avatar: everyone ? .everyone : .group)
		case .dm(let user):
			let preview = last?.messagePayload ?? String(localized: "Say hello")
			return ChatRowModel(title: name(user), preview: preview, date: date(last), unread: unread, avatar: .person(num: user.num, shortName: user.shortName))
		}
	}

	/// What `lastDate` gives when there's a message, without fetching it again.
	private static func date(_ message: MessageEntity?) -> Date? {
		message.map { Date(timeIntervalSince1970: TimeInterval($0.messageTimestamp)) }
	}
}

struct ChatRow: View {
	let row: ChatRowModel

	var body: some View {
		HStack(spacing: 12) {
			avatar
			VStack(alignment: .leading, spacing: 3) {
				HStack {
					Text(row.title)
						.font(.headline)
						.lineLimit(1)
					Spacer()
					if let date = row.date {
						Text(date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				HStack {
					Text(row.preview)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(2)
					Spacer()
					if row.unread > 0 {
						Text("\(row.unread)")
							.font(.caption.bold())
							.foregroundStyle(.white)
							.padding(.horizontal, 7)
							.padding(.vertical, 2)
							.background(Color.accentColor, in: Capsule())
					}
				}
			}
		}
		.padding(.vertical, 4)
	}

	@ViewBuilder
	private var avatar: some View {
		switch row.avatar {
		case .everyone, .group:
			let everyone = row.avatar == .everyone
			Image(systemName: everyone ? "globe" : "person.3.fill")
				.font(.system(size: 18, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 46, height: 46)
				.background(everyone ? Color.pangeaTertiary : Color.accentColor, in: Circle())
		case .person(let num, let shortName):
			// Observes ProfileStore itself, so a photo or emoji still updates in place.
			PangeaAvatar(num: num, shortName: shortName, size: 46)
		}
	}
}

struct InviteRow: View {
	let pending: GroupInviteStore.Pending
	/// Passed in, so a nickname or a new card name redraws the row.
	let sender: String
	var onJoin: () -> Void
	var onDecline: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "envelope.badge.fill")
				.font(.title2)
				.foregroundStyle(Color.accentColor)
			VStack(alignment: .leading, spacing: 2) {
				Text("\(sender) invited you to \(pending.invite.name)")
					.font(.subheadline.weight(.semibold))
				Text(GroupInviteStore.shared.received(pending), style: .relative)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Button("Join", action: onJoin)
				.buttonStyle(.borderedProminent)
				.buttonBorderShape(.capsule)
				.controlSize(.small)
			Button(action: onDecline) {
				Image(systemName: "xmark")
			}
			.buttonStyle(.borderless)
			.foregroundStyle(.secondary)
			.accessibilityLabel("Decline")
		}
		.padding(.vertical, 4)
	}
}
