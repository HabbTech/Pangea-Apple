//
//  MyRadioSection.swift
//  Pangea
//
//  Standard-mode Settings: the paired radio, and a pointer to Expert Mode for
//  people looking for the full Meshtastic toolset.
//

import SwiftUI

struct MyRadioSection: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@State private var showPairing = false
	@State private var confirmForget = false
	@State private var isReconnecting = false
	@State private var reconnectFailed = false
	@State private var isPaired = RadioPairing.isPaired
	@State private var editingName = false
	@ObservedObject private var profiles = ProfileStore.shared

	private var myName: String? {
		guard let num = accessoryManager.activeDeviceNum else { return nil }
		return getNodeInfo(id: num, context: accessoryManager.context)?.user?.longName
	}

	private var pairedDevice: Device? {
		accessoryManager.activeConnection?.device
			?? accessoryManager.devices.first { $0.id.uuidString == UserDefaults.preferredPeripheralId }
	}

	private var myRealName: String {
		profiles.me.displayName.isEmpty ? (myName ?? "") : profiles.me.displayName
	}

	private var myDisplayName: String {
		myRealName.isEmpty ? String(localized: "Set Up Your Profile") : myRealName
	}

	private var radioName: String {
		guard let device = pairedDevice else {
			return isPaired ? String(localized: "My Radio") : String(localized: "No radio paired")
		}
		if let serial = RadioAutoConfig.pangeaSerial(device) {
			return String(localized: "Pangea Radio \(serial)")
		}
		return device.longName ?? device.name
	}

	var body: some View {
		Section {
			Button {
				editingName = true
			} label: {
				HStack(spacing: 14) {
					MyAvatar(initials: myRealName.isEmpty ? "" : RadioAutoConfig.shortName(for: myRealName), size: 56)
					VStack(alignment: .leading, spacing: 2) {
						Text(myDisplayName)
							.font(.headline)
							.foregroundStyle(myRealName.isEmpty ? Color.accentColor : Color.primary)
						Text("Photo, name and emoji")
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
					Spacer()
					Image(systemName: "chevron.right")
						.font(.footnote.weight(.semibold))
						.foregroundStyle(.tertiary)
				}
			}
		} header: {
			Text("You")
		} footer: {
			Text("Friends using Pangea see your photo and name. Everyone else sees your name.")
		}
		.sheet(isPresented: $editingName) {
			ProfileEditorSheet(currentName: myName ?? profiles.me.displayName)
		}
		Section {
			HStack(spacing: 12) {
				Image(systemName: accessoryManager.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
					.font(.title3)
					.foregroundStyle(accessoryManager.isConnected ? Color.accentColor : .secondary)
					.frame(width: 28)
				VStack(alignment: .leading, spacing: 2) {
					Text(radioName)
					Text(accessoryManager.state == .subscribed ? "Connected" : (accessoryManager.isConnecting ? "Connecting…" : "Not connected"))
						.font(.caption)
						.foregroundStyle(accessoryManager.state == .subscribed ? .green : .secondary)
				}
			}
			if isPaired && accessoryManager.state != .subscribed && !accessoryManager.isConnecting {
				Button {
					Task { await reconnect() }
				} label: {
					HStack {
						Text(isReconnecting ? "Looking for your radio…" : "Reconnect")
						if isReconnecting {
							Spacer()
							ProgressView()
						}
					}
				}
				.disabled(isReconnecting)
			}
			Button(isPaired ? "Pair a Different Radio" : "Pair a Radio") {
				showPairing = true
			}
			if isPaired {
				Button("Forget This Radio", role: .destructive) {
					confirmForget = true
				}
			}
		} header: {
			Text("My Radio")
		} footer: {
			if reconnectFailed {
				Text("Couldn't find your radio. Make sure it's turned on, nearby, and not connected to another phone or computer.")
			}
		}
		.sheet(isPresented: $showPairing, onDismiss: { isPaired = RadioPairing.isPaired }) {
			PairRadioSheet()
		}
		.confirmationDialog("Forget this radio?", isPresented: $confirmForget, titleVisibility: .visible) {
			Button("Forget Radio", role: .destructive) {
				Task {
					await RadioPairing.forget(accessoryManager: accessoryManager)
					isPaired = false
					reconnectFailed = false
				}
			}
		} message: {
			Text("This disconnects the radio and removes its chats from this device. You can pair it again anytime.")
		}
		.onChange(of: accessoryManager.state) { _, _ in
			isPaired = RadioPairing.isPaired
		}
		if accessoryManager.state == .subscribed {
			Section {
				MyCodeCard()
					.listRowInsets(EdgeInsets())
					.listRowBackground(Color.clear)
			} footer: {
				Text("Give this code to friends so they can message you.")
			}
		}
	}

	private func reconnect() async {
		isReconnecting = true
		reconnectFailed = false
		reconnectFailed = !(await RadioPairing.reconnect(accessoryManager: accessoryManager))
		isReconnecting = false
	}
}

struct ExpertModeHintSection: View {
	@AppStorage("expertModeEnabled") private var expertModeEnabled: Bool = false

	var body: some View {
		Section {
			Toggle(isOn: $expertModeEnabled.animation()) {
				Label("Expert Mode", systemImage: "wand.and.stars")
			}
			.tint(.accentColor)
		} footer: {
			Text("Looking for the node list, mesh map, or radio settings? Turn on Expert Mode to unlock every advanced feature.")
		}
	}
}
