import HygieiaFoundationScanner
import HygieiaFileOperations
import HygieiaScannerCore

@MainActor
struct AppDependencies {
    let scanner: any FileSystemScanner
    let folderPicker: any FolderPicking
    let volumeDiscovery: any VolumeDiscovering
    let projector: any LargestItemsProjecting
    let finder: any FinderService
    let trash: any TrashService

    static let live = AppDependencies(
        scanner: FoundationScanner(),
        folderPicker: AppKitFolderPicker(),
        volumeDiscovery: FoundationVolumeDiscovery(),
        projector: LargestItemsProjector(),
        finder: AppKitFinderService(),
        trash: AppKitTrashService()
    )

    @MainActor
    func makeScanFeatureModel() -> ScanFeatureModel {
        ScanFeatureModel(
            scanner: scanner,
            folderPicker: folderPicker,
            volumeDiscovery: volumeDiscovery,
            projector: projector,
            finder: finder,
            trash: trash
        )
    }
}
