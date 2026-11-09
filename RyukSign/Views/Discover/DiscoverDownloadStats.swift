//
//  DiscoverDownloadStats.swift
//  RyukSign
//
//  Download counts for apps released on GitHub, from the releases API. Sources
//  don't carry counts, so popularity only covers GitHub-hosted IPAs. Counts are
//  sampled about once a day, which turns the totals into downloads per week.
//

import Foundation
import OSLog

struct DownloadStat: Codable, Hashable {
	/// IPA downloads across the repository's recent releases.
	var total: Int
	/// Downloads in the last week: the difference from a week-old sample when one
	/// exists, otherwise estimated from how recently each release went out.
	var recent: Int
}

@MainActor
final class DiscoverDownloadStats: ObservableObject {
	static let shared = DiscoverDownloadStats()

	static let hotWindow: TimeInterval = 7 * 24 * 60 * 60

	/// Bumped once per fetch round so views re-read without reacting to every repository.
	@Published private(set) var revision = 0

	private struct _Sample: Codable {
		let date: Date
		let total: Int
	}

	private struct _Entry: Codable {
		var fetchedAt: Date
		var etag: String?
		var total: Int
		var estimatedRecent: Int
		var samples: [_Sample]
	}

	private static let _refreshInterval: TimeInterval = 6 * 60 * 60
	private static let _sampleInterval: TimeInterval = 20 * 60 * 60
	private static let _sampleRetention: TimeInterval = 45 * 24 * 60 * 60
	/// Unauthenticated calls share 60 an hour with the self-updater; leave it some.
	private static let _rateLimitReserve = 5

	private var _entries: [String: _Entry] = [:]
	private var _isFetching = false
	private var _blockedUntil: Date?

	private let _fileURL = FileManager.default
		.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		.appendingPathComponent("DiscoverDownloadStats.json")

	private init() {
		if
			let data = try? Data(contentsOf: _fileURL),
			let entries = try? JSONDecoder().decode([String: _Entry].self, from: data)
		{
			_entries = entries
		}
	}

	/// `owner/repo` for an IPA attached to a GitHub release.
	nonisolated static func repository(for url: URL?) -> String? {
		guard let url, let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else {
			return nil
		}
		let parts = url.pathComponents.filter { $0 != "/" }
		guard parts.count >= 6, parts[2] == "releases", parts[3] == "download" else { return nil }
		return "\(parts[0])/\(parts[1])".lowercased()
	}

	func stat(for repository: String?) -> DownloadStat? {
		guard let repository, let entry = _entries[repository], entry.total > 0 else { return nil }
		return DownloadStat(total: entry.total, recent: _recent(entry))
	}

	/// Fetches stale repositories, in the order given, until the rate limit runs out.
	func refresh(_ repositories: [String]) {
		guard !_isFetching else { return }
		if let blockedUntil = _blockedUntil, blockedUntil > Date() { return }

		var seen = Set<String>()
		let stale = repositories.filter { repository in
			guard seen.insert(repository).inserted else { return false }
			guard let entry = _entries[repository] else { return true }
			return Date().timeIntervalSince(entry.fetchedAt) > Self._refreshInterval
		}
		guard !stale.isEmpty else { return }

		_isFetching = true
		Task {
			defer {
				_isFetching = false
				_save()
				revision += 1
			}

			for repository in stale {
				guard await _fetch(repository) else { break }
			}
		}
	}

	// MARK: Fetching

	/// Returns false once the rate limit is reached.
	private func _fetch(_ repository: String) async -> Bool {
		guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100") else {
			return true
		}

		var request = URLRequest(url: url)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		if let etag = _entries[repository]?.etag {
			request.setValue(etag, forHTTPHeaderField: "If-None-Match")
		}

		let data: Data
		let http: HTTPURLResponse
		do {
			let (body, response) = try await URLSession.shared.data(for: request)
			guard let response = response as? HTTPURLResponse else { return true }
			data = body
			http = response
		} catch {
			return true
		}

		let remaining = Int(http.value(forHTTPHeaderField: "X-RateLimit-Remaining") ?? "") ?? 1
		let reset = Double(http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "").map(Date.init(timeIntervalSince1970:))

		switch http.statusCode {
		case 200:
			_store(repository, releases: data, etag: http.value(forHTTPHeaderField: "ETag"))
		case 304:
			if var entry = _entries[repository] {
				entry.fetchedAt = Date()
				entry.samples = Self._sampled(entry.samples, total: entry.total)
				_entries[repository] = entry
			}
		case 403, 429:
			_blockedUntil = reset ?? Date().addingTimeInterval(60 * 60)
			Logger.misc.info("Discover download stats paused by the GitHub rate limit")
			return false
		default:
			// Gone or private; don't ask again until the next refresh window.
			_entries[repository] = _Entry(fetchedAt: Date(), etag: nil, total: 0, estimatedRecent: 0, samples: [])
		}

		if remaining <= Self._rateLimitReserve {
			_blockedUntil = reset ?? Date().addingTimeInterval(60 * 60)
			return false
		}
		return true
	}

	private struct _Release: Decodable {
		struct Asset: Decodable {
			let name: String
			let download_count: Int
		}
		let published_at: Date?
		let assets: [Asset]
	}

	private func _store(_ repository: String, releases data: Data, etag: String?) {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		guard let releases = try? decoder.decode([_Release].self, from: data) else { return }

		let now = Date()
		var total = 0
		var estimatedRecent = 0.0
		for release in releases {
			let count = release.assets
				.filter { $0.name.lowercased().hasSuffix(".ipa") || $0.name.lowercased().hasSuffix(".tipa") }
				.reduce(0) { $0 + $1.download_count }
			total += count

			// Spread each release's downloads over its age to guess the last week's share.
			if let published = release.published_at {
				let age = max(now.timeIntervalSince(published), 24 * 60 * 60)
				estimatedRecent += Double(count) * min(1, Self.hotWindow / age)
			}
		}

		_entries[repository] = _Entry(
			fetchedAt: now,
			etag: etag,
			total: total,
			estimatedRecent: Int(estimatedRecent),
			samples: Self._sampled(_entries[repository]?.samples ?? [], total: total)
		)
	}

	/// Adds a sample at most about once a day and drops old ones.
	private static func _sampled(_ samples: [_Sample], total: Int) -> [_Sample] {
		let now = Date()
		var samples = samples
		if now.timeIntervalSince(samples.last?.date ?? .distantPast) > _sampleInterval {
			samples.append(_Sample(date: now, total: total))
		}
		samples.removeAll { now.timeIntervalSince($0.date) > _sampleRetention }
		return samples
	}

	/// A measured weekly delta once a sample is a week old, else the estimate.
	private func _recent(_ entry: _Entry) -> Int {
		let now = Date()
		if let weekOld = entry.samples.last(where: { now.timeIntervalSince($0.date) >= Self.hotWindow }),
		   now.timeIntervalSince(weekOld.date) <= Self.hotWindow * 2 {
			return max(0, entry.total - weekOld.total)
		}
		return entry.estimatedRecent
	}

	private func _save() {
		guard let data = try? JSONEncoder().encode(_entries) else { return }
		try? data.write(to: _fileURL, options: .atomic)
	}
}
