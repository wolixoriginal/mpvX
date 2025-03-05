/*
 * This file is part of mpv.
 *
 * mpv is free software) you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation) either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY) without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

import Cocoa

extension NSTouchBar.CustomizationIdentifier {
    public static let customId: NSTouchBar.CustomizationIdentifier = "io.mpv.touchbar"
}

extension NSTouchBarItem.Identifier {
    public static let seekBar = NSTouchBarItem.Identifier(custom: ".seekbar")
    public static let play = NSTouchBarItem.Identifier(custom: ".play")
    public static let nextItem = NSTouchBarItem.Identifier(custom: ".nextItem")
    public static let previousItem = NSTouchBarItem.Identifier(custom: ".previousItem")
    public static let nextChapter = NSTouchBarItem.Identifier(custom: ".nextChapter")
    public static let previousChapter = NSTouchBarItem.Identifier(custom: ".previousChapter")
    public static let cycleAudio = NSTouchBarItem.Identifier(custom: ".cycleAudio")
    public static let cycleSubtitle = NSTouchBarItem.Identifier(custom: ".cycleSubtitle")
    public static let currentPosition = NSTouchBarItem.Identifier(custom: ".currentPosition")
    public static let timeLeft = NSTouchBarItem.Identifier(custom: ".timeLeft")

    init(custom: String) {
        self.init(NSTouchBar.CustomizationIdentifier.customId + custom)
    }
}

extension TouchBar {
    typealias ViewHandler = (Config) -> (NSView)

    struct Config {
        let name: String
        let command: String
        var item: NSCustomTouchBarItem?
        var constraint: NSLayoutConstraint?
        let image: NSImage
        let imageAlt: NSImage
        let handler: ViewHandler

        init(
            name: String = "",
            command: String = "",
            item: NSCustomTouchBarItem? = nil,
            constraint: NSLayoutConstraint? = nil,
            image: NSImage? = nil,
            imageAlt: NSImage? = nil,
            handler: @escaping ViewHandler = { _ in return NSButton(title: "", target: nil, action: nil) }
        ) {
            self.name = name
            self.command = command
            self.item = item
            self.constraint = constraint
            self.image = image ?? NSImage(size: NSSize(width: 1, height: 1))
            self.imageAlt = imageAlt ?? NSImage(size: NSSize(width: 1, height: 1))
            self.handler = handler
        }
    }
}

class TouchBar: NSTouchBar, NSTouchBarDelegate, EventSubscriber {
    unowned let appHub: AppHub
    var event: EventHelper? { return appHub.event }
    var input: InputHelper { return appHub.input }
    var configs: [NSTouchBarItem.Identifier: Config] = [:]
    var observers: [NSKeyValueObservation] = []
    var isPaused: Bool = false { didSet { updatePlayButton() } }
    var position: Double = 0 { didSet { updateTouchBarTimeItems() } }
    var duration: Double = 0 { didSet { updateTouchBarTimeItems() } }
    var rate: Double = 1

    init(_ appHub: AppHub) {
        self.appHub = appHub
        super.init()

        configs = [
            .seekBar: Config(name: "Seek Bar", command: "seek %f absolute-percent", handler: createSlider),
            .currentPosition: Config(name: "Current Position", handler: createText),
            .timeLeft: Config(name: "Time Left", handler: createText),
            .play: Config(
                name: "Play Button",
                command: "cycle pause",
                image: .init(named: NSImage.touchBarPauseTemplateName),
                imageAlt: .init(named: NSImage.touchBarPlayTemplateName),
                handler: createButton
            ),
            .previousItem: Config(
                name: "Previous Playlist Item",
                command: "playlist-prev",
                image: .init(named: NSImage.touchBarGoBackTemplateName),
                handler: createButton
            ),
            .nextItem: Config(
                name: "Next Playlist Item",
                command: "playlist-next",
                image: .init(named: NSImage.touchBarGoForwardTemplateName),
                handler: createButton
            ),
            .previousChapter: Config(
                name: "Previous Chapter",
                command: "add chapter -1",
                image: .init(named: NSImage.touchBarSkipBackTemplateName),
                handler: createButton
            ),
            .nextChapter: Config(
                name: "Next Chapter",
                command: "add chapter 1",
                image: .init(named: NSImage.touchBarSkipAheadTemplateName),
                handler: createButton
            ),
            .cycleAudio: Config(
                name: "Cycle Audio",
                command: "cycle audio",
                image: .init(named: NSImage.touchBarAudioInputTemplateName),
                handler: createButton
            ),
            .cycleSubtitle: Config(
                name: "Cycle Subtitle",
                command: "cycle sub",
                image: .init(named: NSImage.touchBarComposeTemplateName),
                handler: createButton
            )
        ]

        delegate = self
        customizationIdentifier = .customId
        defaultItemIdentifiers = [.play, .previousItem, .nextItem, .seekBar]
        customizationAllowedItemIdentifiers = [.play, .seekBar, .previousItem, .nextItem,
            .previousChapter, .nextChapter, .cycleAudio, .cycleSubtitle, .currentPosition, .timeLeft]
        observers += [observe(\.isVisible, options: [.new]) { _, change in self.changed(visibility: change.newValue) }]

        event?.subscribe(self, event: .init(name: "duration", format: MPV_FORMAT_DOUBLE))
        event?.subscribe(self, event: .init(name: "time-pos", format: MPV_FORMAT_DOUBLE))
        event?.subscribe(self, event: .init(name: "speed", format: MPV_FORMAT_DOUBLE))
        event?.subscribe(self, event: .init(name: "pause", format: MPV_FORMAT_FLAG))
        event?.subscribe(self, event: .init(name: "MPV_EVENT_END_FILE"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard let config = configs[identifier] else { return nil }

        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = config.handler(config)
        item.customizationLabel = config.name
        configs[identifier]?.item = item
        observers += [item.observe(\.isVisible, options: [.new]) { _, change in self.changed(visibility: change.newValue) }]
        return item
    }

    lazy var createButton: ViewHandler = { config in
        return NSButton(image: config.image, target: self, action: #selector(Self.buttonAction(_:)))
    }

    lazy var createText: ViewHandler = { _ in
        let text = NSTextField(labelWithString: "0:00")
        text.alignment = .center
        return text
    }

    lazy var createSlider: ViewHandler = { _ in
        let slider = NSSlider(target: self, action: #selector(Self.seekbarChanged(_:)))
        slider.minValue = 0
        slider.maxValue = 100
        return slider
    }

    func changed(visibility: Bool?) {
        if let visible = visibility, visible {
            updateTouchBarTimeItems()
            updatePlayButton()
        }
    }

    func updateTouchBarTimeItems() {
        if !isVisible { return }
        updateSlider()
        updateTimeLeft()
        updateCurrentPosition()
    }

    func updateSlider() {
        guard let config = configs[.seekBar], let slider = config.item?.view as? NSSlider else { return }
        if !(config.item?.isVisible ?? false) { return }

        slider.isEnabled = duration > 0
        if !slider.isHighlighted {
            slider.doubleValue = slider.isEnabled ? (position / duration) * 100 : 0
        }
    }

    func updateTimeLeft() {
        guard let config = configs[.timeLeft], let text = config.item?.view as? NSTextField else { return }
        if !(config.item?.isVisible ?? false) { return }

        removeConstraintFor(identifier: .timeLeft)
        text.stringValue = duration > 0 ? "-" + format(time: Int(floor(duration) - floor(position))) : ""
        if !text.stringValue.isEmpty {
            applyConstraintFrom(string: "-" + format(time: Int(duration)), identifier: .timeLeft)
        }
    }

    func updateCurrentPosition() {
        guard let config = configs[.currentPosition], let text = config.item?.view as? NSTextField else { return }
        if !(config.item?.isVisible ?? false) { return }

        text.stringValue = format(time: Int(floor(position)))
        removeConstraintFor(identifier: .currentPosition)
        applyConstraintFrom(string: format(time: Int(duration > 0 ? duration : position)), identifier: .currentPosition)
    }

    func updatePlayButton() {
        guard let config = configs[.play], let button = config.item?.view as? NSButton else { return }
        if !isVisible || !(config.item?.isVisible ?? false) { return }
        button.image = isPaused ? configs[.play]?.imageAlt : configs[.play]?.image
    }

    @objc func buttonAction(_ button: NSButton) {
        guard let identifier = getIdentifierFrom(view: button), let command = configs[identifier]?.command else { return }
        input.command(command)
    }

    @objc func seekbarChanged(_ slider: NSSlider) {
        guard let identifier = getIdentifierFrom(view: slider), let command = configs[identifier]?.command else { return }
        input.command(String(format: command, slider.doubleValue))
    }

    func format(time: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = time >= (60 * 60) ? [.dropLeading] : []
        formatter.allowedUnits = time >= (60 * 60) ? [.hour, .minute, .second] : [.minute, .second]
        return formatter.string(from: TimeInterval(time)) ?? "0:00"
    }

    func removeConstraintFor(identifier: NSTouchBarItem.Identifier) {
        guard let text = configs[identifier]?.item?.view as? NSTextField,
              let constraint = configs[identifier]?.constraint as? NSLayoutConstraint else { return }
        text.removeConstraint(constraint)
    }

    func applyConstraintFrom(string: String, identifier: NSTouchBarItem.Identifier) {
        guard let text = configs[identifier]?.item?.view as? NSTextField else { return }
        let fullString = string.components(separatedBy: .decimalDigits).joined(separator: "0")
        let textField = NSTextField(labelWithString: fullString)
        let con = NSLayoutConstraint(item: text, attribute: .width, relatedBy: .equal, toItem: nil,
            attribute: .notAnAttribute, multiplier: 1.1, constant: ceil(textField.frame.size.width))
        text.addConstraint(con)
        configs[identifier]?.constraint = con
    }

    func getIdentifierFrom(view: NSView) -> NSTouchBarItem.Identifier? {
        for (identifier, config) in configs where config.item?.view == view {
            return identifier
        }
        return nil
    }

    func handle(event: EventHelper.Event) {
        switch event.name {
        case "MPV_EVENT_END_FILE":
            position = 0
            duration = 0
        case "time-pos":
            let newPosition = max(event.double ?? 0, 0)
            if Int((floor(newPosition) - floor(position)) / rate) != 0 {
                position = newPosition
            }
        case "pause": isPaused = event.bool ?? false
        case "duration": duration = event.double ?? 0
        case "speed": rate = event.double ?? 1
        default: break
        }
    }
}
