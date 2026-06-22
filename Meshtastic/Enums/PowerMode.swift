//
//  PowerMode.swift
//  Pangea
//

import Foundation

enum PowerMode: String, CaseIterable, Codable, Identifiable {
	case standard
	case trail
	case expedition

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .standard:		return String(localized: "Standard")
		case .trail:		return String(localized: "Trail")
		case .expedition:	return String(localized: "Expedition")
		}
	}

	var systemImage: String {
		switch self {
		case .standard:		return "bolt.fill"
		case .trail:		return "figure.hiking"
		case .expedition:	return "mountain.2.fill"
		}
	}

	var summary: String {
		switch self {
		case .standard:
			return String(localized: "All features on. Best when your phone is charged or you're near power.")
		case .trail:
			return String(localized: "Day-trip tuning. Smart position only, slower map refresh, cached weather, lower BLE heartbeat. Lets you stay out longer without noticeable feature loss.")
		case .expedition:
			return String(localized: "Multi-day off-grid tuning. Continuous GPS off, WeatherKit off, Live Activities off, widget refresh paused, background auto-connect off. Trades convenience for battery.")
		}
	}

	/// Allows clamping: an effective mode is the more aggressive of two modes.
	static func mostAggressive(_ a: PowerMode, _ b: PowerMode) -> PowerMode {
		let rank: [PowerMode: Int] = [.standard: 0, .trail: 1, .expedition: 2]
		return (rank[a] ?? 0) >= (rank[b] ?? 0) ? a : b
	}
}
