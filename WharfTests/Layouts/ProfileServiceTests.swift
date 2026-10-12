import XCTest
@testable import Wharf

/// ProfileService over throwaway defaults and a throwaway DockyPreferences:
/// migration, CRUD, trigger bookkeeping, activation, and the guard that stops
/// applying a profile from being mirrored straight back over it.
@MainActor
final class ProfileServiceTests: LayoutTestCase {
    private struct Stack {
        let service: ProfileService
        let prefs: DockyPreferences
        let profileDefaults: UserDefaults
        let prefsDefaults: UserDefaults
    }

    private func makeStack(profileDefaults: UserDefaults? = nil, prefsDefaults: UserDefaults? = nil) -> Stack {
        let profileDefaults = profileDefaults ?? makeDefaults()
        let prefsDefaults = prefsDefaults ?? makeDefaults()
        let prefs = DockyPreferences(defaults: prefsDefaults)
        let service = ProfileService(defaults: profileDefaults, preferences: { prefs })
        prefs.profileMirrorTarget = service
        return Stack(service: service, prefs: prefs, profileDefaults: profileDefaults, prefsDefaults: prefsDefaults)
    }

    private func app(_ id: String) -> PinnedTileItem { .app(bundleIdentifier: id) }

    // MARK: - First launch

    func testFirstLaunchWrapsTheExistingDockInADefaultProfile() {
        let prefsDefaults = makeDefaults()
        let prefs = DockyPreferences(defaults: prefsDefaults)
        // Edits are mirrored somewhere; keep that away from ProfileService.shared.
        prefs.profileMirrorTarget = ProfileService(defaults: makeDefaults(), preferences: { prefs })
        prefs.pinnedItems = [app("com.apple.Safari"), app("com.apple.mail")]
        prefs.hiddenAppBundleIdentifiers = ["com.apple.Maps"]
        let service = ProfileService(defaults: makeDefaults(), preferences: { prefs })

        XCTAssertEqual(service.profiles.count, 1)
        XCTAssertEqual(service.profiles[0].name, "Default")
        XCTAssertEqual(service.profiles[0].pinnedItems.map(\.bundleIdentifier), ["com.apple.Safari", "com.apple.mail"])
        XCTAssertEqual(service.profiles[0].hiddenAppBundleIdentifiers, prefs.hiddenAppBundleIdentifiers)
        XCTAssertEqual(service.activeProfileID, service.profiles[0].id)
        XCTAssertEqual(service.activeProfile?.name, "Default")
    }

    func testFirstLaunchPersistsTheMigration() {
        let stack = makeStack()
        let again = ProfileService(defaults: stack.profileDefaults, preferences: { stack.prefs })
        XCTAssertEqual(again.profiles.map(\.id), stack.service.profiles.map(\.id))
        XCTAssertEqual(again.activeProfileID, stack.service.activeProfileID)
    }

    func testEmptyStoredProfileListIsTreatedAsFirstLaunch() {
        let defaults = makeDefaults()
        defaults.set(Data("[]".utf8), forKey: ProfileService.Keys.profiles)
        let stack = makeStack(profileDefaults: defaults)
        XCTAssertEqual(stack.service.profiles.count, 1)
        XCTAssertEqual(stack.service.profiles[0].name, "Default")
    }

    func testCorruptStoredProfilesFallBackToADefaultProfile() {
        let defaults = makeDefaults()
        defaults.set(Data("garbage".utf8), forKey: ProfileService.Keys.profiles)
        let stack = makeStack(profileDefaults: defaults)
        XCTAssertEqual(stack.service.profiles.count, 1)
        XCTAssertNotNil(stack.service.activeProfile)
    }

    func testOneProfileWithAnUnknownTriggerMustNotWipeTheOthers() throws {
        var work = DockProfile(id: "work", name: "Work")
        work.triggers = [.frontmostApp(FrontmostAppTrigger(id: "t", bundleIdentifier: "com.apple.Xcode"))]
        let home = DockProfile(id: "home", name: "Home")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode([work, home])) as! [[String: Any]]
        json[0]["triggers"] = [["bluetoothProximity": ["_0": ["id": "b"]]]]
        let defaults = makeDefaults()
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: ProfileService.Keys.profiles)

        _ = makeStack(profileDefaults: defaults)

        let stored = defaults.data(forKey: ProfileService.Keys.profiles) ?? Data()
        let text = String(decoding: stored, as: UTF8.self)
        XCTExpectFailure("an undecodable trigger discards every profile and overwrites storage with a fresh Default") {
            XCTAssertTrue(text.contains("\"home\""), "the unaffected profile should survive")
        }
    }

    func testStoredActiveIDOfAnUnknownProfileFallsBackToTheFirst() throws {
        let defaults = makeDefaults()
        let profiles = [DockProfile(id: "a", name: "A"), DockProfile(id: "b", name: "B")]
        defaults.set(try JSONEncoder().encode(profiles), forKey: ProfileService.Keys.profiles)
        defaults.set("zzz", forKey: ProfileService.Keys.activeProfileID)
        XCTAssertEqual(makeStack(profileDefaults: defaults).service.activeProfileID, "a")
    }

    func testStoredActiveIDIsHonouredWhenItExists() throws {
        let defaults = makeDefaults()
        let profiles = [DockProfile(id: "a", name: "A"), DockProfile(id: "b", name: "B")]
        defaults.set(try JSONEncoder().encode(profiles), forKey: ProfileService.Keys.profiles)
        defaults.set("b", forKey: ProfileService.Keys.activeProfileID)
        XCTAssertEqual(makeStack(profileDefaults: defaults).service.activeProfileID, "b")
    }

    func testMissingStoredActiveIDFallsBackToTheFirst() throws {
        let defaults = makeDefaults()
        defaults.set(try JSONEncoder().encode([DockProfile(id: "a", name: "A")]), forKey: ProfileService.Keys.profiles)
        XCTAssertEqual(makeStack(profileDefaults: defaults).service.activeProfileID, "a")
    }

    // MARK: - Creating, renaming, symbols

    func testCreateProfileAppendsAndPersistsWithoutChangingTheActiveProfile() {
        let stack = makeStack()
        let active = stack.service.activeProfileID
        let created = stack.service.createProfile(name: "Focus")
        XCTAssertEqual(stack.service.profiles.map(\.name), ["Default", "Focus"])
        XCTAssertEqual(stack.service.activeProfileID, active)
        let reloaded = ProfileService(defaults: stack.profileDefaults, preferences: { stack.prefs })
        XCTAssertEqual(reloaded.profiles.last?.id, created.id)
    }

    func testCreateProfileUsesTheGivenSymbolOrTheDefaultOne() {
        let stack = makeStack()
        XCTAssertEqual(stack.service.createProfile(name: "A").symbolName, "circle.grid.3x3.fill")
        XCTAssertEqual(stack.service.createProfile(name: "B", symbolName: "moon.fill").symbolName, "moon.fill")
    }

    func testCreateProfileBasedOnAnotherCopiesTheDockButNotTheTriggersOrIdentity() {
        let stack = makeStack()
        var source = DockProfile(name: "Source", pinnedItems: [app("com.a")], hiddenAppBundleIdentifiers: ["com.h"])
        source.triggers = [.frontmostApp(FrontmostAppTrigger(bundleIdentifier: "com.a"))]
        let copy = stack.service.createProfile(name: "Copy", basedOn: source)
        XCTAssertEqual(copy.pinnedItems, source.pinnedItems)
        XCTAssertEqual(copy.hiddenAppBundleIdentifiers, ["com.h"])
        XCTAssertTrue(copy.triggers.isEmpty)
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.name, "Copy")
    }

    func testDuplicateAndEmptyProfileNamesAreAllowed() {
        let stack = makeStack()
        let one = stack.service.createProfile(name: "Same")
        let two = stack.service.createProfile(name: "Same")
        let empty = stack.service.createProfile(name: "")
        XCTAssertNotEqual(one.id, two.id)
        XCTAssertEqual(stack.service.profiles.filter { $0.name == "Same" }.count, 2)
        XCTAssertEqual(empty.name, "")
    }

    func testRenameChangesOnlyTheNamedProfileAndPersists() {
        let stack = makeStack()
        let other = stack.service.createProfile(name: "Other")
        stack.service.renameProfile(id: stack.service.activeProfileID, to: "Renamed")
        XCTAssertEqual(stack.service.activeProfile?.name, "Renamed")
        XCTAssertEqual(stack.service.profiles.first { $0.id == other.id }?.name, "Other")
        let reloaded = ProfileService(defaults: stack.profileDefaults, preferences: { stack.prefs })
        XCTAssertEqual(reloaded.profiles.first?.name, "Renamed")
    }

    func testRenameOfAnUnknownProfileDoesNothing() {
        let stack = makeStack()
        stack.service.renameProfile(id: "missing", to: "X")
        XCTAssertEqual(stack.service.profiles.map(\.name), ["Default"])
    }

    func testUpdateSymbolChangesOnlyThatProfile() {
        let stack = makeStack()
        let other = stack.service.createProfile(name: "Other")
        stack.service.updateProfileSymbol(id: other.id, symbolName: "star.fill")
        XCTAssertEqual(stack.service.profiles.first { $0.id == other.id }?.symbolName, "star.fill")
        XCTAssertEqual(stack.service.profiles[0].symbolName, "house.fill")
        stack.service.updateProfileSymbol(id: "missing", symbolName: "x")
    }

    // MARK: - Triggers

    func testAddUpdateAndRemoveTriggerPersist() {
        let stack = makeStack()
        let id = stack.service.activeProfileID
        let trigger = ProfileTrigger.frontmostApp(FrontmostAppTrigger(id: "t1", bundleIdentifier: "com.a"))
        stack.service.addTrigger(trigger, to: id)
        XCTAssertEqual(stack.service.activeProfile?.triggers, [trigger])

        let changed = ProfileTrigger.frontmostApp(FrontmostAppTrigger(id: "t1", bundleIdentifier: "com.b"))
        stack.service.updateTrigger(changed, in: id)
        XCTAssertEqual(stack.service.activeProfile?.triggers, [changed])
        XCTAssertEqual(ProfileService(defaults: stack.profileDefaults, preferences: { stack.prefs }).activeProfile?.triggers, [changed])

        stack.service.removeTrigger("t1", from: id)
        XCTAssertEqual(stack.service.activeProfile?.triggers, [])
    }

    func testTriggerOperationsOnUnknownProfilesOrTriggersDoNothing() {
        let stack = makeStack()
        let id = stack.service.activeProfileID
        let trigger = ProfileTrigger.space(SpaceTrigger(id: "s", bundleIdentifier: "com.a"))
        stack.service.addTrigger(trigger, to: "missing")
        stack.service.updateTrigger(trigger, in: id)
        stack.service.updateTrigger(trigger, in: "missing")
        stack.service.removeTrigger("s", from: id)
        stack.service.removeTrigger("s", from: "missing")
        XCTAssertEqual(stack.service.activeProfile?.triggers, [])
    }

    func testTriggersStayWithTheirOwnProfile() {
        let stack = makeStack()
        let other = stack.service.createProfile(name: "Other")
        stack.service.addTrigger(.space(SpaceTrigger(id: "s", bundleIdentifier: "com.a")), to: other.id)
        XCTAssertTrue(stack.service.profiles[0].triggers.isEmpty)
        XCTAssertEqual(stack.service.profiles[1].triggers.count, 1)
    }

    func testTriggerOrderIsKept() {
        let stack = makeStack()
        let id = stack.service.activeProfileID
        for name in ["c", "a", "b"] {
            stack.service.addTrigger(.frontmostApp(FrontmostAppTrigger(id: name, bundleIdentifier: name)), to: id)
        }
        XCTAssertEqual(stack.service.activeProfile?.triggers.map(\.id), ["c", "a", "b"])
    }

    // MARK: - Activation

    func testSettingTheActiveProfileLoadsItsDockIntoPreferences() {
        let stack = makeStack()
        let work = stack.service.createProfile(name: "Work", basedOn: DockProfile(name: "t", pinnedItems: [app("com.work")]))
        stack.service.setActiveProfile(id: work.id)
        XCTAssertEqual(stack.service.activeProfileID, work.id)
        XCTAssertEqual(stack.prefs.pinnedItems.map(\.bundleIdentifier), ["com.work"])
    }

    func testSettingTheActiveProfilePersistsTheChoice() {
        let stack = makeStack()
        let other = stack.service.createProfile(name: "Other")
        stack.service.setActiveProfile(id: other.id)
        XCTAssertEqual(stack.profileDefaults.string(forKey: ProfileService.Keys.activeProfileID), other.id)
        XCTAssertEqual(ProfileService(defaults: stack.profileDefaults, preferences: { stack.prefs }).activeProfileID, other.id)
    }

    func testSettingAnUnknownProfileActiveIsIgnored() {
        let stack = makeStack()
        let before = stack.service.activeProfileID
        stack.service.setActiveProfile(id: "missing")
        XCTAssertEqual(stack.service.activeProfileID, before)
    }

    func testSettingTheAlreadyActiveProfileDoesNotReapplyIt() {
        let stack = makeStack()
        let id = stack.service.activeProfileID
        stack.prefs.pinnedItems = [app("com.edited")]
        // Roll the stored profile back behind prefs' back: re-applying it
        // would visibly overwrite the edit.
        stack.service.updateActiveProfile { $0.pinnedItems = [] }
        stack.service.setActiveProfile(id: id)
        XCTAssertEqual(stack.prefs.pinnedItems.map(\.bundleIdentifier), ["com.edited"])
    }

    func testUpdateActiveProfileTouchesOnlyTheActiveOne() {
        let stack = makeStack()
        let other = stack.service.createProfile(name: "Other")
        stack.service.updateActiveProfile { $0.name = "Mutated" }
        XCTAssertEqual(stack.service.profiles[0].name, "Mutated")
        XCTAssertEqual(stack.service.profiles.first { $0.id == other.id }?.name, "Other")
    }

    // MARK: - Mirroring tile edits and the apply guard

    func testEditingTheDockMirrorsIntoTheActiveProfileOnly() {
        let stack = makeStack()
        let other = stack.service.createProfile(name: "Other")
        stack.prefs.pinnedItems = [app("com.edit")]
        XCTAssertEqual(stack.service.profiles[0].pinnedItems.map(\.bundleIdentifier), ["com.edit"])
        XCTAssertTrue(stack.service.profiles.first { $0.id == other.id }?.pinnedItems.isEmpty ?? false)
    }

    func testEveryTileStoreFieldIsMirrored() {
        let stack = makeStack()
        stack.prefs.pinnedItems = [app("com.a")]
        stack.prefs.trailingItems = [TrailingTileItem(id: "trash", kind: .trash)]
        stack.prefs.hiddenAppBundleIdentifiers = ["com.hidden"]
        let active = stack.service.activeProfile
        XCTAssertEqual(active?.pinnedItems, stack.prefs.pinnedItems)
        XCTAssertEqual(active?.trailingItems, stack.prefs.trailingItems)
        XCTAssertEqual(active?.hiddenAppBundleIdentifiers, stack.prefs.hiddenAppBundleIdentifiers)
    }

    func testApplyingAProfileDoesNotMirrorBackOverTheActiveOne() {
        let stack = makeStack()
        stack.prefs.pinnedItems = [app("com.keep")]
        let incoming = DockProfile(name: "Incoming", pinnedItems: [app("com.incoming")], hiddenAppBundleIdentifiers: ["com.hide"])
        stack.prefs.applyProfile(incoming)
        XCTAssertEqual(stack.prefs.pinnedItems.map(\.bundleIdentifier), ["com.incoming"])
        // The still-active profile kept its own data.
        XCTAssertEqual(stack.service.activeProfile?.pinnedItems.map(\.bundleIdentifier), ["com.keep"])
        XCTAssertTrue(stack.service.activeProfile?.hiddenAppBundleIdentifiers.isEmpty ?? false)
    }

    func testTheApplyFlagIsClearedAfterApplyingSoEditsMirrorAgain() {
        let stack = makeStack()
        stack.prefs.applyProfile(DockProfile(name: "Incoming", pinnedItems: [app("com.incoming")]))
        XCTAssertFalse(stack.prefs.isApplyingProfile)
        stack.prefs.pinnedItems = [app("com.after")]
        XCTAssertEqual(stack.service.activeProfile?.pinnedItems.map(\.bundleIdentifier), ["com.after"])
    }

    func testSwitchingAwayAndBackKeepsEachProfilesOwnEdits() {
        let stack = makeStack()
        let first = stack.service.activeProfileID
        let second = stack.service.createProfile(name: "Second").id

        stack.prefs.pinnedItems = [app("com.first")]
        stack.service.setActiveProfile(id: second)
        XCTAssertTrue(stack.prefs.pinnedItems.isEmpty, "the second profile starts empty")

        stack.prefs.pinnedItems = [app("com.second")]
        stack.service.setActiveProfile(id: first)
        XCTAssertEqual(stack.prefs.pinnedItems.map(\.bundleIdentifier), ["com.first"])

        stack.service.setActiveProfile(id: second)
        XCTAssertEqual(stack.prefs.pinnedItems.map(\.bundleIdentifier), ["com.second"])

        let stored = Dictionary(uniqueKeysWithValues: stack.service.profiles.map { ($0.id, $0.pinnedItems.map(\.bundleIdentifier)) })
        XCTAssertEqual(stored[first], ["com.first"])
        XCTAssertEqual(stored[second], ["com.second"])
    }

    func testRapidSwitchingNeverBleedsOneProfileIntoAnother() {
        let stack = makeStack()
        let ids = [stack.service.activeProfileID] + (1...4).map { stack.service.createProfile(name: "P\($0)").id }
        for (index, id) in ids.enumerated() {
            stack.service.setActiveProfile(id: id)
            stack.prefs.pinnedItems = [app("com.p\(index)")]
        }
        for _ in 0..<3 {
            for id in ids { stack.service.setActiveProfile(id: id) }
        }
        for (index, id) in ids.enumerated() {
            let profile = stack.service.profiles.first { $0.id == id }
            XCTAssertEqual(profile?.pinnedItems.map(\.bundleIdentifier), ["com.p\(index)"])
        }
    }

    func testApplyingTheSameProfileTwiceIsHarmless() {
        let stack = makeStack()
        let profile = DockProfile(name: "P", pinnedItems: [app("com.a"), app("com.b")])
        stack.prefs.applyProfile(profile)
        stack.prefs.applyProfile(profile)
        XCTAssertEqual(stack.prefs.pinnedItems.map(\.bundleIdentifier), ["com.a", "com.b"])
        XCTAssertFalse(stack.prefs.isApplyingProfile)
    }

    func testEditsAfterSwitchLandInTheNewProfileNotTheOld() {
        let stack = makeStack()
        let first = stack.service.activeProfileID
        let second = stack.service.createProfile(name: "Second").id
        stack.service.setActiveProfile(id: second)
        stack.prefs.pinnedItems = [app("com.new")]
        XCTAssertTrue(stack.service.profiles.first { $0.id == first }?.pinnedItems.isEmpty ?? false)
    }

    // MARK: - Deleting

    func testTheLastProfileCannotBeDeleted() {
        let stack = makeStack()
        stack.service.deleteProfile(id: stack.service.activeProfileID)
        XCTAssertEqual(stack.service.profiles.count, 1)
    }

    func testDeletingAnInactiveProfileKeepsTheActiveOne() {
        let stack = makeStack()
        let active = stack.service.activeProfileID
        let other = stack.service.createProfile(name: "Other")
        stack.service.deleteProfile(id: other.id)
        XCTAssertEqual(stack.service.profiles.map(\.id), [active])
        XCTAssertEqual(stack.service.activeProfileID, active)
        XCTAssertEqual(ProfileService(defaults: stack.profileDefaults, preferences: { stack.prefs }).profiles.map(\.id), [active])
    }

    func testDeletingTheActiveProfileActivatesTheFirstRemaining() {
        let stack = makeStack()
        let first = stack.service.activeProfileID
        let second = stack.service.createProfile(name: "Second", basedOn: DockProfile(name: "t", pinnedItems: [app("com.second")]))
        stack.service.deleteProfile(id: first)
        XCTAssertEqual(stack.service.profiles.map(\.id), [second.id])
        XCTAssertEqual(stack.service.activeProfileID, second.id)
        XCTAssertEqual(stack.prefs.pinnedItems.map(\.bundleIdentifier), ["com.second"])
        XCTAssertNotNil(stack.service.activeProfile)
    }

    func testDeletingTheActiveProfileIsPersisted() {
        let stack = makeStack()
        let first = stack.service.activeProfileID
        let second = stack.service.createProfile(name: "Second")
        stack.service.deleteProfile(id: first)
        let reloaded = ProfileService(defaults: stack.profileDefaults, preferences: { stack.prefs })
        XCTExpectFailure("deleting the active profile switches profile but never persists the shortened list, so it returns on relaunch") {
            XCTAssertEqual(reloaded.profiles.map(\.id), [second.id])
        }
    }

    func testDeletingAnUnknownProfileDoesNothing() {
        let stack = makeStack()
        stack.service.createProfile(name: "Other")
        stack.service.deleteProfile(id: "missing")
        XCTAssertEqual(stack.service.profiles.count, 2)
    }

    func testProfileOrderIsUserDefinedAndStable() {
        let stack = makeStack()
        for name in ["z", "a", "m"] { stack.service.createProfile(name: name) }
        stack.service.renameProfile(id: stack.service.profiles[1].id, to: "A renamed")
        XCTAssertEqual(stack.service.profiles.map(\.name), ["Default", "A renamed", "a", "m"])
        let reloaded = ProfileService(defaults: stack.profileDefaults, preferences: { stack.prefs })
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Default", "A renamed", "a", "m"])
    }

    func testManyProfilesPersist() {
        let stack = makeStack()
        for index in 0..<150 { stack.service.createProfile(name: "Profile \(index)") }
        XCTAssertEqual(ProfileService(defaults: stack.profileDefaults, preferences: { stack.prefs }).profiles.count, 151)
    }

    func testServiceNeverTouchesTheStandardDefaultsDomain() {
        let before = UserDefaults.standard.data(forKey: ProfileService.Keys.profiles)
        let beforeActive = UserDefaults.standard.string(forKey: ProfileService.Keys.activeProfileID)
        let stack = makeStack()
        stack.service.createProfile(name: "Isolated")
        stack.prefs.pinnedItems = [app("com.iso")]
        XCTAssertEqual(UserDefaults.standard.data(forKey: ProfileService.Keys.profiles), before)
        XCTAssertEqual(UserDefaults.standard.string(forKey: ProfileService.Keys.activeProfileID), beforeActive)
    }
}
