import Foundation

/// A playlist shown as the folders its files are in: parents above children, each folder open or closed. Only the arrangement is
/// worked out here; nothing on the disk is read or changed, and the order files are played in stays the playlist's.
public enum FolderTree {
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case folder, file }
        public var id: String
        public var kind: Kind
        /// 0 for a top folder; a folder's contents are one deeper than the folder.
        public var depth: Int
        /// A folder's name (a folder that only holds one folder is joined with it: "2024/Trip"), or a file's title.
        public var title: String
        /// The folder's path, or the file's.
        public var path: String
        /// A file row: the playlist entry it stands for.
        public var itemID: UUID?
        /// A folder row: every file inside it, in the order the tree shows them, whether or not the folder is open.
        public var itemIDs: [UUID]
        public var isExpanded: Bool
        /// A folder row: how many folders are directly inside it.
        public var subfolderCount: Int

        public var fileCount: Int { itemIDs.count }
    }

    /// Compares two folders' paths one name at a time ("Trip 2" before "Trip 10"). A folder comes after the folders inside it,
    /// which is where the tree shows them (subfolders first).
    public static func compareFolders(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(a), y = components(b)
        for (p, q) in zip(x, y) {
            let r = NaturalSort.compare(p, q)
            if r != .orderedSame { return r }
        }
        if x.count == y.count { return .orderedSame }
        return x.count > y.count ? .orderedAscending : .orderedDescending
    }

    static func components(_ path: String) -> [String] {
        ((path as NSString).standardizingPath as NSString).pathComponents.filter { $0 != "/" }
    }

    private final class Node {
        let name: String
        let path: String
        var folders: [String: Node] = [:]
        var files: [PlaylistItem] = []
        var firstIndex = Int.max
        init(name: String, path: String) { self.name = name; self.path = path }
    }

    /// The rows to show, top to bottom. `collapsed` holds the paths of the folders that are closed (a closed folder keeps its row and
    /// hides what is inside). `expandAll` opens everything (a search shows every match, whatever was closed).
    public static func rows(for items: [PlaylistItem], order: PlaylistOrder, collapsed: Set<String> = [], expandAll: Bool = false) -> [Row] {
        let root = Node(name: "/", path: "/")
        // Many files share a folder: its names are worked out once (standardising a path is not free).
        var known: [String: [String]] = [:]
        for (index, item) in items.enumerated() {
            var node = root
            var path = ""
            let dir = PathUtil.directory(of: item.path)
            let names = known[dir] ?? { let c = components(dir); known[dir] = c; return c }()
            for name in names {
                path += "/" + name
                if let next = node.folders[name] { node = next }
                else { let next = Node(name: name, path: path); node.folders[name] = next; node = next }
                node.firstIndex = min(node.firstIndex, index)
            }
            node.files.append(item)
        }
        var builder = Builder(order: order, collapsed: collapsed, expandAll: expandAll)
        // Files straight in "/" are not a real case; anything else starts at the folders below the root.
        for sub in builder.sortedFolders(of: root) {
            let (node, title) = builder.compact(sub, topLevel: true)
            builder.emit(node, title: title, depth: 0, visible: true)
        }
        return builder.rows
    }

    private struct Builder {
        let order: PlaylistOrder
        let collapsed: Set<String>
        let expandAll: Bool
        var rows: [Row] = []

        init(order: PlaylistOrder, collapsed: Set<String>, expandAll: Bool) { self.order = order; self.collapsed = collapsed; self.expandAll = expandAll }

        var byFolder: Bool { order.key == .folder }
        /// Folders Z to A also put a folder's files above its subfolders: the whole order is turned round.
        var subfoldersFirst: Bool { !(byFolder && order.descending) }

        func sortedFolders(of node: Node) -> [Node] {
            let all = Array(node.folders.values)
            if order.key == .manual { return all.sorted { $0.firstIndex < $1.firstIndex } }
            return all.sorted {
                let r = NaturalSort.compare($0.name, $1.name)
                return (byFolder && order.descending) ? r == .orderedDescending : r == .orderedAscending
            }
        }

        /// A folder with nothing but one folder inside shows as one row. A top folder keeps only its own name (the path is its tooltip).
        func compact(_ start: Node, topLevel: Bool) -> (Node, String) {
            var node = start
            var title = start.name
            while node.files.isEmpty, node.folders.count == 1, let child = node.folders.values.first {
                title = topLevel ? child.name : title + "/" + child.name
                node = child
            }
            return (node, title)
        }

        @discardableResult
        mutating func emit(_ node: Node, title: String, depth: Int, visible: Bool) -> [UUID] {
            let index = rows.count
            let isClosed = !expandAll && collapsed.contains(node.path)
            if visible { rows.append(Row(id: "d:" + node.path, kind: .folder, depth: depth, title: title, path: node.path, itemID: nil, itemIDs: [], isExpanded: !isClosed, subfolderCount: node.folders.count)) }
            let showChildren = visible && !isClosed
            var ids: [UUID] = []
            func folders(_ b: inout Builder) {
                for sub in b.sortedFolders(of: node) {
                    let (child, childTitle) = b.compact(sub, topLevel: false)
                    ids += b.emit(child, title: childTitle, depth: depth + 1, visible: showChildren)
                }
            }
            func files(_ b: inout Builder) {
                for item in node.files {
                    ids.append(item.id)
                    if showChildren { b.rows.append(Row(id: "f:" + item.id.uuidString, kind: .file, depth: depth + 1, title: item.title, path: item.path, itemID: item.id, itemIDs: [item.id], isExpanded: false, subfolderCount: 0)) }
                }
            }
            if subfoldersFirst { folders(&self); files(&self) } else { files(&self); folders(&self) }
            if visible { rows[index].itemIDs = ids }
            return ids
        }
    }

    /// The paths of all the folders that have a row (open or not), for "close all" and "open all".
    public static func folderPaths(for items: [PlaylistItem], order: PlaylistOrder) -> [String] {
        rows(for: items, order: order, expandAll: true).filter { $0.kind == .folder }.map(\.path)
    }
}
