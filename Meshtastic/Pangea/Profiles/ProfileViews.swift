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

	/// For VoiceOver, in the same order as `colors`.
	static let names = [
		String(localized: "Orange"), String(localized: "Gold"), String(localized: "Green"), String(localized: "Teal"),
		String(localized: "Blue"), String(localized: "Purple"), String(localized: "Pink"), String(localized: "Gray")
	]

	static func color(_ index: UInt8) -> Color {
		colors[Int(index) % colors.count]
	}
}

enum PhotoCompressor {
	/// 256 px, in up to ~70 radio packets: a few minutes to download, once, when asked.
	static let limit = 12_000

	/// Square and small enough to send over the radio. HEIC holds up far better
	/// than JPEG at this size, so it's tried first.
	static func avatarData(from image: UIImage, limit: Int = PhotoCompressor.limit) -> Data? {
		let side = min(image.size.width, image.size.height)
		guard side > 0 else { return nil }
		for pixels in [256, 224, 192, 160, 128, 96] {
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

	/// Drawn into a bitmap with no alpha channel. UIGraphicsImageRenderer keeps one even
	/// when told the image is opaque, and ImageIO then stores it, making files bigger.
	static func square(_ image: UIImage, side: CGFloat, pixels: Int) -> CGImage? {
		guard let context = CGContext(
			data: nil,
			width: pixels,
			height: pixels,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
		) else { return nil }
		let size = CGSize(width: pixels, height: pixels)
		// White behind transparent images (stickers, PNGs), which would otherwise turn black.
		context.setFillColor(UIColor.white.cgColor)
		context.fill(CGRect(origin: .zero, size: size))
		// UIKit draws top-down; flip so the photo isn't upside down.
		context.translateBy(x: 0, y: size.height)
		context.scaleBy(x: 1, y: -1)
		context.interpolationQuality = .high
		UIGraphicsPushContext(context)
		// Drawing the UIImage applies its orientation, so phone photos come out upright.
		let scale = CGFloat(pixels) / side
		let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
		image.draw(in: CGRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
		UIGraphicsPopContext()
		return context.makeImage()
	}

	/// A received photo is kept only if it really is a small image. A tiny file can
	/// claim to be 10000 × 10000 and cost hundreds of MB once decoded.
	static let maxReceivedPixels = 512

	static func isAcceptableAvatar(_ data: Data) -> Bool {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
			  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			  let width = properties[kCGImagePropertyPixelWidth] as? Int,
			  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
		return width > 0 && height > 0 && width <= maxReceivedPixels && height <= maxReceivedPixels
	}

	/// Decoded at avatar size at most, whatever the file says about itself.
	static func avatarImage(from data: Data) -> UIImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
			  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
				kCGImageSourceThumbnailMaxPixelSize: 256,
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceCreateThumbnailWithTransform: true
			  ] as CFDictionary) else { return nil }
		return UIImage(cgImage: image)
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
					// Up to four letters, as the radio's short name: one line, shrunk to fit the circle.
					Text(initials)
						.font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
						.lineLimit(1)
						.minimumScaleFactor(0.4)
						.padding(.horizontal, size * 0.14)
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
	/// Only whether the radio can take a packet, not everything else AccessoryManager publishes.
	@ObservedObject private var readiness = AccessoryManager.shared.readiness
	@Environment(\.modelContext) private var context
	let nums: [Int64]
	/// "Update" was tapped and none of the photos could be asked for.
	@State private var couldntAsk: ProfileSync.PhotoAsk?

	private var radioAway: Bool { !readiness.value.ready }

	private var offers: [Int64] {
		// Without a radio, who can be reached isn't known; the offer stays, with why it can't go yet.
		nums.filter { store.profile($0)?.hasPhotoOffer == true && !store.downloading.contains($0) && (radioAway || ProfileSync.canRequestPhoto(from: $0)) }
	}

	var body: some View {
		let offers = self.offers
		Group {
			if let busy = nums.first(where: { store.downloading.contains($0) }) {
				let name = store.name(num: busy, radioName: existingUser(num: busy, context: context)?.longName)
				HStack(spacing: 12) {
					ProgressView(value: store.downloadProgress[busy] ?? 0)
						.progressViewStyle(.circular)
					VStack(alignment: .leading, spacing: 2) {
						if let line = ProfileRules.photoLine(downloading: true, radioAway: radioAway, full: false, lastAsk: nil) {
							Text("Getting \(name)'s photo")
							PhotoStatusLine(line: line)
						} else {
							Text("Getting \(name)'s photo… \(Int((store.downloadProgress[busy] ?? 0) * 100))%")
						}
					}
					.font(.subheadline)
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 10)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
				.padding(.horizontal)
				.padding(.top, 4)
			} else if let first = offers.first {
				let name = store.name(num: first, radioName: existingUser(num: first, context: context)?.longName)
				let line = ProfileRules.photoLine(downloading: false, radioAway: radioAway,
												  full: store.downloading.count >= ProfileOutbox.maxTransfers, lastAsk: couldntAsk)
				HStack(spacing: 12) {
					Image(systemName: "person.crop.circle.badge.plus")
						.font(.title2)
						.foregroundStyle(Color.accentColor)
					VStack(alignment: .leading, spacing: 2) {
						Text(offers.count == 1
							 ? "\(name) shared a profile photo."
							 : "\(name) and \(offers.count - 1) more shared profile photos.")
							.font(.subheadline)
						if let line {
							PhotoStatusLine(line: line)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					Button("Update") {
						let results = offers.map { ProfileSync.requestPhoto(from: $0) }
						// Said only when none of them went: whichever reason held them back.
						let asked = results.contains(where: { $0 == .started || $0 == .alreadyGoing })
						couldntAsk = asked ? nil : results.first(where: { $0 == .noRadio }) ?? results.first(where: { $0 == .busy }) ?? results.first
					}
					.buttonStyle(.borderedProminent)
					.tint(.accentFill)
					.buttonBorderShape(.capsule)
					.controlSize(.small)
					.disabled(line != nil)
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
		.onChange(of: store.downloading) { couldntAsk = nil }
		.onChange(of: readiness.value.ready) { couldntAsk = nil }
	}
}

/// Why a photo isn't coming just now. The banner and the profile sheet both use it, so
/// they always say the same thing.
struct PhotoStatusLine: View {
	let line: ProfileRules.PhotoLine

	var body: some View {
		Text(text)
			.font(.footnote)
			.foregroundStyle(.secondary)
	}

	private var text: String {
		switch line {
		case .waitingForRadio:
			return String(localized: "Waiting for your radio…")
		case .connectRadio:
			return String(localized: "Connect your radio to get photos.")
		case .busy:
			return String(localized: "Busy downloading other photos. Try again in a moment.")
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

/// A person in a list: avatar, name, and an optional button on the right. `user` is nil for a
/// saved contact the radio has forgotten; their saved name or code shows instead.
struct ContactRow<Trailing: View>: View {
	@ObservedObject private var store = ProfileStore.shared
	let num: Int64
	let user: UserEntity?
	var size: CGFloat = 36
	@ViewBuilder var trailing: Trailing

	var body: some View {
		HStack {
			PangeaAvatar(num: num, shortName: user?.shortName, size: size)
			Text(store.name(num: num, radioName: user?.longName ?? store.profile(num)?.contactName))
				.lineLimit(1)
			Spacer()
			trailing
		}
	}
}

extension ContactRow where Trailing == EmptyView {
	init(num: Int64, user: UserEntity?, size: CGFloat = 36) {
		self.init(num: num, user: user, size: size) { EmptyView() }
	}
}
