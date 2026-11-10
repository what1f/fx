/// Internal protocol observation for the cross-language conformance runner.
/// Applications should consume typed engine events instead.
@_spi(Conformance) public enum FxWireDirection: Sendable {
    case sent, received
}
