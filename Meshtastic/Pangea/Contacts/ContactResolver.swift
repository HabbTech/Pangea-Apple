//
//  ContactResolver.swift
//  Pangea
//
//  Turns an @code into someone you can message privately. If we already know
//  them, done. If the invite carried their key (link / QR), add them straight
//  to the radio. Otherwise ask them over the mesh and wait for their key.
//

import Foundation
import CoreData
import MeshtasticProtobufs
import OSLog

@MainActor
final class ContactResolver: ObservableObject {

	enum State: Equatable {
		case idle
		case reaching(code: String)
		case ready(nodeNum: Int64)
		case unreachable(code: String)
		case failed(String)
	}

	@Published private(set) var state: State = .idle

	private var task: Task<Void, Never>?
	private let requestInterval: Duration = .seconds(20)
	private let attempts = 3

	func resolve(_ invite: PangeaCode.Invite, accessoryManager: AccessoryManager) {
		task?.cancel()
		task = Task { await run(invite, accessoryManager: accessoryManager) }
	}

	func cancel() {
		task?.cancel()
		task = nil
		state = .idle
	}

	private func run(_ invite: PangeaCode.Invite, accessoryManager: AccessoryManager) async {
		let context = accessoryManager.context

		guard let myNum = accessoryManager.activeDeviceNum, accessoryManager.isConnected else {
			state = .failed(String(localized: "Connect your radio first, then try again."))
			return
		}
		guard invite.nodeNum != myNum else {
			state = .failed(String(localized: "That's your own code. Share it with a friend so they can message you."))
			return
		}

		if hasKey(invite.nodeNum, context: context) {
			state = .ready(nodeNum: invite.nodeNum)
			return
		}

		// Link or QR code: we already have their name and key.
		if let contact = invite.contact, !contact.user.publicKey.isEmpty,
		   accessoryManager.checkIsVersionSupported(forVersion: ContactURLHandler.minimumContactVersion),
		   let data = try? contact.serializedData() {
			do {
				try await accessoryManager.addContactFromURL(base64UrlString: data.base64EncodedString().base64ToBase64url())
				state = .ready(nodeNum: invite.nodeNum)
				return
			} catch {
				Logger.services.error("👥 [Contacts] Adding contact failed: \(error.localizedDescription, privacy: .public)")
			}
		}

		// Typed code: say hello over the mesh and wait for their reply.
		state = .reaching(code: invite.code)
		for _ in 0..<attempts {
			do {
				try await sendUserInfo(to: invite.nodeNum, accessoryManager: accessoryManager)
			} catch {
				state = .failed(String(localized: "Couldn't send through your radio. Make sure it's connected."))
				return
			}
			let deadline = ContinuousClock.now + requestInterval
			while ContinuousClock.now < deadline {
				try? await Task.sleep(for: .seconds(1))
				if Task.isCancelled { return }
				if hasKey(invite.nodeNum, context: context) {
					state = .ready(nodeNum: invite.nodeNum)
					return
				}
			}
		}
		state = .unreachable(code: invite.code)
	}

	private func hasKey(_ nodeNum: Int64, context: NSManagedObjectContext) -> Bool {
		let request = UserEntity.fetchRequest()
		request.predicate = NSPredicate(format: "num == %lld", nodeNum)
		request.fetchLimit = 1
		guard let user = try? context.fetch(request).first else { return false }
		return user.pkiEncrypted && !(user.publicKey?.isEmpty ?? true)
	}

	/// Same packet as "Exchange User Info", but works for someone who isn't in the node list yet.
	private func sendUserInfo(to nodeNum: Int64, accessoryManager: AccessoryManager) async throws {
		guard let myNum = accessoryManager.activeDeviceNum,
			  let me = getNodeInfo(id: myNum, context: accessoryManager.context)?.user else {
			throw AccessoryError.ioFailed("No connected user")
		}
		var data = DataMessage()
		data.payload = try me.toProto().serializedData()
		data.portnum = .nodeinfoApp
		data.wantResponse = true

		var packet = MeshPacket()
		packet.to = UInt32(truncatingIfNeeded: nodeNum)
		packet.from = UInt32(truncatingIfNeeded: myNum)
		packet.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		packet.priority = .reliable
		packet.wantAck = true
		packet.channel = 0
		packet.decoded = data

		var toRadio = ToRadio()
		toRadio.packet = packet
		try await accessoryManager.send(toRadio, debugDescription: "👥 [Contacts] Sent user info to \(PangeaCode.code(for: nodeNum))")
	}
}
