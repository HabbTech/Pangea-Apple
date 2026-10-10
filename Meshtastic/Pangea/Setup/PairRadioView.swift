//
//  PairRadioView.swift
//  Pangea
//
//  One screen that finds nearby radios, connects, and waits until the radio is
//  ready to use. Shared by first-run setup and Settings → My Radio.
//

import SwiftUI
import OSLog

struct PairRadioView: View {
	@EnvironmentObject var accessoryManager: AccessoryManager

	/// Called once the radio has finished sending its config and node list.
	var onPaired: () -> Void

	@State private var selectedDevice: Device?
	@State private var pendingSwitch: Device?
	@State private var didFinish = false

	private var nearbyRadios: [Device] {
		accessoryManager.devices.sorted { lhs, rhs in
			let lhsPangea = RadioAutoConfig.isPangeaRadio(lhs)
			let rhsPangea = RadioAutoConfig.isPangeaRadio(rhs)
			if lhsPangea != rhsPangea { return lhsPangea }
			return (lhs.rssi ?? -200) > (rhs.rssi ?? -200)
		}
	}

	private var isWorking: Bool {
		selectedDevice != nil && accessoryManager.lastConnectionError == nil && accessoryManager.state != .subscribed
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(spacing: 24) {
					header
					if isWorking, let device = selectedDevice {
						progress(for: device)
					} else {
						if let error = accessoryManager.lastConnectionError, selectedDevice != nil {
							errorCard(error)
						}
						radioList
					}
				}
				.padding()
			}
		}
		.onAppear {
			accessoryManager.startDiscovery()
			if accessoryManager.state == .subscribed, accessoryManager.activeConnection != nil {
				finish()
			}
		}
		.onChange(of: accessoryManager.state) { _, state in
			if state == .subscribed, selectedDevice != nil {
				finish()
			}
		}
		.confirmationDialog(
			"Switch to this radio?",
			isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
			titleVisibility: .visible,
			presenting: pendingSwitch
		) { device in
			Button("Switch Radio", role: .destructive) {
				Task { await switchAndConnect(to: device) }
			}
		} message: { _ in
			Text("Messages saved from your current radio will be removed from this phone.")
		}
	}

	// MARK: Sections

	private var header: some View {
		VStack(spacing: 12) {
			Image(systemName: "antenna.radiowaves.left.and.right")
				.font(.system(size: 48, weight: .regular))
				.foregroundStyle(Color.accentColor)
				.symbolEffect(.variableColor.iterative, isActive: selectedDevice == nil || isWorking)
			Text("Pair Your Radio")
				.font(.largeTitle.bold())
			Text("Turn on your radio and keep it close to your phone.")
				.font(.body)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.padding(.top, 24)
	}

	@ViewBuilder
	private var radioList: some View {
		if nearbyRadios.isEmpty {
			VStack(spacing: 12) {
				ProgressView()
				Text("Looking for radios…")
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 32)
		} else {
			VStack(spacing: 12) {
				ForEach(nearbyRadios) { device in
					Button {
						select(device)
					} label: {
						radioRow(device)
					}
					.buttonStyle(.plain)
				}
			}
			Text("If your phone asks for a pairing code, enter the number shown on your radio's screen. Radios without a screen usually use 123456.")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.top, 8)
		}
	}

	private func radioRow(_ device: Device) -> some View {
		HStack(spacing: 16) {
			Image(systemName: RadioAutoConfig.isPangeaRadio(device) ? "checkmark.seal.fill" : "dot.radiowaves.up.forward")
				.font(.title2)
				.foregroundStyle(RadioAutoConfig.isPangeaRadio(device) ? Color.accentColor : .secondary)
				.frame(width: 36)
			VStack(alignment: .leading, spacing: 2) {
				if let serial = RadioAutoConfig.pangeaSerial(device) {
					Text("Pangea Radio")
						.font(.headline)
					Text(serial)
						.font(.subheadline)
						.foregroundStyle(.secondary)
				} else {
					Text(device.name)
						.font(.headline)
					Text(device.transportType == .ble ? "Bluetooth" : "Wi-Fi")
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			device.getSignalStrength().map {
				SignalStrengthIndicator(signalStrength: $0)
			}
			Image(systemName: "chevron.right")
				.foregroundStyle(.tertiary)
		}
		.padding()
		.frame(minHeight: 64)
		.background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		.contentShape(Rectangle())
	}

	private func progress(for device: Device) -> some View {
		VStack(spacing: 16) {
			ProgressView()
				.controlSize(.large)
			Text(progressText)
				.font(.headline)
			Text("This can take up to a minute the first time.")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 32)
	}

	private var progressText: String {
		switch accessoryManager.state {
		case .connecting, .discovering, .idle, .uninitialized:
			return String(localized: "Connecting to your radio…")
		case .retrying:
			return String(localized: "Still trying to connect…")
		case .communicating:
			return String(localized: "Talking to your radio…")
		case .retrievingDatabase(let count):
			return count > 0
				? String(localized: "Getting your radio ready… found \(count) nearby")
				: String(localized: "Getting your radio ready…")
		case .subscribed:
			return String(localized: "Connected")
		}
	}

	private func errorCard(_ error: Error) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Label("Couldn't connect", systemImage: "exclamationmark.triangle.fill")
				.font(.headline)
				.foregroundStyle(.orange)
			Text(friendlyMessage(for: error))
				.font(.subheadline)
				.foregroundStyle(.secondary)
			Text("Tap your radio below to try again.")
				.font(.subheadline)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding()
		.background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
	}

	private func friendlyMessage(for error: Error) -> String {
		let text = error.localizedDescription
		if text.localizedCaseInsensitiveContains("firmware") {
			return String(localized: "Your radio's software is too old for Pangea. Update it from Settings → Firmware Updates after turning on Expert Mode, or contact us for help.")
		}
		if text.localizedCaseInsensitiveContains("pair") || text.localizedCaseInsensitiveContains("peer removed") {
			#if targetEnvironment(macCatalyst)
			return String(localized: "Your Mac forgot this radio. Open System Settings → Bluetooth, click ⓘ next to the radio, choose Forget This Device, then try again.")
			#else
			return String(localized: "Your phone forgot this radio. Open the iPhone Settings app → Bluetooth, tap ⓘ next to the radio, choose Forget This Device, then try again.")
			#endif
		}
		return String(localized: "Make sure the radio is on and nearby.")
	}

	// MARK: Actions

	private func select(_ device: Device) {
		let preferred = UserDefaults.preferredPeripheralId
		if !preferred.isEmpty && preferred != device.id.uuidString {
			pendingSwitch = device
			return
		}
		selectedDevice = device
		Task {
			if accessoryManager.activeConnection != nil {
				try? await accessoryManager.disconnect()
			}
			try? await accessoryManager.connect(to: device)
		}
	}

	private func switchAndConnect(to device: Device) async {
		selectedDevice = device
		UserDefaults.preferredPeripheralId = device.id.uuidString
		UserDefaults.preferredPeripheralNum = 0
		if accessoryManager.activeConnection != nil {
			try? await accessoryManager.disconnect()
		}
		await MeshPackets.shared.clearCoreDataDatabase(includeRoutes: false)
		clearNotifications()
		try? await accessoryManager.connect(to: device)
	}

	private func finish() {
		guard !didFinish else { return }
		didFinish = true
		onPaired()
	}
}
