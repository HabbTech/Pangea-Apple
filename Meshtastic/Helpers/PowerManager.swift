//
//  PowerManager.swift
//  Pangea
//

import Foundation
import Combine

/// Central source of truth for the app's three-tier power profile.
///
/// The user picks a `selectedMode` in App Settings. iOS's own Low Power Mode
/// clamps the effective mode up to `.expedition` while it is active, then
/// drops back to the user's choice when iOS LPM turns off. Feature sites
/// across the app read the boolean accessors below instead of branching on
/// the raw enum.
@MainActor
final class PowerManager: ObservableObject {
	static let shared = PowerManager()

	@Published private(set) var selectedMode: PowerMode
	@Published private(set) var systemLowPowerMode: Bool

	var effectiveMode: PowerMode {
		systemLowPowerMode ? PowerMode.mostAggressive(selectedMode, .expedition) : selectedMode
	}

	// MARK: Feature gates (read these at battery-hungry sites)

	var allowsContinuousLocation: Bool { effectiveMode != .expedition }
	var allowsWeatherKit: Bool { effectiveMode != .expedition }
	var allowsLiveActivities: Bool { effectiveMode == .standard }
	var allowsBackgroundAutoConnect: Bool { effectiveMode != .expedition }
	var allowsWidgetTimelineRefresh: Bool { effectiveMode != .expedition }

	/// Minimum location-update interval (seconds) the app will request,
	/// regardless of the user's `provideLocationInterval` setting.
	var locationIntervalFloor: Int {
		switch effectiveMode {
		case .standard:		return 0
		case .trail:		return 300
		case .expedition:	return Int.max
		}
	}

	private var cancellables: Set<AnyCancellable> = []

	private init() {
		self.selectedMode = UserDefaults.powerMode
		self.systemLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

		NotificationCenter.default
			.publisher(for: .NSProcessInfoPowerStateDidChange)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in
				self?.systemLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
			}
			.store(in: &cancellables)
	}

	/// Persist the user's selection and broadcast the change.
	func setSelectedMode(_ mode: PowerMode) {
		UserDefaults.powerMode = mode
		selectedMode = mode
	}

	/// Re-read the persisted selection (useful when the value is changed
	/// elsewhere, e.g. an @AppStorage-bound picker).
	func reloadFromDefaults() {
		selectedMode = UserDefaults.powerMode
	}
}
