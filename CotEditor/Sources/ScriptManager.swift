//
//  ScriptManager.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by nakamuxu on 2005-03-12.
//
//  ---------------------------------------------------------------------------
//
//  © 2004-2007 nakamuxu
//  © 2014-2022 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Combine
import Cocoa

// NSObject-based NSAppleEventDescriptor must be used but not sendable
// -> According to the documentation, NSAppleEventDescriptor is just a wrapper of AEDesc,
//    so seems safe to conform to Sendable. (macOS 12, Xcode 14.0)
extension NSAppleEventDescriptor: @unchecked Sendable { }


private struct ScriptItem {
    
    var script: any Script
    var shortcut: Shortcut
}


final class ScriptManager: NSObject, NSFilePresenter {
    
    // MARK: Public Properties
    
    static let shared = ScriptManager()
    
    @MainActor private(set) var currentScriptName: String?
    
    
    // MARK: Private Properties
    
    private let scriptsDirectoryURL: URL?
    private var scriptHandlersTable: [ScriptingEventType: [any EventScript]] = [:]
    private var currentContext: String?  { didSet { self.applyShortcuts() } }
    
    private lazy var menuBuildingDebouncer = Debouncer(delay: .milliseconds(200)) { [weak self] in self?.buildScriptMenu() }
    private var applicationObserver: AnyCancellable?
    private var documentObserver: AnyCancellable?
    private var syntaxObserver: AnyCancellable?
    
    
    
    // MARK: -
    // MARK: Lifecycle
    
    private override init() {
        
        do {
            self.scriptsDirectoryURL = try FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            self.scriptsDirectoryURL = nil
            print("cannot create the scripts folder: \(error)")
        }
        
        super.init()
        
        // observe script folder change
        NSFileCoordinator.addFilePresenter(self)
        
        // observe the frontmost syntax change
        self.documentObserver = NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)
            .compactMap { ($0.object as! NSWindow).windowController?.document as? Document }
            .sink { [unowned self] in
                self.syntaxObserver = $0.didChangeSyntaxStyle
                    .merge(with: Just($0.syntaxParser.style.name))
                    .removeDuplicates()
                    .receive(on: RunLoop.main)
                    .sink { self.currentContext = $0 }
            }
    }
    
    
    deinit {
        NSFileCoordinator.removeFilePresenter(self)
    }
    
    
    
    // MARK: File Presenter Protocol
    
    let presentedItemOperationQueue: OperationQueue = .main
    
    var presentedItemURL: URL?  { self.scriptsDirectoryURL }
    
    
    /// script folder did change
    func presentedSubitemDidChange(at url: URL) {
        
        if NSApp.isActive {
            self.menuBuildingDebouncer.schedule()
            
        } else {
            self.applicationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification, object: NSApp)
                .receive(on: DispatchQueue.main)
                .first()
                .sink { [weak self] _ in self?.menuBuildingDebouncer.perform() }
        }
    }
    
    
    
    // MARK: Public Methods
    
    /// Menu for context menu.
    var contexualMenu: NSMenu? {
        
        let items = MainMenu.script.menu!.items
            .filter { $0.action != #selector(openScriptFolder) }
        
        guard items.contains(where: { $0.action == #selector(launchScript) }) else { return nil }
        
        let menu = NSMenu()
        menu.items = items.map { $0.copy() as! NSMenuItem }
        
        return menu
    }
    
    
    /// Build the Script menu and scan script handlers.
    func buildScriptMenu() {
        
        assert(Thread.isMainThread)
        
        self.menuBuildingDebouncer.cancel()
        self.applicationObserver = nil
        self.scriptHandlersTable.removeAll()
        
        guard let directoryURL = self.scriptsDirectoryURL else { return }
        
        let openMenuItem = NSMenuItem(title: "Open Scripts Folder".localized,
                                      action: #selector(openScriptFolder), keyEquivalent: "")
        openMenuItem.target = self
        
        MainMenu.script.menu?.items = self.scriptMenuItems(in: directoryURL) + [.separator(), openMenuItem]
        self.applyShortcuts()
    }
    
    
    /// Dispatch an Apple event that notifies the given document was opened.
    ///
    /// - Parameters:
    ///   - eventType: The event trigger to perform script.
    ///   - document: The target document.
    func dispatch(event eventType: ScriptingEventType, document: Document) {
        
        guard
            let scripts = self.scriptHandlersTable[eventType],
            !scripts.isEmpty
        else { return }
        
        let event = self.createEvent(by: document, eventID: eventType.eventID)
        
        Task {
            await self.dispatch(event, handlers: scripts)
        }
    }
    
    
    
    // MARK: Action Message
    
    /// launch script (invoked by menu item)
    @IBAction func launchScript(_ sender: NSMenuItem) {
        
        guard let script = (sender.representedObject as? ScriptItem)?.script else { return assertionFailure() }
        
        Task {
            do {
                // change behavior if modifier key is pressed
                switch NSEvent.modifierFlags {
                    case [.option]:  // open
                        guard NSWorkspace.shared.open(script.url) else {
                            throw ScriptFileError(kind: .open, url: script.url)
                        }
                        
                    case [.option, .shift]:  // reveal
                        guard script.url.isReachable else {
                            throw ScriptFileError(kind: .existance, url: script.url)
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([script.url])
                        
                    default:  // execute
                        self.currentScriptName = script.name
                        try await script.run()
                        if self.currentScriptName == script.name {
                            self.currentScriptName = nil
                        }
                }
                
            } catch {
                self.presentError(error, scriptName: script.name)
            }
        }
    }
    
    
    /// open Script menu folder in Finder
    @IBAction func openScriptFolder(_ sender: Any?) {
        
        guard let dicrectoryURL = self.scriptsDirectoryURL else { return }
        
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dicrectoryURL.path)
    }
    
    
    
    // MARK: Private Methods
    
    /// Present the given error in the ordenery way by taking the error type in the concideration.
    ///
    /// - Parameters:
    ///   - error: The error to present.
    ///   - scriptName: The name of script.
    @MainActor private func presentError(_ error: Error, scriptName: String) {
        
        switch error {
            case let error as ScriptError:
                Console.shared.show(message: error.localizedDescription, title: scriptName)
            default:
                NSApp.presentError(error)
        }
    }
    
    
    /// Create an Apple event caused by the given `Document`.
    ///
    /// - Bug:
    ///   NSScriptObjectSpecifier.descriptor can be nil.
    ///   If `nil`, the error is propagated by passing a string in place of `Document`.
    ///   [#649](https://github.com/coteditor/CotEditor/pull/649)
    ///
    /// - Parameters:
    ///   - document: The document to dispatch an Apple event.
    ///   - eventID: The event ID to be set in the returned event.
    /// - Returns: A descriptor for an Apple event by the `Document`.
    private func createEvent(by document: NSDocument, eventID: AEEventID) -> NSAppleEventDescriptor {
        
        let event = NSAppleEventDescriptor(eventClass: "cEd1",
                                           eventID: eventID,
                                           targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let documentDescriptor = document.objectSpecifier.descriptor ?? NSAppleEventDescriptor(string: "BUG: document.objectSpecifier.descriptor was nil")
        
        event.setParam(documentDescriptor, forKeyword: keyDirectObject)
        
        return event
    }
    
    
    /// Cause the given Apple event to be dispatched to AppleScripts at given URLs.
    ///
    /// - Parameters:
    ///   - event: The Apple event to be dispatched.
    ///   - scripts: AppleScripts handling the given Apple event.
    private func dispatch(_ event: NSAppleEventDescriptor, handlers scripts: [any EventScript]) async {
        
        await withTaskGroup(of: Void.self) { group in
            for script in scripts {
                group.addTask {
                    do {
                        try await script.run(withAppleEvent: event)
                    } catch {
                        await self.presentError(error, scriptName: script.name)
                    }
                }
            }
        }
    }
    
    
    /// Read files recursively and create menu items.
    ///
    /// - Parameters:
    ///   - directoryURL: The directory where to find files recursively.
    /// - Returns: Menu items represents scripts.
    private func scriptMenuItems(in directoryURL: URL) -> [NSMenuItem] {
        
        guard let urls = try? FileManager.default
            .contentsOfDirectory(at: directoryURL,
                                 includingPropertiesForKeys: [.contentTypeKey, .isDirectoryKey, .isExecutableKey],
                                 options: [.skipsHiddenFiles])
        else { return [] }
        
        return urls
            .filter { !$0.lastPathComponent.hasPrefix("_") }  // ignore files/folders of which name starts with "_"
            .sorted(\.lastPathComponent)
            .compactMap { url in
                var name = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "^[0-9]+\\)", with: "", options: .regularExpression)  // remove ordering prefix
                
                var shortcut = Shortcut(keySpecChars: url.deletingPathExtension().pathExtension)
                shortcut = shortcut.isValid ? shortcut : .none
                if shortcut != .none {
                    name = name.replacingOccurrences(of: "\\..+$", with: "", options: .regularExpression)
                }
                
                if name == .separator {  // separator
                    return .separator()
                    
                } else if let descriptor = ScriptDescriptor(at: url, name: name),
                          let script = try? descriptor.makeScript()
                {  // scripts
                    // -> Check script possibility before folder because a script can be a directory, e.g. .scptd.
                    for eventType in descriptor.eventTypes {
                        guard let script = script as? any EventScript else { continue }
                        self.scriptHandlersTable[eventType, default: []].append(script)
                    }
                    
                    let item = NSMenuItem(title: script.name, action: #selector(launchScript), keyEquivalent: "")
                    // -> Shortcut will be applied later in `applyShortcuts()`.
                    item.representedObject = ScriptItem(script: script, shortcut: shortcut)
                    item.target = self
                    item.toolTip = "Option-click to open script in editor.".localized
                    
                    return item
                    
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {  // folder
                    let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                    item.submenu = NSMenu(title: name)
                    item.submenu!.items = self.scriptMenuItems(in: url)
                    return item
                }
                
                return nil
            }
    }
    
    
    /// Apply the keyboard shortcuts to the Script menu items.
    private func applyShortcuts() {
        
        assert(Thread.isMainThread)
        
        guard let menu = MainMenu.script.menu else { return assertionFailure() }
        
        // clear all shortcuts
        menu.items.forEach { $0.removeAllShortcuts() }
        
        // apply shortcuts for priotarized domain
        let usedShortcuts: [Shortcut]
        if let context = self.currentContext, let submenu = menu.item(withTitle: context)?.submenu {
            usedShortcuts = submenu.items.flatMap { $0.applyShortcut(recursively: true) }
        } else {
            usedShortcuts = menu.items.flatMap { $0.applyShortcut(recursively: false) }
        }
        
        // apply shortcuts for the rest
        menu.items.forEach { $0.applyShortcut(recursively: true, exclude: usedShortcuts) }
    }
    
}



private extension NSMenuItem {
    
    /// Remove all keyboard shortcuts recursively.
    func removeAllShortcuts() {
        
        self.keyEquivalent = ""
        self.keyEquivalentModifierMask = []
        self.submenu?.items.forEach { $0.removeAllShortcuts() }
    }
    
    
    /// Apply the keyboard shortcut determined in `ScriptItem` struct stored in the receiver's `.representedObject`.
    ///
    /// - Parameters:
    ///   - recursively: When `true`, apply shortcuts also to the menu items in the `submenu` recursively.
    ///   - exclude: The list of shortcuts not to apply.
    /// - Returns: The shortcuts actually applied.
    @discardableResult
    func applyShortcut(recursively: Bool, exclude: [Shortcut] = []) -> [Shortcut] {
        
        guard self.keyEquivalent.isEmpty else { return [] }
        
        if let scriptItem = self.representedObject as? ScriptItem {
            let shortcut = scriptItem.shortcut
            
            guard !exclude.contains(shortcut) else { return [] }
            
            self.keyEquivalent = shortcut.keyEquivalent
            self.keyEquivalentModifierMask = shortcut.modifierMask
            
            return shortcut == .none ? [] : [shortcut]
            
        } else if recursively {
            return self.submenu?.items.flatMap { $0.applyShortcut(recursively: true, exclude: exclude) } ?? []
            
        } else {
            return []
        }
    }
    
}
