import SwiftUI

struct ScanCommandActions {
    let chooseFolder: () -> Void
    let rescan: () -> Void
    let cancel: () -> Void
    let goBack: () -> Void
    let goForward: () -> Void
    let goUp: () -> Void
    let drillSelected: () -> Void
    let revealSelectedInFinder: () -> Void
    let moveSelectedToTrash: () -> Void
    let canChooseFolder: Bool
    let canRescan: Bool
    let canCancel: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let canGoUp: Bool
    let canDrillSelected: Bool
    let canRevealSelectedInFinder: Bool
    let canMoveSelectedToTrash: Bool
}

private struct ScanCommandActionsKey: FocusedValueKey {
    typealias Value = ScanCommandActions
}

extension FocusedValues {
    var scanCommandActions: ScanCommandActions? {
        get { self[ScanCommandActionsKey.self] }
        set { self[ScanCommandActionsKey.self] = newValue }
    }
}

struct HygieiaCommands: Commands {
    @FocusedValue(\.scanCommandActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Choose Folder…") {
                actions?.chooseFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!(actions?.canChooseFolder ?? false))

            Button("Rescan") {
                actions?.rescan()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(actions?.canRescan ?? false))

            Button("Cancel Scan") {
                actions?.cancel()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!(actions?.canCancel ?? false))

            Divider()

            Button("Back") {
                actions?.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!(actions?.canGoBack ?? false))

            Button("Forward") {
                actions?.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!(actions?.canGoForward ?? false))

            Button("Up") {
                actions?.goUp()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!(actions?.canGoUp ?? false))

            Button("Open Selected Folder in Chart") {
                actions?.drillSelected()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!(actions?.canDrillSelected ?? false))

            Divider()

            Button("Show Selected Item in Finder") {
                actions?.revealSelectedInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!(actions?.canRevealSelectedInFinder ?? false))

            Button("Move Selected Item to Trash") {
                actions?.moveSelectedToTrash()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(actions?.canMoveSelectedToTrash ?? false))
        }
    }
}
