import Foundation
enum Resources {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        if let url = Bundle.main.resourceURL?.appendingPathComponent("FoFoBooster_FoFoBooster.bundle"), let bundle = Bundle(url: url) { return bundle }
        return .module
        #else
        return .main
        #endif
    }
}
