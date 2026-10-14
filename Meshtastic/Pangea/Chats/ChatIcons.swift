//
//  ChatIcons.swift
//  Pangea
//
//  The picture a group chat or Everyone Nearby shows: an emoji and a color the user
//  picks, kept on this device. Without one, the globe or the group symbol.
//

import SwiftUI

struct ChatIcon: Codable, Equatable {
	var emoji: String
	var color: UInt8
}

@MainActor
final class ChatIconStore: ObservableObject {
	static let shared = ChatIconStore()

	nonisolated static let defaultsKey = "pangeaChatIcons"

	private let defaults: UserDefaults
	@Published private(set) var icons: [String: ChatIcon]

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		// Each icon is read on its own, so one that won't decode doesn't take the rest with it.
		let saved = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: SavedIcon].self, from: $0) } ?? [:]
		icons = saved.compactMapValues(\.icon).filter { ProfileCard.cleanEmoji($0.value.emoji) == $0.value.emoji && !$0.value.emoji.isEmpty }
	}

	func icon(for key: String) -> ChatIcon? {
		icons[key]
	}

	/// Nil puts the chat back to its symbol.
	func set(_ icon: ChatIcon?, for key: String) {
		if let icon, !ProfileCard.cleanEmoji(icon.emoji).isEmpty {
			icons[key] = icon
		} else {
			icons[key] = nil
		}
		if let data = try? JSONEncoder().encode(icons) {
			defaults.set(data, forKey: Self.defaultsKey)
		}
	}

	/// Clear App Data removes the saved icons from UserDefaults (`RadioPairing.localDefaultsKeys`);
	/// this drops the copy kept here, so the next change doesn't write them back.
	func forgetAll() {
		icons = [:]
	}

	/// Everyone Nearby is one chat whatever its slot holds. A group is its name and key, so
	/// its icon stays with it if it moves slot, and a different group in the same slot
	/// doesn't inherit it.
	static func key(for channel: ChannelEntity) -> String {
		if GroupChats.isEveryone(channel) { return "everyone" }
		return key(name: channel.name ?? "", psk: channel.psk ?? Data())
	}

	nonisolated static func key(name: String, psk: Data) -> String {
		PangeaWire.tag(Data(name.utf8) + Data([0]) + psk).map { String(format: "%02x", $0) }.joined()
	}
}

private struct SavedIcon: Decodable {
	let icon: ChatIcon?

	init(from decoder: Decoder) throws {
		icon = try? ChatIcon(from: decoder)
	}
}

/// A chat's picture, redrawn as soon as its icon changes. Hidden from VoiceOver: the
/// chat's name always sits beside it.
struct ChatIconView: View {
	@ObservedObject private var store = ChatIconStore.shared
	let key: String
	let everyone: Bool
	var size: CGFloat = 46

	var body: some View {
		Group {
			if let icon = store.icon(for: key) {
				EmojiAvatar(emoji: icon.emoji, color: AvatarPalette.color(icon.color), size: size)
			} else {
				Image(systemName: everyone ? "globe" : "person.3.fill")
					.font(.system(size: size * 0.4, weight: .semibold))
					.foregroundStyle(.white)
					.frame(width: size, height: size)
					.background(everyone ? Color.pangeaTertiary : Color.accentColor, in: Circle())
			}
		}
		.accessibilityHidden(true)
	}
}

/// Choosing a chat's emoji and color. Only this device sees it.
struct ChatIconSheet: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var store = ChatIconStore.shared
	let key: String
	let everyone: Bool
	let title: String

	@State private var emoji: String
	@State private var color: UInt8
	@State private var showAllEmoji = false

	init(key: String, everyone: Bool, title: String) {
		self.key = key
		self.everyone = everyone
		self.title = title
		let saved = ChatIconStore.shared.icon(for: key)
		_emoji = State(initialValue: saved?.emoji ?? "")
		_color = State(initialValue: saved?.color ?? (everyone ? 3 : 0))
	}

	private var quickEmoji: [String] {
		guard !emoji.isEmpty, !ProfileEditorSheet.suggestedEmoji.contains(emoji) else { return ProfileEditorSheet.suggestedEmoji }
		return [emoji] + ProfileEditorSheet.suggestedEmoji.dropLast()
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					VStack(spacing: 10) {
						Group {
							if emoji.isEmpty {
								ChatIconView(key: "", everyone: everyone, size: 96)
							} else {
								EmojiAvatar(emoji: emoji, color: AvatarPalette.color(color), size: 96)
							}
						}
						.accessibilityHidden(true)
						Text(title)
							.font(.headline)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 8)
					.listRowBackground(Color.clear)
				}

				Section {
					EmojiGrid(emoji: $emoji, choices: quickEmoji)
					Button {
						showAllEmoji = true
					} label: {
						Label("All Emoji", systemImage: "face.smiling")
					}
					.buttonStyle(.borderless)
				} header: {
					Text("Emoji")
				}

				Section {
					ColorSwatches(color: $color)
						.disabled(emoji.isEmpty)
						.opacity(emoji.isEmpty ? 0.4 : 1)
				} header: {
					Text("Color")
				} footer: {
					if emoji.isEmpty {
						Text("Pick an emoji to choose its color.")
					}
				}

				// Only for a saved icon: before that, Cancel already keeps the default.
				if store.icon(for: key) != nil {
					Section {
						Button("Use Default Icon", role: .destructive) {
							store.set(nil, for: key)
							dismiss()
						}
					}
				}

				Section {
				} footer: {
					Text("Only you see this icon.")
				}
			}
			.navigationDestination(isPresented: $showAllEmoji) {
				EmojiPickerView { picked in
					emoji = picked
				}
			}
			.navigationTitle("Chat Icon")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.keyboardShortcut(.cancelAction)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") {
						store.set(emoji.isEmpty ? nil : ChatIcon(emoji: emoji, color: color), for: key)
						dismiss()
					}
				}
			}
		}
	}
}

/// The quick-pick emoji; tapping the chosen one again clears it.
struct EmojiGrid: View {
	@Binding var emoji: String
	let choices: [String]

	var body: some View {
		LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
			ForEach(choices, id: \.self) { item in
				Button {
					emoji = emoji == item ? "" : item
				} label: {
					Text(item)
						.font(.title2)
						.frame(width: 38, height: 38)
						.background(emoji == item ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
				}
				.buttonStyle(.plain)
				.accessibilityAddTraits(emoji == item ? .isSelected : [])
			}
		}
		.padding(.vertical, 4)
	}
}

struct ColorSwatches: View {
	@Binding var color: UInt8

	var body: some View {
		HStack {
			ForEach(Array(AvatarPalette.colors.enumerated()), id: \.offset) { index, swatch in
				Button {
					color = UInt8(index)
				} label: {
					Circle()
						.fill(swatch.gradient)
						.frame(width: 30, height: 30)
						.overlay {
							if color == UInt8(index) {
								Circle().strokeBorder(.primary, lineWidth: 2.5).padding(-4)
							}
						}
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.plain)
				.accessibilityLabel(AvatarPalette.names[index])
				.accessibilityAddTraits(color == UInt8(index) ? .isSelected : [])
			}
		}
		.padding(.vertical, 6)
	}
}
