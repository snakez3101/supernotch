// On Apple platforms the geometry members of CGRect/CGPoint/CGSize (minY, width, insetBy, contains, …)
// and their Equatable conformances live in the CoreGraphics overlay; Foundation alone does not provide
// them. swift-corelibs-foundation on Linux defines them itself, so the import is Apple-only.
// Re-exported so every Core file (and the tests) sees the same API on both platforms.
#if canImport(CoreGraphics)
    @_exported import CoreGraphics
#endif
