//
//  ProfileSync.swift
//  Pangea
//
//  Sends my card to the people I talk to, and fetches photos only when asked.
//
//  - DMs: my card goes along, privately, after a message to someone who doesn't
//    have its latest version.
//  - Groups: my card goes to the group after I post, at most once a day unless it changed.
//  - Photos: never pushed. Their app asks and I send it in pieces: privately when
//    asked privately, or once to a group when asked there. They check every piece
//    against my card, and keep it.
//  - Private replies (my card back, my photo) only go to people I've messaged
//    or who are in one of my groups, never to someone who just found my key.
//  - A card heard in a group can't replace one that came privately from their key,
//    since anyone in a group can send one in their name. If it differs, I ask them
//    privately for their card instead.
//  - Everyone Nearby (the public channel), and any other channel without a private key,
//    never sees any of this.
//  - Everything but photo pieces waits in one outbox (`ProfileOutbox`), which spreads it
//    out, caps it, and works out what to send only when it goes.
//

import Foundation
import CoreData
import MeshtasticProtobufs
import OSLog

@MainActor
enum ProfileSync {

	/// A photo I asked someone for, checked piece by piece against the card it was asked for.
	private struct Transfer {
		var download: PhotoDownload
		/// When to ask again or give up (see `PhotoWatchdog`).
		var clock = PhotoWatchdog.Clock(lastActivity: .now)
		var route: Route
		/// For a download asked for in a group, that group's identity (see `groupKey`): the
		/// slot alone may hold a different group by the time pieces come or I ask again.
		var groupKey: String?
	}

	typealias Route = ProfileRoute

	/// How a send went. Only `noRadio` means nothing else can go out either.
	enum SendResult {
		case sent
		/// No radio connected.
		case noRadio
		/// This one didn't go (no key for them, or the radio refused it).
		case failed
	}

	private static var transfers: [Int64: Transfer] = [:]
	/// Cards and asks waiting to go out.
	private static var outbox = ProfileOutbox()
	private static var photoLimiter = PhotoSendLimiter()
	/// Sends what's in the outbox and the photo pieces queued, one at a time.
	private static var lane: Task<Void, Never>?
	/// Which run of `lane` is current, so one stopped by `reset` doesn't clear its successor.
	private(set) static var laneRun = 0
	/// The lane's sleep until the next thing is due; queuing something sooner cuts it short.
	private static var napping: Task<Void, Never>?
	/// The lane stopped because the radio was gone; what's queued waits for it to be ready again.
	private static var waitingForRadio = false
	/// The lane's last wait after a send found no radio while still linked (see
	/// `ProfileRules.afterNoRadio`), and when that wait is over: nothing is tried before then,
	/// whatever wakes the lane. Cleared once something goes or the radio is ready again.
	private static var backoff: Duration?
	private static var backoffUntil: ContinuousClock.Instant?
	/// Every edge of `AccessoryManager.readiness`, either way, so the lane can tell a send
	/// that failed across a drop and reconnect from one this same link refused.
	private static var readinessEdges = 0
	private static var watchdog: Task<Void, Never>?
	/// My photo, cut up for sending, for the version saved as mine.
	private static var outgoing: PhotoPieces?

	private static var accessoryManager: AccessoryManager { AccessoryManager.shared }

	private static var myUser: UserEntity? {
		guard let num = accessoryManager.activeDeviceNum else { return nil }
		return getNodeInfo(id: num, context: accessoryManager.context)?.user
	}

	private static var myPhotoPieces: PhotoPieces? {
		let version = ProfileStore.shared.me.photoVersion
		guard version != 0 else { return nil }
		if let outgoing, outgoing.version == version { return outgoing }
		outgoing = ProfileStore.shared.myPhotoData.flatMap(PhotoPieces.init(photo:))
		return outgoing
	}

	static var myCard: ProfileCard? {
		guard let me = myUser else { return nil }
		return ProfileStore.shared.me.card(fallbackName: me.longName ?? "", photo: myPhotoPieces)
	}

	/// The radio can take a packet now. Every send decision reads this first: without a
	/// radio, my card, my groups and whom I've messaged all read as gone, which must never
	/// be taken as "nobody needs this". Read live; if `AccessoryManager.readiness` says
	/// otherwise, it missed a change, and is brought up to date here.
	/// That may run `radioReadinessChanged` synchronously: read it (or `readiness`) before
	/// checking or copying `lane`, `waitingForRadio`, `backoff*`, `transfers`, `outbox`,
	/// `pushWhenBack` or `pendingRadioName`.
	static var radioReady: Bool {
		let ready = accessoryManager.radioReadyNow
		if ready != accessoryManager.readiness.value.ready { accessoryManager.refreshRadioReady() }
		return ready
	}

	/// The radio as `AccessoryManager.readiness` has it, checked against the live inputs first.
	private static var readiness: RadioReadiness {
		_ = radioReady
		return accessoryManager.readiness.value
	}

	/// Linked and done connecting, whether or not my own node is known yet.
	private static var radioLinked: Bool {
		accessoryManager.activeConnection != nil && accessoryManager.state == .subscribed
	}

	/// Every change of `AccessoryManager.readiness`, once it's set. Ready again: whatever
	/// waited goes, whether or not a screen is up to notice.
	static func radioReadinessChanged(_ edge: RadioReadiness.Edge) {
		readinessEdges += 1
		guard case .becameReady(let awayFor) = edge else { return }
		waitingForRadio = false
		backoff = nil
		backoffUntil = nil
		// Time without the radio isn't time a sender took between pieces.
		if let awayFor {
			let now = ContinuousClock.now
			for num in transfers.keys {
				transfers[num]?.clock.radioBack(awaySince: now - awayFor, now: now)
			}
		}
		startLane()
		if pushWhenBack {
			pushWhenBack = false
			pushUpdatedCard()
		}
		applyPendingName()
	}

	// MARK: Kept until the radio is back, across launches

	/// Where the name and push waiting for the radio are kept; tests use their own.
	static var defaults: UserDefaults = .standard

	private static let pendingNameKey = "pangeaPendingRadioName"
	private static let pushWhenBackKey = "pangeaPushCardWhenBack"

	static var pendingRadioName: String? {
		get { defaults.string(forKey: pendingNameKey) }
		set {
			nameWrites += 1
			defaults.set(newValue, forKey: pendingNameKey)
		}
	}
	/// Every write of `pendingRadioName`, so a failed apply can tell a newer name came meanwhile.
	private static var nameWrites = 0
	/// Every `reset`, so an apply that ends after a Forget or a switch can tell its radio is gone.
	private static var radioGeneration = 0
	/// The last name write started, for tests to wait on.
	private(set) static var nameApply: Task<Void, Never>?

	/// An edit came while the radio couldn't take a packet (gone, or restarting to take a
	/// new name): my card goes to everyone once it's ready again.
	private(set) static var pushWhenBack: Bool {
		get { defaults.bool(forKey: pushWhenBackKey) }
		set { defaults.set(newValue, forKey: pushWhenBackKey) }
	}

	/// The radio a held push was for is gone (see `RadioPairing.clearRadioData`).
	static func forgetHeldPush() {
		pushWhenBack = false
	}

	/// Writes a name to the radio; tests use their own.
	static var applyName: @MainActor (String) async throws -> Void = { name in
		_ = try await RadioAutoConfig.apply(name: name, region: nil, accessoryManager: .shared)
	}

	/// Saves a name set on this device to the radio, then pushes my card. A write that fails
	/// keeps the name for next time, unless a newer name was set meanwhile or the radio was
	/// forgotten or switched; one that ends after that pushes nothing for the next radio.
	static func applyPendingName() {
		guard let name = pendingRadioName else { return }
		pendingRadioName = nil
		let ticket = nameWrites, generation = radioGeneration
		nameApply = Task {
			do {
				try await applyName(name)
				guard radioGeneration == generation else { return }
				pushUpdatedCard()
			} catch {
				if nameWrites == ticket && radioGeneration == generation {
					pendingRadioName = name
				} else {
					Logger.services.info("👤 [Profiles] A newer name or another radio took the place of one that couldn't be saved")
				}
				Logger.services.error("👤 [Profiles] Couldn't apply saved name: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	// MARK: Outgoing

	/// Hooked into every text message I send.
	static func didSendMessage(toUserNum: Int64, channel: Int32) {
		guard myCard?.payload != nil else { return }
		if toUserNum > 0 && toUserNum != Int64(Constants.maximumNodeNum) {
			guard let user = existingUser(num: toUserNum, context: accessoryManager.context), canReachDirectly(user) else { return }
			// Let the message itself go first.
			schedule(.card(.person(toUserNum)), reason: .myMessage, delay: ProfileOutbox.afterMessage)
		} else if let key = groupKey(channel) {
			schedule(.card(.group(channel, key: key)), reason: .myMessage, delay: ProfileOutbox.afterMessage)
		}
	}

	/// After editing my profile: refresh the people I've talked to lately.
	static func pushUpdatedCard() {
		// Who to send to can't be told without the radio (it may be restarting for a new name).
		guard radioReady else {
			pushWhenBack = true
			return
		}
		guard myCard?.payload != nil else { return }
		let context = accessoryManager.context
		let request = UserEntity.fetchRequest()
		request.predicate = NSPredicate(format: "lastMessage > %@ AND pkiEncrypted == YES", Date().addingTimeInterval(-14 * 24 * 60 * 60) as NSDate)
		request.sortDescriptors = [NSSortDescriptor(keyPath: \UserEntity.lastMessage, ascending: false)]
		request.fetchBatchSize = 32
		let myNum = accessoryManager.activeDeviceNum
		// lastMessage is also set by messages they send me, so check I've written to them.
		// The 8 most recent who pass, not the 8 most recent: people who only wrote to me
		// mustn't crowd out the ones I talk to. They can be many, so who passes is worked
		// out once for everyone, not with queries per person.
		let sharing = mayShareDirectly()
		var people = Array(((try? context.fetch(request)) ?? []).lazy
			.filter { $0.num != myNum && canReachDirectly($0) && sharing.contains($0.num) }
			.prefix(8)
			.map(\.num))
		// Saved contacts too, chat or no chat, while there's room.
		for num in ProfileStore.shared.contactNums where people.count < 8 && num != myNum && !people.contains(num) {
			guard let user = existingUser(num: num, context: context), canReachDirectly(user) else { continue }
			people.append(num)
		}
		for num in people {
			schedule(.card(.person(num)), reason: .myEdit, delay: ProfileOutbox.afterEdit)
		}

		if let num = myNum, let myInfo = getNodeInfo(id: num, context: context)?.myInfo {
			for channel in GroupChats.groups(in: myInfo) where channel.mostRecentPrivateMessage != nil {
				guard let key = groupKey(channel.index) else { continue }
				schedule(.card(.group(channel.index, key: key)), reason: .myEdit, delay: ProfileOutbox.afterEdit)
			}
		}
	}

	/// Queues a packet. What it carries is only worked out when it goes (see `deliver`),
	/// so an edit made while it waits goes out instead of what was current when it was queued.
	/// False when there's no room for another packet sent for `reason`.
	@discardableResult
	private static func schedule(_ item: ProfileOutbox.Item, reason: ProfileOutbox.Reason, delay: ClosedRange<Double>,
								 hint: ProfileCard? = nil, isReask: Bool = false) -> Bool {
		guard outbox.schedule(item, reason: reason, delay: delay, hint: hint, isReask: isReask, now: .now) else {
			Logger.services.info("👤 [Profiles] Outbox full for \(String(describing: reason), privacy: .public); dropped a profile packet")
			return false
		}
		startLane()
		return true
	}

	/// The radio this was all for is gone: nothing queued, downloading or sent from here
	/// belongs to the next one.
	static func reset() {
		radioGeneration += 1
		lane?.cancel()
		lane = nil
		laneRun += 1
		waitingForRadio = false
		backoff = nil
		backoffUntil = nil
		pushWhenBack = false
		outbox = ProfileOutbox()
		photoLimiter = PhotoSendLimiter()
		outgoing = nil
		for num in transfers.keys {
			abandon(num)
		}
	}

	/// What came of asking for someone's photo.
	enum PhotoAsk: Equatable {
		/// Asked; it's downloading.
		case started
		/// Already downloading, this same version.
		case alreadyGoing
		/// No radio to ask through.
		case noRadio
		/// `ProfileOutbox.maxTransfers` are already going.
		case busy
		/// No photo to ask for, or no way to reach them.
		case unavailable
	}

	/// The user tapped "Update" on someone's photo.
	@discardableResult
	static func requestPhoto(from num: Int64) -> PhotoAsk {
		let store = ProfileStore.shared
		guard let profile = store.profile(num), let card = profile.card, let download = PhotoDownload(card: card) else { return .unavailable }
		// Already on its way: asking again would only start it over.
		if let transfer = transfers[num], transfer.download.version == download.version { return .alreadyGoing }
		// Nothing can be asked without the radio, and nor can it tell which groups we share.
		guard radioReady else { return .noRadio }
		guard let route = route(to: num, profile: profile) else { return .unavailable }
		var groupKey: String?
		if case .group(let index) = route {
			guard let key = Self.groupKey(index) else { return .unavailable }
			groupKey = key
		}
		// A few at a time, so asking for photos can't crowd out everything else.
		let others = transfers.count - (transfers[num] == nil ? 0 : 1)
		guard others < ProfileOutbox.maxTransfers,
			  schedule(.photoAsk(num), reason: .photoAsk, delay: 0...0) else { return .busy }
		// Only once it's queued. The lane reads the transfer on a later turn, when the ask goes.
		store.downloading.insert(num)
		store.downloadProgress[num] = 0
		transfers[num] = Transfer(download: download, route: route, groupKey: groupKey)
		startWatchdog()
		return .started
	}

	/// The watchdog clock of a download going; tests set one to stand for time gone by.
	static func photoClock(of num: Int64) -> PhotoWatchdog.Clock? {
		transfers[num]?.clock
	}

	static func setPhotoClock(_ clock: PhotoWatchdog.Clock, of num: Int64) {
		transfers[num]?.clock = clock
	}

	static func canRequestPhoto(from num: Int64) -> Bool {
		guard let profile = ProfileStore.shared.profile(num), profile.card?.hasPhotoLayout == true else { return false }
		return route(to: num, profile: profile) != nil
	}

	private static func route(to num: Int64, profile: ContactProfile) -> Route? {
		let direct = existingUser(num: num, context: accessoryManager.context).map(canReachDirectly) ?? false
		return ProfileRules.requestRoute(
			canReachDirectly: direct,
			theyMessagedMe: direct && theyHaveMessaged(num),
			sharedGroup: currentGroup(of: profile)
		)
	}

	/// The group I last heard their card on, if I'm still in that same group.
	private static func currentGroup(of profile: ContactProfile) -> Int32? {
		guard let channel = profile.lastChannel, let key = profile.lastGroupKey, groupKey(channel) == key else { return nil }
		return channel
	}

	/// They've sent me a private message, so their app accepts my private requests.
	private static func theyHaveMessaged(_ num: Int64) -> Bool {
		guard let myNum = accessoryManager.activeDeviceNum else { return false }
		let request = MessageEntity.fetchRequest()
		request.predicate = NSPredicate(format: "fromUser.num == %lld AND toUser.num == %lld", num, myNum)
		request.fetchLimit = 1
		return ((try? accessoryManager.context.count(for: request)) ?? 0) > 0
	}

	private static func canReachDirectly(_ user: UserEntity) -> Bool {
		user.pkiEncrypted && !(user.publicKey ?? Data()).isEmpty
	}

	/// Whether this person may get my card or photo, given how they reached me.
	private static func mayShare(with num: Int64, over route: Route) -> Bool {
		// Replies on a group channel stay in the group, so the database only matters for private ones.
		if case .group = route { return ProfileRules.mayShare(over: route, iMessagedThem: false, inMyGroup: true, savedContact: false) }
		return ProfileRules.mayShare(over: route, iMessagedThem: iHaveMessaged(num), inMyGroup: isInMyGroups(num),
									 savedContact: ProfileStore.shared.isContact(num))
	}

	/// Whether they'd still get my card and photo with no private messages between us:
	/// a saved contact, or someone in one of my groups. Said when deleting the chat.
	static func keepsSharingWithoutChat(_ num: Int64) -> Bool {
		ProfileStore.shared.isContact(num) || isInMyGroups(num)
	}

	/// I've sent them a private message from this radio (texts and reactions both count).
	private static func iHaveMessaged(_ num: Int64) -> Bool {
		guard let myNum = accessoryManager.activeDeviceNum else { return false }
		let request = MessageEntity.fetchRequest()
		request.predicate = NSPredicate(format: "fromUser.num == %lld AND toUser.num == %lld", myNum, num)
		request.fetchLimit = 1
		return ((try? accessoryManager.context.count(for: request)) ?? 0) > 0
	}

	/// The connected radio, or the last one while it's away, so what's said about groups
	/// doesn't change while the radio is off.
	private static var myNumOrLast: Int64? {
		ChatsView.myNum(activeDeviceNum: accessoryManager.activeDeviceNum)
	}

	/// They've posted, or shared their card, in a Pangea group I'm in now.
	private static func isInMyGroups(_ num: Int64) -> Bool {
		guard let myNum = myNumOrLast,
			  let myInfo = getNodeInfo(id: myNum, context: accessoryManager.context)?.myInfo else { return false }
		let groups = GroupChats.groups(in: myInfo).filter(GroupChats.isPrivateGroup).map(\.index)
		guard !groups.isEmpty else { return false }
		if let profile = ProfileStore.shared.profile(num), currentGroup(of: profile) != nil {
			return true
		}
		let request = MessageEntity.fetchRequest()
		request.predicate = NSPredicate(format: "fromUser.num == %lld AND channel IN %@", num, groups.map { NSNumber(value: $0) })
		request.fetchLimit = 1
		return ((try? accessoryManager.context.count(for: request)) ?? 0) > 0
	}

	/// Everyone `mayShare(with:over: .direct)` lets have my card: those I've messaged, saved
	/// contacts, and those in a group I'm in now (`isInMyGroups`). A few fetches, however many people there are.
	private static func mayShareDirectly() -> Set<Int64> {
		guard let myNum = accessoryManager.activeDeviceNum else { return [] }
		let context = accessoryManager.context
		func people(_ predicate: NSPredicate) -> Set<Int64> {
			let request = UserEntity.fetchRequest()
			request.predicate = predicate
			return Set(((try? context.fetch(request)) ?? []).map(\.num))
		}
		var allowed = people(NSPredicate(format: "SUBQUERY(receivedMessages, $m, $m.fromUser.num == %lld).@count > 0", myNum))
		allowed.formUnion(ProfileStore.shared.contacts.filter { $0.value.isContact }.keys)
		guard let myInfo = getNodeInfo(id: myNum, context: context)?.myInfo else { return allowed }
		let groups = GroupChats.groups(in: myInfo).filter(GroupChats.isPrivateGroup).map(\.index)
		guard !groups.isEmpty else { return allowed }
		// Shared their card in one of them (`currentGroup`).
		var keys: [Int32: String] = [:]
		for index in groups where keys[index] == nil {
			keys[index] = groupKey(index)
		}
		for (num, profile) in ProfileStore.shared.contacts {
			if let channel = profile.lastChannel, let key = profile.lastGroupKey, keys[channel] == key {
				allowed.insert(num)
			}
		}
		allowed.formUnion(people(NSPredicate(format: "SUBQUERY(sentMessages, $m, $m.channel IN %@).@count > 0", groups.map { NSNumber(value: $0) })))
		return allowed
	}

	/// "index:name:key hash" for a Pangea group with a private key on my radio; nil for
	/// Everyone Nearby or anything else. The key hash tells apart two groups that reused a
	/// slot and name.
	private static func groupKey(_ index: Int32) -> String? {
		guard index > 0, let num = myNumOrLast,
			  let channel = (getNodeInfo(id: num, context: accessoryManager.context)?.myInfo?.channels?.array as? [ChannelEntity])?
				.first(where: { $0.index == index }),
			  GroupChats.isPrivateGroup(channel) else { return nil }
		return "\(index):\(channel.name ?? ""):\(PangeaWire.hash(channel.psk ?? Data()))"
	}


	@discardableResult
	private static func send(_ payload: Data, to num: Int64, route: Route, description: String) async -> SendResult {
		guard let me = myUser else { return .noRadio }
		var data = DataMessage()
		data.portnum = .privateApp
		data.payload = payload

		var packet = MeshPacket()
		packet.to = UInt32(truncatingIfNeeded: num)
		packet.from = UInt32(truncatingIfNeeded: me.num)
		packet.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		packet.priority = .background
		switch route {
		case .direct:
			guard let user = existingUser(num: num, context: accessoryManager.context), let key = user.publicKey, !key.isEmpty else { return .failed }
			packet.channel = 0
			packet.pkiEncrypted = true
			packet.publicKey = key
			packet.wantAck = true
		case .group(let index):
			packet.channel = UInt32(index)
			packet.wantAck = num != Int64(Constants.maximumNodeNum)
		}
		packet.decoded = data

		var toRadio = ToRadio()
		toRadio.packet = packet
		do {
			try await accessoryManager.send(toRadio, debugDescription: description)
			return .sent
		} catch AccessoryError.connectionFailed(let reason) {
			Logger.services.error("👤 [Profiles] Send failed, no radio: \(reason, privacy: .public)")
			return .noRadio
		} catch {
			Logger.services.error("👤 [Profiles] Send failed: \(error.localizedDescription, privacy: .public)")
			return .failed
		}
	}

	// MARK: Incoming

	/// Returns true when the packet was a Pangea profile message.
	@discardableResult
	static func handle(_ packet: MeshPacket) -> Bool {
		guard case let .decoded(data) = packet.payloadVariant else { return false }
		let payload = data.payload
		let isCard = payload.starts(with: PangeaWire.cardMagic)
		let isRequest = payload.starts(with: PangeaWire.requestMagic)
		let isManifest = payload.starts(with: PangeaWire.manifestMagic)
		let isChunk = payload.starts(with: PangeaWire.chunkMagic)
		let isCardRequest = payload.starts(with: PangeaWire.cardRequestMagic)
		guard isCard || isRequest || isManifest || isChunk || isCardRequest else { return false }

		let from = Int64(packet.from)
		guard from != accessoryManager.activeDeviceNum else { return true }

		// Only private DMs, or a Pangea group I'm in. Never the public channel.
		guard let route = ProfileRules.route(pkiEncrypted: packet.pkiEncrypted, to: packet.to, channel: packet.channel, isGroupChat: { groupKey($0) != nil }) else {
			return true
		}
		// A private packet must come from the key I already know for them.
		if route == .direct, !packet.publicKey.isEmpty,
		   let known = existingUser(num: from, context: accessoryManager.context)?.publicKey, !known.isEmpty, known != packet.publicKey {
			Logger.services.error("👤 [Profiles] Ignored a private packet signed with an unexpected key")
			return true
		}

		if isCard, let card = ProfileCard(payload: payload) {
			received(card, from: from, route: route)
		} else if isRequest, let request = PhotoRequest(payload: payload) {
			received(request, from: from, route: route)
		} else if isManifest, let manifest = PhotoManifest(payload: payload) {
			receivedPhotoPart(from: from, route: route) { $0.accept(manifest) }
		} else if isChunk, let chunk = PhotoChunk(payload: payload) {
			receivedPhotoPart(from: from, route: route) { $0.accept(chunk) }
		} else if isCardRequest {
			receivedCardRequest(from: from, route: route)
		}
		return true
	}

	private static func received(_ card: ProfileCard, from num: Int64, route: Route) {
		let store = ProfileStore.shared
		let accepted: Bool
		if case .group(let index) = route {
			accepted = store.receivedCard(card, from: num, channel: index, groupKey: groupKey(index))
		} else {
			accepted = store.receivedCard(card, from: num, channel: nil)
		}
		guard accepted else {
			// Their card came privately from their key, so this one can't replace it. It
			// may still mean they changed something: ask them, privately, for the real one.
			// Whoever sent it, the answer can only come from their key.
			// Everyone who heard it would ask at once, so the ask waits a while, and is
			// checked again before it goes (their real card may have come meanwhile).
			let user = existingUser(num: num, context: accessoryManager.context)
			if ProfileRules.asksForCard(heard: card, stored: store.profile(num)?.card, canReachDirectly: user.map(canReachDirectly) ?? false) {
				Logger.services.info("👤 [Profiles] Group card differs from their private one; asking them for it")
				schedule(.cardAsk(num), reason: .ask, delay: ProfileOutbox.ask, hint: card)
			} else {
				Logger.services.info("👤 [Profiles] Ignored a group card for someone whose private card I have")
			}
			return
		}
		Logger.services.info("👤 [Profiles] Got a card")

		// Swap cards: if they don't have mine yet, send it back. Only to people I talk
		// to; anyone can find my key, and a card shouldn't be the reply to a stranger.
		guard myCard?.payload != nil, mayShare(with: num, over: route) else { return }
		switch route {
		case .direct:
			schedule(.card(.person(num)), reason: .reply, delay: ProfileOutbox.cardBack)
		case .group(let index):
			guard let key = groupKey(index) else { return }
			schedule(.card(.group(index, key: key)), reason: .reply, delay: ProfileOutbox.cardBackToGroup)
		}
	}

	/// Someone asked for my card: a group card of mine they heard didn't match the one they
	/// have from me privately. Answered privately, to people I talk to, even if I think
	/// they have it already (they're asking because they may not).
	private static func receivedCardRequest(from num: Int64, route: Route) {
		guard route == .direct, mayShare(with: num, over: .direct), myCard?.payload != nil else { return }
		// Merges with a card back already waiting for them, so they get one copy.
		schedule(.card(.person(num)), reason: .answer, delay: ProfileOutbox.afterMessage)
	}

	/// Someone wants my photo. A request in a group is answered once, to the whole group:
	/// whoever else there is waiting takes the same pieces, and since anyone in a group
	/// can claim to be anyone, who asked doesn't change what goes out. A private request
	/// is answered privately, to that person's key.
	private static func received(_ request: PhotoRequest, from num: Int64, route: Route) {
		guard let pieces = myPhotoPieces, request.photoVersion == pieces.version,
			  mayShare(with: num, over: route) else { return }
		let audience: PhotoAudience
		switch route {
		case .direct:
			audience = .person(num)
		case .group(let index):
			guard let key = groupKey(index) else { return }
			audience = .group(channel: index, key: key)
		}
		let key = PhotoSendLimiter.Key(audience: audience, version: pieces.version)
		guard photoLimiter.admit(request.wanted, slotCount: pieces.slotCount, for: key, now: .now) else {
			Logger.services.info("👤 [Profiles] Skipped a photo request (sent enough lately, or too busy)")
			return
		}
		startLane()
	}

	/// Sends what's waiting, one packet at a time and at least `ProfileOutbox.spacing`
	/// apart so regular messages still get through: my own cards first, then the rest of
	/// the outbox taking turns with photo pieces (see `ProfileOutbox.next`). Already
	/// running, it just looks again, in case what was queued is due sooner than it's sleeping.
	private static func startLane() {
		// Waiting for the radio, unless it's back and the callback was missed. (During a
		// teardown the state still reads `.subscribed` with the link already gone.) Read
		// before looking at `lane`: bringing a stale `readiness` up to date runs
		// `radioReadinessChanged`, which may start the lane itself.
		let mayGo = !waitingForRadio || radioReady
		guard lane == nil else {
			napping?.cancel()
			return
		}
		guard mayGo else { return }
		waitingForRadio = false
		laneRun += 1
		let run = laneRun
		lane = Task {
			sending: while !Task.isCancelled {
				let now = ContinuousClock.now
				// Backing off: being woken doesn't end it (see `waitOutNoRadio`).
				if let until = backoffUntil, until > now {
					await nap(for: until - now)
					continue
				}
				let ready = outbox.sendableAt(now)
				if ready > now {
					await nap(for: ready - now)
					continue
				}
				switch outbox.next(now: now, piecesWaiting: !photoLimiter.isIdle) {
				case .entry(let entry):
					let edges = readinessEdges
					let result = await deliver(entry)
					guard !Task.isCancelled else { break sending }
					// The read first: it can bring `readiness` up to date, which is an edge.
					let readyAfter = radioReady
					let outcome = ProfileRules.outcome(of: result, readyAfter: readyAfter, sameLink: readinessEdges == edges)
					// No radio: it's back in the outbox, uncharged, until the radio is.
					guard outbox.finish(entry, outcome, at: .now) else {
						if outcome == .sent { sentOne() }
						continue
					}
					guard waitOutNoRadio() else { break sending }
				case .piece:
					// Before working out who it's for: with no radio, a group reads as gone.
					guard radioReady else {
						guard waitOutNoRadio() else { break sending }
						continue
					}
					guard let next = photoLimiter.next(now: now) else { continue }
					guard let pieces = myPhotoPieces, pieces.version == next.key.version,
						  let payload = pieces.payload(slot: next.slot),
						  let destination = destination(next.key.audience) else {
						// My photo changed, the group is gone, or I no longer have their key:
						// nobody can take the rest of this one.
						photoLimiter.cancel(next.key, unsent: next.slot)
						continue
					}
					let edges = readinessEdges
					let result = await send(payload, to: destination.num, route: destination.route, description: "👤 [Profiles] Sent photo part \(Int(next.slot) + 1)/\(pieces.slotCount)")
					guard !Task.isCancelled else { break sending }
					let readyAfter = radioReady
					switch ProfileRules.outcome(of: result, readyAfter: readyAfter, sameLink: readinessEdges == edges) {
					case .sent:
						photoLimiter.delivered(next.key)
						outbox.sentPhotoPiece(at: .now)
						sentOne()
					case .noRadio:
						// Kept for when it's back, with the airtime handed back.
						photoLimiter.putBack(next)
						guard waitOutNoRadio() else { break sending }
					case .failed, .notNeeded:
						// Only this one: the others queued can still go.
						photoLimiter.cancel(next.key, unsent: next.slot)
						Logger.services.info("👤 [Profiles] Stopped sending my photo to one group or person; the send failed")
					}
				case nil:
					guard let wake = outbox.nextWake(now: now, piecesWaiting: !photoLimiter.isIdle) else { break sending }
					// Until then: a cap held back is one wake-up, not one a second. Anything
					// queued meanwhile cuts it short (see the top of `startLane`).
					await nap(for: wake - now)
				}
			}
			if laneRun == run { lane = nil }
		}
	}

	/// Sleeps the lane, until `startLane` or `reset` wakes it.
	private static func nap(for duration: Duration) async {
		let sleep = Task<Void, Never> { try? await Task.sleep(for: duration) }
		napping = sleep
		await withTaskCancellationHandler {
			await sleep.value
		} onCancel: {
			sleep.cancel()
		}
		if napping == sleep { napping = nil }
	}

	/// No radio. What's queued stays, uncharged, photo pieces included, and goes once it's
	/// ready again (`radioReadinessChanged`). Pieces nobody waits for any more by then are
	/// dropped (`PhotoSendLimiter.maxWait`).
	private static func pauseForRadio() {
		waitingForRadio = true
		Logger.services.info("👤 [Profiles] Waiting for the radio to send profile packets")
	}

	/// A send found no radio (what it was is back in the outbox). Gone or still connecting:
	/// the lane pauses until it's back, and false says so. Still linked: tried again after a
	/// backoff, which the lane waits out before anything else, so it can't spin and can't
	/// stall while the radio is up.
	private static func waitOutNoRadio() -> Bool {
		guard let wait = ProfileRules.afterNoRadio(linked: radioLinked, lastBackoff: backoff) else {
			pauseForRadio()
			return false
		}
		backoff = wait
		backoffUntil = .now + wait
		Logger.services.info("👤 [Profiles] Radio linked but not taking profile packets; trying again in \(String(describing: wait), privacy: .public)")
		return true
	}

	/// Something went: the radio's taking packets.
	private static func sentOne() {
		backoff = nil
		backoffUntil = nil
	}

	/// Sends one outbox packet, worked out now (see `ProfileRules.stillNeeded`): my card as it
	/// is now, to someone who still needs it; an ask that's still worth asking; a photo ask
	/// for a download still going. Nil when there's nothing to send any more, which is only
	/// decided with a ready radio.
	private static func deliver(_ entry: ProfileOutbox.Entry) async -> SendResult? {
		guard radioReady else { return .noRadio }
		let store = ProfileStore.shared
		var facts = ProfileRules.SendFacts()
		switch entry.item {
		case .card(let target):
			guard let card = myCard, let payload = card.payload else { return nil }
			facts.myCardVersion = card.version
			switch target {
			case .person(let num):
				facts.sentCardVersion = store.profile(num)?.sentCardVersion
				facts.canReachDirectly = existingUser(num: num, context: accessoryManager.context).map(canReachDirectly) ?? false
				facts.mayShare = mayShare(with: num, over: .direct)
				guard ProfileRules.stillNeeded(entry, facts: facts) else { return nil }
				let result = await send(payload, to: num, route: .direct, description: entry.force ? "👤 [Profiles] Sent my card when asked" : "👤 [Profiles] Sent my card")
				// Stopped by `reset`: the radio it went through is gone, and the next one hasn't sent it.
				guard !Task.isCancelled else { return result }
				// Recorded only once it went, so a lost send is tried again next time instead of never.
				if result == .sent { store.markCardSent(card.version, to: num) }
				return result
			case .group(let index, let key):
				// Same slot, name and key as when it was queued.
				facts.sameGroup = groupKey(index) == key
				facts.needsGroupSend = store.needsGroupSend(key, version: card.version)
				guard ProfileRules.stillNeeded(entry, facts: facts) else { return nil }
				let result = await send(payload, to: Int64(Constants.maximumNodeNum), route: .group(index), description: "👤 [Profiles] Sent my card to group")
				guard !Task.isCancelled else { return result }
				if result == .sent { store.markGroupSent(key, version: card.version) }
				return result
			}
		case .cardAsk(let num):
			facts.canReachDirectly = existingUser(num: num, context: accessoryManager.context).map(canReachDirectly) ?? false
			facts.storedCard = store.profile(num)?.card
			guard ProfileRules.stillNeeded(entry, facts: facts) else { return nil }
			return await send(PangeaWire.cardRequestMagic, to: num, route: .direct, description: "👤 [Profiles] Asked for card")
		case .photoAsk(let num):
			facts.transferExists = transfers[num] != nil
			guard ProfileRules.stillNeeded(entry, facts: facts), let transfer = transfers[num] else { return nil }
			guard isStillAskedGroup(transfer) else {
				abandon(num)
				return nil
			}
			let request = PhotoRequest(photoVersion: transfer.download.version, wanted: entry.isReask ? transfer.download.missingSlots : nil)
			transfers[num]?.clock.asked(now: .now)
			return await send(request.payload, to: num, route: transfer.route, description: entry.isReask ? "👤 [Profiles] Asked again for photo" : "👤 [Profiles] Asked for photo")
		}
	}

	private static func destination(_ audience: PhotoAudience) -> (num: Int64, route: Route)? {
		switch audience {
		case .person(let num):
			// Their key can be gone (a node database reset); the send would fail for them alone.
			guard let user = existingUser(num: num, context: accessoryManager.context), canReachDirectly(user) else { return nil }
			return (num, .direct)
		case .group(let channel, let key):
			// Same slot, name and key as when they asked.
			guard groupKey(channel) == key else { return nil }
			return (Int64(Constants.maximumNodeNum), .group(channel))
		}
	}

	private static func receivedPhotoPart(from num: Int64, route: Route, _ accept: (inout PhotoDownload) -> PhotoDownload.Outcome) {
		// First: bringing `readiness` up to date can run `radioReadinessChanged`, which updates `transfers`.
		let radio = readiness
		guard var transfer = transfers[num], ProfileRules.photoPart(arrivedOver: route, fits: transfer.route) else { return }
		if case .group = route, !isStillAskedGroup(transfer) {
			// The slot it was asked in now holds another group.
			abandon(num)
			return
		}
		switch accept(&transfer.download) {
		case .ignored, .duplicate:
			// Nothing new. Not progress either, so a replayed piece can't hold off asking again.
			return
		case .held:
			// Kept to check once its manifest part comes; that part is what's missing.
			transfers[num] = transfer
			return
		case .added:
			// Still making progress, so don't count earlier retries against it.
			transfer.clock.pieceCame(now: .now, awaySince: radio.awaySince)
		}
		let store = ProfileStore.shared
		if transfer.download.isComplete {
			if let photo = transfer.download.assemble(), PhotoCompressor.isAcceptableAvatar(photo) {
				endTransfer(num, saved: true)
				store.savePhoto(photo, version: transfer.download.version, for: num)
				Logger.services.info("👤 [Profiles] Photo received")
			} else {
				// Every piece matched the card, yet it isn't a small image of that version:
				// the card itself was wrong. Asking again would bring the same bytes.
				Logger.services.error("👤 [Profiles] Received photo isn't a usable image; dropped")
				endTransfer(num, saved: false)
			}
			return
		}
		transfers[num] = transfer
		store.downloadProgress[num] = transfer.download.progress
	}

	/// Whether a download is still for the group it was asked in (always true for a private one).
	private static func isStillAskedGroup(_ transfer: Transfer) -> Bool {
		guard case .group(let index) = transfer.route else { return true }
		return ProfileRules.isSameGroup(askedIn: transfer.groupKey, now: groupKey(index))
	}

	private static func abandon(_ num: Int64) {
		endTransfer(num, saved: false)
	}

	/// A download is over: saved, given up, or not a usable image. Its queued ask goes with
	/// it, so it doesn't keep a photo ask's place. `saved`: `savePhoto` clears the spinner.
	private static func endTransfer(_ num: Int64, saved: Bool) {
		transfers[num] = nil
		outbox.remove(.photoAsk(num))
		guard !saved else { return }
		ProfileStore.shared.downloading.remove(num)
		ProfileStore.shared.downloadProgress[num] = nil
	}

	/// Re-asks for missing parts, and gives up after a few quiet tries, once the group it
	/// was asked in is gone from its slot (asking there again would ask strangers), or once
	/// the radio has been away too long.
	private static func startWatchdog() {
		guard watchdog == nil else { return }
		watchdog = Task {
			while !transfers.isEmpty {
				try? await Task.sleep(for: .seconds(10))
				// Before the clocks: bringing `readiness` up to date can update them.
				let radio = readiness
				let steps = PhotoWatchdog(clocks: transfers.mapValues(\.clock)).steps(
					now: .now, radio: radio,
					askQueued: { outbox.contains(.photoAsk($0)) },
					stillAskedGroup: { transfers[$0].map(isStillAskedGroup) ?? false })
				for (num, step) in steps {
					switch step {
					case .wait:
						continue
					case .giveUp:
						abandon(num)
					case .askAgain:
						// Through the outbox, so a dozen stalled downloads aren't asked for back to back.
						// A try only counts once it's queued.
						guard schedule(.photoAsk(num), reason: .photoAsk, delay: ProfileOutbox.reask, isReask: true) else { continue }
						transfers[num]?.clock.attempts += 1
						transfers[num]?.clock.asked(now: .now)
					}
				}
			}
			watchdog = nil
		}
	}
}

/// How a profile packet reaches someone: privately to their key, or inside a group they're in.
enum ProfileRoute: Equatable {
	case direct
	case group(Int32)
}

/// Who gets profile traffic. Kept apart from the radio and the database so it can be tested.
enum ProfileRules {

	/// How a profile packet arrived, or nil when it has to be ignored: anything on the
	/// public channel, or on a channel that isn't one of my Pangea groups.
	static func route(pkiEncrypted: Bool, to: UInt32, channel: UInt32, isGroupChat: (Int32) -> Bool) -> ProfileRoute? {
		if pkiEncrypted && to != Constants.maximumNodeNum {
			return .direct
		}
		let index = Int32(truncatingIfNeeded: channel)
		guard index > 0, isGroupChat(index) else { return nil }
		return .group(index)
	}

	/// How to ask someone for their photo. Their app answers a private request only if
	/// they've messaged me (or think I'm in their group); a request inside a group we
	/// share is always answered. So: private when they've messaged me, else the group.
	static func requestRoute(canReachDirectly: Bool, theyMessagedMe: Bool, sharedGroup: Int32?) -> ProfileRoute? {
		if canReachDirectly && theyMessagedMe { return .direct }
		if let sharedGroup { return .group(sharedGroup) }
		return canReachDirectly ? .direct : nil
	}

	/// My card and photo go to people I've messaged, people I saved to Contacts, and my
	/// groups. In a group, everyone who can read the channel is a member, so anything sent
	/// there stays there. A saved contact is trusted, so deleting our chat doesn't stop it.
	static func mayShare(over route: ProfileRoute, iMessagedThem: Bool, inMyGroup: Bool, savedContact: Bool) -> Bool {
		switch route {
		case .group:
			return true
		case .direct:
			return iMessagedThem || inMyGroup || savedContact
		}
	}

	/// A group download belongs to the group it was asked in: its identity then
	/// ("index:name:key hash") must still be what that slot holds now.
	static func isSameGroup(askedIn key: String?, now current: String?) -> Bool {
		key != nil && key == current
	}

	/// Whether a group card for someone whose card came privately from their key is worth
	/// asking them about: it says something else, and they can be reached privately. Both
	/// cards are already cleaned, so they're compared as they are (the sender's version
	/// hash is of what they sent, not of the cleaned card).
	static func asksForCard(heard: ProfileCard, stored: ProfileCard?, canReachDirectly: Bool) -> Bool {
		canReachDirectly && heard != stored
	}

	/// What's known when a queued packet comes up, for `stillNeeded`. Only what the item
	/// needs is filled in.
	struct SendFacts {
		/// My card's version now; nil when I have no card to send.
		var myCardVersion: UInt32?
		/// The version of my card they last got.
		var sentCardVersion: UInt32?
		var canReachDirectly = false
		/// They may get my card privately (see `mayShare`).
		var mayShare = false
		/// The group's slot holds the group it was queued for.
		var sameGroup = false
		/// The group hasn't had this card today.
		var needsGroupSend = false
		/// Their card as I have it, for an ask.
		var storedCard: ProfileCard?
		/// The photo download a photo ask is for is still going.
		var transferExists = false
	}

	/// Whether a packet that waited in the outbox is still worth sending, as things are when it goes.
	static func stillNeeded(_ entry: ProfileOutbox.Entry, facts: SendFacts) -> Bool {
		switch entry.item {
		case .card(.person):
			guard let version = facts.myCardVersion else { return false }
			// An answer goes even if they have it: they're asking because they may not.
			return facts.canReachDirectly && facts.mayShare && (entry.force || facts.sentCardVersion != version)
		case .card(.group):
			return facts.myCardVersion != nil && facts.sameGroup && facts.needsGroupSend
		case .cardAsk:
			// Their real card may have come while it waited.
			guard let hint = entry.hint else { return false }
			return asksForCard(heard: hint, stored: facts.storedCard, canReachDirectly: facts.canReachDirectly)
		case .photoAsk:
			return facts.transferExists
		}
	}

	/// The radio can take a packet: linked, done connecting, and my own node known.
	static func radioReady(hasConnection: Bool, state: AccessoryManagerState, hasMyUser: Bool) -> Bool {
		hasConnection && state == .subscribed && hasMyUser
	}

	/// How the lane books a send. Nil from `deliver` is "not needed any more", which it
	/// only decides with a ready radio. A send refused just as the radio went
	/// (`readyAfter`: whether it's ready once the send returned), or across a drop and
	/// reconnect (`sameLink`: no readiness edge while it was out), found no radio: it goes
	/// back, uncharged.
	static func outcome(of result: ProfileSync.SendResult?, readyAfter: Bool, sameLink: Bool) -> ProfileOutbox.Outcome {
		switch result {
		case nil: return .notNeeded
		case .sent?: return .sent
		case .noRadio?: return .noRadio
		case .failed?: return readyAfter && sameLink ? .failed : .noRadio
		}
	}

	/// After a send found no radio. Nil when it's gone or still connecting: the lane waits
	/// for it, and going back into `.subscribed` resumes it. Still linked (my own node not
	/// known yet, or a write that failed across a reconnect): how long to wait before trying
	/// again, from `ProfileOutbox.firstBackoff` doubling up to `maxBackoff`.
	static func afterNoRadio(linked: Bool, lastBackoff: Duration?) -> Duration? {
		guard linked else { return nil }
		guard let lastBackoff else { return ProfileOutbox.firstBackoff }
		return min(lastBackoff * 2, ProfileOutbox.maxBackoff)
	}

	enum PhotoRetry: Equatable {
		case wait, askAgain, giveUp
	}

	/// What the photo watchdog does with a download: nothing while pieces come or its ask is
	/// still queued (it hasn't failed, it's waiting its turn), else ask again, or give up after
	/// `ProfileOutbox.maxPhotoAttempts` quiet tries or once its group is gone from the slot.
	/// With the radio away nothing can come or be asked, so it waits without using a try,
	/// and gives up once the radio has been away `ProfileOutbox.maxRadioAway`.
	static func photoRetry(quietFor quiet: Duration, attempts: Int, askQueued: Bool, stillAskedGroup: Bool,
						   radioAwayFor away: Duration? = nil, longestGap: Duration = .zero) -> PhotoRetry {
		if let away { return away > ProfileOutbox.maxRadioAway ? .giveUp : .wait }
		guard quiet > photoPatience(longestGap: longestGap), !askQueued else { return .wait }
		return attempts >= ProfileOutbox.maxPhotoAttempts || !stillAskedGroup ? .giveUp : .askAgain
	}

	/// How long a download may go quiet before it's asked again: a minute, or, once pieces
	/// have come slowly (a sender busy with others takes turns between us), five times the
	/// longest wait so far, up to three minutes.
	static func photoPatience(longestGap: Duration) -> Duration {
		min(max(longestGap * 5, ProfileOutbox.minPhotoPatience), ProfileOutbox.maxPhotoPatience)
	}

	/// How long a sender took over a piece that just came: since the ask or the piece before
	/// it, less the time my radio was away meanwhile (`awayInGap`, outages already over, and
	/// since `awaySince` for one still going), when nothing could come.
	static func pieceGap(now: ContinuousClock.Instant, lastActivity: ContinuousClock.Instant, awayInGap: Duration,
						 awaySince: ContinuousClock.Instant?) -> Duration {
		let stillAway = awaySince.map { now - max($0, lastActivity) } ?? .zero
		return max(.zero, now - lastActivity - awayInGap - stillAway)
	}

	/// What saving my profile does next.
	enum SaveAction: Equatable {
		/// Save the new name to the radio (it's kept for later either way, see `pendingRadioName`).
		case applyName
		/// Send my card to the people and groups I talk to; held until the radio's ready if it isn't.
		case push
	}

	static func afterSave(nameChanged: Bool, meChanged: Bool, radioReady: Bool) -> [SaveAction] {
		var actions: [SaveAction] = []
		if nameChanged && radioReady { actions.append(.applyName) }
		if meChanged { actions.append(.push) }
		return actions
	}

	/// The line shown with a photo offer or download, when there's something to say.
	enum PhotoLine: Equatable {
		/// A download going while the radio's away.
		case waitingForRadio
		/// No radio to ask through.
		case connectRadio
		/// `ProfileOutbox.maxTransfers` are already going.
		case busy
	}

	/// `full`: as many downloads going as there may be. `lastAsk`: what the last tap here came to.
	static func photoLine(downloading: Bool, radioAway: Bool, full: Bool, lastAsk: ProfileSync.PhotoAsk?) -> PhotoLine? {
		if downloading { return radioAway ? .waitingForRadio : nil }
		if radioAway || lastAsk == .noRadio { return .connectRadio }
		if full || lastAsk == .busy { return .busy }
		return nil
	}

	/// Whether a photo part that arrived over `arrival` belongs to a download asked for
	/// over `requested`. A private download takes only private packets, which the radio
	/// checked came from their key. A group download takes its own group, or private
	/// packets from them. (Every part is also checked against their card.)
	static func photoPart(arrivedOver arrival: ProfileRoute, fits requested: ProfileRoute) -> Bool {
		switch requested {
		case .direct:
			return arrival == .direct
		case .group(let index):
			return arrival == .group(index) || arrival == .direct
		}
	}
}

/// When to ask again for a photo coming in, or give up on it, worked out for every download
/// at once from their clocks and the radio.
struct PhotoWatchdog {
	typealias Instant = ContinuousClock.Instant

	struct Clock: Equatable {
		/// The last ask or piece.
		private(set) var lastActivity: Instant
		var attempts = 1
		/// The longest wait for a piece so far, from the ask or the piece before it. A sender
		/// busy with others takes turns between us, so it goes longer quiet (see `ProfileRules.photoPatience`).
		var longestGap: Duration = .zero
		/// Time the radio was away since `lastActivity`, from outages already over.
		var awayInGap: Duration = .zero

		/// A piece came: still making progress, so earlier retries don't count against it.
		mutating func pieceCame(now: Instant, awaySince: Instant?) {
			longestGap = max(longestGap, ProfileRules.pieceGap(now: now, lastActivity: lastActivity, awayInGap: awayInGap, awaySince: awaySince))
			awayInGap = .zero
			attempts = 1
			lastActivity = now
		}

		/// Asked (again): a new gap starts, with none of the radio's time away in it yet.
		mutating func asked(now: Instant) {
			lastActivity = now
			awayInGap = .zero
		}

		/// The radio's ready again, after being away since `awaySince`.
		mutating func radioBack(awaySince: Instant, now: Instant) {
			awayInGap += max(.zero, now - max(awaySince, lastActivity))
		}
	}

	var clocks: [Int64: Clock]

	/// Every download's step, as of `now`, with the radio as `radio` says. Groups are only
	/// looked up with a radio: without one, every group reads as gone.
	func steps(now: Instant, radio: RadioReadiness, askQueued: (Int64) -> Bool, stillAskedGroup: (Int64) -> Bool) -> [Int64: ProfileRules.PhotoRetry] {
		let away: Duration? = radio.ready ? nil : (radio.awaySince.map { now - $0 } ?? .zero)
		var steps: [Int64: ProfileRules.PhotoRetry] = [:]
		for (num, clock) in clocks {
			steps[num] = ProfileRules.photoRetry(quietFor: now - clock.lastActivity, attempts: clock.attempts, askQueued: askQueued(num),
												 stillAskedGroup: away != nil || stillAskedGroup(num), radioAwayFor: away, longestGap: clock.longestGap)
		}
		return steps
	}
}

/// A photo coming in. The card it was asked for says how many pieces there are and
/// the tag of each manifest part; each manifest part gives the tag of each piece. So
/// nothing from the air is taken on trust: a part or piece that doesn't match is never
/// stored and never undoes progress, and the piece count never comes from a piece.
struct PhotoDownload {
	enum Outcome: Equatable {
		/// Checked and kept.
		case added
		/// Already have it.
		case duplicate
		/// Kept aside until its manifest part arrives to check it.
		case held
		/// Not part of this photo.
		case ignored
	}

	let version: UInt32
	let pieceCount: Int
	let partTags: [Data]
	private var tags: [Int: [Data]] = [:]
	private var pieces: [UInt8: Data] = [:]
	/// Pieces that came before their manifest part: a few different copies each, at most.
	private var unchecked: [UInt8: [Data]] = [:]

	static let maxUncheckedCopies = 3

	init?(card: ProfileCard) {
		guard card.hasPhotoLayout else { return nil }
		version = card.photoVersion
		pieceCount = Int(card.photoPieces)
		partTags = card.photoPartTags
	}

	var slotCount: Int { partTags.count + pieceCount }

	/// Slots still needed (manifest parts first, then pieces). A piece held unchecked
	/// isn't asked for again until its manifest part shows whether it was right.
	var missingSlots: Set<UInt8> {
		var missing = Set<UInt8>()
		for part in 0..<partTags.count where tags[part] == nil {
			missing.insert(UInt8(part))
		}
		for index in 0..<pieceCount where pieces[UInt8(index)] == nil && unchecked[UInt8(index)] == nil {
			missing.insert(UInt8(partTags.count + index))
		}
		return missing
	}

	var isComplete: Bool { pieces.count == pieceCount }

	var progress: Double {
		guard slotCount > 0 else { return 0 }
		return Double(tags.count + pieces.count) / Double(slotCount)
	}

	mutating func accept(_ manifest: PhotoManifest) -> Outcome {
		let part = Int(manifest.part)
		guard manifest.photoVersion == version, part < partTags.count else { return .ignored }
		if tags[part] != nil { return .duplicate }
		let covered = min(PhotoManifest.tagsPerPart, pieceCount - part * PhotoManifest.tagsPerPart)
		guard manifest.tags.count == covered, manifest.tag == partTags[part] else { return .ignored }
		tags[part] = manifest.tags
		// Check the pieces that came early; the ones that don't match are asked for again.
		for offset in 0..<covered {
			let index = UInt8(part * PhotoManifest.tagsPerPart + offset)
			if let copies = unchecked.removeValue(forKey: index), let right = copies.first(where: { PangeaWire.tag($0) == manifest.tags[offset] }) {
				pieces[index] = right
			}
		}
		return .added
	}

	mutating func accept(_ chunk: PhotoChunk) -> Outcome {
		guard chunk.photoVersion == version, Int(chunk.index) < pieceCount else { return .ignored }
		if pieces[chunk.index] != nil { return .duplicate }
		let part = Int(chunk.index) / PhotoManifest.tagsPerPart
		guard let pieceTags = tags[part] else {
			var copies = unchecked[chunk.index] ?? []
			guard !copies.contains(chunk.bytes), copies.count < Self.maxUncheckedCopies else { return .ignored }
			copies.append(chunk.bytes)
			unchecked[chunk.index] = copies
			return .held
		}
		guard PangeaWire.tag(chunk.bytes) == pieceTags[Int(chunk.index) % PhotoManifest.tagsPerPart] else { return .ignored }
		pieces[chunk.index] = chunk.bytes
		return .added
	}

	/// The photo, once every piece is in and it's the version the card named.
	func assemble() -> Data? {
		PhotoChunk.assemble(pieces, count: UInt8(pieceCount), version: version)
	}
}

/// Who a photo send is for: a group channel (one broadcast every member there takes),
/// or one person, privately to their key.
enum PhotoAudience: Hashable {
	case group(channel: Int32, key: String)
	case person(Int64)

	var isGroup: Bool {
		if case .group = self { return true }
		return false
	}
}

/// Decides which photo pieces go on the air, and in what order. Budgets are per group
/// and per person, for one photo version, with groups and people kept apart:
/// - Anyone in a group can claim to be anyone, so group sends are keyed by the group,
///   never by who asked. Spoofed requests can't do more than one real member's.
/// - Private requests come from a key the radio checked, so they're budgeted per person,
///   and group traffic can never use up what's set aside for them, or the other way round.
/// - A request for pieces already queued for the same group or person adds nothing.
/// - A new photo version gets a new allowance.
/// - Time is the monotonic clock, so changing the phone's clock can't stretch a window.
struct PhotoSendLimiter {
	typealias Instant = ContinuousClock.Instant

	struct Key: Hashable {
		var audience: PhotoAudience
		var version: UInt32
	}

	static let window: Duration = .seconds(15 * 60)
	/// Each group, and each person, can get the whole photo twice per window, so one lost send can be redone.
	static let photosPerKey = 2
	/// Across all groups, and separately across all people.
	static let photosPerClass = 3
	/// That as airtime: slots of any photo, old or new, counted against the largest photo's
	/// worth, so slots already sent of a bigger old photo don't shut out a small new one.
	static let classSlots = PhotoRequest.maxSlots * photosPerClass
	/// Groups and people waiting at once.
	static let maxQueued = 4
	/// Between pieces, so regular messages still get through.
	static let spacing: Duration = .seconds(3)
	/// Their app gives up after about four quiet minutes.
	static let maxWait: Duration = .seconds(240)

	private struct Job {
		var key: Key
		var remaining: Set<UInt8>
		/// When it was last asked for or last handed out a piece.
		var lastProgress: Instant
	}

	private var jobs: [Job] = []
	private var sent: [(key: Key, at: Instant)] = []
	private var turn = 0
	/// Whose piece `next` handed out, until it's `delivered`, put back or cancelled: its job
	/// may be gone (that was its last piece) and come back on `putBack`, so it keeps its place.
	private var inFlight: Key?

	var isIdle: Bool { jobs.isEmpty }

	/// Groups and people waiting.
	var queuedCount: Int { jobs.count }

	/// Pieces sent to this group or person within `window`, the one handed out included.
	func charged(_ key: Key, now: Instant) -> Int {
		sent.filter { $0.key == key && now - $0.at < Self.window }.count
	}

	/// Pieces sent to all groups, or all people, within `window`.
	func charged(groups: Bool, now: Instant) -> Int {
		sent.filter { $0.key.audience.isGroup == groups && now - $0.at < Self.window }.count
	}

	/// Slots still to go for this group or person.
	func queued(for key: Key) -> Set<UInt8> {
		jobs.first { $0.key == key }?.remaining ?? []
	}

	/// Queues the wanted slots (nil: all of them). False when the request is ignored.
	mutating func admit(_ wanted: Set<UInt8>?, slotCount: Int, for key: Key, now: Instant) -> Bool {
		guard slotCount > 0, slotCount <= Int(UInt8.max) else { return false }
		let all = Set((0..<slotCount).map { UInt8($0) })
		let asked = wanted.map { $0.intersection(all) } ?? all
		guard !asked.isEmpty else { return false }
		sent.removeAll { now - $0.at >= Self.window }

		let existing = jobs.firstIndex { $0.key == key }
		let new = asked.subtracting(existing.map { jobs[$0].remaining } ?? [])
		// Already on its way to them. Asked for again: they're still waiting, so it's progress.
		guard !new.isEmpty else {
			if let existing { jobs[existing].lastProgress = now }
			return true
		}
		// The piece handed out holds its job's place while it's out, unless that job is queued.
		let held = inFlight.map { flight in flight != key && !jobs.contains { $0.key == flight } } ?? false
		guard existing != nil || jobs.count + (held ? 1 : 0) < Self.maxQueued else { return false }

		let forKey = sent.filter { $0.key == key }.count + (existing.map { jobs[$0].remaining.count } ?? 0)
		guard forKey + new.count <= slotCount * Self.photosPerKey else { return false }
		let isGroup = key.audience.isGroup
		let forClass = sent.filter { $0.key.audience.isGroup == isGroup }.count
			+ jobs.filter { $0.key.audience.isGroup == isGroup }.reduce(0) { $0 + $1.remaining.count }
		guard forClass + new.count <= Self.classSlots else { return false }

		if let existing {
			jobs[existing].remaining.formUnion(new)
			jobs[existing].lastProgress = now
		} else {
			jobs.append(Job(key: key, remaining: new, lastProgress: now))
		}
		return true
	}

	/// The next slot to send, taking turns between groups and people. It's counted as
	/// sent now; call `putBack` if it doesn't go out.
	mutating func next(now: Instant) -> (key: Key, slot: UInt8)? {
		// One held up that long (no radio), started or not, is skipped: they've given up
		// waiting, and ask again for whatever they still miss.
		jobs.removeAll { now - $0.lastProgress > Self.maxWait }
		guard !jobs.isEmpty else { return nil }
		let index = turn % jobs.count
		guard let slot = jobs[index].remaining.min() else {
			jobs.remove(at: index)
			return next(now: now)
		}
		let key = jobs[index].key
		jobs[index].remaining.remove(slot)
		jobs[index].lastProgress = now
		sent.append((key: key, at: now))
		inFlight = key
		if jobs[index].remaining.isEmpty {
			jobs.remove(at: index)
			turn = index
		} else {
			turn = index + 1
		}
		return (key: key, slot: slot)
	}

	/// Nobody wants the rest of this one. `unsent` was handed out by `next` but didn't go.
	mutating func cancel(_ key: Key, unsent: UInt8) {
		if inFlight == key { inFlight = nil }
		refund(key)
		jobs.removeAll { $0.key == key }
	}

	/// The piece `next` handed out for `key` went.
	mutating func delivered(_ key: Key) {
		if inFlight == key { inFlight = nil }
	}

	/// A piece `next` handed out couldn't go (no radio): it's queued again, uncharged, with
	/// everything else still queued, for when the radio's back.
	mutating func putBack(_ unsent: (key: Key, slot: UInt8)) {
		if inFlight == unsent.key { inFlight = nil }
		guard let handedOut = refund(unsent.key) else { return }
		if let index = jobs.firstIndex(where: { $0.key == unsent.key }) {
			jobs[index].remaining.insert(unsent.slot)
		} else {
			// It was that job's last piece; `admit` kept its place while it was out.
			jobs.append(Job(key: unsent.key, remaining: [unsent.slot], lastProgress: handedOut))
			assert(jobs.count <= Self.maxQueued)
		}
	}

	/// Takes back the last piece sent to `key`; when it was handed out.
	@discardableResult
	private mutating func refund(_ key: Key) -> Instant? {
		guard let last = sent.lastIndex(where: { $0.key == key }) else { return nil }
		return sent.remove(at: last).at
	}
}

/// Where my card goes: one person privately, or a group ("index:name:key hash").
enum CardTarget: Hashable {
	case person(Int64)
	case group(Int32, key: String)
}

/// Every profile packet but photo pieces waits here before it goes on the air (pieces
/// take turns with them, see `next`). Whatever the packet, it's:
/// - spread out: a random delay when it's queued, and a gap between any two packets
/// - queued once: queuing the same thing again merges into what's already waiting
/// - kept apart by why it goes (`Reason`): each reason has its own room here, its own cap
///   across everyone, and its own turn on the lane, so one kind of traffic can't crowd out
///   or hold up another
/// - charged only for airtime used: a send that never happened, or that was dropped
///   because it wasn't needed any more, counts for nothing
/// - kept while the radio is away, and sent once it's back
/// What a packet carries is worked out when it goes, not here. Time is the monotonic
/// clock and randomness is passed in, so it can be tested without a radio.
struct ProfileOutbox {
	typealias Instant = ContinuousClock.Instant

	enum Item: Hashable {
		/// My card. One that answers their ask is sent even if they have it (see `Entry.force`).
		case card(CardTarget)
		/// Asking this person, privately, for their card.
		case cardAsk(Int64)
		/// Asking this person for their photo, for the download in progress.
		case photoAsk(Int64)
	}

	/// Why a packet goes. Declaration order is priority: an entry queued for several
	/// reasons goes under the first one whose cap and interval let it through.
	enum Reason: Int, Comparable, CaseIterable {
		/// My card, after I message someone or post in a group.
		case myMessage
		/// My card, after I edit my profile.
		case myEdit
		/// My card back to someone whose card just came.
		case reply
		/// My card to someone who asked for it.
		case answer
		/// Asking someone for their photo.
		case photoAsk
		/// Asking someone, privately, for their card.
		case ask

		static func < (lhs: Reason, rhs: Reason) -> Bool {
			lhs.rawValue < rhs.rawValue
		}
	}

	/// Where an entry waits its turn on the lane: `mine` first, then the others and photo
	/// pieces in turn (see `cycle`).
	enum LaneClass {
		case mine, edit, inbound, photoAsks, asks, pieces
	}

	struct Entry {
		var item: Item
		var due: Instant
		/// Every reason it was queued for; merging adds to them.
		var reasons: Set<Reason>
		/// For an ask: the group card that made me ask (the latest one heard).
		var hint: ProfileCard?
		/// For a photo ask: only the pieces still missing.
		var isReask = false
		/// When it was first queued.
		var queued: Instant
		/// When it was first due with no reason letting it through; cleared once one does.
		var blockedSince: Instant?
		/// The reason it went under, set when `next` hands it out.
		var admittedAs: Reason?
		/// The reason whose room it takes: the one it was first queued for, kept through
		/// merges, so a merge can't fill another reason's room or free its own.
		var roomReason: Reason?

		/// My card to someone who asked for it: sent even if they have its version.
		var force: Bool { reasons.contains(.answer) }
		/// The reason it waits under on the lane.
		var lead: Reason { reasons.min() ?? .ask }
		var laneClass: LaneClass { ProfileOutbox.laneClass(lead) }
	}

	/// What the lane sends next.
	enum Pick {
		case entry(Entry)
		/// A photo piece (see `PhotoSendLimiter.next`).
		case piece
	}

	/// How a send `next` handed out went.
	enum Outcome {
		/// Not needed any more; nothing went.
		case notNeeded
		case sent
		/// It reached the radio, which refused it.
		case failed
		/// No radio.
		case noRadio
	}

	// Delays, in seconds, between queuing and sending.
	/// My card after I message someone or post in a group, or as an answer: the message goes first.
	static let afterMessage = 2.0...5.0
	/// My card back to someone whose card just came privately.
	static let cardBack = 2.0...5.0
	/// My card back to a group, spread out so a new member doesn't get every reply at once.
	static let cardBackToGroup = 3.0...15.0
	/// After editing my profile, to each person and group.
	static let afterEdit = 1.0...10.0
	/// Asking for a card: everyone who heard the same group card doesn't ask at the same moment.
	static let ask = 5.0...60.0
	/// Asking again for missing photo pieces.
	static let reask = 0.0...5.0

	/// Photo downloads going at once. Past that, "Update" waits for one to finish.
	static let maxTransfers = 6
	/// Asks per download (the first and three more) before it's given up.
	static let maxPhotoAttempts = 4
	/// A download goes this long quiet before it's asked again, at least and at most (see
	/// `ProfileRules.photoPatience`).
	static let minPhotoPatience: Duration = .seconds(60)
	static let maxPhotoPatience: Duration = .seconds(180)
	/// A download is given up once the radio has been away this long.
	static let maxRadioAway: Duration = .seconds(10 * 60)
	/// Linked but not taking packets: the lane tries again after this, doubling up to `maxBackoff`.
	static let firstBackoff: Duration = .seconds(5)
	static let maxBackoff: Duration = .seconds(60)
	/// Other packets, my own cards included, between two photo pieces while pieces wait.
	static let maxBetweenPieces = 3

	/// What the caps across everyone count over.
	static let window: Duration = .seconds(10 * 60)
	static let repliesPerWindow = 12
	static let answersPerWindow = 12
	static let photoAsksPerWindow = maxTransfers * maxPhotoAttempts
	static let asksPerWindow = 3
	/// At most one card per person or group per this long after edits, so a few quick edits
	/// send one card: the latest.
	static let editInterval: Duration = .seconds(60)
	/// One answer per person per this long.
	static let answerInterval: Duration = .seconds(10 * 60)
	/// One ask per person per this long; sooner, after `askRearm`, when the card heard
	/// differs from the one last asked about, so one forged card can't hold off a real change.
	static let askInterval: Duration = .seconds(30 * 60)
	static let askRearm: Duration = .seconds(5 * 60)
	/// Between any two profile packets, photo pieces included.
	static let spacing = PhotoSendLimiter.spacing
	/// A packet no reason has let through for this long is dropped. Every capped reason's
	/// room drains well within it (room ÷ cap × window, plus its interval), so it's only a
	/// safety net: what's accepted is sent, or dropped when it goes as not needed.
	static let maxBlockedAge: Duration = .seconds(60 * 60)
	/// And anything queued this long, for a radio that never comes back.
	static let maxQueuedAge: Duration = .seconds(6 * 60 * 60)

	/// The lane's turns after `mine`: photo pieces every other one, so whatever else
	/// waits, pieces someone asked me for keep going. A class with nothing to send is skipped.
	static let cycle: [LaneClass] = [.edit, .pieces, .inbound, .pieces, .photoAsks, .pieces, .edit, .pieces, .asks, .pieces]

	static func laneClass(_ reason: Reason) -> LaneClass {
		switch reason {
		case .myMessage: return .mine
		case .myEdit: return .edit
		case .reply, .answer: return .inbound
		case .photoAsk: return .photoAsks
		case .ask: return .asks
		}
	}

	/// Entries each reason may queue at once, counted by the reason each was first queued for.
	static func room(_ reason: Reason) -> Int {
		switch reason {
		case .myMessage, .reply: return 16
		// One card per person or group, 8 people and 7 groups, after an edit: a push the edit
		// interval holds back, and a whole new one.
		case .myEdit: return 32
		case .answer: return 32
		case .photoAsk: return maxTransfers
		case .ask: return 8
		}
	}

	/// Sends per `window` across everyone, charged to the reason each went under. My own
	/// cards aren't capped: there's one per person per version, and only when I message or edit.
	static func cap(_ reason: Reason) -> Int? {
		switch reason {
		case .myMessage, .myEdit: return nil
		case .reply: return repliesPerWindow
		case .answer: return answersPerWindow
		case .photoAsk: return photoAsksPerWindow
		case .ask: return asksPerWindow
		}
	}

	private struct Sent {
		var item: Item
		var reasons: Set<Reason>
		var chargedTo: Reason
		var hint: ProfileCard?
		var at: Instant
	}

	private(set) var entries: [Entry] = []
	private var sent: [Sent] = []
	/// When the last profile packet of any kind, photo pieces included, went to the radio.
	private var lastSend: Instant?
	/// Where the lane is in `cycle`.
	private var cursor = 0
	/// Other packets handed out in a row while photo pieces wait.
	private var sinceLastPiece = 0
	/// The entry `next` handed out, until `finish`: it keeps its place in its room, since it
	/// may come back.
	private var inFlight: Entry?

	/// Queues `item` to go after a random delay in `delay` (seconds). If it's already
	/// waiting, the two become one: the sooner time, both reasons, the newer hint, and all
	/// missing pieces if either asked for all. False when `reason` has no room left.
	@discardableResult
	mutating func schedule(_ item: Item, reason: Reason, delay: ClosedRange<Double>, hint: ProfileCard? = nil,
						   isReask: Bool = false, now: Instant) -> Bool {
		var random = SystemRandomNumberGenerator()
		return schedule(item, reason: reason, delay: delay, hint: hint, isReask: isReask, now: now, using: &random)
	}

	@discardableResult
	mutating func schedule<Random: RandomNumberGenerator>(_ item: Item, reason: Reason, delay: ClosedRange<Double>, hint: ProfileCard? = nil,
														  isReask: Bool = false, now: Instant, using random: inout Random) -> Bool {
		let due = now + .seconds(Double.random(in: delay, using: &random))
		if let index = entries.firstIndex(where: { $0.item == item }) {
			entries[index].due = min(entries[index].due, due)
			entries[index].reasons.insert(reason)
			entries[index].hint = hint ?? entries[index].hint
			entries[index].isReask = entries[index].isReask && isReask
			return true
		}
		// One in flight for another item holds its place, unless something queued meanwhile
		// for its item already does. One for this same item doesn't: it would merge back into this.
		var held = false
		if let flight = inFlight, (flight.roomReason ?? flight.lead) == reason, flight.item != item, !contains(flight.item) {
			held = true
		}
		guard entries.filter({ ($0.roomReason ?? $0.lead) == reason }).count + (held ? 1 : 0) < Self.room(reason) else { return false }
		entries.append(Entry(item: item, due: due, reasons: [reason], hint: hint, isReask: isReask, queued: now, roomReason: reason))
		return true
	}

	func contains(_ item: Item) -> Bool {
		entries.contains { $0.item == item }
	}

	/// Not wanted any more (a photo download given up).
	mutating func remove(_ item: Item) {
		entries.removeAll { $0.item == item }
	}

	/// The earliest a packet of any kind may go: `spacing` after the last one.
	func sendableAt(_ now: Instant) -> Instant {
		lastSend.map { max(now, $0 + Self.spacing) } ?? now
	}

	/// Sends counted against `reason`'s cap right now.
	func charged(_ reason: Reason, now: Instant) -> Int {
		sent.filter { $0.chargedTo == reason && now - $0.at < Self.window }.count
	}

	/// The earliest, from `now` on, that `reason` lets this entry through if nothing else
	/// goes meanwhile: once its cap has room, and its interval for this person or group is over.
	func admitsAt(_ reason: Reason, _ entry: Entry, now: Instant) -> Instant {
		var at = now
		if let cap = Self.cap(reason) {
			let times = sent.filter { $0.chargedTo == reason && now - $0.at < Self.window }.map(\.at).sorted()
			if times.count >= cap {
				at = max(at, times[times.count - cap] + Self.window)
			}
		}
		// Any send that carried this reason counts, whatever it was charged to: an update that
		// also answered someone still starts their answer interval.
		if let last = sent.last(where: { $0.item == entry.item && $0.reasons.contains(reason) }) {
			switch reason {
			case .myEdit:
				at = max(at, last.at + Self.editInterval)
			case .answer:
				at = max(at, last.at + Self.answerInterval)
			case .ask:
				at = max(at, last.at + (last.hint != entry.hint ? Self.askRearm : Self.askInterval))
			case .myMessage, .reply, .photoAsk:
				break
			}
		}
		return at
	}

	/// The reason an entry may go under now, by priority; nil while every one holds it back.
	func admittingReason(_ entry: Entry, now: Instant) -> Reason? {
		entry.reasons.sorted().first { admitsAt($0, entry, now: now) <= now }
	}

	/// What to send now, or nil while it's too soon after the last packet or nothing may go.
	/// My own cards go first. Then the lane takes turns (`cycle`), skipping whatever has
	/// nothing to send, so nothing waits while there's room. While pieces wait, one goes
	/// after at most `maxBetweenPieces` others, mine included, so whoever's getting my photo
	/// doesn't go quiet long enough to ask again. An entry handed out is taken out of the
	/// outbox; give it to `finish` once it's gone. `piecesWaiting`: the photo limiter has
	/// pieces to send.
	mutating func next(now: Instant, piecesWaiting: Bool) -> Pick? {
		guard sendableAt(now) <= now else { return nil }
		prune(now)
		for index in entries.indices where entries[index].due <= now {
			if admittingReason(entries[index], now: now) == nil {
				if entries[index].blockedSince == nil { entries[index].blockedSince = now }
			} else {
				entries[index].blockedSince = nil
			}
		}
		entries.removeAll { entry in
			(entry.blockedSince.map { now - $0 > Self.maxBlockedAge } ?? false) || now - entry.queued > Self.maxQueuedAge
		}
		if piecesWaiting && sinceLastPiece >= Self.maxBetweenPieces {
			sinceLastPiece = 0
			return .piece
		}
		if let index = earliest(.mine, now: now) {
			return .entry(handOut(index, now: now, piecesWaiting: piecesWaiting))
		}
		for step in Self.cycle.indices {
			let turn = (cursor + step) % Self.cycle.count
			let laneClass = Self.cycle[turn]
			if laneClass == .pieces {
				guard piecesWaiting else { continue }
				cursor = turn + 1
				sinceLastPiece = 0
				return .piece
			}
			if let index = earliest(laneClass, now: now) {
				cursor = turn + 1
				return .entry(handOut(index, now: now, piecesWaiting: piecesWaiting))
			}
		}
		return nil
	}

	private mutating func handOut(_ index: Int, now: Instant, piecesWaiting: Bool) -> Entry {
		sinceLastPiece = piecesWaiting ? sinceLastPiece + 1 : 0
		return take(index, now: now)
	}

	/// When to look again: when the next entry is due and some reason lets it through, or
	/// at once while pieces wait, but not before `spacing` is over. Nil when nothing waits.
	func nextWake(now: Instant, piecesWaiting: Bool) -> Instant? {
		var times = entries.map { entry in
			max(entry.due, entry.reasons.map { admitsAt($0, entry, now: now) }.min() ?? now)
		}
		if piecesWaiting { times.append(now) }
		guard let soonest = times.min() else { return nil }
		return max(soonest, sendableAt(now))
	}

	/// After `next` handed out `entry`. A send that reached the radio (sent, or refused by
	/// it) is charged. One that found no radio goes back as it was, uncharged, and true
	/// says the lane should wait for the radio. One not needed any more counts for nothing.
	@discardableResult
	mutating func finish(_ entry: Entry, _ outcome: Outcome, at now: Instant) -> Bool {
		if inFlight?.item == entry.item { inFlight = nil }
		switch outcome {
		case .sent, .failed:
			prune(now)
			sent.append(Sent(item: entry.item, reasons: entry.reasons, chargedTo: entry.admittedAs ?? entry.lead, hint: entry.hint, at: now))
			lastSend = now
			return false
		case .noRadio:
			putBack(entry)
			return true
		case .notNeeded:
			return false
		}
	}

	/// A photo piece went: the next packet of any kind waits `spacing` after it.
	mutating func sentPhotoPiece(at now: Instant) {
		lastSend = now
	}

	private func earliest(_ laneClass: LaneClass, now: Instant) -> Int? {
		entries.indices
			.filter { entries[$0].laneClass == laneClass && entries[$0].due <= now && admittingReason(entries[$0], now: now) != nil }
			.min { entries[$0].due < entries[$1].due }
	}

	private mutating func take(_ index: Int, now: Instant) -> Entry {
		var entry = entries.remove(at: index)
		entry.admittedAs = admittingReason(entry, now: now)
		inFlight = entry
		return entry
	}

	/// Back as it was when taken; merged into the same item if it was queued again meanwhile.
	private mutating func putBack(_ entry: Entry) {
		var entry = entry
		entry.admittedAs = nil
		guard let index = entries.firstIndex(where: { $0.item == entry.item }) else {
			entries.append(entry)
			return
		}
		entries[index].due = min(entries[index].due, entry.due)
		entries[index].reasons.formUnion(entry.reasons)
		entries[index].hint = entries[index].hint ?? entry.hint
		entries[index].isReask = entries[index].isReask && entry.isReask
		entries[index].queued = min(entries[index].queued, entry.queued)
	}

	private mutating func prune(_ now: Instant) {
		let longest = max(Self.window, Self.editInterval, Self.answerInterval, Self.askInterval)
		sent.removeAll { now - $0.at >= longest }
	}
}
