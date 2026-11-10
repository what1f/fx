func validInputID(_ value: String) -> Bool {
    let bytes = value.utf8
    return (1...128).contains(bytes.count) && bytes.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
    }
}
