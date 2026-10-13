//
//  LegacyStoreImport.swift
//  Pangea
//
//  Runs the one-time Core Data import off the main thread, and holds back everything that
//  would read or write the store until it has saved.
//

import Foundation
import OSLog
import SwiftData
import SwiftUI
import UIKit

/// The one-time import of a pre-SwiftData store (`CoreDataMigrationService.migrate`).
///
/// A large store takes tens of seconds to import. Run on the main thread at launch, that
/// blocked the first window for the whole import, and on iOS the watchdog killed the app
/// before it finished; the import is all-or-nothing, so the next launch started it over.
/// It now runs on a background thread while the window shows "Updating your chats…", and
/// the radio connection waits for it (`waitUntilFinished`), so no radio data lands in the
/// store before the old chats have.
@MainActor
final class LegacyStoreImport: ObservableObject {
	static let shared = LegacyStoreImport()

	/// True from `start` until the import has saved, or failed.
	@Published private(set) var isRunning = false
	/// The import failed and its rows couldn't all be taken out again, almost always because
	/// the disk is full. The store then holds part of an import that the next launch empties,
	/// so for the rest of this session nothing may read or write it: anything saved now would
	/// be emptied along with it. Cleared only by reopening the app.
	@Published private(set) var needsFreeSpace = false
	/// Whether the store is still the import's: running, or stopped by `needsFreeSpace`.
	var holdsStore: Bool { isRunning || needsFreeSpace }
	private var task: Task<Void, Never>?
	/// Where background time comes from, once the app exists (`appDidLaunch`).
	private var backgroundTime: BackgroundTime?
	private var grant: BackgroundGrant?

	/// Starts `work` unless an import is already running. `work` runs off the main actor.
	///
	/// Held under a background task assertion, so leaving the app part-way doesn't suspend
	/// the import at once; it ends on every path, and when the time granted runs out. The
	/// launch import starts from the app's init, before there is an application to ask for
	/// that time, so the assertion is taken in `appDidLaunch` then.
	func start(_ work: @escaping @Sendable () async -> Void) {
		guard task == nil else { return }
		isRunning = true
		beginGrantIfRunning()
		task = Task {
			await Task.detached(priority: .userInitiated, operation: work).value
			grant?.end()
			grant = nil
			isRunning = false
			task = nil
		}
	}

	/// The app delegate's `didFinishLaunching`: the application exists now, so an import
	/// already running gets its background time. Only the first call counts.
	func appDidLaunch(_ time: BackgroundTime = .application) {
		guard backgroundTime == nil else { return }
		backgroundTime = time
		beginGrantIfRunning()
	}

	/// At most one assertion per import.
	private func beginGrantIfRunning() {
		guard isRunning, grant == nil, let backgroundTime else { return }
		grant = BackgroundGrant(name: "LegacyImport", time: backgroundTime)
	}

	/// Imports the legacy store, if there is one, into `container`.
	func start(
		into container: ModelContainer,
		searchDirectories: [URL] = CoreDataMigrationService.defaultSearchDirectories
	) {
		start { [weak self] in
			let started = Date()
			do {
				try CoreDataMigrationService.migrate(into: container, searchDirectories: searchDirectories)
				Logger.data.info("⬆️ Legacy import finished in \(Date().timeIntervalSince(started), privacy: .public)s")
			} catch MigrationError.storeNotEmptied {
				Logger.data.fault("⬆️ Legacy import failed and couldn't be taken out again; the store stays closed until Pangea is reopened")
				await self?.stopForFreeSpace()
			} catch {
				// The store was checked empty again and the legacy store is kept, so the
				// import is attempted again on the next launch; the app works meanwhile.
				Logger.data.error("⬆️ CoreDataMigrationService failed: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	private func stopForFreeSpace() {
		needsFreeSpace = true
	}

	#if DEBUG
	/// Test-only: what reopening the app does.
	func resetForTesting() {
		needsFreeSpace = false
	}
	#endif

	/// Returns once no import is running. Check `needsFreeSpace` after it.
	func waitUntilFinished() async {
		while let task {
			await task.value
		}
	}
}

/// Asks the system for background time, and gives it back; tests count the calls instead.
struct BackgroundTime {
	var begin: @MainActor @Sendable (_ name: String, _ expired: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
	var end: @MainActor @Sendable (UIBackgroundTaskIdentifier) -> Void

	static var application: BackgroundTime {
		BackgroundTime(
			begin: { name, expired in
				UIApplication.shared.beginBackgroundTask(withName: name) {
					MainActor.assumeIsolated { expired() }
				}
			},
			end: { UIApplication.shared.endBackgroundTask($0) }
		)
	}
}

/// A `beginBackgroundTask` grant, ended exactly once: by `end()` or when the time runs out.
@MainActor
private final class BackgroundGrant {
	private var id = UIBackgroundTaskIdentifier.invalid
	private let time: BackgroundTime

	init(name: String, time: BackgroundTime) {
		self.time = time
		id = time.begin(name) { [weak self] in
			Logger.data.warning("⬆️ Background time for the legacy import ran out")
			self?.end()
		}
	}

	func end() {
		guard id != .invalid else { return }
		time.end(id)
		id = .invalid
	}
}

/// Shown in place of the app while the old chats are imported, or after an import that
/// ran out of space (`LegacyStoreImport.needsFreeSpace`).
struct LegacyImportPlaceholder: View {
	var needsFreeSpace = false

	var body: some View {
		VStack(spacing: 16) {
			if needsFreeSpace {
				Image(systemName: "externaldrive.badge.exclamationmark")
					.font(.system(size: 44))
					.foregroundStyle(Color(.secondaryLabel))
				Text("Not enough space to update your chats")
					.font(.title3)
					.multilineTextAlignment(.center)
				Text("Free up some space, then close Pangea and open it again.")
					.font(.callout)
					.foregroundStyle(Color(.secondaryLabel))
					.multilineTextAlignment(.center)
			} else {
				ProgressView()
					.controlSize(.large)
				Text("Updating your chats…")
					.font(.title3)
				Text("This happens once, after an update. Keep Pangea open until it's done.")
					.font(.callout)
					.foregroundStyle(Color(.secondaryLabel))
					.multilineTextAlignment(.center)
			}
		}
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
