import Foundation
import UIKit
import UserNotifications
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import TelegramCallsUI
import AccountContext
import Postbox
import TelegramStringFormatting
import LocalizedPeerData
import SGSimpleSettings

/// An in-memory receipt window, not a second message store. Events observed in
/// the foreground or while disabled are consumed too, so replaying them cannot
/// turn them into background notifications. Server time avoids device-clock skew.
private struct ArielgramLocalNotificationGate {
    private(set) var generation = 0
    private var startedAt: TimeInterval?
    private var seen = Set<String>()
    private var order: [String] = []

    mutating func update(enabled: Bool, background: Bool, now: TimeInterval) {
        let eligible = enabled && background
        if eligible != (self.startedAt != nil) {
            self.generation += 1
            self.startedAt = eligible ? now : nil
        }
    }

    mutating func consume(identifiers: [String], timestamp: Int32, serverNow: Int32, now: TimeInterval) -> Bool {
        let fresh = identifiers.filter { !self.seen.contains($0) }
        for identifier in fresh where self.seen.insert(identifier).inserted {
            self.order.append(identifier)
        }
        if self.order.count > 4096 {
            let count = self.order.count - 4096
            for identifier in self.order.prefix(count) { self.seen.remove(identifier) }
            self.order.removeFirst(count)
        }
        guard !fresh.isEmpty, let startedAt = self.startedAt else { return false }
        let age = Double(Int64(serverNow) - Int64(timestamp))
        return age >= -30.0 && age <= max(0.0, now - startedAt) + 2.0
    }

    func allows(generation: Int) -> Bool {
        return self.startedAt != nil && self.generation == generation
    }
}

private func arielgramNotificationIdentifier(accountId: Int64, peerId: Int64, namespace: Int32, messageId: Int32) -> String {
    // The m... prefix is understood by the existing read/delete cleanup.
    return "m\(peerId):\(namespace):\(messageId)_arielgram_\(accountId)"
}

private func arielgramNotificationPreview(_ text: String, spoilers: [NSRange]) -> String {
    let result = NSMutableString(string: text)
    var merged: [NSRange] = []
    for range in spoilers.sorted(by: { $0.location < $1.location }) where range.location >= 0 && range.length > 0 && range.location < result.length {
        let range = NSRange(location: range.location, length: min(range.length, result.length - range.location))
        if let previous = merged.last, NSMaxRange(previous) >= range.location {
            merged[merged.count - 1] = NSUnionRange(previous, range)
        } else {
            merged.append(range)
        }
    }
    for range in merged.reversed() {
        result.replaceCharacters(in: range, with: "••••")
    }
    return String((result as String).prefix(512))
}

private final class ArielgramLocalMessageNotifications {
    private let application: UIApplication
    private let sharedContext: SharedAccountContext
    private let center = UNUserNotificationCenter.current()
    private var gate = ArielgramLocalNotificationGate()
    private var observers: [NSObjectProtocol] = []
    private let accountsDisposable = MetaDisposable()
    private let settingsDisposable = MetaDisposable()
    private var accountDisposables: [AccountRecordId: DisposableSet] = [:]
    private var accounts: [AccountRecordId: Account] = [:]
    private var primaryId: AccountRecordId?
    private var soundLists: [AccountRecordId: NotificationSoundList] = [:]
    private var settings = InAppNotificationSettings.defaultSettings
    private var passcodeEnabled = true
    private var authorizationRequested = false

    init(application: UIApplication, sharedContext: SharedAccountContext, accounts: Signal<[(Account, Bool)], NoError>) {
        self.application = application
        self.sharedContext = sharedContext
        self.settingsDisposable.set((combineLatest(
            sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings]),
            sharedContext.accountManager.accessChallengeData()
        ) |> deliverOnMainQueue).start(next: { [weak self] data, challenge in
            self?.settings = data.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) ?? .defaultSettings
            self?.passcodeEnabled = challenge.data.isLockable
        }))
        for name in [SGSimpleSettings.arielgramBackgroundMonitoringChanged, UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateEligibility()
            })
        }
        self.updateEligibility()
        self.accountsDisposable.set((accounts |> deliverOnMainQueue).start(next: { [weak self] accounts in
            guard let self else { return }
            self.primaryId = accounts.first(where: { $0.1 })?.0.id
            let ids = Set(accounts.map { $0.0.id })
            for id in Array(self.accountDisposables.keys) where !ids.contains(id) {
                self.accountDisposables.removeValue(forKey: id)?.dispose()
                self.accounts.removeValue(forKey: id)
                self.soundLists.removeValue(forKey: id)
            }
            for (account, _) in accounts where self.accountDisposables[account.id] == nil {
                self.accounts[account.id] = account
                let disposable = DisposableSet()
                self.accountDisposables[account.id] = disposable
                disposable.add((TelegramEngine(account: account).peers.notificationSoundList() |> deliverOnMainQueue).start(next: { [weak self] list in
                    self?.soundLists[account.id] = list
                }))
                disposable.add((account.stateManager.notificationMessages |> deliverOnMainQueue).start(next: { [weak self] list in
                    self?.receive(account: account, list: list)
                }))
            }
        }))
    }

    deinit {
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }
        self.accountsDisposable.dispose()
        self.settingsDisposable.dispose()
        self.accountDisposables.values.forEach { $0.dispose() }
    }

    private func updateEligibility() {
        let enabled = SGSimpleSettings.shared.arielgramBackgroundMonitoring
        self.gate.update(enabled: enabled, background: self.application.applicationState == .background, now: ProcessInfo.processInfo.systemUptime)
        // Authorization is local too. Do not register a remote token or ask the
        // system to show an authorization prompt from the background.
        if enabled, self.application.applicationState == .active, !self.authorizationRequested {
            self.authorizationRequested = true
            self.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                if let error { Logger.shared.log("LocalNotifications", "Authorization failed: \(error)") }
            }
        }
    }

    private func receive(account: Account, list: [([Message], PeerGroupId, Bool, MessageHistoryThreadData?)]) {
        self.updateEligibility()
        let generation = self.gate.generation
        let now = ProcessInfo.processInfo.systemUptime
        let serverNow = account.network.getApproximateRemoteTimestamp()
        var messageIds: [MessageId] = []
        for (messages, _, notify, _) in list {
            let incoming = messages.filter { message in
                return message.flags.contains(.Incoming) && message.author?.id != account.peerId
                    && (message.id.namespace == Namespaces.Message.Cloud || message.id.namespace == Namespaces.Message.SecretIncoming)
                    && !(message.forwardInfo?.flags.contains(.isImported) ?? false)
            }
            guard let message = incoming.min(by: { $0.index < $1.index }) else { continue }
            let identifiers = incoming.map { arielgramNotificationIdentifier(accountId: account.id.int64, peerId: $0.id.peerId.toInt64(), namespace: $0.id.namespace, messageId: $0.id.id) }
            let fresh = self.gate.consume(identifiers: identifiers, timestamp: incoming.map(\.timestamp).max() ?? message.timestamp, serverNow: serverNow, now: now)
            if fresh && notify && (self.primaryId == account.id || self.settings.displayNotificationsFromAllAccounts) {
                messageIds.append(message.id)
            }
        }
        guard !messageIds.isEmpty, self.accountDisposables[account.id] != nil else { return }
        let _ = (account.postbox.transaction { transaction -> [([Message], PeerMessageSound, Bool, MessageHistoryThreadData?, ContentSettings)] in
            let contentSettings = getContentSettings(transaction: transaction)
            return messageIds.compactMap { id in
                guard transaction.getPeerChatListIndex(id.peerId) != nil else { return nil }
                let result = messagesForNotification(transaction: transaction, id: id, alwaysReturnMessage: false)
                guard result.notify, !result.messages.isEmpty else { return nil }
                return (result.messages, result.sound, result.displayContents, result.threadData, contentSettings)
            }
        } |> deliverOnMainQueue).startStandalone(next: { [weak self] payloads in
            guard let self, self.gate.allows(generation: generation), self.accounts[account.id] === account,
                  self.application.applicationState == .background, SGSimpleSettings.shared.arielgramBackgroundMonitoring else { return }
            for (messages, sound, previews, threadData, contentSettings) in payloads {
                self.deliver(account: account, messages: messages, sound: sound, previews: previews, threadData: threadData, contentSettings: contentSettings)
            }
        })
    }

    private func deliver(account: Account, messages: [Message], sound: PeerMessageSound, previews: Bool, threadData: MessageHistoryThreadData?, contentSettings: ContentSettings) {
        guard self.primaryId == account.id || self.settings.displayNotificationsFromAllAccounts,
              let message = messages.min(by: { $0.index < $1.index }), let peer = message.peers[message.id.peerId] else { return }
        let presentation = self.sharedContext.currentPresentationData.with { $0 }
        let strings = presentation.strings
        let content = UNMutableNotificationContent()
        let showNames = self.settings.displayNameOnLockscreen && !self.passcodeEnabled
        let showText = previews && self.settings.displayPreviews && showNames && message.id.peerId.namespace != Namespaces.Peer.SecretChat
        content.title = showNames ? EnginePeer(peer).displayTitle(strings: strings, displayOrder: presentation.nameDisplayOrder) : "Arielgram"
        if showNames, let threadData { content.subtitle = threadData.info.title }
        content.body = strings.Watch_MessageView_Title
        if showText {
            let description = descriptionStringForMessage(contentSettings: contentSettings, message: EngineMessage(message), strings: strings, nameDisplayOrder: presentation.nameDisplayOrder, dateTimeFormat: presentation.dateTimeFormat, accountPeerId: account.peerId)
            var spoilers: [NSRange] = []
            if description.2, let entities = message.textEntitiesAttribute?.entities {
                spoilers = entities.compactMap { entity in
                    if case .Spoiler = entity.type { return NSRange(location: entity.range.lowerBound, length: entity.range.count) }
                    return nil
                }
            }
            // Raw entity offsets apply before folding line breaks.
            let text = description.2 ? arielgramNotificationPreview(message.text, spoilers: spoilers) : description.0.string
            content.body = foldLineBreaks(text)
            if let author = message.author, author.id != peer.id, !(peer is TelegramUser) {
                content.body = EnginePeer(author).displayTitle(strings: strings, displayOrder: presentation.nameDisplayOrder) + ": " + content.body
            }
            if messages.count > 1 { content.body += " (\(messages.count))" }
        }
        content.sound = self.notificationSound(account: account, sound: sound)
        content.categoryIdentifier = "unknown"
        content.threadIdentifier = "arielgram_\(account.id.int64)_\(message.id.peerId.toInt64())_\(message.threadId ?? 0)"
        content.userInfo = ["accountId": account.id.int64, "peerId": message.id.peerId.toInt64(), "messageId.namespace": message.id.namespace, "messageId.id": message.id.id, "arielgramLocalMessage": true]
        if let threadId = message.threadId, threadData != nil { content.userInfo["threadId"] = threadId }
        let identifier = arielgramNotificationIdentifier(accountId: account.id.int64, peerId: message.id.peerId.toInt64(), namespace: message.id.namespace, messageId: message.id.id)
        self.center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { Logger.shared.log("LocalNotifications", "Delivery failed: \(error)") }
        }
    }

    private func notificationSound(account: Account, sound: PeerMessageSound) -> UNNotificationSound? {
        switch sound {
        case .none: return nil
        case .default: return .default
        case let .bundledModern(id): return UNNotificationSound(named: UNNotificationSoundName("\(id + 100).m4a"))
        case let .bundledClassic(id): return UNNotificationSound(named: UNNotificationSoundName("\(id + 2).m4a"))
        case let .cloud(fileId):
            if let (id, category) = getCloudLegacySound(id: fileId) {
                let name = category == .modern ? id + 100 : id + 2
                return UNNotificationSound(named: UNNotificationSoundName("\(name).m4a"))
            }
            if let file = self.soundLists[account.id]?.sounds.first(where: { $0.file.fileId.id == fileId })?.file,
               let source = account.postbox.mediaBox.completedResourcePath(file.resource, pathExtension: nil) {
                do {
                    let directory = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Sounds", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let pathExtension = (file.fileName as NSString?)?.pathExtension ?? ""
                    let name = "arielgram_\(fileId)." + (pathExtension.isEmpty ? "m4a" : pathExtension)
                    let target = directory.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(atPath: source, toPath: target.path) }
                    return UNNotificationSound(named: UNNotificationSoundName(name))
                } catch { Logger.shared.log("LocalNotifications", "Sound preparation failed: \(error)") }
            }
            return .default
        }
    }
}

private final class PollStateContext {
    let subscribers = Bag<(Bool) -> Void>()
    var disposable: Disposable?
    
    deinit {
        self.disposable?.dispose()
    }
    
    var isEmpty: Bool {
        return self.disposable == nil && self.subscribers.isEmpty
    }
}

private final class NotificationInfo {
    let dict: [AnyHashable: Any]
    
    init(dict: [AnyHashable: Any]) {
        self.dict = dict
    }
}

public final class SharedNotificationManager {
    private let episodeId: UInt32
    private let application: UIApplication
    
    private let clearNotificationsManager: ClearNotificationsManager?
    private let pollLiveLocationOnce: (AccountRecordId) -> Void
    
    private var inForeground: Bool = false
    private var inForegroundDisposable: Disposable?
    
    private var accountManager: AccountManager<TelegramAccountManagerTypes>?
    private var accountsAndKeys: [(Account, Bool, MasterNotificationKey)]?
    private var accountsAndKeysDisposable: Disposable?
    
    private var notifications: [NotificationInfo] = []
    
    private var pollStateContexts: [AccountRecordId: PollStateContext] = [:]
    private var localMessageNotifications: ArielgramLocalMessageNotifications?
    
    init(episodeId: UInt32, application: UIApplication, sharedContext: SharedAccountContext, clearNotificationsManager: ClearNotificationsManager?, inForeground: Signal<Bool, NoError>, accounts: Signal<[(Account, Bool)], NoError>, pollLiveLocationOnce: @escaping (AccountRecordId) -> Void) {
        assert(Queue.mainQueue().isCurrent())
        
        self.episodeId = episodeId
        self.application = application
        self.clearNotificationsManager = clearNotificationsManager
        self.pollLiveLocationOnce = pollLiveLocationOnce
        self.localMessageNotifications = ArielgramLocalMessageNotifications(application: application, sharedContext: sharedContext, accounts: accounts)
        
        self.inForegroundDisposable = (inForeground
        |> deliverOnMainQueue).startStrict(next: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            strongSelf.inForeground = value
        })
        
        self.accountsAndKeysDisposable = (accounts
        |> mapToSignal { accounts -> Signal<[(Account, Bool, MasterNotificationKey)], NoError> in
            let signals = accounts.map { account, isCurrent -> Signal<(Account, Bool, MasterNotificationKey), NoError> in
                return masterNotificationsKey(account: account, ignoreDisabled: true)
                |> map { key -> (Account, Bool, MasterNotificationKey) in
                    return (account, isCurrent, key)
                }
            }
            return combineLatest(signals)
        }
        |> deliverOnMainQueue).startStrict(next: { [weak self] accountsAndKeys in
            guard let strongSelf = self else {
                return
            }
            let shouldProcess = strongSelf.accountsAndKeys == nil
            strongSelf.accountsAndKeys = accountsAndKeys
            if shouldProcess {
                strongSelf.process()
            }
        })
    }
    
    deinit {
        self.inForegroundDisposable?.dispose()
        self.accountsAndKeysDisposable?.dispose()
    }
    
    func isPollingState(accountId: AccountRecordId) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let context: PollStateContext
            if let current = self.pollStateContexts[accountId] {
                context = current
            } else {
                context = PollStateContext()
                self.pollStateContexts[accountId] = context
            }
            subscriber.putNext(context.disposable != nil)
            let index = context.subscribers.add({ value in
                subscriber.putNext(value)
            })
            
            return ActionDisposable { [weak context] in
                Queue.mainQueue().async {
                    if let current = self.pollStateContexts[accountId], current === context {
                        current.subscribers.remove(index)
                        if current.isEmpty {
                            self.pollStateContexts.removeValue(forKey: accountId)
                        }
                    }
                }
            }
        }
    }
    
    func beginPollingState(account: Account) {
        let accountId = account.id
        let context: PollStateContext
        if let current = self.pollStateContexts[accountId] {
            context = current
        } else {
            context = PollStateContext()
            self.pollStateContexts[accountId] = context
        }
        let previousDisposable = context.disposable
        context.disposable = (account.stateManager.pollStateUpdateCompletion()
        |> mapToSignal { messageIds -> Signal<[EngineMessage.Id], NoError> in
            return .single(messageIds)
            |> delay(1.0, queue: Queue.mainQueue())
        }
        |> deliverOnMainQueue).startStrict(next: { [weak self, weak context] _ in
            guard let strongSelf = self else {
                return
            }
            if let current = strongSelf.pollStateContexts[accountId], current === context {
                if let disposable = current.disposable {
                    disposable.dispose()
                    current.disposable = nil
                    for f in current.subscribers.copyItems() {
                        f(false)
                    }
                }
                if current.isEmpty {
                    strongSelf.pollStateContexts.removeValue(forKey: accountId)
                }
            }
        })
        previousDisposable?.dispose()
        if previousDisposable == nil {
            for f in context.subscribers.copyItems() {
                f(true)
            }
        }
    }
    
    func addNotification(_ dict: [AnyHashable: Any]) {
        self.notifications.append(NotificationInfo(dict: dict))
        
        if self.accountsAndKeys != nil {
            self.process()
        }
    }
    
    private func process() {
        guard let accountsAndKeys = self.accountsAndKeys else {
            return
        }
        var decryptedNotifications: [(Account, Bool, [AnyHashable: Any])] = []
        for notification in self.notifications {
            if let accountIdString = notification.dict["accountId"] as? String, let accountId = Int64(accountIdString) {
                inner: for (account, isCurrent, _) in accountsAndKeys {
                    if account.id.int64 == accountId {
                        decryptedNotifications.append((account, isCurrent, notification.dict))
                        break inner
                    }
                }
            } else {
                if var encryptedPayload = notification.dict["p"] as? String {
                    encryptedPayload = encryptedPayload.replacingOccurrences(of: "-", with: "+")
                    encryptedPayload = encryptedPayload.replacingOccurrences(of: "_", with: "/")
                    while encryptedPayload.count % 4 != 0 {
                        encryptedPayload.append("=")
                    }
                    if let data = Data(base64Encoded: encryptedPayload) {
                        inner: for (account, isCurrent, key) in accountsAndKeys {
                            if let decryptedData = decryptedNotificationPayload(key: key, data: data) {
                                if let decryptedDict = (try? JSONSerialization.jsonObject(with: decryptedData, options: [])) as? [AnyHashable: Any] {
                                    decryptedNotifications.append((account, isCurrent, decryptedDict))
                                }
                                break inner
                            }
                        }
                    }
                }
            }
        }
        self.notifications.removeAll()
        
        for (account, isCurrent, payload) in decryptedNotifications {
            var redactedPayload = payload
            if var aps = redactedPayload["aps"] as? [AnyHashable: Any] {
                if Logger.shared.redactSensitiveData {
                    if aps["alert"] != nil {
                        aps["alert"] = "[[redacted]]"
                    }
                    if aps["body"] != nil {
                        aps["body"] = "[[redacted]]"
                    }
                }
                redactedPayload["aps"] = aps
            }
            Logger.shared.log("Apns \(self.episodeId)", "\(redactedPayload)")
            
            let aps = payload["aps"] as? [AnyHashable: Any]
            
            var readMessageId: EngineMessage.Id?
            var isForcedLogOut = false
            var isCall = false
            var isAnnouncement = false
            var isLocationPolling = false
            var notificationRequestId: NotificationManagedNotificationRequestId?
            var shouldPollState = false
            var title: String = ""
            var body: String?
            var apnsSound: String?
            var configurationUpdate: (Int32, String, Int32, Data?)?
            var messagesDeleted: [EngineMessage.Id] = []
            if let aps = aps, let alert = aps["alert"] as? String {
                if let range = alert.range(of: ": ") {
                    title = String(alert[..<range.lowerBound])
                    body = String(alert[range.upperBound...])
                } else {
                    body = alert
                }
            } else if let aps = aps, let alert = aps["alert"] as? [AnyHashable: AnyObject] {
                if let alertBody = alert["body"] as? String {
                    body = alertBody
                    if let alertTitle = alert["title"] as? String {
                        title = alertTitle
                    }
                }
            }
            if let locKey = payload["loc-key"] as? String {
                if locKey == "SESSION_REVOKE" {
                    isForcedLogOut = true
                } else if locKey == "PHONE_CALL_REQUEST" {
                    isCall = true
                } else if locKey == "GEO_LIVE_PENDING" {
                    isLocationPolling = true
                } else if locKey == "MESSAGE_MUTED" {
                    shouldPollState = true
                } else if locKey == "MESSAGE_DELETED" {
                    var peerId: EnginePeer.Id?
                    if let fromId = payload["from_id"] {
                        let fromIdValue = fromId as! NSString
                        peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                    } else if let fromId = payload["chat_id"] {
                        let fromIdValue = fromId as! NSString
                        peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                    } else if let fromId = payload["channel_id"] {
                        let fromIdValue = fromId as! NSString
                        peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                    }
                    if let peerId = peerId {
                        if let messageIds = payload["messages"] as? String {
                            for messageId in messageIds.split(separator: ",") {
                                if let messageIdValue = Int32(messageId) {
                                    messagesDeleted.append(EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageIdValue))
                                }
                            }
                        }
                    }
                }
            }
            
            if let aps = aps, let address = aps["addr"] as? String, let datacenterId = aps["dc"] as? Int {
                var host = address
                var port: Int32 = 443
                if let range = address.range(of: ":") {
                    host = String(address[address.startIndex ..< range.lowerBound])
                    if let portValue = Int(String(address[range.upperBound...])) {
                        port = Int32(portValue)
                    }
                }
                var secret: Data?
                if let secretString = aps["sec"] as? String {
                    let data = dataWithHexString(secretString)
                    if data.count == 16 || data.count == 32 {
                        secret = data
                    }
                }
                configurationUpdate = (Int32(datacenterId), host, port, secret)
            }
            
            if let aps = aps, let sound = aps["sound"] as? String {
                apnsSound = sound
            }
            
            if payload["call_id"] != nil {
                isCall = true
            }
            
            if payload["announcement"] != nil {
                isAnnouncement = true
            }
            
            if let _ = body {
                let _ = title
                let _ = apnsSound
                
                if isAnnouncement {
                    //presentAnnouncement
                } else {
                    var peerId: EnginePeer.Id?
                    
                    shouldPollState = true
                    
                    if let fromId = payload["from_id"] {
                        let fromIdValue = fromId as! NSString
                        peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                    } else if let fromId = payload["chat_id"] {
                        let fromIdValue = fromId as! NSString
                        peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                    } else if let fromId = payload["channel_id"] {
                        let fromIdValue = fromId as! NSString
                        peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                    }
                    
                    if let msgId = payload["msg_id"] {
                        let msgIdValue = msgId as! NSString
                        if let peerId = peerId {
                            notificationRequestId = .messageId(EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(msgIdValue.intValue)))
                        }
                    } else if let randomId = payload["random_id"] {
                        let randomIdValue = randomId as! NSString
                        var peerId: EnginePeer.Id?
                        if let encryptionIdString = payload["encryption_id"] as? String, let encryptionId = Int64(encryptionIdString) {
                            peerId = EnginePeer.Id(namespace: Namespaces.Peer.SecretChat, id: EnginePeer.Id.Id._internalFromInt64Value(encryptionId))
                        }
                        notificationRequestId = .globallyUniqueId(randomIdValue.longLongValue, peerId)
                    } else {
                        shouldPollState = true
                    }
                }
            } else if let _ = payload["max_id"] {
                var peerId: EnginePeer.Id?
                
                if let fromId = payload["from_id"] {
                    let fromIdValue = fromId as! NSString
                    peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                } else if let fromId = payload["chat_id"] {
                    let fromIdValue = fromId as! NSString
                    peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                } else if let fromId = payload["channel_id"] {
                    let fromIdValue = fromId as! NSString
                    peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                }
                
                if let peerId = peerId {
                    if let msgId = payload["max_id"] {
                        let msgIdValue = msgId as! NSString
                        if msgIdValue.intValue != 0 {
                            readMessageId = EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(msgIdValue.intValue))
                        }
                    }
                }
            }
            
            if isForcedLogOut {
                self.clearNotificationsManager?.clearAll()
                
                if let accountManager = self.accountManager {
                    let _ = logoutFromAccount(id: account.id, accountManager: accountManager, alreadyLoggedOutRemotely: true).startStandalone()
                }
                return
            }
            
            if notificationRequestId != nil || shouldPollState || isCall {
                if !self.inForeground || !isCurrent {
                    self.beginPollingState(account: account)
                }
            }
            if isLocationPolling {
                if !self.inForeground || !isCurrent {
                    self.pollLiveLocationOnce(account.id)
                }
            }
            
            if let readMessageId = readMessageId {
                self.clearNotificationsManager?.append(readMessageId)
            }
            
            for messageId in messagesDeleted {
                self.clearNotificationsManager?.append(messageId)
            }
            
            if !messagesDeleted.isEmpty {
            }
            
            if readMessageId != nil || !messagesDeleted.isEmpty {
                self.clearNotificationsManager?.commitNow()
            }
            
            if let (datacenterId, host, port, secret) = configurationUpdate {
                account.network.mergeBackupDatacenterAddress(datacenterId: datacenterId, host: host, port: port, secret: secret)
            }
        }
    }
    
    private var currentNotificationCall: (peer: EnginePeer?, internalId: CallSessionInternalId)?
    private func updateNotificationCall(call: (peer: EnginePeer?, internalId: CallSessionInternalId)?, strings: PresentationStrings, nameOrder: PresentationPersonNameOrder) {
        if let previousCall = currentNotificationCall {
            if #available(iOS 10.0, *) {
                let center = UNUserNotificationCenter.current()
                center.removeDeliveredNotifications(withIdentifiers: ["call_\(previousCall.internalId)"])
            } else {
                if let notifications = self.application.scheduledLocalNotifications {
                    for notification in notifications {
                        if let userInfo = notification.userInfo, let callId = userInfo["callId"] as? String, callId == String(describing: previousCall.internalId) {
                            self.application.cancelLocalNotification(notification)
                        }
                    }
                }
            }
        }
        self.currentNotificationCall = call
        
        if let notificationCall = call {
            let rawText = strings.PUSH_PHONE_CALL_REQUEST(notificationCall.peer?.displayTitle(strings: strings, displayOrder: nameOrder) ?? "").string
            let title: String?
            let body: String
            if let index = rawText.firstIndex(of: "|") {
                title = String(rawText[rawText.startIndex ..< index])
                body = String(rawText[rawText.index(after: index)...])
            } else {
                title = nil
                body = rawText
            }
            
            if #available(iOS 10.0, *) {
                let content = UNMutableNotificationContent()
                if let title = title {
                    content.title = title
                }
                content.body = body
                content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "0.m4a"))
                content.categoryIdentifier = "incomingCall"
                content.userInfo = [:]
                
                let request = UNNotificationRequest(identifier: "call_\(notificationCall.internalId)", content: content, trigger: nil)
                
                let center = UNUserNotificationCenter.current()
                Logger.shared.log("NotificationManager", "adding call \(notificationCall.internalId)")
                center.add(request, withCompletionHandler: { error in
                    if let error = error {
                        Logger.shared.log("NotificationManager", "error adding call \(notificationCall.internalId), error: \(String(describing: error))")
                    }
                })
                
            } else {
                let notification = UILocalNotification()
                
                notification.alertTitle = title
                notification.alertBody = body
                
                notification.category = "incomingCall"
                notification.userInfo = ["callId": String(describing: notificationCall.internalId)]
                notification.soundName = "0.m4a"
                self.application.presentLocalNotificationNow(notification)
            }
        }
    }
    
    private let notificationCallStateDisposable = MetaDisposable()
    private(set) var notificationCall: PresentationCall?
    
    func setNotificationCall(_ call: PresentationCall?, strings: PresentationStrings) {
        if self.notificationCall?.internalId != call?.internalId {
            self.notificationCall = call
            if let notificationCall = self.notificationCall {
                let peer = notificationCall.peer
                let internalId = notificationCall.internalId
                let isIntegratedWithCallKit = notificationCall.isIntegratedWithCallKit
                self.notificationCallStateDisposable.set((notificationCall.state
                    |> map { state -> (EnginePeer?, CallSessionInternalId)? in
                        if isIntegratedWithCallKit {
                            return nil
                        }
                        if case .ringing = state.state {
                            return (peer, internalId)
                        } else {
                            return nil
                        }
                    }
                    |> distinctUntilChanged(isEqual: { $0?.1 == $1?.1 })).startStrict(next: { [weak self] peerAndInternalId in
                        self?.updateNotificationCall(call: peerAndInternalId, strings: strings, nameOrder: .firstLast)
                    }))
            } else {
                self.notificationCallStateDisposable.set(nil)
                self.updateNotificationCall(call: nil, strings: strings, nameOrder: .firstLast)
            }
        }
    }
}
