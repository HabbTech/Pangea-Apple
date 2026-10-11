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

	func card(fallbackName: String) -> ProfileCard {
		ProfileCard(displayName: displayName.isEmpty ? fallbackName : displayName, emoji: emoji, color: color, photoVersion: photoVersion)
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
	}

	private let folder: URL

	init(folder: URL? = nil) {
		let base = folder ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("PangeaProfiles", isDirectory: true))
		self.folder = base
		try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
		if let data = try? Data(contentsOf: base.appendingPathComponent("profiles.json")),
		   let saved = try? JSONDecoder().decode(Saved.self, from: data) {
			me = saved.me
			contacts = saved.contacts
			groupSends = saved.groupSends
		}
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
		myPhotoImage = myPhotoData.flatMap(UIImage.init(data:))
		return myPhotoImage
	}

	func updateMe(displayName: String, emoji: String, color: UInt8, photo: Data??) {
		var profile = me
		profile.displayName = ProfileCard.clamp(displayName.trimmingCharacters(in: .whitespacesAndNewlines), bytes: ProfileCard.maxNameBytes)
		profile.emoji = ProfileCard.clamp(emoji, bytes: ProfileCard.maxEmojiBytes)
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
		let image = (try? Data(contentsOf: photoURL(String(num)))).flatMap(UIImage.init(data:))
		photoCache[num] = image
		return image
	}

	func receivedCard(_ card: ProfileCard, from num: Int64, channel: Int32?) {
		var profile = contacts[num] ?? ContactProfile()
		profile.card = card
		if let channel { profile.lastChannel = channel }
		if card.photoVersion == 0, profile.savedPhotoVersion != 0 {
			// They removed their photo.
			profile.savedPhotoVersion = 0
			try? FileManager.default.removeItem(at: photoURL(String(num)))
			photoCache[num] = nil
		}
		contacts[num] = profile
		save()
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

	func markCardSent(_ version: UInt32, to num: Int64) {
		var profile = contacts[num] ?? ContactProfile()
		profile.sentCardVersion = version
		contacts[num] = profile
		save()
	}

	func needsGroupSend(_ key: String, version: UInt32, every interval: TimeInterval = 24 * 60 * 60) -> Bool {
		guard let last = groupSends[key] else { return true }
		return last.version != version || Date().timeIntervalSince(last.date) > interval
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

	// MARK: Names

	/// Nickname, then the name they chose in Pangea, then their radio name.
	func name(for user: UserEntity) -> String {
		name(num: user.num, radioName: user.longName)
	}

	func name(num: Int64, radioName: String?) -> String {
		if let nickname = contacts[num]?.nickname { return nickname }
		if let display = contacts[num]?.card?.displayName, !display.isEmpty { return display }
		if let radioName, !radioName.isEmpty { return radioName }
		return PangeaCode.code(for: num)
	}
}
