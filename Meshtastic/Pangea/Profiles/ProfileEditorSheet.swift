//
//  ProfileEditorSheet.swift
//  Pangea
//
//  My photo, emoji, color and name. Pangea users see all of it; other
//  Meshtastic apps see the name, which is also saved to the radio.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
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
	@State private var error: String?
	@State private var showAllEmoji = false
	@State private var isLoadingPhoto = false
	@State private var showFileImporter = false
	@State private var showPhotosPicker = false

	private let originalName: String

	static let suggestedEmoji = ["😀", "😎", "🤠", "🥾", "🏕️", "⛰️", "🌲", "🔥", "🐻", "🦊", "🐺", "🦅", "🚙", "📡", "🎣", "⭐️"]

	init(currentName: String) {
		let me = ProfileStore.shared.me
		originalName = currentName
		_name = State(initialValue: me.displayName.isEmpty ? currentName : me.displayName)
		_emoji = State(initialValue: me.emoji)
		_color = State(initialValue: me.color)
	}

	/// The suggestions, with a pick from the full list shown first.
	private var quickEmoji: [String] {
		guard !emoji.isEmpty, !Self.suggestedEmoji.contains(emoji) else { return Self.suggestedEmoji }
		return [emoji] + Self.suggestedEmoji.dropLast()
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
							.overlay {
								if isLoadingPhoto {
									ZStack {
										Circle().fill(.black.opacity(0.35))
										ProgressView()
											.controlSize(.large)
											.tint(.white)
									}
									.frame(width: 110, height: 110)
								}
							}
							.dropDestination(for: Data.self) { items, _ in
								guard let data = items.first else { return false }
								usePhoto(data)
								return true
							}
						HStack(spacing: 12) {
							#if targetEnvironment(macCatalyst)
							// On a Mac most pictures live in Finder, not the Photos library.
							Menu {
								Button("Choose File…") { showFileImporter = true }
								Button("Photos Library…") { showPhotosPicker = true }
							} label: {
								Text(hasPhoto ? "Change Photo" : "Add Photo")
							}
							.menuStyle(.button)
							.buttonStyle(.bordered)
							.buttonBorderShape(.capsule)
							#else
							PhotosPicker(selection: $pickerItem, matching: .images) {
								Text(hasPhoto ? "Change Photo" : "Add Photo")
							}
							.buttonStyle(.bordered)
							.buttonBorderShape(.capsule)
							#endif
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
						ForEach(quickEmoji, id: \.self) { item in
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
						Button {
							showAllEmoji = true
						} label: {
							Label("All Emoji", systemImage: "face.smiling")
						}
						Spacer()
						if !emoji.isEmpty {
							Button("Remove", role: .destructive) { emoji = "" }
						}
					}
					.buttonStyle(.borderless)
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
					Button("Save") { save() }
						.disabled(trimmedName.isEmpty || isLoadingPhoto)
				}
			}
			.sheet(isPresented: $showAllEmoji) {
				EmojiPickerSheet { picked in
					emoji = picked
				}
			}
			.photosPicker(isPresented: $showPhotosPicker, selection: $pickerItem, matching: .images)
			.fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
				guard case .success(let url) = result else { return }
				let access = url.startAccessingSecurityScopedResource()
				defer { if access { url.stopAccessingSecurityScopedResource() } }
				if let data = try? Data(contentsOf: url) {
					usePhoto(data)
				} else {
					error = String(localized: "Couldn't open that file. Try a different one.")
				}
			}
			.onChange(of: pickerItem) { _, item in
				guard let item else { return }
				Task {
					if let data = try? await item.loadTransferable(type: Data.self) {
						usePhoto(data)
					} else {
						error = String(localized: "Couldn't use that photo. Try a different one.")
					}
				}
			}
		}
	}

	/// Shrinks the photo off the main thread, with a spinner on the avatar meanwhile.
	private func usePhoto(_ data: Data) {
		isLoadingPhoto = true
		error = nil
		Task {
			let small = await Task.detached(priority: .userInitiated) {
				UIImage(data: data).flatMap { PhotoCompressor.avatarData(from: $0) }
			}.value
			isLoadingPhoto = false
			if let small {
				photo = .some(small)
			} else {
				error = String(localized: "Couldn't use that photo. Try a different one.")
			}
		}
	}

	private func save() {
		// Everything is kept on this device first, so nothing is lost if the radio
		// drops the connection (it restarts to apply a new name).
		let before = store.me
		store.updateMe(displayName: trimmedName, emoji: emoji, color: color, photo: photo)
		let nameChanged = trimmedName != originalName
		if nameChanged {
			ProfileSync.pendingRadioName = trimmedName
		}
		if nameChanged && accessoryManager.state == .subscribed {
			ProfileSync.radioDidConnect()
		} else if store.me != before && accessoryManager.state == .subscribed {
			ProfileSync.pushUpdatedCard()
		}
		dismiss()
	}
}
