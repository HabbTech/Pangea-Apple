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

	private var radioName: String {
		guard let device = accessoryManager.activeConnection?.device else {
			return String(localized: "No radio connected")
		}
		if let serial = RadioAutoConfig.pangeaSerial(device) {
			return String(localized: "Pangea Radio \(serial)")
		}
		return device.longName ?? device.name
	}

	var body: some View {
		Section("My Radio") {
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
			Button(accessoryManager.activeConnection == nil ? "Pair a Radio" : "Pair a Different Radio") {
				showPairing = true
			}
		}
		.sheet(isPresented: $showPairing) {
			PairRadioSheet()
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
