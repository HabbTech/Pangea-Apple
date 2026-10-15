//
//  GroupChats.swift
//  Pangea
//
//  A group chat is a private channel with a random key. Creating, joining and
//  leaving only ever touch secondary channel slots (1–7); the primary channel
//  and LoRa settings are never changed, so joining can't knock a radio off the mesh.
//

import Foundation
import SwiftData
import MeshtasticProtobufs
import OSLog
import UserNotifications
import CryptoKit

struct GroupInvite: Equatable, Codable, Identifiable {
	var name: String
	var psk: Data

	/// The name's bytes plus a hash of the key, so the key itself never ends up in
	/// identifiers such as notification IDs.
	var id: String {
		Data(name.utf8).base64EncodedString() + "." + SHA256.hash(data: psk).prefix(8).map { String(format: "%02x", $0) }.joined()
	}

	/// Byte for byte, as the radio tells channels apart. Swift's `==` on strings matches
	/// "Café" typed with an accented é and with e plus an accent; the radio doesn't.
	static func == (lhs: GroupInvite, rhs: GroupInvite) -> Bool {
		lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.psk == rhs.psk
	}

	static let maxNameBytes = 11 // firmware limit for channel names

	/// Channel names firmware modules and upstream treat as special; never a group chat.
	static let reservedNames: Set<String> = ["gpio", "mqtt", "serial", "admin"]

	/// Also true for names with hidden characters (see `String.withoutHiddenCharacters`):
	/// firmware reads names as C strings, so "gpio\0x" is "gpio" on the radio, and a
	/// zero-width or direction-changing character can make any name look like another.
	static func isReserved(_ name: String) -> Bool {
		name.hasHiddenCharacters || reservedNames.contains(name.cleanedName.lowercased())
	}

	/// For the name being typed into New Group only: trimmed and cut to the firmware limit
	/// in whole characters, then trimmed again so a cut that lands after a space doesn't
	/// keep it. Applying it twice changes nothing. Never applied to a received name, which
	/// is the channel's identity (see `init?(settings:)`).
	static func clampedName(_ name: String) -> String {
		name.trimmingCharacters(in: .whitespacesAndNewlines).clampedUTF8(maxNameBytes).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// A received name is shown only if it's exactly what it looks like. It can't be
	/// cleaned instead: the name is part of the channel's identity on the radio, so a
	/// cleaned name would be a different channel.
	static func isAcceptableName(_ name: String) -> Bool {
		!name.isEmpty && name.cleanedName == name && !name.isBlankName && !isReserved(name)
	}

	/// The name a new group gets from what was typed: hidden characters stripped, spaces
	/// made plain, cut to fit. Fails when nothing visible was typed, when not even the first
	/// character fits, or when it's a reserved name.
	static func nameForNewGroup(_ typed: String) -> Result<String, GroupChatError> {
		let cut = typed.cutName(fitting: maxNameBytes)
		if cut.name.isEmpty {
			return .failure(cut.tooLong ? .tooLong : .blankName)
		}
		return isAcceptableName(cut.name) ? .success(cut.name) : .failure(.reservedName)
	}

	/// A key only the group has: 16 or 32 random bytes. No key, or the 1-byte default
	/// one, is public: anyone who adds a channel of the same name can read it. So is the
	/// published default key written out in full, or any of its 1-byte variants (the firmware
	/// makes key n the default with its last byte 0x01 + n - 1), or a key of all zeros.
	static func isPrivateKey(_ psk: Data) -> Bool {
		guard psk.count == 16 || psk.count == 32, psk.contains(where: { $0 != 0 }) else { return false }
		return !(psk.count == 16 && psk.starts(with: defaultKeyPrefix))
	}

	/// The firmware's default channel key, but for its last byte.
	private static let defaultKeyPrefix = Data([0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59, 0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69])

	/// The invite for a group I'm in, or why a friend's app couldn't join from one: the
	/// same check their app makes on what it receives, so I'm never offered a link or DM
	/// that their app would refuse.
	static func shareable(name: String, psk: Data) -> Result<GroupInvite, GroupChatError> {
		guard isPrivateKey(psk) else { return .failure(.cantShareKey) }
		guard let invite = GroupInvite(settings: GroupInvite(name: name, psk: psk).settings) else { return .failure(.cantShareName) }
		return .success(invite)
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

	/// Received from someone else (link, QR or DM). The name is taken byte for byte: the
	/// radio hears the channel by a hash of its name and key, so a trimmed or shortened
	/// name would be a different channel from the inviter's. One that doesn't fit the
	/// firmware, isn't exactly what it looks like, or is reserved is refused, never fixed.
	init?(settings: ChannelSettings) {
		let name = settings.name
		guard name.utf8.count <= Self.maxNameBytes, Self.isAcceptableName(name), Self.isPrivateKey(settings.psk) else { return nil }
		self.init(name: name, psk: settings.psk)
	}

	/// Passes the checks made on an invite as it comes in, as they are now. One kept by an
	/// earlier version, which checked less, may not.
	static func isJoinable(_ invite: GroupInvite) -> Bool {
		GroupInvite(settings: invite.settings) != nil
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
	static let magic = Data("PGI1".utf8)

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
	case channelsNotLoaded
	case full
	case noKey
	case reservedName
	case blankName
	case tooLong
	case cantShareName
	case cantShareKey

	var errorDescription: String? {
		switch self {
		case .notConnected:
			return String(localized: "Connect your radio first, then try again.")
		case .channelsNotLoaded:
			return String(localized: "Your radio is still loading its groups. Try again in a moment.")
		case .full:
			return String(localized: "Your radio can be in 7 group chats at once. Leave one to make room.")
		case .noKey:
			return String(localized: "You can only invite people you've already messaged privately.")
		case .reservedName:
			return String(localized: "That name is used by the radio. Pick another.")
		case .blankName:
			return String(localized: "Give the group a name with at least one letter or number.")
		case .tooLong:
			return String(localized: "That's too long for a group name.")
		case .cantShareName:
			return String(localized: "This group's name has spacing or characters Pangea can't share. Make a new group to invite people.")
		case .cantShareKey:
			return String(localized: "This group doesn't have a private key, so anyone could read it. Make a new group to invite people.")
		}
	}
}

@MainActor
enum GroupChats {

	static let maxGroups = 7

	static func isChat(_ channel: ChannelEntity) -> Bool {
		channel.role > 0 && !GroupInvite.isReserved(channel.name ?? "")
	}

	/// A chat my card and photo may go to: a group with a private key. A channel on no
	/// key or the default one is still listed, but anyone could be reading it, so it's
	/// treated like Everyone Nearby.
	static func isPrivateGroup(_ channel: ChannelEntity) -> Bool {
		!isEveryone(channel) && isChat(channel) && GroupInvite.isPrivateKey(channel.psk ?? Data())
	}

	/// Everyone Nearby is public and can be busy, so it doesn't notify until turned on in its chat.
	nonisolated static let everyoneNotificationsKey = "pangeaEveryoneNotifications"

	/// Whether a message on this channel may notify, before the channel's own mute and the
	/// app-wide setting. Expert Mode keeps the per-channel alerts it has always had.
	nonisolated static func mayNotify(channelIndex: Int32, expertMode: Bool = UserDefaults.expertModeEnabled,
						  everyoneOn: Bool = UserDefaults.standard.bool(forKey: everyoneNotificationsKey)) -> Bool {
		channelIndex != 0 || expertMode || everyoneOn
	}

	/// Whether the channel's mute, which is kept on the radio, silences it. Only Expert Mode
	/// shows or changes that mute, so outside it a mute left by Expert Mode, another app, or a
	/// group that used the slot before can't silence a chat. Everyone Nearby's bell decides there.
	nonisolated static func radioMuteApplies(channelIndex: Int32, expertMode: Bool = UserDefaults.expertModeEnabled) -> Bool {
		expertMode
	}

	/// Whether an @mention of this radio notifies past the bell, the notification setting and
	/// the channel's mute, as upstream does. Expert Mode only: anyone on the public channel can
	/// type a node's @!hex, so in standard mode a stranger could make the phone notify.
	nonisolated static func mentionOverridesMutes(expertMode: Bool = UserDefaults.expertModeEnabled) -> Bool {
		expertMode
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
		myInfo.sortedChannels.filter { isChat($0) && !isEveryone($0) }
	}

	/// Matched on key and the name's exact bytes: the radio hears a channel by a hash of
	/// both, so the same key under any other name, even one a space longer or the same
	/// letters encoded another way, is a different group.
	static func existing(_ invite: GroupInvite, in myInfo: MyInfoEntity) -> ChannelEntity? {
		myInfo.sortedChannels.first {
			$0.index > 0 && $0.role > 0 && $0.psk == invite.psk && ($0.name ?? "").utf8.elementsEqual(invite.name.utf8)
		}
	}

	// MARK: Create / join / leave

	static func create(name: String, accessoryManager: AccessoryManager) async throws -> Int32 {
		// A name the app would then hide (a reserved one, or one with hidden characters
		// that can't be cleaned away) would use up a slot nobody can see.
		let name = try GroupInvite.nameForNewGroup(name).get()
		var key = Data(count: 32)
		let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
		guard status == errSecSuccess else { throw AccessoryError.appError("Couldn't generate a key") }
		return try await join(GroupInvite(name: name, psk: key), accessoryManager: accessoryManager)
	}

	/// Adds the group to the first free slot. Already a member? Returns that slot.
	@discardableResult
	static func join(_ invite: GroupInvite, accessoryManager: AccessoryManager) async throws -> Int32 {
		try joinCheck(invite)
		let (user, myInfo) = try connectedUser(accessoryManager)
		if let channel = existing(invite, in: myInfo) {
			GroupInviteStore.shared.remove(invite: invite)
			return channel.index
		}
		let index = try freeSlot(in: myInfo.sortedChannels)

		var channel = Channel()
		channel.index = index
		channel.role = .secondary
		channel.settings = invite.settings
		_ = try await accessoryManager.saveChannel(channel: channel, fromUser: user, toUser: user)
		// Mirrored on the main context, where the channel lists read it. The radio already has
		// the group, so a local save error isn't a failed join: the next connect lists it anyway.
		do {
			try accessoryManager.applyLocalChannelMutation(channel, fromNum: user.num)
		} catch {
			Logger.pangea.error("👥 [Groups] Joined, but couldn't save the group locally: \(error.localizedDescription, privacy: .public)")
		}
		// The Messages extension shares groups from its own copy; rebuilt from the row just saved.
		MeshShareSnapshotBuilder.refresh(nodeNum: user.num, context: accessoryManager.context)
		Logger.pangea.info("👥 [Groups] Joined group in slot \(index)")
		GroupInviteStore.shared.remove(invite: invite)
		return index
	}

	/// The first secondary slot the radio isn't using. The radio always has a primary channel,
	/// so a list without one is still loading or out of date, and a slot that looks free in it
	/// may hold a group: writing there would replace that group on the radio.
	static func freeSlot(in channels: [ChannelEntity]) throws -> Int32 {
		try freeSlots(in: channels, count: 1)[0]
	}

	/// The first `count` free secondary slots, by the same rule as `freeSlot`. Throws `full`
	/// unless there are that many, so an import of several channels writes all or none.
	static func freeSlots(in channels: [ChannelEntity], count: Int) throws -> [Int32] {
		guard channels.contains(where: { $0.index == 0 && $0.role == Int32(Channel.Role.primary.rawValue) }) else {
			throw GroupChatError.channelsNotLoaded
		}
		let used = Set(channels.filter { $0.role > 0 }.map(\.index))
		let free = (Int32(1)...Int32(maxGroups)).filter { !used.contains($0) }
		guard !free.isEmpty, free.count >= count else {
			throw GroupChatError.full
		}
		return Array(free.prefix(count))
	}

	/// Never a group anyone could read, whatever kept the invite: one listed by an earlier
	/// version is taken off the list.
	static func joinCheck(_ invite: GroupInvite) throws {
		guard GroupInvite.isPrivateKey(invite.psk) else {
			GroupInviteStore.shared.remove(invite: invite)
			throw GroupChatError.cantShareKey
		}
	}

	/// Slots being left right now. A second Leave of the same group while the first is
	/// waiting on the radio is dropped, so it can't disable whatever group takes the slot next.
	private static var leaving: Set<Int32> = []

	static func leave(_ channel: ChannelEntity, accessoryManager: AccessoryManager) async throws {
		let (user, _) = try connectedUser(accessoryManager)
		// Read before the radio write: once another leave has deleted it, the channel reads
		// index 0, and its messages would be Everyone Nearby's.
		guard !channel.isDeleted, channel.modelContext != nil else { return }
		let index = channel.index
		let id = channel.persistentModelID
		guard index > 0, leaving.insert(index).inserted else { return }
		defer { leaving.remove(index) }
		var disabled = Channel()
		disabled.index = index
		disabled.role = .disabled
		_ = try await accessoryManager.saveChannel(channel: disabled, fromUser: user, toUser: user)

		let context = accessoryManager.context
		// The Messages extension shares groups from its own copy, which still holds this
		// group's key: rebuilt once the row is gone, whichever way this ends.
		defer { MeshShareSnapshotBuilder.refresh(nodeNum: user.num, context: context) }
		if !removeLocally(id, index: index, context: context) {
			// A reconnect during the radio write can drop the row first (the radio now reports
			// the slot disabled). The leave still happened, so the slot's messages go too, or the
			// next group in it would show them. Not when another group already holds the slot.
			guard !slotHoldsGroup(index, context: context), removeMessages(inSlot: index, context: context) else { return }
		}
		// A notification for this slot would otherwise open whatever group joins it next.
		ChatsView.removeNotifications(opening: .group(index: index))
		if let appState = accessoryManager.appState {
			ChatsView.refreshUnread(appState: appState, myNum: user.num, context: context)
		}
	}

	/// Deletes the group and its messages, found by the slot read before the radio write.
	/// False when the channel is already gone or the slot now holds another group.
	@discardableResult
	static func removeLocally(_ id: PersistentIdentifier, index: Int32, context: ModelContext) -> Bool {
		// Fetched rather than looked up, so a channel already deleted is simply not found.
		var byId = FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.persistentModelID == id })
		byId.fetchLimit = 1
		guard index > 0,
			  let channel = try? context.fetch(byId).first,
			  !channel.isDeleted, channel.index == index else { return false }
		deleteMessages(inSlot: index, context: context)
		context.delete(channel)
		do {
			try context.save()
		} catch {
			context.rollback()
			Logger.pangea.error("👥 [Groups] Failed to remove group: \(error.localizedDescription, privacy: .public)")
			return false
		}
		return true
	}

	/// Whether any channel row is using this slot.
	static func slotHoldsGroup(_ index: Int32, context: ModelContext) -> Bool {
		var descriptor = FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.index == index && $0.role > 0 })
		descriptor.fetchLimit = 1
		return ((try? context.fetchCount(descriptor)) ?? 1) > 0
	}

	/// Deletes and saves a left group's messages when its row is already gone.
	@discardableResult
	static func removeMessages(inSlot index: Int32, context: ModelContext) -> Bool {
		guard index > 0 else { return false }
		deleteMessages(inSlot: index, context: context)
		do {
			try context.save()
		} catch {
			context.rollback()
			Logger.pangea.error("👥 [Groups] Failed to remove a left group's messages: \(error.localizedDescription, privacy: .public)")
			return false
		}
		return true
	}

	/// The slot's own messages, without reading the channel again.
	private static func deleteMessages(inSlot index: Int32, context: ModelContext) {
		let descriptor = FetchDescriptor<MessageEntity>(predicate: #Predicate {
			$0.channel == index && $0.toUser == nil && $0.isEmoji == false
		})
		for message in (try? context.fetch(descriptor)) ?? [] {
			context.delete(message)
		}
	}

	// MARK: Invite over DM

	/// Sends the group's key privately (PKI) on a port other apps ignore.
	static func sendInvite(_ invite: GroupInvite, to recipient: UserEntity, accessoryManager: AccessoryManager) async throws {
		// Their app would refuse it without a word, so don't let it look sent.
		_ = try GroupInvite.shareable(name: invite.name, psk: invite.psk).get()
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
			  packet.to != UInt32.max else { return }
		guard let invite = GroupInvite(invitePayload: data.payload) else {
			if data.payload.starts(with: GroupInvite.magic) {
				Logger.pangea.info("👥 [Groups] Ignored an invite whose name or key can't be joined")
			}
			return
		}
		let accessoryManager = AccessoryManager.shared
		if let num = accessoryManager.activeDeviceNum,
		   let myInfo = getNodeInfo(id: num, context: accessoryManager.context)?.myInfo,
		   existing(invite, in: myInfo) != nil {
			// Already in this group.
			return
		}
		GroupInviteStore.shared.add(invite, from: Int64(packet.from))
	}
}

/// Where the invite store reads the time. Invites are aged by time since boot, which keeps
/// counting while the phone sleeps and can't be set by hand. The wall clock is only used
/// across a restart, when time since boot starts over.
struct InviteClock: Sendable {
	struct Reading: Codable, Equatable, Sendable {
		/// Which boot this is; nil when the system doesn't say.
		var boot: String?
		/// Nanoseconds since that boot.
		var sinceBoot: UInt64
		var wall: Date
	}

	var now: @Sendable () -> Reading

	static let system = InviteClock {
		Reading(boot: bootSession, sinceBoot: clock_gettime_nsec_np(CLOCK_MONOTONIC), wall: Date())
	}

	private static let bootSession: String? = {
		var size = 0
		guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
		var buffer = [CChar](repeating: 0, count: size)
		guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
		let id = String(cString: buffer)
		return id.isEmpty ? nil : id
	}()
}

/// Invites waiting for a tap on "Join". Kept on the phone only.
@MainActor
final class GroupInviteStore: ObservableObject {
	static let shared = GroupInviteStore()

	struct Pending: Codable, Identifiable, Equatable {
		var invite: GroupInvite
		var fromNum: Int64
		/// Seconds it has waited, counted on `InviteClock`.
		var age: TimeInterval = 0
		var id: String { invite.id }

		init(invite: GroupInvite, fromNum: Int64, age: TimeInterval = 0) {
			self.invite = invite
			self.fromNum = fromNum
			self.age = age
		}

		private enum CodingKeys: String, CodingKey {
			case invite, fromNum, age, received
		}

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			invite = try container.decode(GroupInvite.self, forKey: .invite)
			fromNum = try container.decode(Int64.self, forKey: .fromNum)
			if let age = try container.decodeIfPresent(TimeInterval.self, forKey: .age) {
				self.age = max(0, age)
			} else {
				// Saved by an earlier version, which stamped it by the wall clock: read that
				// once (the store then saves it with its age), and never as a negative age.
				let wall = decoder.userInfo[.pangeaInviteWall] as? Date ?? Date()
				(decoder.userInfo[.pangeaInviteLegacy] as? DecodeLoss)?.happened = true
				let received = try container.decodeIfPresent(Date.self, forKey: .received) ?? wall
				age = max(0, wall.timeIntervalSince(received))
			}
		}

		func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(invite, forKey: .invite)
			try container.encode(fromNum, forKey: .fromNum)
			try container.encode(age, forKey: .age)
		}
	}

	/// One saved invite, or nil when it can't be read. Never throws, so the list goes on past it.
	private struct LossyPending: Decodable {
		let value: Pending?

		init(from decoder: Decoder) {
			value = try? Pending(from: decoder)
		}
	}

	@Published private(set) var pending: [Pending] = []
	private let key: String
	private let defaults: UserDefaults
	private let clock: InviteClock
	/// The reading the ages were last brought up to.
	private var checkpoint: InviteClock.Reading?

	/// Waiting invites from one person, so nobody can bury the list (or the lock screen) in invites.
	static let maxPerSender = 3
	static let maxPending = 20
	/// Waiting invites older than this are dropped, so a full list frees up on its own.
	static let maxAge: TimeInterval = 7 * 24 * 60 * 60
	/// The most a restart can age invites by: the wall clock is all there is to go on then.
	static let maxRestartGap: TimeInterval = 24 * 60 * 60
	/// Invite notifications per hour; past that one "new invites" notification stands in for the rest.
	static let maxNotificationsPerHour = 3

	private var notified: [ContinuousClock.Instant] = []

	init(defaults: UserDefaults = .standard, key: String = "pangeaPendingGroupInvites", clock: InviteClock = .system) {
		self.defaults = defaults
		self.key = key
		self.clock = clock
		let legacy = DecodeLoss()
		let decoder = JSONDecoder()
		decoder.userInfo[.pangeaInviteWall] = clock.now().wall
		decoder.userInfo[.pangeaInviteLegacy] = legacy
		if let data = defaults.object(forKey: key) as? Data {
			// Entry by entry, so one that can't be read doesn't lose the rest.
			let saved = try? decoder.decode([LossyPending].self, from: data)
			pending = saved?.compactMap(\.value) ?? []
			if saved == nil || saved?.contains(where: { $0.value == nil }) == true {
				// Kept aside before anything is saved over it.
				keepUnreadable(data)
			}
		} else if let raw = defaults.object(forKey: key) {
			// Not a saved list at all: nothing to read, but kept aside all the same.
			keepUnreadable(raw)
		}
		// Kept by an earlier version that checked less (a key anyone could read, say).
		let before = pending.count
		pending.removeAll { !GroupInvite.isJoinable($0.invite) }
		checkpoint = defaults.data(forKey: checkpointKey).flatMap { try? JSONDecoder().decode(InviteClock.Reading.self, from: $0) }
		// Ages read from an earlier version's wall-clock stamps are saved as ages now, or
		// the next launch would read the stamp again and count the time since twice.
		let unsaved = legacy.happened || (checkpoint == nil && !pending.isEmpty) || pending.count != before
		advance()
		if unsaved { save() }
	}

	private var checkpointKey: String { key + ".clock" }

	/// Copies of saved lists that couldn't all be read: the latest `maxUnreadable` that differ,
	/// oldest first. Kept until the radio is forgotten (`removeAll`).
	var unreadableKeys: [String] {
		(0..<Self.maxUnreadable).map { $0 == 0 ? key + ".unreadable" : key + ".unreadable.\($0 + 1)" }
	}
	static let maxUnreadable = 3

	/// `raw` is whatever was saved under the list's key (a plist value).
	private func keepUnreadable(_ raw: Any) {
		let keys = unreadableKeys
		guard !keys.contains(where: { (defaults.object(forKey: $0) as? NSObject)?.isEqual(raw) == true }) else { return }
		if let free = keys.first(where: { defaults.object(forKey: $0) == nil }) {
			defaults.set(raw, forKey: free)
			Logger.pangea.error("👥 [Groups] Some saved invites couldn't be read; kept a copy as \(free, privacy: .public)")
			return
		}
		// All full: the oldest goes, so the copy of what's about to be saved over is kept.
		for (older, newer) in zip(keys, keys.dropFirst()) {
			defaults.set(defaults.object(forKey: newer), forKey: older)
		}
		defaults.set(raw, forKey: keys[keys.count - 1])
		Logger.pangea.error("👥 [Groups] Some saved invites couldn't be read; kept a copy as \(keys[keys.count - 1], privacy: .public); dropped the oldest")
	}

	/// Returns true if the invite was new and kept.
	@discardableResult
	func add(_ invite: GroupInvite, from num: Int64, notify shouldNotify: Bool = true) -> Bool {
		guard GroupInvite.isJoinable(invite) else { return false }
		advance()
		let fromThem = pending.filter { $0.fromNum == num }.count
		// The same group is name and key (see `GroupInvite ==`): another name on the same key
		// is another group, so a decoy sent first can't keep the real invite out.
		guard !pending.contains(where: { $0.invite == invite }), fromThem < Self.maxPerSender else { return false }
		if pending.count >= Self.maxPending {
			// Full. Someone who already has invites waiting waits for those. Anyone else
			// takes the place of the oldest invite from whoever has the most waiting, so a
			// flood only ever pushes out the flooder's own invites.
			guard fromThem == 0 else { return false }
			let counts = Dictionary(grouping: pending, by: \.fromNum).mapValues(\.count)
			guard let most = counts.values.max(), most > 1,
				  let oldest = pending.lastIndex(where: { counts[$0.fromNum] == most }) else { return false }
			pending.remove(at: oldest)
		}
		pending.insert(Pending(invite: invite, fromNum: num), at: 0)
		save()
		if shouldNotify {
			notify(invite, from: num)
		}
		return true
	}

	/// Ages every waiting invite by the time since the last look, and drops the ones past
	/// `maxAge`. Within one boot that's time since boot, so setting the clock, either way,
	/// changes nothing. Across a restart the wall clock is trusted for at most a day, so a
	/// wrong clock then can neither drop every invite at once nor keep one for ever.
	func advance() {
		let now = clock.now()
		var elapsed: TimeInterval = 0
		if let checkpoint {
			// Without a boot id on either reading, time since boot that went forward is taken
			// as this boot's: if it was a restart, the new boot's time is less than the time
			// that really passed, so it can only count short. It never trusts the wall clock.
			let sameOrUnknownBoot = now.boot == nil || checkpoint.boot == nil || now.boot == checkpoint.boot
			if sameOrUnknownBoot, now.sinceBoot >= checkpoint.sinceBoot {
				elapsed = TimeInterval(now.sinceBoot - checkpoint.sinceBoot) / 1_000_000_000
			} else {
				elapsed = min(max(0, now.wall.timeIntervalSince(checkpoint.wall)), Self.maxRestartGap)
			}
		}
		checkpoint = now
		if let data = try? JSONEncoder().encode(now) {
			defaults.set(data, forKey: checkpointKey)
		}
		let before = pending
		if elapsed > 0 {
			for index in pending.indices {
				pending[index].age += elapsed
			}
		}
		pending.removeAll { $0.age > Self.maxAge }
		if pending != before { save() }
	}

	/// When it came, for showing "2 hours ago": its age back from the last look, so a
	/// clock that was wrong when it came doesn't show it as "in 1 year".
	func received(_ item: Pending) -> Date {
		(checkpoint?.wall ?? Date()).addingTimeInterval(-item.age)
	}

	/// The radio these invites arrived on is gone, and so are the copies kept of lists that
	/// couldn't be read: they hold its groups' keys too.
	func removeAll() {
		for key in unreadableKeys {
			defaults.removeObject(forKey: key)
		}
		pending = []
		save()
	}

	/// Whether an invite arriving now gets its own notification. On the monotonic clock,
	/// so setting the phone's clock back can't hold notifications off.
	func mayNotify(now: ContinuousClock.Instant = .now) -> Bool {
		notified = notified.filter { now - $0 < .seconds(60 * 60) }
		guard notified.count < Self.maxNotificationsPerHour else { return false }
		notified.append(now)
		return true
	}

	private func notify(_ invite: GroupInvite, from num: Int64) {
		guard mayNotify() else {
			// Same identifier each time, so extras replace one notification instead of piling up.
			let content = UNMutableNotificationContent()
			content.title = String(localized: "Group Invites")
			content.body = String(localized: "You have new group invites.")
			UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pangea.invite.more", content: content, trigger: nil))
			return
		}
		let sender = existingUser(num: num, context: PersistenceController.shared.context)?.longName ?? PangeaCode.code(for: num)

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

	/// The waiting invite to this group, once you're in it. One to the same key under
	/// another name is another group, and stays.
	func remove(invite: GroupInvite) {
		guard pending.contains(where: { $0.invite == invite }) else { return }
		pending.removeAll { $0.invite == invite }
		save()
	}

	private func save() {
		if let data = try? JSONEncoder().encode(pending) {
			defaults.set(data, forKey: key)
		}
	}
}

extension CodingUserInfoKey {
	/// The wall clock as the invite store reads it, for invites saved by an earlier version.
	static let pangeaInviteWall = CodingUserInfoKey(rawValue: "pangeaInviteWall")!
	/// A `DecodeLoss` set when an invite saved by an earlier version was read.
	static let pangeaInviteLegacy = CodingUserInfoKey(rawValue: "pangeaInviteLegacy")!
}

extension MyInfoEntity {
	/// Pangea: the radio's channels in slot order, one per slot. SwiftData keeps the list
	/// unordered, and an older app version could leave a second row for a slot.
	var sortedChannels: [ChannelEntity] {
		canonicalValidUniqueChannels(from: channels.filter { !$0.isDeleted })
	}
}
