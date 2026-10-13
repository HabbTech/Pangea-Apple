//
//  NewMessageSheet.swift
//  Pangea
//
//  Start a DM from an @code: type it, paste it, scan it, arrive via a link,
//  or pick someone saved to Contacts.
//

import SwiftUI
import SwiftData

/// App-wide hand-off for invites that arrive from outside the sheet (links, mentions).
@MainActor
final class PangeaInbox: ObservableObject {
	static let shared = PangeaInbox()

	@Published var pendingInvite: PangeaCode.Invite?
	@Published var isComposing = false
	@Published var isScanning = false

	/// Group waiting for the user to confirm joining, and the stored invite it came from.
	@Published var joinRequest: GroupInvite?
	var joinRequestSource: GroupInviteStore.Pending?
	/// Set after a successful join so the chat list can open the group.
	@Published var openedGroup: Int32?

	/// Opens New Message with an invite already filled in.
	func open(_ invite: PangeaCode.Invite) {
		pendingInvite = invite
		isComposing = true
	}

	/// - Parameter afterDismissal: wait for a sheet that's closing, so SwiftUI can present the next one.
	func openJoin(_ invite: GroupInvite, pending: GroupInviteStore.Pending? = nil, afterDismissal: Bool = false) {
		joinRequestSource = pending
		guard afterDismissal else {
			joinRequest = invite
			return
		}
		Task {
			try? await Task.sleep(for: .milliseconds(700))
			joinRequest = invite
		}
	}

	/// Handles pangea:// links. Returns false for anything that isn't ours.
	@discardableResult
	func handle(url: URL) -> Bool {
		guard url.scheme?.lowercased() == PangeaCode.scheme else { return false }
		if let group = GroupInvite(url: url) {
			openJoin(group)
		} else if let invite = PangeaCode.invite(from: url) {
			open(invite)
		}
		return true
	}

	/// Anything scanned or pasted: a person's code or a group invite.
	@discardableResult
	func handle(scanned text: String) -> Bool {
		if let url = URL(string: text), let group = GroupInvite(url: url) {
			openJoin(group)
			return true
		}
		if let invite = PangeaCode.invite(from: text) {
			open(invite)
			return true
		}
		return false
	}
}

/// Fetch without creating; upstream's getUser inserts a blank user when none exists.
@MainActor
func existingUser(num: Int64, context: ModelContext) -> UserEntity? {
	var descriptor = FetchDescriptor<UserEntity>(predicate: #Predicate { $0.num == num })
	descriptor.fetchLimit = 1
	return try? context.fetch(descriptor).first
}

struct NewMessageSheet: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.modelContext) private var context
	@Environment(\.dismiss) private var dismiss
	@ObservedObject var router: Router
	@ObservedObject private var inbox = PangeaInbox.shared
	@ObservedObject private var profiles = ProfileStore.shared
	@StateObject private var resolver = ContactResolver()

	@State private var input = ""
	@State private var invite: PangeaCode.Invite?
	@State private var showScanner = false
	@State private var scanError: String?
	/// Contact waiting on "Remove from Contacts" to be confirmed.
	@State private var removingContact: Int64?
	@FocusState private var inputFocused: Bool

	private var parsedInvite: PangeaCode.Invite? {
		invite ?? PangeaCode.invite(from: input)
	}

	private var isBusy: Bool {
		if case .reaching = resolver.state { return true }
		return false
	}

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 24) {
					composeCard
					resolverStatus
					contactsCard
					MyCodeCard()
				}
				.padding()
			}
			.navigationTitle("New Message")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") {
						resolver.cancel()
						dismiss()
					}
				}
			}
			.sheet(isPresented: $showScanner) {
				QRScannerSheet { value in
					if let url = URL(string: value), let group = GroupInvite(url: url) {
						dismiss()
						inbox.openJoin(group, afterDismissal: true)
					} else if let scanned = PangeaCode.invite(from: value) {
						scanError = nil
						invite = scanned
						input = scanned.code
						start(scanned)
					} else {
						scanError = String(localized: "That QR code isn't a Pangea code.")
					}
				}
			}
		}
		.onAppear {
			if !takePendingInvite() {
				inputFocused = true
			}
		}
		.onChange(of: inbox.pendingInvite) { _, _ in
			// A link or mention tapped while this sheet is already open.
			takePendingInvite()
		}
		.onDisappear {
			// Closed however it was closed: stop saying hello, and don't replay a stale link next time.
			resolver.cancel()
			inbox.pendingInvite = nil
		}
		.onChange(of: resolver.state) { _, state in
			if case .ready(let nodeNum) = state {
				openConversation(nodeNum)
			}
		}
	}

	// MARK: Sections

	private var composeCard: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Message someone")
				.font(.headline)
			HStack(spacing: 8) {
				TextField("@code", text: $input)
					.font(.system(.title3, design: .monospaced))
					.textInputAutocapitalization(.characters)
					.autocorrectionDisabled()
					.submitLabel(.go)
					.focused($inputFocused)
					.onSubmit { if let parsedInvite { start(parsedInvite) } }
					.onChange(of: input) { _, newValue in
						// Typing replaces whatever a scan or link filled in.
						if let invite, newValue != invite.code { self.invite = nil }
					}
					.disabled(isBusy)
				if input.isEmpty, UIPasteboard.general.hasStrings {
					PasteButton(payloadType: String.self) { strings in
						if let first = strings.first {
							input = PangeaCode.invite(from: first)?.code ?? first
						}
					}
					.labelStyle(.iconOnly)
					.buttonBorderShape(.capsule)
				}
				Button {
					showScanner = true
				} label: {
					Image(systemName: "qrcode.viewfinder")
						.font(.title2)
				}
				.accessibilityLabel("Scan QR code")
				.disabled(isBusy)
			}
			.padding()
			.background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

			if let name = parsedInvite?.displayName {
				Label(name, systemImage: "person.crop.circle.badge.checkmark")
					.foregroundStyle(.secondary)
			} else if !input.isEmpty && parsedInvite == nil && PangeaCode.looksComplete(input) {
				Label("That code doesn't look right. Check it and try again.", systemImage: "exclamationmark.circle")
					.font(.footnote)
					.foregroundStyle(.orange)
			}
			if let scanError {
				Label(scanError, systemImage: "exclamationmark.circle")
					.font(.footnote)
					.foregroundStyle(.orange)
			}

			Button {
				if let parsedInvite { start(parsedInvite) }
			} label: {
				Text("Start Chat")
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.buttonBorderShape(.capsule)
			.controlSize(.large)
			.disabled(parsedInvite == nil || isBusy)
		}
	}

	private var contactsCard: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Contacts")
				.font(.headline)
			// Not me: a contact saved on another radio can be the one connected now.
			let nums = profiles.contactNums(radioName: { existingUser(num: $0, context: context)?.longName }).filter { $0 != accessoryManager.activeDeviceNum }
			if nums.isEmpty {
				Text("Save people from their profile to see them here.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				VStack(spacing: 0) {
					ForEach(nums, id: \.self) { num in
						Button {
							openContact(num)
						} label: {
							ContactRow(num: num, user: existingUser(num: num, context: context)) {
								Image(systemName: "chevron.right")
									.font(.footnote.weight(.semibold))
									.foregroundStyle(.tertiary)
							}
							.padding(.vertical, 8)
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
						.disabled(isBusy)
						.contextMenu {
							Button(role: .destructive) {
								removingContact = num
							} label: {
								Label("Remove from Contacts", systemImage: "person.crop.circle.badge.minus")
							}
						}
						if num != nums.last {
							Divider()
						}
					}
				}
				.padding(.horizontal)
				.background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			}
		}
		.confirmationDialog(removingContact.map(removeContactQuestion) ?? "", isPresented: Binding(
			get: { removingContact != nil },
			set: { if !$0 { removingContact = nil } }
		), titleVisibility: .visible, presenting: removingContact) { num in
			Button("Remove from Contacts", role: .destructive) {
				profiles.setContact(false, for: num)
				removingContact = nil
			}
		}
	}

	private func removeContactQuestion(_ num: Int64) -> String {
		let name = profiles.name(num: num, radioName: existingUser(num: num, context: context)?.longName ?? profiles.profile(num)?.contactName)
		return String(localized: "Remove \(name) from Contacts?")
	}

	@ViewBuilder
	private var resolverStatus: some View {
		switch resolver.state {
		case .idle, .ready:
			EmptyView()
		case .reaching(let code):
			HStack(alignment: .top, spacing: 12) {
				ProgressView()
				VStack(alignment: .leading, spacing: 4) {
					Text("Reaching \(code)…")
						.font(.headline)
					Text("Saying hello over the mesh to swap encryption keys. They need to have their radio on and be in range.")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}
			.statusCard(tint: .accentColor)
		case .unreachable(let code):
			VStack(alignment: .leading, spacing: 8) {
				Label("Couldn't reach \(code) yet", systemImage: "antenna.radiowaves.left.and.right.slash")
					.font(.headline)
				Text("They might be out of range or have their radio off. Scanning their QR code or opening their link connects instantly, even from far away.")
					.font(.footnote)
					.foregroundStyle(.secondary)
				Button("Try Again") {
					if let parsedInvite { start(parsedInvite) }
				}
				.font(.subheadline.bold())
			}
			.statusCard(tint: .orange)
		case .failed(let message):
			Label(message, systemImage: "exclamationmark.triangle.fill")
				.font(.subheadline)
				.statusCard(tint: .orange)
		}
	}

	// MARK: Actions

	@discardableResult
	private func takePendingInvite() -> Bool {
		guard let pending = inbox.pendingInvite else { return false }
		inbox.pendingInvite = nil
		scanError = nil
		invite = pending
		input = pending.code
		start(pending)
		return true
	}

	private func start(_ invite: PangeaCode.Invite) {
		inputFocused = false
		resolver.resolve(invite, accessoryManager: accessoryManager)
	}

	/// Reached by code, as if it were typed: the resolver opens the chat at once when we have
	/// their key, and swaps keys first when we don't, so nothing goes out on the public channel.
	private func openContact(_ num: Int64) {
		let contact = PangeaCode.Invite(nodeNum: num)
		scanError = nil
		invite = contact
		input = contact.code
		start(contact)
	}

	private func openConversation(_ nodeNum: Int64) {
		router.selectedTab = .messages
		router.messagesState = .directMessages(userNum: nodeNum)
		dismiss()
	}
}

private extension View {
	func statusCard(tint: Color) -> some View {
		self
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding()
			.background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
	}
}

struct NewMessageButton: View {
	var body: some View {
		Button {
			PangeaInbox.shared.isComposing = true
		} label: {
			Image(systemName: "square.and.pencil")
		}
		.accessibilityLabel("New Message")
	}
}
