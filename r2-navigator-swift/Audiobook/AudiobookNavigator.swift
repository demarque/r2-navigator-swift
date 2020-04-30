//
//  AudiobookNavigator.swift
//  r2-navigator-swift
//
//  Created by Mickaël Menu on 12/03/2020.
//
//  Copyright 2020 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import AVFoundation
import Foundation
import R2Shared

public protocol AudiobookNavigatorDelegate: MediaNavigatorDelegate { }

@available(iOS 10.0, *)
open class AudiobookNavigator: MediaNavigator, AudioSessionUser, Loggable {
    
    public weak var delegate: AudiobookNavigatorDelegate?
    
    private let publication: Publication
    private let initialLocation: Locator?

    public init(publication: Publication, initialLocation: Locator? = nil) {
        self.publication = publication
        self.initialLocation = initialLocation
            ?? publication.readingOrder.first.map { Locator(link: $0) }
        
        let durations = publication.readingOrder.map { $0.duration ?? 0 }
        self.durations = durations
        let totalDuration = publication.metadata.duration ?? durations.reduce(0, +)
        self.totalDuration = (totalDuration > 0) ? totalDuration : nil
    }
    
    deinit {
        AudioSession.shared.end(for: self)
    }
    
    // Current playback info.
    public var playbackInfo: MediaPlaybackInfo {
        MediaPlaybackInfo(
            resourceIndex: resourceIndex,
            state: state,
            time: currentTime,
            duration: resourceDuration
        )
    }

    // Index of the current resource in the reading order.
    private var resourceIndex: Int = 0
    
    /// Starting time of the current resource, in the reading order.
    private var resourceStartingTime: Double? {
        durations[..<resourceIndex].reduce(0, +)
    }

    /// Duration in seconds in the current resource.
    private var resourceDuration: Double? {
        if let duration = player.currentItem?.duration, duration.isNumeric {
            return duration.secondsOrZero
        } else {
            return publication.readingOrder[resourceIndex].duration
        }
    }

    /// Total duration in the publication.
    public private(set) var totalDuration: Double?

    /// Durations indexed by reading order position.
    private let durations: [Double]

    private var timeControlStatusObserver: NSKeyValueObservation?
    private var currentItemObserver: NSKeyValueObservation?

    private lazy var player: AVPlayer = {
        let player = AVPlayer()
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false

        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 1000), queue: .main) { [weak self] time in
            if let self = self {
                let time = time.secondsOrZero
                self.playbackDidChange(time)
            }
        }
        
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new, .old]) { [weak self] player, change in
            self?.playbackDidChange()
        }
        
        currentItemObserver = player.observe(\.currentItem, options: [.new, .old]) { [weak self] player, change in
            self?.playbackDidChange()
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            if let self = self,
                (self.delegate?.navigator(self, shouldPlayNextResource: self.makePlaybackInfo()) ?? true),
                let currentItem = player.currentItem,
                currentItem == (notification.object as? AVPlayerItem) {
                if self.goToNextResource() {
                    self.play()
                }
            }
        }
        
        return player
    }()
    
    private func playbackDidChange(_ time: Double? = nil) {
        if let time = time {
            let locator = makeLocator(forTime: time)
            currentLocation = locator
            self.delegate?.navigator(self, locationDidChange: locator)
        }
        delegate?.navigator(self, playbackDidChange: makePlaybackInfo(forTime: time))
        // FIXME: probably not working when paused
        delegate?.navigator(self, loadedTimeRangesDidChange: (player.currentItem?.loadedTimeRanges ?? [])
            .map { value in
                let range = value.timeRangeValue
                let start = range.start.secondsOrZero
                let duration = range.duration.secondsOrZero
                return start..<(start + duration)
            }
        )
    }
    
    private func makePlaybackInfo(forTime time: Double? = nil) -> MediaPlaybackInfo {
        return MediaPlaybackInfo(
            resourceIndex: resourceIndex,
            state: state,
            time: time ?? currentTime,
            duration: resourceDuration
        )
    }

    private func makeLocator(forTime time: Double) -> Locator {
        let link = publication.readingOrder[resourceIndex]
        
        var progression: Double?
        if let duration = resourceDuration, duration > 0 {
            progression = resourceDuration.map { time / max($0, 1) }
        }
        
        var totalProgression: Double? = nil
        if let totalDuration = totalDuration, totalDuration > 0, let startingTime = resourceStartingTime {
            totalProgression = (startingTime + time) / totalDuration
        }
        
        return Locator(
            href: link.href,
            type: link.type ?? "audio/*",
            title: link.title,
            locations: Locator.Locations(
                fragments: ["t=\(time)"],
                progression: progression,
                totalProgression: totalProgression
            )
        )
    }

    // MARK: - Navigator
    
    public private(set) var currentLocation: Locator?

    @discardableResult
    public func go(to locator: Locator, animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        guard let newResourceIndex = publication.readingOrder.firstIndex(withHref: locator.href),
            let url = publication.url(to: locator.href) else
        {
            return false
        }
        
        pause()

        // Loads resource
        if player.currentItem == nil || resourceIndex != newResourceIndex {
            log(.info, "Starts playing \(url.absoluteString)")
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            resourceIndex = newResourceIndex
            currentLocation = locator
            delegate?.navigator(self, loadedTimeRangesDidChange: [])
        }

        // Seeks to time
        let time = locator.time(forDuration: resourceDuration) ?? 0
        if time > 0 {
            player.seek(to: CMTime(seconds: time, preferredTimescale: 1000))
        }
        
        play()

        return true
    }


    @discardableResult
    public func go(to link: Link, animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        return go(to: Locator(link: link), animated: animated, completion: completion)
    }
    
    @discardableResult
    public func goForward(animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        return false
    }
    
    @discardableResult
    public func goBackward(animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        return false
    }
    
    @discardableResult
    public func goToNextResource(animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        return goToResourceIndex(resourceIndex + 1, animated: animated, completion: completion)
    }
    
    @discardableResult
    public func goToPreviousResource(animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        return goToResourceIndex(resourceIndex - 1, animated: animated, completion: completion)
    }
    
    @discardableResult
    public func goToResourceIndex(_ index: Int, animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        guard publication.readingOrder.indices ~= index else {
            return false
        }
        return go(to: publication.readingOrder[index], animated: animated, completion: completion)
    }
    
    // MARK: – MediaNavigator
    
    public var currentTime: Double {
        return player.currentTime().secondsOrZero
    }

    public var volume: Double {
        get { Double(player.volume) }
        set {
            assert(0...1 ~= newValue)
            player.volume = Float(newValue)
        }
    }

    public var rate: Double = 1 {
        // We don't alias to `player.rate`, because it might be 0 when the player is paused. `rate`
        // is actually the default rate while playing.
        didSet {
            assert(rate >= 0)
            if state != .paused {
                player.rate = Float(rate)
            }
        }
    }
    
    public var state: MediaPlaybackState {
        MediaPlaybackState(player.timeControlStatus)
    }

    public func play() {
        AudioSession.shared.start(with: self)
        
        if player.currentItem == nil, let location = initialLocation {
            go(to: location)
        }
        player.playImmediately(atRate: Float(rate))
    }

    public func pause() {
        player.pause()
    }
    
    public func seek(to time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 1000))
    }
    
    public func seek(relatively delta: Double) {
        seek(to: currentTime + delta)
    }
    
}

private extension Locator {
    
    private static let timeFragmentRegex = try! NSRegularExpression(pattern: #"t=(\d+(?:\.\d+)?)"#)
    
    // FIXME: Should probably be in `Locator` itself.
    func time(forDuration duration: Double? = nil) -> Double? {
        if let progression = locations.progression, let duration = duration {
            return progression * duration
        } else {
            for fragment in locations.fragments {
                let range = NSRange(fragment.startIndex..<fragment.endIndex, in: fragment)
                if let match = Self.timeFragmentRegex.firstMatch(in: fragment, range: range) {
                    let matchRange = match.range(at: 1)
                    if matchRange.location != NSNotFound, let range = Range(matchRange, in: fragment) {
                        return Double(fragment[range])
                    }
                }
            }
        }
        return nil
    }
    
}

@available(iOS 10.0, *)
private extension MediaPlaybackState {
    
    init(_ timeControlStatus: AVPlayer.TimeControlStatus) {
        switch timeControlStatus {
        case .paused:
            self = .paused
        case .waitingToPlayAtSpecifiedRate:
            self = .loading
        case .playing:
            self = .playing
        @unknown default:
            self = .loading
        }
    }
    
}

private extension CMTime {
    
    var secondsOrZero: Double {
        return isNumeric ? seconds : 0
    }
    
}
