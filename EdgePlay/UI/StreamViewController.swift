// SPDX-License-Identifier: AGPL-3.0-only

import UIKit
import AVFoundation

/// The full-screen player. Plain UIKit so it fully controls the status bar,
/// home indicator, edge gestures and orientation.
final class StreamViewController: UIViewController {
    private let session: StreamSession
    private var settings: StreamSettings
    private let saveSettings: (StreamSettings) -> Void

    private let input = ControllerInput()
    private let videoContainer = UIView()
    private let statsLabel = PaddedLabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let menuButton = UIButton(type: .system)
    private let hintLabel = PaddedLabel()
    private let netBadge = PaddedLabel()
    private var poorSeconds = 0
    private lazy var panel = StreamMenuPanel()
    private var statsTimer: Timer?
    private var hideMenuButtonWork: DispatchWorkItem?
    private var connected = false
    private var ending = false
    private var pinchStartBalance: Double = 0
    private var pinchStartCustom = CustomFrame()

    init(session: StreamSession, settings: StreamSettings, saveSettings: @escaping (StreamSettings) -> Void) {
        self.session = session
        self.settings = settings
        self.saveSettings = saveSettings
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: system chrome

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    /// First swipe from an edge is delivered to us; iOS only acts on a second swipe.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoContainer.clipsToBounds = true
        videoContainer.backgroundColor = .black
        videoContainer.frame = view.bounds
        videoContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoContainer)
        videoContainer.layer.addSublayer(session.video.outputLayer)

        setupOverlays()
        setupGestures()
        wireSession()
        wireInput()

        do {
            try session.start()
        } catch {
            end(message: error.localizedDescription)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        flashMenuButton()
        session.video.renderer?.start(highRefresh: settings.highRefresh)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStats() }
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        statsTimer?.invalidate()
        session.video.renderer?.stop()
        input.stop()
        session.close()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutVideo()
    }

    private func layoutVideo() {
        let dims = session.dimensions
        let aspect: CGFloat = dims.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 16.0 / 9.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = settings.screenMode == .custom
            ? ScreenGeometry.customFrame(in: videoContainer.bounds, videoAspect: aspect, custom: settings.custom)
            : ScreenGeometry.videoFrame(in: videoContainer.bounds, videoAspect: aspect,
                                        mode: settings.screenMode, balance: settings.fillBalance)
        session.video.outputLayer.frame = frame
        CATransaction.commit()
        if let r = session.video.renderer {
            // Render at the panel's real pixel size so MetalFX/sharpening work on true pixels.
            let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
            r.layer.contentsScale = scale
            r.setDrawableSize(CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded()))
        }
    }

    @objc private func appBecameActive() {
        // The display layer fails while backgrounded; get a fresh keyframe.
        session.video.reset()
        session.requestKeyframe()
    }

    // MARK: session & input

    private func wireSession() {
        session.onDimensions = { [weak self] _ in self?.layoutVideo() }
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected:
                connected = true
                if settings.microphone { setMic(true) }
                spinner.stopAnimating()
                statusLabel.isHidden = true
                updateHint()
            case .pinRequested(let wrong):
                askForPin(wrong: wrong)
            case .nickname:
                break
            case .rumble(let l, let r):
                if settings.rumble { input.rumble(left: l, right: r) }
            case .triggers(let l, let r):
                if settings.adaptiveTriggers {
                    input.setTriggers(left: l, right: r, scale: Float(settings.triggerStrength))
                }
            case .lightbar(let r, let g, let b):
                if settings.lightbar { input.setLightbar(red: r, green: g, blue: b) }
            case .ended(let reason, let isError):
                end(message: isError ? reason : nil)
            }
        }
    }

    private var micOn = false

    private func setMic(_ on: Bool) {
        session.setMicrophone(on) { [weak self] ok in
            guard let self else { return }
            micOn = on && ok
            panel.setMicState(micOn)
            if on && !ok {
                let a = UIAlertController(title: "Microphone unavailable",
                                          message: "Allow microphone access for EdgePlay in iPhone Settings, then try again.",
                                          preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                present(a, animated: true)
            }
        }
    }

    private func wireInput() {
        input.motionEnabled = settings.motion
        input.invertHorizontal = settings.invertGyroHorizontal
        input.invertVertical = settings.invertGyroVertical
        input.phoneVibration = settings.phoneVibration
        input.onPad = { [weak self] pad in self?.session.sendPad(&pad) }
        input.onControllersChanged = { [weak self] _ in self?.updateHint() }
        input.onMenuRequested = { [weak self] in self?.toggleMenu() }
        input.start()
    }

    private func end(message: String?) {
        guard !ending else { return }
        ending = true
        if let message {
            let alert = UIAlertController(title: "Stream ended", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.dismiss(animated: true) })
            if let shown = presentedViewController {
                shown.dismiss(animated: false) { [weak self] in self?.present(alert, animated: true) }
            } else {
                present(alert, animated: true)
            }
        } else {
            dismiss(animated: true)
        }
    }

    private func askForPin(wrong: Bool) {
        let alert = UIAlertController(title: "Console PIN",
                                      message: wrong ? "That PIN was wrong. Try again." : "Enter the Remote Play login PIN set on your console.",
                                      preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad; $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.end(message: nil) })
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            self?.session.submitPin(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    // MARK: overlays

    private func setupOverlays() {
        let guide = view.safeAreaLayoutGuide

        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statsLabel.textColor = .white
        statsLabel.numberOfLines = 0
        statsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        statsLabel.layer.cornerRadius = 6
        statsLabel.clipsToBounds = true
        statsLabel.isHidden = !settings.showStats
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)

        statusLabel.text = "Connecting to \(session.console.name)…"
        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        hintLabel.text = "No controller connected. Pair a DualSense in Settings › Bluetooth."
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .white
        hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hintLabel.layer.cornerRadius = 8
        hintLabel.clipsToBounds = true
        hintLabel.isHidden = true
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        netBadge.text = "Weak connection · lower the bitrate or move closer to Wi-Fi"
        netBadge.font = .preferredFont(forTextStyle: .caption1)
        netBadge.textColor = .white
        netBadge.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.85)
        netBadge.layer.cornerRadius = 8
        netBadge.clipsToBounds = true
        netBadge.isHidden = true
        netBadge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(netBadge)

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "ellipsis")
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.5)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        menuButton.configuration = config
        menuButton.addTarget(self, action: #selector(toggleMenu), for: .touchUpInside)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)

        NSLayoutConstraint.activate([
            statsLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            statsLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -16),
            netBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            netBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            menuButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            menuButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            menuButton.widthAnchor.constraint(equalToConstant: 40),
            menuButton.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func updateHint() {
        hintLabel.isHidden = !connected || input.hasController
    }

    private func updateStats() {
        let s = session.sampleStats()
        guard connected else { return }

        // Connection health: show a hint if it stays poor for a few seconds.
        let health: String
        if s.packetLoss < 0.01 && s.rttMs < 40 { health = "● good" }
        else if s.packetLoss < 0.03 && s.rttMs < 80 { health = "● fair" }
        else { health = "● poor" }
        poorSeconds = health == "● poor" ? poorSeconds + 1 : 0
        let showBadge = poorSeconds >= 3
        if netBadge.isHidden == showBadge {
            UIView.animate(withDuration: 0.25) { self.netBadge.isHidden = !showBadge }
        }

        guard settings.showStats else { return }
        let q = session.quality
        let res = s.resolution.map { "\($0.height)p" } ?? q.resolution.rawValue
        let codec = q.hdr ? "HEVC HDR" : (q.hevc ? "HEVC" : "H.264")
        let enhance = session.video.renderer == nil ? "basic" : settings.enhance.rawValue.lowercased()
        statsLabel.text = String(format: "%@ · %@ · %.0f fps · %@\n%.1f/%d Mb/s · RTT %.0f ms · %@\nloss %.1f%% · dropped %d · enhance %@",
                                 res, codec, s.fps, q.label, s.receivedMbps, Int(q.bitrateKbps / 1000), s.rttMs, health,
                                 s.packetLoss * 100, s.framesLost, enhance)
    }

    // MARK: gestures & menu

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(flashMenuButton))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        view.addGestureRecognizer(pinch)
    }

    /// Pinch out = more crop, pinch in = more stretch (only in Fill mode).
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            if settings.screenMode == .fit { settings.screenMode = .fill }
            pinchStartBalance = settings.fillBalance
            pinchStartCustom = settings.custom
        case .changed:
            if settings.screenMode == .custom {
                // Uniform zoom: both axes together, no extra stretch.
                let r = CustomFrame.range
                settings.custom.width = min(r.upperBound, max(r.lowerBound, pinchStartCustom.width * Double(g.scale)))
                settings.custom.height = min(r.upperBound, max(r.lowerBound, pinchStartCustom.height * Double(g.scale)))
            } else {
                settings.fillBalance = min(1, max(0, pinchStartBalance + Double(g.scale - 1) * 1.5))
            }
            panel.sync(settings)
            layoutVideo()
        case .ended, .cancelled:
            saveSettings(settings)
        default: break
        }
    }

    @objc private func flashMenuButton() {
        hideMenuButtonWork?.cancel()
        UIView.animate(withDuration: 0.2) { self.menuButton.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.superview == nil else { return }
            UIView.animate(withDuration: 0.4) { self.menuButton.alpha = 0 }
        }
        hideMenuButtonWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    @objc private func toggleMenu() {
        if panel.superview != nil {
            panel.removeFromSuperview()
            flashMenuButton()
            return
        }
        panel.sync(settings)
        panel.onChange = { [weak self] new in
            guard let self else { return }
            settings = new
            statsLabel.isHidden = !new.showStats
            session.video.renderer?.sharpness = new.enhance.sharpness
            session.video.renderer?.useMetalFX = new.enhance != .off
            layoutVideo()
            saveSettings(new)
        }
        panel.onRest = { [weak self] in
            self?.session.putConsoleToRest()
        }
        panel.onDisconnect = { [weak self] in self?.end(message: nil) }
        panel.onMic = { [weak self] in
            guard let self else { return }
            setMic(!micOn)
        }
        panel.setMicState(micOn)
        panel.onClose = { [weak self] in self?.toggleMenu() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 360),
            panel.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, constant: -16),
        ])
        menuButton.alpha = 1
    }
}

/// In-stream settings panel: screen mode, crop/stretch balance, stats, rest, disconnect.
final class StreamMenuPanel: UIVisualEffectView {
    var onChange: ((StreamSettings) -> Void)?
    var onRest: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onClose: (() -> Void)?
    var onMic: (() -> Void)?
    private let micButton = UIButton(configuration: .tinted())

    func setMicState(_ on: Bool) {
        var c = micButton.configuration ?? .tinted()
        c.title = on ? "Mic on" : "Mic off"
        c.image = UIImage(systemName: on ? "mic.fill" : "mic.slash")
        c.imagePadding = 6
        c.baseForegroundColor = on ? .systemGreen : .white
        micButton.configuration = c
    }

    private var settings = StreamSettings()
    private let mode = UISegmentedControl(items: ScreenMode.allCases.map(\.rawValue))
    private let balance = UISlider()
    private let balanceRow = UIStackView()
    private let customStack = UIStackView()
    private let cWidth = UISlider(), cHeight = UISlider(), cX = UISlider(), cY = UISlider()
    private let cLock = UISwitch()
    private let stats = UISwitch()
    private let enhance = UISegmentedControl(items: EnhanceLevel.allCases.map(\.rawValue))

    init() {
        super.init(effect: UIBlurEffect(style: .systemMaterialDark))
        layer.cornerRadius = 16
        clipsToBounds = true

        let title = UILabel()
        title.text = "Screen"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .white

        mode.addTarget(self, action: #selector(changed), for: .valueChanged)

        let stretch = UILabel(); stretch.text = "Stretch"
        let crop = UILabel(); crop.text = "Crop"
        [stretch, crop].forEach { $0.font = .preferredFont(forTextStyle: .caption1); $0.textColor = .secondaryLabel }
        balance.minimumValue = 0
        balance.maximumValue = 1
        balance.addTarget(self, action: #selector(changed), for: .valueChanged)
        balanceRow.axis = .horizontal
        balanceRow.spacing = 8
        [stretch, balance, crop].forEach(balanceRow.addArrangedSubview)

        enhance.addTarget(self, action: #selector(changed), for: .valueChanged)
        let enhanceTitle = UILabel()
        enhanceTitle.text = "Picture enhance"
        enhanceTitle.font = .preferredFont(forTextStyle: .subheadline)
        enhanceTitle.textColor = .white

        let statsLabel = UILabel()
        statsLabel.text = "Show stream stats"
        statsLabel.textColor = .white
        stats.addTarget(self, action: #selector(changed), for: .valueChanged)
        let statsRow = UIStackView(arrangedSubviews: [statsLabel, stats])

        let tip = UILabel()
        tip.text = "Tip: pinch to adjust (Fill: crop vs stretch, Custom: zoom). Hold the PS button for this menu."
        tip.font = .preferredFont(forTextStyle: .caption2)
        tip.textColor = .secondaryLabel
        tip.numberOfLines = 0

        func button(_ title: String, _ role: UIButton.Configuration, _ action: Selector) -> UIButton {
            var c = role
            c.title = title
            let b = UIButton(configuration: c)
            b.addTarget(self, action: action, for: .touchUpInside)
            return b
        }
        var destructive = UIButton.Configuration.tinted()
        destructive.baseForegroundColor = .systemRed
        destructive.baseBackgroundColor = .systemRed
        let buttons = UIStackView(arrangedSubviews: [
            button("Rest mode", .tinted(), #selector(rest)),
            button("Disconnect", destructive, #selector(disconnect)),
            button("Done", .filled(), #selector(close)),
        ])
        buttons.distribution = .fillEqually
        buttons.spacing = 8

        // Custom mode: width, height, and where the crop happens.
        func sliderRow(_ left: String, _ slider: UISlider, _ right: String, _ range: ClosedRange<Float>) -> UIStackView {
            let l = UILabel(); l.text = left
            let r = UILabel(); r.text = right
            [l, r].forEach { $0.font = .preferredFont(forTextStyle: .caption1); $0.textColor = .secondaryLabel; $0.setContentHuggingPriority(.required, for: .horizontal) }
            slider.minimumValue = range.lowerBound
            slider.maximumValue = range.upperBound
            slider.addTarget(self, action: #selector(changed), for: .valueChanged)
            let row = UIStackView(arrangedSubviews: [l, slider, r])
            row.spacing = 8
            return row
        }
        let cr = Float(CustomFrame.range.lowerBound)...Float(CustomFrame.range.upperBound)
        let lockLabel = UILabel()
        lockLabel.text = "Keep proportions (zoom only)"
        lockLabel.font = .preferredFont(forTextStyle: .footnote)
        lockLabel.textColor = .white
        cLock.addTarget(self, action: #selector(changed), for: .valueChanged)
        customStack.axis = .vertical
        customStack.spacing = 8
        [sliderRow("Width", cWidth, "wider", cr),
         sliderRow("Height", cHeight, "taller", cr),
         UIStackView(arrangedSubviews: [lockLabel, cLock]),
         sliderRow("Keep left", cX, "right", -1...1),
         sliderRow("Keep top", cY, "bottom", -1...1)].forEach(customStack.addArrangedSubview)

        micButton.addTarget(self, action: #selector(mic), for: .touchUpInside)
        setMicState(false)
        let stack = UIStackView(arrangedSubviews: [title, mode, balanceRow, customStack, enhanceTitle, enhance, statsRow, micButton, tip, buttons])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Scrolls when the panel is taller than a landscape iPhone screen.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        contentView.addSubview(scroll)
        scroll.addSubview(stack)
        let fitHeight = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 32)
        fitHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            fitHeight,
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func sync(_ s: StreamSettings) {
        settings = s
        mode.selectedSegmentIndex = ScreenMode.allCases.firstIndex(of: s.screenMode) ?? 1
        balance.value = Float(s.fillBalance)
        balanceRow.isHidden = s.screenMode != .fill
        customStack.isHidden = s.screenMode != .custom
        cWidth.value = Float(s.custom.width)
        cHeight.value = Float(s.custom.height)
        cLock.isOn = s.custom.lockAspect
        cX.value = Float(s.custom.offsetX)
        cY.value = Float(s.custom.offsetY)
        stats.isOn = s.showStats
        enhance.selectedSegmentIndex = EnhanceLevel.allCases.firstIndex(of: s.enhance) ?? 1
    }

    @objc private func changed() {
        settings.screenMode = ScreenMode.allCases[max(0, mode.selectedSegmentIndex)]
        settings.fillBalance = Double(balance.value)
        let old = settings.custom
        var c = old
        c.lockAspect = cLock.isOn
        c.width = Double(cWidth.value)
        c.height = Double(cHeight.value)
        if c.lockAspect {
            // Move both together by whichever slider the user touched.
            if abs(c.width - old.width) > 0.0001 { c.height = min(CustomFrame.range.upperBound, max(CustomFrame.range.lowerBound, old.height * c.width / old.width)) }
            else if abs(c.height - old.height) > 0.0001 { c.width = min(CustomFrame.range.upperBound, max(CustomFrame.range.lowerBound, old.width * c.height / old.height)) }
        }
        c.offsetX = Double(cX.value)
        c.offsetY = Double(cY.value)
        settings.custom = c
        settings.showStats = stats.isOn
        settings.enhance = EnhanceLevel.allCases[max(0, enhance.selectedSegmentIndex)]
        sync(settings)
        onChange?(settings)
    }

    @objc private func rest() { onRest?() }
    @objc private func mic() { onMic?() }
    @objc private func disconnect() { onDisconnect?() }
    @objc private func close() { onClose?() }
}

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}

/// Presents the player on top of the SwiftUI hierarchy.
enum StreamPresenter {
    @MainActor
    static func present(console: Console, host: String, store: ConsoleStore) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }

        do {
            let link: EffectiveQuality.Link = NetworkMonitor.shared.isCellular ? .cellular
                : (host == console.homeHost ? .homeWiFi : .awayWiFi)
            let hdrDisplay = (top.view.window?.screen ?? UIScreen.main).potentialEDRHeadroom > 1.0
            let quality = EffectiveQuality.resolve(store.settings, ps5: console.ps5, link: link, hdrDisplay: hdrDisplay)
            let session = try StreamSession(console: console, host: host, settings: store.settings, quality: quality)
            let vc = StreamViewController(session: session, settings: store.settings) { new in
                Task { @MainActor in store.settings = new }
            }
            top.present(vc, animated: true)
        } catch {
            let alert = UIAlertController(title: "Can't start", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            top.present(alert, animated: true)
        }
    }
}
