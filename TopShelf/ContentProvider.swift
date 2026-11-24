import TVServices

/// Fills the Top Shelf with live games for the user's teams and Continue Watching,
/// from what Tellio last published.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let snapshot = TopShelfStore.read()
        TopShelfStore.recordRead(cards: snapshot?.cardCount ?? 0)
        guard let snapshot, !snapshot.isEmpty else {
            completionHandler(nil)
            return
        }
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        if !snapshot.live.isEmpty {
            let section = TVTopShelfItemCollection(items: snapshot.live.map(Self.item))
            section.title = String(localized: "Live now")
            sections.append(section)
        }
        if !snapshot.continueWatching.isEmpty {
            let section = TVTopShelfItemCollection(items: snapshot.continueWatching.map(Self.item))
            section.title = String(localized: "Continue Watching")
            sections.append(section)
        }
        if !snapshot.upcoming.isEmpty {
            let section = TVTopShelfItemCollection(items: snapshot.upcoming.map(Self.item))
            section.title = String(localized: "Coming up")
            sections.append(section)
        }
        if !snapshot.myList.isEmpty {
            let section = TVTopShelfItemCollection(items: snapshot.myList.map(Self.item))
            section.title = String(localized: "My List")
            sections.append(section)
        }
        if !snapshot.trending.isEmpty {
            let section = TVTopShelfItemCollection(items: snapshot.trending.map(Self.item))
            section.title = String(localized: "Trending")
            sections.append(section)
        }
        completionHandler(TVTopShelfSectionedContent(sections: sections))
    }

    private static func item(_ source: TopShelfItem) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: source.id)
        item.title = source.title
        item.imageShape = .hdtv
        if let string = source.imageURL, let url = URL(string: string) {
            item.setImageURL(url, for: .screenScale1x)
            item.setImageURL(url, for: .screenScale2x)
        }
        if let url = URL(string: source.link) {
            item.displayAction = TVTopShelfAction(url: url)
            item.playAction = TVTopShelfAction(url: url)
        }
        if let progress = source.progress {
            item.playbackProgress = progress
        }
        return item
    }
}
