//
//  NewMessageSheet.swift
//  Pangea
//
//  Start a DM from an @code: type it, paste it, scan it, or arrive via a link.
//

import SwiftUI
import CoreData

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
func existingUser(num: Int64, context: NSManagedObjectContext) -> UserEntity? {
	let request = UserEntity.fetchRequest()
	request.predicate = NSPredicate(format: "num == %lld", num)
	request.fetchLimit = 1
	return try? context.fetch(request).first
}

struct NewMessageSheet: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss
	@ObservedObject var router: Router
	@ObservedObject private var inbox = PangeaInbox.shared
	@StateObject private var resolver = ContactResolver()

	@State private var input = ""
	@State private var invite: PangeaCode.Invite?
	@State private var showScanner = false
	@State private var scanError: String?
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
			if let pending = inbox.pendingInvite {
				inbox.pendingInvite = nil
				invite = pending
				input = pending.code
				start(pending)
			} else {
				inputFocused = true
			}
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
			} else if !input.isEmpty && parsedInvite == nil && input.count >= 8 {
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

	private func start(_ invite: PangeaCode.Invite) {
		inputFocused = false
		resolver.resolve(invite, accessoryManager: accessoryManager)
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
