//
//  RadioPairing.swift
//  Pangea
//
//  Reconnect to, or forget, the radio this device is paired with.
//

import Foundation
import OSLog

@MainActor
enum RadioPairing {

	static var isPaired: Bool { !UserDefaults.preferredPeripheralId.isEmpty }

	/// Looks for the paired radio for up to `timeout` and connects to it.
	/// Returns false if it never showed up.
	static func reconnect(accessoryManager: AccessoryManager, timeout: Duration = .seconds(15)) async -> Bool {
		guard isPaired, !accessoryManager.isConnecting, accessoryManager.state != .subscribed else { return true }
		let id = UserDefaults.preferredPeripheralId
		if accessoryManager.activeConnection != nil {
			try? await accessoryManager.disconnect()
		}
		accessoryManager.startDiscovery()

		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			if let device = accessoryManager.devices.first(where: { $0.id.uuidString == id }) {
				do {
					try await accessoryManager.connect(to: device)
					return true
				} catch {
					Logger.transport.error("📻 [Pangea] Reconnect failed: \(error.localizedDescription, privacy: .public)")
					return false
				}
			}
			try? await Task.sleep(for: .milliseconds(500))
		}
		return false
	}

	/// Disconnects, stops auto-reconnecting, and removes that radio's chats from this device.
	static func forget(accessoryManager: AccessoryManager) async {
		if accessoryManager.activeConnection != nil || accessoryManager.isConnecting {
			try? await accessoryManager.disconnect()
		}
		UserDefaults.preferredPeripheralId = ""
		UserDefaults.preferredPeripheralNum = 0
		await MeshPackets.shared.clearCoreDataDatabase(includeRoutes: false)
		clearNotifications()
		accessoryManager.startDiscovery()
		Logger.transport.info("📻 [Pangea] Forgot paired radio")
	}
}
