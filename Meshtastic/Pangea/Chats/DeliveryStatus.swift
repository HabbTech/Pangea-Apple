//
//  DeliveryStatus.swift
//  Pangea
//
//  The line under a sent message. Expert Mode keeps the original mesh terms;
//  standard mode says what happened in plain words.
//

import SwiftUI
import SwiftData
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
		case .pkiFailed, .pkiUnknownPubkey, .pkiSendFailPublicKey:
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
	static func markStaleSends(fromNum: Int64, connectedSince: Date = .distantPast, now: Date = Date(), context: ModelContext) -> Int {
		guard shouldSweep(connectedSince: connectedSince, now: now) else { return 0 }
		let cutoff = Int32(clamping: Int64(now.timeIntervalSince1970 - staleAfter))
		// Every condition in the store query: incoming messages are all receivedACK == false, so
		// filtering by sender in memory loaded nearly the whole message table on the main actor.
		let none: Int32 = 0
		let fromMe = #Predicate<MessageEntity> { message in
			message.fromUser?.num == fromNum && message.receivedACK == false && message.admin == false
		}
		let unansweredText = #Predicate<MessageEntity> { message in
			message.ackError == none && message.portNum == none
				&& message.messageTimestamp > none && message.messageTimestamp <= cutoff
		}
		let descriptor = FetchDescriptor<MessageEntity>(predicate: #Predicate<MessageEntity> { message in
			fromMe.evaluate(message) && unansweredText.evaluate(message)
		})
		let stale: [MessageEntity] = (try? context.fetch(descriptor)) ?? []
		guard !stale.isEmpty else { return 0 }
		for message in stale {
			message.ackError = Int32(RoutingError.timeout.rawValue)
		}
		do {
			try context.save()
			NotificationCenter.default.post(name: .meshMessagesDidChange, object: nil)
			Logger.data.info("💬 [Chats] \(stale.count, privacy: .public) unanswered sends marked not delivered")
		} catch {
			context.rollback()
			Logger.data.error("💬 [Chats] Couldn't mark unanswered sends: \(error.localizedDescription, privacy: .public)")
			return 0
		}
		return stale.count
	}

	/// Checks again once anything sent before now has had `staleAfter` to be answered. Only if
	/// the same radio is still connected then: after a disconnect, a Forget, a radio switch or a
	/// data clear the context of now may belong to a replaced store or another radio's rows, and
	/// the next connection runs its own sweep anyway. The context is read again after the wait.
	@MainActor
	static func checkForStaleSends(fromNum: Int64, accessoryManager: AccessoryManager) {
		guard let deviceId = accessoryManager.activeConnection?.device.id else { return }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(staleAfter + 5))
			guard accessoryManager.isConnected,
				  accessoryManager.activeDeviceNum == fromNum,
				  accessoryManager.activeConnection?.device.id == deviceId,
				  // A reconnect meanwhile is a new connection: its queued replies get the same
				  // grace as on any connect, and none while its download is still running. A
				  // connection that asked for no download counts from its configuration.
				  !accessoryManager.nodeDatabaseDumpInProgress,
				  let connectedSince = accessoryManager.databaseDownloadedAt ?? accessoryManager.lastConfigRefresh else { return }
			markStaleSends(fromNum: fromNum, connectedSince: connectedSince, context: accessoryManager.context)
		}
	}
}

// MARK: Plain wording for the status line

extension DeliveryStatus {

	/// Pangea: the status upstream works out, with its words swapped for plain ones outside
	/// Expert Mode. Icon, colour and whether Try Again shows stay as they are.
	static func plain(_ status: MessageDeliveryStatus, receivedACK: Bool, realACK: Bool, ackError: Int32,
					  timedOut: Bool, isDirect: Bool) -> MessageDeliveryStatus {
		guard plainWording else { return status }
		let text: String
		if receivedACK {
			text = isDirect ? (realACK ? String(localized: "Delivered") : relayedOnly) : String(localized: "Sent")
		} else if ackError == 0 {
			text = timedOut ? Self.text(for: nil, isDirect: isDirect) : waiting
		} else {
			text = Self.text(for: RoutingError(rawValue: Int(ackError)), isDirect: isDirect)
		}
		return MessageDeliveryStatus(text: text, detail: status.detail, systemImage: status.systemImage,
									 color: status.color, canRetry: status.canRetry)
	}
}
