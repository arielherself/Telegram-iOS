import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ContactsPeerItem
import ItemListPeerItem
import PresentationDataUtils

private final class WatchlistArguments {
    let context: AccountContext
    let open: (EnginePeer) -> Void

    init(context: AccountContext, open: @escaping (EnginePeer) -> Void) {
        self.context = context
        self.open = open
    }
}

private enum WatchlistEntryId: Hashable {
    case empty
    case peer(EnginePeer.Id)
}

private enum WatchlistEntry: ItemListNodeEntry {
    case empty(String)
    case peer(Int, EnginePeer)

    var section: ItemListSectionId { return 0 }
    var stableId: WatchlistEntryId {
        switch self {
        case .empty: return .empty
        case let .peer(_, peer): return .peer(peer.id)
        }
    }

    static func <(lhs: WatchlistEntry, rhs: WatchlistEntry) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .peer): return true
        case let (.peer(lhsIndex, _), .peer(rhsIndex, _)): return lhsIndex < rhsIndex
        default: return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WatchlistArguments
        switch self {
        case let .empty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: 0)
        case let .peer(_, peer):
            return ContactsPeerItem(
                presentationData: presentationData, style: .plain, systemStyle: .glass,
                sectionId: 0, sortOrder: .firstLast, displayOrder: .firstLast,
                context: arguments.context, peerMode: .peer,
                peer: .peer(peer: peer, chatPeer: peer), status: .none, enabled: true,
                selection: .none, editing: ContactsPeerItemEditing(editable: false, editing: false, revealed: false),
                options: [ItemListPeerItemRevealOption(type: .destructive, title: "Unwatch", action: {
                    let _ = arielgramSetPeerWatched(account: arguments.context.account, peerId: peer.id, watched: false).startStandalone()
                })], index: nil, header: nil, action: { _ in arguments.open(peer) }
            )
        }
    }
}

func arielgramWatchlistController(context: AccountContext) -> ViewController {
    var openImpl: ((EnginePeer) -> Void)?
    let arguments = WatchlistArguments(context: context, open: { peer in openImpl?(peer) })
    let icon = UIImage(systemName: "bookmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 25.0, weight: .regular))
    let selectedIcon = UIImage(systemName: "bookmark.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 25.0, weight: .regular))
    let tab = ItemListControllerTabBarItem(title: "Watchlist", image: icon, selectedImage: selectedIcon)

    // Only local preferences and basic peer views: no history, unread counts,
    // peerView refreshes, or history preloading for the rows on this page.
    let state = combineLatest(context.sharedContext.presentationData, arielgramWatchlistPeers(account: context.account))
    |> map { data, peers -> (ItemListControllerState, (ItemListNodeState, WatchlistArguments)) in
        let entries: [WatchlistEntry]
        if peers.isEmpty {
            let text = data.strings.baseLanguageCode.lowercased().hasPrefix("zh")
                ? "在公开群或频道的预览页点击 Watch，即可在这里查看，无需加入。"
                : "Tap Watch in a public group or channel preview to add it here without joining."
            entries = [.empty(text)]
        } else {
            entries = peers.enumerated().map { .peer($0.offset, $0.element) }
        }
        let controller = ItemListControllerState(presentationData: ItemListPresentationData(data), title: .text("Watchlist"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back), tabBarItem: tab)
        let list = ItemListNodeState(presentationData: ItemListPresentationData(data), entries: entries, style: .plain, animateChanges: true)
        return (controller, (list, arguments))
    }
    let controller = ItemListController(context: context, state: state, tabBarItem: .single(tab))
    openImpl = { [weak controller] peer in
        guard let navigationController = controller?.navigationController as? NavigationController else { return }
        context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
    }
    return controller
}
