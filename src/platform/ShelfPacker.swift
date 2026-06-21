import Foundation

// A placed rectangle in top-left atlas pixel space: (x, y) is the top-left
// corner, (width, height) the extent. This is the SAME coordinate space the
// rasterizer's mask is produced in and that texture.replace uploads into, so a
// placement maps one-to-one to a texture region with no orientation conversion.
struct PackedRectangle: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

// Pure-geometry shelf bin-packer: no Core Text, no Metal. It fills a fixed
// square of `size` pixels with axis-aligned rectangles laid out in horizontal
// shelves. Each shelf is a band whose height equals its tallest rectangle;
// rectangles fill a shelf left-to-right until the next would overflow the width,
// at which point a new shelf opens above the previous one. A rectangle that
// would overflow the atlas height returns nil so the caller can grow and retry.
// Placements never overlap: each consumes a disjoint [x, x+width) span within a
// disjoint [shelfTop, shelfTop+shelfHeight) band.
final class ShelfPacker {
    private struct Shelf {
        let top: Int
        let height: Int
        var nextX: Int
    }

    private(set) var size: Int
    private var shelves: [Shelf]
    private var usedHeight: Int

    var shelfCount: Int { shelves.count }

    init(size: Int) {
        precondition(size > 0, "ShelfPacker size must be positive, got \(size)")
        self.size = size
        self.shelves = []
        self.usedHeight = 0
    }

    // Drops every shelf and resets the cursor to an empty atlas of `newSize`.
    // Used by Atlas.grow() to re-pack all live entries into the larger texture.
    func reset(size newSize: Int) {
        precondition(newSize > 0, "ShelfPacker size must be positive, got \(newSize)")
        self.size = newSize
        self.shelves = []
        self.usedHeight = 0
    }

    // Places a maskWidth x maskHeight rectangle and returns its top-left
    // position, or nil if it does not fit in the current atlas size. A rectangle
    // wider or taller than the whole atlas can never fit and returns nil.
    func place(maskWidth: Int, maskHeight: Int) -> PackedRectangle? {
        precondition(maskWidth > 0 && maskHeight > 0, "mask must be non-empty, got \(maskWidth)x\(maskHeight)")
        if maskWidth > size || maskHeight > size {
            return nil
        }
        if let onExisting = placeOnExistingShelf(maskWidth: maskWidth, maskHeight: maskHeight) {
            return onExisting
        }
        return placeOnNewShelf(maskWidth: maskWidth, maskHeight: maskHeight)
    }

    private func placeOnExistingShelf(maskWidth: Int, maskHeight: Int) -> PackedRectangle? {
        for index in shelves.indices {
            let shelf = shelves[index]
            let fitsWidth = shelf.nextX + maskWidth <= size
            let fitsHeight = maskHeight <= shelf.height
            if fitsWidth && fitsHeight {
                let rectangle = PackedRectangle(
                    x: shelf.nextX,
                    y: shelf.top,
                    width: maskWidth,
                    height: maskHeight
                )
                shelves[index].nextX += maskWidth
                return rectangle
            }
        }
        return nil
    }

    private func placeOnNewShelf(maskWidth: Int, maskHeight: Int) -> PackedRectangle? {
        if usedHeight + maskHeight > size {
            return nil
        }
        let rectangle = PackedRectangle(
            x: 0,
            y: usedHeight,
            width: maskWidth,
            height: maskHeight
        )
        shelves.append(Shelf(top: usedHeight, height: maskHeight, nextX: maskWidth))
        usedHeight += maskHeight
        return rectangle
    }
}
