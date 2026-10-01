import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import Display
import AsyncDisplayKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatControllerInteraction
import ChatMessageItemView
import WallpaperBackgroundNode

private func arielgramHistoryMessages(_ message: Message) -> [Message] {
    let versions = (message.arielgramHistory?.versions ?? []) + [ArielgramMessageVersion(message: message)]
    return versions.enumerated().map { index, version in
        let previous = index == 0 ? nil : versions[index - 1]
        let mediaEdited = previous.map { old in
            !arielgramMediaContentEqual(old.media, version.media) || (old.timestamp != version.timestamp && old.media.count == version.media.count && zip(old.media, version.media).contains { !$0.0.isEqual(to: $0.1) })
        } == true
        var attributes = version.attributes.filter { !($0 is ArielgramMessageHistoryAttribute) && !($0 is TranslationMessageAttribute) }
        attributes.append(ArielgramHistoryDisplayAttribute(sourceMessageId: message.id, previousText: previous?.text, previousEntities: previous?.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities ?? [], mediaEdited: mediaEdited))
        if index == versions.count - 1, let deletedAt = message.arielgramHistory?.deletedAt {
            attributes.append(ArielgramMessageHistoryAttribute(versions: [], deletedAt: deletedAt))
        }
        return Message(
            stableId: UInt32(index + 1), stableVersion: message.stableVersion,
            id: MessageId(peerId: message.id.peerId, namespace: Namespaces.Message.Local, id: Int32(index + 1)),
            globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: message.threadId,
            timestamp: version.timestamp, flags: message.flags, tags: [], globalTags: [], localTags: [], customTags: [],
            forwardInfo: message.forwardInfo, author: message.author, text: version.text, attributes: attributes,
            // Each row displays this version's complete media, with a badge
            // when it changed. Do not append the preceding version's media.
            media: version.media,
            peers: message.peers, associatedMessages: message.associatedMessages,
            associatedMessageIds: message.associatedMessageIds, associatedMedia: message.associatedMedia,
            associatedThreadInfo: message.associatedThreadInfo, associatedStories: message.associatedStories
        )
    }
}

final class ArielgramMessageHistoryController: ViewController {
    private let context: AccountContext
    private let message: Message
    private var interaction: ChatControllerInteraction!
    private var historyNode: ChatHistoryListNodeImpl?
    private var wallpaperNode: WallpaperBackgroundNode?
    private var presentationData: PresentationData
    private var presentationDisposable: Disposable?

    init(context: AccountContext, message: Message, interaction: ChatControllerInteraction) {
        self.context = context
        self.message = message
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationTheme: self.presentationData.theme, presentationStrings: self.presentationData.strings))
        self.interaction = arielgramHistoryInteraction(interaction, context: context, openMessage: { [weak self] message, params in
            guard let self else { return false }
            return self.openHistoryMessage(message, params: params)
        })
        self.title = "History"
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDisposable?.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        let wallpaper = createWallpaperBackgroundNode(context: self.context, forChatDisplay: true, useSharedAnimationPhase: false)
        wallpaper.update(wallpaper: self.presentationData.chatWallpaper, animated: false)
        self.wallpaperNode = wallpaper
        self.displayNode.addSubnode(wallpaper)
        self.interaction.presentationContext.backgroundNode = wallpaper

        let messages = self.context.account.postbox.messageView(self.message.id)
        |> map { [message = self.message] view -> ([Message], Int32, Bool) in
            let messages = arielgramHistoryMessages(view.message ?? message)
            return (Array(messages.reversed()), Int32(messages.count), false)
        }
        let history = ChatHistoryListNodeImpl(
            context: self.context,
            updatedPresentationData: (self.presentationData, self.context.sharedContext.presentationData),
            chatLocation: .customChatContents,
            chatLocationContextHolder: Atomic<ChatLocationContextHolder?>(value: nil),
            adMessagesContext: nil, tag: nil,
            source: .custom(messages: messages, messageId: nil, quote: nil, isSavedMusic: false, canReorder: false, loadMore: nil),
            subject: nil, controllerInteraction: self.interaction,
            selectedMessages: .single(nil), reverseMessageOrder: true, rotated: false, isChatPreview: false,
            messageTransitionNode: { nil }
        )
        self.historyNode = history
        self.displayNode.addSubnode(history)
        self.presentationDisposable = (self.context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.presentationData = data
            self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationTheme: data.theme, presentationStrings: data.strings), transition: .immediate)
            self.wallpaperNode?.update(wallpaper: data.chatWallpaper, animated: false)
        })
        self.displayNodeDidLoad()
    }


    private func openHistoryMessage(_ message: Message, params: OpenMessageParams) -> Bool {
        return self.context.sharedContext.openChatMessage(OpenChatMessageParams(
            context: self.context,
            updatedPresentationData: (self.presentationData, self.context.sharedContext.presentationData),
            chatLocation: nil, chatFilterTag: nil, chatLocationContextHolder: nil,
            message: message, mediaSubject: params.mediaSubject, standalone: true,
            copyProtected: message.isCopyProtected(),
            reverseMessageGalleryOrder: false, mode: params.mode,
            navigationController: self.interaction.navigationController(),
            dismissInput: {},
            present: { [weak self] controller, arguments, _ in
                self?.present(controller, in: .window(.root), with: arguments)
            },
            transitionNode: { [weak self] messageId, media, adjustRect in
                var result: (ASDisplayNode, CGRect, () -> (UIView?, UIView?))?
                self?.historyNode?.forEachItemNode { node in
                    if let node = node as? ChatMessageItemView, let transition = node.transitionNode(id: messageId, media: media, adjustRect: adjustRect) {
                        result = transition
                    }
                }
                return result
            },
            addToTransitionSurface: { [weak self] view in self?.displayNode.view.addSubview(view) },
            openUrl: { [weak self] url in
                self?.interaction.openUrl(.init(url: url, concealed: false, progress: Promise()))
            },
            openPeer: { [weak self] peer, navigation in self?.interaction.openPeer(EnginePeer(peer), navigation, nil, .default) },
            callPeer: { _, _ in }, openConferenceCall: { _ in }, enqueueMessage: { _ in },
            sendSticker: nil, sendEmoji: nil,
            setupTemporaryHiddenMedia: { _, _, _ in }, chatAvatarHiddenMedia: { _, _ in },
            gallerySource: .standaloneMessage(message, params.mediaSubject)
        ))
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.wallpaperNode?.frame = CGRect(origin: .zero, size: layout.size)
        self.wallpaperNode?.updateLayout(size: layout.size, displayMode: .aspectFill, transition: transition)
        self.historyNode?.frame = CGRect(origin: .zero, size: layout.size)
        var insets = layout.insets(options: [])
        insets.top = navigationHeight
        insets.bottom += 8.0
        self.historyNode?.updateLayout(transition: transition, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, scrollIndicatorInsets: insets, duration: 0.0, curve: .Default(duration: nil), ensureTopInsetForOverlayHighlightedItems: nil, customAnimationTransition: nil))
    }
}
