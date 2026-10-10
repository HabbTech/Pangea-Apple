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
			Messages(
				router: appState.router,
				unreadChannelMessages: $appState.unreadChannelMessages,
				unreadDirectMessages: $appState.unreadDirectMessages
			)
			.tabItem {
				Label("Messages", systemImage: "message")
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
