//
//  DeliveryStatus.swift
//  Pangea
//
//  The line under a sent message. Expert Mode keeps the original mesh terms;
//  standard mode says what happened in plain words.
//

import SwiftUI
import CoreData
import OSLog

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
		guard plainWording else { return error?.display ?? "Empty Ack Error" }
		guard let error else { return String(localized: "Not delivered. Try again.") }
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

// MARK: Sends the radio never answered

extension DeliveryStatus {

	/// The radio answers every send it took, with a delivery or a failure, well inside this
	/// (it gives up on its own retries first). A send still unanswered after it was lost on the
	/// way: the link dropped mid-write, the write was rejected, or the reply came while the
	/// app wasn't connected.
	nonisolated static let staleAfter: TimeInterval = 5 * 60

	/// After connecting, the radio hands over what it queued while the app was away, replies to
	/// earlier sends among them. The first sweep on a connection waits this long for them.
	nonisolated static let replyGrace: TimeInterval = 30

	/// Whether a connection has been up long enough for its queued replies to have arrived.
	nonisolated static func shouldSweep(connectedSince: Date, now: Date = Date()) -> Bool {
		now.timeIntervalSince(connectedSince) >= replyGrace
	}

	/// Turns my sends that are still "Sending…" after `staleAfter` into "Not delivered", which
	/// offers Try Again. Only text the app sent (`portNum` 0): rows the radio made itself, like a
	/// detection sensor alert, aren't something to resend. Nothing is resent here, and a reply
	/// that does arrive still corrects the row. Returns how many changed.
	/// - Parameter connectedSince: when the radio finished its database download; nothing is
	///   marked until `replyGrace` after it.
	@MainActor
	@discardableResult
	static func markStaleSends(fromNum: Int64, connectedSince: Date = .distantPast, now: Date = Date(), context: NSManagedObjectContext) -> Int {
		guard shouldSweep(connectedSince: connectedSince, now: now) else { return 0 }
		let request = MessageEntity.fetchRequest()
		let cutoff = Int32(clamping: Int64(now.timeIntervalSince1970 - staleAfter))
		request.predicate = NSPredicate(format: "fromUser.num == %lld AND receivedACK == false AND ackError == 0 AND admin == false AND portNum == 0 AND messageTimestamp > 0 AND messageTimestamp <= %d", fromNum, cutoff)
		guard let stale = try? context.fetch(request), !stale.isEmpty else { return 0 }
		for message in stale {
			message.ackError = Int32(RoutingError.timeout.rawValue)
		}
		do {
			try context.save()
			Logger.data.info("💬 [Chats] \(stale.count, privacy: .public) unanswered sends marked not delivered")
		} catch {
			context.rollback()
			Logger.data.error("💬 [Chats] Couldn't mark unanswered sends: \(error.localizedDescription, privacy: .public)")
			return 0
		}
		return stale.count
	}

	/// Checks again once anything sent before now has had `staleAfter` to be answered.
	@MainActor
	static func checkForStaleSends(fromNum: Int64, context: NSManagedObjectContext) {
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(staleAfter + 5))
			markStaleSends(fromNum: fromNum, context: context)
		}
	}
}
