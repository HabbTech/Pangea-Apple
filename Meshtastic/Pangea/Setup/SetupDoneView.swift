//
//  SetupDoneView.swift
//  Pangea
//

import SwiftUI

struct SetupDoneView: View {
	var onDone: () -> Void

	var body: some View {
		VStack(spacing: 0) {
			Spacer()
			VStack(spacing: 16) {
				Image(systemName: "checkmark.circle.fill")
					.font(.system(size: 72))
					.foregroundStyle(.green)
					.symbolEffect(.bounce, value: true)
				Text("You're All Set")
					.font(.largeTitle.bold())
				Text("Your radio is ready. You can message anyone nearby with Pangea, no cell service needed.")
					.font(.body)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
			.padding()
			Spacer()
			Button {
				onDone()
			} label: {
				Text("Start Messaging")
					.frame(maxWidth: 400)
			}
			.capsuleButtonStyle()
			.padding(.bottom)
		}
	}
}
