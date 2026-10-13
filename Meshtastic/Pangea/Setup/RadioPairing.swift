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

	/// A connection attempt has been admitted and hasn't finished (see the guard in
	/// `AccessoryManager.connect(to:)`).
	static func isAttemptInFlight(_ accessoryManager: AccessoryManager) -> Bool {
		accessoryManager.isConnecting || accessoryManager.connectionStepper != nil
	}

	/// Looks for the paired radio for up to `timeout` and connects to it. If discovery's
	/// own auto-connect (or an earlier tap) gets there first, that attempt is followed
	/// instead of starting a second one. An attempt, once started, is followed to its end
	/// for up to `attemptTimeout`, the same whoever started it.
	/// Returns true only once the radio is connected and ready.
	static func reconnect(accessoryManager: AccessoryManager, timeout: Duration = .seconds(15), attemptTimeout: Duration = .seconds(90)) async -> Bool {
		if accessoryManager.state == .subscribed { return true }
		guard isPaired else { return false }
		if isAttemptInFlight(accessoryManager) {
			return await outcome(of: nil, accessoryManager: accessoryManager, timeout: attemptTimeout)
		}
		let id = UserDefaults.preferredPeripheralId
		guard await disconnect(accessoryManager: accessoryManager) else { return false }
		accessoryManager.startDiscovery()

		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			if accessoryManager.state == .subscribed { return true }
			if isAttemptInFlight(accessoryManager) {
				return await outcome(of: nil, accessoryManager: accessoryManager, timeout: attemptTimeout)
			}
			if let device = accessoryManager.devices.first(where: { $0.id.uuidString == id }) {
				let attempt = Attempt()
				Task {
					defer { attempt.isFinished = true }
					do {
						try await accessoryManager.connect(to: device)
					} catch {
						// Refused because auto-connect got in first: `outcome` follows that one.
						Logger.transport.error("📻 [Pangea] Reconnect: \(error.localizedDescription, privacy: .public)")
					}
				}
				return await outcome(of: attempt, accessoryManager: accessoryManager, timeout: attemptTimeout)
			}
			try? await Task.sleep(for: .milliseconds(500))
		}
		return false
	}

	@MainActor
	private final class Attempt {
		var isFinished = false
	}

	/// Waits for the radio to be ready, or for the attempt to end: ours, if we started one
	/// (it may not have begun yet), and whichever attempt is in flight.
	private static func outcome(of ours: Attempt?, accessoryManager: AccessoryManager, timeout: Duration) async -> Bool {
		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			if accessoryManager.state == .subscribed { return true }
			if ours?.isFinished ?? true, !isAttemptInFlight(accessoryManager) { return false }
			try? await Task.sleep(for: .milliseconds(200))
		}
		return accessoryManager.state == .subscribed
	}

	/// Disconnects, stops auto-reconnecting, and removes that radio's chats from this device.
	/// False, with nothing changed, when the radio didn't let go.
	@discardableResult
	static func forget(accessoryManager: AccessoryManager, timeout: Duration = .seconds(5)) async -> Bool {
		guard await disconnect(accessoryManager: accessoryManager, timeout: timeout) else {
			Logger.transport.error("📻 [Pangea] Couldn't disconnect; nothing forgotten")
			return false
		}
		UserDefaults.preferredPeripheralId = ""
		UserDefaults.preferredPeripheralNum = 0
		await clearRadioData()
		accessoryManager.startDiscovery()
		Logger.transport.info("📻 [Pangea] Forgot paired radio")
		return true
	}

	/// Disconnects; `disconnect()` waits for the teardown to finish.
	/// - Returns: false if it still hadn't finished after `timeout`.
	@discardableResult
	static func disconnect(accessoryManager: AccessoryManager, timeout: Duration = .seconds(5)) async -> Bool {
		guard !accessoryManager.isFullyDisconnected else { return true }
		try? await accessoryManager.disconnect(timeout: timeout)
		return accessoryManager.isFullyDisconnected
	}

	/// Waits (up to `timeout`) for discovery to report this radio. Closing a connection
	/// restarts the scan, which forgets what it had found, so a radio picked from the list
	/// while another was connected has to be heard again before it can be connected to.
	static func waitForDevice(id: UUID, accessoryManager: AccessoryManager, timeout: Duration = .seconds(10)) async -> Device? {
		let deadline = ContinuousClock.now + timeout
		while true {
			if let device = accessoryManager.devices.first(where: { $0.id == id }) { return device }
			guard ContinuousClock.now < deadline else { return nil }
			try? await Task.sleep(for: .milliseconds(200))
		}
	}

	/// Everything on this device that belonged to the old radio: its chats, invites
	/// that arrived on it, a name change still waiting to be saved to it, and profile
	/// packets and photo downloads still going through it.
	static func clearRadioData() async {
		ProfileSync.reset()
		await MeshPackets.shared.clearCoreDataDatabase(includeRoutes: false)
		clearNotifications()
		// Every message is gone, so nothing is unread: the tab and app icon badges go too.
		if let appState = AccessoryManager.shared.appState {
			appState.unreadDirectMessages = 0
			appState.unreadChannelMessages = 0
		}
		ProfileStore.shared.resetSentCards()
		GroupInviteStore.shared.removeAll()
		// After the wait: a name saved meanwhile, or the push an edit held for want of a radio, was for the old one.
		ProfileSync.pendingRadioName = nil
		ProfileSync.forgetHeldPush()
	}
}
