//
//  ProfileStore.swift
//  Pangea
//
//  Profiles live in their own folder, separate from the Meshtastic database, so
//  upstream migrations never have to know about them. Nicknames never leave
//  this device.
//

import SwiftUI
import OSLog

struct MyProfile: Codable, Equatable {
	var displayName = ""
	var emoji = ""
	var color: UInt8 = 0
	var photoVersion: UInt32 = 0

	/// My card. The photo is described only when `photo` is the one saved as mine.
	func card(fallbackName: String, photo: PhotoPieces? = nil) -> ProfileCard {
		ProfileCard(displayName: displayName.isEmpty ? fallbackName : displayName, emoji: emoji, color: color,
					photo: photo?.version == photoVersion && photoVersion != 0 ? photo : nil)
	}
}

struct ContactProfile: Codable, Equatable {
	var card: ProfileCard?
	/// Version of the photo saved on this device.
	var savedPhotoVersion: UInt32 = 0
	/// Photo version the user tapped "Not Now" on.
	var declinedPhotoVersion: UInt32 = 0
	var nickname: String?
	/// Version of my card this person has been sent.
	var sentCardVersion: UInt32 = 0
	/// Group channel we last heard their card on, for people without a DM key.
	var lastChannel: Int32?
	/// That group's identity ("index:name:key hash") when the card arrived. A slot
	/// index alone is reused when a group is left and another joined, or the radio changes.
	var lastGroupKey: String?
	/// How the card arrived. One sent privately came from their key; one heard in a group
	/// could have been sent by anyone in it, so it never replaces a private one.
	var cardSource: CardSource?
	/// Saved to Contacts. Kept here, not in the node list, so they stay after the radio forgets them.
	/// A build from before Contacts drops this and `contactName` when it saves: only a TestFlight
	/// rollback can install one (the App Store never goes back a version), so that is accepted.
	var isContact = false
	/// Their radio name when they were saved, to show while the radio doesn't know them.
	var contactName: String?

	enum CardSource: String, Codable {
		case direct, group
	}

	/// A photo is waiting that the user hasn't downloaded or dismissed.
	var hasPhotoOffer: Bool {
		guard let version = card?.photoVersion, version != 0 else { return false }
		return version != savedPhotoVersion && version != declinedPhotoVersion
	}

	/// A newer photo exists than the one on this device, dismissed or not.
	var canUpdatePhoto: Bool {
		guard let version = card?.photoVersion, version != 0 else { return false }
		return version != savedPhotoVersion
	}
}

// Decoded field by field, so a file written by an older or newer version (a field
// added, missing, or of another type) still loads instead of being thrown away. A field
// that's there but unreadable is noted, so the file is copied aside before it's rewritten.
extension MyProfile {
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		displayName = container.tolerant(String.self, forKey: .displayName, decoder) ?? ""
		// Older versions took any text here; it's held to the rule every receiver applies.
		emoji = ProfileCard.cleanEmoji(container.tolerant(String.self, forKey: .emoji, decoder) ?? "")
		color = container.tolerant(UInt8.self, forKey: .color, decoder) ?? 0
		photoVersion = container.tolerant(UInt32.self, forKey: .photoVersion, decoder) ?? 0
	}
}

extension ContactProfile {
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// Cleaned here, so every screen sees the same name and emoji, whenever the card was saved.
		card = container.tolerant(ProfileCard.self, forKey: .card, decoder)?.cleaned
		savedPhotoVersion = container.tolerant(UInt32.self, forKey: .savedPhotoVersion, decoder) ?? 0
		declinedPhotoVersion = container.tolerant(UInt32.self, forKey: .declinedPhotoVersion, decoder) ?? 0
		nickname = container.tolerant(String.self, forKey: .nickname, decoder)
		sentCardVersion = container.tolerant(UInt32.self, forKey: .sentCardVersion, decoder) ?? 0
		lastChannel = container.tolerant(Int32.self, forKey: .lastChannel, decoder)
		lastGroupKey = container.tolerant(String.self, forKey: .lastGroupKey, decoder)
		cardSource = container.tolerant(CardSource.self, forKey: .cardSource, decoder)
		// Missing from files saved before Contacts existed.
		isContact = container.tolerant(Bool.self, forKey: .isContact, decoder) ?? false
		contactName = container.tolerant(String.self, forKey: .contactName, decoder)
	}
}

@MainActor
final class ProfileStore: ObservableObject {
	static let shared = ProfileStore()

	@Published private(set) var me = MyProfile()
	@Published private(set) var contacts: [Int64: ContactProfile] = [:]
	/// People whose photo is downloading right now.
	@Published var downloading: Set<Int64> = []
	/// 0...1 while a photo downloads.
	@Published var downloadProgress: [Int64: Double] = [:]
	/// Profile sheet to show, by node number.
	@Published var presentedProfile: Int64?

	/// My card version per group ("index:name"), and when it was last sent there.
	private var groupSends: [String: GroupSend] = [:]
	private var photoCache: [Int64: UIImage] = [:]
	private var myPhotoImage: UIImage?

	struct GroupSend: Codable {
		var version: UInt32
		var date: Date
	}

	private struct Saved: Codable {
		var me: MyProfile
		var contacts: [Int64: ContactProfile]
		var groupSends: [String: GroupSend]

		private enum CodingKeys: String, CodingKey {
			case me, contacts, groupSends
		}

		init(me: MyProfile, contacts: [Int64: ContactProfile], groupSends: [String: GroupSend]) {
			self.me = me
			self.contacts = contacts
			self.groupSends = groupSends
		}

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			me = container.tolerant(MyProfile.self, forKey: .me, decoder) ?? MyProfile()
			contacts = Self.decodeContacts(container, decoder)
			groupSends = container.tolerant([String: GroupSend].self, forKey: .groupSends, decoder) ?? [:]
		}

		/// One contact at a time, so one bad entry costs that contact, not everyone.
		/// JSONEncoder writes an [Int64: X] dictionary as a flat [key, value, key, value] array.
		private static func decodeContacts(_ container: KeyedDecodingContainer<CodingKeys>, _ decoder: Decoder) -> [Int64: ContactProfile] {
			guard container.contains(.contacts) else { return [:] }
			let loss = decoder.userInfo[.pangeaDecodeLoss] as? DecodeLoss
			guard var list = try? container.nestedUnkeyedContainer(forKey: .contacts) else {
				loss?.happened = true
				return [:]
			}
			var contacts: [Int64: ContactProfile] = [:]
			while !list.isAtEnd {
				let start = list.currentIndex
				let num = try? list.decode(Int64.self)
				if num == nil { _ = try? list.decode(Skip.self) }
				guard !list.isAtEnd else {
					loss?.happened = true
					break
				}
				if let num, let profile = try? list.decode(ContactProfile.self) {
					contacts[num] = profile
				} else {
					loss?.happened = true
					_ = try? list.decode(Skip.self)
				}
				// A value even Skip can't step past (shouldn't happen): stop, keep what loaded.
				if list.currentIndex == start {
					loss?.happened = true
					break
				}
			}
			return contacts
		}

		/// Decodes anything, to step past a value that can't be read.
		private struct Skip: Decodable {
			init(from decoder: Decoder) throws {}
		}
	}

	private let folder: URL

	init(folder: URL? = nil) {
		let base = folder ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("PangeaProfiles", isDirectory: true))
		self.folder = base
		try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
		let file = base.appendingPathComponent("profiles.json")
		guard let data = try? Data(contentsOf: file) else { return }
		let loss = DecodeLoss()
		let decoder = JSONDecoder()
		decoder.userInfo[.pangeaDecodeLoss] = loss
		do {
			let saved = try decoder.decode(Saved.self, from: data)
			me = saved.me
			contacts = saved.contacts
			groupSends = saved.groupSends
			if loss.happened {
				// Part of the file couldn't be read (a downgrade, say). Keep a copy of it
				// before the next save writes it out without that part, then save what
				// did load, so the copy isn't made again on every launch.
				let aside = Self.setAsideURL(in: base)
				Logger.data.error("👤 [Profiles] Part of profiles.json couldn't be read, copied to \(aside.lastPathComponent, privacy: .public)")
				if (try? FileManager.default.copyItem(at: file, to: aside)) != nil {
					save()
				}
			}
		} catch {
			// Keep the unreadable file (nicknames can't be fetched again) rather than
			// letting the next save write over it. An earlier set-aside copy is kept too.
			let aside = Self.setAsideURL(in: base)
			Logger.data.error("👤 [Profiles] Couldn't read profiles.json, set aside as \(aside.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
			try? FileManager.default.moveItem(at: file, to: aside)
		}
	}

	/// profiles.corrupt.json, or a unique name next to it once that's taken.
	private static func setAsideURL(in base: URL) -> URL {
		let first = base.appendingPathComponent("profiles.corrupt.json")
		guard FileManager.default.fileExists(atPath: first.path) else { return first }
		return base.appendingPathComponent("profiles.corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
	}

	private func save() {
		let saved = Saved(me: me, contacts: contacts, groupSends: groupSends)
		do {
			try JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("profiles.json"), options: .atomic)
		} catch {
			Logger.data.error("👤 [Profiles] Save failed: \(error.localizedDescription, privacy: .public)")
		}
	}

	private func photoURL(_ name: String) -> URL {
		folder.appendingPathComponent("\(name).jpg")
	}

	// MARK: Me

	var myPhotoData: Data? {
		me.photoVersion == 0 ? nil : try? Data(contentsOf: photoURL("me"))
	}

	var myPhoto: UIImage? {
		if let myPhotoImage { return myPhotoImage }
		myPhotoImage = myPhotoData.flatMap(PhotoCompressor.avatarImage(from:))
		return myPhotoImage
	}

	func updateMe(displayName: String, emoji: String, color: UInt8, photo: Data??) {
		var profile = me
		profile.displayName = displayName.cleanedName(fitting: ProfileCard.maxNameBytes)
		profile.emoji = ProfileCard.cleanEmoji(emoji)
		profile.color = color
		if let photo {
			if let photo {
				try? photo.write(to: photoURL("me"), options: .atomic)
				profile.photoVersion = PangeaWire.hash(photo)
			} else {
				try? FileManager.default.removeItem(at: photoURL("me"))
				profile.photoVersion = 0
			}
			myPhotoImage = nil
		}
		me = profile
		save()
	}

	// MARK: Other people

	func profile(_ num: Int64) -> ContactProfile? {
		contacts[num]
	}

	func photo(for num: Int64) -> UIImage? {
		guard let profile = contacts[num], profile.savedPhotoVersion != 0 else { return nil }
		if let cached = photoCache[num] { return cached }
		let image = (try? Data(contentsOf: photoURL(String(num)))).flatMap(PhotoCompressor.avatarImage(from:))
		photoCache[num] = image
		return image
	}

	/// `channel` is the group it was heard in, or nil for a private (PKI) card. Returns
	/// false when it was ignored: anyone in a group can send a card in someone else's
	/// name, so a group card never replaces one that came privately from their key.
	@discardableResult
	func receivedCard(_ card: ProfileCard, from num: Int64, channel: Int32?, groupKey: String? = nil) -> Bool {
		var profile = contacts[num] ?? ContactProfile()
		if channel != nil, profile.cardSource == .direct {
			return false
		}
		profile.card = card
		profile.cardSource = channel == nil ? .direct : .group
		if let channel {
			profile.lastChannel = channel
			profile.lastGroupKey = groupKey
		}
		if card.photoVersion == 0, profile.savedPhotoVersion != 0 {
			// They removed their photo.
			profile.savedPhotoVersion = 0
			try? FileManager.default.removeItem(at: photoURL(String(num)))
			photoCache[num] = nil
		}
		contacts[num] = profile
		save()
		return true
	}

	func savePhoto(_ data: Data, version: UInt32, for num: Int64) {
		var profile = contacts[num] ?? ContactProfile()
		try? data.write(to: photoURL(String(num)), options: .atomic)
		profile.savedPhotoVersion = version
		contacts[num] = profile
		photoCache[num] = nil
		downloading.remove(num)
		downloadProgress[num] = nil
		save()
	}

	func declinePhoto(for num: Int64) {
		guard var profile = contacts[num], let version = profile.card?.photoVersion else { return }
		profile.declinedPhotoVersion = version
		contacts[num] = profile
		save()
	}

	func setNickname(_ nickname: String, for num: Int64) {
		var profile = contacts[num] ?? ContactProfile()
		let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
		profile.nickname = trimmed.isEmpty ? nil : trimmed
		contacts[num] = profile
		save()
	}

	// MARK: Contacts

	func isContact(_ num: Int64) -> Bool {
		contacts[num]?.isContact == true
	}

	/// `radioName` is kept so the contact still has a name once the radio forgets them.
	func setContact(_ saved: Bool, for num: Int64, radioName: String? = nil) {
		var profile = contacts[num] ?? ContactProfile()
		profile.isContact = saved
		if saved {
			if let radioName, !radioName.isEmpty { profile.contactName = radioName }
		} else {
			profile.contactName = nil
		}
		contacts[num] = profile
		save()
	}

	/// Saved contacts by name, A to Z.
	var contactNums: [Int64] {
		contactNums(radioName: { _ in nil })
	}

	/// Sorted by the name each row shows: the radio's current name, when it has one, over the
	/// one saved with the contact.
	func contactNums(radioName current: (Int64) -> String?) -> [Int64] {
		contacts.filter { $0.value.isContact }
			.map { (num: $0.key, name: name(num: $0.key, radioName: current($0.key) ?? $0.value.contactName)) }
			.sorted { lhs, rhs in
				let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
				return order == .orderedSame ? lhs.num < rhs.num : order == .orderedAscending
			}
			.map(\.num)
	}

	func markCardSent(_ version: UInt32, to num: Int64) {
		var profile = contacts[num] ?? ContactProfile()
		profile.sentCardVersion = version
		contacts[num] = profile
		save()
	}

	/// Due when the card changed, a day after the last send, or when the clock is now before
	/// the last send (it was set back): otherwise an unchanged card would never go again.
	func needsGroupSend(_ key: String, version: UInt32, every interval: TimeInterval = 24 * 60 * 60, now: Date = Date()) -> Bool {
		guard let last = groupSends[key] else { return true }
		let since = now.timeIntervalSince(last.date)
		return last.version != version || since > interval || since < 0
	}

	func markGroupSent(_ key: String, version: UInt32) {
		groupSends[key] = GroupSend(version: version, date: Date())
		save()
	}

	/// Called when switching or forgetting a radio: other people's profiles stay,
	/// but they'll need my card again since it came from a different radio.
	func resetSentCards() {
		for num in contacts.keys {
			contacts[num]?.sentCardVersion = 0
		}
		groupSends = [:]
		save()
	}

	/// Settings → Clear App Data: my profile and photo, and everyone else's cards, photos,
	/// nicknames and saved contacts, as on a fresh install. Unlike `resetSentCards`, nothing stays.
	func eraseAll() {
		me = MyProfile()
		contacts = [:]
		groupSends = [:]
		photoCache = [:]
		myPhotoImage = nil
		downloading = []
		downloadProgress = [:]
		presentedProfile = nil
		// Photos, and copies of files that couldn't be read. profiles.json is written empty
		// below rather than removed, so a removal that fails can't bring it back next launch.
		let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
		for file in files where file.lastPathComponent != "profiles.json" {
			do {
				try FileManager.default.removeItem(at: file)
			} catch {
				Logger.data.error("👤 [Profiles] Couldn't remove \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
			}
		}
		save()
	}

	// MARK: Names

	/// Nickname, then the name they chose in Pangea, then their radio name.
	func name(for user: UserEntity) -> String {
		name(num: user.num, radioName: user.longName)
	}

	func name(num: Int64, radioName: String?) -> String {
		if let nickname = contacts[num]?.nickname { return nickname }
		if let display = (contacts[num]?.card?.displayName).map(ProfileCard.cleanName), !display.isEmpty { return display }
		if let radioName, !radioName.isEmpty { return radioName }
		return PangeaCode.code(for: num)
	}
}
