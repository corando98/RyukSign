//
//  PinnedSourcesManager.swift
//  RyukSign
//
//  Sources the user has starred, listed above the rest.
//

import Foundation
import Combine

final class PinnedSourcesManager: ObservableObject {
	static let shared = PinnedSourcesManager()

	static let defaultsKey = "RyukSign.pinnedSourceIdentifiers"

	/// Pinned source identifiers. Mutated on the main thread (drives UI).
	@Published private(set) var identifiers: Set<String>

	private init() {
		identifiers = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
	}

	/// Same key the exclusion list uses, so a source without an identifier still pins.
	static func identifier(for source: AltSource) -> String {
		source.identifier ?? source.sourceURL?.absoluteString ?? ""
	}

	func isPinned(_ source: AltSource) -> Bool {
		identifiers.contains(Self.identifier(for: source))
	}

	func toggle(_ source: AltSource) {
		let id = Self.identifier(for: source)
		guard !id.isEmpty else { return }
		if identifiers.contains(id) {
			identifiers.remove(id)
		} else {
			identifiers.insert(id)
		}
		UserDefaults.standard.set(Array(identifiers), forKey: Self.defaultsKey)
	}

	/// Pinned sources first, keeping the incoming order within each group.
	func sorted<S: Sequence>(_ sources: S) -> [AltSource] where S.Element == AltSource {
		let all = Array(sources)
		return all.filter(isPinned) + all.filter { !isPinned($0) }
	}
}
