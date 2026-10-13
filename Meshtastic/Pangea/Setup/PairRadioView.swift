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

	/// First-run setup moves on if a radio is already connected. From Settings the
	/// user is here to pick a different radio, so the list always shows.
	var finishIfAlreadyConnected = false
	/// Called once the radio has finished sending its config and node list.
	var onPaired: () -> Void

	@State private var selectedDevice: Device?
	@State private var pendingSwitch: Device?
	@State private var didFinish = false
	/// Why the last pick didn't get as far as connecting.
	@State private var pickError: String?
	/// A pick is under way: disconnecting, waiting for the radio, clearing the old radio's
	/// chats, or connecting. `lastConnectionError` until then is the old radio's, cleared only
	/// once the connect starts, so it mustn't bring the list (and a second pick) back meanwhile.
	@State private var isPicking = false

	/// The radio already in use, shown above the list when opened from Settings.
	private var currentRadio: Device? {
		guard !finishIfAlreadyConnected, selectedDevice == nil, accessoryManager.state == .subscribed else { return nil }
		return accessoryManager.activeConnection?.device
	}

	private var nearbyRadios: [Device] {
		let currentId = accessoryManager.activeConnection?.device.id
		return accessoryManager.devices.filter { $0.id != currentId }.sorted { lhs, rhs in
			let lhsPangea = RadioAutoConfig.isPangeaRadio(lhs)
			let rhsPangea = RadioAutoConfig.isPangeaRadio(rhs)
			if lhsPangea != rhsPangea { return lhsPangea }
			return (lhs.rssi ?? -200) > (rhs.rssi ?? -200)
		}
	}

	private var isWorking: Bool {
		selectedDevice != nil && (isPicking || accessoryManager.lastConnectionError == nil) && accessoryManager.state != .subscribed
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(spacing: 24) {
					header
					if isWorking, let device = selectedDevice {
						progress(for: device)
					} else {
						if let pickError {
							errorCard(pickError)
						} else if let error = accessoryManager.lastConnectionError, selectedDevice != nil {
							errorCard(friendlyMessage(for: error))
						}
						if let currentRadio {
							currentRadioCard(currentRadio)
						}
						radioList
					}
				}
				.padding()
			}
		}
		.onAppear {
			if finishIfAlreadyConnected, accessoryManager.state == .subscribed, accessoryManager.activeConnection != nil {
				finish()
				return
			}
			// While a radio is connected this scans for others without changing the
			// connection state (see AccessoryManager.startDiscovery).
			accessoryManager.startDiscovery()
		}
		.onDisappear {
			// Connecting stops the scan; if the user leaves with the old radio still
			// connected, stop the scan this screen started.
			if selectedDevice == nil, accessoryManager.activeConnection != nil {
				accessoryManager.stopDiscovery()
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
			Text("The first time, your phone may ask for a pairing code: enter the number shown on your radio's screen, or 123456 if it doesn't have one. After that it won't ask again.")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.top, 8)
		}
	}

	private func currentRadioCard(_ device: Device) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Label("Connected to \(RadioAutoConfig.pangeaSerial(device) ?? device.name)", systemImage: "checkmark.circle.fill")
				.font(.headline)
				.foregroundStyle(.green)
			Text("To switch, pick another radio below. Radios that are turned on and nearby show up here.")
				.font(.subheadline)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding()
		.background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
	}

	private func radioRow(_ device: Device) -> some View {
		HStack(spacing: 16) {
			Image(systemName: RadioAutoConfig.isPangeaRadio(device) ? "checkmark.seal.fill" : "dot.radiowaves.up.forward")
				.font(.title2)
				.foregroundStyle(RadioAutoConfig.isPangeaRadio(device) ? Color.accentColor : Color(.secondaryLabel))
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

	private func errorCard(_ message: String) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Label("Couldn't connect", systemImage: "exclamationmark.triangle.fill")
				.font(.headline)
				.foregroundStyle(.orange)
			Text(message)
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
		guard !isPicking else { return }
		let preferred = UserDefaults.preferredPeripheralId
		if !preferred.isEmpty && preferred != device.id.uuidString {
			pendingSwitch = device
			return
		}
		selectedDevice = device
		pickError = nil
		isPicking = true
		Task {
			defer { isPicking = false }
			guard let found = await readyToConnect(device) else { return }
			try? await accessoryManager.connect(to: found)
		}
	}

	/// Nothing about the current radio changes (its preference, its chats) until it has
	/// let go and the new one has been heard again.
	private func switchAndConnect(to device: Device) async {
		guard !isPicking else { return }
		selectedDevice = device
		pickError = nil
		isPicking = true
		defer { isPicking = false }
		guard let found = await readyToConnect(device) else { return }
		UserDefaults.preferredPeripheralId = found.id.uuidString
		UserDefaults.preferredPeripheralNum = 0
		// As in upstream's node switch: auto-connect would otherwise find the new preferred
		// radio while the old one's chats are still being cleared, and its node download would
		// land in a half-cleared store. This connect is the only one.
		accessoryManager.isSwitchingDevices = true
		defer {
			accessoryManager.isSwitchingDevices = false
			if !accessoryManager.isConnected {
				accessoryManager.startDiscovery()
			}
		}
		await RadioPairing.clearRadioData()
		try? await accessoryManager.connect(to: found)
	}

	/// Disconnects whatever is connected and waits for the picked radio to show up in
	/// the scan again (closing a connection restarts it). Nil, with the reason shown and
	/// the list back, if either doesn't happen.
	private func readyToConnect(_ device: Device) async -> Device? {
		let name = RadioAutoConfig.pangeaSerial(device) ?? device.name
		guard await RadioPairing.disconnect(accessoryManager: accessoryManager) else {
			let current = accessoryManager.activeConnection.map { RadioAutoConfig.pangeaSerial($0.device) ?? $0.device.name }
			pickError = String(localized: "Couldn't disconnect from \(current ?? String(localized: "your radio")). Try again.")
			selectedDevice = nil
			return nil
		}
		guard let found = await RadioPairing.waitForDevice(id: device.id, accessoryManager: accessoryManager) else {
			pickError = String(localized: "Couldn't find \(name). Make sure it's turned on and nearby.")
			selectedDevice = nil
			return nil
		}
		return found
	}

	private func finish() {
		guard !didFinish else { return }
		didFinish = true
		onPaired()
	}
}
