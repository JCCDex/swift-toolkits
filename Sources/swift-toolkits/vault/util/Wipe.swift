import Foundation

public extension Array where Element == UInt8 {
    mutating func wipe() {
        for index in indices {
            self[index] = 0
        }
    }
}

public extension Array where Element == Character {
    mutating func wipe() {
        let nul = Character(UnicodeScalar(0))
        for index in indices {
            self[index] = nul
        }
    }
}

public extension Data {
    mutating func wipe() {
        resetBytes(in: startIndex ..< endIndex)
    }
}