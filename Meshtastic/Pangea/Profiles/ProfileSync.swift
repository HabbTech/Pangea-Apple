//
//  ProfileSync.swift
//  Pangea
//
//  Sends my card to the people I talk to, and fetches photos only when asked.
//
//  - DMs: my card goes along, privately, after a message to someone who doesn't
//    have its latest version.
//  - Groups: my card goes to the group after I post, at most once a day unless it changed.
//  - Photos: never pushed. Their app asks, I send ~1 KB in pieces, they keep it.
//  - Everyone Nearby (the public channel) never sees any of this.
//

import Foundation
import CoreData
import MeshtasticProtobufs
import OSLog

@MainActor
enum ProfileSync {

	private struct Transfer {
		var version: UInt32
		var count: UInt8?
		var chunks: [UInt8: Data] = [:]
		var lastActivity = Date()
		var attempts = 1
		var route: Route
	}

	/// How a packet reaches someone: privately to their key, or inside a group they're in.
	enum Route: Equatable {
		case direct
		case group(Int32)
	}

	private static var transfers: [Int64: Transfer] = [:]
	private static var lastPhotoSend: [Int64: Date] = [:]
	private static var watchdog: Task<Void, Never>?

	private static var accessoryManager: AccessoryManager { AccessoryManager.shared }

	private static var myUser: UserEntity? {
		guard let num = accessoryManager.activeDeviceNum else { return nil }
		return getNodeInfo(id: num, context: accessoryManager.context)?.user
	}

	static var myCard: ProfileCard? {
		guard let me = myUser else { return nil }
		return ProfileStore.shared.me.card(fallbackName: me.longName ?? "")
	}

	// MARK: Name set while no radio was connected

	private static let pendingNameKey = "pangeaPendingRadioName"

	static var pendingRadioName: String? {
		get { UserDefaults.standard.string(forKey: pendingNameKey) }
		set { UserDefaults.standard.set(newValue, forKey: pendingNameKey) }
	}

	/// Called when the radio finishes connecting.
	static func radioDidConnect() {
		guard let name = pendingRadioName else { return }
		pendingRadioName = nil
		Task {
			do {
				_ = try await RadioAutoConfig.apply(name: name, region: nil, accessoryManager: accessoryManager)
			} catch {
				pendingRadioName = name
				Logger.services.error("👤 [Profiles] Couldn't apply saved name: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	// MARK: Outgoing

	/// Hooked into every text message I send.
	static func didSendMessage(toUserNum: Int64, channel: Int32) {
		guard let card = myCard, let payload = card.payload else { return }
		let store = ProfileStore.shared
		if toUserNum > 0 && toUserNum != Int64(Constants.maximumNodeNum) {
			guard store.profile(toUserNum)?.sentCardVersion != card.version,
				  let user = existingUser(num: toUserNum, context: accessoryManager.context), canReachDirectly(user) else { return }
			store.markCardSent(card.version, to: toUserNum)
			Task {
				// Let the message itself go first.
				try? await Task.sleep(for: .seconds(2))
				await send(payload, to: toUserNum, route: .direct, description: "👤 [Profiles] Sent my card")
			}
		} else if let key = groupKey(channel) {
			guard store.needsGroupSend(key, version: card.version) else { return }
			store.markGroupSent(key, version: card.version)
			Task {
				try? await Task.sleep(for: .seconds(2))
				await send(payload, to: Int64(Constants.maximumNodeNum), route: .group(channel), description: "👤 [Profiles] Sent my card to group")
			}
		}
	}

	/// After editing my profile: refresh the people I've talked to lately.
	static func pushUpdatedCard() {
		guard let card = myCard, let payload = card.payload else { return }
		let store = ProfileStore.shared
		let context = accessoryManager.context
		let request = UserEntity.fetchRequest()
		request.predicate = NSPredicate(format: "lastMessage > %@ AND pkiEncrypted == YES", Date().addingTimeInterval(-14 * 24 * 60 * 60) as NSDate)
		request.sortDescriptors = [NSSortDescriptor(keyPath: \UserEntity.lastMessage, ascending: false)]
		request.fetchLimit = 8
		let myNum = accessoryManager.activeDeviceNum
		let people = ((try? context.fetch(request)) ?? []).filter { $0.num != myNum && canReachDirectly($0) }.map(\.num)

		var groups: [Int32] = []
		if let num = myNum, let myInfo = getNodeInfo(id: num, context: context)?.myInfo {
			groups = GroupChats.groups(in: myInfo).filter { $0.mostRecentPrivateMessage != nil }.map(\.index)
		}

		Task {
			for num in people {
				store.markCardSent(card.version, to: num)
				await send(payload, to: num, route: .direct, description: "👤 [Profiles] Sent updated card")
				try? await Task.sleep(for: .seconds(3))
			}
			for index in groups {
				guard let key = groupKey(index) else { continue }
				store.markGroupSent(key, version: card.version)
				await send(payload, to: Int64(Constants.maximumNodeNum), route: .group(index), description: "👤 [Profiles] Sent updated card to group")
				try? await Task.sleep(for: .seconds(3))
			}
		}
	}

	/// The user tapped "Update" on someone's photo.
	static func requestPhoto(from num: Int64) {
		let store = ProfileStore.shared
		guard let profile = store.profile(num), let version = profile.card?.photoVersion, version != 0,
			  let route = route(to: num, profile: profile) else { return }
		store.downloading.insert(num)
		transfers[num] = Transfer(version: version, route: route)
		Task {
			await send(PhotoRequest(photoVersion: version).payload, to: num, route: route, description: "👤 [Profiles] Asked for photo")
		}
		startWatchdog()
	}

	static func canRequestPhoto(from num: Int64) -> Bool {
		guard let profile = ProfileStore.shared.profile(num) else { return false }
		return route(to: num, profile: profile) != nil
	}

	private static func route(to num: Int64, profile: ContactProfile) -> Route? {
		if let user = existingUser(num: num, context: accessoryManager.context), canReachDirectly(user) {
			return .direct
		}
		if let channel = profile.lastChannel, groupKey(channel) != nil {
			return .group(channel)
		}
		return nil
	}

	private static func canReachDirectly(_ user: UserEntity) -> Bool {
		user.pkiEncrypted && !(user.publicKey ?? Data()).isEmpty
	}

	/// "index:name" for a Pangea group on my radio; nil for Everyone Nearby or anything else.
	private static func groupKey(_ index: Int32) -> String? {
		guard index > 0, let num = accessoryManager.activeDeviceNum,
			  let channel = (getNodeInfo(id: num, context: accessoryManager.context)?.myInfo?.channels?.array as? [ChannelEntity])?
				.first(where: { $0.index == index }),
			  GroupChats.isChat(channel) else { return nil }
		return "\(index):\(channel.name ?? "")"
	}

	private static func send(_ payload: Data, to num: Int64, route: Route, description: String) async {
		guard let me = myUser else { return }
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
			guard let user = existingUser(num: num, context: accessoryManager.context), let key = user.publicKey, !key.isEmpty else { return }
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
		} catch {
			Logger.services.error("👤 [Profiles] Send failed: \(error.localizedDescription, privacy: .public)")
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
		let isChunk = payload.starts(with: PangeaWire.chunkMagic)
		guard isCard || isRequest || isChunk else { return false }

		let from = Int64(packet.from)
		guard from != accessoryManager.activeDeviceNum else { return true }

		// Only private DMs, or a Pangea group I'm in. Never the public channel.
		let route: Route
		if packet.pkiEncrypted && packet.to != Constants.maximumNodeNum {
			route = .direct
		} else if groupKey(Int32(packet.channel)) != nil {
			route = .group(Int32(packet.channel))
		} else {
			return true
		}

		if isCard, let card = ProfileCard(payload: payload) {
			received(card, from: from, route: route)
		} else if isRequest, let request = PhotoRequest(payload: payload) {
			received(request, from: from, route: route)
		} else if isChunk, let chunk = PhotoChunk(payload: payload) {
			received(chunk, from: from)
		}
		return true
	}

	private static func received(_ card: ProfileCard, from num: Int64, route: Route) {
		let store = ProfileStore.shared
		if case .group(let index) = route {
			store.receivedCard(card, from: num, channel: index)
		} else {
			store.receivedCard(card, from: num, channel: nil)
		}
		Logger.services.info("👤 [Profiles] Got a card")

		// Swap cards: if they don't have mine yet, send it back.
		guard let mine = myCard, let payload = mine.payload else { return }
		switch route {
		case .direct:
			guard store.profile(num)?.sentCardVersion != mine.version else { return }
			store.markCardSent(mine.version, to: num)
			Task {
				try? await Task.sleep(for: .seconds(Double.random(in: 2...5)))
				await send(payload, to: num, route: .direct, description: "👤 [Profiles] Sent my card back")
			}
		case .group(let index):
			guard let key = groupKey(index), store.needsGroupSend(key, version: mine.version) else { return }
			store.markGroupSent(key, version: mine.version)
			Task {
				// Spread out so a new member doesn't get every reply at once.
				try? await Task.sleep(for: .seconds(Double.random(in: 3...15)))
				await send(payload, to: Int64(Constants.maximumNodeNum), route: route, description: "👤 [Profiles] Sent my card to group")
			}
		}
	}

	private static func received(_ request: PhotoRequest, from num: Int64, route: Route) {
		let store = ProfileStore.shared
		guard request.photoVersion == store.me.photoVersion, let photo = store.myPhotoData else { return }
		// One full send per person every few minutes; re-requests for missing pieces are allowed.
		let isRetry = request.wanted != PhotoRequest.everything
		if !isRetry, let last = lastPhotoSend[num], Date().timeIntervalSince(last) < 5 * 60 { return }
		lastPhotoSend[num] = Date()

		let chunks = PhotoChunk.split(photo).filter { request.wanted & (1 << UInt16($0.index)) != 0 }
		Task {
			for chunk in chunks {
				await send(chunk.payload, to: num, route: route, description: "👤 [Profiles] Sent photo piece \(chunk.index + 1)/\(chunk.count)")
				try? await Task.sleep(for: .milliseconds(1500))
			}
		}
	}

	private static func received(_ chunk: PhotoChunk, from num: Int64) {
		guard var transfer = transfers[num], transfer.version == chunk.photoVersion else { return }
		transfer.count = chunk.count
		transfer.chunks[chunk.index] = chunk.bytes
		transfer.lastActivity = Date()
		if let photo = PhotoChunk.assemble(transfer.chunks, count: chunk.count, version: chunk.photoVersion) {
			transfers[num] = nil
			ProfileStore.shared.savePhoto(photo, version: chunk.photoVersion, for: num)
			Logger.services.info("👤 [Profiles] Photo received")
		} else {
			transfers[num] = transfer
		}
	}

	/// Re-asks for missing pieces, and gives up after a few tries.
	private static func startWatchdog() {
		guard watchdog == nil else { return }
		watchdog = Task {
			while !transfers.isEmpty {
				try? await Task.sleep(for: .seconds(10))
				for (num, transfer) in transfers where Date().timeIntervalSince(transfer.lastActivity) > 45 {
					if transfer.attempts >= 3 {
						transfers[num] = nil
						ProfileStore.shared.downloading.remove(num)
						continue
					}
					var wanted = PhotoRequest.everything
					if let count = transfer.count {
						wanted = 0
						for index in 0..<count where transfer.chunks[index] == nil {
							wanted |= 1 << UInt16(index)
						}
					}
					transfers[num]?.attempts += 1
					transfers[num]?.lastActivity = Date()
					await send(PhotoRequest(photoVersion: transfer.version, wanted: wanted).payload, to: num, route: transfer.route, description: "👤 [Profiles] Asked again for photo")
				}
			}
			watchdog = nil
		}
	}
}
