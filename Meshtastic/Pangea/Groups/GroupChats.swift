//
//  GroupChats.swift
//  Pangea
//
//  A group chat is a private channel with a random key. Creating, joining and
//  leaving only ever touch secondary channel slots (1–7); the primary channel
//  and LoRa settings are never changed, so joining can't knock a radio off the mesh.
//

import Foundation
import CoreData
import MeshtasticProtobufs
import OSLog
import UserNotifications

struct GroupInvite: Equatable, Codable, Identifiable {
	var name: String
	var psk: Data

	var id: String { name + psk.base64EncodedString() }

	static let maxNameBytes = 11 // firmware limit for channel names

	static func clampedName(_ name: String) -> String {
		var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
		while value.utf8.count > maxNameBytes {
			value = String(value.dropLast())
		}
		return value
	}

	var settings: ChannelSettings {
		var settings = ChannelSettings()
		settings.name = name
		settings.psk = psk
		settings.uplinkEnabled = false
		settings.downlinkEnabled = false
		return settings
	}

	init(name: String, psk: Data) {
		self.name = name
		self.psk = psk
	}

	init?(settings: ChannelSettings) {
		guard !settings.name.isEmpty, settings.psk.count == 16 || settings.psk.count == 32 else { return nil }
		self.init(name: settings.name, psk: settings.psk)
	}

	// MARK: Links

	static let host = "group"

	/// pangea://group#<ChannelSet with just this channel and no LoRa config>
	var link: URL? {
		var set = ChannelSet()
		set.settings = [settings]
		guard let data = try? set.serializedData() else { return nil }
		return URL(string: "\(PangeaCode.scheme)://\(Self.host)#\(data.base64EncodedString().base64ToBase64url())")
	}

	init?(url: URL) {
		guard url.scheme?.lowercased() == PangeaCode.scheme, url.host?.lowercased() == Self.host,
			  let fragment = url.fragment,
			  let data = Data(base64Encoded: fragment.base64urlToBase64()),
			  let set = try? ChannelSet(serializedBytes: data),
			  let first = set.settings.first else { return nil }
		self.init(settings: first)
	}

	// MARK: Invites sent over a DM

	/// Prefix so we never mistake another app's PRIVATE_APP payload for an invite.
	private static let magic = Data("PGI1".utf8)

	var invitePayload: Data? {
		guard let body = try? settings.serializedData() else { return nil }
		return Self.magic + body
	}

	init?(invitePayload payload: Data) {
		guard payload.starts(with: Self.magic),
			  let settings = try? ChannelSettings(serializedBytes: payload.dropFirst(Self.magic.count)) else { return nil }
		self.init(settings: settings)
	}
}

enum GroupChatError: LocalizedError {
	case notConnected
	case full
	case noKey

	var errorDescription: String? {
		switch self {
		case .notConnected:
			return String(localized: "Connect your radio first, then try again.")
		case .full:
			return String(localized: "Your radio can be in 7 group chats at once. Leave one to make room.")
		case .noKey:
			return String(localized: "You can only invite people you've already messaged privately.")
		}
	}
}

@MainActor
enum GroupChats {

	/// Channel names upstream treats as special; never shown as chats.
	static let reservedNames: Set<String> = ["gpio", "mqtt", "serial", "admin"]
	static let maxGroups = 7

	static func isChat(_ channel: ChannelEntity) -> Bool {
		channel.role > 0 && !reservedNames.contains((channel.name ?? "").lowercased())
	}

	/// Primary channel is the public mesh everyone with default settings shares.
	static func isEveryone(_ channel: ChannelEntity) -> Bool {
		channel.index == 0
	}

	static func displayName(_ channel: ChannelEntity) -> String {
		if isEveryone(channel) { return String(localized: "Everyone Nearby") }
		if let name = channel.name, !name.isEmpty { return name }
		return String(localized: "Group \(channel.index)")
	}

	private static func connectedUser(_ accessoryManager: AccessoryManager) throws -> (UserEntity, MyInfoEntity) {
		guard accessoryManager.isConnected,
			  let num = accessoryManager.activeDeviceNum,
			  let node = getNodeInfo(id: num, context: accessoryManager.context),
			  let user = node.user,
			  let myInfo = node.myInfo else { throw GroupChatError.notConnected }
		return (user, myInfo)
	}

	static func groups(in myInfo: MyInfoEntity) -> [ChannelEntity] {
		(myInfo.channels?.array as? [ChannelEntity] ?? []).filter { isChat($0) && !isEveryone($0) }
	}

	static func existing(_ invite: GroupInvite, in myInfo: MyInfoEntity) -> ChannelEntity? {
		(myInfo.channels?.array as? [ChannelEntity])?.first { $0.psk == invite.psk && $0.name == invite.name && $0.role > 0 }
	}

	// MARK: Create / join / leave

	static func create(name: String, accessoryManager: AccessoryManager) async throws -> Int32 {
		var key = Data(count: 32)
		let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
		guard status == errSecSuccess else { throw AccessoryError.appError("Couldn't generate a key") }
		return try await join(GroupInvite(name: GroupInvite.clampedName(name), psk: key), accessoryManager: accessoryManager)
	}

	/// Adds the group to the first free slot. Already a member? Returns that slot.
	@discardableResult
	static func join(_ invite: GroupInvite, accessoryManager: AccessoryManager) async throws -> Int32 {
		let (user, myInfo) = try connectedUser(accessoryManager)
		if let channel = existing(invite, in: myInfo) {
			return channel.index
		}
		let used = Set((myInfo.channels?.array as? [ChannelEntity] ?? []).filter { $0.role > 0 }.map(\.index))
		guard let index = (Int32(1)...Int32(maxGroups)).first(where: { !used.contains($0) }) else {
			throw GroupChatError.full
		}

		var channel = Channel()
		channel.index = index
		channel.role = .secondary
		channel.settings = invite.settings
		_ = try await accessoryManager.saveChannel(channel: channel, fromUser: user, toUser: user)
		await MeshPackets.shared.channelPacket(channel: channel, fromNum: user.num)
		Logger.services.info("👥 [Groups] Joined group in slot \(index)")
		return index
	}

	static func leave(_ channel: ChannelEntity, accessoryManager: AccessoryManager) async throws {
		let (user, _) = try connectedUser(accessoryManager)
		guard channel.index > 0 else { return }
		var disabled = Channel()
		disabled.index = channel.index
		disabled.role = .disabled
		_ = try await accessoryManager.saveChannel(channel: disabled, fromUser: user, toUser: user)

		let context = accessoryManager.context
		for message in channel.allPrivateMessages {
			context.delete(message)
		}
		context.delete(channel)
		do {
			try context.save()
		} catch {
			context.rollback()
			Logger.data.error("👥 [Groups] Failed to remove group: \(error.localizedDescription, privacy: .public)")
		}
	}

	// MARK: Invite over DM

	/// Sends the group's key privately (PKI) on a port other apps ignore.
	static func sendInvite(_ invite: GroupInvite, to recipient: UserEntity, accessoryManager: AccessoryManager) async throws {
		let (me, _) = try connectedUser(accessoryManager)
		guard recipient.pkiEncrypted, let publicKey = recipient.publicKey, !publicKey.isEmpty else {
			throw GroupChatError.noKey
		}
		guard let payload = invite.invitePayload else { throw AccessoryError.appError("Couldn't encode invite") }

		var data = DataMessage()
		data.portnum = .privateApp
		data.payload = payload

		var packet = MeshPacket()
		packet.to = UInt32(truncatingIfNeeded: recipient.num)
		packet.from = UInt32(truncatingIfNeeded: me.num)
		packet.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		packet.priority = .reliable
		packet.wantAck = true
		packet.channel = 0
		packet.pkiEncrypted = true
		packet.publicKey = publicKey
		packet.decoded = data

		var toRadio = ToRadio()
		toRadio.packet = packet
		try await accessoryManager.send(toRadio, debugDescription: "👥 [Groups] Sent group invite")
	}

	/// Called for every PRIVATE_APP packet. Only PKI-encrypted DMs count, so an
	/// invite can't be broadcast to everyone on a public channel.
	static func handlePrivateAppPacket(_ packet: MeshPacket) {
		if ProfileSync.handle(packet) { return }
		guard case let .decoded(data) = packet.payloadVariant,
			  packet.pkiEncrypted,
			  packet.to != UInt32.max,
			  let invite = GroupInvite(invitePayload: data.payload) else { return }
		GroupInviteStore.shared.add(invite, from: Int64(packet.from))
	}
}

/// Invites waiting for a tap on "Join". Kept on the phone only.
@MainActor
final class GroupInviteStore: ObservableObject {
	static let shared = GroupInviteStore()

	struct Pending: Codable, Identifiable, Equatable {
		var invite: GroupInvite
		var fromNum: Int64
		var received: Date
		var id: String { invite.id }
	}

	@Published private(set) var pending: [Pending] = []
	private let key = "pangeaPendingGroupInvites"

	init() {
		if let data = UserDefaults.standard.data(forKey: key),
		   let saved = try? JSONDecoder().decode([Pending].self, from: data) {
			pending = saved
		}
	}

	func add(_ invite: GroupInvite, from num: Int64) {
		guard !pending.contains(where: { $0.invite == invite }) else { return }
		pending.insert(Pending(invite: invite, fromNum: num, received: Date()), at: 0)
		save()
		notify(invite, from: num)
	}

	private func notify(_ invite: GroupInvite, from num: Int64) {
		let request = UserEntity.fetchRequest()
		request.predicate = NSPredicate(format: "num == %lld", num)
		request.fetchLimit = 1
		let sender = (try? PersistenceController.shared.container.viewContext.fetch(request).first)?.longName ?? PangeaCode.code(for: num)

		let content = UNMutableNotificationContent()
		content.title = String(localized: "Group Invite")
		content.body = String(localized: "\(sender) invited you to \(invite.name)")
		content.sound = .default
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pangea.invite.\(invite.id)", content: content, trigger: nil))
	}

	func remove(_ item: Pending) {
		pending.removeAll { $0.id == item.id }
		save()
	}

	private func save() {
		if let data = try? JSONEncoder().encode(pending) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}
}
