//
//  ContactProfileSheet.swift
//  Pangea
//
//  Someone else's profile: their photo and name, their code, a private
//  nickname, and the button to fetch their latest photo.
//

import SwiftUI

struct ContactProfileSheet: View {
	@Environment(\.modelContext) private var context
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var store = ProfileStore.shared
	/// Only whether the radio can take a packet, not everything else AccessoryManager publishes.
	@ObservedObject private var readiness = AccessoryManager.shared.readiness
	@ObservedObject var router: Router
	let num: Int64

	@State private var nickname = ""
	@State private var copied = false
	/// "Update Profile Photo" was tapped and the photo couldn't be asked for.
	@State private var couldntAsk: ProfileSync.PhotoAsk?

	private var user: UserEntity? { existingUser(num: num, context: context) }
	private var profile: ContactProfile? { store.profile(num) }
	private var code: String { PangeaCode.code(for: num) }
	private var radioAway: Bool { !readiness.value.ready }

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
						// A few photos download at a time, over the radio; more wait for one of them to finish.
						let downloading = store.downloading.contains(num)
						let line = ProfileRules.photoLine(downloading: downloading, radioAway: radioAway,
														  full: store.downloading.count >= ProfileOutbox.maxTransfers, lastAsk: couldntAsk)
						if downloading {
							VStack(alignment: .leading, spacing: 8) {
								if let line {
									Text("Downloading photo…")
									PhotoStatusLine(line: line)
								} else {
									Text("Downloading photo… \(Int((store.downloadProgress[num] ?? 0) * 100))%")
								}
								ProgressView(value: store.downloadProgress[num] ?? 0)
							}
						} else if radioAway || ProfileSync.canRequestPhoto(from: num) {
							// Without a radio, whether they can be reached (a group we share) isn't known yet.
							Button("Update Profile Photo") {
								let result = ProfileSync.requestPhoto(from: num)
								couldntAsk = result == .started || result == .alreadyGoing ? nil : result
							}
							.disabled(line != nil)
							if let line {
								PhotoStatusLine(line: line)
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
						router.selectedTab = .messages
						if ContactResolver.hasKey(user) {
							router.messagesState = .directMessages(userNum: num)
						} else {
							// As from New Message: swap keys first, so nothing goes out on the public channel.
							let invite = PangeaCode.Invite(nodeNum: num)
							Task {
								// Let this sheet finish closing before New Message opens.
								try? await Task.sleep(for: .milliseconds(700))
								PangeaInbox.shared.open(invite)
							}
						}
					} label: {
						Label("Send Message", systemImage: "bubble.left.fill")
					}
					let saved = store.isContact(num)
					Button {
						store.setContact(!saved, for: num, radioName: user?.longName)
					} label: {
						Label(saved ? "Remove from Contacts" : "Add to Contacts",
							  systemImage: saved ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.plus")
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
			.onChange(of: store.downloading) { couldntAsk = nil }
			.onChange(of: readiness.value.ready) { couldntAsk = nil }
		}
	}

	/// The name they picked (in Pangea, or on their radio), shown under a nickname.
	private var sharedName: String? {
		if let display = profile?.card?.displayName, !display.isEmpty { return display }
		return user?.longName
	}
}
