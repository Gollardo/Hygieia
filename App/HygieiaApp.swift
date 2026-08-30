import SwiftUI

@main
@MainActor
struct HygieiaApp: App {
    private let dependencies = AppDependencies.live

    var body: some Scene {
        Window("Hygieia", id: "main") {
            ScanSceneRoot(dependencies: dependencies)
        }
        .defaultSize(width: 1_440, height: 1_024)
        .commands {
            HygieiaCommands()
        }
    }
}

@MainActor
private struct ScanSceneRoot: View {
    @State private var model: ScanFeatureModel

    init(dependencies: AppDependencies) {
        _model = State(initialValue: dependencies.makeScanFeatureModel())
    }

    var body: some View {
        ScanRootView(model: model)
            .onDisappear {
                model.teardown()
            }
    }
}
