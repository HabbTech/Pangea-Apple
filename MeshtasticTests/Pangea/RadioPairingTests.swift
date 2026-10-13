//
//  RadioPairingTests.swift
//  MeshtasticTests
//

import Foundation
import Testing
import MeshtasticProtobufs
@testable import Meshtastic

/// Stands in for a live radio link; nothing is sent anywhere.
private actor StubConnection: Connection {
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

@Suite("Scanning for radios", .serialized)
@MainActor
struct DiscoveryStateTests {

	private let device = Device(id: UUID(), name: "Test Radio", transportType: .ble, identifier: "BLE-TEST")

	/// No transports, so starting discovery never touches Bluetooth or the network.
	private func manager() -> AccessoryManager {
		let manager = AccessoryManager(transports: [])
		// The init takes over the shared MQTT delegate; hand it back to the app's manager.
		MqttClientProxyManager.shared.delegate = AccessoryManager.shared
		return manager
	}

	@Test func scanningWhileConnectedKeepsTheRadioConnected() {
		let manager = manager()
		manager.activeConnection = (device: device, connection: StubConnection())
		manager.updateState(.subscribed)

		// What "Pair a Different Radio" and finishing setup both do.
		manager.startDiscovery()

		#expect(manager.state == .subscribed)
		#expect(manager.isConnected)
		#expect(manager.discoveryTask != nil)
		manager.stopDiscovery()
	}

	@Test func scanningWhileConnectingLeavesTheConnectionAlone() {
		let manager = manager()
		manager.updateState(.connecting)
		manager.startDiscovery()
		#expect(manager.state == .connecting)
		#expect(manager.isConnecting)
		manager.stopDiscovery()
	}

	@Test func scanningWithNoRadioShowsSearching() {
		let manager = manager()
		manager.updateState(.idle)
		manager.startDiscovery()
		#expect(manager.state == .discovering)
		#expect(!manager.isConnected)
		manager.stopDiscovery()
	}
}

/// A transport that counts connects and hands out links that never finish the config
/// handshake, so an attempt stays in flight until it's cancelled.
private final class FakeTransport: Transport, @unchecked Sendable {
	let type: TransportType = .ble
	var status: TransportStatus { .ready }
	let latency: Duration
	private let lock = NSLock()
	private var connectCount = 0
	private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
	var connects: Int { lock.withLock { connectCount } }

	init(latency: Duration) { self.latency = latency }

	func discoverDevices() async -> AsyncStream<DiscoveryEvent> {
		AsyncStream { continuation in self.lock.withLock { self.continuation = continuation } }
	}

	func yield(_ event: DiscoveryEvent) { lock.withLock { continuation }?.yield(event) }

	func connect(to device: Device) async throws -> any Connection {
		lock.withLock { connectCount += 1 }
		try? await Task.sleep(for: latency)
		return FakeConnection()
	}

	var requiresPeriodicHeartbeat: Bool { false }
	var supportsManualConnection: Bool { false }
	func device(forManualConnection: String) -> Device? { nil }
	func manuallyConnect(toDevice: Device) async throws {}
}

/// A link that closes when asked, the way a real one reports it.
private actor FakeConnection: Connection {
	let type: TransportType = .ble
	var isConnected: Bool { true }
	private var continuation: AsyncStream<ConnectionEvent>.Continuation?
	func send(_ data: ToRadio) async throws {}
	func connect() async throws -> AsyncStream<ConnectionEvent> {
		AsyncStream { continuation in self.continuation = continuation }
	}
	func disconnect(withError error: Error?, shouldReconnect: Bool) async throws {
		continuation?.yield(.disconnected(shouldReconnect: shouldReconnect))
		continuation?.finish()
		continuation = nil
	}
	func drainPendingPackets() async throws {}
	func startDrainPendingPackets() throws {}
	func appDidEnterBackground() {}
	func appDidBecomeActive() {}
}

@Suite("Connecting and disconnecting", .serialized)
@MainActor
struct ConnectionRaceTests {

	private let device = Device(id: UUID(), name: "Test Radio", transportType: .ble, identifier: "BLE-TEST")

	private func manager(_ transport: FakeTransport? = nil) -> AccessoryManager {
		let manager = AccessoryManager(transports: transport.map { [$0] } ?? [])
		MqttClientProxyManager.shared.delegate = AccessoryManager.shared
		return manager
	}

	/// Pairing settings are put back afterwards, and nothing stale is purged from the store.
	private func withDefaults(_ body: () async -> Void) async {
		let savedId = UserDefaults.preferredPeripheralId
		let savedNum = UserDefaults.preferredPeripheralNum
		let savedPurge = UserDefaults.purgeStaleNodeDays
		UserDefaults.purgeStaleNodeDays = 0
		await body()
		UserDefaults.preferredPeripheralId = savedId
		UserDefaults.preferredPeripheralNum = savedNum
		UserDefaults.purgeStaleNodeDays = savedPurge
	}

	private func teardown(_ manager: AccessoryManager) async {
		try? await manager.disconnect()
		for _ in 0..<60 where manager.connectionStepper != nil || manager.activeConnection != nil || manager.closingConnections > 0 {
			try? await Task.sleep(for: .milliseconds(50))
		}
		manager.stopDiscovery()
	}

	/// The radio was lost and auto-connect is armed; the user taps Reconnect, then the radio
	/// turns up. Whoever gets there first, there's one attempt, and Reconnect reports it.
	@Test(arguments: [50, 300, 1500])
	func reconnectAndAutoConnectMakeOneAttempt(latencyMs: Int) async {
		await withDefaults {
			UserDefaults.preferredPeripheralId = device.id.uuidString
			let transport = FakeTransport(latency: .milliseconds(latencyMs))
			let manager = manager(transport)
			manager.startDiscovery()
			let reconnect = Task { await RadioPairing.reconnect(accessoryManager: manager, timeout: .seconds(4), attemptTimeout: .seconds(8)) }
			try? await Task.sleep(for: .milliseconds(120))
			transport.yield(.deviceFound(device))
			// What discovery does when it hears the preferred radio (the test host doesn't
			// arm it on its own), while Reconnect's own search is about to find it too.
			manager.connectToPreferredDevice(device: device)
			for _ in 0..<100 where manager.activeConnection == nil {
				try? await Task.sleep(for: .milliseconds(50))
			}
			// Room for a second attempt to show up, if anything let one in.
			try? await Task.sleep(for: .milliseconds(800))
			#expect(transport.connects == 1)
			#expect(manager.activeConnection != nil)
			// The radio finishes sending its config.
			manager.updateState(.subscribed)
			#expect(await reconnect.value)
			await teardown(manager)
		}
	}

	@Test func aSecondConnectWhileOneIsStartingIsRefused() async {
		await withDefaults {
			let transport = FakeTransport(latency: .milliseconds(300))
			let manager = manager(transport)
			let first = Task { try? await manager.connect(to: device) }
			try? await Task.sleep(for: .milliseconds(50))
			// Still in its first step: not connected yet, but no longer free either.
			#expect(manager.activeConnection == nil)
			await #expect(throws: (any Error).self) { try await manager.connect(to: device) }
			try? await Task.sleep(for: .milliseconds(500))
			#expect(transport.connects == 1)
			await teardown(manager)
			_ = await first.value
			#expect(manager.connectionStepper == nil)
		}
	}

	@Test func disconnectWaitsUntilTheTeardownIsDone() async {
		await withDefaults {
			let manager = manager(FakeTransport(latency: .milliseconds(10)))
			let link = FakeConnection()
			let events = (try? await link.connect()) ?? AsyncStream(unfolding: { nil })
			manager.activeConnection = (device: device, connection: link)
			manager.connectionEventTask = Task {
				for await event in events { await manager.didReceive(event) }
			}
			manager.updateState(.subscribed)
			#expect(await RadioPairing.disconnect(accessoryManager: manager))
			#expect(manager.activeConnection == nil)
			#expect(manager.closingConnections == 0)
			#expect(!manager.isConnecting)
			await teardown(manager)
		}
	}

	/// Upstream's "Connect to new radio" calls `disconnect()` and connects straight away,
	/// while the old attempt is still being cancelled.
	@Test func disconnectReturnsOnlyOnceAnAttemptHasEnded() async {
		await withDefaults {
			let transport = FakeTransport(latency: .milliseconds(10))
			let manager = manager(transport)
			let first = Task { try? await manager.connect(to: device) }
			// Linked, and waiting for a config that never comes.
			for _ in 0..<100 where manager.activeConnection == nil {
				try? await Task.sleep(for: .milliseconds(20))
			}
			#expect(manager.activeConnection != nil)
			#expect(manager.connectionStepper != nil)
			try? await manager.disconnect()
			#expect(manager.connectionStepper == nil)
			#expect(manager.activeConnection == nil)
			#expect(manager.closingConnections == 0)
			_ = await first.value
			// So connecting at once is let in, not refused as "Already connecting".
			let second = Task { () -> Error? in
				do {
					try await manager.connect(to: device)
					return nil
				} catch {
					return error
				}
			}
			for _ in 0..<100 where transport.connects < 2 {
				try? await Task.sleep(for: .milliseconds(20))
			}
			#expect(transport.connects == 2)
			await teardown(manager)
			#expect(await second.value.map { "\($0)" }?.contains("Already") != true)
		}
	}

	@Test func aDisconnectThatNeverFinishesIsReported() async {
		await withDefaults {
			UserDefaults.preferredPeripheralId = device.id.uuidString
			let manager = manager()
			// This link ignores the request to close.
			manager.activeConnection = (device: device, connection: StubConnection())
			manager.updateState(.subscribed)
			#expect(!(await RadioPairing.disconnect(accessoryManager: manager, timeout: .milliseconds(300))))
			// Forgetting then changes nothing: still paired, nothing cleared.
			#expect(!(await RadioPairing.forget(accessoryManager: manager, timeout: .milliseconds(300))))
			#expect(UserDefaults.preferredPeripheralId == device.id.uuidString)
			manager.activeConnection = nil
		}
	}

	@Test func waitingForARadioToBeHeardAgain() async {
		let manager = manager()
		#expect(await RadioPairing.waitForDevice(id: device.id, accessoryManager: manager, timeout: .milliseconds(300)) == nil)
		let device = device
		Task {
			try? await Task.sleep(for: .milliseconds(200))
			manager.devices.append(device)
		}
		#expect(await RadioPairing.waitForDevice(id: device.id, accessoryManager: manager, timeout: .seconds(3))?.id == device.id)
	}
}
