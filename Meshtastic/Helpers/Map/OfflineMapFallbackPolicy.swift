//
//  OfflineMapFallbackPolicy.swift
//  Meshtastic
//
//  Determines when saved offline maps should render without changing the user's preference.
//

import Foundation
import Network

enum OfflineMapFallbackPolicy {
	static func shouldRenderOfflineMaps(
		userEnabled: Bool,
		hasSavedMaps: Bool,
		networkAvailable: Bool
	) -> Bool {
		userEnabled || (hasSavedMaps && !networkAvailable)
	}

	/// Whether the Offline Tiles setting applies on this style. The setting lives in Expert Mode's
	/// Map Options. In standard mode it applies only on the Standard style (a legacy `.offline`
	/// value draws as Standard too), so Hybrid and Satellite show plain imagery.
	static func userWantsOfflineTiles(enabled: Bool, expertMode: Bool, layer: MapLayer) -> Bool {
		enabled && (expertMode || layer == .standard || layer == .offline)
	}
}
@MainActor
final class OfflineMapConnectivityMonitor: ObservableObject {
	static let shared = OfflineMapConnectivityMonitor()

	@Published private(set) var isNetworkAvailable = true

	private let monitor = NWPathMonitor()
	private let queue = DispatchQueue(label: "org.meshtastic.offline-map-connectivity")

	private init() {
		monitor.pathUpdateHandler = { [weak self] path in
			Task { @MainActor in
				self?.isNetworkAvailable = path.status == .satisfied
			}
		}
		monitor.start(queue: queue)
	}

	deinit {
		monitor.cancel()
	}
}
