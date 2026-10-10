/*
 Copyright (c) Garth Vander Houwen 2021
 */

import SwiftUI

struct ContentView: View {
	@ObservedObject var appState: AppState
	@EnvironmentObject var accessoryManager: AccessoryManager
	@State var router: Router
	@State var isShowingDeviceOnboardingFlow: Bool = false
	@AppStorage("expertModeEnabled") private var expertModeEnabled: Bool = false
	@ObservedObject private var inbox = PangeaInbox.shared

	/// Standard mode only has Messages and Settings; anything routed elsewhere lands on Messages.
	private func keepSelectionVisible() {
		if !expertModeEnabled && ![.messages, .settings].contains(appState.router.selectedTab) {
			appState.router.selectedTab = .messages
		}
	}

	init(appState: AppState, router: Router) {
		self.appState = appState
		self.router = router
		UITabBar.appearance().scrollEdgeAppearance = UITabBarAppearance(idiom: .unspecified)
	}

	var body: some View {
		TabView(selection: $appState.router.selectedTab) {
			Group {
				if expertModeEnabled {
					Messages(
						router: appState.router,
						unreadChannelMessages: $appState.unreadChannelMessages,
						unreadDirectMessages: $appState.unreadDirectMessages
					)
				} else {
					ChatsView(router: appState.router)
				}
			}
			.tabItem {
				Label(expertModeEnabled ? "Messages" : "Chats", systemImage: "message")
			}
			.tag(NavigationState.Tab.messages)
			.badge(appState.totalUnreadMessages)
			.safeAreaInset(edge: .bottom) {
				if !expertModeEnabled {
					RadioStatusBanner()
				}
			}

			if expertModeEnabled {
				Connect(
						router: appState.router
					)
					.tabItem {
						Label("Connect", systemImage: "link")
					}
					.tag(NavigationState.Tab.connect)

				NodeList(
					router: appState.router
				)
				.tabItem {
					Label("Nodes", systemImage: "flipphone")
				}
				.tag(NavigationState.Tab.nodes)

				MeshMap(router: appState.router)
					.tabItem {
						Label("Mesh Map", systemImage: "map")
					}
					.tag(NavigationState.Tab.map)
			}

			Settings(
				router: appState.router
			)
			.tabItem {
				Label("Settings", systemImage: "gear")
					.font(.title)
			}
			.tag(NavigationState.Tab.settings)
		}
		.sheet(
			isPresented: $isShowingDeviceOnboardingFlow,
			onDismiss: {
				UserDefaults.firstLaunch = false
				accessoryManager.startDiscovery()
				appState.router.selectedTab = .messages
			}, content: {
				DeviceOnboarding()
			}
		)
		.sheet(isPresented: $inbox.isComposing) {
			NewMessageSheet(router: appState.router)
		}
		.sheet(item: $inbox.joinRequest) { invite in
			JoinGroupSheet(router: appState.router, invite: invite)
				.presentationDetents([.medium, .large])
		}
		.sheet(isPresented: $inbox.isScanning) {
			QRScannerSheet { value in
				// Let the scanner finish closing before the next sheet opens.
				Task {
					try? await Task.sleep(for: .milliseconds(700))
					inbox.handle(scanned: value)
				}
			}
		}
		.onAppear {
			if UserDefaults.firstLaunch {
				isShowingDeviceOnboardingFlow = true
			}
			keepSelectionVisible()
		}
		.onChange(of: appState.router.selectedTab) {
			keepSelectionVisible()
		}
		.onChange(of: expertModeEnabled) {
			keepSelectionVisible()
		}
		.onChange(of: UserDefaults.showDeviceOnboarding) {_, newValue in
			isShowingDeviceOnboardingFlow = newValue
		}
	}
}
