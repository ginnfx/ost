//
//  EPGSourceTests.swift
//  LumeTests
//
//  Covers the reworked EPG handling: guide-URL resolution, the automatic
//  reconciliation of a playlist's EPG source on add/edit/delete, and the
//  EPG-specific refresh schedule.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct EPGSourceTests {
    // MARK: - Guide URL resolution

    @Test func `xtream guide url targets xmltv endpoint with credentials`() throws {
        let playlist = Playlist(name: "P", serverURL: "http://host:8080", username: "user", password: "pass")
        let url = try #require(EPGSourceReconciler.guideURL(for: playlist))
        #expect(url.contains("xmltv.php"))
        #expect(url.contains("username=user"))
        #expect(url.contains("password=pass"))
    }

    @Test func `m3u guide url uses the playlist epg url`() {
        let playlist = Playlist(name: "P", m3uURL: "http://host/list.m3u", epgURL: "http://host/guide.xml")
        #expect(EPGSourceReconciler.guideURL(for: playlist) == "http://host/guide.xml")
    }

    @Test func `m3u without epg url has no guide`() {
        let playlist = Playlist(name: "P", m3uURL: "http://host/list.m3u")
        #expect(EPGSourceReconciler.guideURL(for: playlist) == nil)
    }

    // MARK: - Reconciliation

    @Test func `reconcile creates a linked source for a new playlist`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Provider", serverURL: "http://host:8080", username: "u", password: "p")
        context.insert(playlist)

        EPGSourceReconciler.reconcile(playlist, in: context)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.playlistID == playlist.id)
        #expect(source.isManual == false)
        #expect(source.name == "Provider")
    }

    @Test func `reconcile updates the existing linked source instead of duplicating`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Provider", serverURL: "http://host:8080", username: "u", password: "p")
        context.insert(playlist)
        EPGSourceReconciler.reconcile(playlist, in: context)

        // Edit: rename and change credentials, then reconcile again.
        playlist.name = "Renamed"
        playlist.password = "newpass"
        EPGSourceReconciler.reconcile(playlist, in: context)

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.name == "Renamed")
        #expect(source.url.contains("password=newpass"))
    }

    @Test func `reconcile removes the source when the m3u guide url is cleared`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "P", m3uURL: "http://host/list.m3u", epgURL: "http://host/guide.xml")
        context.insert(playlist)
        EPGSourceReconciler.reconcile(playlist, in: context)
        #expect(try context.fetch(FetchDescriptor<EPGSource>()).count == 1)

        playlist.epgURL = nil
        EPGSourceReconciler.reconcile(playlist, in: context)
        #expect(try context.fetch(FetchDescriptor<EPGSource>()).isEmpty)
    }

    @Test func `reconcile preserves the user's enabled choice`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "P", serverURL: "http://host:8080", username: "u", password: "p")
        context.insert(playlist)
        EPGSourceReconciler.reconcile(playlist, in: context)

        let source = try #require(try context.fetch(FetchDescriptor<EPGSource>()).first)
        source.isEnabled = false
        try context.save()

        EPGSourceReconciler.reconcile(playlist, in: context)
        let after = try #require(try context.fetch(FetchDescriptor<EPGSource>()).first)
        #expect(after.isEnabled == false)
    }

    @Test func `remove deletes only the linked source, never a manual one`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "P", serverURL: "http://host:8080", username: "u", password: "p")
        context.insert(playlist)
        EPGSourceReconciler.reconcile(playlist, in: context)
        let manual = EPGSource(name: "Custom", url: "http://host/custom.xml")
        context.insert(manual)
        try context.save()

        EPGSourceReconciler.remove(playlistID: playlist.id, in: context)
        try context.save()

        let sources = try context.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.count == 1)
        #expect(sources.first?.isManual == true)
    }

    // MARK: - EPG schedule

    @Test func `epg default frequency is daily`() {
        #expect(SyncFrequency.epgDefaultValue == .daily)
        #expect(SyncFrequency.resolveEPG("") == .daily)
        #expect(SyncFrequency.resolveEPG("weekly") == .weekly)
    }
}
