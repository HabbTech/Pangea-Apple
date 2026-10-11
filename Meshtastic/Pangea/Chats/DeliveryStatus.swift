//
//  DeliveryStatus.swift
//  Pangea
//
//  The line under a sent message. Expert Mode keeps the original mesh terms;
//  standard mode says what happened in plain words.
//

import SwiftUI

enum DeliveryStatus {

	static var plainWording: Bool { !UserDefaults.expertModeEnabled }

	static var waiting: String {
		plainWording ? String(localized: "Sending…") : String(localized: "Waiting to be acknowledged. . .")
	}

	/// A DM a relay picked up, but the recipient hasn't confirmed.
	static var relayedOnly: String {
		plainWording ? String(localized: "Sent. They haven't confirmed it yet.") : String(localized: "Acknowledged by another node")
	}

	/// - Parameter isDirect: true for a DM, false for a group or Everyone Nearby.
	static func text(for error: RoutingError?, isDirect: Bool) -> String {
		guard let error else { return String(localized: "Not delivered. Try again.") }
		guard plainWording else { return error.display }
		switch error {
		case .none:
			return isDirect ? String(localized: "Delivered") : String(localized: "Sent")
		case .maxRetransmit, .timeout, .noResponse:
			return isDirect
				? String(localized: "Not delivered. They may be out of range.")
				: String(localized: "Not delivered. No one in range heard it.")
		case .noRoute:
			return String(localized: "Not delivered. Couldn't find a way to reach them.")
		case .noInterface:
			return String(localized: "Your radio couldn't send this. Try again.")
		case .noChannel:
			return String(localized: "Not delivered. Their radio couldn't read it.")
		case .tooLarge:
			return String(localized: "This message is too long to send.")
		case .dutyCycleLimit:
			return String(localized: "Your radio has reached its sending limit for now. Try again in a few minutes.")
		case .rateLimitExceeded:
			return String(localized: "Sending too fast. Wait a moment and try again.")
		case .pkiFailed, .pkiUnknownPubkey:
			return String(localized: "Couldn't send privately yet. Try again in a minute.")
		case .gotNak, .badRequest, .notAuthorized, .adminBadSessionKey, .adminPublicKeyUnauthorized:
			return String(localized: "Not delivered. Try again.")
		}
	}
}
