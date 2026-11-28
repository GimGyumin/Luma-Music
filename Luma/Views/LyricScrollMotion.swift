// Luma — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.

import SwiftUI
import QuartzCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Moves the existing native scroll view during active transitions without publishing
/// frame offsets to SwiftUI. The reader still owns jumps to rows outside the lazy layout.
@MainActor
final class LyricScrollMotion {
    nonisolated struct Row: Equatable, Sendable {
        let top: CGFloat
        let height: CGFloat
    }

    nonisolated static let coordinateSpace = "lyric-scroll-content"

    private var rows: [Int: Row] = [:]
    private weak var probe: LyricScrollProbeView?
    private var displayLink: CADisplayLink?
    private var trajectory: LyricScrollTrajectory?
    private var startedAt: CFTimeInterval = 0
    private var sampledAt: CFTimeInterval = 0
    private var readerIsAnimating = false
    private var readerSample: (offset: CGFloat, time: CFTimeInterval)?
    private var readerVelocity = 0.0

    func updateReaderPhase(_ phase: ScrollPhase) {
        readerIsAnimating = phase == .animating
        if !readerIsAnimating {
            readerSample = nil
            readerVelocity = 0
        }
    }

    func observeReaderOffset(_ offset: CGFloat) {
        guard readerIsAnimating, trajectory == nil else { return }
        let now = CACurrentMediaTime()
        defer { readerSample = (offset, now) }
        guard let previous = readerSample, now > previous.time, now - previous.time < 0.12 else {
            readerVelocity = 0
            return
        }
        readerVelocity = max(-2_400, min(2_400, Double(offset - previous.offset) / max(1.0 / 120, now - previous.time)))
    }

    func measure(_ row: Row, at index: Int) {
        rows[index] = row
    }

    func forget(_ index: Int) {
        rows.removeValue(forKey: index)
    }

    func attach(_ view: LyricScrollProbeView) {
        if probe !== view { stop() }
        probe = view
    }

    func detach(_ view: LyricScrollProbeView) {
        guard probe === view else { return }
        stop()
        probe = nil
    }

    /// Returns the response used by the decorative row cascade, or nil when
    /// SwiftUI must resolve the destination through its lazy scroll reader.
    func move(to index: Int, anchor: CGFloat, viewport: CGFloat, cadence: LyricScrollCadence,
              lowPower: Bool, forwardOnly: Bool) -> Double? {
        guard let probe, let scroll = probe.scrollView, let row = rows[index],
              viewport > 0, row.height > 0, row.top.isFinite else { return nil }
        let position = probe.offset(in: scroll)
        let target = probe.clamp(probe.contentTop(in: scroll) + row.top
            - anchor * max(0, viewport - row.height), in: scroll)
        guard position.isFinite, target.isFinite else { return nil }
        let now = CACurrentMediaTime()
        let measuredReaderVelocity = readerSample.map { now - $0.time < 0.10 ? readerVelocity : 0 } ?? 0
        let velocity = trajectory?.sample(at: sampledAt - startedAt).velocity ?? measuredReaderVelocity
        let sample = LyricScrollTrajectory.Sample(offset: Double(position), velocity: velocity)
        let next = forwardOnly
            ? LyricScrollTrajectory.forward(from: sample, to: Double(target), cadence: cadence)
            : LyricScrollTrajectory(start: sample, target: Double(target),
                response: LyricScrollTrajectory.response(from: sample, to: Double(target), cadence: cadence))
        if abs(next.target - sample.offset) < 0.5, abs(next.start.velocity) < 8 {
            stop()
            return next.response
        }
        if let trajectory, abs(trajectory.target - next.target) < 0.5,
           !forwardOnly || (trajectory.target >= trajectory.start.offset
               && (0...(trajectory.response * (trajectory.target - trajectory.start.offset))).contains(trajectory.start.velocity)) {
            return trajectory.response
        }

        trajectory = next
        startedAt = now
        sampledAt = now
        if displayLink == nil {
            let target = LyricScrollDisplayTarget(motion: self)
            #if os(iOS)
            let link = CADisplayLink(target: target, selector: #selector(LyricScrollDisplayTarget.tick(_:)))
            #else
            let link = probe.displayLink(target: target, selector: #selector(LyricScrollDisplayTarget.tick(_:)))
            #endif
            displayLink = link
            updateFrameRate(lowPower: lowPower)
            link.add(to: .main, forMode: .common)
        }
        return next.response
    }

    func updateFrameRate(lowPower: Bool) {
        guard let probe, let displayLink else { return }
        #if os(iOS)
        let available = probe.window?.screen.maximumFramesPerSecond ?? 60
        #else
        let available = probe.window?.screen?.maximumFramesPerSecond ?? 60
        #endif
        let maximum = Float(min(lowPower ? 60 : 120, max(1, available)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, maximum),
            maximum: maximum, preferred: maximum)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        trajectory = nil
        readerSample = nil
        readerVelocity = 0
    }

    fileprivate func tick() {
        guard let trajectory, let probe, let scroll = probe.scrollView, !probe.isBeingDragged(scroll) else {
            stop()
            return
        }
        sampledAt = CACurrentMediaTime()
        let elapsed = sampledAt - startedAt
        let sample = trajectory.sample(at: elapsed)
        if (abs(sample.offset - trajectory.target) < 0.5 && abs(sample.velocity) < 8) || elapsed > 2 {
            probe.setOffset(CGFloat(trajectory.target), in: scroll)
            stop()
        } else {
            probe.setOffset(CGFloat(sample.offset), in: scroll)
        }
    }
}

@MainActor
private final class LyricScrollDisplayTarget: NSObject {
    private weak var motion: LyricScrollMotion?

    init(motion: LyricScrollMotion) {
        self.motion = motion
    }

    @objc func tick(_ link: CADisplayLink) {
        if let motion { motion.tick() }
        else { link.invalidate() }
    }
}

#if os(iOS)
struct LyricScrollProbe: UIViewRepresentable {
    let motion: LyricScrollMotion

    func makeUIView(context: Context) -> LyricScrollProbeView { LyricScrollProbeView(motion: motion) }
    func updateUIView(_ uiView: LyricScrollProbeView, context: Context) {}
}

@MainActor
final class LyricScrollProbeView: UIView {
    private weak var motion: LyricScrollMotion?

    init(motion: LyricScrollMotion) {
        self.motion = motion
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { motion?.detach(self) }
        else { motion?.attach(self) }
    }

    var scrollView: UIScrollView? {
        guard window != nil else { return nil }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }

    func isBeingDragged(_ scroll: UIScrollView) -> Bool { scroll.isDragging || scroll.isDecelerating }
    func offset(in scroll: UIScrollView) -> CGFloat { scroll.contentOffset.y + scroll.adjustedContentInset.top }
    func contentTop(in scroll: UIScrollView) -> CGFloat { convert(.zero, to: scroll).y }

    func clamp(_ offset: CGFloat, in scroll: UIScrollView) -> CGFloat {
        let maximum = scroll.contentSize.height - scroll.bounds.height
            + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom
        return min(max(0, maximum), max(0, offset))
    }

    func setOffset(_ offset: CGFloat, in scroll: UIScrollView) {
        let y = clamp(offset, in: scroll) - scroll.adjustedContentInset.top
        if abs(scroll.contentOffset.y - y) > 0.05 {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
        }
    }
}
#elseif os(macOS)
struct LyricScrollProbe: NSViewRepresentable {
    let motion: LyricScrollMotion

    func makeNSView(context: Context) -> LyricScrollProbeView { LyricScrollProbeView(motion: motion) }
    func updateNSView(_ nsView: LyricScrollProbeView, context: Context) {}
}

@MainActor
final class LyricScrollProbeView: NSView {
    private weak var motion: LyricScrollMotion?

    init(motion: LyricScrollMotion) {
        self.motion = motion
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { motion?.detach(self) }
        else { motion?.attach(self) }
    }

    var scrollView: NSScrollView? { window == nil ? nil : enclosingScrollView }

    // SwiftUI's scroll-phase callback stops the motion when the user takes over.
    func isBeingDragged(_ scroll: NSScrollView) -> Bool { false }

    func offset(in scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return 0 }
        let clip = scroll.contentView.bounds
        return document.isFlipped ? clip.minY - document.frame.minY : document.frame.maxY - clip.maxY
    }

    func contentTop(in scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return 0 }
        let y = convert(.zero, to: document).y
        return document.isFlipped ? y - document.bounds.minY : document.bounds.maxY - y
    }

    func clamp(_ offset: CGFloat, in scroll: NSScrollView) -> CGFloat {
        let maximum = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        return min(max(0, maximum), max(0, offset))
    }

    func setOffset(_ offset: CGFloat, in scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let offset = clamp(offset, in: scroll)
        let y = document.isFlipped ? document.frame.minY + offset : document.frame.maxY - clip.bounds.height - offset
        if abs(clip.bounds.minY - y) > 0.05 {
            clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
    }
}
#endif
