//
//  PairRadioSheet.swift
//  Pangea
//
//  Pairing outside of first-run setup: pair, then ask for a name / region only
//  if the radio still needs them.
//

import SwiftUI

/// Presents `PairRadioSheet` from the window root, above ContentView's `.id(databaseResetID)`.
/// Pairing a different radio clears this device's chats, and the clear remounts everything
/// under that id: a sheet presented from inside it was torn down mid-connect, so the name and
/// region step after pairing never showed.
@MainActor
final class PairRadioPresenter: ObservableObject {
	@Published var isPresented = false
}

struct PairRadioSheet: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss
	@State private var showProfile = false

	var body: some View {
		NavigationStack {
			PairRadioView {
				if let status = RadioAutoConfig.status(of: accessoryManager), status.needsRegion || status.hasDefaultName {
					showProfile = true
				} else {
					dismiss()
				}
			}
			.navigationDestination(isPresented: $showProfile) {
				SetupProfileView {
					dismiss()
				}
				.navigationBarBackButtonHidden()
			}
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
			}
		}
	}
}

/// Shown above the tab bar in standard mode whenever the radio isn't ready, so a
/// disconnected radio never looks like "messages aren't sending".
struct RadioStatusBanner: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@EnvironmentObject private var pairRadio: PairRadioPresenter
	@State private var isReconnecting = false

	private enum Status {
		case hidden
		case connecting
		case searching
		case notPaired
	}

	private var status: Status {
		if accessoryManager.state == .subscribed { return .hidden }
		if isReconnecting || accessoryManager.isConnecting || accessoryManager.isConnected { return .connecting }
		return UserDefaults.preferredPeripheralId.isEmpty ? .notPaired : .searching
	}

	var body: some View {
		// A VStack, not a Group: a Group hands its modifiers to its child, so the
		// .hidden case (EmptyView) would lose the animation the moment the radio connects.
		// The pairing sheet itself is presented from the window root (PairRadioPresenter).
		VStack(spacing: 0) {
			switch status {
			case .hidden:
				EmptyView()
			case .connecting:
				pill(icon: nil, text: String(localized: "Connecting to your radio…"), action: nil) {}
			case .searching:
				pill(icon: "antenna.radiowaves.left.and.right.slash", text: String(localized: "Radio disconnected"), action: String(localized: "Reconnect")) {
					Task {
						isReconnecting = true
						let found = await RadioPairing.reconnect(accessoryManager: accessoryManager)
						isReconnecting = false
						if !found { pairRadio.isPresented = true }
					}
				}
			case .notPaired:
				pill(icon: "antenna.radiowaves.left.and.right", text: String(localized: "No radio paired"), action: String(localized: "Pair Radio")) {
					pairRadio.isPresented = true
				}
			}
		}
		.animation(.snappy, value: status == .hidden)
	}

	private func pill(icon: String?, text: String, action: String?, perform: @escaping () -> Void) -> some View {
		HStack(spacing: 10) {
			if let icon {
				Image(systemName: icon)
					.foregroundStyle(.secondary)
			} else {
				ProgressView()
					.controlSize(.small)
			}
			Text(text)
				.font(.subheadline)
			if let action {
				Spacer(minLength: 8)
				Button(action, action: perform)
					.font(.subheadline.bold())
					.buttonStyle(.borderedProminent)
					.buttonBorderShape(.capsule)
					.controlSize(.small)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
		.background(.regularMaterial, in: Capsule())
		.padding(.horizontal)
		.padding(.bottom, 6)
		.transition(.move(edge: .bottom).combined(with: .opacity))
	}
}
