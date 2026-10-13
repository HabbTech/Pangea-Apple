//
//  Messages.swift
//  Pangea
//
//  Copyright(c) Garth Vander Houwen 8/29/23.
//

import SwiftUI
import CoreData
import OSLog
import TipKit

struct Messages: View {

	@Environment(\.managedObjectContext) var context
	@Environment(\.colorScheme) private var colorScheme
	@ObservedObject	var router: Router
	@Binding var unreadChannelMessages: Int
	@Binding var unreadDirectMessages: Int
	@State var node: NodeInfoEntity?
	@State private var userSelection: UserEntity? // Nothing selected by default.
	@State private var channelSelection: ChannelEntity? // Nothing selected by default.

	@State private var columnVisibility = NavigationSplitViewVisibility.all

	var body: some View {
		NavigationSplitView(columnVisibility: $columnVisibility) {
			List(selection: $router.messagesState) {
				NavigationLink(value: MessagesNavigationState.channels()) {
					Spacer()
					Label {
						Text("Channels")
							.badge(unreadChannelMessages)
							.font(.title2)
							.padding()
					} icon: {
						Image(systemName: "person.2")
							.symbolRenderingMode(.hierarchical)
							.foregroundColor(.accentColor)
							.font(.title2)
							.padding()
					}
				}
				.alignmentGuide(.listRowSeparatorLeading) {
					$0[.leading]
				}
				NavigationLink(value: MessagesNavigationState.directMessages()) {
					Spacer()
					Label {
						Text("Direct Messages")
							.badge(unreadDirectMessages)
							.font(.title2)
							.padding()
					} icon: {
						Image(systemName: "person")
							.symbolRenderingMode(.hierarchical)
							.foregroundColor(.accentColor)
							.font(.title2)
							.padding()
					}
				}
				.alignmentGuide(.listRowSeparatorLeading) {
					$0[.leading]
				}
				Spacer()
				TipView(MessagesTip(), arrowEdge: .top)
					.tipViewStyle(PersistentTip())
					.listRowSeparator(.hidden)
				Spacer()
					.listRowSeparator(.hidden)
			}
			.listStyle(.plain)
			.navigationTitle("Messages")
			.navigationBarTitleDisplayMode(.large)
			.navigationBarItems(leading: MeshtasticLogo(), trailing: NewMessageButton())
		} content: {
			switch router.messagesState {
			case .channels(let channelId, let messageId):
				ChannelList(node: $node, channelSelection: $channelSelection)
					// Removed navigationTitle and navigationBarTitleDisplayMode here.
					// ChannelList.swift now handles this within its own NavigationStack.
			case .directMessages(let userNum, let messageId):
				UserList(node: $node, userSelection: $userSelection)
					// Removed navigationTitle here. UserList will handle this.
			case nil:
				Text("Select a conversation type")
			}
		} detail: {
			// The open list decides which chat shows, so a channel opened earlier doesn't
			// stay up when a contact is picked (or a contact when a channel is).
			switch router.messagesState {
			case .channels:
				if let myInfo = node?.myInfo, let channelSelection {
					ChannelMessageList(myInfo: myInfo, channel: channelSelection)
						.id(channelSelection.objectID)
						// The toolbar is now defined inside ChannelMessageList.swift
				} else {
					Text("Select a channel")
				}
			case .directMessages:
				if let userSelection {
					UserMessageList(user: userSelection)
						.id(userSelection.objectID)
				} else {
					Text("Select a conversation")
				}
			case nil:
				EmptyView()
			}
		}.onChange(of: router.messagesState) {
			setupNavigationState()
		}
	}

	private func setupNavigationState() {
		let nodeId = Int64(UserDefaults.preferredPeripheralNum)
		if nodeId > 0 {
			node = getNodeInfo(id: nodeId, context: context)
		}

		guard let state = router.messagesState else {
			channelSelection = nil
			userSelection = nil
			return
		}

		switch state {
		case .channels(channelId: let channelId, messageId: _):
			userSelection = nil
			if let channelId {
				channelSelection = node?.myInfo?.channels?.first(where: { channel in
					guard let channel = channel as? ChannelEntity else { return false }
					return channel.id == channelId
				}) as? ChannelEntity
			} else {
				channelSelection = nil
				userSelection = nil
			}
		case .directMessages(userNum: let userNum, messageId: _):
			channelSelection = nil
			if let userNum {
				userSelection = getUser(id: userNum, context: context)
			} else {
				channelSelection = nil
				userSelection = nil
			}
		}
	}
}
