//
//  RadioReadinessTests.swift
//  MeshtasticTests
//

import Foundation
import CoreData
import Testing
import MeshtasticProtobufs
@testable import Meshtastic

/// Stands in for a live radio link; nothing is sent anywhere.
private actor ReadinessLink: Connection {
	let type: TransportType = .ble
	var isConnected: Bool { true }
	func send(_ data: ToRadio) async throws {}
	func connect() async throws -> AsyncStream<ConnectionEvent> { AsyncStream { $0.finish() } }
	func disconnect(withError: Error?, shouldReconnect: Bool) async throws {}
	func drainPendingPackets() async throws {}
	func startDrainPendingPackets() throws {}
	func appDidEnterBackground() {}
	func appDidBecomeActive() {}
}

/// One readiness value, worked out from every input, in one place. Nothing here touches the
/// app's own database: each test has an in-memory one.
@Suite("Radio readiness", .serialized)
@MainActor
struct RadioReadinessTests {

	private let start = ContinuousClock.now

	private static let states: [AccessoryManagerState] = [
		.uninitialized, .idle, .discovering, .connecting, .retrying(attempt: 1, maxAttempts: 3),
		.retrievingDatabase(nodeCount: 5), .communicating, .subscribed
	]

	private func isReady(_ edge: RadioReadiness.Edge?) -> Bool {
		if case .becameReady? = edge { return true }
		return false
	}

	/// Polls until `done`, for at most `seconds`.
	private func wait(upTo seconds: Double, until done: () -> Bool) async throws {
		let deadline = ContinuousClock.now + .seconds(seconds)
		while !done(), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	/// My node, with its user, saved from a background context the way a NodeInfo packet is.
	private func saveMyNode(_ num: Int64, in container: NSPersistentContainer) async throws {
		let background = container.newBackgroundContext()
		try await background.perform {
			let node = NodeInfoEntity(context: background)
			node.num = num
			let user = UserEntity(context: background)
			user.num = num
			user.userId = "!\(String(num, radix: 16))"
			user.longName = "Readiness \(num)"
			user.shortName = "RD"
			user.hwModel = "UNSET"
			node.user = user
			try background.save()
		}
	}

	// MARK: T1, the reducer

	@Test func onlyAChangeIsAnEdge() {
		var readiness = RadioReadiness(now: start)
		#expect(!readiness.ready)
		#expect(readiness.awaySince == start)
		// Linked and subscribed, my node not known yet: not ready, nothing to say.
		#expect(readiness.update(ready: ProfileRules.radioReady(hasConnection: true, state: .subscribed, hasMyUser: false), now: start + .seconds(1)) == nil)
		// My node becomes known, with no change of state.
		let back = readiness.update(ready: ProfileRules.radioReady(hasConnection: true, state: .subscribed, hasMyUser: true), now: start + .seconds(5))
		#expect(back == .becameReady(awayFor: .seconds(5)))
		#expect(readiness.ready)
		#expect(readiness.awaySince == nil)
		#expect(readiness.update(ready: true, now: start + .seconds(6)) == nil)
		// Its row is deleted.
		let gone = start + .seconds(9)
		#expect(readiness.update(ready: ProfileRules.radioReady(hasConnection: true, state: .subscribed, hasMyUser: false), now: gone) == .wentAway)
		#expect(readiness.awaySince == gone)
		#expect(readiness.update(ready: false, now: gone + .seconds(1)) == nil)
		#expect(readiness.awaySince == gone)
		#expect(readiness.update(ready: true, now: gone + .seconds(3)) == .becameReady(awayFor: .seconds(3)))
	}

	/// The tracker's value is the radio predicate of its inputs, for every input.
	@Test func readyIsExactlyThePredicate() async throws {
		let persistence = PersistenceController(inMemory: true)
		try await saveMyNode(31, in: persistence.container)
		let tracker = RadioReadinessTracker(context: persistence.container.viewContext)
		for state in Self.states {
			for hasConnection in [false, true] {
				for known in [false, true] {
					tracker.refresh(hasConnection: hasConnection, state: state, deviceNum: known ? 31 : 32)
					let expected = ProfileRules.radioReady(hasConnection: hasConnection, state: state, hasMyUser: known)
					#expect(tracker.value.ready == expected, "\(state) \(hasConnection) \(known)")
					#expect(tracker.isReady(hasConnection: hasConnection, state: state, deviceNum: known ? 31 : 32) == expected)
					#expect((tracker.value.awaySince == nil) == expected)
				}
			}
		}
	}

	// MARK: T2, the funnel against a real database

	/// Linked and subscribed with my node unknown; then my node is saved from a background
	/// context, with nothing else changing: ready, once. Then the app's data is cleared by a
	/// batch delete in a background context: away, once.
	@Test func myNodeComingAndGoingIsSeenWithoutAnyOtherChange() async throws {
		let persistence = PersistenceController(inMemory: true)
		let tracker = RadioReadinessTracker(context: persistence.container.viewContext)
		var edges: [RadioReadiness.Edge] = []
		tracker.onEdge = { edges.append($0) }
		tracker.refresh(hasConnection: true, state: .subscribed, deviceNum: 4242)
		#expect(!tracker.value.ready)
		#expect(edges.isEmpty)

		try await saveMyNode(4242, in: persistence.container)
		try await wait(upTo: 1) { tracker.value.ready }
		#expect(tracker.value.ready)
		#expect(edges.count == 1 && isReady(edges.first))

		let background = persistence.container.newBackgroundContext()
		await background.perform {
			for entity in ["UserEntity", "NodeInfoEntity"] {
				try? background.executeAndMergeChanges(using: NSBatchDeleteRequest(fetchRequest: NSFetchRequest(entityName: entity)))
			}
		}
		try await wait(upTo: 1) { !tracker.value.ready }
		#expect(!tracker.value.ready)
		#expect(edges.count == 2 && edges.last == .wentAway)
		#expect(tracker.value.awaySince != nil)
	}

	/// My node saved, then deleted, in the view context itself (removing a node does this):
	/// no merge happens, only the view context's own change notification.
	@Test func myNodeChangedInTheViewContextIsSeen() async throws {
		let persistence = PersistenceController(inMemory: true)
		let view = persistence.container.viewContext
		let tracker = RadioReadinessTracker(context: view)
		var edges: [RadioReadiness.Edge] = []
		tracker.onEdge = { edges.append($0) }
		tracker.refresh(hasConnection: true, state: .subscribed, deviceNum: 6161)
		let node = NodeInfoEntity(context: view)
		node.num = 6161
		let user = UserEntity(context: view)
		user.num = 6161
		user.userId = "!00001811"
		user.longName = "Readiness 6161"
		user.shortName = "RD"
		user.hwModel = "UNSET"
		node.user = user
		try view.save()
		try await wait(upTo: 1) { tracker.value.ready }
		#expect(tracker.value.ready)
		#expect(edges.count == 1 && isReady(edges.first))
		view.delete(user)
		view.delete(node)
		try view.save()
		try await wait(upTo: 1) { !tracker.value.ready }
		#expect(!tracker.value.ready)
		#expect(edges.count == 2 && edges.last == .wentAway)
	}

	/// A change to some other node, or to nothing it depends on, isn't an edge.
	@Test func otherNodesChangeNothing() async throws {
		let persistence = PersistenceController(inMemory: true)
		let tracker = RadioReadinessTracker(context: persistence.container.viewContext)
		var edges: [RadioReadiness.Edge] = []
		tracker.onEdge = { edges.append($0) }
		tracker.refresh(hasConnection: true, state: .subscribed, deviceNum: 4242)
		try await saveMyNode(5151, in: persistence.container)
		try await Task.sleep(for: .milliseconds(200))
		#expect(!tracker.value.ready)
		#expect(edges.isEmpty)
	}

	/// Each of AccessoryManager's own inputs (the link, the state, my node number) brings it
	/// up to date at once, with the new value already set.
	@Test func everyInputOfAccessoryManagerRefreshesIt() async throws {
		let persistence = PersistenceController(inMemory: true)
		try await saveMyNode(777, in: persistence.container)
		let manager = AccessoryManager(transports: [], readiness: RadioReadinessTracker(context: persistence.container.viewContext))
		// The init takes over the shared MQTT delegate; hand it back to the app's manager.
		MqttClientProxyManager.shared.delegate = AccessoryManager.shared
		// With each edge: what the inputs say, and what the published value says.
		var seen: [(edge: RadioReadiness.Edge, live: Bool, published: Bool)] = []
		manager.readiness.onEdge = { [weak manager] edge in
			seen.append((edge, manager?.radioReadyNow ?? false, manager?.readiness.value.ready ?? false))
		}
		let device = Device(id: UUID(), name: "Readiness", transportType: .ble, identifier: "READINESS", num: 777)

		manager.activeConnection = (device: device, connection: ReadinessLink())
		manager.updateState(.subscribed)
		#expect(!manager.readiness.value.ready)
		manager.activeDeviceNum = 777
		#expect(manager.readiness.value.ready)
		manager.updateState(.retrievingDatabase(nodeCount: 3))
		#expect(!manager.readiness.value.ready)
		manager.updateState(.subscribed)
		#expect(manager.readiness.value.ready)
		manager.activeConnection = nil
		#expect(!manager.readiness.value.ready)
		manager.activeConnection = (device: device, connection: ReadinessLink())
		#expect(manager.readiness.value.ready)
		manager.activeDeviceNum = nil
		#expect(!manager.readiness.value.ready)
		// Each edge came after its input and the new value were set.
		#expect(seen.map { isReady($0.edge) } == [true, false, true, false, true, false])
		#expect(seen.allSatisfy { isReady($0.edge) == $0.live && isReady($0.edge) == $0.published })
	}
}
