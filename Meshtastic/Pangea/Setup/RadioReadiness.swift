//
//  RadioReadiness.swift
//  Pangea
//
//  Whether the radio can take a packet, worked out in one place from everything it
//  depends on: the link, the connection state, my node number, and my own node in the
//  database. Everything that waits for the radio, and every "Connect your radio" line,
//  goes by this one value.
//

import Foundation
import SwiftData
import Combine

/// Whether the radio can take a packet (`ProfileRules.radioReady`), and since when it hasn't.
struct RadioReadiness: Equatable {
	typealias Instant = ContinuousClock.Instant

	enum Edge: Equatable {
		/// Ready again, after this long without it.
		case becameReady(awayFor: Duration?)
		case wentAway
	}

	private(set) var ready: Bool
	/// Since when it hasn't been ready; nil while it is. Not ready at launch, so from then.
	private(set) var awaySince: Instant?

	init(now: Instant = .now) {
		ready = false
		awaySince = now
	}

	init(ready: Bool, awaySince: Instant?) {
		self.ready = ready
		self.awaySince = ready ? nil : awaySince
	}

	/// Takes what the radio's inputs now say; the edge, if that's a change.
	mutating func update(ready: Bool, now: Instant) -> Edge? {
		guard ready != self.ready else { return nil }
		self.ready = ready
		if ready {
			let away = awaySince.map { now - $0 }
			awaySince = nil
			return .becameReady(awayFor: away)
		}
		awaySince = now
		return .wentAway
	}
}

/// Keeps a `RadioReadiness` up to date. AccessoryManager reports the link, the state and my
/// node number whenever one changes (`AccessoryManager.refreshRadioReady`); my own node coming
/// into the database or leaving it is watched here. A small object of its own, so views that
/// show it aren't rebuilt by everything else AccessoryManager publishes.
@MainActor
final class RadioReadinessTracker: ObservableObject {
	@Published private(set) var value = RadioReadiness()
	/// Each change of `value`, once it's set.
	var onEdge: ((RadioReadiness.Edge) -> Void)?

	/// Read on every look rather than kept, because the app's container is replaced after a data
	/// clear (see `PersistenceController.recreateContainer`).
	private let contextProvider: @MainActor () -> ModelContext
	private var context: ModelContext { contextProvider() }
	private var hasConnection = false
	private var state: AccessoryManagerState = .uninitialized
	private var deviceNum: Int64?
	private var refreshQueued = false
	/// Only set in `init`, only read in `deinit`.
	nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

	/// `context` is for tests; the app reads the shared container's main context.
	init(context: ModelContext? = nil) {
		if let context {
			contextProvider = { context }
		} else {
			contextProvider = { PersistenceController.shared.context }
		}
		// A save in any context (the packet actor's, the main one, or a clear of the app's data)
		// may bring my own node in or take it away.
		observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] note in
			guard Self.touchesNodes(note) else { return }
			Task { @MainActor in self?.refreshSoon() }
		})
	}

	deinit {
		for observer in observers {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	/// Whether the radio can take a packet with these inputs, my own node looked up now.
	func isReady(hasConnection: Bool, state: AccessoryManagerState, deviceNum: Int64?) -> Bool {
		// Looked up only once the rest says ready, so a change to the link costs nothing.
		let linked = hasConnection && state == .subscribed
		// A fresh context each time: the main one can keep a node another context has deleted.
		let hasMyUser = linked && deviceNum.map { getNodeInfo(id: $0, context: ModelContext(context.container))?.user != nil } == true
		return ProfileRules.radioReady(hasConnection: hasConnection, state: state, hasMyUser: hasMyUser)
	}

	/// New inputs from AccessoryManager. The edge, if readiness changed.
	@discardableResult
	func refresh(hasConnection: Bool, state: AccessoryManagerState, deviceNum: Int64?, now: ContinuousClock.Instant = .now) -> RadioReadiness.Edge? {
		self.hasConnection = hasConnection
		self.state = state
		self.deviceNum = deviceNum
		return refresh(now: now)
	}

	/// The same inputs, my own node looked up again.
	@discardableResult
	func refresh(now: ContinuousClock.Instant = .now) -> RadioReadiness.Edge? {
		var next = value
		guard let edge = next.update(ready: isReady(hasConnection: hasConnection, state: state, deviceNum: deviceNum), now: now) else { return nil }
		value = next
		onEdge?(edge)
		return edge
	}

	/// A database download changes hundreds of nodes: one look for all of them.
	private func refreshSoon() {
		guard !refreshQueued else { return }
		refreshQueued = true
		Task { @MainActor in
			refreshQueued = false
			refresh()
		}
	}

	/// Whether a save could mean my own node, or its user, came or went. A save that doesn't
	/// say what it changed counts.
	nonisolated private static func touchesNodes(_ note: Foundation.Notification) -> Bool {
		guard let info = note.userInfo else { return true }
		let keys = [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
		var sawAny = false
		for key in keys {
			guard let ids = info[key.rawValue] as? [PersistentIdentifier] else { continue }
			sawAny = true
			if ids.contains(where: { ["NodeInfoEntity", "UserEntity"].contains($0.entityName) }) {
				return true
			}
		}
		return !sawAny
	}
}

extension AccessoryError {
	/// Pangea: whether a send that threw certainly never reached the radio. `connectionFailed`
	/// (no link) and `ioFailed` (nothing to write to, or the packet couldn't be built) are only
	/// thrown before anything is written. Anything else, such as `disconnected` while a write
	/// waited for its reply, may have been delivered.
	nonisolated static func neverSent(_ error: Error) -> Bool {
		switch error as? AccessoryError {
		case .connectionFailed, .ioFailed: true
		default: false
		}
	}
}
