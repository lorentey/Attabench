//
//  BTree.swift
//  dotSwift
//
//  Copyright © 2017 Károly Lőrentey.
//

public struct BTree<Element: Comparable> {
    typealias Node = BTreeNode<Element>
    var root: Node
    var mutationCount: Int = 0

    public init() {
        self.init(order: 1023)
    }
    
    public init(order: Int) {
        self.root = Node(order: order)
    }

    mutating func makeUnique() -> Node {
        if isKnownUniquelyReferenced(&root) { return root }
        let r = root.clone()
        root = r
        return r
    }
}

class BTreeNode<Element: Comparable> {
    let order: Int
    var elementCount: Int
    var elements: UnsafeMutablePointer<Element>
    var children: ContiguousArray<BTreeNode>

    convenience init(order: Int) {
        self.init(order: order, elements: [], children: [])
    }

    init<Elements: Collection>(order: Int, elements: Elements, children: ContiguousArray<BTreeNode> = []) where Elements.Iterator.Element == Element {
        self.order = order
        self.elementCount = numericCast(elements.count)
        self.elements = .allocate(capacity: order)
        self.elements.initialize(from: elements)
        self.children = children
        self.children.reserveCapacity(order)
    }

    deinit {
        elements.deallocate(capacity: order)
    }
}

private struct Unowned<Wrapped: AnyObject> {
    unowned(unsafe) let value: Wrapped

    init(_ value: Wrapped) {
        self.value = value
    }
}

public struct BTreeIndex<Element: Comparable>: Comparable {
    typealias Node = BTreeNode<Element>

    fileprivate weak var root: Node?
    fileprivate let mutationCount: Int

    fileprivate var path: [(ref: Unowned<Node>, slot: Int)]
    fileprivate unowned var node: Node
    fileprivate var slot: Int

    init(startOf tree: BTree<Element>) {
        self.root = tree.root
        self.mutationCount = tree.mutationCount
        self.path = []
        self.node = tree.root
        self.slot = 0
        _descend()
    }

    init(endOf tree: BTree<Element>) {
        self.root = tree.root
        self.mutationCount = tree.mutationCount
        self.path = []
        self.node = tree.root
        self.slot = tree.root.elementCount
    }

    private mutating func _push(_ slot: Int) {
        let n = self.node
        path.append((Unowned(n), self.slot))
        self.node = n.children[self.slot]
        self.slot = slot
    }

    private mutating func _pop() {
        let last = self.path.removeLast()
        self.node = last.ref.value
        self.slot = last.slot
    }

    private mutating func _descend() {
        if self.node.isLeaf { return }
        _push(0)
        while !self.node.isLeaf {
            _push(0)
        }
    }

    fileprivate mutating func _advance() {
        slot += 1
        if _fastPath(node.isLeaf && slot < node.elementCount) {
            return
        }
        if slot < node.children.count {
            _descend()
            return
        }
        if node === root {
            precondition(slot <= node.elementCount, "Cannot advance beyond endIndex")
        }
        else {
            _pop()
            while node !== root, slot == node.elementCount {
                _pop()
            }
        }
    }

    public static func ==(left: BTreeIndex, right: BTreeIndex) -> Bool {
        precondition(left.root != nil && left.root === right.root && left.mutationCount == right.mutationCount)
        return left.node === right.node && left.slot == right.slot
    }

    public static func <(left: BTreeIndex, right: BTreeIndex) -> Bool {
        precondition(left.root != nil && left.root === right.root && left.mutationCount == right.mutationCount)
        var li = BTreeIndexSlotIterator<Element>(left)
        var ri = BTreeIndexSlotIterator<Element>(right)
        while true {
            switch (li.next(), ri.next()) {
            case let (.some(l), .some(r)):
                guard l == r else { return l < r }
            case (.some(_), nil):
                return true
            case (nil, .some(_)):
                return false
            case (nil, nil):
                return false
            }
        }
    }
}

private struct BTreeIndexSlotIterator<Element: Comparable>: IteratorProtocol {
    let index: BTreeIndex<Element>
    var i: Int

    init(_ index: BTreeIndex<Element>) {
        self.index = index
        self.i = 0
    }

    mutating func next() -> Int? {
        if i < index.path.count {
            let result = index.path[i].slot
            i += 1
            return result
        }
        if i == index.path.count {
            i += 1
            return index.slot
        }
        return nil
    }
}

extension BTree: Collection {
    public typealias Index = BTreeIndex<Element>

    public var startIndex: Index { return Index(startOf: self) }
    public var endIndex: Index { return Index(endOf: self) }

        func _validate(_ index: Index) {
        precondition(index.root === self.root && index.mutationCount == self.mutationCount)
    }

    public subscript(index: Index) -> Element {
                get {
            _validate(index)
            return index.node.elements[index.slot]
        }
    }

        public func formIndex(after i: inout Index) {
        _validate(i)
        i._advance()
    }

    public func index(after i: Index) -> Index {
        _validate(i)
        var i = i
        i._advance()
        return i
    }
}

extension BTree {
    public func contains(_ element: Element) -> Bool {
        return root.contains(element)
    }

    public func forEach(_ body: (Element) throws -> Void) rethrows {
        try root.forEach(body)
    }
}

extension BTreeNode {
    func contains(_ element: Element) -> Bool {
        let slot = self.slot(of: element)
        if slot.match != nil { return true }
        return children[slot.descend].contains(element)
    }

    func forEach(_ body: (Element) throws -> Void) rethrows {
        if isLeaf {
            for i in 0 ..< elementCount {
                try body(elements[i])
            }
        }
        else {
            for i in 0 ..< elementCount {
                try children[i].forEach(body)
                try body(elements[i])
            }
            try children[elementCount].forEach(body)
        }
    }
}

extension BTreeNode {

    func clone() -> BTreeNode {
        return BTreeNode(order: order,
                         elements: UnsafeBufferPointer(start: elements, count: elementCount),
                         children: children)
    }

    func makeChildUnique(_ slot: Int) -> BTreeNode {
        guard !isKnownUniquelyReferenced(&children[slot]) else { return children[slot] }
        let clone = children[slot].clone()
        children[slot] = clone
        return clone
    }

    var maxChildren: Int { return order }
    var minChildren: Int { return (maxChildren + 1) / 2 }
    var maxElements: Int { return maxChildren - 1 }
    var minElements: Int { return minChildren - 1 }

    var isLeaf: Bool { return children.isEmpty }
    var isFull: Bool { return elementCount == maxElements }
    var isTooSmall: Bool { return elementCount < minElements }
    var isTooLarge: Bool { return elementCount > maxElements }
    var isBalanced: Bool { return !isTooLarge && !isTooSmall }
}

extension BTreeNode {
    internal func slot(of element: Element) -> (match: Int?, descend: Int) {
        var start = 0
        var end = elementCount
        while start < end {
            let mid = start + (end - start) / 2
            if elements[mid] < element {
                start = mid + 1
            }
            else {
                end = mid
            }
        }
        return (start < elementCount && elements[start] == element ? start : nil, start)
    }
}

internal struct BTreeSplinter<Element: Comparable> {
    let separator: Element
    let node: BTreeNode<Element>
}

extension BTreeNode {
    typealias Splinter = BTreeSplinter<Element>

    internal convenience init(node: BTreeNode, slotRange: CountableRange<Int>) {
        if node.isLeaf {
            self.init(order: node.order,
                      elements: UnsafeBufferPointer(start: node.elements + slotRange.lowerBound, count: slotRange.count),
                      children: [])
        }
        else if slotRange.count == 0 {
            let n = node.children[slotRange.lowerBound]
            self.init(order: n.order,
                      elements: UnsafeBufferPointer(start: n.elements, count: n.elementCount),
                      children: n.children)
        }
        else {
            var children = ContiguousArray<BTreeNode>()
            children.reserveCapacity(node.order)
            children += node.children[slotRange.startIndex ... slotRange.endIndex]

            self.init(order: node.order,
                      elements: UnsafeBufferPointer(start: node.elements + slotRange.lowerBound, count: slotRange.count),
                      children: children)
        }
    }

    func split() -> Splinter {
        let count = elementCount
        let median = count / 2
        let separator = elements[median]
        let node = BTreeNode(node: self, slotRange: median + 1 ..< count)
        (elements + median).deinitialize(count: count - median)
        elementCount = median
        if !isLeaf {
            children.removeSubrange(median + 1 ..< count + 1)
        }
        return Splinter(separator: separator, node: node)
    }

    func _insertElement(_ element: Element, at index: Int) {
        assert(index >= 0 && index <= elementCount)
        (elements + index + 1).moveInitialize(from: elements + index, count: elementCount - index)
        (elements + index).initialize(to: element)
        elementCount += 1
    }

    func insert(_ element: Element) -> (old: Element?, splinter: Splinter?) {
        let slot = self.slot(of: element)
        if let m = slot.match {
            // We found the element.
            return (self.elements[m], nil)
        }
        if self.isLeaf {
            _insertElement(element, at: slot.descend)
            return (nil, self.isTooLarge ? self.split() : nil)
        }
        let (old, splinter) = makeChildUnique(slot.descend).insert(element)
        guard let s = splinter else { return (old, nil) }
        _insertElement(s.separator, at: slot.descend)
        self.children.insert(s.node, at: slot.descend + 1)
        return (old, self.isTooLarge ? self.split() : nil)
    }
}

extension BTree {

    @discardableResult
    public mutating func insert(_ element: Element) -> (inserted: Bool, memberAfterInsert: Element) {
        let root = makeUnique()
        let (old, splinter) = root.insert(element)
        if let s = splinter {
            self.root = Node(order: root.order, elements: [s.separator], children: [root, s.node])
        }
        return (inserted: old == nil, memberAfterInsert: old ?? element)
    }
}

extension BTree {
    public func validate() {
        _ = root.validate(level: 0)
    }
}

extension BTreeNode {
    func validate(level: Int, min: Element? = nil, max: Element? = nil) -> Int {
        // Check balance.
        precondition(!isTooLarge)
        precondition(level == 0 || !isTooSmall)

        if elementCount == 0 {
            precondition(children.isEmpty)
            return 0
        }

        // Check element ordering.
        var previous = min
        for i in 0 ..< elementCount {
            let next = elements[i]
            precondition(previous == nil || previous! < next)
            previous = next
        }

        if isLeaf {
            return 0
        }

        // Check children.
        precondition(children.count == elementCount + 1)
        let depth = children[0].validate(level: level + 1, min: min, max: elements[0])
        for i in 1 ..< elementCount {
            let d = children[i].validate(level: level + 1, min: elements[i - 1], max: elements[i])
            precondition(depth == d)
        }
        let d = children[elementCount].validate(level: level + 1, min: elements[elementCount - 1], max: max)
        precondition(depth == d)
        return depth + 1
    }
}
