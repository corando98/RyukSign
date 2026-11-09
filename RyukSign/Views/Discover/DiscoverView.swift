//
//  DiscoverView.swift
//  RyukSign
//
//  A storefront over every source: what's hot, apps from pinned sources,
//  what's new, and the full catalog by category.
//

import SwiftUI
import AltSourceKit
import NimbleViews

// MARK: - View
struct DiscoverView: View {
	@StateObject private var _viewModel = SourcesViewModel.shared
	@ObservedObject private var _pinned = PinnedSourcesManager.shared
	@ObservedObject private var _stats = DiscoverDownloadStats.shared
	@ObservedObject private var _tabSelection = TabSelectionObserver.shared

	@AppStorage("RyukSign.discoverSort") private var _sort: DiscoverSort = .name

	@State private var _catalog: DiscoverCatalog = .empty
	/// A rebuild that arrived while the tab was on screen; it waits for the user
	/// so the page never reorders under them.
	@State private var _pending: DiscoverCatalog?
	@State private var _searchText = ""
	@State private var _category: DiscoverCategory?
	@State private var _isAddingPresenting = false

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	private static let _carouselLimit = 20
	private static let _topID = "discover.top"

	private var _isBrowsing: Bool {
		_searchText.isEmpty && _category == nil
	}

	private var _isOnScreen: Bool {
		_tabSelection.selectedTab == .discover
	}

	private var _results: [DiscoverItem] {
		let filtered = _catalog.items.filter { item in
			(_category == nil || item.category == _category) && item.matches(_searchText)
		}
		return _catalog.sorted(filtered, by: _sort)
	}

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Discover")) {
			_content
				.searchable(text: $_searchText, placement: .platform(), prompt: .localized("Search all sources"))
				.refreshable {
					await _viewModel.fetchSources(_sources, refresh: true)
					_apply(_build())
				}
				.toolbar {
					ToolbarItemGroup(placement: .topBarTrailing) {
						_sortMenu
						Button {
							_isAddingPresenting = true
						} label: {
							Image(systemName: "plus")
						}
					}
				}
				.sheet(isPresented: $_isAddingPresenting) {
					SourcesAddView()
						.adaptiveSheetSizing()
				}
		}
		.task(id: Array(_sources)) {
			await _viewModel.fetchSources(_sources)
		}
		.onAppear {
			if _catalog.items.isEmpty { _offer() }
		}
		// Only whole loads count; a refresh republishes sources batch by batch.
		.onReceive(_viewModel.$isFinished.dropFirst().removeDuplicates()) { isFinished in
			if isFinished { DispatchQueue.main.async { _offer() } }
		}
		.onReceive(_pinned.$identifiers.dropFirst()) { _ in
			// Published fires before the new value is stored.
			DispatchQueue.main.async { _offer() }
		}
		.onReceive(_stats.$revision.dropFirst()) { _ in
			DispatchQueue.main.async { _offer() }
		}
		.onChange(of: _tabSelection.selectedTab) { tab in
			if tab != .discover, let pending = _pending {
				_apply(pending)
			}
		}
	}

	@ViewBuilder
	private var _content: some View {
		if _sources.isEmpty {
			NBContentUnavailable(
				.localized("No Repositories"),
				systemImage: "sparkles",
				description: .localized("Add a source to discover apps.")
			) {
				Button {
					_isAddingPresenting = true
				} label: {
					NBButton(.localized("Add Source"), style: .text)
				}
			}
		} else if _catalog.items.isEmpty {
			if _viewModel.isFinished && !_viewModel.sources.isEmpty {
				NBContentUnavailable(
					.localized("No Apps"),
					systemImage: "sparkles",
					description: .localized("Your sources don't list any apps yet.")
				)
			} else {
				NBSkeletonList()
					.padding(.top, 16)
			}
		} else {
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						_categoryChips
							.padding(.bottom, 8)
							.id(Self._topID)

						if _isBrowsing {
							_carousels
						}

						_appList
					}
					.padding(.bottom, 24)
				}
				.overlay(alignment: .top) {
					if let pending = _pending {
						_pendingButton {
							withAnimation(.easeInOut(duration: 0.25)) {
								_apply(pending)
								proxy.scrollTo(Self._topID, anchor: .top)
							}
						}
						.transition(.move(edge: .top).combined(with: .opacity))
					}
				}
			}
		}
	}

	// MARK: Rebuilding

	private func _build() -> DiscoverCatalog {
		DiscoverCatalog(sources: _viewModel.sources, pinned: _pinned, stats: _stats)
	}

	/// Shows a rebuild right away when nothing would move under the user,
	/// otherwise holds it behind the "New updates" button.
	private func _offer() {
		guard _viewModel.isFinished, !_viewModel.sources.isEmpty else { return }

		let candidate = _build()
		_stats.refresh(candidate.repositories)

		if _catalog.items.isEmpty || !_isOnScreen || candidate.signature == _catalog.signature {
			_apply(candidate)
		} else {
			withAnimation(.easeInOut(duration: 0.25)) {
				_pending = candidate
			}
		}
	}

	private func _apply(_ catalog: DiscoverCatalog) {
		_catalog = catalog
		_pending = nil
		if let category = _category, !catalog.categories.contains(where: { $0.category == category }) {
			_category = nil
		}
	}

	private func _pendingButton(action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Label(.localized("New updates"), systemImage: "arrow.up")
				.font(.subheadline.weight(.semibold))
				.padding(.horizontal, 16)
				.padding(.vertical, 9)
				.foregroundStyle(.white)
				.background(Capsule().fill(Color.accentColor))
				.shadow(color: .black.opacity(0.15), radius: 8, y: 3)
		}
		.buttonStyle(.plain)
		.padding(.top, 8)
	}

	private var _sortMenu: some View {
		Menu {
			Picker(.localized("Sort"), selection: $_sort) {
				ForEach(DiscoverSort.allCases, id: \.self) { sort in
					Label(sort.title, systemImage: sort.systemImage).tag(sort)
				}
			}
		} label: {
			Image(systemName: "arrow.up.arrow.down")
		}
	}
}

// MARK: - Extension: Sections
extension DiscoverView {
	@ViewBuilder
	private var _categoryChips: some View {
		if !_catalog.categories.isEmpty {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					_chip(.localized("All"), systemImage: "square.grid.2x2", isSelected: _category == nil) {
						_category = nil
					}
					ForEach(_catalog.categories, id: \.category) { entry in
						_chip(entry.category.title, systemImage: entry.category.systemImage, isSelected: _category == entry.category) {
							_category = _category == entry.category ? nil : entry.category
						}
					}
				}
				.padding(.horizontal)
				.padding(.vertical, 4)
			}
		}
	}

	private func _chip(_ title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
		Button {
			withAnimation(.easeInOut(duration: 0.2)) { action() }
		} label: {
			Label(title, systemImage: systemImage)
				.font(.subheadline.weight(.semibold))
				.padding(.horizontal, 14)
				.padding(.vertical, 8)
				.foregroundStyle(isSelected ? Color.white : Color.primary)
				.background(
					Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemFill))
				)
		}
		.buttonStyle(.plain)
	}

	@ViewBuilder
	private var _carousels: some View {
		let hot = Array(_catalog.hot.prefix(Self._carouselLimit))
		if !hot.isEmpty {
			_carousel(.localized("Hot This Week"), systemImage: "flame.fill", items: hot, showsWeeklyDownloads: true)
		}

		let pinned = Array(_catalog.fromPinnedSources.prefix(Self._carouselLimit))
		if !pinned.isEmpty {
			_carousel(.localized("From Pinned Sources"), systemImage: "star.fill", items: pinned)
		}

		let recent = Array(_catalog.recentlyUpdated.prefix(Self._carouselLimit))
		if !recent.isEmpty {
			_carousel(.localized("New & Updated"), systemImage: "clock.arrow.circlepath", items: recent)
		}
	}

	private func _carousel(_ title: String, systemImage: String, items: [DiscoverItem], showsWeeklyDownloads: Bool = false) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			_header(title, systemImage: systemImage, count: nil)
			ScrollView(.horizontal, showsIndicators: false) {
				LazyHStack(spacing: 12) {
					ForEach(items) { item in
						NavigationLink {
							SourceAppsDetailView(source: item.source, app: item.app)
						} label: {
							DiscoverCardView(item: item, showsWeeklyDownloads: showsWeeklyDownloads)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal)
			}
		}
		.padding(.vertical, 12)
	}

	@ViewBuilder
	private var _appList: some View {
		let results = _results
		_header(
			_category?.title ?? (_searchText.isEmpty ? .localized("All Apps") : .localized("Results")),
			systemImage: _category?.systemImage ?? "square.stack",
			count: results.count
		)
		.padding(.top, 12)

		if results.isEmpty {
			Text(.localized("No apps match your search."))
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity)
				.padding(.vertical, 32)
		}

		ForEach(results) { item in
			NavigationLink {
				SourceAppsDetailView(source: item.source, app: item.app)
			} label: {
				DiscoverRowView(item: item)
			}
			.buttonStyle(.plain)
			.padding(.horizontal)
			.padding(.vertical, 8)

			Divider().padding(.leading, 90)
		}
	}

	private func _header(_ title: String, systemImage: String, count: Int?) -> some View {
		HStack(spacing: 6) {
			Image(systemName: systemImage)
				.foregroundStyle(.secondary)
			Text(title)
			if let count {
				Text("\(count)")
					.foregroundStyle(.secondary)
			}
			Spacer()
		}
		.font(.title3.weight(.bold))
		.padding(.horizontal)
	}
}
