//
//  PangeaTestStore.swift
//  MeshtasticTests
//

import Foundation
import SwiftData
@testable import Meshtastic

/// A store of its own for one test, in memory, so counts and deletes see only that test's rows.
/// Keep the container for as long as the test uses its contexts.
@MainActor
enum PangeaTestStore {
	static func make() -> ModelContainer {
		// swiftlint:disable:next force_try
		try! ModelContainer(
			for: Schema(MeshtasticSchema.allModels),
			configurations: ModelConfiguration(isStoredInMemoryOnly: true)
		)
	}
}

extension ModelContext {
	/// Inserts `model` and hands it back, for building test rows inline.
	func add<T: PersistentModel>(_ model: T) -> T {
		insert(model)
		return model
	}

	/// Every message id in the store and pending in this context.
	func messageIds() -> Set<Int64> {
		Set(((try? fetch(FetchDescriptor<MessageEntity>())) ?? []).map(\.messageId))
	}
}
