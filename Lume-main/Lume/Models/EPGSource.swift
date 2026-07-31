import Foundation
import SwiftData

/// A standalone XMLTV guide source. EPG is no longer pulled as part of a
/// playlist sync — every guide URL (a provider's `xmltv.php`, an m3u's
/// `url-tvg`, or a user-supplied external XMLTV feed) is represented here and
/// refreshed on its own schedule by `EPGSyncManager`.
///
/// A source is either *playlist-linked* (`playlistID != nil`) — created and
/// kept in step with a playlist by `EPGSourceReconciler` — or *manual*, added
/// by the user in EPG settings and editable/removable there.
@Model
final class EPGSource {
    var id: UUID = UUID()
    var name: String
    /// The XMLTV URL to download. For playlist-linked Xtream sources this is the
    /// resolved `xmltv.php` URL (credentials embedded); for m3u it is the
    /// playlist's guide URL; for manual sources it is whatever the user entered.
    var url: String

    /// The playlist this source was derived from, or `nil` for a manual source.
    var playlistID: UUID?

    var isEnabled: Bool = true
    var lastSyncDate: Date?
    var syncStatusRaw: String = SyncStatus.idle.rawValue

    var addedAt: Date = Date()

    init(name: String, url: String, playlistID: UUID? = nil) {
        self.name = name
        self.url = url
        self.playlistID = playlistID
    }
}

extension EPGSource {
    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .idle }
        set { syncStatusRaw = newValue.rawValue }
    }

    /// Manual sources can be renamed and deleted; playlist-linked ones are
    /// managed automatically and only their enabled state is user-editable.
    var isManual: Bool {
        playlistID == nil
    }
}
