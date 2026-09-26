import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WayforkCore

/// The first-run guide window content (F22, docs/design/02-ux.md "First-run guide"): a rail
/// of six steps, each the real action — nothing here is a second copy of an existing
/// screen's logic. Hosted by `GuideWindowController` in a plain `NSWindow`.
struct GuideView: View {
    @Environment(AppModel.self) private var model

    /// Step 4's two ways to read the sites list.
    enum SiteMode: Hashable {
        case onlyThese
        case exceptThese
    }

    let startStep: GuideStep

    @State private var step: GuideStep

    // Step 3 — Add a VPN
    @State private var addedTunnelID: UUID?
    @State private var baselineTunnelCount: Int?
    @State private var linkFieldText = ""
    @State private var showAddLinkSheet = false
    @State private var nameInput = ""
    @State private var nameError: String?
    @State private var usernameInput = ""
    @State private var passwordInput = ""

    // Step 2 — helper
    @State private var waitingForHelper = false

    // Step 4 — sites
    @State private var siteInput = ""
    @State private var siteTokens: [String] = []
    @State private var siteMode: SiteMode = .onlyThese
    @State private var siteError: String?
    /// Rules and default tunnel as they were before step 4 first wrote anything, so a
    /// second Continue (after Back) replaces the first one's work instead of adding to it.
    @State private var rulesBeforeSites: [Rule]?
    @State private var defaultBeforeSites: UUID?

    // Step 6 — try it
    @State private var tryItCheck: GuideTryItCheck?
    /// The site the user last opened from step 6, named in the proof line.
    @State private var openedSite: String?
    @State private var tunnelProofLine: String?
    @State private var directProofLine: String?
    @State private var tryItSummaryShown = false

    init(startStep: GuideStep) {
        self.startStep = startStep
        _step = State(initialValue: startStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                rail.frame(width: 150)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    stepContent
                    Spacer(minLength: 0)
                    footer
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 600, height: 410)
        .onAppear {
            model.guideStepChanged(step)
            if step == .addVPN, addedTunnelID == nil {
                baselineTunnelCount = model.store.tunnels.count
            }
        }
        .onChange(of: step) { _, newStep in
            if newStep == .addVPN, addedTunnelID == nil, baselineTunnelCount == nil {
                baselineTunnelCount = model.store.tunnels.count
            }
        }
        .onChange(of: model.store.tunnels.count) { _, newCount in
            // The first tunnel of the batch: for a single import it's also the last one; for
            // a subscription with several servers, step 4 names the first one kept
            // (docs/design/02-ux.md, "First-run guide").
            guard step == .addVPN, addedTunnelID == nil, let baselineTunnelCount,
                newCount > baselineTunnelCount,
                model.store.tunnels.indices.contains(baselineTunnelCount)
            else { return }
            let first = model.store.tunnels[baselineTunnelCount]
            addedTunnelID = first.id
            nameInput = first.name
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(GuideStrings.order.enumerated()), id: \.element) { index, item in
                let currentIndex = GuideStrings.order.firstIndex(of: step) ?? 0
                let done = index < currentIndex
                let isCurrent = item == step
                Button {
                    guard done else { return }
                    step = item
                    model.guideStepChanged(item)
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(
                                    isCurrent
                                        ? Color.accentColor
                                        : (done
                                            ? Color.accentColor.opacity(0.85)
                                            : Color.secondary.opacity(0.18))
                                )
                                .frame(width: 18, height: 18)
                            if done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(isCurrent ? .white : .secondary)
                            }
                        }
                        Text(GuideStrings.railTitle(item))
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!done)
                .padding(.vertical, 6)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 14, bottom: 18, trailing: 6))
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .helper: helperStep
        case .addVPN: addVPNStep
        case .sites: sitesStep
        case .turnOn: turnOnStep
        case .tryIt: tryItStep
        }
    }

    // MARK: - Step 1 · Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send only the sites you choose through a VPN")
                .font(.system(size: 17, weight: .semibold))
            Text(
                "Everything else keeps using your normal connection. You can use several VPNs at once — each site goes through the one you pick."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                diagramBox(title: "This Mac", subtitle: nil)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                VStack(spacing: 8) {
                    diagramBox(title: "Your VPN", subtitle: "sites you choose", accent: true)
                    diagramBox(title: "Direct", subtitle: "everything else")
                }
            }
            Text(
                "Takes about two minutes. You need the VPN config file or link your provider or admin gave you."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func diagramBox(title: String, subtitle: String?, accent: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(accent ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Step 2 · Helper

    private var helperStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow the Wayfork helper").font(.system(size: 17, weight: .semibold))
            Text(
                "To steer traffic, Wayfork runs a small helper with system rights. macOS asks you to allow it once."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            if waitingForHelper {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to turn on Wayfork in System Settings…")
                        .font(.system(size: 12))
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Click Open System Settings.").font(.system(size: 12))
                    Text("2. Under Allow in the Background, turn on Wayfork:")
                        .font(.system(size: 12))
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "app.badge")
                Text("Wayfork").font(.system(size: 12, weight: .medium))
                Text("Login Items › Allow in the Background")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            if !waitingForHelper {
                Text("3. Come back — this window moves on by itself.").font(.system(size: 12))
            }
            Text(
                "Wayfork never asks for your password. macOS may, if this account is not an administrator."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task(id: step) {
            guard step == .helper else { return }
            model.refreshHelperState()
            if model.helperState == .enabled {
                advance(to: .addVPN)
            }
        }
    }

    private func startHelperApproval() {
        waitingForHelper = true
        Task {
            let approved = await model.approveHelperForGuide()
            waitingForHelper = false
            if approved { advance(to: .addVPN) }
        }
    }

    // MARK: - Step 3 · Add a VPN

    private var addVPNStep: some View {
        Group {
            if let addedTunnelID, let tunnel = model.store.tunnel(id: addedTunnelID) {
                addVPNNameStep(tunnel: tunnel)
            } else {
                addVPNSourceStep
            }
        }
    }

    private var addVPNSourceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a VPN you already have").font(.system(size: 17, weight: .semibold))
            VStack(spacing: 6) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text("Drop an OpenVPN file (.ovpn) here").font(.system(size: 12))
                Button("Choose File…") { Task { await model.importOpenVPNFromPicker() } }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.tertiary)
            )
            .dropDestination(for: URL.self) { urls, _ in
                let profiles = urls.filter {
                    ["ovpn", "conf"].contains($0.pathExtension.lowercased())
                }
                guard !profiles.isEmpty else { return false }
                Task {
                    for url in profiles {
                        if url.pathExtension.lowercased() == "conf" {
                            await model.importWireGuard(from: url)
                        } else {
                            await model.importOpenVPN(from: url)
                        }
                    }
                }
                return true
            }
            Text("or paste a link").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(
                    "vless://, trojan://, ss://, wireguard://… or a subscription https://",
                    text: $linkFieldText
                )
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { showAddLinkSheet = true }
                Button("Add") { showAddLinkSheet = true }
                    .controlSize(.small)
                    .disabled(linkFieldText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                Text(
                    "Where do I get this? From your VPN provider's site or app — often under \"Manual setup\" or \"Other devices\" — or from whoever runs your server."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddLinkSheet) {
            AddLinkSheet(mode: .add, initialText: linkFieldText)
        }
    }

    private func addVPNNameStep(tunnel: Tunnel) -> some View {
        let needsCredentials = tunnel.kind.openVPN?.needsCredentials == true
        return VStack(alignment: .leading, spacing: 12) {
            Text("Got it").font(.system(size: 17, weight: .semibold))
            HStack(spacing: 6) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(tunnel.name).font(.system(size: 12, weight: .medium))
                Text(StatusText.typeBadge(tunnel.kind)).font(.system(size: 11)).foregroundStyle(
                    .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Name", text: $nameInput).textFieldStyle(.roundedBorder).frame(width: 220)
                Text("What you will see in the menu bar. Short is best.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let nameError {
                    Text(nameError).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            if needsCredentials {
                Text("This config asks for a login").font(.system(size: 12, weight: .semibold))
                TextField("Username", text: $usernameInput).textFieldStyle(.roundedBorder).frame(
                    width: 220)
                SecureField("Password", text: $passwordInput).textFieldStyle(.roundedBorder).frame(
                    width: 220)
                Text("Stored in your Keychain, not in a file.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if needsCredentials, let credentials = model.credentials(for: tunnel.id) {
                usernameInput = credentials.username
                passwordInput = credentials.password
            }
        }
    }

    private var canContinueAddVPN: Bool {
        guard let addedTunnelID, let tunnel = model.store.tunnel(id: addedTunnelID) else {
            return false
        }
        guard !nameInput.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if tunnel.kind.openVPN?.needsCredentials == true {
            return !usernameInput.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    private func commitAddVPN() {
        guard let addedTunnelID else { return }
        if let error = model.rename(tunnelID: addedTunnelID, to: nameInput) {
            nameError = error
            return
        }
        if model.store.tunnel(id: addedTunnelID)?.kind.openVPN?.needsCredentials == true {
            model.setCredentials(
                tunnelID: addedTunnelID, username: usernameInput, password: passwordInput)
        }
        advance(to: .sites)
    }

    // MARK: - Step 4 · Sites

    private var sitesStep: some View {
        let tunnelName = addedTunnelID.flatMap { model.store.tunnel(id: $0)?.name } ?? "the tunnel"
        return VStack(alignment: .leading, spacing: 12) {
            Text(
                siteMode == .onlyThese
                    ? "Which sites go through \(tunnelName)?" : "Which sites stay direct?"
            )
            .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                FlowLayoutChips(
                    tokens: siteTokens, remove: { token in siteTokens.removeAll { $0 == token } })
                TextField("Type a site and press Return", text: $siteInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSiteToken)
                    .onChange(of: siteInput) {
                        if siteInput.hasSuffix(",") {
                            siteInput.removeLast()
                            addSiteToken()
                        }
                    }
            }
            if let siteError {
                Text(siteError).font(.system(size: 11)).foregroundStyle(.red)
            }
            Text(
                "Type it as the browser shows it. example.org also covers www.example.org and every other subdomain."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                modeOption(
                    .onlyThese, title: "Only these sites",
                    detail: "Everything else goes direct, as it does now.")
                modeOption(
                    .exceptThese, title: "Everything through \(tunnelName), except these sites",
                    detail: "For when the VPN should be the rule and direct the exception.")
            }
            Text("Change it any time — menu bar › Wayfork, or Settings › Rules.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func modeOption(_ mode: SiteMode, title: String, detail: String) -> some View {
        Button {
            siteMode = mode
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: siteMode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(siteMode == mode ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Validates the typed site the way quick add will, and keeps its normalized form, so
    /// Continue never writes fewer rules than the chips show.
    private func addSiteToken() {
        let token = siteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let addedTunnelID else { return }
        switch QuickAdd.evaluate(input: token, target: .tunnel(addedTunnelID), store: model.store) {
        case .invalid(let message):
            siteError = message
            return
        case .add(let rule), .update(let rule):
            siteError = nil
            siteInput = ""
            if !siteTokens.contains(rule.pattern) { siteTokens.append(rule.pattern) }
        }
    }

    private func commitSites() {
        guard let addedTunnelID, !siteTokens.isEmpty else { return }
        if let before = rulesBeforeSites {
            undoSites(before)
        } else {
            rulesBeforeSites = model.store.rules
            defaultBeforeSites = model.store.defaultTunnelID
        }
        switch siteMode {
        case .onlyThese:
            for token in siteTokens {
                _ = model.quickAdd(input: token, target: .tunnel(addedTunnelID))
            }
        case .exceptThese:
            model.setDefaultTunnel(addedTunnelID)
            for token in siteTokens { _ = model.quickAdd(input: token, target: .direct) }
        }
        advance(to: .turnOn)
    }

    /// Puts rules and the default tunnel back to how step 4 found them: rules it added go,
    /// rules it re-pointed get their old target back.
    private func undoSites(_ before: [Rule]) {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        model.update { store in
            store.rules.removeAll { old[$0.id] == nil }
            for index in store.rules.indices {
                if let rule = old[store.rules[index].id] { store.rules[index] = rule }
            }
        }
        model.setDefaultTunnel(defaultBeforeSites)
    }

    // MARK: - Step 5 · Turn on

    private var turnOnTunnel: Tunnel? { addedTunnelID.flatMap { model.store.tunnel(id: $0) } }
    private var turnOnPresentation: TunnelPresentation? { turnOnTunnel.map { model.card(for: $0) } }

    private var turnOnStep: some View {
        let tunnel = turnOnTunnel
        let presentation = turnOnPresentation
        return VStack(alignment: .leading, spacing: 12) {
            Text("Turn it on").font(.system(size: 17, weight: .semibold))
            HStack(spacing: 12) {
                Toggle(
                    "", isOn: Binding(get: { model.desiredOn }, set: { _ in model.toggle() })
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.transition != nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.desiredOn ? "Wayfork is on" : "Off").font(
                        .system(size: 13, weight: .semibold))
                    Text(turnOnHint(tunnelName: tunnel?.name ?? ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let tunnel { TunnelCardView(tunnel: tunnel) }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "menubar.rectangle").foregroundStyle(.secondary)
                Text(
                    "The same switch and this card live in the menu bar — the Wayfork icon at the top right of the screen."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if presentation?.isError == true {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(
                        "Another VPN app still on? Two VPNs fight over the same traffic. Turn the other one off, then Retry. Wrong password — Fix login…."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func turnOnHint(tunnelName: String) -> String {
        let sites = StatusText.count(siteTokens.count, "site")
        switch siteMode {
        case .onlyThese: return "\(sites) via \(tunnelName), everything else direct"
        case .exceptThese: return "everything via \(tunnelName), except \(sites)"
        }
    }

    // MARK: - Step 6 · Try it

    private var tryItStep: some View {
        Group {
            if tryItSummaryShown {
                tryItSummaryContent
            } else {
                tryItWaitingContent
            }
        }
        .task(id: step) {
            guard step == .tryIt else { return }
            await pollTryIt()
        }
    }

    /// Up to two sites that can be opened as a page: wildcard and address rules can't.
    private var tryItSites: [String] {
        Array(siteTokens.filter { !$0.contains("*") && !$0.contains("/") }.prefix(2))
    }

    private var tryItWaitingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try it").font(.system(size: 17, weight: .semibold))
            Text("Open one of your sites. Wayfork shows here which way it went.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(tryItSites, id: \.self) { site in
                    Button("Open \(site) ↗") { openSite(site) }.controlSize(.regular)
                }
            }
            if let tunnelProofLine {
                proofLine(text: tunnelProofLine, ok: true)
            }
            if let directProofLine {
                proofLine(text: directProofLine, ok: false)
            }
            if tunnelProofLine == nil && directProofLine == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for a connection to one of your sites…").font(.system(size: 12))
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                Text(
                    "Nothing shows up? Reload the page. A browser tab that was open before Wayfork turned on may keep its old connection for a while."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var tryItSummaryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're set").font(.system(size: 17, weight: .semibold))
            if let tunnelProofLine { proofLine(text: tunnelProofLine, ok: true) }
            if let directProofLine { proofLine(text: directProofLine, ok: false) }
            Divider()
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "menubar.rectangle").foregroundStyle(.secondary)
                Text(
                    "Wayfork lives here, in the menu bar. Click the icon to turn it on or off, check your tunnels, and send another site through a VPN."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func proofLine(text: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "arrow.right.circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(text).font(.system(size: 12))
        }
    }

    private func openSite(_ site: String) {
        if tryItCheck == nil, let addedTunnelID {
            let baseline =
                model.traffic
                ?? TrafficSnapshot(sampledAt: Date(), interval: 0, tunnels: [:], direct: .init())
            tryItCheck = GuideTryItCheck(
                tunnelID: addedTunnelID,
                mode: siteMode == .exceptThese ? .everythingExceptThese : .onlyTheseSites,
                baseline: baseline, openedAt: Date())
        }
        openedSite = site
        if let url = URL(string: "https://\(site)") { NSWorkspace.shared.open(url) }
    }

    private func pollTryIt() async {
        while step == .tryIt, !tryItSummaryShown {
            if let tryItCheck, let latest = model.traffic, let addedTunnelID,
                let tunnel = model.store.tunnel(id: addedTunnelID)
            {
                let result = tryItCheck.evaluate(latest: latest)
                if result.sitesProven, tunnelProofLine == nil {
                    let site = openedSite ?? tryItSites.first ?? tunnel.name
                    tunnelProofLine =
                        siteMode == .exceptThese
                        ? "Opened \(site) — it went direct, as you asked"
                        : "Opened \(site) — it went through \(tunnel.name)"
                }
                if let otherHost = result.otherHost, directProofLine == nil {
                    directProofLine =
                        siteMode == .exceptThese
                        ? "\(otherHost) went through \(tunnel.name) — everything else does"
                        : "\(otherHost) went direct — not on your list"
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            skipLabel
            Spacer()
            if step != .welcome { Button("Back") { goBack() } }
            primaryButton
        }
    }

    @ViewBuilder
    private var skipLabel: some View {
        switch step {
        case .welcome:
            Button("Skip — I'll set it up myself") { model.skipGuide() }
                .buttonStyle(.link).font(.system(size: 12))
        case .helper, .addVPN, .sites:
            Button("Skip guide") { model.skipGuide() }.buttonStyle(.link).font(.system(size: 12))
        case .turnOn:
            if turnOnPresentation?.isError == true {
                Button("Finish setup later") { model.guideWindowController?.close() }
                    .buttonStyle(.link).font(.system(size: 12))
            } else {
                Button("Skip guide") { model.skipGuide() }.buttonStyle(.link).font(
                    .system(size: 12))
            }
        case .tryIt:
            if !tryItSummaryShown {
                Button("Skip this step") { model.finishGuide() }.buttonStyle(.link).font(
                    .system(size: 12))
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Get started") { advance(to: .helper) }.buttonStyle(.borderedProminent)
        case .helper:
            if waitingForHelper {
                Button("Open System Settings again") { HelperInstaller.openLoginItems() }
                    .buttonStyle(.bordered)
            } else {
                Button("Open System Settings") { startHelperApproval() }
                    .buttonStyle(.borderedProminent)
            }
        case .addVPN:
            Button("Continue") { commitAddVPN() }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinueAddVPN)
        case .sites:
            Button("Continue") { commitSites() }
                .buttonStyle(.borderedProminent)
                .disabled(siteTokens.isEmpty)
        case .turnOn:
            if turnOnPresentation?.isError == true {
                Button("Continue anyway") { advance(to: .tryIt) }.buttonStyle(.bordered)
            } else {
                Button("Continue") { advance(to: .tryIt) }
                    .buttonStyle(.borderedProminent)
                    .disabled(turnOnPresentation?.glyph != .up)
            }
        case .tryIt:
            if tryItSummaryShown {
                Button("Done") { model.finishGuide() }.buttonStyle(.borderedProminent)
            } else {
                Button("Finish") { tryItSummaryShown = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(tunnelProofLine == nil)
            }
        }
    }

    // MARK: - Navigation

    private func advance(to next: GuideStep) {
        if next == .helper {
            model.refreshHelperState()
            if model.helperState == .enabled {
                advance(to: .addVPN)
                return
            }
        }
        step = next
        model.guideStepChanged(next)
    }

    private func goBack() {
        guard let index = GuideStrings.order.firstIndex(of: step), index > 0 else { return }
        var target = GuideStrings.order[index - 1]
        if target == .helper {
            model.refreshHelperState()
            if model.helperState == .enabled, index - 1 > 0 {
                target = GuideStrings.order[index - 2]
            }
        }
        step = target
        model.guideStepChanged(target)
    }
}

/// Chosen sites as removable chips, each noting "and subdomains" (docs/design/02-ux.md,
/// "First-run guide" step 4).
private struct FlowLayoutChips: View {
    let tokens: [String]
    let remove: (String) -> Void

    var body: some View {
        if !tokens.isEmpty {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 140, maximum: 280), spacing: 6, alignment: .leading)
                ],
                alignment: .leading, spacing: 6
            ) {
                ForEach(tokens, id: \.self) { token in
                    HStack(spacing: 4) {
                        Text(token).font(.system(size: 11)).lineLimit(1)
                        Text("and subdomains").font(.system(size: 9)).foregroundStyle(.secondary)
                        Button {
                            remove(token)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
            }
        }
    }
}
