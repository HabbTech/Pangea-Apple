//
//  About.swift
//  Pangea
//
//  Copyright(c) Garth Vander Houwen 10/6/22.
//
import SwiftUI

struct AboutMeshtastic: View {

	let locale = Locale.current

	var body: some View {

		VStack {
			List {
				Section(header: Text("What is Pangea?")) {
					Text("Off-grid, decentralized, mesh network that runs on affordable, low-power radios.")
						.font(.title3)

				}
				Section(header: Text("Apple Apps")) {

					if locale.region?.identifier ?? "US" == "US" {
						HStack {
							Image("SOLAR_NODE")
								.resizable()
								.aspectRatio(contentMode: .fit)
								.frame(width: 75)
								.cornerRadius(5)
								.padding()
							VStack(alignment: .leading) {
								// No link yet.
								Text("Buy Complete Radios (coming soon)")
									.font(.title2)
								Text("Get custom waterproof solar and detection sensor router nodes, aluminium desktop nodes and rugged handsets.")
									.font(.callout)
							}
						}
					}
					// No links yet for sponsoring, reviews or documentation.
					Text("Sponsor App Development (coming soon)")
						.font(.title2)
					Text("Review the app (coming soon)")
						.font(.title2)

					Text("Version: \(Bundle.main.appVersionLong) (\(Bundle.main.appBuild))")
				}

				Section(header: Text("Project information")) {
					Link("Website", destination: URL(string: "https://habb.tech/")!)
						.font(.title2)
					Text("Documentation (coming soon)")
						.font(.title2)
				}
				Text("Pangea® Copyright HABB")
					.font(.caption)
			}
		}
		.navigationTitle("About")
		.navigationBarTitleDisplayMode(.inline)
	}
}

#Preview {
	NavigationView {
		AboutMeshtastic()
	}
}
