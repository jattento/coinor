import Testing

@testable import Coinor

@Test
func conversationStartsWithPermanentMainAndIDETabs() {
    let tabs = ConversationTabMetadata.initial

    #expect(tabs.mainName == "main")
    #expect(
        tabs.orderedTabIDs == [
            ConversationTabMetadata.mainID,
            ConversationTabMetadata.ideID,
        ]
    )
    #expect(tabs.selectedTabID == ConversationTabMetadata.mainID)
    #expect(tabs.nextTabNumber == 1)
}

@Test
func shellTabNamesUseAMonotonicCounter() {
    var tabs = ConversationTabMetadata.initial

    let first = tabs.appendShell(id: "first")
    tabs.closeShell(tabID: first.id)
    let second = tabs.appendShell(id: "second")

    #expect(first.name == "Tab 1")
    #expect(second.name == "Tab 2")
    #expect(tabs.nextTabNumber == 3)
}

@Test
func closingTheSelectedTabMovesSelectionLeft() {
    var tabs = ConversationTabMetadata.initial
    _ = tabs.appendShell(id: "first")
    _ = tabs.appendShell(id: "second")

    tabs.closeShell(tabID: "second")
    #expect(tabs.selectedTabID == "first")

    tabs.closeShell(tabID: "first")
    #expect(tabs.selectedTabID == ConversationTabMetadata.ideID)
}

@Test
func renamePreservesExactTextIncludingEmptyAndDuplicates() {
    var tabs = ConversationTabMetadata.initial
    _ = tabs.appendShell(id: "first")
    _ = tabs.appendShell(id: "second")

    tabs.rename(tabID: ConversationTabMetadata.mainID, to: "")
    tabs.rename(tabID: "first", to: "same")
    tabs.rename(tabID: "second", to: "same")

    #expect(tabs.mainName == "")
    #expect(tabs.shellTabs.map(\.name) == ["same", "same"])
}

@Test
func ideNameIsFixed() {
    var tabs = ConversationTabMetadata.initial
    let original = tabs

    tabs.rename(tabID: ConversationTabMetadata.ideID, to: "editor")

    #expect(tabs == original)
}

@Test
func permanentTabsIgnoreShellCloseRequests() {
    var tabs = ConversationTabMetadata.initial
    tabs.select(tabID: ConversationTabMetadata.ideID)

    tabs.closeShell(tabID: ConversationTabMetadata.mainID)
    tabs.closeShell(tabID: ConversationTabMetadata.ideID)

    #expect(
        tabs.orderedTabIDs == [
            ConversationTabMetadata.mainID,
            ConversationTabMetadata.ideID,
        ]
    )
    #expect(tabs.selectedTabID == ConversationTabMetadata.ideID)
}

@Test
func permanentTabsRemainFirstWhileShellTabsReorder() {
    var tabs = ConversationTabMetadata.initial
    _ = tabs.appendShell(id: "first")
    _ = tabs.appendShell(id: "second")
    _ = tabs.appendShell(id: "third")

    tabs.moveShell(tabID: "third", toFinalIndex: 0)

    #expect(
        tabs.orderedTabIDs == [
            ConversationTabMetadata.mainID,
            ConversationTabMetadata.ideID,
            "third",
            "first",
            "second",
        ]
    )
}

@Test
func normalizationDropsDuplicateOrReservedShellIDs() {
    let tabs = ConversationTabMetadata(
        mainName: "work",
        shellTabs: [
            ShellTabMetadata(id: "same", name: "first"),
            ShellTabMetadata(id: "same", name: "duplicate"),
            ShellTabMetadata(
                id: ConversationTabMetadata.mainID,
                name: "reserved"
            ),
            ShellTabMetadata(
                id: ConversationTabMetadata.ideID,
                name: "also-reserved"
            ),
        ],
        selectedTabID: "missing",
        nextTabNumber: 0
    ).normalized()

    #expect(
        tabs.shellTabs == [
            ShellTabMetadata(id: "same", name: "first"),
        ]
    )
    #expect(tabs.selectedTabID == ConversationTabMetadata.mainID)
    #expect(tabs.nextTabNumber == 1)
}

@Test
func ideSelectionSurvivesNormalization() {
    var tabs = ConversationTabMetadata.initial
    tabs.select(tabID: ConversationTabMetadata.ideID)

    #expect(
        tabs.normalized().selectedTabID
            == ConversationTabMetadata.ideID
    )
}
