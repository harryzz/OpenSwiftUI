//
//  StrongHash.swift
//  OpenSwiftUICore
//
//  Audited for 6.0.87
//  Status: Blocked by OAGTypeGetSignature

#if OPENSWIFTUI_SWIFT_CRYPTO
import Crypto
#elseif canImport(CommonCrypto)
import CommonCrypto
#endif

import Foundation
import OpenAttributeGraphShims
import OpenRenderBoxShims

package protocol StronglyHashable {
  func hash(into hasher: inout StrongHasher)
}

package struct StrongHash: Hashable, StronglyHashableByBitPattern, Codable, CustomStringConvertible {
    package var words: (UInt32, UInt32, UInt32, UInt32, UInt32)
    package init() {
        words = (.zero, .zero, .zero, .zero, .zero)
    }
    
    package init<T>(of value: T) where T: StronglyHashable {
        var hasher = StrongHasher()
        value.hash(into: &hasher)
        self = hasher.finalize()
    }
    
    package init<T>(encodable value: T) throws where T: Encodable {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        var hasher = StrongHasher()
        data.hash(into: &hasher)
        self = hasher.finalize()
    }
    
    package static func random() -> StrongHash {
        StrongHash(of: UUID())
    }
    
    package static func == (lhs: StrongHash, rhs: StrongHash) -> Bool {
        lhs.words.0 == rhs.words.0 &&
        lhs.words.1 == rhs.words.1 &&
        lhs.words.2 == rhs.words.2 &&
        lhs.words.3 == rhs.words.3 &&
        lhs.words.4 == rhs.words.4
    }
    
    package func hash(into hasher: inout Hasher) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 5) { pointer in
            pointer.initializeElement(at: 0, to: words.0)
            pointer.initializeElement(at: 1, to: words.1)
            pointer.initializeElement(at: 2, to: words.2)
            pointer.initializeElement(at: 3, to: words.3)
            pointer.initializeElement(at: 4, to: words.4)
            hasher.combine(bytes: UnsafeRawBufferPointer(pointer))
        }
    }
    
    package var description: String {
        String(format: "#%08x%08x%08x%08x%08x", words.4, words.3, words.2, words.1, words.0)
    }
    
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(words.0)
        try container.encode(words.1)
        try container.encode(words.2)
        try container.encode(words.3)
        try container.encode(words.4)
    }
    
    package init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        words.0 = try container.decode(UInt32.self)
        words.1 = try container.decode(UInt32.self)
        words.2 = try container.decode(UInt32.self)
        words.3 = try container.decode(UInt32.self)
        words.4 = try container.decode(UInt32.self)
    }
}

#if !OPENSWIFTUI_SWIFT_CRYPTO && !canImport(CommonCrypto)
// Pure-Swift SHA-1 — a faithful port of `repros/compute-wasm/shims/openssl/sha.h`. Used off-Apple
// (e.g. wasm32-wasip1) so that StrongHash — OpenSwiftUI's ONLY use of crypto — no longer needs
// swift-crypto, which statically links all of BoringSSL (the AOT-footprint bloat). Produces the
// same 20-byte big-endian digest as the Crypto/CommonCrypto paths, so StrongHash values are
// backend-independent.
struct _OpenSwiftUIInsecureSHA1 {
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32) =
        (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
    private var len: UInt64 = 0
    private var buf = [UInt8](repeating: 0, count: 64)
    private var blen: Int = 0

    @inline(__always)
    private static func rol(_ v: UInt32, _ b: UInt32) -> UInt32 { (v << b) | (v >> (32 &- b)) }

    private mutating func processBlock(_ p: UnsafePointer<UInt8>) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0 ..< 16 {
            w[i] = (UInt32(p[i &* 4]) << 24) | (UInt32(p[i &* 4 &+ 1]) << 16)
                 | (UInt32(p[i &* 4 &+ 2]) << 8) | UInt32(p[i &* 4 &+ 3])
        }
        for i in 16 ..< 80 { w[i] = Self.rol(w[i &- 3] ^ w[i &- 8] ^ w[i &- 14] ^ w[i &- 16], 1) }
        var a = h.0, b = h.1, c = h.2, d = h.3, e = h.4
        for i in 0 ..< 80 {
            let f: UInt32, k: UInt32
            switch i {
            case 0 ..< 20:  f = (b & c) | (~b & d);          k = 0x5A82_7999
            case 20 ..< 40: f = b ^ c ^ d;                   k = 0x6ED9_EBA1
            case 40 ..< 60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
            default:        f = b ^ c ^ d;                   k = 0xCA62_C1D6
            }
            let tmp = Self.rol(a, 5) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = Self.rol(b, 30); b = a; a = tmp
        }
        h.0 = h.0 &+ a; h.1 = h.1 &+ b; h.2 = h.2 &+ c; h.3 = h.3 &+ d; h.4 = h.4 &+ e
    }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        guard let base = data.baseAddress, data.count > 0 else { return }
        let p = base.assumingMemoryBound(to: UInt8.self)
        len &+= UInt64(data.count)
        var off = 0
        var n = data.count
        while n > 0 {
            let take = Swift.min(n, 64 - blen)
            for i in 0 ..< take { buf[blen &+ i] = p[off &+ i] }
            blen &+= take; off &+= take; n &-= take
            if blen == 64 {
                buf.withUnsafeBufferPointer { processBlock($0.baseAddress!) }
                blen = 0
            }
        }
    }

    /// Writes the 20-byte big-endian digest to `md` (mirrors SHA1_Final).
    mutating func finalize(into md: UnsafeMutablePointer<UInt8>) {
        let bits = len &* 8
        var pad: UInt8 = 0x80
        withUnsafeBytes(of: &pad) { update($0) }
        var zero: UInt8 = 0
        while blen != 56 { withUnsafeBytes(of: &zero) { update($0) } }
        var lb = [UInt8](repeating: 0, count: 8)
        for i in 0 ..< 8 { lb[i] = UInt8((bits >> UInt64(56 - i &* 8)) & 0xFF) }
        lb.withUnsafeBytes { update($0) }
        let arr = [h.0, h.1, h.2, h.3, h.4]
        for i in 0 ..< 5 {
            md[i &* 4]      = UInt8((arr[i] >> 24) & 0xFF)
            md[i &* 4 &+ 1] = UInt8((arr[i] >> 16) & 0xFF)
            md[i &* 4 &+ 2] = UInt8((arr[i] >> 8) & 0xFF)
            md[i &* 4 &+ 3] = UInt8(arr[i] & 0xFF)
        }
    }
}
#endif

package struct StrongHasher {
    #if OPENSWIFTUI_SWIFT_CRYPTO
    var state: Insecure.SHA1
    #elseif canImport(CommonCrypto)
    var state: CC_SHA1state_st
    #else
    var state: _OpenSwiftUIInsecureSHA1
    #endif

    package init() {
        #if OPENSWIFTUI_SWIFT_CRYPTO
        state = Insecure.SHA1()
        #elseif canImport(CommonCrypto)
        var context = CC_SHA1_CTX()
        CC_SHA1_Init(&context)
        state = context
        #else
        state = _OpenSwiftUIInsecureSHA1()
        #endif
    }

    package mutating func finalize() -> StrongHash {
        #if OPENSWIFTUI_SWIFT_CRYPTO
        var hash = StrongHash()
        let digest = state.finalize()
        digest.withUnsafeBytes { pointer in
            pointer.withMemoryRebound(to: UInt32.self) { buffer in
                hash.words = (buffer[0], buffer[1], buffer[2], buffer[3], buffer[4])
            }
        }
        return hash
        #elseif canImport(CommonCrypto)
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { pointer in
            CC_SHA1_Final(pointer.baseAddress, &state)
            var hash = StrongHash()
            pointer.withMemoryRebound(to: UInt32.self) { buffer in
                hash.words = (buffer[0], buffer[1], buffer[2], buffer[3], buffer[4])
            }
            return hash
        }
        #else
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { pointer in
            state.finalize(into: pointer.baseAddress!)
            var hash = StrongHash()
            pointer.withMemoryRebound(to: UInt32.self) { buffer in
                hash.words = (buffer[0], buffer[1], buffer[2], buffer[3], buffer[4])
            }
            return hash
        }
        #endif
    }

    mutating func combineBytes(_ ptr: UnsafeRawBufferPointer) {
        #if OPENSWIFTUI_SWIFT_CRYPTO
        state.update(bufferPointer: ptr)
        #elseif canImport(CommonCrypto)
        combineBytes(UnsafeRawPointer(ptr.baseAddress!), count: ptr.count)
        #else
        state.update(ptr)
        #endif
    }

    #if !OPENSWIFTUI_SWIFT_CRYPTO && canImport(CommonCrypto)
    package mutating func combineBytes(_ ptr: UnsafeRawPointer, count: Int) {
        CC_SHA1_Update(&state, ptr, CC_LONG(count))
    }
    #endif

    package mutating func combineBitPattern<T>(_ x: T) {
        withUnsafeBytes(of: x) { buffer in
            combineBytes(buffer)
        }
    }

    package mutating func combine<T>(_ x: T) where T: StronglyHashable {
        x.hash(into: &self)
    }

    package mutating func combineType(_ type: any Any.Type) {
        let signature = Metadata(type).signature
        _ = withUnsafePointer(to: signature.bytes) { ptr in
            #if OPENSWIFTUI_SWIFT_CRYPTO
            // TODO: Auditd signature API design
            _openSwiftUIUnimplementedFailure()
            #elseif canImport(CommonCrypto)
            CC_SHA1_Update(&state, ptr, 20)
            #else
            state.update(UnsafeRawBufferPointer(start: UnsafeRawPointer(ptr), count: 20))
            #endif
        }
    }
}

extension String: StronglyHashable {
    package func hash(into hasher: inout StrongHasher) {
        guard !isEmpty else { return }
        let cString = utf8CString
        cString.withUnsafeBufferPointer { buffer in
            hasher.combineBytes(UnsafeRawBufferPointer(buffer))
        }
    }
}

extension Data: StronglyHashable {
    package func hash(into hasher: inout StrongHasher) {
        withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            hasher.combineBytes(pointer)
        }
    }
}

extension Bool: StronglyHashable {
    package func hash(into hasher: inout StrongHasher) {
        hasher.combineBitPattern(self)
    }
}

extension Optional where Wrapped: StronglyHashable {
    package func hash(into hasher: inout StrongHasher) {
        guard let value = self else { return }
        value.hash(into: &hasher)
    }
}

extension RawRepresentable where RawValue: StronglyHashable {
    package func hash(into hasher: inout StrongHasher) {
        rawValue.hash(into: &hasher)
    }
}

package protocol StronglyHashableByBitPattern: StronglyHashable {}

extension StronglyHashableByBitPattern {
    package func hash(into hasher: inout StrongHasher) {
        hasher.combineBitPattern(self)
    }
}
extension Int: StronglyHashableByBitPattern {}
extension UInt: StronglyHashableByBitPattern {}
extension Int8: StronglyHashableByBitPattern {}
extension UInt8: StronglyHashableByBitPattern {}
extension Int16: StronglyHashableByBitPattern {}
extension UInt16: StronglyHashableByBitPattern {}
extension Int32: StronglyHashableByBitPattern {}
extension UInt32: StronglyHashableByBitPattern {}
extension Int64: StronglyHashableByBitPattern {}
extension UInt64: StronglyHashableByBitPattern {}
extension Float: StronglyHashableByBitPattern {}
extension Double: StronglyHashableByBitPattern {}
extension UUID: StronglyHashableByBitPattern {}

extension ORBUUID {
    package init(hash: StrongHash) {
        self.init(
            UInt64(hash.words.0) | (UInt64(hash.words.1) << 32),
            UInt64(hash.words.2) | (UInt64(hash.words.3) << 32),
            5
        )
    }
}

extension StrongHash: ProtobufMessage {
    package func encode(to encoder: inout ProtobufEncoder) {
        encoder.packedField(1) { encoder in
            encoder.encodeFixed32(words.0)
            encoder.encodeFixed32(words.1)
            encoder.encodeFixed32(words.2)
            encoder.encodeFixed32(words.3)
            encoder.encodeFixed32(words.4)
        }
    }
    
    package init(from decoder: inout ProtobufDecoder) throws {
        var hash = StrongHash()
        var count = 0
        while count < 5 {
            guard let field = try decoder.nextField() else {
                self = hash
                return
            }
            if field.tag == 1 {
                let result = try decoder.fixed32Field(field)
                switch count {
                case 0: hash.words.0 = result
                case 1: hash.words.1 = result
                case 2: hash.words.2 = result
                case 3: hash.words.3 = result
                case 4: hash.words.4 = result
                default: break
                }
                count += 1
            } else {
                try decoder.skipField(field)
            }
        }
        self = hash
    }
}
