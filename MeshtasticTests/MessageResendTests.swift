//
//  MessageResendTests.swift
//  MeshtasticTests
//
//  Copyright(c) Garth Vander Houwen 9/23/26.
//
import Foundation
import SwiftData
import Testing

@testable import Meshtastic
import MeshtasticProtobufs

/// Retrying a message sends the same one again rather than replacing it. It used to delete the
/// message and build a new one, which changed its timestamp — the row left the conversation and
/// a different one appeared at the bottom, and a send that threw left nothing behind at all.
/// The packet id does change: radios drop a packet whose id they've already seen.
@Suite("Message resend")
struct MessageResendTests {

	private func failedMessage(
		id: Int64 = 4242,
		sentAgo: TimeInterval = 10 * 60,
		ackError: Int32 = Int32(RoutingError.noResponse.rawValue)
	) -> MessageEntity {
		let message = MessageEntity()
		message.messageId = id
		message.messagePayload = "hello"
		message.messageTimestamp = Int32(Date().addingTimeInterval(-sentAgo).timeIntervalSince1970)
		message.receivedACK = false
		message.realACK = false
		message.ackError = ackError
		return message
	}

	@Test func aResendPutsTheMessageBackIntoSending() {
		let message = failedMessage()
		#expect(message.meshDeliveryStatus(isDirectMessage: true).canRetry, "starts out failed")

		message.markResending()

		#expect(message.ackError == 0)
		#expect(!message.receivedACK)
		#expect(!message.realACK)
		#expect(message.meshDeliveryStatus(isDirectMessage: true).text == MessageDeliveryStatus.sending.text)
	}

	@Test func aResendKeepsTheMessageId() {
		// The id is what makes this one message rather than two: the radio matches its ack on
		// it, replies point at it, and the echo coming back off the mesh is recognised as this
		// message rather than inserted again.
		let message = failedMessage(id: 987_654)
		message.markResending()
		#expect(message.messageId == 987_654)
	}

	@Test func aFailedTransmitPutsTheRowBackToFailed() {
		// A transmit that never leaves must not leave the row in "Sending…". It would show no
		// retry action until the ack timeout turned it into "Not delivered" minutes later, so
		// the one thing the user wants to do again is the one thing they cannot.
		let message = failedMessage(sentAgo: 10 * 60)
		let originalError = message.ackError
		let originalTimestamp = message.messageTimestamp

		message.markResending()
		#expect(message.meshDeliveryStatus(isDirectMessage: true).text == MessageDeliveryStatus.sending.text)

		message.markResendFailed(ackError: originalError, timestamp: originalTimestamp)

		#expect(message.ackError == originalError)
		#expect(message.messageTimestamp == originalTimestamp, "and back where it was in the thread")
		#expect(message.meshDeliveryStatus(isDirectMessage: true).canRetry, "retryable again straight away")
	}

	@Test func anAcknowledgementDuringTheTransmitWins() {
		// The ack says the message got through, whatever the transport reported afterwards.
		let message = failedMessage()
		let originalError = message.ackError
		let originalTimestamp = message.messageTimestamp
		message.markResending()

		message.receivedACK = true
		message.realACK = true
		message.markResendFailed(ackError: originalError, timestamp: originalTimestamp)

		#expect(message.ackError == 0, "not dragged back to failed")
		#expect(message.meshDeliveryStatus(isDirectMessage: true).text == MessageDeliveryStatus.deliveredToRecipient.text)
	}

	@Test func aResendMovesTheTimestampForward() {
		// The one that is easy to miss. Status is derived from how long ago the message was
		// sent, so leaving the old timestamp in place would put it past sendAckTimeout
		// immediately and the row would show as failed again without anything going wrong.
		let sentLongAgo = MessageEntity.sendAckTimeout + 60
		let message = failedMessage(sentAgo: sentLongAgo, ackError: 0)
		#expect(message.meshDeliveryStatus(isDirectMessage: true).canRetry, "aged out into not-delivered")

		let before = message.messageTimestamp
		message.markResending()

		#expect(message.messageTimestamp > before)
		#expect(message.meshDeliveryStatus(isDirectMessage: true).text == MessageDeliveryStatus.sending.text,
				"an aged-out message goes back to sending, not straight back to failed")
	}

	/// Every radio that heard the first try drops a packet with its id as a copy, so a retry
	/// under the old id never left the first hop. Same row, new id, and what points at it follows.
	@MainActor
	@Test func aResendGoesOutUnderANewId() async throws {
		let connection = ResendRecordingConnection()
		let manager = AccessoryManager(transports: [])
		manager.activeConnection = (
			device: Device(id: UUID(), name: "Test", transportType: .ble, identifier: "resend-test", connectionState: .connected, num: 0x1234),
			connection: connection
		)
		let context = manager.context
		let message = failedMessage(id: 777_001)
		let tapback = MessageEntity()
		tapback.messageId = 777_002
		tapback.isEmoji = true
		tapback.replyID = 777_001
		context.insert(message)
		context.insert(tapback)
		try context.save()
		defer {
			context.delete(message)
			context.delete(tapback)
			try? context.save()
		}

		try await manager.resendMessage(message)

		let sent = await connection.sentPackets
		guard case let .packet(packet) = try #require(sent.last).payloadVariant else {
			Issue.record("no packet sent")
			return
		}
		#expect(packet.id != 777_001, "not the id the mesh already saw")
		#expect(Int64(packet.id) == message.messageId, "the row now answers to the id that went out")
		#expect(tapback.replyID == message.messageId, "the reaction stays on the message")
		let all = try context.fetch(FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.messagePayload == "hello" && $0.isEmoji == false }))
		#expect(all.count == 1, "still one message")
	}
}

private actor ResendRecordingConnection: Connection {
	let type: TransportType = .ble
	var isConnected: Bool = true
	private(set) var sentPackets: [ToRadio] = []

	func send(_ data: ToRadio) async throws {
		sentPackets.append(data)
	}
	func connect() async throws -> AsyncStream<ConnectionEvent> {
		AsyncStream { $0.finish() }
	}
	func disconnect(withError: Error?, shouldReconnect: Bool) async throws {}
	func drainPendingPackets() async throws {}
	func startDrainPendingPackets() throws {}
	func appDidEnterBackground() {}
	func appDidBecomeActive() {}
}
