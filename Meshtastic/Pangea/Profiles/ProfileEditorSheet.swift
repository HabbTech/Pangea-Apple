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
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var store = ProfileStore.shared

	@State private var name: String
	@State private var emoji: String
	@State private var color: UInt8
	/// nil = unchanged, .some(nil) = removed, .some(data) = new photo
	@State private var photo: Data??
	@State private var pickerItem: PhotosPickerItem?
	@State private var error: String?
	@State private var isLoadingPhoto = false
	/// The photo being read and shrunk; a newer pick cancels it.
	@State private var photoLoad: Task<Void, Never>?
	@State private var showFileImporter = false
	@State private var showAllEmoji = false
	@State private var showPhotoLibrary = false

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

	/// What gets saved: no hidden characters, plain spaces, trimmed. Cleaned here
	/// rather than while typing, so a joiner typed before its next letter isn't lost.
	private var trimmedName: String {
		name.cleanedName(fitting: ProfileCard.maxNameBytes)
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
								loadPhoto { data }
								return true
							}
						HStack(spacing: 12) {
							#if targetEnvironment(macCatalyst)
							// The library opens as a page inside this sheet: on a Mac a picker over
							// the sheet could close without the photo reaching it.
							Button(hasPhoto ? "Change Photo" : "Add Photo") { showPhotoLibrary = true }
								.buttonStyle(.bordered)
								.buttonBorderShape(.capsule)
							// Most pictures on a Mac live in Finder, not the Photos library.
							Button("Choose File…") { showFileImporter = true }
								.buttonStyle(.bordered)
								.buttonBorderShape(.capsule)
							#else
							PhotosPicker(selection: $pickerItem, matching: .images) {
								Text(hasPhoto ? "Change Photo" : "Add Photo")
							}
							.buttonStyle(.bordered)
							.buttonBorderShape(.capsule)
							#endif
							if isLoadingPhoto {
								// A photo that never finishes loading (an iCloud original with
								// no network) mustn't leave Save disabled with no way out.
								Button("Stop") {
									cancelPhotoLoad()
								}
								.buttonStyle(.bordered)
								.buttonBorderShape(.capsule)
							} else if hasPhoto {
								Button("Remove", role: .destructive) {
									cancelPhotoLoad()
									photo = .some(nil)
								}
								.buttonStyle(.bordered)
								.buttonBorderShape(.capsule)
							}
						}
						if let error {
							Label(error, systemImage: "exclamationmark.triangle.fill")
								.font(.footnote)
								.foregroundStyle(.orange)
								.multilineTextAlignment(.center)
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
					EmojiGrid(emoji: $emoji, choices: quickEmoji)
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
					ColorSwatches(color: $color)
				}

				Section {
				} footer: {
					Text("Your photo is only sent to people you message and groups you're in, and only when they choose to download it.")
				}

			}
			.navigationTitle("Your Profile")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") {
						cancelPhotoLoad()
						dismiss()
					}
					.keyboardShortcut(.cancelAction)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") { save() }
						.disabled(trimmedName.isEmpty || isLoadingPhoto)
				}
			}
			.navigationDestination(isPresented: $showAllEmoji) {
				EmojiPickerView { picked in
					emoji = picked
				}
			}
			.navigationDestination(isPresented: $showPhotoLibrary) {
				PhotoLibraryPage { data in
					loadPhoto { data }
				}
			}
			.fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
				guard case .success(let url) = result else { return }
				loadPhoto(readFailure: String(localized: "Couldn't open that file. Try a different one.")) {
					// Read off the main thread, so a large or not-yet-downloaded file doesn't
					// freeze the sheet. The security scope is opened and closed around the
					// read itself; closing it when this callback returns would end access first.
					await Task.detached(priority: .userInitiated) {
						let access = url.startAccessingSecurityScopedResource()
						defer { if access { url.stopAccessingSecurityScopedResource() } }
						return try? Data(contentsOf: url)
					}.value
				}
			}
			.onChange(of: pickerItem) { _, item in
				guard let item else { return }
				// Cleared right away so picking the same photo again still counts.
				pickerItem = nil
				loadPhoto { try? await item.loadTransferable(type: Data.self) }
			}
		}
	}

	/// Reads and shrinks a photo off the main thread, with a spinner on the avatar and
	/// Save held back from the moment it's picked. Only the latest pick is used.
	/// - Parameter readFailure: shown when `read` returns nothing, instead of the
	///   general "Couldn't use that photo".
	private func loadPhoto(readFailure: String? = nil, _ read: @escaping () async -> Data?) {
		photoLoad?.cancel()
		isLoadingPhoto = true
		error = nil
		photoLoad = Task {
			var small: Data?
			let data = await read()
			if let data, !Task.isCancelled {
				small = await Task.detached(priority: .userInitiated) {
					UIImage(data: data).flatMap { PhotoCompressor.avatarData(from: $0) }
				}.value
			}
			guard !Task.isCancelled else { return }
			photoLoad = nil
			isLoadingPhoto = false
			if let small {
				photo = .some(small)
			} else if data == nil, let readFailure {
				error = readFailure
			} else {
				error = String(localized: "Couldn't use that photo. Try a different one.")
			}
		}
	}

	private func cancelPhotoLoad() {
		photoLoad?.cancel()
		photoLoad = nil
		isLoadingPhoto = false
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
		// An edit made while the radio's away is pushed once it's back (`ProfileSync.pushWhenBack`).
		for action in ProfileRules.afterSave(nameChanged: nameChanged, meChanged: store.me != before, radioReady: ProfileSync.radioReady) {
			switch action {
			case .applyName: ProfileSync.applyPendingName()
			case .push: ProfileSync.pushUpdatedCard()
			}
		}
		dismiss()
	}
}

/// The Photos library as a page. It stays open, with a spinner, until the picked photo has
/// been read: closing it at once ended the read on a Mac, and the photo never arrived.
/// Cancel stands in for the back button meanwhile, so a photo that never finishes
/// (an iCloud original with no network) can't hold the sheet.
private struct PhotoLibraryPage: View {
	@Environment(\.dismiss) private var dismiss
	var onPicked: (Data?) -> Void
	@State private var selection: PhotosPickerItem?
	@State private var isReading = false
	@State private var cancelled = false

	var body: some View {
		PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .compatible) {
			EmptyView()
		}
		.photosPickerStyle(.inline)
		.photosPickerDisabledCapabilities(.selectionActions)
		.ignoresSafeArea(edges: .bottom)
		.disabled(isReading)
		.overlay {
			if isReading {
				ZStack {
					Color.black.opacity(0.3)
					ProgressView()
						.controlSize(.large)
				}
				.ignoresSafeArea()
			}
		}
		.navigationTitle("Photos")
		.navigationBarTitleDisplayMode(.inline)
		.navigationBarBackButtonHidden(isReading)
		.toolbar {
			if isReading {
				// The read only ends once the page has slid away, so a photo that arrives
				// meanwhile is dropped here rather than used.
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") {
						cancelled = true
						dismiss()
					}
					.keyboardShortcut(.cancelAction)
				}
			}
		}
		.task(id: selection) {
			guard let item = selection else { return }
			isReading = true
			let data = try? await item.loadTransferable(type: Data.self)
			guard !Task.isCancelled, !cancelled else { return }
			isReading = false
			onPicked(data)
			dismiss()
		}
	}
}
