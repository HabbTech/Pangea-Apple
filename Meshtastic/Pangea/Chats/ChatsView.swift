//
//  ChatsView.swift
//  Pangea
//
//  Standard mode's Messages tab: one list of every conversation, newest first.
//  Group chats and DMs look the same; channels and nodes never come up.
//

import SwiftUI
import CoreData

enum ChatRoute: Hashable {
	case group(index: Int32)
	case dm(userNum: Int64)
}

struct ChatsView: View {
	@Environment(\.managedObjectContext) private var context
	@EnvironmentObject var accessoryManager: AccessoryManager
	@ObservedObject var router: Router
	@ObservedObject private var invites = GroupInviteStore.shared
	@ObservedObject private var inbox = PangeaInbox.shared

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \UserEntity.lastMessage, ascending: false)],
		predicate: NSPredicate(format: "lastMessage != nil")
	) private var dmUsers: FetchedResults<UserEntity>

	@State private var path: [ChatRoute] = []
	@State private var showNewGroup = false
	@State private var refresh = 0

	private var myInfo: MyInfoEntity? {
		guard let num = accessoryManager.activeDeviceNum ?? (UserDefaults.preferredPeripheralNum > 0 ? Int64(UserDefaults.preferredPeripheralNum) : nil) else { return nil }
		return getNodeInfo(id: num, context: context)?.myInfo
	}

	private var chats: [ChatSummary] {
		_ = refresh
		var items: [ChatSummary] = []
		if let myInfo {
			for channel in (myInfo.channels?.array as? [ChannelEntity] ?? []) where GroupChats.isChat(channel) {
				items.append(.group(channel))
			}
		}
		let myNum = accessoryManager.activeDeviceNum ?? -1
		for user in dmUsers where user.num != myNum {
			items.append(.dm(user))
		}
		return items.sorted { lhs, rhs in
			if lhs.isEveryone != rhs.isEveryone { return rhs.isEveryone }
			return lhs.lastDate > rhs.lastDate
		}
	}

	var body: some View {
		NavigationStack(path: $path) {
			List {
				if !invites.pending.isEmpty {
					Section {
						ForEach(invites.pending) { pending in
							InviteRow(pending: pending) {
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
						NavigationLink(value: chat.route) {
							ChatRow(chat: chat)
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
			} else {
				ContentUnavailableView("Chat Not Found", systemImage: "person", description: Text("Connect your radio to see this chat."))
			}
		}
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

	var title: String {
		switch self {
		case .group(let channel): return GroupChats.displayName(channel)
		case .dm(let user): return user.longName ?? PangeaCode.code(for: user.num)
		}
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
}

struct ChatRow: View {
	let chat: ChatSummary

	var body: some View {
		let last = chat.lastMessage
		let unread = chat.unread
		HStack(spacing: 12) {
			avatar
			VStack(alignment: .leading, spacing: 3) {
				HStack {
					Text(chat.title)
						.font(.headline)
						.lineLimit(1)
					Spacer()
					if last != nil {
						Text(chat.lastDate.formatted(Calendar.current.isDateInToday(chat.lastDate) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				HStack {
					Text(preview(last))
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(2)
					Spacer()
					if unread > 0 {
						Text("\(unread)")
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

	private func preview(_ message: MessageEntity?) -> String {
		guard let message, let text = message.messagePayload else {
			switch chat {
			case .group(let channel) where GroupChats.isEveryone(channel):
				return String(localized: "Public chat with everyone in range")
			case .group:
				return String(localized: "No messages yet. Invite people to start.")
			case .dm:
				return String(localized: "Say hello")
			}
		}
		if case .group = chat, let sender = message.fromUser?.shortName, !sender.isEmpty {
			return "\(sender): \(text)"
		}
		return text
	}

	@ViewBuilder
	private var avatar: some View {
		switch chat {
		case .group(let channel):
			Image(systemName: GroupChats.isEveryone(channel) ? "globe" : "person.3.fill")
				.font(.system(size: 18, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 46, height: 46)
				.background(GroupChats.isEveryone(channel) ? Color.pangeaTertiary : Color.accentColor, in: Circle())
		case .dm(let user):
			CircleText(text: user.shortName ?? "?", color: Color(UIColor(hex: UInt32(truncatingIfNeeded: user.num))), circleSize: 46)
		}
	}
}

struct InviteRow: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	let pending: GroupInviteStore.Pending
	var onJoin: () -> Void
	var onDecline: () -> Void

	private var sender: String {
		existingUser(num: pending.fromNum, context: accessoryManager.context)?.longName ?? PangeaCode.code(for: pending.fromNum)
	}

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "envelope.badge.fill")
				.font(.title2)
				.foregroundStyle(Color.accentColor)
			VStack(alignment: .leading, spacing: 2) {
				Text("\(sender) invited you to \(pending.invite.name)")
					.font(.subheadline.weight(.semibold))
				Text(pending.received, style: .relative)
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
