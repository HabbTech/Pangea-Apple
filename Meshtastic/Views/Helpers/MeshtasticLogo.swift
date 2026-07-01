//
//  MeshtasticLogo.swift
//  Pangea
//
//  Copyright(c) Garth Vander Houwen 10/6/22.
//
import SwiftUI

struct MeshtasticLogo: View {

	@Environment(\.colorScheme) var colorScheme
	@ObservedObject private var powerManager = PowerManager.shared

	private var powerModeBinding: Binding<PowerMode> {
		Binding(
			get: { powerManager.selectedMode },
			set: { powerManager.setSelectedMode($0) }
		)
	}

	private var logoImage: some View {
		Image(colorScheme == .dark ? "logo-white" : "logo-black")
			.resizable()
			.scaledToFit()
	}

	private var menu: some View {
		Menu {
			Picker(selection: powerModeBinding) {
				ForEach(PowerMode.allCases) { mode in
					Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
				}
			} label: {
				Label("Power Mode", systemImage: "battery.100")
			}
			.pickerStyle(.inline)

			if powerManager.systemLowPowerMode {
				Text("iOS Low Power Mode is on — temporarily bumped to Expedition")
			}

			Divider()

			Link(destination: URL(string: "meshtastic:///settings/about")!) {
				Label("About Pangea", systemImage: "info.circle")
			}
		} label: {
			logoImage
		}
	}

	var body: some View {
		#if targetEnvironment(macCatalyst)
		VStack {
			menu
		}
		.padding(.bottom, 5)
		.padding(.top, 5)
		#else
		if #available(iOS 26.0, macOS 26.0, *) {
			VStack {
				menu
			}
		} else {
			VStack {
				menu
			}
			.padding(.bottom, 5)
		}
		#endif
	}
}

#Preview {
	MeshtasticLogo()
		.frame(width: 200, height: 44)
}
