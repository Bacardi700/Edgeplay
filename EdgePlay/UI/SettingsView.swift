// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ConsoleStore
    @Environment(\.dismiss) private var dismiss
    @State private var vibrationResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $store.settings.screenMode) {
                        ForEach(ScreenMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if store.settings.screenMode == .custom {
                        CustomFrameControls(custom: $store.settings.custom)
                    }
                    if store.settings.screenMode == .fill {
                        VStack(alignment: .leading) {
                            Slider(value: $store.settings.fillBalance, in: 0...1) {
                                Text("Crop vs stretch")
                            } minimumValueLabel: {
                                Text("Stretch").font(.caption)
                            } maximumValueLabel: {
                                Text("Crop").font(.caption)
                            }
                            ScreenPreview(balance: store.settings.fillBalance)
                                .frame(height: 90)
                        }
                    }
                } header: {
                    Text("Screen")
                } footer: {
                    Text("Fill uses the whole screen, notch area included. Slide toward Stretch to keep everything visible (slightly wider picture) or toward Crop to keep proportions (top and bottom edges trimmed). You can also pinch during play.")
                }

                Section {
                    Toggle("Auto quality", isOn: $store.settings.autoQuality)
                    if !store.settings.autoQuality {
                        Picker("Resolution", selection: $store.settings.resolution) {
                            ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Frame rate", selection: $store.settings.fps) {
                            Text("30 fps").tag(UInt32(30))
                            Text("60 fps").tag(UInt32(60))
                        }
                        Picker("Bitrate", selection: $store.settings.bitrateKbps) {
                            ForEach(StreamSettings.bitratePresets) { Text($0.label).tag($0.kbps) }
                        }
                    }
                    Picker("Codec (PS5)", selection: $store.settings.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("HDR (PS5, HEVC)", isOn: $store.settings.hdr)
                        .disabled(store.settings.codec != .hevc)
                } header: {
                    Text("Stream quality")
                } footer: {
                    Text("Auto picks 1080p60 at 15 Mb/s on home Wi-Fi, 1080p60 at 10 Mb/s away from home, and 720p60 at 6 Mb/s on mobile data. PS5 Remote Play tops out at 1080p. HDR needs an HDR iPhone screen and an HDR game.")
                }

                Section {
                    Picker("Picture enhance", selection: $store.settings.enhance) {
                        ForEach(EnhanceLevel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("120 Hz presentation (ProMotion)", isOn: $store.settings.highRefresh)
                } header: {
                    Text("Picture")
                } footer: {
                    Text("Enhance upscales the 1080p stream to your screen's exact resolution with MetalFX and sharpens away compression blur. 120 Hz shows each frame the moment it's decoded for smoother motion.")
                }

                Section("Overlay & controller") {
                    Toggle("Show stream stats", isOn: $store.settings.showStats)
                    Toggle("Controller rumble", isOn: $store.settings.rumble)
                    if store.settings.rumble {
                        HStack {
                            Text("Vibration strength")
                            Slider(value: $store.settings.rumbleStrength, in: 0.2...1)
                        }
                    }
                    Toggle("DualSense lightbar", isOn: $store.settings.lightbar)
                    Toggle("Motion controls (gyro)", isOn: $store.settings.motion)
                    if store.settings.motion {
                        Toggle("Invert gyro horizontal", isOn: $store.settings.invertGyroHorizontal)
                        Toggle("Invert gyro vertical", isOn: $store.settings.invertGyroVertical)
                    }
                    Toggle("Vibrate iPhone if controller can't", isOn: $store.settings.phoneVibration)
                    Button("Test vibration") { vibrationResult = ControllerInput.testVibration() }
                    if let vibrationResult {
                        Text(vibrationResult).font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Microphone on at start", isOn: $store.settings.microphone)
                    Toggle("Adaptive triggers", isOn: $store.settings.adaptiveTriggers)
                    if store.settings.adaptiveTriggers {
                        HStack {
                            Text("Trigger strength")
                            Slider(value: $store.settings.triggerStrength, in: 0.2...1)
                        }
                    }
                }

                Section("Playing away from home") {
                    Text("Install Tailscale on this iPhone and on an always-on device at home (Raspberry Pi, Apple TV, PC or NAS) set up as a subnet router for your home network. Then put the console's home IP (or the Tailscale IP) as the console's away address. Wake works too if the console has “Stay connected to the internet” and “Enable turning on from network” on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("EdgePlay uses chiaki-ng, the open-source Remote Play library, under the AGPL-3.0. Not affiliated with or endorsed by Sony Interactive Entertainment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Little diagram of how the picture will sit on a 19.5:9 screen.
private struct ScreenPreview: View {
    var balance: Double

    var body: some View {
        GeometryReader { geo in
            let screen = CGRect(origin: .zero, size: CGSize(width: geo.size.height * 19.5 / 9, height: geo.size.height))
            let frame = ScreenGeometry.videoFrame(in: screen, videoAspect: 16.0 / 9.0, mode: .fill, balance: balance)
            let natural = CGSize(width: screen.height * 16 / 9, height: screen.height)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                // Draw the 16:9 picture at its natural shape, then apply the same
                // scale the player uses, so stretching shows as an oval circle.
                LinearGradient(colors: [.blue, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Grid())
                    .frame(width: natural.width, height: natural.height)
                    .scaleEffect(x: frame.width / natural.width, y: frame.height / natural.height)
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity)
        }
    }

    private struct Grid: View {
        var body: some View {
            GeometryReader { g in
                Path { p in
                    for i in 1..<4 {
                        let x = g.size.width * CGFloat(i) / 4
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    }
                    for i in 1..<3 {
                        let y = g.size.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                    }
                }
                .stroke(.white.opacity(0.35), lineWidth: 1)
                // Circles look round only when nothing is stretched.
                Circle().stroke(.white, lineWidth: 2)
                    .frame(width: g.size.height * 0.5, height: g.size.height * 0.5)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
        }
    }
}

/// Width / height / position sliders for Custom screen mode.
private struct CustomFrameControls: View {
    @Binding var custom: CustomFrame

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Width", value: Binding(get: { custom.width }, set: { setWidth($0) }), range: CustomFrame.range, left: "fitted", right: "wider")
            row("Height", value: Binding(get: { custom.height }, set: { setHeight($0) }), range: CustomFrame.range, left: "full", right: "taller")
            Toggle("Keep proportions (zoom only)", isOn: $custom.lockAspect)
            row("Horizontal crop", value: $custom.offsetX, range: -1...1, left: "keep left", right: "keep right")
            row("Vertical crop", value: $custom.offsetY, range: -1...1, left: "keep top", right: "keep bottom")
            Text("Width past about 122% fills the screen and crops the sides; height past 100% crops top and bottom. The position sliders pick which side loses the crop.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, left: String, right: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Slider(value: value, in: range) { Text(title) } minimumValueLabel: {
                Text(left).font(.caption2)
            } maximumValueLabel: {
                Text(right).font(.caption2)
            }
        }
    }

    private func clamp(_ v: Double) -> Double { min(CustomFrame.range.upperBound, max(CustomFrame.range.lowerBound, v)) }

    private func setWidth(_ w: Double) {
        if custom.lockAspect, custom.width > 0 { custom.height = clamp(custom.height * w / custom.width) }
        custom.width = w
    }

    private func setHeight(_ h: Double) {
        if custom.lockAspect, custom.height > 0 { custom.width = clamp(custom.width * h / custom.height) }
        custom.height = h
    }
}
