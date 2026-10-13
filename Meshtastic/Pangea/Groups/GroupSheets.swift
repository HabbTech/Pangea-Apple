//
//  GroupSheets.swift
//  Pangea
//
//  New Group, Invite People, Join Group, and the group chat screen itself.
//

import SwiftUI
import SwiftData
import CoreImage.CIFilterBuiltins
import OSLog

// MARK: New Group

struct NewGroupSheet: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss
	var onCreated: (Int32) -> Void

	@State private var name = ""
	@State private var isCreating = false
	@State private var error: String?
	@State private var created: ChannelEntity?
	@FocusState private var focused: Bool

	var body: some View {
		NavigationStack {
			Group {
				if let created {
					GroupInviteContent(channel: created)
						.toolbar {
							ToolbarItem(placement: .confirmationAction) {
								Button("Done") {
									onCreated(created.index)
									dismiss()
								}
							}
						}
				} else {
					form
				}
			}
			.navigationTitle(created == nil ? "New Group" : "Invite People")
			.navigationBarTitleDisplayMode(.inline)
		}
	}

	private var form: some View {
		VStack(spacing: 20) {
			Image(systemName: "person.3.fill")
				.font(.system(size: 44))
				.foregroundStyle(Color.accentColor)
				.padding(.top, 24)
			TextField("Group name", text: $name)
				.font(.title3)
				.multilineTextAlignment(.center)
				.focused($focused)
				.submitLabel(.done)
				.onSubmit { Task { await create() } }
				.onChange(of: name) { _, value in
					if value.utf8.count > GroupInvite.maxNameBytes {
						name = GroupInvite.clampedName(value)
					}
				}
				.padding()
				.background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			Text("Only people you invite can read this group. Names can be up to 11 letters.")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			if let error {
				Label(error, systemImage: "exclamationmark.triangle.fill")
					.font(.footnote)
					.foregroundStyle(.orange)
			}
			Spacer()
			Button {
				Task { await create() }
			} label: {
				Text(isCreating ? "Creating…" : "Create Group")
					.frame(maxWidth: 400)
			}
			.capsuleButtonStyle()
			.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
			.padding(.bottom)
		}
		.padding(.horizontal)
		.onAppear { focused = true }
		.toolbar {
			ToolbarItem(placement: .cancellationAction) {
				Button("Cancel") { dismiss() }
			}
		}
	}

	private func create() async {
		guard !isCreating, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
		isCreating = true
		defer { isCreating = false }
		do {
			let index = try await GroupChats.create(name: name, accessoryManager: accessoryManager)
			if let num = accessoryManager.activeDeviceNum,
			   let channel = getNodeInfo(id: num, context: accessoryManager.context)?.myInfo?.sortedChannels.first(where: { $0.index == index }) {
				created = channel
			} else {
				onCreated(index)
				dismiss()
			}
		} catch {
			self.error = error.localizedDescription
		}
	}
}

// MARK: Invite

struct GroupInviteSheet: View {
	@Environment(\.dismiss) private var dismiss
	let channel: ChannelEntity

	var body: some View {
		NavigationStack {
			GroupInviteContent(channel: channel)
				.navigationTitle("Invite People")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .confirmationAction) {
						Button("Done") { dismiss() }
					}
				}
		}
	}
}

struct GroupInviteContent: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@ObservedObject private var profiles = ProfileStore.shared
	@StateObject private var resolver = ContactResolver()
	let channel: ChannelEntity

	@Query(
		filter: #Predicate<UserEntity> { $0.pkiEncrypted == true && $0.lastMessage != nil },
		sort: \UserEntity.lastMessage, order: .reverse
	) private var messaged: [UserEntity]

	@State private var sent: Set<Int64> = []
	@State private var sending: Set<Int64> = []
	@State private var error: String?
	@State private var code = ""
	@State private var showScanner = false
	/// Who's being reached, to invite once they answer: from the code field, or a contact the radio has forgotten.
	@State private var reaching: Int64?
	/// The last person entered in the code field, whose progress shows under it.
	@State private var codeTarget: Int64?
	@State private var codeError: String?

	/// Saved contacts first, then everyone else I've messaged privately, each once, never me.
	nonisolated static func inviteList(contacts: [Int64], messaged: [Int64], me: Int64?) -> [Int64] {
		var seen = Set<Int64>()
		return (contacts + messaged).filter { $0 != me && seen.insert($0).inserted }
	}

	private var people: [Int64] {
		Self.inviteList(contacts: profiles.contactNums(radioName: { existingUser(num: $0, context: accessoryManager.context)?.longName }), messaged: messaged.map(\.num), me: accessoryManager.activeDeviceNum)
	}

	/// Nil when a friend's app couldn't join from it (see `GroupInvite.shareable`).
	private var invite: GroupInvite? {
		try? shareable.get()
	}

	private var shareable: Result<GroupInvite, GroupChatError> {
		GroupInvite.shareable(name: channel.name ?? "", psk: channel.psk ?? Data())
	}

	var body: some View {
		List {
			if case .failure(let reason) = shareable {
				// Made elsewhere (expert channel settings, another app, an older Pangea).
				// Renaming it or changing its key would make it a different channel, so
				// there's nothing to fix here.
				Section {
					Label(reason.localizedDescription, systemImage: "exclamationmark.triangle.fill")
						.font(.footnote)
						.foregroundStyle(.orange)
				}
			} else if let invite, let link = invite.link {
				Section {
					VStack(spacing: 12) {
						if let image = qrImage(link) {
							Image(uiImage: image)
								.interpolation(.none)
								.resizable()
								.scaledToFit()
								.frame(maxWidth: 220)
								.padding(10)
								.background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
						}
						Text("Have friends scan this in Pangea to join \(invite.name).")
							.font(.footnote)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
						ShareLink(item: link, message: Text("Join my Pangea group \"\(invite.name)\"")) {
							Label("Share Invite Link", systemImage: "square.and.arrow.up")
								.frame(maxWidth: .infinity)
						}
						.buttonStyle(.borderedProminent)
						.buttonBorderShape(.capsule)
						.controlSize(.large)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 8)
				}
			}

			if invite != nil {
				Section {
					let people = self.people
					if people.isEmpty {
						Text("Your contacts and people you've messaged privately show up here, so you can invite them with one tap.")
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
					ForEach(people, id: \.self) { num in
						ContactRow(num: num, user: existingUser(num: num, context: accessoryManager.context)) {
							status(for: num) {
								Button("Invite") {
									Task { await inviteListed(num) }
								}
								.buttonStyle(.bordered)
								.buttonBorderShape(.capsule)
								.disabled(reaching != nil)
							}
						}
					}
				} header: {
					Text("Invite Contacts")
				} footer: {
					if let error {
						Text(error).foregroundStyle(.orange)
					}
				}

				Section {
					codeField
					if let codeTarget {
						codeStatus(codeTarget)
					}
					if let codeError {
						Label(codeError, systemImage: "exclamationmark.circle")
							.font(.footnote)
							.foregroundStyle(.orange)
					} else if !code.isEmpty && PangeaCode.invite(from: code) == nil && PangeaCode.looksComplete(code) {
						Label("That code doesn't look right. Check it and try again.", systemImage: "exclamationmark.circle")
							.font(.footnote)
							.foregroundStyle(.orange)
					}
				} header: {
					Text("Invite by Code")
				} footer: {
					Text("They need to have their radio on and be in range, unless you scan their QR code.")
				}
			}
		}
		.sheet(isPresented: $showScanner) {
			QRScannerSheet { value in
				if let scanned = PangeaCode.invite(from: value) {
					code = scanned.code
					reach(scanned, fromCode: true)
				} else {
					codeError = String(localized: "That QR code isn't a person's Pangea code.")
				}
			}
		}
		.onDisappear {
			resolver.cancel()
		}
	}

	private var codeField: some View {
		HStack(spacing: 8) {
			// An edit clears the last code's error, so it doesn't stand in for what's typed now.
			// Not .onChange: a scanned code is set just before `reach` reports on it.
			TextField("@code", text: Binding(get: { code }, set: { value in
				if value != code { codeError = nil }
				code = value
			}))
				.font(.body.monospaced())
				.textInputAutocapitalization(.characters)
				.autocorrectionDisabled()
				.submitLabel(.send)
				.onSubmit { reachTypedCode() }
				.disabled(reaching != nil)
			Button {
				showScanner = true
			} label: {
				Image(systemName: "qrcode.viewfinder")
					.font(.title3)
			}
			.buttonStyle(.borderless)
			.accessibilityLabel("Scan QR code")
			.disabled(reaching != nil)
			Button("Invite") {
				reachTypedCode()
			}
			.buttonStyle(.bordered)
			.buttonBorderShape(.capsule)
			.disabled(PangeaCode.invite(from: code) == nil || reaching != nil)
		}
	}

	/// Under the code field: reaching them, sending, or sent. Nothing once it failed.
	@ViewBuilder
	private func codeStatus(_ num: Int64) -> some View {
		let name = profiles.name(num: num, radioName: existingUser(num: num, context: accessoryManager.context)?.longName)
		if sent.contains(num) {
			Label("Invite sent to \(name)", systemImage: "checkmark")
				.font(.subheadline)
				.foregroundStyle(.green)
		} else if reaching == num || sending.contains(num) {
			HStack(spacing: 10) {
				ProgressView()
				if case .reaching(let code) = resolver.state {
					Text("Reaching \(code)…")
				} else {
					Text("Sending invite to \(name)…")
				}
			}
			.font(.subheadline)
			.foregroundStyle(.secondary)
		}
	}

	/// The per-person Sent / progress / Invite control.
	@ViewBuilder
	private func status(for num: Int64, @ViewBuilder button: () -> some View) -> some View {
		if sent.contains(num) {
			Label("Sent", systemImage: "checkmark")
				.labelStyle(.titleAndIcon)
				.font(.subheadline)
				.foregroundStyle(.green)
		} else if sending.contains(num) || reaching == num {
			ProgressView()
		} else {
			button()
		}
	}

	// MARK: Sending

	/// A list row: sent straight away when we have their key, otherwise reached first.
	private func inviteListed(_ num: Int64) async {
		if let user = keyedUser(num) {
			error = await send(to: user)
		} else {
			reach(PangeaCode.Invite(nodeNum: num), fromCode: false)
		}
	}

	private func reachTypedCode() {
		guard let typed = PangeaCode.invite(from: code), reaching == nil else { return }
		reach(typed, fromCode: true)
	}

	private func reach(_ person: PangeaCode.Invite, fromCode: Bool) {
		let num = person.nodeNum
		// Typed or scanned: my own node has a key, so it would otherwise be sent one.
		guard num != accessoryManager.activeDeviceNum else {
			let message = String(localized: "That's your own code. Enter a friend's code to invite them.")
			if fromCode {
				codeTarget = nil
				codeError = message
			} else {
				error = message
			}
			return
		}
		if fromCode {
			codeTarget = num
			codeError = nil
		} else {
			error = nil
		}
		reaching = num
		if keyedUser(num) != nil {
			// Already known: no need to say hello first.
			Task { await sendOnceKnown(num) }
			return
		}
		// From idle, so the status line doesn't show the last attempt's outcome meanwhile.
		resolver.cancel()
		Task {
			let outcome = await resolver.resolveAndWait(person, accessoryManager: accessoryManager)
			guard reaching == num else { return }
			switch outcome {
			case .ready(let ready) where ready == num:
				await sendOnceKnown(num)
			case .unreachable(let code):
				report(String(localized: "Couldn't reach \(code) yet. They might be out of range or have their radio off."), for: num)
				reaching = nil
			case .failed(let message):
				report(message, for: num)
				reaching = nil
			case .idle, .reaching, .ready:
				// Cancelled (the sheet closed): nothing to say.
				reaching = nil
			}
		}
	}

	/// Shown under the code field when that's where they were entered, otherwise under the list.
	private func report(_ message: String?, for num: Int64?) {
		if num != nil, num == codeTarget {
			codeError = message
		} else {
			error = message
		}
	}

	/// Only someone with a key can be sent an invite (it goes privately).
	private func keyedUser(_ num: Int64) -> UserEntity? {
		guard let user = existingUser(num: num, context: accessoryManager.context),
			  user.pkiEncrypted, !(user.publicKey?.isEmpty ?? true) else { return nil }
		return user
	}

	/// The resolver says ready as soon as a link's contact is added; their key can land a moment later.
	private func sendOnceKnown(_ num: Int64) async {
		defer { reaching = nil }
		for _ in 0..<10 {
			if let user = keyedUser(num) {
				report(await send(to: user), for: num)
				return
			}
			try? await Task.sleep(for: .milliseconds(500))
		}
		report(GroupChatError.noKey.localizedDescription, for: num)
	}

	/// Returns what went wrong, in words, or nil once it's sent.
	private func send(to user: UserEntity) async -> String? {
		guard let invite else { return nil }
		sending.insert(user.num)
		defer { sending.remove(user.num) }
		do {
			try await GroupChats.sendInvite(invite, to: user, accessoryManager: accessoryManager)
			sent.insert(user.num)
			return nil
		} catch {
			return error.localizedDescription
		}
	}

	private func qrImage(_ url: URL) -> UIImage? {
		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(url.absoluteString.utf8)
		filter.correctionLevel = "M"
		guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
			  let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
		return UIImage(cgImage: cgImage)
	}
}

// MARK: Join

struct JoinGroupSheet: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var inbox = PangeaInbox.shared
	@ObservedObject var router: Router
	let invite: GroupInvite

	@State private var isJoining = false
	@State private var error: String?
	@State private var isFull = false
	/// Groups whose Leave was tapped and is waiting on the radio.
	@State private var leaving: Set<Int32> = []

	private var groups: [ChannelEntity] {
		guard let num = accessoryManager.activeDeviceNum,
			  let myInfo = getNodeInfo(id: num, context: accessoryManager.context)?.myInfo else { return [] }
		return GroupChats.groups(in: myInfo)
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 20) {
				Image(systemName: "person.3.fill")
					.font(.system(size: 44))
					.foregroundStyle(Color.accentColor)
					.padding(.top, 24)
				Text("Join \(invite.name)?")
					.font(.title.bold())
					.multilineTextAlignment(.center)
				Text("You'll see messages from everyone in this group, and they'll see yours.")
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
				if let error {
					Label(error, systemImage: "exclamationmark.triangle.fill")
						.font(.footnote)
						.foregroundStyle(.orange)
				}
				if isFull {
					fullList
				}
				Spacer()
				Button {
					Task { await join() }
				} label: {
					Text(isJoining ? "Joining…" : "Join Group")
						.frame(maxWidth: 400)
				}
				.capsuleButtonStyle()
				.disabled(isJoining)
				.padding(.bottom)
			}
			.padding(.horizontal)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Not Now") { dismiss() }
				}
			}
		}
	}

	private var fullList: some View {
		List {
			Section("Leave a group to make room") {
				ForEach(groups, id: \.index) { channel in
					HStack {
						Text(GroupChats.displayName(channel))
						Spacer()
						let index = channel.index
						Button("Leave", role: .destructive) {
							leaving.insert(index)
							Task {
								defer { leaving.remove(index) }
								try? await GroupChats.leave(channel, accessoryManager: accessoryManager)
								isFull = false
								error = nil
							}
						}
						.buttonStyle(.bordered)
						.disabled(leaving.contains(index))
					}
				}
			}
		}
		.listStyle(.insetGrouped)
		.frame(maxHeight: 320)
	}

	private func join() async {
		isJoining = true
		defer { isJoining = false }
		do {
			let index = try await GroupChats.join(invite, accessoryManager: accessoryManager)
			if let source = inbox.joinRequestSource {
				GroupInviteStore.shared.remove(source)
			}
			router.selectedTab = .messages
			inbox.openedGroup = index
			dismiss()
		} catch GroupChatError.full {
			isFull = true
			error = GroupChatError.full.localizedDescription
		} catch {
			self.error = error.localizedDescription
		}
	}
}

// MARK: Group chat screen

struct GroupChatScreen: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	let myInfo: MyInfoEntity
	let channel: ChannelEntity
	var onLeft: () -> Void

	@State private var showInvite = false
	@State private var confirmLeave = false
	@AppStorage(GroupChats.everyoneNotificationsKey) private var everyoneNotifications = false

	private var recentSenders: [Int64] {
		var seen = Set<Int64>()
		return channel.allPrivateMessages.reversed().prefix(200).compactMap { $0.fromUser?.num }.filter { seen.insert($0).inserted }
	}

	var body: some View {
		ChannelMessageList(myInfo: myInfo, channel: channel)
			.safeAreaInset(edge: .top) {
				PhotoUpdateBanner(nums: recentSenders)
			}
			.toolbar {
				if GroupChats.isEveryone(channel) {
					ToolbarItem(placement: .topBarTrailing) {
						Button {
							everyoneNotifications.toggle()
						} label: {
							Image(systemName: everyoneNotifications ? "bell.fill" : "bell.slash")
						}
						.accessibilityLabel(everyoneNotifications ? "Turn Off Notifications" : "Turn On Notifications")
					}
				} else {
					ToolbarItem(placement: .topBarTrailing) {
						Menu {
							Button {
								showInvite = true
							} label: {
								Label("Invite People", systemImage: "person.badge.plus")
							}
							Button(role: .destructive) {
								confirmLeave = true
							} label: {
								Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
							}
						} label: {
							Image(systemName: "person.badge.plus")
						}
						.accessibilityLabel("Group Options")
					}
				}
			}
			.sheet(isPresented: $showInvite) {
				GroupInviteSheet(channel: channel)
			}
			.confirmationDialog("Leave \(GroupChats.displayName(channel))?", isPresented: $confirmLeave, titleVisibility: .visible) {
				Button("Leave Group", role: .destructive) {
					// Pop the screen before the channel's objects are deleted out from under it.
					onLeft()
					Task {
						try? await Task.sleep(for: .milliseconds(600))
						do {
							try await GroupChats.leave(channel, accessoryManager: accessoryManager)
						} catch {
							Logger.services.error("👥 [Groups] Leave failed: \(error.localizedDescription, privacy: .public)")
						}
					}
				}
			} message: {
				Text("Messages in this group will be removed from this phone. You can rejoin with an invite.")
			}
	}
}
