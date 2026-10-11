//
//  ProfileEditorSheet.swift
//  Pangea
//
//  My photo, emoji, color and name. Pangea users see all of it; other
//  Meshtastic apps see the name, which is also saved to the radio.
//

import SwiftUI
import PhotosUI
import OSLog

struct ProfileEditorSheet: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var store = ProfileStore.shared

	@State private var name: String
	@State private var emoji: String
	@State private var color: UInt8
	/// nil = unchanged, .some(nil) = removed, .some(data) = new photo
	@State private var photo: Data??
	@State private var pickerItem: PhotosPickerItem?
	@State private var isSaving = false
	@State private var error: String?
	@FocusState private var emojiFocused: Bool

	private let originalName: String

	static let suggestedEmoji = ["😀", "😎", "🤠", "🥾", "🏕️", "⛰️", "🌲", "🔥", "🐻", "🦊", "🐺", "🦅", "🚙", "📡", "🎣", "⭐️"]

	init(currentName: String) {
		let me = ProfileStore.shared.me
		originalName = currentName
		_name = State(initialValue: me.displayName.isEmpty ? currentName : me.displayName)
		_emoji = State(initialValue: me.emoji)
		_color = State(initialValue: me.color)
	}

	private var trimmedName: String {
		name.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private var previewPhoto: UIImage? {
		switch photo {
		case .some(.some(let data)): return UIImage(data: data)
		case .some(.none): return nil
		case .none: return store.myPhoto
		}
	}

	private var hasPhoto: Bool { previewPhoto != nil }

	var body: some View {
		NavigationStack {
			Form {
				Section {
					VStack(spacing: 14) {
						MyAvatar(photo: previewPhoto, useSavedPhoto: false, emoji: emoji, color: color, initials: trimmedName.isEmpty ? "" : RadioAutoConfig.shortName(for: trimmedName), size: 110)
						HStack(spacing: 12) {
							PhotosPicker(selection: $pickerItem, matching: .images) {
								Text(hasPhoto ? "Change Photo" : "Add Photo")
							}
							.buttonStyle(.bordered)
							.buttonBorderShape(.capsule)
							if hasPhoto {
								Button("Remove", role: .destructive) {
									photo = .some(nil)
								}
								.buttonStyle(.bordered)
								.buttonBorderShape(.capsule)
							}
						}
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 8)
					.listRowBackground(Color.clear)
				}

				Section {
					TextField("Your name", text: $name)
						.textContentType(.name)
						.onChange(of: name) { _, value in
							if value.utf8.count > ProfileCard.maxNameBytes {
								name = ProfileCard.clamp(value, bytes: ProfileCard.maxNameBytes)
							}
						}
				} header: {
					Text("Name")
				} footer: {
					Text("People see this when you message them.")
				}

				Section {
					LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
						ForEach(Self.suggestedEmoji, id: \.self) { item in
							Button {
								emoji = emoji == item ? "" : item
							} label: {
								Text(item)
									.font(.title2)
									.frame(width: 38, height: 38)
									.background(emoji == item ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
							}
							.buttonStyle(.plain)
						}
					}
					.padding(.vertical, 4)
					HStack {
						TextField("Or type any emoji", text: $emoji)
							.focused($emojiFocused)
							.onChange(of: emoji) { _, value in
								// Keep just the last emoji typed; drop letters and numbers.
								guard let last = value.last else { return }
								let isEmoji = last.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0xFF) }
								let cleaned = isEmoji ? String(last) : ""
								if cleaned != value { emoji = cleaned }
							}
						if !emoji.isEmpty {
							Button("Clear") { emoji = "" }
								.buttonStyle(.borderless)
						}
					}
				} header: {
					Text("Emoji")
				} footer: {
					Text("Shown when you don't have a photo, or until a friend downloads it.")
				}

				Section("Color") {
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
						}
					}
					.padding(.vertical, 6)
				}

				Section {
				} footer: {
					Text("Your photo is only sent to people you message and groups you're in, and only when they choose to download it.")
				}

				if let error {
					Section {
						Label(error, systemImage: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
					}
				}
			}
			.navigationTitle("Your Profile")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					if isSaving {
						ProgressView()
					} else {
						Button("Save") { Task { await save() } }
							.disabled(trimmedName.isEmpty)
					}
				}
			}
			.onChange(of: pickerItem) { _, item in
				guard let item else { return }
				Task {
					guard let data = try? await item.loadTransferable(type: Data.self),
						  let image = UIImage(data: data),
						  let small = PhotoCompressor.avatarData(from: image) else {
						error = String(localized: "Couldn't use that photo. Try a different one.")
						return
					}
					error = nil
					photo = .some(small)
				}
			}
		}
	}

	private func save() async {
		isSaving = true
		defer { isSaving = false }
		if trimmedName != originalName {
			guard accessoryManager.state == .subscribed else {
				// Saved here now; the radio gets it the next time it connects.
				ProfileSync.pendingRadioName = trimmedName
				store.updateMe(displayName: trimmedName, emoji: emoji, color: color, photo: photo)
				dismiss()
				return
			}
			ProfileSync.pendingRadioName = nil
			do {
				_ = try await RadioAutoConfig.apply(name: trimmedName, region: nil, accessoryManager: accessoryManager)
			} catch {
				Logger.services.error("👤 [Profiles] Name change failed: \(error.localizedDescription, privacy: .public)")
				self.error = String(localized: "Couldn't save your name. Make sure your radio is connected and try again.")
				return
			}
		}
		let before = store.me
		store.updateMe(displayName: trimmedName, emoji: emoji, color: color, photo: photo)
		if store.me != before && accessoryManager.state == .subscribed {
			ProfileSync.pushUpdatedCard()
		}
		dismiss()
	}
}
