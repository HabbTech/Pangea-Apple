//
//  ProfileViews.swift
//  Pangea
//
//  Avatars, and the "has a profile photo" prompt shown in chats.
//

import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum AvatarPalette {
	static let colors: [Color] = [
		Color(red: 0.94, green: 0.33, blue: 0.05), // Pangea orange
		Color(red: 0.98, green: 0.62, blue: 0.10),
		Color(red: 0.20, green: 0.70, blue: 0.40),
		Color(red: 0.10, green: 0.65, blue: 0.70),
		Color(red: 0.20, green: 0.48, blue: 0.95),
		Color(red: 0.45, green: 0.35, blue: 0.90),
		Color(red: 0.85, green: 0.30, blue: 0.60),
		Color(red: 0.45, green: 0.47, blue: 0.52)
	]

	static func color(_ index: UInt8) -> Color {
		colors[Int(index) % colors.count]
	}
}

enum PhotoCompressor {
	/// Fits in 15 radio packets (~30 seconds to download, once).
	static let limit = 2400

	/// Square and small enough to send over the radio. HEIC holds up far better
	/// than JPEG at this size: 128 px usually fits where JPEG only managed 64.
	static func avatarData(from image: UIImage, limit: Int = PhotoCompressor.limit) -> Data? {
		let side = min(image.size.width, image.size.height)
		guard side > 0 else { return nil }
		for pixels in [128, 112, 96, 80, 64, 48] {
			guard let scaled = square(image, side: side, pixels: pixels) else { continue }
			for type in [UTType.heic, .jpeg] {
				for quality in [0.5, 0.4, 0.3] {
					if let data = encode(scaled, type: type, quality: quality), data.count <= limit {
						return data
					}
				}
			}
		}
		return nil
	}

	private static func square(_ image: UIImage, side: CGFloat, pixels: Int) -> CGImage? {
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		format.opaque = true
		let size = CGSize(width: pixels, height: pixels)
		// Drawing the UIImage applies its orientation, so phone photos come out upright.
		return UIGraphicsImageRenderer(size: size, format: format).image { _ in
			let scale = CGFloat(pixels) / side
			let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
			image.draw(in: CGRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
		}.cgImage
	}

	private static func encode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
		guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
		return data as Data
	}
}

/// Photo, then emoji, then initials, the same way across every Pangea screen.
struct PangeaAvatar: View {
	@ObservedObject private var store = ProfileStore.shared
	let num: Int64
	let shortName: String?
	var size: CGFloat = 46

	init(user: UserEntity?, size: CGFloat = 46) {
		num = user?.num ?? 0
		shortName = user?.shortName
		self.size = size
	}

	init(num: Int64, shortName: String?, size: CGFloat = 46) {
		self.num = num
		self.shortName = shortName
		self.size = size
	}

	var body: some View {
		if let photo = store.photo(for: num) {
			Image(uiImage: photo)
				.resizable()
				.scaledToFill()
				.frame(width: size, height: size)
				.clipShape(Circle())
		} else if let card = store.profile(num)?.card, !card.emoji.isEmpty {
			EmojiAvatar(emoji: card.emoji, color: AvatarPalette.color(card.color), size: size)
		} else {
			CircleText(text: shortName ?? "?", color: Color(UIColor(hex: UInt32(truncatingIfNeeded: num))), circleSize: size)
		}
	}
}

struct EmojiAvatar: View {
	let emoji: String
	let color: Color
	var size: CGFloat

	var body: some View {
		Text(emoji)
			.font(.system(size: size * 0.55))
			.frame(width: size, height: size)
			.background(color.gradient, in: Circle())
	}
}

/// My own avatar, from what I've set in my profile.
struct MyAvatar: View {
	@ObservedObject private var store = ProfileStore.shared
	var photo: UIImage?
	/// False while editing, so a removed photo previews as removed.
	var useSavedPhoto = true
	var emoji: String?
	var color: UInt8?
	var initials: String
	var size: CGFloat

	var body: some View {
		let emoji = self.emoji ?? store.me.emoji
		let color = AvatarPalette.color(self.color ?? store.me.color)
		if let image = photo ?? (useSavedPhoto ? store.myPhoto : nil) {
			Image(uiImage: image)
				.resizable()
				.scaledToFill()
				.frame(width: size, height: size)
				.clipShape(Circle())
		} else if !emoji.isEmpty {
			EmojiAvatar(emoji: emoji, color: color, size: size)
		} else {
			Group {
				if initials.isEmpty {
					Image(systemName: "person.fill")
						.font(.system(size: size * 0.45))
				} else {
					Text(initials)
						.font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
				}
			}
			.foregroundStyle(.white)
			.frame(width: size, height: size)
			.background(color.gradient, in: Circle())
		}
	}
}

/// "Sam shared a profile photo · Update / Not Now", like Name & Photo Sharing on iPhone.
struct PhotoUpdateBanner: View {
	@ObservedObject private var store = ProfileStore.shared
	@Environment(\.managedObjectContext) private var context
	let nums: [Int64]

	private var offers: [Int64] {
		nums.filter { store.profile($0)?.hasPhotoOffer == true && !store.downloading.contains($0) && ProfileSync.canRequestPhoto(from: $0) }
	}

	var body: some View {
		let offers = self.offers
		if let first = offers.first {
			let name = store.name(num: first, radioName: existingUser(num: first, context: context)?.longName)
			HStack(spacing: 12) {
				Image(systemName: "person.crop.circle.badge.plus")
					.font(.title2)
					.foregroundStyle(Color.accentColor)
				Text(offers.count == 1
					 ? "\(name) shared a profile photo."
					 : "\(name) and \(offers.count - 1) more shared profile photos.")
					.font(.subheadline)
					.frame(maxWidth: .infinity, alignment: .leading)
				Button("Update") {
					for num in offers {
						ProfileSync.requestPhoto(from: num)
					}
				}
				.buttonStyle(.borderedProminent)
				.buttonBorderShape(.capsule)
				.controlSize(.small)
				Button {
					for num in offers {
						store.declinePhoto(for: num)
					}
				} label: {
					Image(systemName: "xmark")
				}
				.buttonStyle(.borderless)
				.foregroundStyle(.secondary)
				.accessibilityLabel("Not Now")
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
			.padding(.horizontal)
			.padding(.top, 4)
			.transition(.move(edge: .top).combined(with: .opacity))
		}
	}
}

/// A person's name that updates as soon as a nickname or card changes.
struct PangeaName: View {
	@ObservedObject private var store = ProfileStore.shared
	let user: UserEntity

	var body: some View {
		Text(store.name(for: user))
	}
}
