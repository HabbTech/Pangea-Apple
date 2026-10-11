//
//  ProfileTests.swift
//  MeshtasticTests
//

import Foundation
import Testing
import UIKit
@testable import Meshtastic

@Suite("Profile wire format")
struct ProfileWireTests {

	@Test func cardRoundTrips() throws {
		let card = ProfileCard(displayName: "Sam Rivera", emoji: "🏕️", color: 3, photoVersion: 0xDEADBEEF)
		let payload = try #require(card.payload)
		#expect(payload.count < 100)
		#expect(ProfileCard(payload: payload) == card)
	}

	@Test func cardVersionChangesWithContent() {
		let card = ProfileCard(displayName: "Sam", emoji: "", color: 0, photoVersion: 0)
		var changed = card
		changed.color = 1
		#expect(card.version != changed.version)
		#expect(card.version == ProfileCard(displayName: "Sam", emoji: "", color: 0, photoVersion: 0).version)
	}

	@Test func longFieldsAreClampedToFit() throws {
		let card = ProfileCard(displayName: String(repeating: "é", count: 100), emoji: String(repeating: "🔥", count: 10), color: 0, photoVersion: 0)
		let payload = try #require(card.payload)
		let decoded = try #require(ProfileCard(payload: payload))
		#expect(decoded.displayName.utf8.count <= ProfileCard.maxNameBytes)
		#expect(decoded.emoji.utf8.count <= ProfileCard.maxEmojiBytes)
	}

	@Test func rejectsOtherPayloads() {
		#expect(ProfileCard(payload: Data("PGI1hello".utf8)) == nil)
		#expect(ProfileCard(payload: PangeaWire.cardMagic + Data([1, 2])) == nil)
		#expect(PhotoRequest(payload: Data("nope".utf8)) == nil)
		#expect(PhotoChunk(payload: PangeaWire.chunkMagic + Data([0, 0, 0, 1, 5, 2])) == nil) // index past count
	}

	@Test func requestRoundTrips() {
		let some = PhotoRequest(photoVersion: 42, wanted: [1, 3, 9, 70])
		#expect(PhotoRequest(payload: some.payload) == some)
		let all = PhotoRequest(photoVersion: 42)
		#expect(PhotoRequest(payload: all.payload) == all)
		#expect(all.wants(77))
		#expect(!some.wants(2))
	}

	@Test func photoSplitsAndReassembles() throws {
		let photo = Data((0..<1100).map { UInt8($0 % 251) })
		let chunks = PhotoChunk.split(photo)
		#expect(chunks.count == 7)
		#expect(PhotoChunk.split(Data(count: PhotoCompressor.limit)).count <= PhotoChunk.maxChunks)
		#expect(chunks.allSatisfy { $0.payload.count <= PhotoChunk.maxBytes + 10 })

		// Arrive out of order, through the wire format.
		var received: [UInt8: Data] = [:]
		for chunk in chunks.reversed() {
			let decoded = try #require(PhotoChunk(payload: chunk.payload))
			received[decoded.index] = decoded.bytes
		}
		let version = PangeaWire.hash(photo)
		#expect(PhotoChunk.assemble(received, count: UInt8(chunks.count), version: version) == photo)

		received[3] = nil
		#expect(PhotoChunk.assemble(received, count: UInt8(chunks.count), version: version) == nil)
	}

	@Test func corruptPhotoIsRejected() {
		let photo = Data(repeating: 7, count: 300)
		var received: [UInt8: Data] = [:]
		for chunk in PhotoChunk.split(photo) { received[chunk.index] = chunk.bytes }
		received[0]?[0] = 8
		#expect(PhotoChunk.assemble(received, count: 2, version: PangeaWire.hash(photo)) == nil)
	}

	@Test func versionIsNeverZero() {
		#expect(PangeaWire.hash(Data()) != 0)
	}
}

@Suite("Profile photos and names")
@MainActor
struct ProfileStoreTests {

	@Test func compressedPhotoFitsInAFewPackets() throws {
		let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).image { context in
			for row in 0..<30 {
				UIColor(hue: CGFloat(row) / 30, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
				context.fill(CGRect(x: 0, y: row * 30, width: 1200, height: 30))
			}
		}
		let data = try #require(PhotoCompressor.avatarData(from: image))
		#expect(data.count <= PhotoCompressor.limit)
		#expect(PhotoChunk.split(data).count <= PhotoChunk.maxChunks)
		let decoded = try #require(UIImage(data: data))
		#expect(decoded.size.width >= 192) // close to 256 px for a simple image
	}

	@Test func namePriorityIsNicknameThenCardThenRadio() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		let store = ProfileStore(folder: folder)
		#expect(store.name(num: 5, radioName: "Radio Name") == "Radio Name")
		store.receivedCard(ProfileCard(displayName: "Sam Rivera", emoji: "", color: 0, photoVersion: 0), from: 5, channel: nil)
		#expect(store.name(num: 5, radioName: "Radio Name") == "Sam Rivera")
		store.setNickname("  Sammy ", for: 5)
		#expect(store.name(num: 5, radioName: "Radio Name") == "Sammy")
		store.setNickname("", for: 5)
		#expect(store.name(num: 5, radioName: "Radio Name") == "Sam Rivera")

		// Survives a relaunch.
		store.setNickname("Sammy", for: 5)
		#expect(ProfileStore(folder: folder).name(num: 5, radioName: nil) == "Sammy")
	}

	@Test func photoOfferTracksDownloadAndDismiss() {
		let store = ProfileStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
		store.receivedCard(ProfileCard(displayName: "Sam", emoji: "", color: 0, photoVersion: 10), from: 5, channel: 2)
		#expect(store.profile(5)?.hasPhotoOffer == true)
		#expect(store.profile(5)?.lastChannel == 2)

		store.declinePhoto(for: 5)
		#expect(store.profile(5)?.hasPhotoOffer == false)
		#expect(store.profile(5)?.canUpdatePhoto == true) // still available from their profile

		store.savePhoto(Data([1, 2, 3]), version: 10, for: 5)
		#expect(store.profile(5)?.canUpdatePhoto == false)

		// A new photo asks again.
		store.receivedCard(ProfileCard(displayName: "Sam", emoji: "", color: 0, photoVersion: 11), from: 5, channel: nil)
		#expect(store.profile(5)?.hasPhotoOffer == true)
		#expect(store.profile(5)?.lastChannel == 2)
	}
}

@Suite("Emoji catalog")
struct EmojiCatalogTests {

	private var all: [EmojiCatalog.Emoji] { EmojiCatalog.groups.flatMap(\.emoji) }

	@Test func hasTheFullSet() {
		#expect(EmojiCatalog.groups.count == 9)
		#expect(all.count > 1800)
		#expect(all.contains { $0.emoji == "🏳️‍🌈" })
		#expect(all.contains { $0.emoji == "🇺🇸" })
	}

	@Test func skinTonesAreVariantsOfTheirBase() throws {
		let wave = try #require(all.first { $0.emoji == "👋" })
		#expect(wave.variants == ["👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"])
		let astronaut = try #require(all.first { $0.emoji == "🧑‍🚀" })
		#expect(astronaut.variants.count == 5)
		let handshake = try #require(all.first { $0.emoji == "🤝" })
		#expect(handshake.variants.count >= 5)
		// Variants aren't listed again on their own.
		#expect(!all.contains { $0.emoji == "👋🏽" })
	}

	@Test func everyEmojiFitsOnACard() throws {
		for item in all {
			for emoji in [item.emoji] + item.variants {
				let card = ProfileCard(displayName: "Sam", emoji: emoji, color: 0, photoVersion: 0)
				let payload = try #require(card.payload)
				#expect(ProfileCard(payload: payload)?.emoji == emoji, "\(item.name)")
			}
		}
	}
}
