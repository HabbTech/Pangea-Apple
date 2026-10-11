//
//  ContactProfileSheet.swift
//  Pangea
//
//  Someone else's profile: their photo and name, their code, a private
//  nickname, and the button to fetch their latest photo.
//

import SwiftUI

struct ContactProfileSheet: View {
	@Environment(\.managedObjectContext) private var context
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var store = ProfileStore.shared
	@ObservedObject var router: Router
	let num: Int64

	@State private var nickname = ""
	@State private var copied = false

	private var user: UserEntity? { existingUser(num: num, context: context) }
	private var profile: ContactProfile? { store.profile(num) }
	private var code: String { PangeaCode.code(for: num) }

	var body: some View {
		NavigationStack {
			Form {
				Section {
					VStack(spacing: 10) {
						PangeaAvatar(num: num, shortName: user?.shortName, size: 110)
						Text(store.name(num: num, radioName: user?.longName))
							.font(.title2.bold())
							.multilineTextAlignment(.center)
						if let shared = sharedName, shared != store.name(num: num, radioName: user?.longName) {
							Text(shared)
								.foregroundStyle(.secondary)
						}
						Button {
							UIPasteboard.general.string = code
							copied = true
						} label: {
							Label(copied ? "Copied" : code, systemImage: copied ? "checkmark" : "doc.on.doc")
								.font(.subheadline.monospaced())
						}
						.buttonStyle(.borderless)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 8)
					.listRowBackground(Color.clear)
				}

				Section {
					TextField("Add a nickname", text: $nickname)
						.onSubmit { store.setNickname(nickname, for: num) }
				} header: {
					Text("Nickname")
				} footer: {
					Text("Only you can see this.")
				}

				if profile?.canUpdatePhoto == true || store.downloading.contains(num) {
					Section {
						if store.downloading.contains(num) {
							VStack(alignment: .leading, spacing: 8) {
								Text("Downloading photo… \(Int((store.downloadProgress[num] ?? 0) * 100))%")
								ProgressView(value: store.downloadProgress[num] ?? 0)
							}
						} else if ProfileSync.canRequestPhoto(from: num) {
							Button("Update Profile Photo") {
								ProfileSync.requestPhoto(from: num)
							}
						} else {
							Text("Send them a message to get their photo.")
								.foregroundStyle(.secondary)
						}
					} footer: {
						Text("Photos download over the radio in a few minutes. You can keep chatting while it does.")
					}
				}

				Section {
					Button {
						store.setNickname(nickname, for: num)
						dismiss()
						router.messagesState = .directMessages(userNum: num)
						router.selectedTab = .messages
					} label: {
						Label("Send Message", systemImage: "bubble.left.fill")
					}
				}
			}
			.navigationTitle("Profile")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") {
						store.setNickname(nickname, for: num)
						dismiss()
					}
				}
			}
			.onAppear { nickname = profile?.nickname ?? "" }
		}
	}

	/// The name they picked (in Pangea, or on their radio), shown under a nickname.
	private var sharedName: String? {
		if let display = profile?.card?.displayName, !display.isEmpty { return display }
		return user?.longName
	}
}
