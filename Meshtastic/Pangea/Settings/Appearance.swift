//
//  Appearance.swift
//  Pangea
//
//  Light or dark for the app itself, whatever the device is set to. Set on every
//  window rather than through SwiftUI, so sheets, alerts and the Mac's extra
//  windows follow it too, and Match Device hands the choice straight back.
//

import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
	case system
	case light
	case dark

	/// A `UserDefaults.Keys` case, so Reset App Settings puts it back to Match Device.
	static let defaultsKey = UserDefaults.Keys.pangeaAppearance.rawValue

	var id: Self { self }

	var title: LocalizedStringKey {
		switch self {
		case .system: "Match Device"
		case .light: "Light"
		case .dark: "Dark"
		}
	}

	var style: UIUserInterfaceStyle {
		switch self {
		case .system: .unspecified
		case .light: .light
		case .dark: .dark
		}
	}

	@MainActor
	func apply() {
		#if DEBUG
		// Screenshots pick their own style.
		if MarketingCapture.isActive { return }
		#endif
		for scene in UIApplication.shared.connectedScenes {
			guard let scene = scene as? UIWindowScene else { continue }
			for window in scene.windows {
				window.overrideUserInterfaceStyle = style
			}
		}
	}
}

/// Put on each window's root view: a window that opens later picks up the choice too.
struct AppearanceScope: ViewModifier {
	@AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system

	func body(content: Content) -> some View {
		content
			.onAppear { appearance.apply() }
			// A new window may not be on its scene yet when its view first appears.
			.onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in appearance.apply() }
			.onChange(of: appearance) { _, newValue in newValue.apply() }
	}
}

extension View {
	func appAppearance() -> some View {
		modifier(AppearanceScope())
	}
}
