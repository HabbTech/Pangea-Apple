//
//  RadioPairing.swift
//  Pangea
//
//  Reconnect to, or forget, the radio this device is paired with.
//

import Foundation
import OSLog
import SwiftUI

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
		let forgottenNum = accessoryManager.activeDeviceNum ?? Int64(UserDefaults.preferredPeripheralNum)
		// A renumbered radio's backup is filed under its old number, but under the same device id.
		let forgottenDevice = forgottenNum == 0 ? nil
			: BackupKey.forDevice(getNodeInfo(id: forgottenNum, context: accessoryManager.context)?.myInfo?.deviceId)
		guard await disconnect(accessoryManager: accessoryManager, timeout: timeout) else {
			Logger.transport.error("📻 [Pangea] Couldn't disconnect; nothing forgotten")
			return false
		}
		UserDefaults.preferredPeripheralId = ""
		UserDefaults.preferredPeripheralNum = 0
		await clearRadioData()
		// A copy of its chats kept by an earlier radio switch would bring them back if this
		// radio were connected again.
		if forgottenNum != 0 {
			for entry in NodeBackupManager.shared.listBackups()
			where entry.nodeNum == forgottenNum || (forgottenDevice != nil && entry.deviceId == forgottenDevice) {
				_ = NodeBackupManager.shared.deleteBackup(forKey: entry.key)
			}
		}
		accessoryManager.startDiscovery()
		Logger.transport.info("📻 [Pangea] Forgot paired radio")
		return true
	}

	/// Disconnects; `disconnect()` waits for the teardown to finish.
	/// - Returns: false if it still hadn't finished after `timeout`. A link that never answers
	///   the close doesn't hold the caller past it: the request carries on without being waited for.
	@discardableResult
	static func disconnect(accessoryManager: AccessoryManager, timeout: Duration = .seconds(5)) async -> Bool {
		guard !accessoryManager.isFullyDisconnected else { return true }
		let request = Task { @MainActor in try? await accessoryManager.disconnect(timeout: timeout) }
		let deadline = ContinuousClock.now + timeout
		while !accessoryManager.isFullyDisconnected && ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(20))
		}
		if accessoryManager.isFullyDisconnected {
			await request.value
		}
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
	///
	/// The store is cleared in place, on the one container, the way upstream's node switch
	/// does it (`backupCurrentAndRestoreDatabase`), and not by replacing the container: every
	/// replacement leaves SwiftUI's observer of the old one alive, and the next save traps in
	/// it. That is most likely right here, where pairing a different radio connects straight
	/// after and the node download saves over and over. Every store-bound view is unmounted
	/// for the clear (`isDatabaseResetting`); the pairing sheet sits above that gate.
	///
	/// Clears don't overlap: one that starts while another is still running waits for it, and
	/// the gate stays up until the last of them has finished, so a second Switch Radio can't
	/// remount the lists in the middle of the first one's clear.
	///
	/// The profile and Contacts stay: they're this device's, not the radio's.
	/// - Parameters:
	///   - profiles: replaced only by tests.
	///   - clearStore: the clear itself; replaced only by tests.
	static func clearRadioData(
		profiles: ProfileStore = .shared,
		clearStore: @MainActor () async -> Bool = { await MeshPackets.shared.clearDatabase(includeRoutes: false) }
	) async {
		clearsInFlight += 1
		// One at a time, from the start: a later clear finds the gate already up, and the
		// lists already unmounted, when its turn comes.
		if isClearing {
			await withCheckedContinuation { clearWaiters.append($0) }
		}
		isClearing = true
		ProfileSync.reset()
		let appState = AccessoryManager.shared.appState
		if let appState, !appState.isDatabaseResetting {
			// Same sequence as the node switch: drop the detail screens and let them go,
			// then unmount without animation, then let that commit before touching the store.
			appState.sceneRouters.popAllStacks()
			try? await Task.sleep(for: .milliseconds(350))
			var gate = Transaction()
			gate.disablesAnimations = true
			withTransaction(gate) { appState.isDatabaseResetting = true }
			await Task.yield()
			try? await Task.sleep(for: .milliseconds(300))
		}
		await MeshPackets.shared.flushDebouncedSaves()
		if !(await clearStore()) {
			// A half-cleared store would keep chats the user was told are gone. Same escalation
			// as the node switch: a guaranteed-empty store. That replaces the container once;
			// rebinding (not repointing) keeps it to once.
			Logger.data.error("📻 [Pangea] Clearing the radio's data failed; destroying the store instead")
			PersistenceController.shared.destroyStoreAndRecreateContainer()
			AccessoryManager.shared.rebindToCurrentContainer()
		}
		// Hand the store to the next clear waiting, if any; it keeps isClearing set.
		if clearWaiters.isEmpty {
			isClearing = false
		} else {
			clearWaiters.removeFirst().resume()
		}
		clearsInFlight -= 1
		if let appState {
			// The clear went through another context; remounting makes every list fetch again.
			appState.databaseResetID = UUID()
			if clearsInFlight == 0 {
				var drop = Transaction()
				drop.disablesAnimations = true
				withTransaction(drop) { appState.isDatabaseResetting = false }
			}
		}
		clearNotifications()
		clearRadioState(profiles: profiles)
	}

	/// Clears started and not yet finished, the waiting ones included (see `clearRadioData`).
	private static var clearsInFlight = 0
	/// A clear is running; the next one waits in `clearWaiters`.
	private static var isClearing = false
	private static var clearWaiters: [CheckedContinuation<Void, Never>] = []

	/// Settings → App Settings → Clear App Data: everything the app has stored, for every radio,
	/// so Pangea starts over as on a fresh install, with setup and pairing. Unlike Forget and
	/// Pair a Different Radio, that takes my profile and everyone in Contacts too, every node
	/// backup, the old Core Data chats an upgrade kept, radio private keys saved on this device
	/// only (iCloud-synced ones stay, as across a reinstall) and saved manual connections. Downloaded maps and firmware stay: they're downloads, not data.
	///
	/// The store goes the same way as the radio's chats in `clearRadioData`, in place on the one
	/// container, with every store-bound view unmounted meanwhile. Upstream replaced the
	/// container here (`resetDatabaseAfterClear`) under the mounted Settings screen and saved
	/// into the new one at once (the device catalogue refresh), which is the stale-observer trap
	/// `clearRadioData` describes. The caller refreshes the device catalogue afterwards.
	/// - Parameters:
	///   - disconnect: lets go of the radio first; if it throws, nothing is erased.
	///   - clearStore: the clear itself; replaced only by tests.
	///   - profiles, invites, chatIcons (nil: `ChatIconStore.shared`), defaults, backups (nil: `NodeBackupManager.shared`), oldBackupFolders,
	///     oldStoreFolders, keychainService: where Pangea keeps the rest; replaced only by tests.
	/// - Returns: false, with nothing erased, when `disconnect` threw.
	@discardableResult
	static func eraseAppData(
		disconnect: @MainActor () async throws -> Void,
		profiles: ProfileStore = .shared,
		invites: GroupInviteStore = .shared,
		chatIcons: ChatIconStore? = nil,
		defaults: UserDefaults = .standard,
		backups: NodeBackupManager? = nil,
		oldBackupFolders: [URL] = NodeBackupManager.backupFolders,
		oldStoreFolders: [URL] = CoreDataMigrationService.defaultSearchDirectories,
		keychainService: String = Bundle.main.bundleIdentifier!,
		clearStore: @MainActor () async -> Bool = { await MeshPackets.shared.clearDatabase(includeRoutes: true) }
	) async -> Bool {
		do {
			try await disconnect()
		} catch {
			Logger.transport.error("📻 [Pangea] Couldn't disconnect; nothing erased: \(error.localizedDescription, privacy: .public)")
			return false
		}
		// At once, as Forget does: auto-connect looks for this radio, and a connect that got in
		// during the clear would fill the store again and save the radio back.
		defaults.removeObject(forKey: UserDefaults.Keys.preferredPeripheralId.rawValue)
		defaults.removeObject(forKey: UserDefaults.Keys.preferredPeripheralNum.rawValue)
		erasesInFlight += 1
		AccessoryManager.shared.appState?.isErasingAppData = true
		defer {
			erasesInFlight -= 1
			if erasesInFlight == 0 {
				AccessoryManager.shared.appState?.isErasingAppData = false
			}
		}
		await TranslationCache.shared.clearAll()
		await DocTranslationService.shared.clearUIStringCache()
		(backups ?? .shared).eraseAll(otherFolders: oldBackupFolders)
		// The next launch would import a kept Core Data store again. Settings, and so this,
		// can't be reached while an import runs.
		CoreDataMigrationService.removeLegacyStores(in: oldStoreFolders)
		// Only keys kept on this device: one synced through iCloud Keychain would go from the
		// user's other devices too, and survives a reinstall anyway.
		if !KeychainHelper.standard.deleteAllLocal(withPrefix: KeychainHelper.privateKeyPrefix, service: keychainService) {
			Logger.services.error("📻 [Pangea] Couldn't remove every saved private key")
		}
		await clearRadioData(profiles: profiles, clearStore: {
			let cleared = await clearStore()
			// While the lists are still unmounted, so nothing shows a contact on its way out.
			eraseLocalData(profiles: profiles, invites: invites, chatIcons: chatIcons ?? .shared, defaults: defaults)
			return cleared
		})
		return true
	}

	/// Clear App Data runs that haven't finished; the placeholder says "Erasing" until the last.
	private static var erasesInFlight = 0

	/// What Pangea keeps outside the database, for Clear App Data. `clearRadioState` takes the
	/// rest (notifications, the Messages snapshot, a pending name, a held push) on every clear.
	static func eraseLocalData(profiles: ProfileStore, invites: GroupInviteStore, chatIcons: ChatIconStore, defaults: UserDefaults) {
		profiles.eraseAll()
		invites.removeAll()
		for key in localDefaultsKeys {
			defaults.removeObject(forKey: key)
		}
		ManualConnectionList.shared.forgetAll()
		chatIcons.forgetAll()
	}

	/// What Clear App Data puts back as on a fresh install: no radio paired, so nothing
	/// reconnects; setup shown again; the Everyone Nearby bell; the pairing-code tries per radio;
	/// the name and push waiting for the radio; the saved manual connections; and the chat icons. App settings
	/// stay (Reset App Settings is separate), as do the iOS Bluetooth bonds
	/// (`pairedPeripheralIds`) that iOS itself keeps.
	static let localDefaultsKeys: [String] = [
		UserDefaults.Keys.preferredPeripheralId.rawValue,
		UserDefaults.Keys.preferredPeripheralNum.rawValue,
		UserDefaults.Keys.firstLaunch.rawValue,
		UserDefaults.Keys.manualConnections.rawValue,
		GroupChats.everyoneNotificationsKey,
		RadioAutoConfig.pairingCodeAttemptsKey,
		ProfileSync.pendingNameKey,
		ProfileSync.pushWhenBackKey,
		ChatIconStore.defaultsKey
	]

	/// The part of `clearRadioData` that isn't the database: also run when switching to another
	/// radio, which swaps the database itself (see `switchToDevice`).
	static func clearRadioState(profiles: ProfileStore = .shared) {
		ProfileSync.reset()
		// Every message is gone, so nothing is unread: the tab and app icon badges go too.
		if let appState = AccessoryManager.shared.appState {
			appState.unreadDirectMessages = 0
			appState.unreadChannelMessages = 0
		}
		profiles.resetSentCards()
		GroupInviteStore.shared.removeAll()
		// The Messages extension's copy of the radio's channels, keys included, lives in the
		// shared keychain, not the database. The next radio writes its own once connected.
		do {
			try MeshShareStore.delete()
		} catch {
			Logger.services.error("📻 [Pangea] Couldn't remove the Messages sharing snapshot: \(error.localizedDescription, privacy: .public)")
		}
		// After the wait: a name saved meanwhile, or the push an edit held for want of a radio, was for the old one.
		ProfileSync.pendingRadioName = nil
		ProfileSync.forgetHeldPush()
	}
}
