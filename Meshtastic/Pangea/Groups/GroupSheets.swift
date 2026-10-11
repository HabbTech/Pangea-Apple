//
//  GroupSheets.swift
//  Pangea
//
//  New Group, Invite People, Join Group, and the group chat screen itself.
//

import SwiftUI
import CoreData
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
			   let channel = (getNodeInfo(id: num, context: accessoryManager.context)?.myInfo?.channels?.array as? [ChannelEntity])?.first(where: { $0.index == index }) {
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
	let channel: ChannelEntity

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \UserEntity.lastMessage, ascending: false)],
		predicate: NSPredicate(format: "pkiEncrypted == YES AND lastMessage != nil")
	) private var contacts: FetchedResults<UserEntity>

	@State private var sent: Set<Int64> = []
	@State private var sending: Set<Int64> = []
	@State private var error: String?

	private var invite: GroupInvite? {
		guard let name = channel.name, let psk = channel.psk else { return nil }
		return GroupInvite(name: name, psk: psk)
	}

	var body: some View {
		List {
			if let invite, let link = invite.link {
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

			Section {
				if contacts.isEmpty {
					Text("People you've messaged privately show up here, so you can invite them with one tap.")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				ForEach(contacts.filter { $0.num != accessoryManager.activeDeviceNum }, id: \.num) { user in
					HStack {
						PangeaAvatar(user: user, size: 36)
						Text(ProfileStore.shared.name(for: user))
						Spacer()
						if sent.contains(user.num) {
							Label("Sent", systemImage: "checkmark")
								.labelStyle(.titleAndIcon)
								.font(.subheadline)
								.foregroundStyle(.green)
						} else if sending.contains(user.num) {
							ProgressView()
						} else {
							Button("Invite") {
								Task { await send(to: user) }
							}
							.buttonStyle(.bordered)
							.buttonBorderShape(.capsule)
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
		}
	}

	private func send(to user: UserEntity) async {
		guard let invite else { return }
		sending.insert(user.num)
		defer { sending.remove(user.num) }
		do {
			try await GroupChats.sendInvite(invite, to: user, accessoryManager: accessoryManager)
			sent.insert(user.num)
			error = nil
		} catch {
			self.error = error.localizedDescription
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
						Button("Leave", role: .destructive) {
							Task {
								try? await GroupChats.leave(channel, accessoryManager: accessoryManager)
								isFull = false
								error = nil
							}
						}
						.buttonStyle(.bordered)
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
				if !GroupChats.isEveryone(channel) {
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
