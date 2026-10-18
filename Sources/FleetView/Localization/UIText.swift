import Foundation

/// Every piece of text the Mac app shows, by meaning rather than by wording.
///
/// One case per string; the Chinese and English wording live in two tables beside this file
/// (`UIText+zh.swift`, `UIText+en.swift`), each an exhaustive `switch`, so a case added here and
/// missing from either table is a compile error rather than a blank label at run time.
/// Interpolated values (a count, a name) are associated values: word order and plurals differ
/// between the two languages and belong to the table, not to the call site.
///
/// What is *not* in here, on purpose: `TermStatus.apiLabel` (the `/state` field scripts and
/// `project-manager` parse, which must not change with the Mac's language), log and audit
/// messages, and the snapshot mode's sample data. The web page has its own table in its script.
enum UIText {
    case statusClosed
    case statusShell
    case statusIdle
    case statusWorking
    case statusNeedsYou
    case statusExited
    case justNow
    case cancel
    case clear
    case copy
    case copied
    case closeEsc
    case collapse
    case save
    case edit
    case delete
    case unknownProject
    case nTerminals(Int)
    case menuAbout
    case menuCheckUpdates
    case menuHide
    case menuCloseAll
    case menuClearBoard
    case menuUninstallHooks
    case menuRevealSupport
    case menuQuit
    case menuEdit
    case menuCut
    case menuCopy
    case menuPaste
    case menuSelectAll
    case menuSearch
    case menuView
    case menuFontBigger
    case menuFontSmaller
    case menuFontActual
    case hooksRemovedTitle
    case hooksRemovedBody
    case winHide
    case winHideA11y
    case winHideHelp
    case dockUnmark
    case dockMark
    case dockDuplicate
    case dockRename
    case dockTree
    case dockLeaveCluster
    case dockRemove
    case notesHint
    case notesPeerEmpty(String)
    case notesNoMatch(String)
    case notesFilter
    case notesTitle
    case notesFrom(String)
    case notesAdd
    case notesAddOn(String)
    case notesEmpty
    case notesEditOn(String)
    case notesDeleteOn(String)
    case notesPeerHelp(String)
    case notesPeerField(String)
    case notesSaveOn(String)
    case notesField
    case webTitle
    case copyLink
    case openOnThisMac
    case webReachAll(String)
    case webReachOne(String)
    case webOffline
    case webSubtitleTerminal(String)
    case webSubtitleBoard
    case webReachTailscale
    case webLabelLAN
    case webReachLAN
    case closeAllTitle
    case closeAllRunning(Int)
    case closeAllNone
    case closeAllKeepsCards
    case closeAllInterrupts(Int)
    case closeOnQuit
    case closeOnQuitOn
    case closeOnQuitOff
    case clearBoardEllipsis
    case clearBoardHelp
    case closeAllButton
    case panelTitle
    case panelTitlePinned(String)
    case panelExpand
    case panelCollapse
    case panelLive
    case panelHistory
    case cardMarked
    case cardHidden
    case cardRunningFor(String)
    case cardLastActivity
    case cardLastRun(String)
    case tokensHelp(Int)
    case cardOpenOnPhone
    case more
    case cardRaise
    case cardReopen
    case cardCopyPath
    case cardRename
    case cardCloseTree
    case cardOpenTree
    case cardDuplicateFork
    case cardDuplicateBlank
    case cardUnmark
    case cardMark
    case cardShowWindow
    case cardHideWindow
    case cardLeaveCluster
    case cardRemove
    case idCopied
    case idPathCopied
    case idNoLog
    case idHelp(String)
    case treeCopyId
    case treeTitle
    case treeBranchPoints
    case treeTurns
    case treeSearch
    case treeWithReplies
    case treeWithRepliesHelp
    case treeNewestFirst
    case treeOldestFirst
    case treeLoading
    case treeNTurns(Int)
    case treeExpandFold(Int)
    case treeExpandCompaction(Int)
    case treeExpandCompactionHelp(Int)
    case treeCompactionGone
    case treeCompactionGoneHelp
    case treeVersions(Int)
    case treeVersionsHelp(Int)
    case treeHitReply
    case treeCompactedHelp
    case treeBranchesHelp(Int)
    case treeStoppedHere(String)
    case treeNativeLeaf
    case treeOpenHere
    case treeOpenHereHelp
    case treeNoAgent
    case treeNoCodexCwd
    case treeEmpty
    case treeCodexOpenFailed
    case chartUpdated(String)
    case cloneTitle
    case cloneRepo
    case cloneRepoPlaceholder
    case cloneInto
    case cloneBackground
    case cloneButton
    case choose
    case nameField
    case sheetNewTerminal
    case sheetOpen
    case sheetRenameTerminal
    case sheetRename
    case sheetRenameCluster
    case jobCloneTitle(String)
    case jobPreparing
    case jobRetry
    case jobFailedNoInfo
    case jobCloning
    case jobUpdating
    case jobNTasks(Int)
    case jobVerbFailed(String)
    case jobDone
    case peerThisMac
    case peerHelpWorking(String, Int, Int)
    case peerHelp(String, Int)
    case peerScanning(Int)
    case peerNone
    case peerNarrowed
    case peerOpenBrowser
    case peerRescan
    case searchFleetPlaceholder
    case searchConvPlaceholder
    case searchMine
    case searchReplies
    case searchAll
    case searchTruncated(Int)
    case searchNoArchived
    case searchNothing
    case searchStats(Int, Int)
    case searchYourPrompt
    case searchAgentReply
    case searchNMessages(Int)
    case searchOpening
    case searchOpenNew
    case searchJumpTerminal
    case searchSwitchProject
    case searchSelect
    case searchDragHint
    case modeFleet
    case modeSession
    case modeHistory
    case modeArchive
    case indexBuilding
    case indexUpdating
    case indexProgress(Int, Int, Int)
    case searchNoSession
    case treeflowMissing
    case updNotABundle(String)
    case updNotWritable(String)
    case updNoAsset
    case updStatus(String)
    case updJobTitle(String)
    case updConnecting
    case updVerifying
    case updNotZip
    case updNoApp
    case updVersionMismatch(String, String)
    case updUnknown
    case updBadSignature
    case updInstalling
    case updInstallingRestart
    case updScriptPrepare(String)
    case updScriptLaunch(String)
    case updSeeLog
    case updOpenReleasePage
    case updFailedTitle
    case updSeeLogBody
    case ok
    case updDownloaded(String)
    case updHTTP(Int)
    case updSaveFailed(String)
    case updNoFile
    case updAvailableTitle(String)
    case updCurrentVersion(String)
    case updCannotInstall(String)
    case updViewRelease
    case updLater
    case updInstall
    case updRestartNote
    case updUpToDate
    case updVersionLine(String)
    case updCheckFailed
    case updChecksOff
    case updNoRelease
    case dropJoinCluster(String)
    case dropGroupWith(String)
    case dropLeaveCluster(String)
    case dropMoveTo(String)
    case groupFallback
    case projectFallback
    case dropNoteWorking
    case dropNoteCodex
    case dropNoteNoHistory
    case dropNoteMove
    case pickOpenProject
    case pickOpenMessage
    case pickFolderName
    case pickCreate
    case pickCreateMessage
    case alertCloseN(Int)
    case alertCloseAll
    case alertCloseBody
    case alertCloseButton
    case alertClearTitle
    case alertClearBody(Int, Int)
    case alertClearButton
    case sidebarTerminals
    case sidebarNoMarked
    case sidebarNoTerminals
    case sidebarOpenFolder
    case sidebarNewFolder
    case sidebarClone
    case sidebarDormantHelp
    case statusCount(Int, String)
    case topSearch
    case topSearchHelp
    case topHideRecent
    case topShowRecent
    case topJobsHelp
    case topJobsTitle
    case topJobsBody
    case topUpdateHelp(String)
    case topSkipVersion
    case topShowAll
    case topShowMarked
    case topPowerHelp
    case topPeersHelp
    case topWebHelp
    case emptyTitle
    case emptySubtitle
    case emptyButton
    case emptyMarkedTitle
    case emptyMarkedSubtitle
    case zoneLive
    case zoneRecent
    case zoneDormant
    case tagOpenInFinder(String)
    case skillNoDescription
    case copyAbsolutePath
    case projDragHelp
    case projExpand
    case projCollapse
    case projNameHelp(String)
    case projRateHelp
    case projLastActivity
    case projHideSkills
    case projSkills(Int)
    case projArchived(Int)
    case projHideChart
    case projShowChart
    case projNewTerminal
    case projRemove
    case clusterRenameHint
    case clusterShown(Int, Int)
    case clusterRename
    case clusterAdd
    case dropTreeNew
    case dropTreeJoin
    case errNotClaudeProject(String)
    case errNoCwd(String)
    case errNodeNotFound
    case errForkWrite(String)
    case peerReading(String)
    case peerNoTerminals(String)
    case cardJustFinished
}

/// The language the UI is drawn in: Chinese when the first preferred language is any Chinese,
/// English otherwise. Read once — macOS relaunches apps for a language change anyway.
enum Lang {
    case zh, en
    static let current: Lang = (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? .zh : .en
}

/// The wording of `t` in the current language.
func L(_ t: UIText) -> String {
    switch Lang.current {
    case .zh: return t.zh
    case .en: return t.en
    }
}
