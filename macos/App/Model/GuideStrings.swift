import WayforkCore

/// Rail labels for the first-run guide (F22), shared by `GuideView`'s rail and the
/// No-tunnels popover's resume line (docs/design/02-ux.md "First-run guide" › "Steps").
enum GuideStrings {
    static let order: [GuideStep] = [.welcome, .helper, .addVPN, .sites, .turnOn, .tryIt]

    static func railTitle(_ step: GuideStep) -> String {
        switch step {
        case .welcome: "Welcome"
        case .helper: "Allow the helper"
        case .addVPN: "Add a VPN"
        case .sites: "Choose sites"
        case .turnOn: "Turn on"
        case .tryIt: "Try it"
        }
    }
}
